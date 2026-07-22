# Running benchmarks locally (incl. local Marko)

This repo's normal benchmark flow assumes a desktop with Google Chrome installed
and unrestricted network access. In CI / sandboxed containers a few things get
in the way. [`bench-local.sh`](./bench-local.sh) handles them so you can compare
frameworks — in particular the published Marko build (`keyed/marko`) against a
local Marko build (`keyed/marko-local`) — with a single command.

## Quick start

```sh
# Build keyed/marko + keyed/marko-local and compare them on 01_run1k:
./bench-local.sh

# Skip the (re)build, run specific benchmarks with more iterations:
./bench-local.sh --no-build --benchmark 01_ 02_ --count 10

# Compare any frameworks:
./bench-local.sh keyed/vanillajs keyed/marko-local --benchmark 01_
```

Results are written to `webdriver-ts/results/<framework>_<benchmark>.json`; each
file's `values.total.{median,mean,min}` are the headline numbers.

Any non-flag arguments are forwarded to `webdriver-ts/dist/benchmarkRunner.js`.
If a framework arg looks like `keyed/x` or `non-keyed/x` it is also (re)built
unless `--no-build` is given.

## What the script handles

* **Browser selection.** The full `chrome` binary can hang on headless startup
  in some sandboxes, so the script prefers Playwright's headless shell — probing
  both `/opt/pw-browsers/chromium_headless_shell-*` and the default
  `~/.cache/ms-playwright/chromium_headless_shell-*` cache (and both the newer
  `chrome-headless-shell` and older `headless_shell` binary names) — then a
  prebuilt `chromium-*`, then a system `google-chrome`/`chromium`. Get one with
  `npx playwright install --only-shell chromium`, or override with
  `CHROME_BINARY=/path/to/binary`.
* **Root / containers.** Sets `--no-sandbox` automatically when running as root.
* **Runner.** Uses the **Playwright** runner. The default `puppeteer` runner
  downloads its own browser from `cdn.playwright.dev`, which egress-restricted
  environments block.
* **Setup.** Installs `server/` and `webdriver-ts/` deps (skipping the
  Playwright browser download) and compiles the runner on first use, and starts
  the static server on `:8080` if it isn't already up.

## Two supporting changes in this repo

These make the above possible and are useful beyond Marko:

1. `webdriver-ts/src/playwrightAccess.ts` honors two env vars:
   * `CHROME_BINARY` — path to the Chrome/Chromium executable to launch.
   * `CHROME_NO_SANDBOX` — when set, adds `--no-sandbox`.
2. `frameworks/keyed/marko-local` uses a static `frameworkVersion: "local"`
   (instead of `frameworkVersionFromPackage`) because its Marko dependency is a
   symlinked `file:` build with no version recorded in `package-lock.json`.

## Manual equivalent

```sh
# one-time setup
( cd server && npm install )
( cd webdriver-ts && PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 npm install && npm run compile )

# build the frameworks under test
( cd frameworks/keyed/marko        && npm install && npm run build-prod )
( cd frameworks/keyed/marko-local  && npm run link-local && npm run build-prod )

# start the server (separate shell)
( cd server && npm start )

# run the benchmark
cd webdriver-ts
CHROME_NO_SANDBOX=1 \
CHROME_BINARY=/opt/pw-browsers/chromium_headless_shell-1194/chrome-linux/headless_shell \
LANG=en_US.UTF-8 \
node dist/benchmarkRunner.js keyed/marko keyed/marko-local \
  --benchmark 01_ --count 8 --runner playwright --headless true
```

## Refreshing the local Marko build

`keyed/marko-local` benchmarks whatever was last vendored into its `.local/`
directory. After changing the local Marko checkout, refresh it with
`./bench-local.sh` (which re-runs `link-local`) or manually:

```sh
( cd frameworks/keyed/marko-local && npm run link-local && npm run build-prod )
```

See [`frameworks/keyed/marko-local/README.md`](./frameworks/keyed/marko-local/README.md).
