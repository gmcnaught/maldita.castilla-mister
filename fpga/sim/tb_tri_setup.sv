// tb_tri_setup.sv — self-checking unit tb for blt_tri_setup (Task 4).
//
// Verifies the triangle-SETUP datapath against the combinational golden
// blt_tri.sv within +-1 LSB. Setup computes ONCE per triangle: signed area,
// a fixed-point reciprocal area_recip = round(2^SHIFT/area), the constant
// per-x / per-row deltas of the three edge functions and of the six
// barycentric-WEIGHTED attribute sums {u,v,r,g,b,a}, plus the origin values at
// the bbox-min sample corner. The per-pixel walk (Task 5) then needs only adds
// (to step the weighted sums W) and one fixed-point multiply per attribute:
//     attr = round(W * area_recip / 2^SHIFT)      (NO per-pixel divide)
// This tb reconstructs (u,v,r,g,b,a) that way at every covered pixel of the
// bbox and asserts each equals blt_tri's (tu,tv,cr,cg,cb,ca) within +-1.
//
// Datapath A (robust): accumulate the INTEGER weighted sums, multiply by the
// reciprocal per pixel. SHIFT=40 keeps the reciprocal-quantization error
// (<= |W|*0.5/2^SHIFT ~ 2e-4 for this triangle) far below the +-1 tolerance.
//
// Copyright (C) 2026 — GPL-3.0.
`timescale 1ns/1ps
`default_nettype none
module tb_tri_setup;
  localparam integer SHIFT = 40;   // must match blt_tri_setup's fixed-point shift

  reg clk=0; always #5 clk=~clk;

  // ---- the fixed test triangle: DISTINCT per-vertex u,v AND r,g,b,a so the
  //      barycentric interpolation is actually exercised (tri_copy's uniform
  //      attrs would not). Screen coords are 12.4 (pixel*16); u,v are 12.4
  //      texel over an 8x8 texture (texel 0..7 -> 0..112). CCW winding (area>0).
  // v0 (100,80)  u=0    v=0    rgba=( 30,200, 10,255)
  // v1 (180,90)  u=112  v=0    rgba=(240, 20, 60,200)
  // v2 (130,170) u=16   v=112  rgba=( 80,120,220,100)
  localparam signed [15:0] VX0=16'sd1600, VY0=16'sd1280;
  localparam signed [15:0] VX1=16'sd2880, VY1=16'sd1440;
  localparam signed [15:0] VX2=16'sd2080, VY2=16'sd2720;
  localparam [15:0] VU0=16'd0,   VV0=16'd0;
  localparam [15:0] VU1=16'd112, VV1=16'd0;
  localparam [15:0] VU2=16'd16,  VV2=16'd112;
  localparam [7:0] VR0=8'd30,  VG0=8'd200, VB0=8'd10,  VA0=8'd255;
  localparam [7:0] VR1=8'd240, VG1=8'd20,  VB1=8'd60,  VA1=8'd200;
  localparam [7:0] VR2=8'd80,  VG2=8'd120, VB2=8'd220, VA2=8'd100;
  localparam [15:0] TEX_W=16'd8, TEX_H=16'd8;

  // ---- golden combinational evaluator (drive px,py; read hit/tu/tv/cr..ca) ----
  reg  [15:0] px, py;
  wire        g_hit;
  wire [15:0] g_tu, g_tv;
  wire [7:0]  g_cr, g_cg, g_cb, g_ca;
  blt_tri golden (
    .vx0(VX0),.vy0(VY0),.vx1(VX1),.vy1(VY1),.vx2(VX2),.vy2(VY2),
    .vu0(VU0),.vv0(VV0),.vu1(VU1),.vv1(VV1),.vu2(VU2),.vv2(VV2),
    .vr0(VR0),.vg0(VG0),.vb0(VB0),.va0(VA0),
    .vr1(VR1),.vg1(VG1),.vb1(VB1),.va1(VA1),
    .vr2(VR2),.vg2(VG2),.vb2(VB2),.va2(VA2),
    .tex_w(TEX_W),.tex_h(TEX_H),.px(px),.py(py),
    .hit(g_hit),.tu(g_tu),.tv(g_tv),.cr(g_cr),.cg(g_cg),.cb(g_cb),.ca(g_ca),
    .texel(16'd0),.dst(16'd0),.g_alpha(8'd0),.blend_mode(8'd0),.colorkey(16'd0),
    .write_en(),.out_pix() );

  // ---- setup under test (registered; start->valid) ----
  reg  start=0;
  wire valid, degenerate;
  wire [15:0] ox, oy;
  wire signed [47:0] area;
  wire        [47:0] area_recip;
  wire signed [31:0] w0_0, w1_0, w2_0;
  wire signed [31:0] dw0dx, dw1dx, dw2dx, dw0dy, dw1dy, dw2dy;
  wire signed [47:0] Wu_0, Wv_0, Wr_0, Wg_0, Wb_0, Wa_0;
  wire signed [47:0] dWudx, dWvdx, dWrdx, dWgdx, dWbdx, dWadx;
  wire signed [47:0] dWudy, dWvdy, dWrdy, dWgdy, dWbdy, dWady;
  blt_tri_setup dut (
    .clk(clk),.rst(1'b0),.start(start),
    .vx0(VX0),.vy0(VY0),.vx1(VX1),.vy1(VY1),.vx2(VX2),.vy2(VY2),
    .vu0(VU0),.vv0(VV0),.vu1(VU1),.vv1(VV1),.vu2(VU2),.vv2(VV2),
    .vr0(VR0),.vg0(VG0),.vb0(VB0),.va0(VA0),
    .vr1(VR1),.vg1(VG1),.vb1(VB1),.va1(VA1),
    .vr2(VR2),.vg2(VG2),.vb2(VB2),.va2(VA2),
    .tex_w(TEX_W),.tex_h(TEX_H),
    .valid(valid),.degenerate(degenerate),.ox(ox),.oy(oy),
    .area(area),.area_recip(area_recip),
    .w0_0(w0_0),.w1_0(w1_0),.w2_0(w2_0),
    .dw0dx(dw0dx),.dw1dx(dw1dx),.dw2dx(dw2dx),
    .dw0dy(dw0dy),.dw1dy(dw1dy),.dw2dy(dw2dy),
    .Wu_0(Wu_0),.Wv_0(Wv_0),.Wr_0(Wr_0),.Wg_0(Wg_0),.Wb_0(Wb_0),.Wa_0(Wa_0),
    .dWudx(dWudx),.dWvdx(dWvdx),.dWrdx(dWrdx),.dWgdx(dWgdx),.dWbdx(dWbdx),.dWadx(dWadx),
    .dWudy(dWudy),.dWvdy(dWvdy),.dWrdy(dWrdy),.dWgdy(dWgdy),.dWbdy(dWbdy),.dWady(dWady) );

  // round(W * recip / 2^SHIFT), round-half-up in magnitude (matches divr).
  function automatic longint rnd_recip(input longint W, input longint recip);
    longint half; begin
      half = (64'sd1 <<< (SHIFT-1));
      if (W >= 0) rnd_recip =  ( (W  * recip) + half) >>> SHIFT;
      else        rnd_recip = -(((-W) * recip) + half) >>> SHIFT;
    end
  endfunction

  // reconstruct one attribute's WEIGHTED SUM at pixel (x,y) via origin+stepping,
  // then divide by area through the reciprocal.
  function automatic longint recon_attr(input longint W0, dWdx, dWdy,
                                        input integer kx, ky);
    recon_attr = rnd_recip(W0 + kx*dWdx + ky*dWdy, area_recip);
  endfunction

  integer kx, ky, nsamp, errs, i;
  longint ruu, rvv, itu, itv, tw1, th1;
  integer d;

  // check one pixel: golden must be covered, reconstruction within +-1.
  task check_pixel; input [15:0] X, Y; begin
    px = X; py = Y; #1;               // settle combinational golden
    if (g_hit) begin
      kx = X - ox; ky = Y - oy;
      // colours are 8-bit direct attributes
      d = recon_attr(Wr_0,dWrdx,dWrdy,kx,ky) - g_cr; if (d<0) d=-d; if (d>1) begin errs=errs+1; $display("FAIL @(%0d,%0d) cr rec=%0d gold=%0d",X,Y,recon_attr(Wr_0,dWrdx,dWrdy,kx,ky),g_cr); end
      d = recon_attr(Wg_0,dWgdx,dWgdy,kx,ky) - g_cg; if (d<0) d=-d; if (d>1) begin errs=errs+1; $display("FAIL @(%0d,%0d) cg rec=%0d gold=%0d",X,Y,recon_attr(Wg_0,dWgdx,dWgdy,kx,ky),g_cg); end
      d = recon_attr(Wb_0,dWbdx,dWbdy,kx,ky) - g_cb; if (d<0) d=-d; if (d>1) begin errs=errs+1; $display("FAIL @(%0d,%0d) cb rec=%0d gold=%0d",X,Y,recon_attr(Wb_0,dWbdx,dWbdy,kx,ky),g_cb); end
      d = recon_attr(Wa_0,dWadx,dWady,kx,ky) - g_ca; if (d<0) d=-d; if (d>1) begin errs=errs+1; $display("FAIL @(%0d,%0d) ca rec=%0d gold=%0d",X,Y,recon_attr(Wa_0,dWadx,dWady,kx,ky),g_ca); end
      // u,v are 12.4; apply the SAME nearest-texel clamp as blt_tri, compare tu/tv
      ruu = recon_attr(Wu_0,dWudx,dWudy,kx,ky);
      rvv = recon_attr(Wv_0,dWvdx,dWvdy,kx,ky);
      itu = (ruu + 64'sd8) >>> 4; itv = (rvv + 64'sd8) >>> 4;
      tw1 = TEX_W-1; th1 = TEX_H-1;
      if (itu<0) itu=0; else if (itu>tw1) itu=tw1;
      if (itv<0) itv=0; else if (itv>th1) itv=th1;
      d = itu - g_tu; if (d<0) d=-d; if (d>1) begin errs=errs+1; $display("FAIL @(%0d,%0d) tu rec=%0d gold=%0d",X,Y,itu,g_tu); end
      d = itv - g_tv; if (d<0) d=-d; if (d>1) begin errs=errs+1; $display("FAIL @(%0d,%0d) tv rec=%0d gold=%0d",X,Y,itv,g_tv); end
      nsamp = nsamp + 1;
    end
  end endtask

  initial begin : main
    // watchdog
    fork begin #100000; $display("RESULT: FAIL (TIMEOUT)"); $finish; end join_none

    errs=0; nsamp=0;
    @(negedge clk); start<=1; @(negedge clk); start<=0;
    // wait for setup to present registered outputs
    i=0; while (!valid && i<20) begin @(negedge clk); i=i+1; end
    if (!valid) begin $display("RESULT: FAIL (setup never asserted valid)"); $finish; end
    if (degenerate) begin $display("RESULT: FAIL (setup flagged degenerate on a valid triangle)"); $finish; end

    $display("setup: area=%0d area_recip=%0d origin=(%0d,%0d)", area, area_recip, ox, oy);

    // sweep the whole bbox (verts span x 100..180, y 80..170); check_pixel only
    // counts pixels the golden covers, so we always sample true INTERIOR pixels.
    // Sub-sample by 3 to spread coverage without exercising every pixel.
    for (ky=0; ky<=92; ky=ky+3)
      for (kx=0; kx<=84; kx=kx+3)
        check_pixel(ox + kx, oy + ky);

    if (nsamp < 8) begin
      $display("RESULT: FAIL (only %0d covered samples; need >=8)", nsamp);
      $finish;
    end
    if (errs==0) $display("RESULT: PASS (%0d covered pixels within +-1 of golden)", nsamp);
    else         $display("RESULT: FAIL (%0d mismatches over %0d covered pixels)", errs, nsamp);
    $finish;
  end
endmodule
`default_nettype wire
