// tb_arb_beat_owner.sv — read-beat OWNERSHIP under late (not lost) responses.
//
// Device evidence 2026-07-26 (.62, probe RBF): the in-game "fabric pause" is a
// 0.6-14 s TRILIST grind over GARBAGE vertices. peak_stuck never saturated
// through 10 s+ parks (deepest single-state dwell 95 ms in S_TRI_PIX), so the
// FSM is churning, not parked: it is rasterizing wrong data. The wrong data
// comes from HERE: the arbiter routes read-return beats by GRANT STATE
// (rdr_grant/blt_grant are state equalities the consumers AND with
// ddram_dout_ready). When a blitter read's response arrives LATER than
// BLT_QUIET_MAX (f2h latency spike under game-side DDR traffic), blt_abort
// exits G_BLT_RD, and the late beat lands in whatever grant state is current:
//  - reader granted -> the reader ingests the blitter's qword (display junk)
//    and the beat count desyncs;
//  - the blitter's NEXT read granted -> S_RD_WAIT captures the WRONG qword and
//    every chained fetch after it is off by one: shifted TRILIST vertices ->
//    huge clipped garbage triangles -> the multi-second pause.
//
// The f2h port returns read data strictly IN COMMAND ORDER, so exact routing
// is knowable at accept time. Contract under test (owner-FIFO arb):
//  1. every returned beat is delivered to the master that issued its command,
//     regardless of grant state at arrival time;
//  2. blt_abort may release the GRANT (reader service resumes) but must NOT
//     discard the expectation — the late beat still belongs to the blitter;
//  3. reader beats are never consumed by the blitter and vice versa.
//
// RED on the pre-fix arb: the late blitter beat is handed to the reader.
`timescale 1ns/1ps
`default_nettype none
module tb_arb_beat_owner;
  reg clk=0, reset=1; always #5 clk=~clk;

  reg  [7:0]  r_burst=8'd4; reg [28:0] r_addr=0; reg r_rd=0; reg [63:0] r_din=0;
  reg  [7:0]  r_be=8'hFF; reg r_we=0; wire r_busy, r_grant;
  reg  [7:0]  b_burst=8'd1; reg [28:0] b_addr=0; reg b_rd=0; reg [63:0] b_din=0;
  reg  [7:0]  b_be=8'hFF; reg b_we=0; wire b_busy, b_grant;
  reg  ddr_busy=0, ddr_dready=0; reg [63:0] ddr_dout=64'd0;
  wire [7:0] d_burst; wire [28:0] d_addr; wire d_rd, d_we;
  wire [63:0] d_din; wire [7:0] d_be;

  ddr_blitter_arb #(.ENABLE(1'b1)) arb(.clk(clk),.reset(reset),
    .rdr_burstcnt(r_burst),.rdr_addr(r_addr),.rdr_rd(r_rd),.rdr_din(r_din),.rdr_be(r_be),.rdr_we(r_we),
    .rdr_busy(r_busy),.rdr_grant(r_grant),
    .blt_burstcnt(b_burst),.blt_addr(b_addr),.blt_rd(b_rd),.blt_din(b_din),.blt_be(b_be),.blt_we(b_we),
    .blt_busy(b_busy),.blt_grant(b_grant),
    .ddram_busy(ddr_busy),.ddram_dout_ready(ddr_dready),
    .ddram_burstcnt(d_burst),.ddram_addr(d_addr),.ddram_rd(d_rd),.ddram_din(d_din),.ddram_be(d_be),.ddram_we(d_we));

  // ── behavioral f2h: accepts read commands into an IN-ORDER response queue;
  //    each command has its own latency; responses never reorder. ─────────────
  reg [15:0] next_lat = 0; reg [63:0] next_marker = 0;   // set by the test per command
  reg [7:0]  q_beats [0:7]; reg [15:0] q_lat [0:7]; reg [63:0] q_data [0:7];
  reg [2:0]  q_wr, q_rd;
  wire q_empty = (q_wr == q_rd);
  integer cmds_seen = 0;
  reg [7:0] cur_left = 0; reg [15:0] cur_lat = 0; reg [63:0] cur_data = 0; reg cur_on = 0;
  always @(posedge clk) begin
    ddr_dready <= 1'b0;
    if (reset) begin q_wr<=0; q_rd<=0; cur_on<=0; cur_left<=0; end
    else begin
      if (d_rd && !ddr_busy) begin
        q_beats[q_wr] <= d_burst;
        // per-command latency + data marker set by the test via force vars below
        q_lat[q_wr]   <= next_lat;
        q_data[q_wr]  <= next_marker;
        q_wr <= q_wr + 3'd1;
        cmds_seen = cmds_seen + 1;
      end
      if (!cur_on && !q_empty) begin
        cur_left <= q_beats[q_rd]; cur_lat <= q_lat[q_rd]; cur_data <= q_data[q_rd];
        q_rd <= q_rd + 3'd1; cur_on <= 1'b1;
      end else if (cur_on) begin
        if (cur_lat != 0) cur_lat <= cur_lat - 16'd1;
        else if (cur_left != 0) begin
          ddr_dready <= 1'b1;
          ddr_dout   <= cur_data + {56'd0, cur_left};   // marker + beat index
          cur_left   <= cur_left - 8'd1;
          if (cur_left == 8'd1) cur_on <= 1'b0;
        end
      end
    end
  end

  // ── beat capture at the consumer contract: grant AND dout_ready ────────────
  integer blt_beats=0, rdr_beats=0, misrouted=0;
  reg [63:0] last_blt_data=0;
  always @(posedge clk) if (ddr_dready) begin
    if (b_grant) begin
      blt_beats = blt_beats + 1; last_blt_data = ddr_dout;
      if (ddr_dout[63:32] != 32'hB117_0000) misrouted = misrouted + 1;
    end
    if (r_grant) begin
      rdr_beats = rdr_beats + 1;
      if (ddr_dout[63:32] != 32'h0BEE_0000) misrouted = misrouted + 1;
    end
  end

  integer errors=0, waitc;
  initial begin
    repeat(4) @(posedge clk); reset<=0; repeat(2) @(posedge clk);

    // ── Phase 1: blitter 1-beat read whose response is LATE (1500 cyc >
    //    BLT_QUIET_MAX=1024). Real-blitter model: DROP b_rd after acceptance
    //    (blitter_top S_RD_WAIT holds bm_rd only until !mem_busy). ───────────
    next_lat = 16'd1500; next_marker = {32'hB117_0000, 32'd0};
    b_burst <= 8'd1; b_addr <= 29'h100; b_rd <= 1;
    waitc = 0;
    while (!(d_rd && !ddr_busy)) begin @(posedge clk); waitc=waitc+1;
      if (waitc>200) begin $display("RESULT: FAIL (blt cmd never accepted)"); $finish; end end
    b_rd <= 0;   // accepted this cycle -> request drops at the next edge (real blitter)

    // ── Phase 2: while that response is in flight, the abort window passes and
    //    the reader issues a 4-beat line burst (fast latency). In-order port:
    //    the late blitter beat still returns FIRST. ──────────────────────────
    repeat(1100) @(posedge clk);          // > BLT_QUIET_MAX: old arb aborts here
    next_lat = 16'd3; next_marker = {32'h0BEE_0000, 32'd0};
    r_burst <= 8'd4; r_addr <= 29'h200; r_rd <= 1;
    waitc = 0;
    while (!(d_rd && !ddr_busy)) begin @(posedge clk); waitc=waitc+1;
      if (waitc>200) begin $display("RESULT: FAIL (rdr cmd never accepted)"); $finish; end end
    r_rd <= 0;

    // ── Drain: all 5 beats (1 blt + 4 rdr) return in command order. ─────────
    waitc = 0;
    while ((blt_beats + rdr_beats) < 5 && waitc < 4000) begin @(posedge clk); waitc=waitc+1; end

    if (blt_beats != 1) begin errors=errors+1;
      $display("FAIL: blitter got %0d beats (want 1) — late beat not owner-routed", blt_beats); end
    if (rdr_beats != 4) begin errors=errors+1;
      $display("FAIL: reader got %0d beats (want 4)", rdr_beats); end
    if (misrouted != 0) begin errors=errors+1;
      $display("FAIL: %0d beats delivered with the WRONG master's data marker", misrouted); end
    if (blt_beats == 1 && last_blt_data[63:32] != 32'hB117_0000) begin errors=errors+1;
      $display("FAIL: blitter captured foreign data 0x%016x", last_blt_data); end
    if (cmds_seen != 2) begin errors=errors+1;
      $display("FAIL: %0d read commands issued (want exactly 2: no phantom retry)", cmds_seen); end

    // ── Phase 3: post-event health — a fresh blitter read completes promptly.─
    next_lat = 16'd3; next_marker = {32'hB117_0000, 32'd0};
    b_addr <= 29'h300; b_rd <= 1;
    waitc = 0;
    while (!(d_rd && !ddr_busy) && waitc < 3000) begin @(posedge clk); waitc=waitc+1; end
    if (!(d_rd && !ddr_busy)) begin errors=errors+1;
      $display("FAIL: post-event blt cmd never accepted");
    end else begin
      b_rd <= 0;
      waitc = 0;
      while (blt_beats < 2 && waitc < 2000) begin @(posedge clk); waitc=waitc+1; end
      if (blt_beats != 2) begin errors=errors+1;
        $display("FAIL: post-event blitter read never completed (blt_beats=%0d)", blt_beats); end
    end

    if (errors == 0) $display("RESULT: PASS");
    else             $display("RESULT: FAIL (%0d errors)", errors);
    $finish;
  end

  initial begin #200000; $display("RESULT: FAIL (timeout)"); $finish; end
endmodule
`default_nettype wire
