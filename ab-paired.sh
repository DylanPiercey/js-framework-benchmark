#!/usr/bin/env bash
#
# ab-paired.sh — hang-guarded paired A/B (base=clean vs local=patched Marko).
# Starts the static server ONCE, then calls benchmarkRunner directly each round,
# ALTERNATING which framework leads to cancel the runner's fixed-order and any
# background-contention bias (measure all of A then all of B drifts one way).
# ab-aggregate.py pairs the rounds and reports mean Δ%, sem, t, and win count.
# Each round is wrapped in `timeout` so a stalled browser fork can't block it.
#
# Usage: ./ab-paired.sh <rounds> <count> <round_timeout_s> <bench-prefix...>
#   ./ab-paired.sh 14 4 300 01_ 08_ 09_ && python3 ab-aggregate.py
#
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

ROUNDS="${1:?rounds}"; shift
COUNT="${1:?count}"; shift
RTO="${1:?round timeout s}"; shift
BENCHES=("$@"); [ ${#BENCHES[@]} -eq 0 ] && BENCHES=(01_)

FWA="keyed/marko-base"; FWB="keyed/marko-local"
RESULTS="$ROOT/webdriver-ts/results"
SNAP="${AB_SNAP:-$RESULTS/paired-snap}"
rm -rf "$SNAP"; mkdir -p "$SNAP"
# Clear stale result files so only freshly-measured benchmarks get snapshotted.
rm -f "$RESULTS"/marko-base-*.json "$RESULTS"/marko-local-*.json

export CHROME_BINARY="${CHROME_BINARY:-$(ls ~/.cache/ms-playwright/chromium_headless_shell-*/chrome-headless-shell-linux64/chrome-headless-shell 2>/dev/null | head -1)}"
export CHROME_NO_SANDBOX=1
export LANG=en_US.UTF-8

# Start server once if not up.
if ! curl -sf http://localhost:8080/ls >/dev/null 2>&1; then
  echo "starting server..."
  ( cd server && npm start >/tmp/jfb-ab-server.log 2>&1 & )
  for _ in $(seq 1 30); do curl -sf http://localhost:8080/ls >/dev/null 2>&1 && break; sleep 1; done
fi

echo "ab-paired: $ROUNDS rounds x count $COUNT (timeout ${RTO}s), benches: ${BENCHES[*]}"
ok=0
for r in $(seq 1 "$ROUNDS"); do
  if (( r % 2 == 1 )); then ORDER=("$FWA" "$FWB"); LEAD="base"; else ORDER=("$FWB" "$FWA"); LEAD="local"; fi
  printf '== round %d/%d (lead=%s) ' "$r" "$ROUNDS" "$LEAD"
  if ( cd webdriver-ts && timeout "$RTO" node dist/benchmarkRunner.js "${ORDER[@]}" \
        --benchmark "${BENCHES[@]}" --count "$COUNT" --runner playwright --headless true ) \
        >"$SNAP/round_${r}.log" 2>&1; then
    for f in "$RESULTS"/marko-base-*.json "$RESULTS"/marko-local-*.json; do
      [ -e "$f" ] || continue
      cp "$f" "$SNAP/r$(printf '%02d' "$r")_${LEAD}__$(basename "$f")"
    done
    ok=$((ok+1)); echo "ok"
  else
    echo "TIMED OUT/failed (skipped)"
    pkill -9 -f 'forkedBenchmarkRunner' 2>/dev/null
    pkill -9 -f 'chrome-headless-shell' 2>/dev/null
  fi
done
echo "done. $ok/$ROUNDS rounds ok. snapshots in $SNAP"
