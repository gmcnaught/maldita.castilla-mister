#!/usr/bin/env bash
# run_sims.sh — build + run every fpga/sim testbench under Icarus Verilog and
# report PASS/FAIL. Run LOCALLY ONLY — there is no sim workflow in .github/workflows/
# (build-rbf.yml is the sole workflow, and it does not invoke this script). That matters:
# the geometry contract-check below is the only gate covering the production RTL's root,
# so nothing catches a root change automatically. Adding a sim workflow would close it.
#
# Why a runner instead of per-test filelists: every tb_*.sv resolves its RTL
# deps through iverilog's library search (-y over ../rtl ../sys and this dir,
# module-name == file-name), so one invocation builds all of them with zero
# hand-maintained file lists. Verified: 0 build errors across the suite.
#
# Pass detection: the suite uses several success conventions (PASS / RESULT:
# PASS / "errors=0" / RESULT: ALIVE), so each TB's positive marker is given
# below; a run passes iff it prints its PASS marker, prints no FAIL marker, and
# exits within its timeout. SKIP and NONGATING tune which TBs affect the exit
# code (see comments). Unknown/new tb_*.sv default to needing "PASS".
#
# Usage:
#   ./run_sims.sh                 # all testbenches
#   ./run_sims.sh tb_sdram_ctrl   # a subset (names with or without .sv)
#
# STREAM_VEC=<tag> env var: tb_blitter_trilist_stream[/cache]'s header
# documents replaying an alternate committed vector tag via
# -DSTREAM_VEC='"<tag>"' on the iverilog command line (see the tb header's
# "SELECTING A FRAME" note). This is that pass-through, so an alternate tag
# can be gated without hand-invoking iverilog:
#   STREAM_VEC=stream_heavy_f0 ./run_sims.sh tb_blitter_trilist_stream
# Applied to EVERY TB compile in the run (harmless on TBs that don't
# reference the STREAM_VEC macro, same as TIER_DEFINES_FULL below).
set -uo pipefail

cd "$(dirname "$0")"   # fpga/sim — relative ../rtl, ../sys resolve from here

