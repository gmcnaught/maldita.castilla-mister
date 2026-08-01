#!/usr/bin/env bash
# check_quartus_gates.sh -- production gates for a Quartus build of Maldita.
#
# Usage: check_quartus_gates.sh <output_files_dir>
#
# Exits 0 only when BOTH gates pass. Fails closed: a missing report is a
# failure, never a silent pass, because a build that produced no report is
# exactly the case a naive grep would wave through.
#
#   setup timing  a slack-baseline check against Maldita.sta.summary, not a
#                 warning-presence check. Baseline -0.20 ns on the accepted
#                 domain emu|pll (the real, merged, device-validated
#                 milestone-a build measured -0.159 ns on that domain, CI run
#                 30663741590, 2026-07-31); any other domain going negative,
#                 or emu|pll regressing past the baseline, fails.
#   276007        Quartus declined to infer an array to M10K. Two distinct mechanisms
#                 produce this: (a) a `ramstyle`-attributed array whose read is nested
#                 inside an FSM case arm (the 2026-07-29 tq_data regression: -0.983 ns,
#                 ALMs 61%, 20,480 stray flops -- see docs/architecture/04-code-fabric-raster.md
#                 §(b)); (b) asynchronous-read logic on an array with NO ramstyle
#                 attribute at all, e.g. ddr_blitter_arb.sv's xq_mem. Either way the
#                 array becomes stray flops behind a big mux and timing degrades. Any
#                 hit fails EXCEPT the reviewed, known-benign array(s) listed in
#                 M10K_ALLOWLIST below.
set -uo pipefail

[ $# -eq 1 ] || { echo "usage: $0 <output_files_dir>" >&2; exit 2; }
OUT="$1"

# Array(s) whose 276007 hit has been reviewed and accepted. Each entry is
# "file.sv+array_name" -- a report line is allowlisted only when BOTH
# substrings appear in it. This is per-ARRAY, not per-file: a blanket
# file-only skip would also hide a SECOND array regressing in the same file,
# which is exactly the failure mode this gate exists to catch (that is what
# the tq_data precedent was -- one array in one file). The `.sv` suffix is
# load-bearing on the first token: every 276007 hit in this file also carries
# the "ddr_blitter_arb:blitter_arb" INSTANCE PATH substring (the hierarchy,
# not the filename), so a bare "ddr_blitter_arb" token (no ".sv") would
# false-match that instance-path text before the array-name check even runs.
#
#   ddr_blitter_arb.sv+xq_mem -- pre-existing, reviewed 2026-07-31. Predates
#       the gate; not introduced by any Phase 4 work. NOT a `ramstyle`-array
#       case (this file carries no `ramstyle` attribute at all) -- Quartus
#       17.0 flags xq_mem "uninferred due to asynchronous read logic", a
#       different mechanism from the ramstyle/FSM-case-arm mechanism 276007
#       also reports (see docs/architecture/04-code-fabric-raster.md §(b)).
M10K_ALLOWLIST="ddr_blitter_arb.sv+xq_mem"

fail() { echo "::error::$*"; echo "GATE FAIL: $*" >&2; exit 1; }

# --- gate 0: the reports must exist ------------------------------------------
for r in "$OUT/Maldita.map.rpt" "$OUT/Maldita.sta.rpt" "$OUT/Maldita.sta.summary"; do
    [ -f "$r" ] || fail "required report missing: $r (a build with no report is not a pass)"
done

# --- gate 1: setup timing (per-domain baseline) ------------------------------
# Baseline -0.20 ns, established 2026-07-31 from the real, merged,
# device-validated shipping build (CI run 30663741590, milestone-a). That
# build's worst-case setup slack is -0.159 ns / TNS -0.287 ns, entirely on
# the emu|pll clock domain (the PLL output-counter path); every other
# domain is positive with TNS 0.000, and hold is clean (+0.243 ns). Gating
# on the mere presence of a setup violation (Critical Warning 332148) would
# block every release including this one, so instead: baseline the known
# violation and fail on regression. -0.20 leaves ~0.04 ns of headroom over
# today's real -0.159; the goal is to TIGHTEN this value toward zero as the
# emu|pll path is improved, never to loosen it.
SETUP_BASELINE="-0.20"
ACCEPTED_SETUP_DOMAIN="emu|pll"
STA_SUMMARY="$OUT/Maldita.sta.summary"

# Emit "<domain>\t<slack>" for every Setup record; Hold/Recovery/Removal/
# Minimum-Pulse-Width records are ignored. Domain names are matched between
# the FIRST and LAST single-quote on the "Type" line (passed in as awk var Q
# to avoid bash quoting issues), so embedded spaces survive and a stray
# embedded quote doesn't truncate the name early.
SETUP_ROWS=$(awk -v Q="'" '
    /^Type[ \t]*:/ {
        kind = ""; name = ""
        line = $0
        q1 = index(line, Q)
        if (q1 == 0) { next }
        prefix = substr(line, 1, q1 - 1)
        colon = index(prefix, ":")
        kind = substr(prefix, colon + 1)
        gsub(/^[ \t]+|[ \t]+$/, "", kind)
        rest = substr(line, q1 + 1)
        lastq = 0
        for (i = length(rest); i >= 1; i--) {
            if (substr(rest, i, 1) == Q) { lastq = i; break }
        }
        name = (lastq > 0) ? substr(rest, 1, lastq - 1) : rest
        next
    }
    /^Slack[ \t]*:/ {
        if (kind == "Setup") {
            val = $0
            sub(/^Slack[ \t]*:[ \t]*/, "", val)
            gsub(/^[ \t]+|[ \t]+$/, "", val)
            printf "%s\t%s\n", name, val
        }
        kind = ""
        next
    }
' "$STA_SUMMARY" 2>/dev/null)

if [ -z "$SETUP_ROWS" ]; then
    fail "timing gate: no Setup entries found in $STA_SUMMARY -- a parser finding nothing is a failure, not a pass"
fi

WORST_DOMAIN=""; WORST_SLACK=""
OTHER_DOMAIN_HITS=""
while IFS=$'\t' read -r domain slack; do
    [ -n "$domain" ] || continue

    if [ -z "$WORST_SLACK" ] || awk -v a="$slack" -v b="$WORST_SLACK" 'BEGIN{exit !(a+0 < b+0)}'; then
        WORST_SLACK="$slack"; WORST_DOMAIN="$domain"
    fi

    case "$domain" in
        *"$ACCEPTED_SETUP_DOMAIN"*) ;;  # only this domain may be negative
        *)
            if awk -v s="$slack" 'BEGIN{exit !(s+0 < 0)}'; then
                OTHER_DOMAIN_HITS="$OTHER_DOMAIN_HITS$domain: $slack
