#!/usr/bin/env bash
# Tests for fpga/scripts/check_quartus_gates.sh. Builds synthetic report
# fixtures in a temp dir — no Quartus required. Pure bash, no deps, exit 0/1,
# matching the other scripts/tests/test_*.sh files.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
GATE="$(cd "$HERE/../.." && pwd)/fpga/scripts/check_quartus_gates.sh"
PASS=0; FAIL=0

run_case() {
    local name="$1" want="$2"; shift 2
    local tmp; tmp="$(mktemp -d)"
    mkdir -p "$tmp/output_files" "$tmp/logs"
    "$@" "$tmp"
    bash "$GATE" "$tmp/output_files" "$tmp/logs" >"$tmp/out" 2>&1
    local got=$?
    if [ "$got" = "$want" ]; then
        echo "PASS  $name (exit $got)"; PASS=$((PASS+1))
    else
        echo "FAIL  $name (want exit $want, got $got)"; sed 's/^/      /' "$tmp/out"; FAIL=$((FAIL+1))
    fi
    rm -rf "$tmp"
}

fixture_clean() {
    printf 'Fitter completed\n' > "$1/output_files/Maldita.map.rpt"
    printf 'Timing analysis OK\n' > "$1/output_files/Maldita.sta.rpt"
    printf 'build ok\n' > "$1/logs/build_maldita.log"
    printf 'sta ok\n' > "$1/logs/sta_maldita.log"
}

fixture_missing_map() {
    fixture_clean "$1"; rm -f "$1/output_files/Maldita.map.rpt"
}

fixture_timing_violation() {
    fixture_clean "$1"
    printf 'Critical Warning (332148): Timing requirements not met\n' \
        >> "$1/output_files/Maldita.sta.rpt"
}

fixture_m10k_new_file() {
    fixture_clean "$1"
    printf 'Warning (276007): Inferred RAM node from tq_data in file blitter_top.sv\n' \
        >> "$1/output_files/Maldita.map.rpt"
}

fixture_m10k_allowlisted() {
    fixture_clean "$1"
    printf 'Warning (276007): Inferred RAM node in file ddr_blitter_arb.sv\n' \
        >> "$1/output_files/Maldita.map.rpt"
}

fixture_m10k_both() {
    fixture_m10k_allowlisted "$1"
    printf 'Warning (276007): Inferred RAM node in file blitter_top.sv\n' \
        >> "$1/output_files/Maldita.map.rpt"
}

run_case "clean build passes"                    0 fixture_clean
run_case "missing map.rpt fails"                 1 fixture_missing_map
run_case "332148 timing violation fails"         1 fixture_timing_violation
run_case "276007 on a new file fails"            1 fixture_m10k_new_file
run_case "276007 on ddr_blitter_arb.sv passes"   0 fixture_m10k_allowlisted
run_case "allowlisted plus new file still fails" 1 fixture_m10k_both

echo "---"
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
