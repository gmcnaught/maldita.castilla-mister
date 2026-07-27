// tb_blitter_surface_src.sv — Task 7: BLT_OP_TRILIST texel sample-surface-as-texture.
//
// Backdoor-loads a known image into comp_fbram's off-screen surface bank, then submits
// a CLEAR(blue) + a fullscreen TRILIST carrying BLT_F_SRC_SURFACE (+BLEND_COPY) targeting
// WORK, and diffs the ENTIRE composited WORK bank against vectors/tri_surface_exp.hex
// (`FB_PIXELS RGB565 px) within +-1 LSB per channel.
//
// The scene (vectors/tri_surface_*.hex, from gen_tri_golden.c) uses a fullscreen quad
// whose UV == position, so destination pixel (px,py) samples surface texel (px+1,py+1)
// (the rasterizer's existing +1 sample-point convention), clamped to the fixed `FB_W x `FB_H (288x216)
// surface extent. The golden (blt_raster_tri, 6-arg surface path) is bit-exact to the
// engine reference; this proves the RTL surface texel-fetch matches it.
`timescale 1ns/1ps
`default_nettype none
`include "blitter_defs.vh"
module tb_blitter_surface_src;
  localparam [28:0] WBASE = 29'h07400000;
  localparam        MEMQW = (`SRC_QW - 29'h07400000) + 29'h8000;

  reg clk=0, rst=1; always #5 clk=~clk;

  wire [31:0] bt_addr; wire b_rd, b_we; wire [63:0] b_din; wire [7:0] b_be; wire bt_idle;
  reg  d_dready; reg [63:0] d_dout;

  // behavioral DDR: single-beat reads w/ latency + backpressure (clone of trilist_pipe).
  reg [63:0] mem [0:MEMQW-1];
  reg [7:0] rbeats; reg [28:0] raddr; reg [2:0] rlat; reg [1:0] bp=0;
  always @(posedge clk) bp <= bp+2'd1;
  wire d_busy = (bp != 2'd2) | (rbeats != 8'd0) | (rlat != 3'd0);
  integer i;

  // ── P_SRC cache-ok source model: trivial always-ready, returns 0. The surface
  // texel path issues NO p0 reads; this only keeps the PRE-implementation RTL (which
  // still samples SDRAM) from hanging — it reads 0 and mismatches, a clean FAIL. ──
  wire [26:0] s_src_addr; wire s_src_rd;
  reg  [63:0] s_src_dout=64'd0; reg s_src_ok=1'b0; reg s_rd_d=1'b0;
  always @(posedge clk) begin
    s_rd_d    <= s_src_rd;
    s_src_ok  <= s_src_rd & ~s_rd_d;   // 1-cycle ok after each read pulse
    s_src_dout<= 64'd0;
  end

  wire [7:0] bt_burst;
  wire fb_wr_en; wire [14:0] fb_wr_qw; wire [1:0] fb_wr_lane; wire [15:0] fb_wr_pix;
  wire fb_rd_en; wire [14:0] fb_rd_qw; wire [63:0] fb_rd_qword;
  wire sf_wr_en; wire [14:0] sf_wr_qw; wire [1:0] sf_wr_lane; wire [15:0] sf_wr_pix;
  wire sf_rd_en; wire [14:0] sf_rd_qw; wire [63:0] sf_rd_qword;
  comp_fbram fbram(.clk(clk),
    .wr_en(fb_wr_en), .wr_qw(fb_wr_qw), .wr_lane(fb_wr_lane), .wr_pix(fb_wr_pix),
    .rd_en(fb_rd_en), .rd_qw(fb_rd_qw), .rd_qword(fb_rd_qword),
    .surf_wr_en(sf_wr_en), .surf_wr_qw(sf_wr_qw), .surf_wr_lane(sf_wr_lane), .surf_wr_pix(sf_wr_pix),
    .surf_rd_en(sf_rd_en), .surf_rd_qw(sf_rd_qw), .surf_rd_qword(sf_rd_qword));
  blitter_top blt(.clk(clk), .rst(rst),
    .mem_addr(bt_addr), .mem_rd(b_rd), .mem_wr(b_we), .mem_burstcnt(bt_burst),
    .mem_din(b_din), .mem_be(b_be),
    .mem_dout(d_dout), .mem_dout_ready(d_dready), .mem_busy(d_busy),
    .p0_addr(s_src_addr), .p0_rd(s_src_rd), .p0_dout(s_src_dout), .p0_ok(s_src_ok),
    .fb_wr_en(fb_wr_en), .fb_wr_qw(fb_wr_qw), .fb_wr_lane(fb_wr_lane), .fb_wr_pix(fb_wr_pix),
    .fb_rd_en(fb_rd_en), .fb_rd_qw(fb_rd_qw), .fb_rd_qword(fb_rd_qword),
    .surf_wr_en(sf_wr_en), .surf_wr_qw(sf_wr_qw), .surf_wr_lane(sf_wr_lane), .surf_wr_pix(sf_wr_pix),
    .surf_rd_en(sf_rd_en), .surf_rd_qw(sf_rd_qw), .surf_rd_qword(sf_rd_qword),
    .idle(bt_idle));

  always @(posedge clk) begin
    d_dready <= 1'b0;
    d_dout   <= 64'hDEAD_BEEF_DEAD_BEEF;
    if (rst) begin rbeats<=0; rlat<=0; end
    else begin
      if (rlat != 3'd0) rlat <= rlat - 3'd1;
      else if (rbeats != 8'd0) begin
        if (bp == 2'd2) begin
          d_dout <= mem[raddr-WBASE]; d_dready <= 1'b1;
          raddr <= raddr + 29'd1; rbeats <= rbeats - 8'd1;
        end
      end else if (!d_busy) begin
        if (b_rd) begin rbeats<=bt_burst; raddr<=bt_addr[28:0]; rlat<=3'd3; end
        else if (b_we) for(i=0;i<8;i=i+1) if(b_be[i]) mem[(bt_addr[28:0]-WBASE)][i*8 +:8]<=b_din[i*8 +:8];
      end
    end
  end

  // ── golden framebuffer + surface source image ────────────────────────────────
  reg [15:0] exp     [0:`FB_PIXELS-1];
  reg [15:0] surfimg [0:`FB_PIXELS-1];

  integer x,y,idx,bad,sidx;
  reg [15:0] got, e;
  function integer chan_ok(input [15:0] a, input [15:0] b);
    integer dr,dg,db;
    begin
      dr = a[15:11] - b[15:11]; if (dr<0) dr=-dr;
      dg = a[10:5]  - b[10:5];  if (dg<0) dg=-dg;
      db = a[4:0]   - b[4:0];   if (db<0) db=-db;
      chan_ok = (dr<=1) && (dg<=1) && (db<=1);
    end
  endfunction

  initial begin
    for(i=0;i<MEMQW;i=i+1) mem[i]=64'd0;
    $readmemh("vectors/tri_surface_ddr.hex", mem);
    $readmemh("vectors/tri_surface_exp.hex", exp);
    $readmemh("vectors/tri_surface_surf.hex", surfimg);
    // backdoor-load the surface bank with the golden's surface image (linear -> qword/lane)
    for (y=0;y<`FB_H;y=y+1) for (x=0;x<`FB_W;x=x+1) begin
      sidx = y*`FB_STRIDE_QW + (x>>2);
      case (x&3)
        2'd0: fbram.surf_bank0[sidx] = surfimg[y*`FB_W+x];
        2'd1: fbram.surf_bank1[sidx] = surfimg[y*`FB_W+x];
        2'd2: fbram.surf_bank2[sidx] = surfimg[y*`FB_W+x];
        2'd3: fbram.surf_bank3[sidx] = surfimg[y*`FB_W+x];
      endcase
    end
  end

  integer to;
  initial begin
    repeat(8) @(posedge clk); rst<=0;
    to=0;
    while (mem[32'h200005][31:0] !== mem[32'h200000][31:0] && to<4000000) begin @(posedge clk); to=to+1; end
    repeat(10) @(posedge clk);
    $display("=== done_seq=%0d submit=%0d (to=%0d) ===", mem[32'h200005][31:0], mem[32'h200000][31:0], to);

    bad=0;
    for (y=0;y<`FB_H;y=y+1) for (x=0;x<`FB_W;x=x+1) begin
      idx = y*`FB_STRIDE_QW + (x>>2);
      got = ((x&3)==0) ? fbram.bank0[idx] : ((x&3)==1) ? fbram.bank1[idx] :
            ((x&3)==2) ? fbram.bank2[idx] : fbram.bank3[idx];
      e   = exp[y*`FB_W+x];
      // Golden-short trap: an entry past the end of the loaded vectors/*.hex reads
      // back x; x propagates through chan_ok and Verilog treats the resulting x as
      // FALSE, so the pixel would be silently NOT compared. That is exactly how this
      // bench passed vacuously before the geometry root landed — if FB_W/FB_H move
      // without regenerating vectors, fail loudly instead of re-opening the hole.
      if (e === 16'hxxxx) begin
        bad=bad+1;
        if (bad<=20) $display("  GOLDEN SHORT at (%0d,%0d) — vectors not regenerated for this canvas?", x,y);
      end
      else if (!chan_ok(got,e)) begin
        bad=bad+1;
        if (bad<=20) $display("  MISMATCH (%0d,%0d): got %04h exp %04h", x,y,got,e);
      end
    end
    $display("=== bad pixels = %0d / %0d ===", bad, `FB_PIXELS);
    if (mem[32'h200005][31:0]==mem[32'h200000][31:0] && bad==0) $display("RESULT: PASS");
    else $display("RESULT: FAIL (bad=%0d)", bad);
    $finish;
  end
  initial begin #200000000 $display("RESULT: FAIL (timeout)"); $finish; end
endmodule
`default_nettype wire
