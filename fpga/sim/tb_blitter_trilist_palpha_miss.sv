// tb_blitter_trilist_palpha_miss.sv — [TRILIST PALPHA] the miss + dst path under PALPHA.
//
// A wrapper: selects the tri_palpha_miss vector set (tri_missdst's 128x128 stride-256
// cache-thrash geometry, ARGB4444 with all 16 A4 levels, over a patterned bg) and
// includes tb_blitter_trilist_palpha.sv, so there is ONE copy of the harness.
// PALPHA sets tri_need_dst, so every texel miss here also exercises the A2
// B_WAIT -> B_LOOK dst re-issue; the coverage gate asserts that it happened.
`define PALPHA_VEC        "tri_palpha_miss"
`define PALPHA_TB_NAME    tb_blitter_trilist_palpha_miss
`define PALPHA_EXPECT_MISS
`include "tb_blitter_trilist_palpha.sv"
