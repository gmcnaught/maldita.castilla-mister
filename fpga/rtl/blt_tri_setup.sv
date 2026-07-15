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
//  This is a behavioural, longint-precise setup block (a sim-equivalence model,
//  mirroring blt_tri.sv's style), registered on `clk`: pulse `start` with the
//  vertices; `valid` rises the next cycle with all outputs stable. A real build
//  would replace the single-cycle divide with a pipelined reciprocal (amortized
//  ~10 triangles/frame); the OUTPUT interface below is what Task 5 consumes.
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

    // combinational "next" values
    reg  signed [63:0] x0,y0, x1n,y1n, x2n,y2n, n_area, den;
    reg  signed [63:0] u1a,v1a,u2a,v2a;
    reg  signed [63:0] r0a,g0a,b0a,a0a, r1a,g1a,b1a,a1a, r2a,g2a,b2a,a2a;
    reg  signed [63:0] b0,b1,b2, sx0,sy0, nw0,nw1,nw2;
    reg  signed [63:0] ndw0dx,ndw1dx,ndw2dx, ndw0dy,ndw1dy,ndw2dy;
    reg  signed [63:0] n_recip;
    reg  signed [63:0] minx,miny;
    reg         [15:0] n_ox,n_oy;
    reg                n_degen;

    // weighted-sum helper: W = w0*A0 + w1*A1 + w2*A2 (all longint)
    function automatic longint wsum(input longint k0,k1,k2, A0,A1,A2);
        wsum = k0*A0 + k1*A1 + k2*A2;
    endfunction

    always @* begin
        // --- CCW-normalize by swapping verts b,c when signed area < 0 (== golden) ---
        x0 = vx0; y0 = vy0;
        n_area = edgef(vx0,vy0, vx1,vy1, vx2,vy2);
        if (n_area < 0) begin
            x1n=vx2; y1n=vy2; x2n=vx1; y2n=vy1;
            u1a=vu2; v1a=vv2; u2a=vu1; v2a=vv1;
            r1a=vr2; g1a=vg2; b1a=vb2; a1a=va2;
            r2a=vr1; g2a=vg1; b2a=vb1; a2a=va1;
            n_area = -n_area;
        end else begin
            x1n=vx1; y1n=vy1; x2n=vx2; y2n=vy2;
            u1a=vu1; v1a=vv1; u2a=vu2; v2a=vv2;
            r1a=vr1; g1a=vg1; b1a=vb1; a1a=va1;
            r2a=vr2; g2a=vg2; b2a=vb2; a2a=va2;
        end
        r0a=vr0; g0a=vg0; b0a=vb0; a0a=va0;

        n_degen = (n_area == 0);
        den     = n_degen ? 64'sd1 : n_area;

        // --- bbox-min pixel = interpolation origin (clamp >=0, matches golden lx>>4) ---
        minx = (x0 < x1n) ? ((x0 < x2n) ? x0 : x2n) : ((x1n < x2n) ? x1n : x2n);
        miny = (y0 < y1n) ? ((y0 < y2n) ? y0 : y2n) : ((y1n < y2n) ? y1n : y2n);
        if (minx < 0) minx = 0;
        if (miny < 0) miny = 0;
        n_ox = (minx >>> 4);
        n_oy = (miny >>> 4);
        sx0  = (n_ox <<< 4) | 64'sd8;   // pixel-center sample at origin, 12.4
        sy0  = (n_oy <<< 4) | 64'sd8;

        // --- top-left biases (identical edge pairing to blt_tri.sv:95-97) ---
        b0 = tlbias(x1n,y1n, x2n,y2n);   // edge b->c, opposite a
        b1 = tlbias(x2n,y2n, x0,y0);     // edge c->a, opposite b
        b2 = tlbias(x0,y0,   x1n,y1n);   // edge a->b, opposite c

        // --- edge functions at the origin sample ---
        nw0 = edgef(x1n,y1n, x2n,y2n, sx0,sy0) + b0;
        nw1 = edgef(x2n,y2n, x0,y0,   sx0,sy0) + b1;
        nw2 = edgef(x0,y0,   x1n,y1n, sx0,sy0) + b2;

        // --- constant per-x / per-row edge deltas. d(edge)/d(sample) is linear;
        //     one pixel step == +16 in 12.4. dw_k/dx = 16*(y diff), dw_k/dy = 16*(x diff). ---
        ndw0dx = 64'sd16 * (y1n - y2n);  ndw0dy = 64'sd16 * (x2n - x1n);
        ndw1dx = 64'sd16 * (y2n - y0 );  ndw1dy = 64'sd16 * (x0  - x2n);
        ndw2dx = 64'sd16 * (y0  - y1n);  ndw2dy = 64'sd16 * (x1n - x0 );

        // --- fixed-point reciprocal of the (positive) area, round-to-nearest ---
        n_recip = ( (64'sd1 <<< SHIFT) + (den >>> 1) ) / den;
    end

    // ── register everything (single behavioural cycle) ────────────────────────
    always @(posedge clk) begin
        if (rst) begin
            valid <= 1'b0; degenerate <= 1'b0;
        end else begin
            valid <= start;
            if (start) begin
                degenerate <= n_degen;
                ox <= n_ox; oy <= n_oy;
                area       <= n_area[47:0];
                area_recip <= n_recip[47:0];

                w0_0 <= nw0[47:0]; w1_0 <= nw1[47:0]; w2_0 <= nw2[47:0];
                dw0dx<=ndw0dx[47:0]; dw1dx<=ndw1dx[47:0]; dw2dx<=ndw2dx[47:0];
                dw0dy<=ndw0dy[47:0]; dw1dy<=ndw1dy[47:0]; dw2dy<=ndw2dy[47:0];

                // origin weighted sums (attr0 uses the un-swapped v0 texel/colour)
                Wu_0 <= wsum(nw0,nw1,nw2, vu0,u1a,u2a);
                Wv_0 <= wsum(nw0,nw1,nw2, vv0,v1a,v2a);
                Wr_0 <= wsum(nw0,nw1,nw2, r0a,r1a,r2a);
                Wg_0 <= wsum(nw0,nw1,nw2, g0a,g1a,g2a);
                Wb_0 <= wsum(nw0,nw1,nw2, b0a,b1a,b2a);
                Wa_0 <= wsum(nw0,nw1,nw2, a0a,a1a,a2a);

                // weighted-sum deltas: dW_A/dx = sum_k dw_k/dx * A_k  (affine)
                dWudx <= wsum(ndw0dx,ndw1dx,ndw2dx, vu0,u1a,u2a);
                dWvdx <= wsum(ndw0dx,ndw1dx,ndw2dx, vv0,v1a,v2a);
                dWrdx <= wsum(ndw0dx,ndw1dx,ndw2dx, r0a,r1a,r2a);
                dWgdx <= wsum(ndw0dx,ndw1dx,ndw2dx, g0a,g1a,g2a);
                dWbdx <= wsum(ndw0dx,ndw1dx,ndw2dx, b0a,b1a,b2a);
                dWadx <= wsum(ndw0dx,ndw1dx,ndw2dx, a0a,a1a,a2a);

                dWudy <= wsum(ndw0dy,ndw1dy,ndw2dy, vu0,u1a,u2a);
                dWvdy <= wsum(ndw0dy,ndw1dy,ndw2dy, vv0,v1a,v2a);
                dWrdy <= wsum(ndw0dy,ndw1dy,ndw2dy, r0a,r1a,r2a);
                dWgdy <= wsum(ndw0dy,ndw1dy,ndw2dy, g0a,g1a,g2a);
                dWbdy <= wsum(ndw0dy,ndw1dy,ndw2dy, b0a,b1a,b2a);
                dWady <= wsum(ndw0dy,ndw1dy,ndw2dy, a0a,a1a,a2a);
            end
        end
    end
endmodule
`default_nettype wire
