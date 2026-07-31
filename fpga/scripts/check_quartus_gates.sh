#!/usr/bin/env bash
# check_quartus_gates.sh -- production gates for a Quartus build of Maldita.
#
# Usage: check_quartus_gates.sh <output_files_dir> <logs_dir>
#
# Exits 0 only when BOTH gates pass. Fails closed: a missing report is a
# failure, never a silent pass, because a build that produced no report is
# exactly the case a naive grep would wave through.
#
#   332148  setup timing violation. Any hit fails.
#   276007  an array carrying a `ramstyle` attribute did not infer to M10K.
#           When this fires the array becomes thousands of stray flops behind a
#           huge mux and timing collapses (see the 2026-07-29 tq_data
#           regression: -0.983 ns, ALMs 61%). Any hit fails EXCEPT the
#           reviewed, known-benign case listed in M10K_ALLOWLIST below.
set -uo pipefail

[ $# -eq 2 ] || { echo "usage: $0 <output_files_dir> <logs_dir>" >&2; exit 2; }
OUT="$1"; LOGS="$2"

# Files whose 276007 hit has been reviewed and accepted. Named individually on
# purpose: a blanket skip would also hide the NEXT regression, which is the
# failure mode this gate exists to catch.
#
#   ddr_blitter_arb.sv -- pre-existing, reviewed 2026-07-31. Predates the gate;
#                         not introduced by any Phase 4 work.
M10K_ALLOWLIST="ddr_blitter_arb.sv"

fail() { echo "::error::$*"; echo "GATE FAIL: $*" >&2; exit 1; }

# --- gate 0: the reports must exist ------------------------------------------
for r in "$OUT/Maldita.map.rpt" "$OUT/Maldita.sta.rpt"; do
    [ -f "$r" ] || fail "required report missing: $r (a build with no report is not a pass)"
done

# --- gate 1: setup timing (332148) -------------------------------------------
TIMING_HITS=$(grep -l "332148" "$OUT"/*.sta.rpt "$LOGS"/build_*.log "$LOGS"/sta_*.log 2>/dev/null || true)
if [ -n "$TIMING_HITS" ]; then
    echo "--- 332148 hits ---" >&2
    grep -h "332148" "$OUT"/*.sta.rpt "$LOGS"/build_*.log "$LOGS"/sta_*.log 2>/dev/null >&2 || true
    fail "timing gate: setup violation (Critical Warning 332148) in: $(echo "$TIMING_HITS" | tr '\n' ' ')"
fi

# --- gate 2: M10K inference (276007) -----------------------------------------
M10K_LINES=$(grep -h "276007" "$OUT"/*.map.rpt 2>/dev/null || true)
if [ -n "$M10K_LINES" ]; then
    UNEXPECTED=""
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        allowed=0
        for f in $M10K_ALLOWLIST; do
            case "$line" in *"$f"*) allowed=1; break;; esac
        done
        [ "$allowed" -eq 1 ] || UNEXPECTED="$UNEXPECTED$line
"
    done <<< "$M10K_LINES"
    if [ -n "$UNEXPECTED" ]; then
        echo "--- unexpected 276007 hits ---" >&2
        printf '%s' "$UNEXPECTED" >&2
        fail "M10K gate: uninferred ramstyle array (map.rpt 276007) outside the allowlist. A ramstyle array's read must never be nested in an FSM case arm."
    fi
    echo "note: 276007 present only on allowlisted files ($M10K_ALLOWLIST) -- accepted"
fi

echo "OK: both production gates passed (332148 clean, 276007 within allowlist)"
