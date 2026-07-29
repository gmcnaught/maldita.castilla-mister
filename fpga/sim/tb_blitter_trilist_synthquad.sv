// tb_blitter_trilist_synthquad.sv — [Phase 3A Task 5] the CYCLE-BUCKET calibration
// case, as its own run_sims.sh entry.
//
// A three-line wrapper: it selects the synthetic single-quad vector set and a
// distinct top-module name, then `include's tb_blitter_trilist_stream.sv, so there
// is exactly ONE copy of the replay harness (see that file for the DUT wiring, the
// bucket definitions and the CYC contract).
//
// WHY THIS EXISTS AS A SEPARATE GATING TB: every other stream-replay run is a real
// captured frame, whose expected cycle counts are only knowable by running the
// bench — so the buckets could drift and still look plausible. This case is the
// only one whose numbers are hand-computable from the geometry, and it is
// therefore the calibration anchor for the buckets themselves:
//
//   vectors/mftrace-synth-quad.txt is one hand-written MFTRACE group: two right
//   triangles sharing an edge, forming a 120x120 px axis-aligned quad at
//   (60,60)-(180,180) (12.4 fixed: 960..2880), an 8x8 stride-16 texture, BLEND_COPY.
//
//   pix_covered  == 120*120                    == 14400   (the quad's area)
//   pix_visits   == 2 * (121*121)              == 29282   (each triangle's clamped
//                                                          bbox, walked in full)
//   pix_visits/pix_covered == 2.033            -- THE BBOX-TAX SIGNATURE: a
//                  right-triangle pair pays ~2x its covered area in coverage tests.
//   wr           == 3 * 14400                  == 43200   (the 3-stage blend/write
//                                                          on every covered pixel)
//
// Those three numbers are ASSERTED, not just documented: STREAM_EXP_* below feed a
// gated check in the harness, so if a future change to the bucket conditions (or to
// blitter_top's pa/pb encodings) makes them move, this bench fails and the arithmetic
// above says which one is wrong. The captured-frame benches cannot tell you that --
// their expected counts are only knowable by running them.
//
// Runtime ~5 s (181 k cycles), so this gates in every tier.
`define STREAM_VEC          "stream_synth_quad"
`define STREAM_TB_NAME      tb_blitter_trilist_synthquad
`define STREAM_EXP_VISITS   29282   // 2 * 121*121  (per-triangle clamped bbox)
`define STREAM_EXP_COVERED  14400   // 120*120      (the quad's area)
`define STREAM_EXP_WR       43200   // 3 * 14400    (3-stage blend/write per covered px)
`include "tb_blitter_trilist_stream.sv"
