// tb_surfram.sv — Task 6: off-screen BRAM surface + BLT_OP_SET_TARGET target-select.
//
// Proves the composite write/read routes to an independent off-screen surface bank
// when the active render target is APPSURF, and to the WORK bank otherwise, with the
// two banks fully independent.
//
// Ring (single frame, no CLEAR flag):
//   cmd0  SET_TARGET APPSURF          -> comp_target = APPSURF
//   cmd1  FILL magentaA rect 64x48@(0,0)  -> writes the SURFACE bank
//   cmd2  SET_TARGET WORK             -> comp_target = WORK
//   cmd3  FILL greenB   rect 64x48@(0,0)  -> writes the WORK bank (SAME rect)
//   cmd4  END
//
// Both banks are pre-filled with DISTINCT junk. Independence assertions:
//   surface[rect]   == magentaA          (surface FILL landed on surface)
//   surface[outside]== JUNK_S            (surface FILL only hit the rect; WORK FILL never leaked here)
//   work[rect]      == greenB            (WORK FILL landed on work — NOT the surface's magenta)
//   work[outside]   == JUNK_W            (WORK FILL only hit the rect; surface FILL never leaked here)
`timescale 1ns/1ps
`default_nettype none
`include "blitter_defs.vh"
module tb_surfram;
  localparam [28:0] WBASE = 29'h07400000;
  localparam        MEMQW = (`SRC_QW - 29'h07400000) + 29'h10000;
  localparam [15:0] MAGENTA = 16'hF81F, GREEN = 16'h07E0;
  localparam [15:0] JUNK_W = 16'hA5A5, JUNK_S = 16'h5A5A;
  localparam integer RW = 64, RH = 48;   // fill rect

  reg clk=0, rst=1; always #5 clk=~clk;
  reg vs=0; always #1000 vs=~vs;   // free-running vblank so the per-frame snapshot fires
  wire [31:0] bt_addr; wire b_rd, b_we; wire [63:0] b_din; wire [7:0] b_be; wire bt_idle;
  wire [7:0] bt_burst;
  reg  d_dready; reg [63:0] d_dout;
  reg [63:0] mem [0:MEMQW-1];
  reg [7:0] rbeats; reg [28:0] raddr; reg [2:0] rlat; reg [1:0] bp=0;
  always @(posedge clk) bp <= bp+2'd1;
  wire d_busy = (bp != 2'd2) | (rbeats != 8'd0) | (rlat != 3'd0);
  integer i;

  // P_SRC tied off: FILL never reads a source.
  wire [26:0] s_src_addr; wire s_src_rd;

  // on-chip dest framebuffer [FB-in-BRAM] + off-screen surface (Task 6)
  wire fb_wr_en; wire [14:0] fb_wr_qw; wire [1:0] fb_wr_lane; wire [15:0] fb_wr_pix;
  wire fb_rd_en; wire [14:0] fb_rd_qw; wire [63:0] fb_rd_qword;
  wire sf_wr_en; wire [14:0] sf_wr_qw; wire [1:0] sf_wr_lane; wire [15:0] sf_wr_pix;
  wire sf_rd_en; wire [14:0] sf_rd_qw; wire [63:0] sf_rd_qword;
  comp_fbram fbram(.clk(clk),
    .wr_en(fb_wr_en), .wr_qw(fb_wr_qw), .wr_lane(fb_wr_lane), .wr_pix(fb_wr_pix),
    .rd_en(fb_rd_en), .rd_qw(fb_rd_qw), .rd_qword(fb_rd_qword),
    .scan_rd_en(1'b0), .scan_rd_qw(15'd0), .scan_rd_qword(),
    .surf_wr_en(sf_wr_en), .surf_wr_qw(sf_wr_qw), .surf_wr_lane(sf_wr_lane), .surf_wr_pix(sf_wr_pix),
    .surf_rd_en(sf_rd_en), .surf_rd_qw(sf_rd_qw), .surf_rd_qword(sf_rd_qword));

  blitter_top blt(.clk(clk), .rst(rst), .vs(vs),
    .mem_addr(bt_addr), .mem_rd(b_rd), .mem_wr(b_we), .mem_burstcnt(bt_burst),
    .mem_din(b_din), .mem_be(b_be),
    .mem_dout(d_dout), .mem_dout_ready(d_dready), .mem_busy(d_busy),
    .p0_addr(s_src_addr), .p0_rd(s_src_rd), .p0_dout(64'd0), .p0_ok(1'b0),
    .fb_wr_en(fb_wr_en), .fb_wr_qw(fb_wr_qw), .fb_wr_lane(fb_wr_lane), .fb_wr_pix(fb_wr_pix),
    .fb_rd_en(fb_rd_en), .fb_rd_qw(fb_rd_qw), .fb_rd_qword(fb_rd_qword),
    .surf_wr_en(sf_wr_en), .surf_wr_qw(sf_wr_qw), .surf_wr_lane(sf_wr_lane), .surf_wr_pix(sf_wr_pix),
    .surf_rd_en(sf_rd_en), .surf_rd_qw(sf_rd_qw), .surf_rd_qword(sf_rd_qword),
    .idle(bt_idle));

  always @(posedge clk) begin
    d_dready <= 1'b0; d_dout <= 64'hDEAD_BEEF_DEAD_BEEF;
    if (rst) begin rbeats<=0; rlat<=0; end
    else begin
      if (rlat!=3'd0) rlat<=rlat-3'd1;
      else if (rbeats!=8'd0) begin
        if (bp==2'd2) begin d_dout<=mem[raddr-WBASE]; d_dready<=1'b1; raddr<=raddr+29'd1; rbeats<=rbeats-8'd1; end
      end else if (!d_busy) begin
        if (b_rd) begin rbeats<=bt_burst; raddr<=bt_addr[28:0]; rlat<=3'd3; end
        else if (b_we) for(i=0;i<8;i=i+1) if(b_be[i]) mem[(bt_addr[28:0]-WBASE)][i*8 +:8]<=b_din[i*8 +:8];
      end
    end
  end

  integer errs=0, to, qw, lane;
  function [15:0] getwork(input integer dx, input integer dy);
    begin
      qw = dy*80 + (dx>>2); lane = dx & 3;
      getwork = (lane==0) ? fbram.bank0[qw] : (lane==1) ? fbram.bank1[qw] :
                (lane==2) ? fbram.bank2[qw] : fbram.bank3[qw];
    end
  endfunction
  function [15:0] getsurf(input integer dx, input integer dy);
    begin
      qw = dy*80 + (dx>>2); lane = dx & 3;
      getsurf = (lane==0) ? fbram.surf_bank0[qw] : (lane==1) ? fbram.surf_bank1[qw] :
                (lane==2) ? fbram.surf_bank2[qw] : fbram.surf_bank3[qw];
    end
  endfunction
  task ckwork(input integer dx, input integer dy, input [15:0] exp, input [127:0] tag);
    reg [15:0] got; begin got=getwork(dx,dy);
      if (got!==exp) begin errs=errs+1; $display("  WORK MISMATCH %0s (%0d,%0d): got %h exp %h",tag,dx,dy,got,exp); end
    end
  endtask
  task cksurf(input integer dx, input integer dy, input [15:0] exp, input [127:0] tag);
    reg [15:0] got; begin got=getsurf(dx,dy);
      if (got!==exp) begin errs=errs+1; $display("  SURF MISMATCH %0s (%0d,%0d): got %h exp %h",tag,dx,dy,got,exp); end
    end
  endtask

  // Pre-fill WORK and SURFACE with DISTINCT junk so a routing bug is detectable.
  task junkfill; begin
    for(i=0;i<`FB_QWORDS;i=i+1) begin
      fbram.bank0[i]=JUNK_W; fbram.bank1[i]=JUNK_W; fbram.bank2[i]=JUNK_W; fbram.bank3[i]=JUNK_W;
      fbram.surf_bank0[i]=JUNK_S; fbram.surf_bank1[i]=JUNK_S; fbram.surf_bank2[i]=JUNK_S; fbram.surf_bank3[i]=JUNK_S;
    end
  end endtask

  task await_submit(input [31:0] n);
    begin
      to=0; while(mem[32'h200005][31:0]!==n && to<3000000) begin @(posedge clk); to=to+1; end
      repeat(10) @(posedge clk);
    end
  endtask

  initial begin
    for(i=0;i<MEMQW;i=i+1) mem[i]=64'd0;
    mem[32'h200007]=64'd2;   // C_PIPE
    junkfill;

    // ---- control block ----
    mem[32'h200000]=64'd0;   // submit (set last)
    mem[32'h200001]=64'd5;   // cmd_count = 5
    mem[32'h200002]=64'd0;   // C_TARGET = 0 (frame default WORK)
    mem[32'h200003]=64'd0;   // clear_color (unused)
    mem[32'h200004]=64'd0;   // flags = 0 (NO CLEAR)
    mem[32'h200005]=64'd0;   // done=0

    // cmd0 @ 0x200008: SET_TARGET APPSURF (op=11, target id in c_color = cmd_qw[3][47:32])
    mem[32'h200008]=64'h0000_0000_0000_000B;              // op=SET_TARGET(11)
    mem[32'h200009]=64'd0;
    mem[32'h20000A]=64'd0;
    mem[32'h20000B]={16'd0, 16'd2, 32'd0};                // color = BLT_TARGET_APPSURF(2)
    // cmd1 @ 0x20000C: FILL magenta rect RWxRH @ (0,0)
    mem[32'h20000C]=64'h0000_0000_0000_0002;              // op=FILL
    mem[32'h20000D]={16'(RH),16'(RW),32'd0};              // h,w
    mem[32'h20000E]={16'd0,16'd0,32'd0};                  // dst_y=0,dst_x=0
    mem[32'h20000F]={16'd0,MAGENTA,32'd0};                // color=magenta
    // cmd2 @ 0x200010: SET_TARGET WORK
    mem[32'h200010]=64'h0000_0000_0000_000B;              // op=SET_TARGET(11)
    mem[32'h200011]=64'd0;
    mem[32'h200012]=64'd0;
    mem[32'h200013]={16'd0, 16'd0, 32'd0};                // color = BLT_TARGET_WORK(0)
    // cmd3 @ 0x200014: FILL green rect RWxRH @ (0,0)  (SAME rect)
    mem[32'h200014]=64'h0000_0000_0000_0002;              // op=FILL
    mem[32'h200015]={16'(RH),16'(RW),32'd0};
    mem[32'h200016]={16'd0,16'd0,32'd0};
    mem[32'h200017]={16'd0,GREEN,32'd0};                  // color=green
    // cmd4 @ 0x200018: END
    mem[32'h200018]=64'd1;

    repeat(8) @(posedge clk); rst<=0;
    mem[32'h200000]=64'd1;   // submit=1
    await_submit(32'd1);
    $display("=== tb_surfram (to=%0d) ===", to);

    // SURFACE: rect == magenta, outside == JUNK_S (untouched by the WORK fill)
    cksurf(0,0,     MAGENTA, "surf-tl");   cksurf(RW-1,RH-1, MAGENTA, "surf-br");
    cksurf(32,24,   MAGENTA, "surf-mid");
    cksurf(RW,0,    JUNK_S,  "surf-out-x"); cksurf(0,RH,     JUNK_S,  "surf-out-y");
    cksurf(319,239, JUNK_S,  "surf-out-far");
    // WORK: rect == green (NOT magenta), outside == JUNK_W
    ckwork(0,0,     GREEN,   "work-tl");   ckwork(RW-1,RH-1, GREEN,   "work-br");
    ckwork(32,24,   GREEN,   "work-mid");
    ckwork(RW,0,    JUNK_W,  "work-out-x"); ckwork(0,RH,     JUNK_W,  "work-out-y");
    ckwork(319,239, JUNK_W,  "work-out-far");

    if (errs==0) $display("RESULT: PASS"); else $display("RESULT: FAIL (errs=%0d)", errs);
    $finish;
  end
  initial begin #80000000 $display("RESULT: FAIL (timeout)"); $finish; end
endmodule
`default_nettype wire
