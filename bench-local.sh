#!/usr/bin/env bash
#
# bench-local.sh — reliably run a js-framework-benchmark comparison locally
# (and in CI / sandboxed containers), with sensible defaults for comparing the
# published Marko build (keyed/marko) against a local Marko build
# (keyed/marko-local).
#
# It papers over the rough edges that otherwise make a local run fail:
#   * Picks a Chromium that actually works headless. The full `chrome` binary
#     can hang on startup in some sandboxes, so Playwright's `headless_shell`
#     is preferred when available (see CHROME_BINARY detection below).
#   * Passes --no-sandbox when running as root (containers).
#   * Uses the Playwright runner (the default `puppeteer` runner needs a
#     downloadable browser that egress-restricted environments can't fetch).
#   * Installs runner/server deps and compiles the runner on first use.
#   * Starts the static server on :8080 if it isn't already up.
#
# Usage:
#   ./bench-local.sh                       # build + compare keyed/marko vs keyed/marko-local on 01_run1k
#   ./bench-local.sh --no-build            # skip the framework (re)build step
#   ./bench-local.sh keyed/marko keyed/marko-local --benchmark 01_ 02_ --count 10
#   CHROME_BINARY=/path/to/chrome ./bench-local.sh   # force a specific browser
#
# Any arguments are forwarded to webdriver-ts/dist/benchmarkRunner.js. If none
# are given, it compares keyed/marko vs keyed/marko-local on 01_run1k.

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

DEFAULT_FRAMEWORKS=(keyed/marko keyed/marko-local)
DO_BUILD=1
RUNNER_ARGS=()

for arg in "$@"; do
  case "$arg" in
    --no-build) DO_BUILD=0 ;;
    --build)    DO_BUILD=1 ;;
    *)          RUNNER_ARGS+=("$arg") ;;
  esac
done

# ---------------------------------------------------------------------------
# 1. Locate a working Chromium.
# ---------------------------------------------------------------------------
detect_chrome() {
  if [ -n "${CHROME_BINARY:-}" ]; then echo "$CHROME_BINARY"; return; fi
  # Prefer the lightweight headless shell — the full chrome build hangs on
  # headless startup in some sandboxes.
  for d in /opt/pw-browsers/chromium_headless_shell-*/chrome-linux/headless_shell; do
    [ -x "$d" ] && { echo "$d"; return; }
  done
  for d in /opt/pw-browsers/chromium-*/chrome-linux/chrome; do
    [ -x "$d" ] && { echo "$d"; return; }
  done
  for b in google-chrome google-chrome-stable chromium chromium-browser; do
    p="$(command -v "$b" 2>/dev/null || true)"; [ -n "$p" ] && { echo "$p"; return; }
  done
  echo ""
}

CHROME_BINARY="$(detect_chrome)"
if [ -z "$CHROME_BINARY" ]; then
  echo "ERROR: no Chrome/Chromium found. Install one or set CHROME_BINARY=/path/to/binary." >&2
  exit 1
fi
export CHROME_BINARY
echo "==> Using Chrome binary: $CHROME_BINARY"

# Chromium refuses to run as root without --no-sandbox (e.g. inside containers).
if [ "$(id -u)" = "0" ]; then export CHROME_NO_SANDBOX=1; fi

# ---------------------------------------------------------------------------
# 2. Ensure runner + server deps and the compiled runner exist.
# ---------------------------------------------------------------------------
if [ ! -d server/node_modules ]; then
  echo "==> Installing server deps"
  ( cd server && npm install --no-audit --no-fund )
fi
if [ ! -d webdriver-ts/node_modules ]; then
  echo "==> Installing webdriver-ts deps (skipping browser download)"
  ( cd webdriver-ts && PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 npm install --no-audit --no-fund )
fi
echo "==> Compiling benchmark runner"
( cd webdriver-ts && npm run compile )

# ---------------------------------------------------------------------------
# 3. (Optionally) build the frameworks under test.
#    keyed/marko-local must be linked against the local Marko build first.
# ---------------------------------------------------------------------------
build_framework() {
  local fw="$1" dir="frameworks/$1"
  [ -f "$dir/package.json" ] || return 0
  echo "==> Building $fw"
  if [ "$fw" = "keyed/marko-local" ]; then
    # link-local rebuilds the local Marko, vendors it into .local/ and installs.
    ( cd "$dir" && npm run link-local )
  elif [ ! -d "$dir/node_modules" ]; then
    ( cd "$dir" && npm install --no-audit --no-fund )
  fi
  ( cd "$dir" && npm run build-prod )
}

if [ "$DO_BUILD" = "1" ]; then
  # Build the frameworks we're about to benchmark (defaults if none specified).
  to_build=()
  for a in "${RUNNER_ARGS[@]:-}"; do
    case "$a" in keyed/*|non-keyed/*) to_build+=("$a") ;; esac
  done
  [ ${#to_build[@]} -eq 0 ] && to_build=("${DEFAULT_FRAMEWORKS[@]}")
  for fw in "${to_build[@]}"; do build_framework "$fw"; done
fi

# ---------------------------------------------------------------------------
# 4. Ensure the static server is running on :8080.
# ---------------------------------------------------------------------------
if ! curl -sf http://localhost:8080/ls >/dev/null 2>&1; then
  echo "==> Starting static server on :8080"
  ( cd server && npm start >/tmp/jfb-server.log 2>&1 & )
  for _ in $(seq 1 30); do
    curl -sf http://localhost:8080/ls >/dev/null 2>&1 && break
    sleep 1
  done
fi

# ---------------------------------------------------------------------------
# 5. Run the benchmark (Playwright runner).
# ---------------------------------------------------------------------------
if [ ${#RUNNER_ARGS[@]} -eq 0 ]; then
  RUNNER_ARGS=("${DEFAULT_FRAMEWORKS[@]}" --benchmark 01_ --count 8)
fi

echo "==> Running: benchmarkRunner ${RUNNER_ARGS[*]} --runner playwright --headless true"
cd webdriver-ts
exec env LANG="en_US.UTF-8" node dist/benchmarkRunner.js \
  "${RUNNER_ARGS[@]}" --runner playwright --headless true
