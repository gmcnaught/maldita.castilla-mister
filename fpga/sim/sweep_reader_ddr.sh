#!/usr/bin/env bash
# sweep_reader_ddr.sh — [#15 Task 3] characterise openbor_video_reader's scanout under
# real DDR latency. Builds tb_reader_ddr ONCE, then runs it in +DIAG mode across a grid
# of DDR delay / injected-stall / injected-beacon configurations and tabulates the
# DIAG SUM line from each run.
#
#   ./sweep_reader_ddr.sh grid            # G x B grid (default)
#   ./sweep_reader_ddr.sh stall           # one-shot stall, swept over its length
#   ./sweep_reader_ddr.sh beacon          # beacon fired at each row of the frame
#   ./sweep_reader_ddr.sh run <plusargs>  # one ad-hoc run, full output
#
# Each DIAG run prints:
#   DIAG SUM ... dup_events=<n> dup_row=<r> dup_frame=<f> bad_rows=<n> collide=<n>
#                anchors=<n> anchor_first=<r> anchor_last=<r> ...
# dup_events counts (row != 0) that displayed row 0's content for EVERY pixel — the
# device symptom. bad_rows counts rows that displayed anything other than themselves.
set -uo pipefail
cd "$(dirname "$0")"
export PATH="/opt/homebrew/bin:$PATH"

BUILD=.sweepbuild
VVP="$BUILD/tb_reader_ddr.vvp"
JOBS=${JOBS:-6}
FRAMES=${FRAMES:-12}

mkdir -p "$BUILD"
if [ ! -f "$VVP" ] || [ tb_reader_ddr.sv -nt "$VVP" ] || [ ../rtl/openbor_video_reader.sv -nt "$VVP" ]; then
  echo "building $VVP ..."
  iverilog -g2012 -o "$VVP" -I ../rtl -I ../rtl/jtframe -I ../sys -I . \
      -y ../rtl -y ../rtl/jtframe -y ../sys -y . -Y .sv -Y .v \
      ./*_stub.sv tb_reader_ddr.sv || exit 1
fi

run_one() {   # $*: NAME=VALUE tokens (the leading '+' is added here — vvp needs it)
  local tag="$*" out a; local -a pa=()
  for a in "$@"; do pa+=("+$a"); done
  out=$(vvp "$VVP" +DIAG "+FRAMES=$FRAMES" "${pa[@]}" 2>&1)
  printf '%s\n' "$out" | grep -E '^DIAG SUM' | sed "s|^DIAG SUM|$(printf '%-46s' "$tag")|"
  printf '%s\n' "$out" | grep -E '^DIAG ROWDUP' | head -4
}
export -f run_one; export VVP FRAMES

mode=${1:-grid}; shift || true
case "$mode" in
  run)
    exec vvp "$VVP" +DIAG "+FRAMES=$FRAMES" "$@"
    ;;
  grid)
    # G  = grant latency (cycles ddr_busy held after each accepted transaction)
    # B  = inter-beat gap. Budget: a scanline is 380px x 4 clk = 1520 cycles; the
    #      72-beat fill has only the 92-px hblank (368 cycles) of head start on the
    #      display, and the display consumes one qword every 16 cycles.
    for g in 0 64 128 256 320 368 400 512 768 1024 1520 3040; do
      for b in 0; do echo "DDR_G=$g DDR_B=$b"; done
    done > "$BUILD/grid.txt"
    for b in 1 2 4 8 12 15 16 20 32 64; do echo "DDR_G=0 DDR_B=$b"; done >> "$BUILD/grid.txt"
    ;;
  stall)
    # one-shot starvation: hold ddr_busy for N cycles from row R of frame 5.
    # 1520 cycles = one scanline.
    : > "$BUILD/grid.txt"
    for row in 0 100 210 213 214; do
      for len in 1520 3040 15200 152000 304000 320000 324000 325000 326000 330000; do
        echo "STALL_ROW=$row STALL_LEN=$len STALL_FRAME=5" >> "$BUILD/grid.txt"
      done
    done
    ;;
  beacon)
    # fire the liveness beacon at each row of frame 5 (and in vblank), optionally
    # with a grant latency on top ($2 = G, default 0).
    G=${1:-0}
    : > "$BUILD/grid.txt"
    for row in 0 1 100 200 208 209 210 211 212 213 214 215; do
      echo "BEACON_ROW=$row BEACON_FRAME=5 DDR_G=$G" >> "$BUILD/grid.txt"
    done
    ;;
  file)
    # $1 = a file of "NAME=VALUE NAME=VALUE" lines (one run per line)
    cp "$1" "$BUILD/grid.txt"
    ;;
  *) echo "usage: $0 [grid|stall|beacon|file <pts>|run]"; exit 2 ;;
esac

echo "== sweep: $mode (FRAMES=$FRAMES, $(wc -l < "$BUILD/grid.txt") points, JOBS=$JOBS) =="
xargs -P "$JOBS" -I{} bash -c 'run_one {}' < "$BUILD/grid.txt"
