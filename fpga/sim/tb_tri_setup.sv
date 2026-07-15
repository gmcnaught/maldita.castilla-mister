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
// (<= |W|*0.5/2^SHIFT) far below the +-1 tolerance across the validated
// envelope (see the "envelope_worst_case" case below and the doc block in
// blt_tri_setup.sv).
//
// Four triangle cases (all vertices/attrs driven through regs so the same
// golden+dut instances are reused, one case at a time, via run_case()):
//   1. ccw_baseline        — CCW winding (area>0), the original fixed triangle.
//   2. cw_swap_negative_area — CW winding (signed area<0) so blt_tri_setup's
//      vertex-swap CCW-normalize path (blt_tri_setup.sv:89-94) actually runs;
//      distinct per-vertex u,v,r,g,b,a from case 1.
//   3. degenerate_collinear — three collinear vertices (area==0): asserts
//      degenerate==1 and that the den==0 guard holds (area_recip well-defined,
//      no div-by-zero X-propagation).
//   4. envelope_worst_case — near-full-screen triangle (~300x220px) over a
//      wide (2048x2048) texture, u/v near 32768 in 12.4: the real worst case
//      for the SHIFT=40 reciprocal's quantization error and for edge-function
//      product width (see blt_tri_setup.sv field-width comments).
//
// Copyright (C) 2026 — GPL-3.0.
`timescale 1ns/1ps
`default_nettype none
module tb_tri_setup;
  localparam integer SHIFT = 40;   // must match blt_tri_setup's fixed-point shift

  reg clk=0; always #5 clk=~clk;

  // ---- triangle under test: driven per-case by run_case() below, so the same
  //      golden + dut instances are reused across all four cases. ----
  reg signed [15:0] VX0, VY0, VX1, VY1, VX2, VY2;
  reg        [15:0] VU0, VV0, VU1, VV1, VU2, VV2;
  reg        [7:0]  VR0, VG0, VB0, VA0;
  reg        [7:0]  VR1, VG1, VB1, VA1;
  reg        [7:0]  VR2, VG2, VB2, VA2;
  reg        [15:0] TEX_W, TEX_H;

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
  wire signed [47:0] w0_0, w1_0, w2_0;
  wire signed [47:0] dw0dx, dw1dx, dw2dx, dw0dy, dw1dy, dw2dy;
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
  integer total_errs;

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

  // run one full triangle case: load verts+attrs into the shared regs, pulse
  // start, wait for valid, check degenerate against expectation, and (unless
  // expect_degen) sweep the bbox asserting reconstruction vs golden. $finish's
  // with RESULT: FAIL on any problem so a case failure aborts the whole run.
  task automatic run_case;
    input [8*32:1] case_name;
    input signed [15:0] ax,ay,bx,by,cx,cy;
    input [15:0] au,avv,bu,bv,cu,cv;
    input [7:0] car,cag,cab,caa;
    input [7:0] cbr,cbg,cbb,cba;
    input [7:0] ccr_,ccg_,ccb_,cca_;
    input [15:0] tw_, th_;
    input integer bbox_w, bbox_h, stride;
    input expect_degen;
    integer wi;
    begin
      VX0=ax; VY0=ay; VX1=bx; VY1=by; VX2=cx; VY2=cy;
      VU0=au; VV0=avv; VU1=bu; VV1=bv; VU2=cu; VV2=cv;
      VR0=car; VG0=cag; VB0=cab; VA0=caa;
      VR1=cbr; VG1=cbg; VB1=cbb; VA1=cba;
      VR2=ccr_; VG2=ccg_; VB2=ccb_; VA2=cca_;
      TEX_W=tw_; TEX_H=th_;

      errs = 0; nsamp = 0;
      @(negedge clk); start<=1; @(negedge clk); start<=0;
      wi=0; while (!valid && wi<20) begin @(negedge clk); wi=wi+1; end
      if (!valid) begin
        $display("RESULT: FAIL (%0s: setup never asserted valid)", case_name);
        $finish;
      end

      if (expect_degen) begin
        if (!degenerate) begin
          $display("RESULT: FAIL (%0s: expected degenerate==1, got 0)", case_name);
          $finish;
        end
        // guard check: den==0 must not have produced an X-propagated / bogus
        // reciprocal. den is forced to 1 internally when n_area==0, so
        // area_recip must equal round(2^SHIFT/1) == 2^SHIFT exactly, and must
        // be a known (non-X) value.
        if (^area_recip === 1'bx) begin
          $display("RESULT: FAIL (%0s: area_recip is X after degenerate divide-by-zero guard)", case_name);
          $finish;
        end
        if (area_recip !== (48'sd1 <<< SHIFT)) begin
          $display("RESULT: FAIL (%0s: area_recip=%0d, expected 2^SHIFT=%0d under den==1 guard)",
                    case_name, area_recip, (48'sd1 <<< SHIFT));
          $finish;
        end
        $display("case %0s: PASS (degenerate=1, area=%0d, guarded area_recip=%0d)",
                  case_name, area, area_recip);
      end else begin
        if (degenerate) begin
          $display("RESULT: FAIL (%0s: unexpected degenerate==1 on a non-degenerate triangle)", case_name);
          $finish;
        end
        $display("case %0s: area=%0d area_recip=%0d origin=(%0d,%0d)", case_name, area, area_recip, ox, oy);
        for (ky=0; ky<=bbox_h; ky=ky+stride)
          for (kx=0; kx<=bbox_w; kx=kx+stride)
            check_pixel(ox + kx, oy + ky);
        if (nsamp < 8) begin
          $display("RESULT: FAIL (%0s: only %0d covered samples; need >=8)", case_name, nsamp);
          $finish;
        end
        if (errs==0) begin
          $display("case %0s: PASS (%0d covered pixels within +-1 of golden)", case_name, nsamp);
        end else begin
          $display("RESULT: FAIL (%0s: %0d mismatches over %0d covered pixels)", case_name, errs, nsamp);
          $finish;
        end
      end
      total_errs = total_errs + errs;
    end
  endtask

  initial begin : main
    // watchdog
    fork begin #100000; $display("RESULT: FAIL (TIMEOUT)"); $finish; end join_none

    total_errs = 0;

    // ---- case 1: CCW baseline (area>0). Original fixed triangle: DISTINCT
    //      per-vertex u,v AND r,g,b,a so the barycentric interpolation is
    //      actually exercised. Screen coords 12.4 (pixel*16); u,v 12.4 texel
    //      over an 8x8 texture (texel 0..7 -> 0..112).
    //   v0 (100,80)  u=0    v=0    rgba=( 30,200, 10,255)
    //   v1 (180,90)  u=112  v=0    rgba=(240, 20, 60,200)
    //   v2 (130,170) u=16   v=112  rgba=( 80,120,220,100)
    run_case("ccw_baseline",
      16'sd1600,16'sd1280, 16'sd2880,16'sd1440, 16'sd2080,16'sd2720,
      16'd0,16'd0, 16'd112,16'd0, 16'd16,16'd112,
      8'd30,8'd200,8'd10,8'd255,
      8'd240,8'd20,8'd60,8'd200,
      8'd80,8'd120,8'd220,8'd100,
      16'd8,16'd8,
      84,92,3, 1'b0);

    // ---- case 2: CW winding (signed area<0), so blt_tri_setup's vertex-swap
    //      normalize path runs. v0=(60,60), v1=(60,140), v2=(140,60): going
    //      v0->v1->v2 is clockwise on screen (edgef<0), unlike case 1's CCW
    //      order. Distinct per-vertex u,v,r,g,b,a from case 1.
    run_case("cw_swap_negative_area",
      16'sd960,16'sd960, 16'sd960,16'sd2240, 16'sd2240,16'sd960,
      16'd0,16'd0, 16'd112,16'd0, 16'd64,16'd112,
      8'd10,8'd50,8'd200,8'd255,
      8'd250,8'd5,8'd5,8'd150,
      8'd0,8'd255,8'd128,8'd80,
      16'd8,16'd8,
      80,80,3, 1'b0);

    // ---- case 3: degenerate (collinear vertices, area==0). v0=(50,50),
    //      v1=(100,100), v2=(150,150) all lie on y==x: signed area is exactly
    //      0. Asserts degenerate==1 and that the den==0 guard (n_area==0 ->
    //      den forced to 1) produced a defined, non-divide-by-zero reciprocal.
    run_case("degenerate_collinear",
      16'sd800,16'sd800, 16'sd1600,16'sd1600, 16'sd2400,16'sd2400,
      16'd0,16'd0, 16'd0,16'd0, 16'd0,16'd0,
      8'd0,8'd0,8'd0,8'd0,
      8'd0,8'd0,8'd0,8'd0,
      8'd0,8'd0,8'd0,8'd0,
      16'd8,16'd8,
      0,0,1, 1'b1);

    // ---- case 4: envelope worst-case. Near-full-screen triangle (~300x220px:
    //      v0=(10,10), v1=(310,10), v2=(160,230), all well within the 16-bit-
    //      signed 12.4 vertex range) sampling a WIDE texture (2048x2048, u/v up
    //      to ~2047 texels == ~32752 in 12.4). Signed (x16-scaled) area here is
    //      ~1.7e7 — the real worst case for both the SHIFT=40 reciprocal's
    //      quantization error and the widened edge-function field width (see
    //      blt_tri_setup.sv). Distinct per-vertex attrs.
    run_case("envelope_worst_case",
      16'sd160,16'sd160, 16'sd4960,16'sd160, 16'sd2560,16'sd3680,
      16'd0,16'd0, 16'd32752,16'd0, 16'd0,16'd32752,
      8'd5,8'd250,8'd15,8'd255,
      8'd250,8'd5,8'd250,8'd1,
      8'd0,8'd128,8'd0,8'd128,
      16'd2048,16'd2048,
      300,220,7, 1'b0);

    if (total_errs==0) $display("RESULT: PASS (4 triangle cases: ccw_baseline, cw_swap_negative_area, degenerate_collinear, envelope_worst_case)");
    else               $display("RESULT: FAIL (%0d total mismatches across cases)", total_errs);
    $finish;
  end
endmodule
`default_nettype wire