# ── tuning ────────────────────────────────────────────────────────────────
# tb_profile is a cycle-budget PROFILER (analysis, not a correctness gate): it
# runs representative blits through the real comp_pipeline + vram_demux datapath
# and buckets every cycle by FSM phase (setup/load/SRCFILL/comp/WB) to report
# cyc/px. Run it directly, with optional knob sweeps:
#   iverilog -g2012 -o /tmp/p.vvp -I ../rtl -I ../rtl/jtframe -I ../sys -I . \
#     -y ../rtl -y ../rtl/jtframe -y ../sys -y . -Y .sv -Y .v tb_profile.sv && vvp /tmp/p.vvp
#   ( +define+PROF_SRC_LAT=n / +PROF_DST_LAT=n / +COMP_BAND_H=n / +COMP_MAXBURST=n )
# It always prints RESULT: PASS, so it stays SKIP (no verdict to gate on).
# (The legacy sdram_psx/sdram_src_arb/sdram_burst_arb modules and their benches —
# (The legacy sdram_psx/sdram_src_arb/sdram_burst_arb modules and their benches —
# tb_sdram_psx/ctrl/sweep/burst_arb/src_arb[_beatloss], plus the retired-DUT
# tb_capture_race/tb_demux_preempt and tb_sdram_stage — were deleted in JC-T8 when
# the SDRAM path pivoted to sdram_fb_cache; the cache wrapper is covered by
# tb_sdram_fb_cache and the per-client cache-ok paths by tb_vram_demux /
# tb_scanout_sdram / tb_blitter_system_pipe.)
SKIP="tb_profile"
# Self-checking but slow under Icarus: run them, report, but don't fail the
# suite on their result (so a CI timeout can't block unrelated work). The legacy
# tb_blitter_system was retired with the legacy renderer; tb_blitter_system_pipe
# (gating) is the system-level check now.
#
# tb_vram_contention is NON-GATING: JC-T7 re-pointed it onto sdram_fb_cache + mt48.
# It builds and the cache serves P_DST, but completing the full contention workload
# under the faithful mt48 model in iverilog is impractically slow; a CI-tractable
# system re-gate (+ the coh_busy client-gating refinement) is a JC follow-up. See
# the tb header.
#
# tb_comp_replay is NON-GATING and CANNOT be gated as-is (#96 correction — the old
# "DOES PASS in ~350s" note was STALE). It is a visual-DUMP dev tool, not a self-
# checking test: it $readmemh's an external capture `bltdump.hex` that is NOT in the
# repo (so in CI it loads an EMPTY command stream, composites a trivial frame, and
# dumps fb0_replay.bin with no PASS assertion), AND it scan-reads FB0 from SDRAM —
# the scanout path FB-in-BRAM (#49) retired (scanout now reads comp_fbram via
# fbram_scan_adapter), so the scan port never serves SDRAM_FB0_BASE and it dies
# "scan_read timeout @0400000". Gating it would require (a) committing a real
# bltdump.hex capture + a golden, and (b) re-pointing its readback to comp_fbram
# (as #96 did for tb_blitter_system_pipe). Until then it stays NON-GATING + nightly-
# only; the reducer's loud NON-GATING-failure banner surfaces it in nightly so it
# cannot drift silently. Tracked as a follow-up. #44/#96.
# tb_scan_qworddup (#44 A,A,C,C guard) and tb_vram_contention (P_DST/P_SCAN
# contention) are now GATING: a sim-only full-rate ce_pix (vs the HW ÷8 pixel
# clock) shrinks the reader's frame-paced sync from ~1.5M to ~188k cycles, and
# reduced scan-rows / fill-height keep coverage while cutting wall time to ~36s /
# ~53s. The full HW-faithful geometry is restored with +define+SCAN_QWORDDUP_FULL
# / +define+VRAM_CONTENTION_FULL (nightly).
# v2 "blitter escape elimination" equivalence TBs (Workstream C). They diff the
# comp_pipeline RTL against the C goldens (blitter_ref.c) for the new colour ops:
#   tb_blitter_add_pipe       — ADD blend (mode 4),  BLIT + FILL  == blt_add565
#   tb_blitter_mul_pipe       — MULTIPLY blend (mode 5), BLIT + FILL == blt_mul565
#   tb_blitter_colormod_pipe  — COLORMOD (0x40) over COPY/CONST_ALPHA/PALPHA + FILL
# GATING as of the v2 integration: Workstream B's ADD/MULTIPLY/COLORMOD comp_pipeline
# is merged and these diff bit-exact against the C goldens (all three PASS), so they
# now fail the suite on any RTL/golden divergence. The tint wire layout was reconciled
# at integration to byte27=cb / byte30=cr / byte31=cg (blt_wire.h ↔ blitter_top.sv).
# [FB-in-BRAM #96] tb_blitter_system_pipe is now GATING again. It had rotted after the
# FB-in-BRAM cutover: the TB never wired comp_fbram / blitter_top.fb_* (so every
# composite vanished) nor drove vs (so the pipe wedged in S_SNAP_WAIT after frame 1 and
# later submits never composited) -> all phases read stale SDRAM = 0 and it "FAILed +
# was slow". #96 wired comp_fbram + the fb_* ports, drove a free-running vs, and
# re-pointed the dest readback (getpx) from the retired SDRAM FB to comp_fbram WORK.
# All four phases (FILL/reader-concurrency, tall-chunk, multi-cmd painter, per-cmd
# SDRAM-source mux, carry-forward) now PASS in ~1.6ms sim (seconds wall) -> gating in
# every tier. (tb_comp_banding / tb_comp_banding_scanout / tb_fbcopy_dst2src_sameframe were
# RETIRED 2026-06-26: they tested the SDRAM FB write / async-flush / ch0->ch5 carry-
# forward paths that FB-in-BRAM deletes — premises moot, no re-point needed.)
# The comp_pipeline mixer-boundary cutover itself is fully gated bit-exact by
# tb_comp_pipeline + the seven tb_blitter_*_pipe equivalence TBs (all reading comp_fbram).
#
# [gmloader-GPU slim] tb_tilelist/tb_tilelist_res/tb_clut_upload/tb_pal8_*/
# tb_bgplane_*/tb_bgw_ch0_mux/tb_mixed_format_seq were RETIRED along with the
# OP_TILELIST/OP_TILELIST_RES/OP_FRT_UPLOAD/OP_BGPLANE_WRITE/OP_CLUT_UPLOAD
# opcodes they exercised — those Solarus-legacy blitter ops (and their FSMs,
# regs, and support submodules) are gone from blitter_top.sv.
# [#96] tb_blitter_system_pipe was FIXED and REMOVED from NONGATING (it gates in every
# tier now). tb_comp_replay remains NON-GATING — it is a visual-dump dev tool that
# cannot self-check without a committed capture + a comp_fbram scanout re-point (see the
# long note above). It is NOT silenced: the reducer's loud NON-GATING-failure banner
# surfaces its failure in nightly. The banner mechanism future-proofs any new NON-GATING
# TB against drifting from "known-slow" into "known-broken".
#
# tb_blitter_trilist_uvfull: FIXED 2026-07-26 (was NON-GATING/known-RED, bad=173/76800;
# now GATES — see git history for the pre-fix note). Root cause: `tri_p0_addr` was
# double-duty as both the P_SRC bus address AND pa's A_ADDR2->A_ISSUE qword-tag
# hand-carry; pb's B_FILL demand-miss write clobbered it mid-flight, pushing a stale
# qtag into the texel FIFO. Fixed by giving pa a private `pa_qtag` register (blitter_top.sv)
# so tri_p0_addr is written only when a P_SRC read is actually issued. bad=0/76800,
# perf-neutral (tri=154084 texwait=39589 dpath=114495, byte-identical pre/post fix). See
# docs/superpowers/plans/2026-07-26-rendering-regression-fixes.md Task 2,
# .superpowers/sdd/uvfull-rootcause-report.md, .superpowers/sdd/task-8-report.md.
#
# tb_blitter_trilist_sdram is NON-GATING (dev tool, not re-gated by the uvfull fix —
# see below).
# Runs TRILIST texel fetch through the REAL sdram_fb_cache + mt48 SDRAM chip model
# (blt.p0_* wired straight to ch5, unlike every other TRILIST bench, which stubs
# P_SRC); stages the same tri_uvfull 32 KiB texture via a real BLT_OP_STAGE (ch1,
# ~126 evictions), then runs the same TRILIST scene. Pre-fix: bad=175/76800, a STRICT
# SUPERSET of tb_blitter_trilist_uvfull's then-known bad=173 (byte-identical got/exp on
# all 173 shared coordinates) plus 2 isolated single-pixel mismatches — (40,48) and
# (166,164). Post-fix (2026-07-26, pa_qtag): bad=0/76800 — the 2 stragglers were the
# SAME bug manifesting through the real cache's fetch timing, not a separate cache-layer
# defect. Left NON-GATING as a dev tool (real SDRAM co-sim, ~45s wall) rather than
# promoted to gating; re-promote if it proves stably green over time. See
# .superpowers/sdd/task-3-report.md, .superpowers/sdd/task-8-report.md.
#
# [Phase 3A Task 5] tb_blitter_trilist_stream is GATING (not in NONGATING below).
# It replays a CAPTURED DEVICE FRAME of Maldita's draw stream — vectors/stream_quiet_f0_*
# from gen_tri_stream.c, 106 TRILIST commands / 212 triangles / 48 texture pages — through
# the production blitter_top and diffs the whole composited WORK bank against the
# refmodel golden. It is the only bench whose scene is real device geometry rather than a
# hand-written scenario, so it catches coverage/blend/addressing breakage that only shows
# up at production scale (48 distinct strides, 78 COLORKEY + 28 COPY draws in one ring, a
# BLT_F_SRC_SURFACE composite, and triangles clipped off all four screen edges).
# bad=0/62208 AND bit-exact. ~32 s standalone -> 300 s budget below. The gate is STRICT
# bit-exactness (exact_bad==0), not the siblings' +-1 LSB tolerance: this bench is the
# Stage-B oracle for a pixel-walk rewrite and rounding drift lands as a 1-LSB diff.
# It also prints the CYC/CYCX/MS cycle decomposition Tasks 6-8 predict against; those
# lines are informational, but five internal cross-checks are gated (TB buckets vs the
# RTL's own perf_frame_cyc / perf_tri_cyc / perf_texwait_cyc / perf_covered_px, plus the
# bucket partition summing to the total) — any of which prints RESULT: FAIL.
# Other frames are runnable by name after regenerating their vectors; see the tb header
# and gen_tri_golden.mk's stream-vectors target.
#
# tb_blitter_trilist_synthquad is the same harness (a 3-line wrapper that `include's it)
# on the SYNTHETIC single-quad vector set, and it is GATING too. It exists because the
# captured frames' expected cycle counts are only knowable by running them — the buckets
# could drift and still look plausible. The synthetic quad's counts are hand-computable
# from the geometry (pix_covered=120*120=14400, pix_visits=2*121*121=29282, wr=3*14400)
# and are ASSERTED via STREAM_EXP_*, so this is the calibration anchor for the bucket
# semantics themselves. ~5 s.
#
# [Phase 3A Task 6] tb_blitter_trilist_spanedge is the same harness again, GATING, on a
# vector set built to close two MEASURED holes in the bit-exact gate: when the span walk
# landed, two deliberate off-by-ones in the walk's LEFT endpoint (sk_covm's `>=` -> `>`,
# and the `tri_px == tri_ox` clamp -> `== tri_ox+1`) were caught by NONE of the other ten
# trilist benches — both need a leftward seek, which the captured frames and the synthetic
# quad barely exercise. Its five non-overlapping triangles (one off-left-CLAMPED, four with
# vertices on pixel centres and slope -1 left edges (T3: -2)) make each mutation fail: exact_bad=760
# and exact_bad=5 respectively. Non-overlapping is load-bearing — an overlapping triangle
# would overpaint the dropped pixels and re-hide the hole. ~2 s. See the tb header for the
# per-triangle derivation and why the M1 margin is inherently only a few pixels.
#
# [Phase 3B Task 1] tb_blitter_trilist_streamcache is the SAME captured-frame harness
# with the REAL texel path: `STREAM_REALCACHE` swaps the fixed-3-cycle P_SRC stub for
# sdram_fb_cache ch5 + the mt48 chip model (the pair tb_blitter_trilist_sdram already
# co-simulates), leaving everything else — DDR image, behavioral DDR3 + its
# poll-before-issue gate, buckets, gates — untouched, so the texwait delta against the
# stub sibling is attributable to texel latency alone. It exists because the stub's
# `texwait` is a FLOOR (0.013 ms post-levers) and the device's is 3.42 ms; this bench
# measures the real number and is what decided the Stage-B/Quartus gate. Pre-lever it
# reproduces device texwait to −0.7% (quiet) / −0.6% (arrival) — see
# .superpowers/sdd/stageB-task-1-report.md.
# NONGATING + NIGHTLY_ONLY purely on RUNTIME (mt48 co-sim, ~10x the stub replay's ~30s,
# and contention-sensitive), NOT because anything about it is known-shaky: it gates
# strict bit-exactness and all five cross-checks internally, and bit-exactness is the
# load-bearing precondition here (same DDR image, same texels, only slower — a single
# changed pixel means the SDRAM image or its address mapping is wrong and every cycle
# number in the run is worthless). A failure is surfaced by the NON-GATING banner.
NONGATING="tb_comp_replay tb_blitter_trilist_sdram tb_blitter_trilist_streamcache"

