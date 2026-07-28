#!/bin/bash
# M10K inference gate — catches the defect class fixed in 476a422.
#
# THE RULE: a `ramstyle`-annotated array's READ must live in its own unconditional clocked
# block. Nest it inside an FSM case arm and Quartus 17.0 silently declines to infer the BRAM
# ("uninferred due to asynchronous read logic", map.rpt Info 276007) and builds the array out
# of LAB flops instead. For blitter_top's 256x64 tq_data + 256x16 tq_tag that meant 20,480
# stray registers (~45% of the whole design's), b_qtag[7:0] becoming the top non-global
# fan-out net in the design (~1,735) driving a real 256:1 distributed mux, and a worst-case
# setup path of -0.983 ns whose data path was a single 9.565 ns route with NO logic cells in
# it. Writes in a case arm are fine; only the read position matters.
#
# Why this is a script and not a plain rules/*.yaml entry: the check has to correlate a
# DECLARATION (which arrays carry `ramstyle`) with a distant READ of that same name, and
# ast-grep matches one node at a time with no cross-node symbol table. So we extract the
# annotated array names per file and generate an inline rule with a name alternation. Upside
# over a hand-maintained name list: a newly added ramstyle array is covered automatically.
#
# Why kind:-based rules and not `pattern:`: ast-grep metavariables are spelled $NAME, and in
# SystemVerilog `$name` is system-task syntax — a metavariable pattern parses to an ERROR
# node and silently matches NOTHING. Same trap documented in rules/hdl-lint.yaml.
#
# Gate scope: WHOLE TREE. Unlike solarus-mister's diff-scoped ratchet (which had ~80 legacy
# findings to grandfather), this tree is at zero findings, so there is no debt to scope
# around and any regression should fail immediately.
set -uo pipefail
cd "$(dirname "$0")/../.."

command -v ast-grep >/dev/null 2>&1 || { echo "FATAL: ast-grep not on PATH (npm i -g @ast-grep/cli)"; exit 1; }
[ -f .ast-grep/systemverilog.so ] || bash scripts/provision_ast_grep_sv.sh

# Pull the identifier out of e.g.  (* ramstyle = "no_rw_check, M10K" *) reg [63:0] tq_data [0:255];
extract_arrays() {
  perl -ne 'print "$1\n" if /ramstyle.*?\*\)\s*(?:reg|logic)\s*(?:signed\s*)?(?:\[[^\]]*\]\s*)?(\w+)\s*\[/' "$1" | sort -u
}

# Scan ONE file for reads of ITS OWN ramstyle arrays nested in a case arm. Echoes findings to
# stdout; returns the finding count via the global `_found`.
_found=0
scan_file() {
  local f="$1" names rule json n
  names=$(extract_arrays "$f" | paste -sd'|' -)
  [ -z "$names" ] && return 0
  rule="
id: ramstyle-array-read-in-case-arm
language: systemverilog
severity: error
message: \"M10K inference: read of ramstyle array nested in a case arm. Quartus will build this from LAB flops, not BRAM (map.rpt Info 276007). Move the read into its own unconditional 'always @(posedge clk)' block.\"
rule:
  kind: nonblocking_assignment
  all:
    - has: {kind: expression, has: {kind: hierarchical_identifier, regex: \"^($names)\$\", stopBy: end}}
    - inside: {kind: case_item, stopBy: end}
"
  json=$(ast-grep scan --inline-rules "$rule" "$f" --json 2>/dev/null || true)
  n=$(printf '%s' "$json" | python3 -c 'import sys,json; print(len(json.load(sys.stdin)))' 2>/dev/null || echo -1)
  if [ "$n" -lt 0 ]; then
    echo "FATAL: ast-grep produced no parseable JSON for $f (grammar/tool error)"
    ast-grep scan --inline-rules "$rule" "$f" || true
    exit 1
  fi
  if [ "$n" -gt 0 ]; then
    ast-grep scan --inline-rules "$rule" "$f" 2>/dev/null || true
    _found=$((_found + n))
  fi
}

# ── self-test: prove the gate has teeth before trusting a clean tree scan ──────────────
# A rule that matched nothing would pass the tree scan forever and guard nothing, so the
# known-bad fixture MUST fire and the known-good one MUST NOT.
_found=0; scan_file scripts/tests/fixtures/ramstyle_bad.sv  >/dev/null 2>&1; bad=$_found
_found=0; scan_file scripts/tests/fixtures/ramstyle_good.sv >/dev/null 2>&1; good=$_found
if [ "$bad" -lt 1 ]; then
  echo "SELF-TEST FAIL — the known-bad fixture did NOT fire; the rule is toothless."
  echo "  (grammar drift, or the rule stopped matching nonblocking_assignment/case_item)"
  exit 1
fi
if [ "$good" -ne 0 ]; then
  echo "SELF-TEST FAIL — the known-good fixture fired ($good); the rule flags the CORRECT shape."
  exit 1
fi
echo "[ramstyle-gate] self-test OK — known-bad fires ($bad), known-good silent"

# ── the actual gate ───────────────────────────────────────────────────────────────────
_found=0
files=$(git ls-files 'fpga/rtl/*.sv' 'fpga/rtl/*.v' 'fpga/rtl/**/*.sv' 'fpga/rtl/**/*.v' 2>/dev/null | grep -vE '/pll\.v$')
count=0
for f in $files; do
  [ -f "$f" ] || continue
  count=$((count + 1))
  scan_file "$f"
done

if [ "$_found" -gt 0 ]; then
  echo "RAMSTYLE-GATE FAIL — $_found ramstyle array read(s) nested in a case arm across $count file(s)."
  echo "  Fix: move the read into its own unconditional 'always @(posedge clk)' block."
  echo "  Verify after the next build: grep 276007 output_files/Maldita.map.rpt"
  exit 1
fi
echo "RAMSTYLE-GATE OK — 0 nested ramstyle-array reads across $count RTL file(s)"
