// tb_present_surf.sv — [present-from-surface] END.flags & BLT_F_SRC_SURFACE makes the
// frame-end DMA copy the APP-SURFACE bank instead of WORK.
//
// blitter_top + comp_fbram + fb_dma_src_mux + comp_fb_dma, wired as in Maldita.sv, with a
// DDR sink for the DMA and a reader model that adopts every published buffer at once.
//
// Ring (both frames): SET_TARGET APPSURF, FILL magenta 64x48@(0,0), SET_TARGET WORK,
// FILL green 64x48@(0,0), END. Banks pre-filled with distinct junk.
//   Frame 1: END.flags = 0x80  -> DMA'd buffer == SURFACE (magenta rect, JUNK_S elsewhere)
//   Frame 2: END.flags = 0x00  -> DMA'd buffer == WORK    (green rect,   JUNK_W elsewhere)
// Every qword of the frame is compared, so a lane/offset slip in the mux is caught.
`timescale 1ns/1ps
`default_nettype none
`include "blitter_defs.vh"
module tb_present_surf;
  localparam [28:0] WBASE = 29'h07400000;
  localparam        MEMQW = (`SRC_QW - 29'h07400000) + 29'h10000;
  localparam [15:0] MAGENTA = 16'hF81F, GREEN = 16'h07E0;
  localparam [15:0] JUNK_W = 16'hA5A5, JUNK_S = 16'h5A5A;
  localparam integer RW = 64, RH = 48;
  localparam integer NQW = `FB_QWORDS;
  localparam [31:0] BUF0 = 32'd8, BUF1 = 32'd8 + 32'h8000;
  reg clk=0, rst=1; always #5 clk=~clk;
  reg vs=0; always #1000 vs=~vs;
  wire [31:0] bt_addr; wire b_rd, b_we; wire [63:0] b_din; wire [7:0] b_be; wire bt_idle;
  wire [7:0] bt_burst;
  reg  d_dready; reg [63:0] d_dout;
  reg [63:0] mem [0:MEMQW-1];
  reg [7:0] rbeats; reg [28:0] raddr; reg [2:0] rlat; reg [1:0] bp=0;
  always @(posedge clk) bp <= bp+2'd1;
  wire d_busy = (bp != 2'd2) | (rbeats != 8'd0) | (rlat != 3'd0);
  integer i;
  wire [26:0] s_src_addr; wire s_src_rd;

  // comp_fbram + the Maldita.sv read-port arbitration
  wire fb_wr_en; wire [14:0] fb_wr_qw; wire [1:0] fb_wr_lane; wire [15:0] fb_wr_pix;
  wire fb_rd_en; wire [14:0] fb_rd_qw; wire [63:0] fb_rd_qword;
  wire blt_fb_rd_en; wire [14:0] blt_fb_rd_qw;
  wire sf_wr_en; wire [14:0] sf_wr_qw; wire [1:0] sf_wr_lane; wire [15:0] sf_wr_pix;
  wire sf_rd_en; wire [14:0] sf_rd_qw; wire [63:0] sf_rd_qword;
  wire blt_sf_rd_en; wire [14:0] blt_sf_rd_qw;
  wire dma_start, dma_busy, dma_src_surf;
  wire dma_rd_en; wire [14:0] dma_rd_qw; wire [63:0] dma_rd_qword;
  comp_fbram fbram(.clk(clk),
    .wr_en(fb_wr_en), .wr_qw(fb_wr_qw), .wr_lane(fb_wr_lane), .wr_pix(fb_wr_pix),
    .rd_en(fb_rd_en), .rd_qw(fb_rd_qw), .rd_qword(fb_rd_qword),
    .surf_wr_en(sf_wr_en), .surf_wr_qw(sf_wr_qw), .surf_wr_lane(sf_wr_lane), .surf_wr_pix(sf_wr_pix),
    .surf_rd_en(sf_rd_en), .surf_rd_qw(sf_rd_qw), .surf_rd_qword(sf_rd_qword));
  fb_dma_src_mux mux(.dma_busy(dma_busy), .src_surf(dma_src_surf),
    .dma_rd_en(dma_rd_en), .dma_rd_qw(dma_rd_qw), .dma_rd_qword(dma_rd_qword),
    .blt_fb_rd_en(blt_fb_rd_en), .blt_fb_rd_qw(blt_fb_rd_qw),
    .blt_surf_rd_en(blt_sf_rd_en), .blt_surf_rd_qw(blt_sf_rd_qw),
    .fb_rd_en(fb_rd_en), .fb_rd_qw(fb_rd_qw), .fb_rd_qword(fb_rd_qword),
    .surf_rd_en(sf_rd_en), .surf_rd_qw(sf_rd_qw), .surf_rd_qword(sf_rd_qword));

  blitter_top blt(.clk(clk), .rst(rst), .vs(vs),
    .mem_addr(bt_addr), .mem_rd(b_rd), .mem_wr(b_we), .mem_burstcnt(bt_burst),
    .mem_din(b_din), .mem_be(b_be),
    .mem_dout(d_dout), .mem_dout_ready(d_dready), .mem_busy(d_busy),
    .p0_addr(s_src_addr), .p0_rd(s_src_rd), .p0_dout(64'd0), .p0_ok(1'b0),
    .fb_wr_en(fb_wr_en), .fb_wr_qw(fb_wr_qw), .fb_wr_lane(fb_wr_lane), .fb_wr_pix(fb_wr_pix),
    .fb_rd_en(blt_fb_rd_en), .fb_rd_qw(blt_fb_rd_qw), .fb_rd_qword(fb_rd_qword),
    .fb_dma_start(dma_start), .fb_dma_busy(dma_busy), .fb_dma_src_surf(dma_src_surf),
    .surf_wr_en(sf_wr_en), .surf_wr_qw(sf_wr_qw), .surf_wr_lane(sf_wr_lane), .surf_wr_pix(sf_wr_pix),
    .surf_rd_en(blt_sf_rd_en), .surf_rd_qw(blt_sf_rd_qw), .surf_rd_qword(sf_rd_qword),
    .idle(bt_idle));

  // comp_fb_dma -> DDR sink; reader adopts each published buffer immediately.
  reg reader_active = 1'b0;
  wire dmem_wr; wire [31:0] dmem_addr; wire [7:0] dmem_burst; wire [63:0] dmem_din; wire [7:0] dmem_be;
  comp_fb_dma #(.AW(15), .MAW(32)) dma(.clk(clk), .rst(rst),
    .start(dma_start), .busy(dma_busy), .fb_qw_base(29'd0), .disp_active(reader_active),
    .work_rd_en(dma_rd_en), .work_rd_qw(dma_rd_qw), .work_rd_qword(dma_rd_qword),
    .mem_wr(dmem_wr), .mem_addr(dmem_addr), .mem_burstcnt(dmem_burst),
    .mem_din(dmem_din), .mem_be(dmem_be), .mem_busy(1'b0));
  reg [63:0] ddr [0:32'h10000];
  reg [31:0] ctrl_writes = 0;
  always @(posedge clk) if (dmem_wr) begin
    if (dmem_addr == 32'd0) begin reader_active <= dmem_din[0]; ctrl_writes <= ctrl_writes + 1; end
    else ddr[dmem_addr] <= dmem_din;
  end

  // blitter DDR model (control block + ring), as tb_surfram
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

  integer errs=0, to, k, x, y, ln;
  function [15:0] expect_px(input integer px, input integer py, input integer from_surf);
    begin
      if (px < RW && py < RH) expect_px = from_surf ? MAGENTA : GREEN;
      else                    expect_px = from_surf ? JUNK_S  : JUNK_W;
    end
  endfunction
  task check_buf(input [31:0] base, input integer from_surf, input [127:0] tag);
    integer bad; reg [15:0] got, exp; begin
      bad = 0;
      for (k=0;k<NQW;k=k+1) for (ln=0;ln<4;ln=ln+1) begin
        x = (k % `FB_STRIDE_QW)*4 + ln; y = k / `FB_STRIDE_QW;
        got = ddr[base+k][ln*16 +: 16]; exp = expect_px(x, y, from_surf);
        if (got !== exp) begin
          if (bad < 4) $display("  MISMATCH %0s (%0d,%0d): got %h exp %h", tag, x, y, got, exp);
          bad = bad + 1;
        end
      end
      if (bad) begin errs = errs + 1; $display("  %0s: %0d pixels wrong", tag, bad); end
      else $display("  %0s: %0d qwords match", tag, NQW);
    end
  endtask

  task run_frame(input [31:0] n, input [7:0] end_flags);
    begin
      mem[32'h200018] = {32'd0, end_flags, 24'h000001};   // END, flags in byte 3
      mem[32'h200000] = n;
      to=0; while(mem[32'h200005][31:0]!==n && to<3000000) begin @(posedge clk); to=to+1; end
      to=0; while(ctrl_writes < n && to<3000000) begin @(posedge clk); to=to+1; end
      repeat(20) @(posedge clk);
    end
  endtask

  initial begin
    for(i=0;i<MEMQW;i=i+1) mem[i]=64'd0;
    for(i=0;i<32'h10000;i=i+1) ddr[i]=64'hFFFF_FFFF_FFFF_FFFF;
    mem[32'h200007]=64'd2;
    for(i=0;i<`FB_QWORDS;i=i+1) begin
      fbram.bank0[i]=JUNK_W; fbram.bank1[i]=JUNK_W; fbram.bank2[i]=JUNK_W; fbram.bank3[i]=JUNK_W;
      fbram.surf_bank0[i]=JUNK_S; fbram.surf_bank1[i]=JUNK_S; fbram.surf_bank2[i]=JUNK_S; fbram.surf_bank3[i]=JUNK_S;
    end
    mem[32'h200000]=64'd0; mem[32'h200001]=64'd5; mem[32'h200002]=64'd0;
    mem[32'h200003]=64'd0; mem[32'h200004]=64'd0; mem[32'h200005]=64'd0;
    mem[32'h200008]=64'h0000_0000_0000_000B; mem[32'h200009]=64'd0; mem[32'h20000A]=64'd0;
    mem[32'h20000B]={16'd0, 16'd2, 32'd0};
    mem[32'h20000C]=64'h0000_0000_0000_0002; mem[32'h20000D]={16'(RH),16'(RW),32'd0};
    mem[32'h20000E]={16'd0,16'd0,32'd0};     mem[32'h20000F]={16'd0,MAGENTA,32'd0};
    mem[32'h200010]=64'h0000_0000_0000_000B; mem[32'h200011]=64'd0; mem[32'h200012]=64'd0;
    mem[32'h200013]={16'd0, 16'd0, 32'd0};
    mem[32'h200014]=64'h0000_0000_0000_0002; mem[32'h200015]={16'(RH),16'(RW),32'd0};
    mem[32'h200016]={16'd0,16'd0,32'd0};     mem[32'h200017]={16'd0,GREEN,32'd0};

    repeat(8) @(posedge clk); rst<=0;
    $display("=== tb_present_surf ===");
    // Frame 1: presents the surface. reader_active starts 0 -> DMA writes BUF1.
    run_frame(32'd1, 8'h80);
    if (dma_src_surf !== 1'b1) begin errs=errs+1; $display("  fb_dma_src_surf=%b after flagged END (want 1)", dma_src_surf); end
    check_buf(BUF1, 1, "frame1-surface");
    // Frame 2: presents WORK. reader adopted BUF1 -> DMA writes BUF0.
    run_frame(32'd2, 8'h00);
    if (dma_src_surf !== 1'b0) begin errs=errs+1; $display("  fb_dma_src_surf=%b after plain END (want 0)", dma_src_surf); end
    check_buf(BUF0, 0, "frame2-work");
    if (errs==0) $display("RESULT: PASS"); else $display("RESULT: FAIL (errs=%0d)", errs);
    $finish;
  end
  initial begin #200000000 $display("RESULT: FAIL (timeout)"); $finish; end
endmodule
`default_nettype wire
