// tb_perf_publish_order.sv — C_DONE MUST BE PUBLISHED LAST.
//
// WHAT THIS GUARDS
// ────────────────
// C_DONE is the host's completion handshake: raster_backend_mfgpu.cpp polls it in a
// tight loop and returns the instant it matches submit_seq, then immediately reads the
// fabric perf counters:
//   frame   = C_DONE.hi   perf_frame_cyc
//   texwait = C_STATUS.hi perf_texwait_cyc
//   tri     = C_SRCSEL.hi perf_tri_cyc
//
// So C_DONE is a RELEASE barrier for everything the host reads alongside it. If the
// fabric writes C_DONE *before* C_STATUS/C_SRCSEL, the host wakes and samples tri and
// texwait for a frame the fabric has not published yet — it gets the PREVIOUS frame's
// values. frame_ms (packed in C_DONE's own qword) is current, so the derived
// ovhd = frame - tri silently mixes two different frames and is garbage.
//
// This is the same discipline the host already applies on the submit side
// ("doorbell LAST, after a barrier" — mf_device_submit) applied to the completion
// side: publish the payload, THEN ring the bell.
//
// This TB does not check counter VALUES (that is tb_blitter_trilist_pipe's job). It
// checks ORDER only, which is the property the race actually violates — a value check
// would pass by luck whenever consecutive frames happen to cost the same.
//
// Reuses the DDR + P_SRC models and the tri_copy vectors from tb_blitter_trilist_pipe.
`timescale 1ns/1ps
`default_nettype none
`include "blitter_defs.vh"
module tb_perf_publish_order;
  localparam [28:0] WBASE = 29'h07400000;
  localparam        MEMQW = (`SRC_QW - 29'h07400000) + 29'h8000;
  // control-block base as an index into `mem` (BLTCTRL_QW - WBASE)
  localparam integer CTRL = 32'h200000;

  reg clk=0, rst=1; always #5 clk=~clk;

  wire [31:0] bt_addr; wire b_rd, b_we; wire [63:0] b_din; wire [7:0] b_be; wire bt_idle;
  reg  d_dready; reg [63:0] d_dout;

  reg [63:0] mem [0:MEMQW-1];
  reg [7:0] rbeats; reg [28:0] raddr; reg [2:0] rlat; reg [1:0] bp=0;
  always @(posedge clk) bp <= bp+2'd1;
  wire d_busy = (bp != 2'd2) | (rbeats != 8'd0) | (rlat != 3'd0);
  integer i;

  // ── P_SRC cache-ok source model (same faithful line-cache as the trilist TB) ──
  localparam P_SRC_LAT = 3;
  wire [26:0] s_src_addr; wire s_src_rd;
  reg  [63:0] s_src_dout; reg s_src_ok=1'b0;
  reg         s_rd_d;
  localparam [28:0] SRC_WIN = `SRC_QW - WBASE;
  localparam LINE_LOG2 = 8;
  localparam NLINES    = 2;
  localparam HIT_LAT   = 4;
  localparam MISS_LAT  = 140;
  reg        so_busy = 1'b0;
  integer    so_cnt  = 0;
  reg [26:0] so_addr = 27'd0;
  reg [26:0] rline   [0:NLINES-1];
  reg        rline_v [0:NLINES-1];
  integer    li, hitpos;
  initial for (li=0; li<NLINES; li=li+1) begin rline[li]=27'h7FFFFFF; rline_v[li]=1'b0; end
  always @(posedge clk) s_rd_d <= s_src_rd;
  always @(posedge clk) begin
    s_src_ok <= 1'b0;
    if ((s_src_rd & ~s_rd_d) && !so_busy) begin
      so_busy <= 1'b1;
      so_addr <= s_src_addr;
      hitpos = -1;
      for (li=0; li<NLINES; li=li+1)
        if (rline_v[li] && (rline[li] == (s_src_addr >> LINE_LOG2))) hitpos = li;
      if (hitpos >= 0) begin
        so_cnt <= HIT_LAT;
        for (li=0; li<NLINES; li=li+1) if (li <= hitpos && li>0) rline[li] <= rline[li-1];
        rline[0] <= (s_src_addr >> LINE_LOG2); rline_v[0] <= 1'b1;
      end else begin
        so_cnt <= MISS_LAT;
        for (li=NLINES-1; li>0; li=li-1) begin rline[li] <= rline[li-1]; rline_v[li] <= rline_v[li-1]; end
        rline[0] <= (s_src_addr >> LINE_LOG2); rline_v[0] <= 1'b1;
      end
    end
    if (so_busy) begin
      if (so_cnt <= 1) begin
        s_src_dout <= mem[SRC_WIN + (so_addr >> 3)];
        s_src_ok   <= 1'b1;
        so_busy    <= 1'b0;
      end else so_cnt <= so_cnt - 1;
    end
  end

  wire [7:0] bt_burst;
  wire fb_wr_en; wire [14:0] fb_wr_qw; wire [1:0] fb_wr_lane; wire [15:0] fb_wr_pix;
  wire fb_rd_en; wire [14:0] fb_rd_qw; wire [63:0] fb_rd_qword;
  comp_fbram fbram(.clk(clk),
    .wr_en(fb_wr_en), .wr_qw(fb_wr_qw), .wr_lane(fb_wr_lane), .wr_pix(fb_wr_pix),
    .rd_en(fb_rd_en), .rd_qw(fb_rd_qw), .rd_qword(fb_rd_qword));
  blitter_top blt(.clk(clk), .rst(rst),
    .mem_addr(bt_addr), .mem_rd(b_rd), .mem_wr(b_we), .mem_burstcnt(bt_burst),
    .mem_din(b_din), .mem_be(b_be),
    .mem_dout(d_dout), .mem_dout_ready(d_dready), .mem_busy(d_busy),
    .p0_addr(s_src_addr), .p0_rd(s_src_rd), .p0_dout(s_src_dout), .p0_ok(s_src_ok),
    .fb_wr_en(fb_wr_en), .fb_wr_qw(fb_wr_qw), .fb_wr_lane(fb_wr_lane), .fb_wr_pix(fb_wr_pix),
    .fb_rd_en(fb_rd_en), .fb_rd_qw(fb_rd_qw), .fb_rd_qword(fb_rd_qword),
    .idle(bt_idle));

  // ── write-order monitor ──────────────────────────────────────────────────────
  // Stamp the cycle of each accepted control-block write. The DDR model accepts a
  // write only on the same condition as the `mem` update below, so mirror it exactly.
  reg [63:0] cyc = 64'd0;
  always @(posedge clk) cyc <= cyc + 64'd1;

  wire wr_accept = (!rst) && (rlat == 3'd0) && (rbeats == 8'd0) && (!d_busy) && b_we;
  wire [31:0] wr_idx = bt_addr[28:0] - WBASE;

  reg [63:0] t_done = 64'd0, t_status = 64'd0, t_srcsel = 64'd0;
  reg [31:0] n_done = 32'd0;

  always @(posedge clk) if (wr_accept) begin
    if (wr_idx == (CTRL + `C_DONE))   begin t_done   <= cyc; n_done <= n_done + 32'd1; end
    if (wr_idx == (CTRL + `C_STATUS))  t_status <= cyc;
    if (wr_idx == (CTRL + `C_SRCSEL))  t_srcsel <= cyc;
  end

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

  initial begin
    for(i=0;i<MEMQW;i=i+1) mem[i]=64'd0;
    $readmemh("vectors/tri_copy_ddr.hex", mem);
  end

  integer to;
  initial begin
    repeat(8) @(posedge clk); rst<=0;
    to=0;
    while (mem[CTRL + `C_DONE][31:0] !== mem[CTRL][31:0] && to<4000000) begin @(posedge clk); to=to+1; end
    // settle so any writes the fabric issues after C_DONE are also stamped
    repeat(200) @(posedge clk);

    $display("=== done_seq=%0d submit=%0d (to=%0d) ===", mem[CTRL + `C_DONE][31:0], mem[CTRL][31:0], to);
    $display("=== publish cycles: C_STATUS=%0d C_SRCSEL=%0d C_DONE=%0d (n_done=%0d) ===",
             t_status, t_srcsel, t_done, n_done);

    if (mem[CTRL + `C_DONE][31:0] !== mem[CTRL][31:0]) begin
      $display("RESULT: FAIL (frame never completed, to=%0d)", to);
    end else if (n_done == 32'd0 || t_status == 64'd0 || t_srcsel == 64'd0) begin
      // Guard against a vacuous pass if the monitor never saw the writes at all.
      $display("RESULT: FAIL (monitor saw no write: n_done=%0d t_status=%0d t_srcsel=%0d)",
               n_done, t_status, t_srcsel);
    end else if (t_done > t_status && t_done > t_srcsel) begin
      $display("RESULT: PASS");
    end else begin
      $display("  C_DONE published BEFORE the perf counters it releases:");
      if (t_done <= t_status) $display("    C_DONE(%0d) <= C_STATUS(%0d)  -> texwait read stale", t_done, t_status);
      if (t_done <= t_srcsel) $display("    C_DONE(%0d) <= C_SRCSEL(%0d)  -> tri read stale",     t_done, t_srcsel);
      $display("RESULT: FAIL (C_DONE not published last)");
    end
    $finish;
  end
  initial begin #200000000 $display("RESULT: FAIL (timeout)"); $finish; end
endmodule
`default_nettype wire
