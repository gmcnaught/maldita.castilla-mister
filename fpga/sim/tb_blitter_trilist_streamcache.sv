// tb_blitter_trilist_streamcache.sv — [Phase 3B Task 1] the captured-frame replay
// with the REAL texel path: sdram_fb_cache ch5 + the mt48 SDRAM chip model instead
// of the fixed-3-cycle P_SRC stub.
//
// A three-line wrapper, same shape as tb_blitter_trilist_synthquad.sv: it defines
// STREAM_REALCACHE and a distinct top-module name, then `include's the ONE copy of
// the replay harness (tb_blitter_trilist_stream.sv — read its header for the DUT
// wiring, the real-cache block, the bucket definitions and the CYC contract).
//
// WHY IT EXISTS. The stub sibling's `texwait` is a FLOOR, not a prediction: P_SRC
// there returns in a fixed 3 cycles, while the device serves texels through this
// cache + chip pair where a demand miss costs an order of magnitude more. Stage A
// measured device texwait at 3.42 ms (quiet) against a 0.725 ms stub floor — 4.7x —
// and then the A-chain pipeline collapsed the SIM texwait by 98%, which is a
// direction with an unquantified magnitude until it is re-measured on a real texel
// port. This bench is that measurement. See
// docs/superpowers/findings/2026-07-30-phase3-stage-a-sizing.md §6 (band #2) and
// §8.3, and .superpowers/sdd/stageB-task-1-report.md for the numbers it produced.
//
// WHAT IT GATES. Everything the stub sibling gates, unchanged and deliberately so:
// strict bit-exactness (exact_bad == 0), the five TB-vs-RTL cross-checks
// (perf_frame_cyc / perf_tri_cyc / perf_texwait_cyc / perf_covered_px, plus
// ax_push == pix_covered), and the bucket partition summing to total. The
// bit-exact gate is the load-bearing one HERE: same DDR image, same texels, only
// slower — so a single changed pixel means the SDRAM image or its address mapping
// is wrong and every cycle number in the run is worthless. It is not a
// "known-slow" allowance; it is the precondition.
//
// WHY IT IS NONGATING + NIGHTLY_ONLY. Co-simulating the bit-level mt48 model puts
// it in tb_blitter_trilist_sdram's runtime class (~10x the stub replay's ~30 s,
// and highly contention-sensitive), which is too slow for the PR tier. It is not
// silenced: run_sims.sh's NON-GATING banner surfaces a failure in nightly.
//
// STREAM_VEC selects the frame; the default (stream_quiet_f0) is the committed
// vector set. The arrival capture is gitignored — regenerate per the recipe in
// .superpowers/sdd/stageA-task-6-report.md §"Reproducibility caveat" and run:
//   iverilog -g2012 -DSTREAM_VEC='"stream_arrival_f3"' -o /tmp/sc.vvp \
//     -I ../rtl -I ../rtl/jtframe -I ../sys -I . -y ../rtl -y ../rtl/jtframe \
//     -y ../sys -y . -Y .sv -Y .v *_stub.sv tb_blitter_trilist_streamcache.sv \
//     && vvp /tmp/sc.vvp
//
// stream_heavy_f0 [Phase 4 Stage B] is ALSO a committed tag (see
// tb_blitter_trilist_stream.sv's header for its full provenance: mftrace-heavy-b.txt
// frame index 0 == device f=1890, the first frame of the measured f=1890..1960
// cov_px=213358 plateau, the Phase 4 Stage B gate anchor). Device fabric frame
// for this scene was 18.02 ms pre-W2 and is 16.68 ms post-W2 ("W2" = an
// engine-side deferred-clear elision, not an RTL or triangle-stream change) --
// calibrate against the post-W2 16.68 ms figure. No re-capture was needed for
// W2: MFTRACE never records fills/clears, and a device A/B proved `tri`,
// `dpath`, `texwait` and `cov_px` bit-identical pre- vs post-W2, so the same
// committed .hex pair backs both figures. It can be run through the real
// sdram_fb_cache + mt48 texel path this bench co-simulates the same way:
//   STREAM_VEC=stream_heavy_f0 ./run_sims.sh --tier=nightly tb_blitter_trilist_streamcache
// (this bench is NIGHTLY_ONLY, so --tier=nightly is required). Same HONESTY NOTE
// as the sibling header: the vector's one synthesized full-screen clear is not a
// like-for-like model of the device's ~3 real clears per frame (that gap is
// also why the sim's `nontri` bucket, 0.786 ms, sits below the device's
// post-W2 `ovhd` of 0.97 ms -- a 0.184 ms difference explained by clear count,
// not RTL).
`define STREAM_REALCACHE
`define STREAM_TB_NAME tb_blitter_trilist_streamcache
`include "tb_blitter_trilist_stream.sv"