# ── tiers ───────────────────────────────────────────────────────────────────
# NIGHTLY_ONLY: TBs excluded from the PR tier. tb_comp_replay is a non-gating visual-
# dump tool (see note above) — deferred in PR (surfaced by the DEFERRED note), and it
# still RUNS non-gating in nightly where the loud banner flags its failure. It is NOT a
# fast gate. tb_blitter_system_pipe is NO LONGER here: after the #96 fix it runs in
# ~1.6ms sim, so it gates in EVERY tier (incl. PR).
# [gmloader-GPU slim] tb_bgplane_maptrans and tb_bgplane_inval_teeth were RETIRED
# with OP_BGPLANE_WRITE (see the note above); they no longer exist to defer.
NIGHTLY_ONLY="tb_comp_replay tb_blitter_trilist_streamcache"

# +defines applied to EVERY compile in the nightly tier to restore full
# HW-faithful geometry/rate. Harmless on TBs that don't reference a macro, so
# Phase 2 tasks add each _FULL guard in their TB file and the macro here is a
# no-op until that guard lands. Pre-populated with ALL 7 macros (team-execution
# amendment) so Phase 2 is pure TB-file edits.
# NOTE: iverilog 13.0 takes -D<NAME> on the command line (the +define+<NAME>
# form is command-FILE only; on argv it is parsed as a source file). This matches
# the -D form already used by defines_for() (e.g. -DP2_SDRAM_SYS).
# [gmloader-GPU slim] BGPLANE_EQUIV_FULL/BGPLANE_WRITE_FULL/BGPLANE_MAPTRANS_FULL/
# FBRAM_SDRAM_FULL guarded TBs (tb_bgplane_equivalence, tb_bgplane_write_pipe[_xl],
# tb_bgplane_maptrans, tb_fbram_to_sdram[_backpressure]) that were RETIRED with
# OP_BGPLANE_WRITE (see the SKIP-block note above); dropped as dead flags.
# [#97] -DFABRIC_ASSERT turns on the sim-only fabric SVAs (immediate assertions gated by
# `ifdef FABRIC_ASSERT in the RTL; iverilog has no concurrent-assertion support). Active
# in nightly so a violated invariant (e.g. stage_barrier dropped mid-sequence) prints
# "FABRIC-ASSERT FAIL ..." -> trips FAIL_RE and fails the suite.
TIER_DEFINES_FULL='-DVRAM_CONTENTION_FULL -DSCAN_QWORDDUP_FULL -DSCANOUT_FBRAM_FULL -DAUDIO_WEDGE_FULL -DFABRIC_ASSERT'

