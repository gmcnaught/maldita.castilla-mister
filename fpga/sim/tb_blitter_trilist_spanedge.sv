// tb_blitter_trilist_spanedge.sv — [Phase 3A Task 6] the SPAN-WALK EDGE-CASE
// vector, as its own run_sims.sh entry.
//
// A wrapper like tb_blitter_trilist_synthquad.sv: selects a vector set and a top
// module name, then `include's tb_blitter_trilist_stream.sv, so there is exactly
// ONE copy of the replay harness.
//
// ── WHY THIS EXISTS: it closes two MEASURED holes in the bit-exact gate ──────
// The span walk (see blitter_top.sv's span-walk block comment) was mutation-tested
// when it landed. Two deliberate off-by-ones in the LEFT endpoint were NOT caught
// by any of the then-existing ten trilist benches:
//
//   M1  sk_covm's `>= 0` -> `> 0`             (left-endpoint MINIMALITY test)
//   M2  the left CLAMP `tri_px == tri_ox` -> `== tri_ox + 1`
//
// Both need a LEFTWARD seek — the direction the captured frames and the synthetic
// quad barely exercise on their leftmost column. This vector's five triangles
// exercise exactly those two paths, and each mutation now FAILS here (see the
// evidence block at the bottom). Their bboxes are DELIBERATELY NON-OVERLAPPING, so
// no triangle can overpaint another's dropped pixel and re-hide the hole.
//
//   T1  (-320,160) (640,160) (640,1120)   bbox x  0..40  y 10.. 70   1580 px
//       Closes M2. Its min x is NEGATIVE, so blt_tri_setup clamps t_minx to 0
//       (blt_tri_setup.sv:323) and tri_ox becomes 0 while x = -1 is genuinely
//       COVERED. `!sk_covm` therefore never fires at x=0 and the `tri_px==tri_ox`
//       clamp is the ONLY thing stopping the leftward seek — exactly the guard M2
//       moves. Under M2 the seek walks past x=0, tri_px wraps to 16'hFFFF, and the
//       row is abandoned. 779 entries of the covered-pixel SET change; 760 of them
//       land as framebuffer diffs (measured exact_bad=760) -- the other 19 are the
//       wrapped out-of-bbox writes, whose dst_qw (pys*stride + (16'hFFFF>>2)) falls
//       outside the compared region instead of corrupting a compared pixel.
//       (This is the geometry the first mutation write-up got WRONG: it is
//       off-left CLAMPING, not the zero-valued-edge case below.)
//
//   T2a (1608,168) (968,808)  (2248,808)   bbox x 60..141 y 10.. 51   1640 px
//   T2b (3208,168) (2568,808) (3848,808)   bbox x160..241 y 10.. 51   1640 px
//   T2c (1608,1768)(968,2408) (2248,2408)  bbox x 60..141 y110..151   1640 px
//       Close M1. Every vertex sits exactly ON a pixel centre ((px<<4)|8, e.g.
//       1608 = (100<<4)|8) and the left edge has slope dx/dy = -1, so the span
//       start descends one column per row (a LEFT-mode seek on every row) and the
//       apex row's span start lies exactly on a bias-0 edge, i.e. a biased edge
//       function of exactly 0 -- the `>=`/`>` boundary sk_covm tests. 1 px each.
//
//   T3  (3208,1768)(2888,2088)(2568,2088)  bbox x160..201 y110..131    210 px
//       A 20px-wide sliver on the same principle; contributes 2 more M1 pixels.
//
// WHY THE M1 MARGIN IS ONLY 5 PIXELS, AND WHY THAT IS INHERENT rather than a weak
// test: for M1 to bite, a covered pixel at a span start must have a biased edge
// function of EXACTLY 0. A y-down CCW triangle always traverses its LEFT edge
// UPWARD, so top_left() gives that edge bias -1 and `w == 0` there needs
// `edge() == 1`; with vertices on pixel centres every edge() term is a product of
// multiples of 16, so edge() is a multiple of 16 and can never be 1. Only a
// bias-0 edge (the RIGHT edge, or a horizontal TOP edge) can put a zero at a span
// start, and that happens only at isolated apex/vertex rows -- one or two pixels
// per triangle, not a band. More triangles is the only way to widen the margin,
// which is why there are four of them. The gate is STRICT bit-exactness
// (exact_bad != 0 fails), so one pixel is already decisive; five is margin.
//
// ── EXPECTED BUCKET COUNTS: provenance, per line ─────────────────────────────
// Unlike tb_blitter_trilist_synthquad, whose four numbers are derivable from the
// geometry in closed form, THESE ARE MODEL-DERIVED and then RTL-cross-checked --
// T1 is screen-clipped and T3 is a sliver, so their per-row spans have no clean
// closed form (the top-left fill rule decides individual boundary pixels). They
// are asserted anyway, as a regression lock on the walk's behaviour over clipped
// and degenerate-thin geometry, but they are NOT independent hand arithmetic and
// must not be read as such. What IS hand-checkable, and was checked:
//   * STREAM_EXP_WR == 3 * STREAM_EXP_COVERED exactly (the 3-stage blend/write).
//   * A_ROWY == the sum of the five bbox row counts: 61+42+42+42+22 == 209, and
//     rowsetup - 209 == 573 == the A_SEEK total.
//   * order of magnitude on T2a: slopes of +-1 give a span ~2k+1 px wide k rows
//     below the apex, so ~sum_{k=0..39}(2k+1) == 1600 against the modelled 1640;
//     the 40 px difference is the base row plus fill-rule boundary pixels, i.e.
//     the part a closed form gets wrong. This anchors the number, it does not
//     derive it.
// The model (a Python transcription of blt_tri.c's setup driving a cycle-accurate
// copy of the pa FSM) predicted covered/pix_visits/rowsetup for the captured
// frames and the synthetic quad to the CYCLE before this vector existed, which is
// why it is trusted for the two shapes hand arithmetic cannot reach.
//
// Runtime ~2 s (114 k cycles, most of it the full-screen CLEAR), so this gates in
// every tier under run_sims.sh's default 120 s budget.
//
// ── MUTATION EVIDENCE (re-verified against THIS bench) ───────────────────────
//   unmutated              : RESULT: PASS, exact_bad=0
//   M1 (sk_covm >= -> >)   : RESULT: FAIL (exact_bad=5 of 62208)
//   M2 (clamp == tri_ox+1) : RESULT: FAIL (exact_bad=760 of 62208)
// Both mutations reverted after testing.
`define STREAM_VEC          "stream_span_edge"
`define STREAM_TB_NAME      tb_blitter_trilist_spanedge
`define STREAM_EXP_VISITS   6909    // model-derived: 6710 covered + 199 span-end tests
`define STREAM_EXP_COVERED  6710    // model-derived: 1580 + 1640*3 + 210
`define STREAM_EXP_ROWSETUP 782     // model-derived: 573 A_SEEK + 209 A_ROWY (209 = 61+42+42+42+22, hand-checked)
`define STREAM_EXP_WR       20130   // 3 * 6710 (hand-checked relation)
`include "tb_blitter_trilist_stream.sv"
