//  blt_tri_setup.sv — TRIANGLE SETUP datapath for BLT_OP_TRILIST (Task 4).
//
//  Computes, ONCE per triangle, everything the per-pixel walk (Task 5) needs so
//  the walk performs only adds + one fixed-point multiply per attribute — NO
//  per-pixel divide. Bit-compatible (±1 LSB) with the golden blt_tri.sv /
//  blt_tri.c, verified by tb_tri_setup.sv.
//
//  Math. Each edge function w_k(x,y) (top-left biased, CCW-normalized exactly as
//  blt_tri.sv:76-100) is LINEAR in the sample coords, so the barycentric-weighted
//  attribute sum W_A(x,y) = w0*A0 + w1*A1 + w2*A2 is linear too:
//      W_A(px,py) = W_A(ox,oy) + (px-ox)*dW_A/dx + (py-oy)*dW_A/dy
//  with dW_A/dx, dW_A/dy CONSTANT per triangle. The final attribute is
//      A = divr(W_A, area)  ==  round(W_A * area_recip / 2^SHIFT).
//  Sample step of 1 pixel == +16 in 12.4, so d/dx of an edge = 16*(coord diff).
//
//  Datapath A (robust, per the brief): the walk accumulates the INTEGER weighted
//  sums W_* and the coverage edges w_k by adds, then multiplies each W_* by
//  area_recip once. area_recip = round(2^SHIFT / area) with SHIFT=40; the
//  reciprocal-quantization error at any pixel is <= |W_*|*0.5/2^SHIFT, which for
//  attribute magnitudes (|W_*/area| <= 255) is ~1e-4 — far inside ±1 LSB.
//
//  ── PIPELINED setup (timing closure) ───────────────────────────────────────
//  Registered on `clk`: pulse `start` with the vertices. The setup math is now
//  split into REGISTERED PIPELINE STAGES so no single clock cycle chains more
//  than one multiplier NOR a multiply into a wide (60-bit) add/normalize. (An
//  earlier build still had the whole edgef area — two products chained into a
//  subtract, abs and CCW-normalize, all combinational from the raw input
//  vertices into the 60-bit s1_den — as ONE cycle, and it was the last path to
//  miss Quartus setup timing at ~98 MHz on the fabric clock.) The stages are:
//    S1, split into five sub-stages so the area/den/num path fits one cycle:
//        P1 (on start): edgef vertex DIFFERENCES (x1-x0,y2-y0,y1-y0,x2-x0) +
//            origin (ox,oy,sx0,sy0 — bbox-min is swap-invariant, so from the raw
//            verts); carry raw verts/attrs forward.            [no multiply]
//        P2: the two edgef PRODUCTS.                           [multiplier depth 1]
//        P3: the SUBTRACT -> signed area.                      [add only]
//        P4: CCW-normalize (|area|, degenerate, den) + swap-select the verts/
//            attrs into the s1_* registers; emit area/ox/oy/degenerate.
//        P5: reciprocal-numerator prep num = 2^SHIFT + den/2.  [add only]
//    S2: the three edge functions w{k}_0 at the origin sample (+top-left bias),
//        and the small per-x/per-row edge deltas dw{k}dx=16*(yi-yj),
//        dw{k}dy=16*(xj-xi); KICK the sequential area reciprocal. [mult depth 1]
//    S3 (MAC): the 54 partial products w{k}_0*A{k}, dw{k}dx*A{k}, dw{k}dy*A{k}
//        (k over the 3 verts, A over u,v,r,g,b,a) summed per attribute into
//        W{}_0, dW{}dx, dW{}dy. This used to be 54 PARALLEL multiplies in one
//        cycle (S3) + a per-attribute adder tree (S4) — ~54 DSP blocks for a
//        per-triangle (~10/frame) computation, the design's dominant DSP
//        consumer. It is now a SEQUENTIAL multiply-accumulate: 3 multipliers
//        (the nw/dwdx/dwdy lanes, all sharing the same A[a][k] operand each
//        step) walk the 18 (attr,vert) pairs over 18 steps, with multiply and
//        accumulate in separate pipeline cycles (no mult->add chain). Frees
//        ~50 DSP blocks. [3 DSPs, ~19 cycles, concurrent with the divider]
//  The area reciprocal is a synthesizable radix-2 restoring divider (UNROLL
//  bits/cycle, ITERS busy cycles) kicked at S2 and running CONCURRENTLY with
//  the S3 MAC; `valid` rises when it finishes (it is the long pole — 48 cycles
//  vs. the MAC's ~19). Latency: non-degenerate ~54 cycles (5 S1 sub-stages
//  P1..P5 + S2 kick + ITERS=48 divider cycles), degenerate ~24 cycles (skips
//  the divider, asserts valid when the MAC drains). Both are well inside the
//  downstream valid-wait (tb caps at 80). The extra pipe depth is free — setup
//  runs once per triangle. The arithmetic is UNCHANGED (same three integer
//  terms summed in the same k=0,1,2 order) — only the multiply was serialized —
//  so every output stays bit-exact-or-±1 vs. the golden (tb_tri_setup).
//  The OUTPUT interface below is what Task 5 consumes and is unchanged.
//
//  Validated operating envelope (tb_tri_setup.sv "envelope_worst_case", passes
//  at +-1 LSB vs. blt_tri.sv with SHIFT=40 and the 48-bit field widths below):
//    - vertex coords: 16-bit signed 12.4 (as declared), i.e. |coord| up to
//      ~2047.9 px; case 4 exercises a ~300x220px triangle near that range.
//    - signed area (x2, post CCW-normalize): validated up to ~1.7e7 (case 4);
//      area is carried in a 48-bit field, which holds area up to ~1.4e14 —
//      vastly beyond what 16-bit-signed 12.4 vertices can produce (max |area|
//      for two ~17-bit coord diffs is on the order of 2^35), so area itself
//      never approaches its field's ceiling.
//    - texture size: up to 2048x2048 texels, u/v up to ~32752 in 12.4 (case 4).
//    - reciprocal error at this envelope: |area_recip quantization| ~0.15 LSB
//      of the final attribute (comment above's ~1e-4 bound scales with area;
//      still far inside +-1 at area~1.7e7).
//    - w{0,1,2}_0 / dw{0,1,2}dx/dy are 48-bit: a single edgef() term multiplies
//      two ~17-bit-signed 12.4 coord differences (~34 bits), and the a-b
//      difference of two such terms is ~35 bits, so 48 bits leaves ~13 bits
//      of headroom over the worst case producible by in-range vertices.
//  Exceeding this envelope (e.g. much larger textures/coords, or SHIFT
//  lowered) would need re-validating against blt_tri.sv before trusting it.
//
//  Copyright (C) 2026 — GPL-3.0.
`default_nettype none
module blt_tri_setup #(
    parameter integer SHIFT = 40           // area_recip fixed-point: recip ~ 2^SHIFT/area
) (
    input  wire                clk,
    input  wire                rst,
    input  wire                start,       // pulse to latch verts + compute
    // raw triangle vertices (screen 12.4 signed), three verts a,b,c
    input  wire signed [15:0]  vx0, vy0, vx1, vy1, vx2, vy2,
    input  wire        [15:0]  vu0, vv0, vu1, vv1, vu2, vv2,   // texel 12.4 unsigned
    input  wire        [7:0]   vr0, vg0, vb0, va0,
    input  wire        [7:0]   vr1, vg1, vb1, va1,
    input  wire        [7:0]   vr2, vg2, vb2, va2,
    input  wire        [15:0]  tex_w, tex_h,                  // texture size (texels)

    // ── registered outputs (Task-5 walk interface) ────────────────────────────
    output reg                 valid,       // outputs stable this cycle
    output reg                 degenerate,  // area==0 (walk must skip the triangle)
    output reg         [15:0]  ox, oy,       // bbox-min pixel = interpolation origin
    output reg signed  [47:0]  area,         // CCW-normalized signed area x2 (>0)
    output reg         [47:0]  area_recip,   // round(2^SHIFT / area), unsigned Q(SHIFT)
    // coverage edge functions at origin + per-x / per-row integer deltas.
    // 48-bit (not 32): edgef() multiplies two ~17-bit-signed 12.4 coord
    // differences (vertex vs. origin sample), so a single term is ~34 bits and
    // the a-b difference of two such terms is ~35 bits — already past a 32-bit
    // signed field for in-range vertices. 48 bits matches area/area_recip/W*_0
    // below and leaves ample headroom (see the envelope note near SHIFT).
    output reg signed  [47:0]  w0_0, w1_0, w2_0,
    output reg signed  [47:0]  dw0dx, dw1dx, dw2dx,
    output reg signed  [47:0]  dw0dy, dw1dy, dw2dy,
    // weighted attribute SUMS at origin (W_A = w0*A0+w1*A1+w2*A2), integer
    output reg signed  [47:0]  Wu_0, Wv_0, Wr_0, Wg_0, Wb_0, Wa_0,
    // per-x / per-row deltas of the weighted sums, integer
    output reg signed  [47:0]  dWudx, dWvdx, dWrdx, dWgdx, dWbdx, dWadx,
    output reg signed  [47:0]  dWudy, dWvdy, dWrdy, dWgdy, dWbdy, dWady
);
    // signed area x2 of triangle (a,b,c) — same integer edge function as the golden.
    // [timing/DSP] the coord differences are ~17-bit (12.4 screen coords, |diff| <=
    // ~5120), so narrow them to 19-bit signed BEFORE multiplying: this makes each
    // product a single 19x19 DSP instead of a 64x64 longint multiply (~4-6 DSPs).
    // Value is unchanged for in-envelope coords (guarded by tb_tri_setup).
    function automatic longint edgef(input longint ax, ay, bx, by, cx, cy);
        reg signed [18:0] dbx, dcy, dby, dcx;
        begin
            dbx = bx - ax; dcy = cy - ay;
            dby = by - ay; dcx = cx - ax;
            edgef = dbx*dcy - dby*dcx;
        end
    endfunction
    // top-left rule bias: 0 on a top/left edge a->b, else -1 (mirrors blt_tri.sv)
    function automatic longint tlbias(input longint ax, ay, bx, by);
        tlbias = (((ay==by) && (bx<ax)) || (by>ay)) ? 64'sd0 : -64'sd1;
    endfunction

    // ── pipeline stage-valid pulses ───────────────────────────────────────────
    // The former one-cycle S1 (edgef = two products chained into a 60-bit
    // subtract/abs/normalize, straight from the raw input vertices) failed
    // Quartus setup timing on the fabric clock. It is now split across FIVE
    // registered sub-stages P1..P5 so no cycle chains a multiply into a wide
    // add/normalize, then feeds the SAME s1_* registers the old S1 produced:
    //   P1 (on start): vertex DIFFERENCES for edgef (x1-x0, y2-y0, y1-y0,
    //       x2-x0) + origin (bbox-min is swap-invariant, so computed from raw
    //       verts here); carry raw verts/attrs forward.            [no multiply]
    //   P2: the two edgef PRODUCTS (dbx*dcy, dby*dcx).             [mult depth 1]
    //   P3: the SUBTRACT -> signed area (n_area).                  [add only]
    //   P4: CCW-normalize: swap-select verts/attrs on n_area<0, |area|, degen,
    //       den; register the swapped s1_* verts/attrs + area/ox/oy outputs.
    //   P5: reciprocal-numerator prep num = 2^SHIFT + den/2.       [add only]
    // g1..g4 are the P1..P4 completion pulses; e1 marks P5 done (== old "S1
    // done"), after which S2/S3/S4 below are UNCHANGED.
    reg e1, e1b, e1c;       // S2 edge-function sub-stages (diffs / products / combine)
    reg g1, g2, g3, g4;

    // ── P1 registers: edgef vertex differences + origin; raw verts/attrs carry ─
    reg signed [63:0] p1_dbx, p1_dcy, p1_dby, p1_dcx;          // edgef diffs
    reg signed [63:0] p1_vx0,p1_vy0, p1_vx1,p1_vy1, p1_vx2,p1_vy2;
    reg signed [63:0] p1_attr [0:5][0:2];                      // raw {u,v,r,g,b,a}x{v0,v1,v2}
    reg        [15:0] p1_ox, p1_oy;
    reg signed [63:0] p1_sx0, p1_sy0;

    // ── P2 registers: the two edgef products; raw verts/attrs + origin carry ───
    reg signed [63:0] p2_prod1, p2_prod2;
    reg signed [63:0] p2_vx0,p2_vy0, p2_vx1,p2_vy1, p2_vx2,p2_vy2;
    reg signed [63:0] p2_attr [0:5][0:2];
    reg        [15:0] p2_ox, p2_oy;
    reg signed [63:0] p2_sx0, p2_sy0;

    // ── P3 registers: signed area (subtract); raw verts/attrs + origin carry ───
    reg signed [63:0] p3_narea;
    reg signed [63:0] p3_vx0,p3_vy0, p3_vx1,p3_vy1, p3_vx2,p3_vy2;
    reg signed [63:0] p3_attr [0:5][0:2];
    reg        [15:0] p3_ox, p3_oy;
    reg signed [63:0] p3_sx0, p3_sy0;

    // ── Stage-1 registers (CCW-normalized verts/attrs + origin + recip inputs) ─
    // attrs held as signed 64-bit (values are small & non-negative) so the later
    // products are unambiguously SIGNED (a signed*unsigned mix would flip context).
    reg signed [63:0] s1_x0,s1_y0, s1_x1,s1_y1, s1_x2,s1_y2;   // swapped coords
    reg signed [63:0] s1_sx0, s1_sy0;                           // origin sample (12.4)
    reg signed [63:0] s1_den, s1_num;                           // divider divisor / dividend
    reg               s1_degen;
    reg signed [63:0] s1_A [0:5][0:2];   // [attr u,v,r,g,b,a][vert 0,1,2], swapped

    // ── Stage-2 registers (edge functions + deltas, carried attrs) ─────────────
    reg signed [63:0] s2_nw    [0:2];    // edge-function value at origin (incl. bias)
    reg signed [63:0] s2_ndwdx [0:2];    // 16*(y diff)
    reg signed [63:0] s2_ndwdy [0:2];    // 16*(x diff)
    reg signed [63:0] s2_A [0:5][0:2];

    // ── Stage-3 as a SEQUENTIAL multiply-accumulate (DSP time-multiplex) ────────
    //  The former Stage-3 fired all 54 partial products (6 attrs x 3 verts x 3
    //  lanes p0/pdx/pdy) in ONE cycle -> ~54 DSP blocks for a per-triangle
    //  (~10/frame) computation, the dominant consumer that starved the rest of
    //  the design of DSPs (the fitter then spilled the per-pixel itv*stride
    //  multiply into LUT soft-multipliers, blowing the mul_v->tri_p0_addr walk
    //  path). It is now a 3-multiplier MAC engine (nw / dwdx / dwdy lanes, all
    //  sharing the SAME A[a][k] operand each step) that walks the 18 (attr,vert)
    //  pairs over 18 steps. The engine is a THREE-STAGE pipeline so that no cycle
    //  chains the operand array-mux INTO the multiply and no cycle chains the
    //  multiply INTO the accumulate:
    //    SEL: use mac_idx (a=idx/3, k=idx%3) to mux the narrow operands out of
    //         s2_nw/s2_ndwdx/s2_ndwdy/s2_A into fixed sel_* registers. [mux only]
    //    MUL: the three products from the fixed sel_* registers -> pr*. [DSP only,
    //         no mux ahead of it — that mux-into-DSP chain was a -4.8 ns path.]
    //    ACC: add pr* into the running per-attribute accumulators. [add only]
    //  Kicked at the S2->divider point, running CONCURRENTLY with the 48-cycle
    //  reciprocal divider; it drains in ~20 cycles (< 48), so setup latency is
    //  unchanged and the divider stays the long pole. Same three integer terms
    //  summed in the same k=0,1,2 order as before -> BIT-IDENTICAL (tb_tri_setup).
    reg               mac_busy = 1'b0;   // engine running (power-up idle; rst may be tied 0)
    reg               s_vld    = 1'b0;   // SEL produced operands for the MUL stage
    reg               p_vld    = 1'b0;   // a product is in pr* to accumulate
    reg               mac_degen;         // area==0: outputs moot, but drive valid
    reg        [5:0]  mac_idx;           // SEL step counter 0..17 (termination only)
    reg        [2:0]  mac_a;             // attribute index 0..5 (direct — no /3)
    reg        [1:0]  mac_k;             // vert index 0..2     (direct — no %3)
    // SEL-stage registered operands (fixed location -> no mux ahead of the DSP)
    reg signed [26:0] sel_w0;            // s2_nw[k]    slice
    reg signed [23:0] sel_wx, sel_wy;    // s2_ndwdx[k] / s2_ndwdy[k] slices
    reg signed [17:0] sel_a;             // s2_A[a][k]  slice (shared operand)
    reg        [2:0]  s_a;               // attribute tag through SEL
    reg        [1:0]  s_k;               // vert tag through SEL
    reg signed [63:0] pr0, prx, pry;     // registered products (nw / dwdx / dwdy)
    reg        [2:0]  p_a;               // attribute of the product in pr*
    reg        [1:0]  p_k;               // vert (0,1,2) of the product in pr*
    reg signed [63:0] acc0, accx, accy;  // running per-attribute accumulators

    // combinational temporaries (blocking, per-stage)
    reg signed [63:0] t_area, t_den;
    reg               t_swap, t_degen;
    reg signed [63:0] t_minx, t_miny, t_sx0, t_sy0;
    reg        [15:0] t_ox, t_oy;
    reg signed [63:0] tb0,tb1,tb2;
    reg signed [63:0] tnw0,tnw1,tnw2, tdx0,tdx1,tdx2, tdy0,tdy1,tdy2;
    // ── S2 edge-function PIPELINE registers (edgef diff->mult->sub split) ───────
    //  edgef(a,b,c) = (bx-ax)(cy-ay) - (by-ay)(cx-ax). Done in one cycle it was a
    //  diff -> DSP multiply -> subtract chain (s1_x2 -> w1_0, the -4.3 ns worst
    //  setup path). Split into S2a (diffs) / S2b (products) / S2c (subtract+bias),
    //  mirroring the S1 P1..P5 split. Setup is divider-bound (~48 cyc), so the two
    //  extra cycles are free; arithmetic is identical -> bit-exact.
    reg signed [18:0] dbx0,dcy0,dby0,dcx0;   // edgef diffs, narrowed to 19b as edgef() does
    reg signed [18:0] dbx1,dcy1,dby1,dcx1;
    reg signed [18:0] dbx2,dcy2,dby2,dcx2;
    reg signed [63:0] sb0,sb1,sb2;           // registered top-left biases
    reg signed [63:0] sdx0,sdy0,sdx1,sdy1,sdx2,sdy2;  // registered per-x/per-row deltas
    reg signed [63:0] pr0a,pr0b,pr1a,pr1b,pr2a,pr2b;  // the two edgef products per edge
    integer a, k;
    // Stage-3 MAC blocking temporaries (accumulate stage: add only)
    reg signed [63:0] sum0, sumx, sumy;
    integer ma, mk;

    // ── SEQUENTIAL area reciprocal (radix-2 restoring divide, unrolled) ────────
    //  Computes q = floor(num/den) == round(2^SHIFT/area), identical to a single
    //  `num/den`, but iteratively: standard long division shifting the dividend
    //  MSB-first into a running remainder, UNROLL bits per clock. num < 2^41, so
    //  DIVW=48 dividend/quotient bits cover every quotient (leading bits are 0);
    //  den <= ~2^35 fits the 64-bit remainder path. Critical path per cycle is
    //  UNROLL chained subtract-compares (not a 41-deep divide). At UNROLL=1 that
    //  is a SINGLE shift + subtract-compare + conditional-restore per clock
    //  (~6 ns), which closes the 10.158 ns fabric clock with margin — a prior
    //  UNROLL=4 build chained four subtract-compares (~25 ns) and missed setup by
    //  ~15.3 ns on div_R. Spreading the SAME divide over ITERS=48 cycles instead
    //  of 12 yields a BIT-IDENTICAL quotient. KICKED at S2, runs concurrently
    //  with S3/S4.
    localparam integer DIVW   = 48;            // dividend / quotient width
    localparam integer UNROLL = 1;             // quotient bits resolved per clock
    localparam integer ITERS  = DIVW / UNROLL; // busy cycles (48)

    reg               busy = 1'b0;             // power-up idle (rst may be tied 0)
    reg  [6:0]        iter;                     // remaining busy cycles
    reg  [DIVW-1:0]   div_N;                    // dividend, shifted left each step
    reg  [DIVW-1:0]   div_Q;                    // quotient accumulator
    reg  [63:0]       div_R;                    // running remainder
    reg  [63:0]       div_D;                    // divisor (den)

    // one clock's worth of UNROLL restoring-division steps
    reg  [63:0]       step_R;
    reg  [DIVW-1:0]   step_N, step_Q;
    integer           u;

    always @(posedge clk) begin
        if (rst) begin
            valid <= 1'b0; degenerate <= 1'b0; busy <= 1'b0;
            e1 <= 1'b0; e1b <= 1'b0; e1c <= 1'b0;
            g1 <= 1'b0; g2 <= 1'b0; g3 <= 1'b0; g4 <= 1'b0;
            mac_busy <= 1'b0; s_vld <= 1'b0; p_vld <= 1'b0;
        end else begin
            valid <= 1'b0;                      // one-cycle pulse; default low
            e1 <= 1'b0; e1b <= 1'b0; e1c <= 1'b0; // S2 sub-stage pulses default low
            g1 <= 1'b0; g2 <= 1'b0; g3 <= 1'b0; g4 <= 1'b0;
            s_vld <= 1'b0;                       // MAC operand-valid default low
            p_vld <= 1'b0;                       // MAC product-valid default low

            // ============ P1: edgef vertex diffs + origin; latch raw =============
            // Accept a new triangle only when the whole pipeline AND divider are
            // idle. edgef(a,b,c)=(bx-ax)(cy-ay)-(by-ay)(cx-ax); register its four
            // DIFFERENCES here (no multiply). The bbox-min origin is swap-
            // invariant (the CCW swap only exchanges verts 1<->2), so compute it
            // from the RAW verts now. Carry raw verts+attrs to the P4 swap point.
            if (start && !busy && !mac_busy && !e1 && !e1b && !e1c && !g1 && !g2 && !g3 && !g4) begin
                p1_dbx <= vx1 - vx0;   p1_dcy <= vy2 - vy0;   // bx-ax , cy-ay
                p1_dby <= vy1 - vy0;   p1_dcx <= vx2 - vx0;   // by-ay , cx-ax

                p1_vx0 <= vx0; p1_vy0 <= vy0;
                p1_vx1 <= vx1; p1_vy1 <= vy1;
                p1_vx2 <= vx2; p1_vy2 <= vy2;

                // raw (un-swapped) attrs, attr order {u,v,r,g,b,a}
                p1_attr[0][0] <= vu0; p1_attr[1][0] <= vv0; p1_attr[2][0] <= vr0;
                p1_attr[3][0] <= vg0; p1_attr[4][0] <= vb0; p1_attr[5][0] <= va0;
                p1_attr[0][1] <= vu1; p1_attr[1][1] <= vv1; p1_attr[2][1] <= vr1;
                p1_attr[3][1] <= vg1; p1_attr[4][1] <= vb1; p1_attr[5][1] <= va1;
                p1_attr[0][2] <= vu2; p1_attr[1][2] <= vv2; p1_attr[2][2] <= vr2;
                p1_attr[3][2] <= vg2; p1_attr[4][2] <= vb2; p1_attr[5][2] <= va2;

                // bbox-min pixel = interpolation origin (clamp >=0, golden lx>>4)
                t_minx = (vx0 < vx1) ? ((vx0 < vx2) ? vx0 : vx2) : ((vx1 < vx2) ? vx1 : vx2);
                t_miny = (vy0 < vy1) ? ((vy0 < vy2) ? vy0 : vy2) : ((vy1 < vy2) ? vy1 : vy2);
                if (t_minx < 0) t_minx = 0;
                if (t_miny < 0) t_miny = 0;
                t_ox = (t_minx >>> 4);
                t_oy = (t_miny >>> 4);
                t_sx0 = (t_ox <<< 4) | 64'sd8;   // pixel-center sample at origin, 12.4
                t_sy0 = (t_oy <<< 4) | 64'sd8;
                p1_ox <= t_ox; p1_oy <= t_oy;
                p1_sx0 <= t_sx0; p1_sy0 <= t_sy0;

                g1 <= 1'b1;
            end

            // ============ P2: the two edgef products ============================
            if (g1) begin
                // [timing/DSP] diffs are ~17-bit; narrow to 19-bit signed operands so
                // each area product is one 19x19 DSP, not a 64x64 longint multiply.
                p2_prod1 <= $signed(p1_dbx[18:0]) * $signed(p1_dcy[18:0]);  // (bx-ax)*(cy-ay)
                p2_prod2 <= $signed(p1_dby[18:0]) * $signed(p1_dcx[18:0]);  // (by-ay)*(cx-ax)

                p2_vx0 <= p1_vx0; p2_vy0 <= p1_vy0;
                p2_vx1 <= p1_vx1; p2_vy1 <= p1_vy1;
                p2_vx2 <= p1_vx2; p2_vy2 <= p1_vy2;
                for (a = 0; a < 6; a = a + 1) begin
                    p2_attr[a][0] <= p1_attr[a][0];
                    p2_attr[a][1] <= p1_attr[a][1];
                    p2_attr[a][2] <= p1_attr[a][2];
                end
                p2_ox <= p1_ox; p2_oy <= p1_oy;
                p2_sx0 <= p1_sx0; p2_sy0 <= p1_sy0;

                g2 <= 1'b1;
            end

            // ============ P3: subtract -> signed area ============================
            if (g2) begin
                p3_narea <= p2_prod1 - p2_prod2;   // == edgef(a,b,c), signed area x2

                p3_vx0 <= p2_vx0; p3_vy0 <= p2_vy0;
                p3_vx1 <= p2_vx1; p3_vy1 <= p2_vy1;
                p3_vx2 <= p2_vx2; p3_vy2 <= p2_vy2;
                for (a = 0; a < 6; a = a + 1) begin
                    p3_attr[a][0] <= p2_attr[a][0];
                    p3_attr[a][1] <= p2_attr[a][1];
                    p3_attr[a][2] <= p2_attr[a][2];
                end
                p3_ox <= p2_ox; p3_oy <= p2_oy;
                p3_sx0 <= p2_sx0; p3_sy0 <= p2_sy0;

                g3 <= 1'b1;
            end

            // ============ P4: CCW-normalize (abs + swap-select) + den ============
            if (g3) begin
                t_swap  = (p3_narea < 0);
                t_area  = t_swap ? -p3_narea : p3_narea;
                t_degen = (t_area == 0);
                t_den   = t_degen ? 64'sd1 : t_area;

                // swapped coords (vert0 never swapped; swap exchanges 1<->2)
                s1_x0 <= p3_vx0; s1_y0 <= p3_vy0;
                if (t_swap) begin
                    s1_x1 <= p3_vx2; s1_y1 <= p3_vy2; s1_x2 <= p3_vx1; s1_y2 <= p3_vy1;
                end else begin
                    s1_x1 <= p3_vx1; s1_y1 <= p3_vy1; s1_x2 <= p3_vx2; s1_y2 <= p3_vy2;
                end

                // swapped attrs, matching the coord swap
                for (a = 0; a < 6; a = a + 1) begin
                    s1_A[a][0] <= p3_attr[a][0];
                    if (t_swap) begin
                        s1_A[a][1] <= p3_attr[a][2];
                        s1_A[a][2] <= p3_attr[a][1];
                    end else begin
                        s1_A[a][1] <= p3_attr[a][1];
                        s1_A[a][2] <= p3_attr[a][2];
                    end
                end

                s1_sx0 <= p3_sx0; s1_sy0 <= p3_sy0;
                s1_den <= t_den;
                s1_degen <= t_degen;

                // outputs final at this stage (valid does not rise until later)
                degenerate <= t_degen;
                ox <= p3_ox; oy <= p3_oy;
                area <= t_area[47:0];

                g4 <= 1'b1;
            end

            // ============ P5: reciprocal-numerator prep (== old "S1 done") =======
            if (g4) begin
                // num = 2^SHIFT + area/2 (== round(2^SHIFT/area)); den registered at P4
                s1_num <= (64'sd1 <<< SHIFT) + (s1_den >>> 1);
                e1 <= 1'b1;
            end

            // ============ Stage 2a: edgef coord differences + biases + deltas ===
            // edgef(a,b,c) = (bx-ax)(cy-ay) - (by-ay)(cx-ax). Register the four
            // DIFFERENCES per edge here (narrowed to 19b exactly as edgef() does),
            // so the products next cycle are NOT chained onto the subtract. Also
            // the (comparison-only) top-left biases and the (shift-only) per-x/
            // per-row deltas, and carry the attrs. Kick the reciprocal divider now
            // (it only needs s1_num/s1_den and is the ~48-cycle long pole).
            if (e1) begin
                // edge 0 = edgef(v1,v2,sample):  a=(x1,y1) b=(x2,y2) c=(sx0,sy0)
                dbx0 <= s1_x2 - s1_x1;  dcy0 <= s1_sy0 - s1_y1;
                dby0 <= s1_y2 - s1_y1;  dcx0 <= s1_sx0 - s1_x1;
                // edge 1 = edgef(v2,v0,sample):  a=(x2,y2) b=(x0,y0) c=(sx0,sy0)
                dbx1 <= s1_x0 - s1_x2;  dcy1 <= s1_sy0 - s1_y2;
                dby1 <= s1_y0 - s1_y2;  dcx1 <= s1_sx0 - s1_x2;
                // edge 2 = edgef(v0,v1,sample):  a=(x0,y0) b=(x1,y1) c=(sx0,sy0)
                dbx2 <= s1_x1 - s1_x0;  dcy2 <= s1_sy0 - s1_y0;
                dby2 <= s1_y1 - s1_y0;  dcx2 <= s1_sx0 - s1_x0;

                // top-left biases (comparisons only; identical edge pairing)
                sb0 <= tlbias(s1_x1,s1_y1, s1_x2,s1_y2);
                sb1 <= tlbias(s1_x2,s1_y2, s1_x0,s1_y0);
                sb2 <= tlbias(s1_x0,s1_y0, s1_x1,s1_y1);

                // constant per-x / per-row edge deltas (shifts only; no multiply)
                sdx0 <= 64'sd16 * (s1_y1 - s1_y2);  sdy0 <= 64'sd16 * (s1_x2 - s1_x1);
                sdx1 <= 64'sd16 * (s1_y2 - s1_y0);  sdy1 <= 64'sd16 * (s1_x0 - s1_x2);
                sdx2 <= 64'sd16 * (s1_y0 - s1_y1);  sdy2 <= 64'sd16 * (s1_x1 - s1_x0);

                // carry attrs forward for the sequential MAC
                for (a = 0; a < 6; a = a + 1) begin
                    s2_A[a][0] <= s1_A[a][0];
                    s2_A[a][1] <= s1_A[a][1];
                    s2_A[a][2] <= s1_A[a][2];
                end

                // kick the sequential reciprocal (or take the degenerate fast path)
                if (s1_degen) begin
                    // area==0: no divide; area_recip == 2^SHIFT (den forced 1)
                    area_recip <= (48'd1 <<< SHIFT);
                end else begin
                    div_N <= s1_num[DIVW-1:0];
                    div_D <= s1_den[63:0];
                    div_R <= 64'd0;
                    div_Q <= {DIVW{1'b0}};
                    iter  <= ITERS[6:0];
                    busy  <= 1'b1;
                end
                mac_degen <= s1_degen;   // latch for the MAC valid at S2c kick

                e1b <= 1'b1;
            end

            // ============ Stage 2b: the two edgef products per edge ==============
            // From the registered 19b differences -> one DSP each, no subtract in
            // this cycle. (This is the split that fixed the s1_x2 -> w1_0 path.)
            if (e1b) begin
                pr0a <= dbx0 * dcy0;  pr0b <= dby0 * dcx0;
                pr1a <= dbx1 * dcy1;  pr1b <= dby1 * dcx1;
                pr2a <= dbx2 * dcy2;  pr2b <= dby2 * dcx2;
                e1c <= 1'b1;
            end

            // ============ Stage 2c: subtract + bias -> edge functions; kick MAC ==
            if (e1c) begin
                tnw0 = pr0a - pr0b + sb0;   // == edgef(v1,v2,sample) + tb0
                tnw1 = pr1a - pr1b + sb1;
                tnw2 = pr2a - pr2b + sb2;

                // full-precision carriers for the MAC
                s2_nw[0] <= tnw0; s2_nw[1] <= tnw1; s2_nw[2] <= tnw2;
                s2_ndwdx[0] <= sdx0; s2_ndwdx[1] <= sdx1; s2_ndwdx[2] <= sdx2;
                s2_ndwdy[0] <= sdy0; s2_ndwdy[1] <= sdy1; s2_ndwdy[2] <= sdy2;

                // registered module outputs (truncate to 48b exactly as before)
                w0_0 <= tnw0[47:0]; w1_0 <= tnw1[47:0]; w2_0 <= tnw2[47:0];
                dw0dx <= sdx0[47:0]; dw1dx <= sdx1[47:0]; dw2dx <= sdx2[47:0];
                dw0dy <= sdy0[47:0]; dw1dy <= sdy1[47:0]; dw2dy <= sdy2[47:0];

                // kick the sequential Stage-3 MAC now that s2_nw/ndw* are valid
                // (still concurrent with the divider, which drains later).
                mac_busy <= 1'b1;
                mac_idx  <= 6'd0;
                mac_a    <= 3'd0;
                mac_k    <= 2'd0;
            end

            // ============ Stage 3 MAC — SEL: operand mux (one step / cycle) ======
            // Walk the 18 (attribute mac_a, vert mac_k) pairs with DIRECT counters
            // (mac_k 0->1->2->0, bumping mac_a) instead of mac_idx/3 and mac_idx%3
            // — the divide/modulo by 3 synthesized a multi-stage combinational
            // divider (mac_idx -> Mod0|divider -> sel_a was the -1.6 ns path). Mux
            // the NARROWED operands (nw ~26b -> 27, deltas ~24b, attrs
            // u/v<=32768,rgba<=255 -> 18b; value unchanged in-envelope, guarded by
            // tb_tri_setup) into FIXED sel_* registers; keeping this array-mux OUT
            // of the multiply cycle is the point. The lanes share sel_a.
            if (mac_busy && mac_idx < 6'd18) begin
                sel_w0 <= s2_nw[mac_k][26:0];
                sel_wx <= s2_ndwdx[mac_k][23:0];
                sel_wy <= s2_ndwdy[mac_k][23:0];
                sel_a  <= s2_A[mac_a][mac_k][17:0];
                s_a    <= mac_a;
                s_k    <= mac_k;
                s_vld  <= 1'b1;
                mac_idx <= mac_idx + 6'd1;
                if (mac_k == 2'd2) begin mac_k <= 2'd0; mac_a <= mac_a + 3'd1; end
                else                    mac_k <= mac_k + 2'd1;
            end

            // ============ Stage 3 MAC — MUL: products from fixed registers =======
            // Reads only the sel_* registers (no mux ahead of the DSP), so each
            // lane is a clean 27x18 / 24x18 multiply.
            if (s_vld) begin
                pr0 <= $signed(sel_w0) * $signed(sel_a);
                prx <= $signed(sel_wx) * $signed(sel_a);
                pry <= $signed(sel_wy) * $signed(sel_a);
                p_a   <= s_a;
                p_k   <= s_k;
                p_vld <= 1'b1;
            end

            // ============ Stage 3 MAC — accumulate stage (add only) =============
            // Consumes the product registered LAST cycle. Verts arrive k=0,1,2
            // per attribute, so start on k==0, add on k==1, and on k==2 latch the
            // completed W/dW outputs for attribute p_a (truncate to 48b exactly as
            // the former Stage-4 did). Only a 64-bit add is in this path — the
            // multiply->add chain of the old single-cycle Stage-3/-4 is gone.
            if (p_vld) begin
                sum0 = acc0 + pr0;  sumx = accx + prx;  sumy = accy + pry;
                if (p_k == 2'd0) begin
                    acc0 <= pr0;  accx <= prx;  accy <= pry;
                end else if (p_k == 2'd1) begin
                    acc0 <= sum0; accx <= sumx; accy <= sumy;
                end else begin
                    case (p_a)
                      3'd0: begin Wu_0<=sum0[47:0]; dWudx<=sumx[47:0]; dWudy<=sumy[47:0]; end
                      3'd1: begin Wv_0<=sum0[47:0]; dWvdx<=sumx[47:0]; dWvdy<=sumy[47:0]; end
                      3'd2: begin Wr_0<=sum0[47:0]; dWrdx<=sumx[47:0]; dWrdy<=sumy[47:0]; end
                      3'd3: begin Wg_0<=sum0[47:0]; dWgdx<=sumx[47:0]; dWgdy<=sumy[47:0]; end
                      3'd4: begin Wb_0<=sum0[47:0]; dWbdx<=sumx[47:0]; dWbdy<=sumy[47:0]; end
                      3'd5: begin Wa_0<=sum0[47:0]; dWadx<=sumx[47:0]; dWady<=sumy[47:0]; end
                    endcase
                    if (p_a == 3'd5) begin
                        // last attribute drained. Non-degenerate triangles assert
                        // valid on divider-done (still running, the long pole);
                        // degenerate ones skipped the divider, so valid here.
                        mac_busy <= 1'b0;
                        if (mac_degen) valid <= 1'b1;
                    end
                end
            end

            // ============ concurrent sequential reciprocal ======================
            if (busy) begin
                // one clock = UNROLL restoring steps (short combinational chain)
                step_R = div_R;
                step_N = div_N;
                step_Q = div_Q;
                for (u = 0; u < UNROLL; u = u + 1) begin
                    step_R = (step_R <<< 1) | step_N[DIVW-1];
                    step_N = step_N <<< 1;
                    if (step_R >= div_D) begin
                        step_R = step_R - div_D;
                        step_Q = (step_Q <<< 1) | 1'b1;
                    end else begin
                        step_Q = (step_Q <<< 1);
                    end
                end
                div_R <= step_R;
                div_N <= step_N;
                div_Q <= step_Q;
                if (iter == 7'd1) begin
                    area_recip <= step_Q[47:0];   // fully resolved quotient
                    valid      <= 1'b1;           // non-degenerate: valid on divide done
                    busy       <= 1'b0;
                end else begin
                    iter <= iter - 7'd1;
                end
            end
        end
    end
endmodule
`default_nettype wire
