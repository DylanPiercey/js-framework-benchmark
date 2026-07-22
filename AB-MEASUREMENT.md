# A/B measuring a local Marko change

Tooling to decide, rigorously, whether an in-progress change to the local Marko
checkout (`../marko`) actually moves a benchmark — despite a noisy, shared,
CPU-throttled local environment.

## Setup: two frameworks from the same Marko base

- `frameworks/keyed/marko-local` — app linked against the **patched** Marko build.
- `frameworks/keyed/marko-base` — identical app linked against a **clean** Marko
  build (stash your change first). This is the A/B baseline.

Build both from one Marko checkout by stashing the change while building `base`:

```sh
cd ../marko && git stash push packages/runtime-tags/src/dom/...   # your change
( cd frameworks/keyed/marko-base  && npm run link-local && npm run build-prod )
cd ../marko && git stash pop
( cd frameworks/keyed/marko-local && npm run link-local && npm run build-prod )
```

`marko-base` differs from `marko-local` only in its `vite.config.js` `base:` path
and `frameworkVersion`.

## Why a naive comparison lies

`benchmarkRunner` measures **all** of framework A's iterations, then **all** of
B's. Any drift over that window — thermal, CPU-frequency, or a background process
— biases every comparison in one direction. On this box, benchmarks whose code
was *identical* still showed ±10–30% "differences" with high t-stats. **A single
fixed-order run cannot be trusted for sub-10% changes.**

Two silent traps that produced phantom results here:
1. **Orphaned benchmark processes.** A backgrounded run that outlives its shell
   keeps hammering the CPU and contaminates every later run. Before/after any
   measurement: `pgrep -af 'benchmarkRunner|chrome-headless|bench-local'` must be
   empty, and check `/proc/loadavg`.
2. **Stale result JSONs.** The runner only overwrites benchmarks it runs, so old
   files masquerade as fresh data. `ab-paired.sh` clears them each run.

## The paired harness

`ab-paired.sh` runs many short rounds and **alternates which framework leads**
each round, snapshotting per-round results. Alternating lead + pairing cancels
the fixed-order/contention bias. `ab-aggregate.py` pairs the rounds and reports
mean Δ%, standard error, a t-stat, and how many rounds the patch won.

```sh
CHROME_BINARY=~/.cache/ms-playwright/chromium_headless_shell-*/chrome-headless-shell-linux64/chrome-headless-shell \
  ./ab-paired.sh 14 4 300 01_ 08_ 09_        # 14 rounds, count 4, 300s/round timeout
python3 ab-aggregate.py                       # report
```

**Always include a control benchmark** your change cannot affect (e.g. `09_` for
a change to the insert path). If the control shows |t|≥2, the run was too noisy —
the method did not fully cancel the bias, so distrust the other rows too. Only
believe a result whose control stayed flat.

Δ% < 0 means the patched build is faster. `|t| ≥ 2` ≈ 95% significant, but treat a
lone significant row among several as likely noise (multiple-comparison).
