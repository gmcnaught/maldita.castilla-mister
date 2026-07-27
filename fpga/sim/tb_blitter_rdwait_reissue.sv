// tb_blitter_rdwait_reissue.sv — [startup-wedge fix] S_RD_WAIT reissue watchdog.
//
// Device evidence 2026-07-27 (.62): ~50% of core launches park the blitter
// forever on its FIRST C_SUBMIT poll read — the read is ACCEPTED by the f2h
// port during the core-load bring-up window but its response beat never
// returns. S_RD_WAIT had no timeout, so rd_issued stayed 1 and C_DONE was
// never written (the "frame-1 wedge": submit climbs via host reclaims, done
// pinned at 0, display black).
//
// TEST 1 (the wedge): the DDR model ACCEPTS the first read but never returns
//   its beat. Old RTL: the FSM hangs here forever (this TB then FAILs on
//   timeout). Fixed RTL: after RW_WD_MAX cycles the watchdog re-arms the issue
//   phase, the reissued read is served, and the frame (cmd list = END only)
//   completes: C_DONE=1, dbg reissue count == 1.
// TEST 2 (clean-run control): a second submit with no drop completes with the
//   reissue count unchanged — the watchdog never fires on a healthy bus.
//
// RW_WD_MAX is overridden small (1000) per its parameter contract (sim-only
// override, same pattern as ddr_blitter_arb FLUSH_QUIET_MAX). In hardware it
// must stay > FLUSH_QUIET_MAX (2^20) so the arbiter's expectation flush runs
// BEFORE the reissue — a reissued read can never pair with a stale queue entry.
`timescale 1ns/1ps
`default_nettype none
`include "blitter_defs.vh"
module tb_blitter_rdwait_reissue;
  localparam [28:0] WBASE = 29'h07400000;
  localparam        MEMQW = (`SRC_QW - 29'h07400000) + 29'h10000;  // tracks SRC_QW heap base
  localparam [21:0] WD_SIM = 22'd1000;

  reg clk=0, rst=1; always #5 clk=~clk;
  reg vs=0; always #1000 vs=~vs;   // free-running vblank so the work->scan snapshot fires
  wire [31:0] bt_addr; wire b_rd, b_we; wire [63:0] b_din; wire [7:0] b_be; wire bt_idle;
  wire [7:0] bt_burst;
  wire [31:0] dbg_w;
  reg  d_dready; reg [63:0] d_dout;
  reg [63:0] mem [0:MEMQW-1];
  reg [7:0] rbeats; reg [28:0] raddr; reg [2:0] rlat; reg [1:0] bp=0;
  reg drop_arm;            // swallow the response of the NEXT accepted read
  integer drops = 0;       // how many reads were swallowed
  always @(posedge clk) bp <= bp+2'd1;
  wire d_busy = (bp != 2'd2) | (rbeats != 8'd0) | (rlat != 3'd0);
  integer i;

  // P_SRC tied off: this TB never blits from a source.
  wire [26:0] s_src_addr; wire s_src_rd;

  // on-chip dest framebuffer [FB-in-BRAM]
  wire fb_wr_en; wire [14:0] fb_wr_qw; wire [1:0] fb_wr_lane; wire [15:0] fb_wr_pix;
  wire fb_rd_en; wire [14:0] fb_rd_qw; wire [63:0] fb_rd_qword;
  comp_fbram fbram(.clk(clk),
    .wr_en(fb_wr_en), .wr_qw(fb_wr_qw), .wr_lane(fb_wr_lane), .wr_pix(fb_wr_pix),
    .rd_en(fb_rd_en), .rd_qw(fb_rd_qw), .rd_qword(fb_rd_qword));

  blitter_top #(.RW_WD_MAX(WD_SIM)) blt(.clk(clk), .rst(rst), .vs(vs),
    .mem_addr(bt_addr), .mem_rd(b_rd), .mem_wr(b_we), .mem_burstcnt(bt_burst),
    .mem_din(b_din), .mem_be(b_be),
    .mem_dout(d_dout), .mem_dout_ready(d_dready), .mem_busy(d_busy),
    .p0_addr(s_src_addr), .p0_rd(s_src_rd), .p0_dout(64'd0), .p0_ok(1'b0),
    .fb_wr_en(fb_wr_en), .fb_wr_qw(fb_wr_qw), .fb_wr_lane(fb_wr_lane), .fb_wr_pix(fb_wr_pix),
    .fb_rd_en(fb_rd_en), .fb_rd_qw(fb_rd_qw), .fb_rd_qword(fb_rd_qword),
    .idle(bt_idle), .dbg(dbg_w));

  // Behavioral DDR: accept-then-serve with 3-cycle latency, EXCEPT when
  // drop_arm — then the read is accepted (the FSM sees !mem_busy and sets
  // rd_issued) but its beats are never scheduled: the lost-response wedge.
  always @(posedge clk) begin
    d_dready <= 1'b0; d_dout <= 64'hDEAD_BEEF_DEAD_BEEF;
    if (rst) begin rbeats<=0; rlat<=0; end
    else begin
      if (rlat!=3'd0) rlat<=rlat-3'd1;
      else if (rbeats!=8'd0) begin
        if (bp==2'd2) begin d_dout<=mem[raddr-WBASE]; d_dready<=1'b1; raddr<=raddr+29'd1; rbeats<=rbeats-8'd1; end
      end else if (!d_busy) begin
        if (b_rd) begin
          if (drop_arm) begin drop_arm<=1'b0; drops=drops+1; end  // swallow: no beats scheduled
          else begin rbeats<=bt_burst; raddr<=bt_addr[28:0]; rlat<=3'd3; end
        end
        else if (b_we) for(i=0;i<8;i=i+1) if(b_be[i]) mem[(bt_addr[28:0]-WBASE)][i*8 +:8]<=b_din[i*8 +:8];
      end
    end
  end

  integer errs=0, to;
  wire [7:0] reissues = dbg_w[22:15];

  task await_done(input [31:0] n, input integer cap);
    begin
      to=0; while(mem[32'h200005][31:0]!==n && to<cap) begin @(posedge clk); to=to+1; end
      if (mem[32'h200005][31:0]!==n) begin
        errs=errs+1;
        $display("  FAIL: C_DONE never reached %0d (done=%h state=%0d rd_issued=%b reissues=%0d)",
                 n, mem[32'h200005][31:0], dbg_w[5:0], dbg_w[23], reissues);
      end
      repeat(10) @(posedge clk);
    end
  endtask

  initial begin
    for(i=0;i<MEMQW;i=i+1) mem[i]=64'd0;
    drop_arm = 1'b1;         // arm BEFORE reset release: the FIRST poll read is the victim

    // Control block: submit=1, one END command, no CLEAR.
    mem[32'h200000]=64'd1;   // C_SUBMIT
    mem[32'h200001]=64'd1;   // C_CMDCOUNT = 1
    mem[32'h200002]=64'd0;   // C_TARGET
    mem[32'h200003]=64'd0;   // C_CLEAR
    mem[32'h200004]=64'd0;   // C_FLAGS (no CLEAR)
    mem[32'h200005]=64'd0;   // C_DONE
    mem[32'h200007]=64'd2;   // C_SRCSEL (C_PIPE bit, legacy)
    mem[32'h200008]=64'd1;   // cmd0 = OP_END

    repeat(8) @(posedge clk); rst<=0;

    // TEST 1: first poll read swallowed -> watchdog must reissue and complete.
    await_done(32'd1, 200000);
    $display("=== TEST1 lost-first-read (to=%0d drops=%0d reissues=%0d) ===", to, drops, reissues);
    if (drops   !== 1) begin errs=errs+1; $display("  FAIL: expected exactly 1 swallowed read, got %0d", drops); end
    if (reissues !== 8'd1) begin errs=errs+1; $display("  FAIL: expected exactly 1 reissue for 1 lost read, got %0d", reissues); end

    // TEST 2: clean second submit -> completes, no new reissues.
    begin : t2
      reg [7:0] r0; r0 = reissues;
      mem[32'h200000]=64'd2;   // C_SUBMIT = 2
      await_done(32'd2, 200000);
      $display("=== TEST2 clean-run control (to=%0d reissues=%0d) ===", to, reissues);
      if (reissues !== r0) begin errs=errs+1; $display("  FAIL: watchdog fired on a healthy bus (%0d -> %0d)", r0, reissues); end
    end

    if (errs==0) $display("RESULT: PASS");
    else         $display("RESULT: FAIL (%0d errors)", errs);
    $finish;
  end

  // Global hang guard: the whole TB must finish well under this.
  initial begin
    #12_000_000;
    $display("RESULT: FAIL (global timeout — blitter parked, watchdog absent/ineffective)");
    $finish;
  end
endmodule
`default_nettype wire
