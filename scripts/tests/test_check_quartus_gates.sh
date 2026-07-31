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
    bash "$GATE" "$tmp/output_files" >"$tmp/out" 2>&1
    local got=$?
    if [ "$got" = "$want" ]; then
        echo "PASS  $name (exit $got)"; PASS=$((PASS+1))
    else
        echo "FAIL  $name (want exit $want, got $got)"; sed 's/^/      /' "$tmp/out"; FAIL=$((FAIL+1))
    fi
    rm -rf "$tmp"
}

# --- Maldita.sta.summary helpers ---------------------------------------------
# Type/Slack/TNS triplets, one per record, matching the real TimeQuest
# summary format. TNS is irrelevant to the gate; a fixed placeholder is fine
# for entries where the exact value doesn't matter to the case under test.
sta_setup() { printf "Type  : Setup '%s'\nSlack : %s\nTNS   : %s\n\n" "$1" "$2" "${3:-0.000}"; }
sta_hold()  { printf "Type  : Hold '%s'\nSlack : %s\nTNS   : %s\n\n" "$1" "$2" "${3:-0.000}"; }

# The real, current, merged, device-validated build's numbers (run
# 30663741590, milestone-a, measured 2026-07-31): emu|pll at -0.159 ns
# (TNS -0.287), every other domain positive with TNS 0.000, hold clean.
sta_summary_real() {
    {
        sta_setup "emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk" "-0.159" "-0.287"
        sta_setup "pll_hdmi|pll_hdmi_inst|altera_pll_i|cyclonev_pll|counter[0].output_counter|divclk" "0.240"
        sta_setup "sysmem|fpga_interfaces|clocks_resets|h2f_user0_clk" "3.065"
        sta_setup "emu|pll|pll_inst|altera_pll_i|general[2].gpll~PLL_OUTPUT_COUNTER|divclk" "7.092"
        sta_setup "FPGA_CLK1_50" "8.364"
        sta_setup "SDRAM_CLK" "12.947"
        sta_setup "FPGA_CLK2_50" "13.125"
        sta_setup "pll_audio|pll_audio_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk" "16.686"
        sta_hold "emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk" "0.243"
        sta_hold "FPGA_CLK1_50" "0.413"
    } > "$1/output_files/Maldita.sta.summary"
}

fixture_clean() {
    printf 'Fitter completed\n' > "$1/output_files/Maldita.map.rpt"
    printf 'Timing analysis OK\n' > "$1/output_files/Maldita.sta.rpt"
    printf 'build ok\n' > "$1/logs/build_maldita.log"
    printf 'sta ok\n' > "$1/logs/sta_maldita.log"
    sta_summary_real "$1"
}

fixture_missing_map() {
    fixture_clean "$1"; rm -f "$1/output_files/Maldita.map.rpt"
}

fixture_missing_summary() {
    fixture_clean "$1"; rm -f "$1/output_files/Maldita.sta.summary"
}

fixture_setup_regression() {
    fixture_clean "$1"
    # emu|pll regresses to -0.25, worse than the -0.20 baseline.
    {
        sta_setup "emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk" "-0.25" "-0.40"
        sta_setup "FPGA_CLK1_50" "8.364"
        sta_hold "emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk" "0.243"
    } > "$1/output_files/Maldita.sta.summary"
}

fixture_setup_baseline_boundary() {
    fixture_clean "$1"
    # emu|pll sits exactly at -0.20, the baseline limit -- must pass.
    {
        sta_setup "emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk" "-0.20" "-0.30"
        sta_setup "FPGA_CLK1_50" "8.364"
    } > "$1/output_files/Maldita.sta.summary"
}

fixture_setup_other_domain_negative() {
    fixture_clean "$1"
    # FPGA_CLK1_50 goes negative by a tiny amount; emu|pll is clean (rule 1
    # alone would pass). Rule 2 must still fail.
    {
        sta_setup "emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk" "0.100" "0.000"
        sta_setup "FPGA_CLK1_50" "-0.001" "-0.001"
    } > "$1/output_files/Maldita.sta.summary"
}

fixture_setup_other_domain_negative_plus_baseline_emu() {
    fixture_clean "$1"
    # FPGA_CLK1_50 negative (rule 2) AND emu|pll within baseline (rule 1
    # would pass on its own) -- the two rules are independent, this fails.
    {
        sta_setup "emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk" "-0.159" "-0.287"
        sta_setup "FPGA_CLK1_50" "-0.001" "-0.001"
    } > "$1/output_files/Maldita.sta.summary"
}

fixture_setup_hold_negative_only() {
    fixture_clean "$1"
    # Only a Hold record is negative, and it lands on FPGA_CLK1_50 -- a
    # domain that is NOT accepted for a negative Setup slack (only emu|pll
    # is). That domain's own Setup record stays positive. This isolates the
    # property: if Hold rows ever leaked into the Setup decision, Rule 2
    # (only emu|pll may be negative) would trip on FPGA_CLK1_50 and the case
    # would fail. Today, with Hold correctly ignored, it must pass.
    {
        sta_setup "emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk" "-0.159" "-0.287"
        sta_setup "FPGA_CLK1_50" "8.364"
        sta_hold "FPGA_CLK1_50" "-0.001" "-0.010"
    } > "$1/output_files/Maldita.sta.summary"
}

fixture_setup_no_setup_entries() {
    fixture_clean "$1"
    # Summary exists but carries only Hold/Recovery-style records -- no
    # Setup entries at all. A parser finding nothing must fail closed.
    {
        sta_hold "FPGA_CLK1_50" "0.413"
        sta_hold "SDRAM_CLK" "11.412"
    } > "$1/output_files/Maldita.sta.summary"
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

run_case "clean build passes"                                            0 fixture_clean
run_case "missing map.rpt fails"                                         1 fixture_missing_map
run_case "missing Maldita.sta.summary fails"                             1 fixture_missing_summary
run_case "real build numbers (emu|pll -0.159, rest positive) pass"       0 fixture_clean
run_case "emu|pll regression past baseline (-0.25) fails"                1 fixture_setup_regression
run_case "emu|pll exactly at baseline (-0.20) passes"                    0 fixture_setup_baseline_boundary
run_case "non-emu|pll domain negative fails even at tiny magnitude"      1 fixture_setup_other_domain_negative
run_case "non-emu|pll negative fails even with emu|pll within baseline"  1 fixture_setup_other_domain_negative_plus_baseline_emu
run_case "negative Hold slack does not trip the setup gate"              0 fixture_setup_hold_negative_only
run_case "summary with no Setup entries fails"                           1 fixture_setup_no_setup_entries
run_case "276007 on a new file fails"                                    1 fixture_m10k_new_file
run_case "276007 on ddr_blitter_arb.sv passes"                           0 fixture_m10k_allowlisted
run_case "allowlisted plus new file still fails"                         1 fixture_m10k_both

echo "---"
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
