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
// therefore the calibration anchor for the buckets themselves.
//
// GEOMETRY. vectors/mftrace-synth-quad.txt is one hand-written MFTRACE group: two
// right triangles sharing the (60,60)-(180,180) diagonal, forming a 120x120 px
// axis-aligned quad at (60,60)-(180,180) (12.4 fixed: 960..2880), an 8x8 stride-16
// texture, BLEND_COPY. Both triangles clamp to the same bbox, ox=oy=60,
// maxx=maxy=180 (= (2880+15)>>4), so each has 121 bbox rows.
//
//   tri A = (60,60),(180,60),(180,180)  — the upper-right half. Covered rows are
//           y=60..178, span [y+1, 179], i.e. 179-y px:  sum_{k=1..119} k = 7140.
//   tri B = (60,60),(180,180),(60,180)  — the lower-left half. Covered rows are
//           y=60..179, span [60, y], i.e. y-59 px:       sum_{k=1..120} k = 7260.
//
//   pix_covered == 7140 + 7260 == 14400 == 120*120, the quad's area. (Neither the
//                  shared diagonal nor the shared edge is double-written: the
//                  top-left fill rule assigns each boundary pixel to exactly one
//                  triangle, which is why the two halves sum to the quad exactly.)
//
// ── [span walk] pix_visits / rowsetup, recomputed by hand ────────────────────
// Before the span walk, pa tested every bbox column, so pix_visits was the two
// clamped bboxes in full: 2 * 121*121 == 29282 == 2.033x covered — the bbox-tax
// signature. The span walk deletes exactly that: A_PIX is entered only AT a covered
// pixel or one column past the previous one, and each row's entry point is LOCATED
// by A_SEEK instead of scanned to.
//
//   pix_visits == covered + one SPAN-END test per row whose span stops short of
//                 tri_maxx. Every span here stops short (tri A ends at x=179, tri B
//                 at x=y<=179, both < maxx=180), so it is one per NON-EMPTY row:
//                 14400 + (119 + 120) == 14639.
//                 (A span that ran to tri_maxx would cost none: A_ISSUE hands
//                 straight to A_ROWY via row_pend.)
//
//   rowsetup   == A_SEEK + A_ROWY cycles.
//                 A_ROWY: once per bbox row, both triangles: 121 + 121 == 242.
//                 A_SEEK, tri A (span start s(y) = y+1, so it advances by one column
//                   per row): row 60 costs 2 (uncovered at ox=60 -> step right;
//                   covered at 61 -> found); rows 61..178 cost 2 each, entering at
//                   the previous row's start y and stepping to y+1: 2*119 == 238;
//                   row 179 costs 2 (uncovered at 179 -> step right to 180 == maxx
//                   -> still uncovered -> empty row); row 180 costs 1 (already at
//                   maxx, uncovered -> empty).  238 + 2 + 1 == 241.
//                 A_SEEK, tri B (s(y) == 60 == ox on every row, so the seek never
//                   moves): 1 cycle per row, 121 rows == 121.
//                 rowsetup == 242 + 241 + 121 == 604, i.e. 2.50 cyc/row over 242
//                 rows — against the ~121 columns per row the bbox scan paid.
//
//   wr         == 3 * 14400 == 43200 (the 3-stage blend/write per covered pixel;
//                 unchanged by the span walk, which changes visit ORDER only).
//
// Those four numbers are ASSERTED, not just documented: STREAM_EXP_* below feed a
// gated check in the harness, so if a future change to the bucket conditions (or to
// blitter_top's pa/pb encodings, or to the walk itself) makes them move, this bench
// fails and the arithmetic above says which one is wrong. The captured-frame benches
// cannot tell you that — their expected counts are only knowable by running them.
//
// Runtime ~5 s (167 k cycles), so this gates in every tier.
`define STREAM_VEC          "stream_synth_quad"
`define STREAM_TB_NAME      tb_blitter_trilist_synthquad
`define STREAM_EXP_VISITS   14639   // 14400 covered + 239 span-end tests (one per non-empty row)
`define STREAM_EXP_COVERED  14400   // 120*120        (the quad's area; 7140 + 7260)
`define STREAM_EXP_ROWSETUP 604     // 242 A_ROWY + (241 + 121) A_SEEK
`define STREAM_EXP_WR       43200   // 3 * 14400      (3-stage blend/write per covered px)
`include "tb_blitter_trilist_stream.sv"
