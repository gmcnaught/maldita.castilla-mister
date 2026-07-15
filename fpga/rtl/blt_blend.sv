//  blt_blend.sv — RGB565 blend core for BLT_OP_TRILIST (Task 5).
//
//  BYTE-IDENTICAL extraction of blt_tri.sv's blend half (lines 121-148): given a
//  fetched texel, the destination pixel, and the setup-interpolated per-vertex
//  colour (cr,cg,cb,ca), it produces the final RGB565 and a write-enable. The
//  interpolation/coverage half of blt_tri.sv is NOT here — the Task-5 walk (in
//  blitter_top) computes coverage + attributes incrementally from blt_tri_setup
//  and feeds this module the tinted colour + the reads it performed.
//
//  Kept bit-for-bit with blt_tri.sv (and thus the host golden blt_tri.c) so
//  out_pix matches within +-1 LSB: same divide-free /255,/31,/63 reductions,
//  same tint (modch), same (ca*alpha)/255 truncation, same saturating add,
//  same colorkey cull.
//
//  Copyright (C) 2026 — GPL-3.0.
`default_nettype none
module blt_blend (
    input  wire        [15:0] texel, dst,
    input  wire        [7:0]  cr, cg, cb, ca,   // setup-interpolated per-vertex colour
    input  wire        [7:0]  g_alpha,
    input  wire        [7:0]  blend_mode,
    input  wire        [15:0] colorkey,
    output reg                write_en,
    output reg         [15:0] out_pix
);
    localparam [7:0] BM_COPY=8'd0, BM_KEY=8'd1, BM_CALPHA=8'd2, BM_ADD=8'd4, BM_MUL=8'd5;

    // divide-free reductions (identical to the refmodel's div255/div31/div63_round)
    function automatic [5:0] red255(input [16:0] t); reg [17:0] m; begin m={1'b0,t}+18'd128; red255=(m+(m>>8))>>8; end endfunction
    function automatic [4:0] red31 (input [11:0] t); reg [12:0] m; begin m={1'b0,t}+13'd16;  red31 =(m+(m>>5))>>5; end endfunction
    function automatic [5:0] red63 (input [12:0] t); reg [13:0] m; begin m={1'b0,t}+14'd32;  red63 =(m+(m>>6))>>6; end endfunction
    // per-channel colour-mod: div255_round(ch*mod)
    function automatic [5:0] modch(input [5:0] ch, input [7:0] mod); modch = red255(ch*mod); endfunction

    reg [5:0] sr,sg,sb, tsr,tsg,tsb, dr,dg,db, o_or,o_og,o_ob;
    reg [6:0] ar,ag,ab;
    reg [7:0] ea,na;

    always @* begin
        sr = texel[15:11]; sg = texel[10:5]; sb = texel[4:0];
        tsr = modch({1'b0,sr}, cr);      // tinted source channels
        tsg = modch(sg, cg);
        tsb = modch({1'b0,sb}, cb);
        dr = dst[15:11]; dg = dst[10:5]; db = dst[4:0];
        // widen operands so the product isn't truncated to the 8-bit LHS context
        ea = ({8'd0,ca} * {8'd0,g_alpha}) / 16'd255;   // truncating, matches C (ca*alpha)/255
        na = 8'd255 - ea;
        o_or = tsr; o_og = tsg; o_ob = tsb;   // default: COPY/COLORKEY write tinted src
        case (blend_mode)
          BM_CALPHA: begin
            o_or = red255(tsr*ea + dr*na);
            o_og = red255(tsg*ea + dg*na);
            o_ob = red255(tsb*ea + db*na);
          end
          BM_ADD: begin
            ar = tsr + dr; ag = tsg + dg; ab = tsb + db;
            if (ar > 31) ar = 31; if (ag > 63) ag = 63; if (ab > 31) ab = 31;
            o_or = ar[5:0]; o_og = ag[5:0]; o_ob = ab[5:0];
          end
          BM_MUL: begin
            o_or = red31(tsr*dr); o_og = red63(tsg*dg); o_ob = red31(tsb*db);
          end
          default: ;
        endcase
        out_pix  = { o_or[4:0], o_og[5:0], o_ob[4:0] };
        write_en = !((blend_mode==BM_KEY) && (texel==colorkey));
    end
endmodule
`default_nettype wire
