#!/usr/bin/env python3
"""Aggregate ab-paired.sh snapshots into a bias-cancelled A/B report.

For each round we have base and local medians (measured with alternating lead
order). The paired per-round delta d_r = local - base still contains any
per-round drift, but because lead order alternates, averaging d_r across rounds
cancels the fixed ordering bias. We report the mean paired delta, its standard
error, a t stat, and a sign test, per benchmark and metric.
"""
import json, os, sys, glob, math, re, statistics as st

SNAP = sys.argv[1] if len(sys.argv) > 1 else "webdriver-ts/results/paired-snap"
METRICS = ["total", "script"]

# filename: r03_local__marko-base-vbase-keyed_01_run1k.json
pat = re.compile(r"r(\d+)_(base|local)__marko-(base|local)-v\w+-keyed_(.+)\.json$")

# data[bench][metric][round] = {"base": median, "local": median, "lead": ...}
data = {}
for f in glob.glob(os.path.join(SNAP, "*.json")):
    m = pat.search(os.path.basename(f))
    if not m: continue
    rnd, lead, which, bench = int(m.group(1)), m.group(2), m.group(3), m.group(4)
    vals = json.load(open(f))["values"]
    for metric in METRICS:
        med = st.median(vals[metric]["values"])
        d = data.setdefault(bench, {}).setdefault(metric, {}).setdefault(rnd, {})
        d[which] = med
        d["lead"] = lead

def report(metric):
    print(f"\n===== {metric.upper()}  (paired rounds, alternating lead; local=patched) =====")
    print(f"{'benchmark':<24}{'base':>8}{'local':>8}{'Δ%':>8}{'±sem%':>7}{'t':>6}{'n':>4}{'win':>6}")
    print("-" * 71)
    for bench in sorted(data):
        rounds = data[bench][metric]
        deltas, basev, locv = [], [], []
        wins = 0
        for rnd, d in rounds.items():
            if "base" in d and "local" in d:
                deltas.append(d["local"] - d["base"])
                basev.append(d["base"]); locv.append(d["local"])
                if d["local"] < d["base"]: wins += 1
        n = len(deltas)
        if n < 2:
            print(f"{bench:<24}  insufficient rounds ({n})"); continue
        mb, ml = st.mean(basev), st.mean(locv)
        md = st.mean(deltas)
        sd = st.pstdev(deltas) if n > 1 else 0
        sem = (st.stdev(deltas) / math.sqrt(n)) if n > 1 else 0
        pct = md / mb * 100 if mb else 0
        sempct = sem / mb * 100 if mb else 0
        t = md / sem if sem else 0
        print(f"{bench:<24}{mb:>8.2f}{ml:>8.2f}{pct:>+7.1f}%{sempct:>6.1f}%{t:>+6.1f}{n:>4}{wins:>3}/{n}")
    print("  Δ%<0 => patched faster. |t|>=2 ~ 95% sig. win=rounds patched won.")

for metric in METRICS:
    report(metric)