# Per-TB positive marker (default = "PASS"); FAIL markers are common to all.
pass_re() { case "$1" in
  tb_ddr_blitter_arb)           echo 'read errors=0|PASS' ;;
  *)                            echo 'RESULT: PASS|PASS' ;;
esac; }
FAIL_RE='FAIL|DEADLOCK|STARV|WEDGE|Assertion failed|PROTO:|TIMEOUT'

# Per-TB wall-clock budget (seconds); slow ones get more.
timeout_s() { case "$1" in
  # GATING faithful-mt48 TBs (reduced sim geometry, see NONGATING note): ~55s
  # local. Budget 120->180: the sim job now runs at nproc-1 (see sim.yml) so light
  # TBs no longer share a saturated core, but keep generous margin for the slower CI
  # core — this is the TB that spuriously timed out at 120s under the old --jobs=nproc.
  # (tb_scan_qworddup retired with the SDRAM scanout path — FB-in-BRAM scanout reads
  #  comp_fbram via fbram_scan_adapter, covered pixel-exact by tb_scanout_fbram.)
  tb_vram_contention)                      echo 180 ;;
  # Non-gating full-frame visual-dump TB: ~350s to actually PASS, capped low.
  tb_comp_replay)                          echo 30 ;;
  # [#15] The scanout gate must run PAST the reader's own 2^22-cycle liveness beacon
  # (~10.5 bench frames) — that fire is what dispatched a frame restart inside active
  # video and made row 214 display row 0. That puts the run at ~13 frames / 5.5 M cycles,
  # ~58s standalone (was ~46s at 10 frames), and it spuriously timed out at 120s under
  # concurrent suite load. Same situation and same remedy as tb_vram_contention above.
  # The frame count is a floor, not slack: the beacon period sets it.
  tb_reader_ddr)                           echo 300 ;;
  # Non-gating real-cache+mt48 TRILIST co-sim (see NONGATING note above). Wall time
  # is HIGHLY contention-sensitive: ~45-60s isolated, but observed 8+ min under
  # concurrent CPU load from other sims/builds on the same machine (this bench
  # co-simulates the bit-level SDRAM chip model, unlike every stub-P_SRC sibling).
  # Generous budget so ordinary CI contention doesn't spuriously non-gate-fail it.
  tb_blitter_trilist_sdram)                echo 480 ;;
  # [Phase 3A Task 5] Captured-device-frame replay: 1.56 M sim cycles (a real frame is
  # ~10x the synthetic scenarios), ~32 s standalone. 300 s covers CI-core contention.
  tb_blitter_trilist_stream)               echo 300 ;;
  # [Phase 3B Task 1] Same replay through the REAL texel path (see the NONGATING note).
  # 1.44 M sim cycles with the bit-level mt48 model in the loop. MEASURED: 147 s run
  # alone, 1384 s inside a full --tier=nightly pass. That 9.4x spread is not CPU
  # scheduling -- the mt48 model declares four 8M x 16-bit bank arrays, so two
  # concurrent instances (this bench + tb_blitter_trilist_sdram) put the whole run under
  # memory pressure. Budget 3600 s: >2.5x the measured worst case, and since the bench
  # is nightly-only a generous budget costs the PR tier nothing.
  tb_blitter_trilist_streamcache)          echo 3600 ;;
  # [gmloader-GPU slim] tb_bgplane_equivalence/write_pipe_xl/3plane_xl/maptrans/
  # inval_teeth and tb_pal8_bgplane were RETIRED with OP_BGPLANE_WRITE/OP_CLUT_
  # UPLOAD (see the SKIP-block note above); their budget entries are gone too.
  *)                                       echo 120 ;;