"
            fi
            ;;
    esac
done <<< "$SETUP_ROWS"

# Rule 1 (regression): worst-case setup slack across ALL domains must not be
# worse than the baseline. -0.20 itself passes (limit, not exclusive bound).
if awk -v w="$WORST_SLACK" -v base="$SETUP_BASELINE" 'BEGIN{exit !(w+0 < base+0)}'; then
    fail "timing gate: setup regression -- worst-case slack $WORST_SLACK ns on domain '$WORST_DOMAIN' is worse than the accepted baseline $SETUP_BASELINE ns"
fi

# Rule 2 (new domain): independent of rule 1 -- ONLY $ACCEPTED_SETUP_DOMAIN
# may carry a negative setup slack, regardless of magnitude.
if [ -n "$OTHER_DOMAIN_HITS" ]; then
    echo "--- negative setup slack outside the accepted domain ($ACCEPTED_SETUP_DOMAIN) ---" >&2
    printf '%s' "$OTHER_DOMAIN_HITS" >&2
    fail "timing gate: negative setup slack outside the accepted domain ($ACCEPTED_SETUP_DOMAIN): $(printf '%s' "$OTHER_DOMAIN_HITS" | tr '\n' '; ')"
fi

echo "note: setup timing within baseline -- worst slack $WORST_SLACK ns on '$WORST_DOMAIN' (accepted domain: $ACCEPTED_SETUP_DOMAIN, baseline: $SETUP_BASELINE ns)"

# --- gate 2: M10K inference (276007) -----------------------------------------
M10K_LINES=$(grep -h "276007" "$OUT"/*.map.rpt 2>/dev/null || true)
if [ -n "$M10K_LINES" ]; then
    UNEXPECTED=""
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        allowed=0
        for entry in $M10K_ALLOWLIST; do
            entry_ok=1
            IFS='+' read -ra reqs <<< "$entry"
            for req in "${reqs[@]}"; do
                case "$line" in *"$req"*) ;; *) entry_ok=0; break;; esac
            done
            if [ "$entry_ok" -eq 1 ]; then allowed=1; break; fi
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

echo "OK: both production gates passed (setup timing within baseline, 276007 within allowlist)"
