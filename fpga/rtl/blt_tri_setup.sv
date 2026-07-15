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
//  than one multiplier (the former one-cycle combinational block chained the
//  edge-function product INTO the weighted-sum product, which failed Quartus
//  setup timing at ~98 MHz on the fabric clock). The stages are:
//    S1 (on start): signed area (edgef) + CCW-normalize (select the possibly-
//        swapped vertex coords/attrs into registers); origin (ox,oy) + sample
//        (sx0,sy0); degenerate/den/reciprocal-numerator. [multiplier depth 1]
//    S2: the three edge functions w{k}_0 at the origin sample (+top-left bias),
//        and the small per-x/per-row edge deltas dw{k}dx=16*(yi-yj),
//        dw{k}dy=16*(xj-xi); KICK the sequential area reciprocal. [mult depth 1]
//    S3: the 54 partial products w{k}_0*A{k}, dw{k}dx*A{k}, dw{k}dy*A{k}
//        (k over the 3 verts, A over u,v,r,g,b,a). [mult depth 1]
//    S4: sum the 3 partials per attribute -> W{}_0, dW{}dx, dW{}dy. [adders only]
//  The area reciprocal is a synthesizable radix-2 restoring divider (UNROLL
//  bits/cycle, ITERS busy cycles) kicked at S2 and running CONCURRENTLY with
//  S3/S4; `valid` rises when it finishes (it is the long pole). Latency:
//  non-degenerate ~13 cycles (1 latch + S2 kick + ITERS divider cycles),
//  degenerate ~4 cycles (skips the divider, asserts valid when S4 lands). Both
//  are well inside the downstream valid-wait. The arithmetic is UNCHANGED from
//  the former single-cycle block — only pipeline registers were inserted — so
//  every output stays bit-exact-or-±1 vs. the golden (tb_tri_setup).
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
    // signed area x2 of triangle (a,b,c) — same integer edge function as the golden
    function automatic longint edgef(input longint ax, ay, bx, by, cx, cy);
        edgef = (bx-ax)*(cy-ay) - (by-ay)*(cx-ax);
    endfunction
    // top-left rule bias: 0 on a top/left edge a->b, else -1 (mirrors blt_tri.sv)
    function automatic longint tlbias(input longint ax, ay, bx, by);
        tlbias = (((ay==by) && (bx<ax)) || (by>ay)) ? 64'sd0 : -64'sd1;
    endfunction

    // ── pipeline stage-valid pulses (one-hot progression S1->S2->S3->S4) ───────
    reg e1, e2, e3;

    // ── Stage-1 registers (CCW-normalized verts/attrs + origin + recip inputs) ─
    // attrs held as signed 64-bit (values are small & non-negative) so the later
    // products are unambiguously SIGNED (a signed*unsigned mix would flip context).
    reg signed [63:0] s1_x0,s1_y0, s1_x1,s1_y1, s1_x2,s1_y2;   // swapped coords
    reg signed [63:0] s1_sx0, s1_sy0;                           // origin sample (12.4)
    reg signed [63:0] s1_den, s1_num;                           // divider divisor / dividend
    reg               s1_degen;
    reg signed [63:0] s1_A [0:5][0:2];   // [attr u,v,r,g,b,a][vert 0,1,2], swapped

    // ── Stage-2 registers (edge functions + deltas, carried attrs) ─────────────
    reg               s2_degen;
    reg signed [63:0] s2_nw    [0:2];    // edge-function value at origin (incl. bias)
    reg signed [63:0] s2_ndwdx [0:2];    // 16*(y diff)
    reg signed [63:0] s2_ndwdy [0:2];    // 16*(x diff)
    reg signed [63:0] s2_A [0:5][0:2];

    // ── Stage-3 registers (partial products, 3 per attribute) ──────────────────
    reg               s3_degen;
    reg signed [63:0] p0  [0:5][0:2];    // w{k}_0  * A{k}
    reg signed [63:0] pdx [0:5][0:2];    // dw{k}dx * A{k}
    reg signed [63:0] pdy [0:5][0:2];    // dw{k}dy * A{k}

    // combinational temporaries (blocking, per-stage)
    reg signed [63:0] t_narea, t_area, t_den;
    reg               t_swap, t_degen;
    reg signed [63:0] tx0,ty0, tx1,ty1, tx2,ty2;
    reg signed [63:0] t_minx, t_miny, t_sx0, t_sy0;
    reg        [15:0] t_ox, t_oy;
    reg signed [63:0] tb0,tb1,tb2;
    reg signed [63:0] tnw0,tnw1,tnw2, tdx0,tdx1,tdx2, tdy0,tdy1,tdy2;
    integer a, k;

    // ── SEQUENTIAL area reciprocal (radix-2 restoring divide, unrolled) ────────
    //  Computes q = floor(num/den) == round(2^SHIFT/area), identical to a single
    //  `num/den`, but iteratively: standard long division shifting the dividend
    //  MSB-first into a running remainder, UNROLL bits per clock. num < 2^41, so
    //  DIVW=48 dividend/quotient bits cover every quotient (leading bits are 0);
    //  den <= ~2^35 fits the 64-bit remainder path. Critical path per cycle is
    //  UNROLL chained subtract-compares (not a 41-deep divide), so this closes
    //  timing; it is KICKED at S2 and runs concurrently with S3/S4.
    localparam integer DIVW   = 48;            // dividend / quotient width
    localparam integer UNROLL = 4;             // quotient bits resolved per clock
    localparam integer ITERS  = DIVW / UNROLL; // busy cycles (12)

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
            e1 <= 1'b0; e2 <= 1'b0; e3 <= 1'b0;
        end else begin
            valid <= 1'b0;                      // one-cycle pulse; default low
            e1 <= 1'b0; e2 <= 1'b0; e3 <= 1'b0; // stage pulses default low

            // ============ Stage 1: latch verts, area + CCW-normalize ============
            // Accept a new triangle only when the pipeline AND divider are idle.
            if (start && !busy && !e1 && !e2 && !e3) begin
                t_narea = edgef(vx0,vy0, vx1,vy1, vx2,vy2);
                t_swap  = (t_narea < 0);
                t_area  = t_swap ? -t_narea : t_narea;
                t_degen = (t_area == 0);
                t_den   = t_degen ? 64'sd1 : t_area;

                tx0 = vx0; ty0 = vy0;
                if (t_swap) begin
                    tx1 = vx2; ty1 = vy2; tx2 = vx1; ty2 = vy1;
                end else begin
                    tx1 = vx1; ty1 = vy1; tx2 = vx2; ty2 = vy2;
                end

                // bbox-min pixel = interpolation origin (clamp >=0, matches golden lx>>4)
                t_minx = (tx0 < tx1) ? ((tx0 < tx2) ? tx0 : tx2) : ((tx1 < tx2) ? tx1 : tx2);
                t_miny = (ty0 < ty1) ? ((ty0 < ty2) ? ty0 : ty2) : ((ty1 < ty2) ? ty1 : ty2);
                if (t_minx < 0) t_minx = 0;
                if (t_miny < 0) t_miny = 0;
                t_ox = (t_minx >>> 4);
                t_oy = (t_miny >>> 4);
                t_sx0 = (t_ox <<< 4) | 64'sd8;   // pixel-center sample at origin, 12.4
                t_sy0 = (t_oy <<< 4) | 64'sd8;

                // latch stage-1 datapath
                s1_x0 <= tx0; s1_y0 <= ty0;
                s1_x1 <= tx1; s1_y1 <= ty1;
                s1_x2 <= tx2; s1_y2 <= ty2;
                s1_sx0 <= t_sx0; s1_sy0 <= t_sy0;
                s1_den <= t_den;
                // reciprocal round-numerator: num = 2^SHIFT + area/2 (== round(2^SHIFT/area))
                s1_num <= (64'sd1 <<< SHIFT) + (t_den >>> 1);
                s1_degen <= t_degen;

                // attributes: attr order {u,v,r,g,b,a}; vert0 is never swapped
                s1_A[0][0] <= vu0; s1_A[1][0] <= vv0; s1_A[2][0] <= vr0;
                s1_A[3][0] <= vg0; s1_A[4][0] <= vb0; s1_A[5][0] <= va0;
                if (t_swap) begin
                    s1_A[0][1] <= vu2; s1_A[1][1] <= vv2; s1_A[2][1] <= vr2;
                    s1_A[3][1] <= vg2; s1_A[4][1] <= vb2; s1_A[5][1] <= va2;
                    s1_A[0][2] <= vu1; s1_A[1][2] <= vv1; s1_A[2][2] <= vr1;
                    s1_A[3][2] <= vg1; s1_A[4][2] <= vb1; s1_A[5][2] <= va1;
                end else begin
                    s1_A[0][1] <= vu1; s1_A[1][1] <= vv1; s1_A[2][1] <= vr1;
                    s1_A[3][1] <= vg1; s1_A[4][1] <= vb1; s1_A[5][1] <= va1;
                    s1_A[0][2] <= vu2; s1_A[1][2] <= vv2; s1_A[2][2] <= vr2;
                    s1_A[3][2] <= vg2; s1_A[4][2] <= vb2; s1_A[5][2] <= va2;
                end

                // outputs that are final at S1
                degenerate <= t_degen;
                ox <= t_ox; oy <= t_oy;
                area <= t_area[47:0];

                e1 <= 1'b1;
            end

            // ============ Stage 2: edge functions + deltas + kick divider =======
            if (e1) begin
                // top-left biases (identical edge pairing to blt_tri.sv:95-97)
                tb0 = tlbias(s1_x1,s1_y1, s1_x2,s1_y2);   // edge b->c, opposite a
                tb1 = tlbias(s1_x2,s1_y2, s1_x0,s1_y0);   // edge c->a, opposite b
                tb2 = tlbias(s1_x0,s1_y0, s1_x1,s1_y1);   // edge a->b, opposite c

                // edge functions at the origin sample (single multiply depth: the
                // two products inside edgef are parallel, then one subtract)
                tnw0 = edgef(s1_x1,s1_y1, s1_x2,s1_y2, s1_sx0,s1_sy0) + tb0;
                tnw1 = edgef(s1_x2,s1_y2, s1_x0,s1_y0, s1_sx0,s1_sy0) + tb1;
                tnw2 = edgef(s1_x0,s1_y0, s1_x1,s1_y1, s1_sx0,s1_sy0) + tb2;

                // constant per-x / per-row edge deltas (shifts only; no multiply)
                tdx0 = 64'sd16 * (s1_y1 - s1_y2);  tdy0 = 64'sd16 * (s1_x2 - s1_x1);
                tdx1 = 64'sd16 * (s1_y2 - s1_y0);  tdy1 = 64'sd16 * (s1_x0 - s1_x2);
                tdx2 = 64'sd16 * (s1_y0 - s1_y1);  tdy2 = 64'sd16 * (s1_x1 - s1_x0);

                // full-precision carriers for the S3 products
                s2_nw[0] <= tnw0; s2_nw[1] <= tnw1; s2_nw[2] <= tnw2;
                s2_ndwdx[0] <= tdx0; s2_ndwdx[1] <= tdx1; s2_ndwdx[2] <= tdx2;
                s2_ndwdy[0] <= tdy0; s2_ndwdy[1] <= tdy1; s2_ndwdy[2] <= tdy2;

                // registered module outputs (truncate to 48b exactly as before)
                w0_0 <= tnw0[47:0]; w1_0 <= tnw1[47:0]; w2_0 <= tnw2[47:0];
                dw0dx <= tdx0[47:0]; dw1dx <= tdx1[47:0]; dw2dx <= tdx2[47:0];
                dw0dy <= tdy0[47:0]; dw1dy <= tdy1[47:0]; dw2dy <= tdy2[47:0];

                // carry attrs + degen forward
                for (a = 0; a < 6; a = a + 1) begin
                    s2_A[a][0] <= s1_A[a][0];
                    s2_A[a][1] <= s1_A[a][1];
                    s2_A[a][2] <= s1_A[a][2];
                end
                s2_degen <= s1_degen;

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

                e2 <= 1'b1;
            end

            // ============ Stage 3: partial products w{k}*A{k} etc ===============
            if (e2) begin
                for (a = 0; a < 6; a = a + 1) begin
                    for (k = 0; k < 3; k = k + 1) begin
                        p0 [a][k] <= s2_nw[k]    * s2_A[a][k];
                        pdx[a][k] <= s2_ndwdx[k] * s2_A[a][k];
                        pdy[a][k] <= s2_ndwdy[k] * s2_A[a][k];
                    end
                end
                s3_degen <= s2_degen;
                e3 <= 1'b1;
            end

            // ============ Stage 4: sum the 3 partials per attribute =============
            if (e3) begin
                Wu_0 <= p0[0][0] + p0[0][1] + p0[0][2];
                Wv_0 <= p0[1][0] + p0[1][1] + p0[1][2];
                Wr_0 <= p0[2][0] + p0[2][1] + p0[2][2];
                Wg_0 <= p0[3][0] + p0[3][1] + p0[3][2];
                Wb_0 <= p0[4][0] + p0[4][1] + p0[4][2];
                Wa_0 <= p0[5][0] + p0[5][1] + p0[5][2];

                dWudx <= pdx[0][0] + pdx[0][1] + pdx[0][2];
                dWvdx <= pdx[1][0] + pdx[1][1] + pdx[1][2];
                dWrdx <= pdx[2][0] + pdx[2][1] + pdx[2][2];
                dWgdx <= pdx[3][0] + pdx[3][1] + pdx[3][2];
                dWbdx <= pdx[4][0] + pdx[4][1] + pdx[4][2];
                dWadx <= pdx[5][0] + pdx[5][1] + pdx[5][2];

                dWudy <= pdy[0][0] + pdy[0][1] + pdy[0][2];
                dWvdy <= pdy[1][0] + pdy[1][1] + pdy[1][2];
                dWrdy <= pdy[2][0] + pdy[2][1] + pdy[2][2];
                dWgdy <= pdy[3][0] + pdy[3][1] + pdy[3][2];
                dWbdy <= pdy[4][0] + pdy[4][1] + pdy[4][2];
                dWady <= pdy[5][0] + pdy[5][1] + pdy[5][2];

                // degenerate triangles skip the divider; their W outputs are moot
                // (the walk drops the triangle) — assert valid as soon as S4 lands.
                if (s3_degen) valid <= 1'b1;
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