esac; }

# Per-TB extra +defines (default none). tb_blitter_system_pipe gates on the
# SDRAM-source/dest phases (PHASE1-pipe/2A/2B/3/4); without the define it falls
# back to DEFERRED stubs and the real phases would not be exercised.
defines_for() { case "$1" in
  tb_blitter_system_pipe) echo '-DP2_SDRAM_SYS' ;;
  *)                      echo '' ;;
esac; }

# ── prerequisites ───────────────────────────────────────────────────────────
command -v iverilog >/dev/null || { echo "ERROR: iverilog not found"; exit 2; }
command -v vvp      >/dev/null || { echo "ERROR: vvp not found"; exit 2; }
command -v make     >/dev/null || { echo "ERROR: make not found (needed for contract-check)"; exit 2; }
TIMEOUT=$(command -v timeout || command -v gtimeout || true)   # optional

# ── contract gate (runs BEFORE any TB) ──────────────────────────────────────
# gen_tri_golden.mk's contract-check asserts that the refmodel the goldens are
# generated from and the RTL the fabric is built from still agree on (a) the
# TRILIST/SET_TARGET opcodes and (b) the FB geometry root (FB_W x FB_H vs
# BLT_FB_WIDTH x BLT_FB_HEIGHT). It used to fire ONLY when someone regenerated
# vectors — i.e. never in the battery — so a geometry/opcode divergence could sit
# in the tree while the bit-exact TBs happily compared against stale goldens.
# Run it here so divergence is an immediate, hard failure of the whole run.
if ! contract_out=$(make -f gen_tri_golden.mk contract-check 2>&1); then
  echo "!!!==========================================================================!!!"
  echo "!!! CONTRACT-CHECK FAILED — refmodel/RTL disagree; goldens do NOT gate the fabric."
  printf '%s\n' "$contract_out" | sed 's/^/!!!   /'
  echo "!!! Fix the contract (or regenerate vectors) before trusting any TB result."
  echo "!!!==========================================================================!!!"
  echo "RESULT: FAIL"
  exit 1
fi
printf '%s\n' "$contract_out" | grep -E '^contract-check' || true

BUILD=.simbuild; rm -rf "$BUILD"; mkdir -p "$BUILD"
RESULTS="$BUILD/results"; mkdir -p "$RESULTS"
STUBS=$(ls ./*_stub.sv 2>/dev/null || true)

# ── tier + jobs + positional-TB parsing ─────────────────────────────────────
TIER=pr; JOBS=0; POS=()
for a in "$@"; do
  case "$a" in
    --tier=*) TIER="${a#--tier=}" ;;
    --jobs=*) JOBS="${a#--jobs=}" ;;
    *)        POS+=("$a") ;;
  esac
done
case "$TIER" in pr|nightly|all) ;; *) echo "ERROR: --tier must be pr|nightly|all"; exit 2;; esac
set -- ${POS[@]+"${POS[@]}"}            # bash-3.2-safe empty-array expansion (macOS)

TIER_DEFINES=''
[ "$TIER" = nightly ] && TIER_DEFINES="$TIER_DEFINES_FULL"

# STREAM_VEC pass-through (see the usage note above). Built once here so it's
# a single already-quoted argv token by the time it reaches iverilog, same
# shape as the tb header's own '-DSTREAM_VEC="tag"' example.
EXTRA_DEFINES=''
if [ -n "${STREAM_VEC:-}" ]; then
  EXTRA_DEFINES="-DSTREAM_VEC=\"$STREAM_VEC\""
fi

# default N = nproc-2 (>=1); N=1 reproduces today's exact serial order+output
if [ "$JOBS" -le 0 ] 2>/dev/null; then
  NPROC=$( { command -v nproc >/dev/null && nproc; } || sysctl -n hw.ncpu || echo 2 )
  JOBS=$(( NPROC > 2 ? NPROC - 2 : 1 ))
fi

# Which testbenches to run
if [ $# -gt 0 ]; then
  TBS=(); for a in "$@"; do TBS+=("${a%.sv}.sv"); done
else
  TBS=(tb_*.sv)
fi

# ── per-TB body (one call per TB; parallel-safe) ────────────────────────────
# Emits two files per TB: $RESULTS/$top.result (CSV: top,gating,verdict,secs —
# consumed by the reducer) and $RESULTS/$top.row (the formatted display row).
# When JOBS=1 it also prints the row live, so -P1 streams identically to the old
# serial loop. Row text is byte-identical to the pre-parallel serial formatting.
run_one_tb() {
  local tb="$1" top row gating=1 blog rlog to rc out ok=0 verdict note tag secs t0
  top="${tb%.sv}"   # separate stmt: in one `local`, all RHS expand pre-assignment
  t0=$(date +%s.%N)
  case " $SKIP " in *" $top "*)
    row=$(printf '%-26s %-8s %s' "$top" "skip" "benchmark (no verdict)")
    printf '%s,1,skip,0\n' "$top" >"$RESULTS/$top.result"; printf '%s\n' "$row" >"$RESULTS/$top.row"
    [ "$JOBS" = 1 ] && printf '%s\n' "$row"; return 0;; esac
  case " $NONGATING " in *" $top "*) gating=0;; esac
  if [ "$TIER" = pr ]; then case " $NIGHTLY_ONLY " in *" $top "*)
    row=$(printf '%-26s %-8s %s' "$top" "defer" "nightly-only (excluded from pr tier)")
    printf '%s,%s,defer,0\n' "$top" "$gating" >"$RESULTS/$top.result"; printf '%s\n' "$row" >"$RESULTS/$top.row"
    [ "$JOBS" = 1 ] && printf '%s\n' "$row"; return 0;; esac; fi
  blog="$BUILD/$top.build.log"
  if ! iverilog -g2012 -o "$BUILD/$top.vvp" $(defines_for "$top") $TIER_DEFINES $EXTRA_DEFINES \
        -I ../rtl -I ../rtl/jtframe -I ../sys -I . \
        -y ../rtl -y ../rtl/jtframe -y ../sys -y . -Y .sv -Y .v \
        $STUBS "$tb" >"$blog" 2>&1; then
    note="build error: $(grep -iE 'error|cannot|no such' "$blog" | head -1)"
    row=$(printf '%-26s %-8s %s' "$top" "BUILD!" "$note")
    printf '%s,%s,BUILD!,0\n' "$top" "$gating" >"$RESULTS/$top.result"; printf '%s\n' "$row" >"$RESULTS/$top.row"
    [ "$JOBS" = 1 ] && printf '%s\n' "$row"; return 0
  fi
  rlog="$BUILD/$top.run.log"; to=$(timeout_s "$top")
  if [ "$TIER" = nightly ]; then case "$top" in
    tb_comp_replay)          to=600 ;;   # needs ~350s to PASS
    tb_blitter_system_pipe)  to=300 ;;
    tb_vram_contention)      to=300 ;;   # FULL geometry safety margin
    # FULL-geometry reduced TBs (~75-95s standalone) need margin over the 120s
    # default under --jobs=nproc contention on a slower CI core (else spurious
    # nightly gating timeout). scanout ~95s is the tightest.
    # tb_gm_audio drives four multi-second scenarios (constant, triangle across
    # two ring wraps, and two rate-lock soaks) through a scaled DUT.
    tb_gm_audio)             to=300 ;;
  esac; fi
  if [ -n "$TIMEOUT" ]; then "$TIMEOUT" "$to" vvp "$BUILD/$top.vvp" >"$rlog" 2>&1; rc=$?
  else vvp "$BUILD/$top.vvp" >"$rlog" 2>&1; rc=$?; fi
  secs=$(awk "BEGIN{printf \"%.1f\", $(date +%s.%N)-$t0}" 2>/dev/null || echo 0)
  out=$(cat "$rlog")
  if [ $rc -eq 124 ]; then verdict=timeout; note="timeout (${to}s)"
  elif echo "$out" | grep -qE "$FAIL_RE"; then verdict=FAIL; note="failed: $(echo "$out" | grep -iE "$FAIL_RE" | head -1)"
  elif echo "$out" | grep -qE "$(pass_re "$top")"; then verdict=PASS; ok=1; note=""
  else verdict=noPASS; note="no PASS marker; finished rc=$rc"; fi
  if [ $ok -eq 1 ]; then
    row=$(printf '%-26s %-8s %s' "$top" "PASS" "$([ $gating -eq 0 ] && echo '(non-gating)')")
  else
    tag=$([ $gating -eq 1 ] && echo "FAIL" || echo "fail")
    row=$(printf '%-26s %-8s %s' "$top" "$tag" "$note$([ $gating -eq 0 ] && echo ' (non-gating)')")
  fi
  printf '%s,%s,%s,%s\n' "$top" "$gating" "$verdict" "$secs" >"$RESULTS/$top.result"
  printf '%s\n' "$row" >"$RESULTS/$top.row"
  [ "$JOBS" = 1 ] && printf '%s\n' "$row"
  return 0
}

# ── dispatch (xargs pool) + reducer ─────────────────────────────────────────
export BUILD RESULTS STUBS TIER TIER_DEFINES EXTRA_DEFINES TIMEOUT JOBS SKIP NONGATING NIGHTLY_ONLY FAIL_RE
export -f run_one_tb pass_re timeout_s defines_for

printf '%-26s %-8s %s\n' "TESTBENCH" "RESULT" "NOTE"
printf '%s\n' "-------------------------------------------------------------"

# -P1 => serial, in TBS order, streaming live (identical to today).
# -PN => parallel; rows written to files, printed in deterministic TBS order below.
printf '%s\n' "${TBS[@]}" | xargs -P "$JOBS" -I{} bash -c 'run_one_tb "$@"' _ {}

[ "$JOBS" != 1 ] && for tb in "${TBS[@]}"; do cat "$RESULTS/${tb%.sv}.row" 2>/dev/null; done
printf '%s\n' "-------------------------------------------------------------"
passed=0; gate_fail=0; nongate_fail=0; skipped=0; deferred=0
nongate_fail_names=""; defer_names=""
for tb in "${TBS[@]}"; do
  top="${tb%.sv}"; [ -f "$RESULTS/$top.result" ] || continue
  IFS=, read -r _t g v _s <"$RESULTS/$top.result"
  case "$v" in
    PASS)  passed=$((passed+1)) ;;
    skip)  skipped=$((skipped+1)) ;;
    defer) deferred=$((deferred+1)); defer_names="$defer_names $top" ;;
    *) if [ "$g" = 1 ]; then gate_fail=$((gate_fail+1));
       else nongate_fail=$((nongate_fail+1)); nongate_fail_names="$nongate_fail_names ${top}:${v}"; fi ;;
  esac
done
# [#96] Loud, un-missable banner so a NON-GATING failure or a DEFERRED (nightly-only)
# TB can never slip past silently — the whole point of the issue: stop "known-slow"
# drifting into "known-broken". Non-gating failures do NOT flip the exit code (that is
# their contract) but they MUST be seen; deferrals are surfaced so PR reviewers know a
# TB did not actually run here.
if [ "$nongate_fail" -gt 0 ]; then
  echo   "!!!==========================================================================!!!"
  printf '!!! WARNING: %d NON-GATING TB failure(s) — NOT gating the suite, but BROKEN:\n' "$nongate_fail"
  ohw_ifs=$IFS; IFS=' '
  for n in $nongate_fail_names; do [ -n "$n" ] && printf '!!!   - %s (verdict=%s)\n' "${n%:*}" "${n##*:}"; done
  IFS=$ohw_ifs
  echo   "!!! A non-gating TB that FAILS is drifting toward known-broken. Fix or re-gate."
  echo   "!!!==========================================================================!!!"
fi
if [ "$deferred" -gt 0 ]; then
  printf '### NOTE: %d TB(s) DEFERRED (nightly-only, did NOT run in this tier):%s — run --tier=nightly to gate them.\n' \
         "$deferred" "$defer_names"
fi
printf 'passed=%d  gating-failures=%d  non-gating-failures=%d  skipped=%d' \
       "$passed" "$gate_fail" "$nongate_fail" "$skipped"
[ "$deferred" -gt 0 ] && printf '  deferred=%d' "$deferred"; echo
[ $gate_fail -eq 0 ] && { echo "RESULT: PASS"; exit 0; } || { echo "RESULT: FAIL"; exit 1; }
