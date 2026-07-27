// tb_arb_blt_timeout.sv — bounded-borrow liveness for ddr_blitter_arb (iter 7).
//
// REWRITTEN for the owner-FIFO contract (2026-07-26). The previous version
// modeled a blitter that HOLDS blt_rd through the wait and asserted a RETRY
// (a second read command) after blt_abort. The real blitter (blitter_top
// S_RD_WAIT) drops bm_rd once the command is accepted, so that retry never
// existed on hardware — and re-issuing while the original response is still
// in flight would create a duplicate response anyway. The iter-7 contract:
//
//   LATE beat  (device event): blt_abort releases only the GRANT — the
//              expectation stays queued, the late beat still routes to the
//              blitter, and the reader is served meanwhile. No retry.
//   LOST beat  (pathological; boot-time bridge-down): the queue head sticks;
//              after FLUSH_QUIET_MAX beat-less cycles the arbiter flushes all
//              expectations and returns to G_READER so the READER regains
//              service. (The blitter stays parked — it has no retry — but one
//              wedged master beats two.)
//   burstcnt=0 guards: read and write with burstcnt=0 are armed as 1 beat,
//              no deadlock (unchanged from iter 6).
`timescale 1ns/1ps
`default_nettype none
module tb_arb_blt_timeout;
  reg clk=0, reset=1; always #5 clk=~clk;

  reg  [7:0]  r_burst=8'd4; reg [28:0] r_addr=0; reg r_rd=0; reg [63:0] r_din=0;
  reg  [7:0]  r_be=8'hFF; reg r_we=0; wire r_busy, r_grant;
  reg  [7:0]  b_burst=8'd1; reg [28:0] b_addr=0; reg b_rd=0; reg [63:0] b_din=0;
  reg  [7:0]  b_be=8'hFF; reg b_we=0; wire b_busy, b_grant;
  reg  ddr_busy=0, ddr_dready=0; reg [63:0] ddr_dout=64'd0;
  wire [7:0] d_burst; wire [28:0] d_addr; wire d_rd, d_we;
  wire [63:0] d_din; wire [7:0] d_be;

  // small flush window so the lost-beat phase runs in sim time
  ddr_blitter_arb #(.ENABLE(1'b1), .FLUSH_QUIET_MAX(20'd3000)) arb(.clk(clk),.reset(reset),
    .rdr_burstcnt(r_burst),.rdr_addr(r_addr),.rdr_rd(r_rd),.rdr_din(r_din),.rdr_be(r_be),.rdr_we(r_we),
    .rdr_busy(r_busy),.rdr_grant(r_grant),
    .blt_burstcnt(b_burst),.blt_addr(b_addr),.blt_rd(b_rd),.blt_din(b_din),.blt_be(b_be),.blt_we(b_we),
    .blt_busy(b_busy),.blt_grant(b_grant),
    .ddram_busy(ddr_busy),.ddram_dout_ready(ddr_dready),
    .ddram_burstcnt(d_burst),.ddram_addr(d_addr),.ddram_rd(d_rd),.ddram_din(d_din),.ddram_be(d_be),.ddram_we(d_we));

  // behavioral f2h: in-order response queue, per-command latency; `swallow`
  // eats the NEXT command (accepted, zero beats ever = the LOST-beat event).
  reg swallow=0; reg [15:0] next_lat=3;
  reg [7:0]  q_beats [0:7]; reg [15:0] q_lat [0:7]; reg q_eat [0:7];
  reg [2:0]  q_wr, q_rd;
  wire q_empty = (q_wr == q_rd);
  integer cmds_seen = 0;
  reg [7:0] cur_left=0; reg [15:0] cur_lat=0; reg cur_on=0;
  always @(posedge clk) begin
    ddr_dready <= 1'b0;
    if (reset) begin q_wr<=0; q_rd<=0; cur_on<=0; cur_left<=0; end
    else begin
      if (d_rd && !ddr_busy) begin
        q_beats[q_wr] <= d_burst; q_lat[q_wr] <= next_lat; q_eat[q_wr] <= swallow;
        swallow <= 0;
        q_wr <= q_wr + 3'd1;
        cmds_seen = cmds_seen + 1;
      end
      if (!cur_on && !q_empty) begin
        if (q_eat[q_rd]) q_rd <= q_rd + 3'd1;   // command eaten: no beats, ever
        else begin
          cur_left <= q_beats[q_rd]; cur_lat <= q_lat[q_rd];
          q_rd <= q_rd + 3'd1; cur_on <= 1'b1;
        end
      end else if (cur_on) begin
        if (cur_lat != 0) cur_lat <= cur_lat - 16'd1;
        else if (cur_left != 0) begin
          ddr_dready <= 1'b1;
          ddr_dout   <= 64'hFEED_0000_0000_0000 + {56'd0, cur_left};
          cur_left   <= cur_left - 8'd1;
          if (cur_left == 8'd1) cur_on <= 1'b0;
        end
      end
    end
  end

  integer blt_beats=0, rdr_beats=0;
  always @(posedge clk) if (ddr_dready) begin
    if (b_grant) blt_beats = blt_beats + 1;
    if (r_grant) rdr_beats = rdr_beats + 1;
  end

  integer errors=0, waitc, mark;
  initial begin
    repeat(4) @(posedge clk); reset<=0; repeat(2) @(posedge clk);

    // ── Phase 1: LATE beat. blt 1-beat read, response 1500 cyc late
    //    (> BLT_QUIET_MAX=1024). Real-blitter model: b_rd drops at accept. ────
    next_lat = 16'd1500;
    b_burst<=8'd1; b_addr<=29'h100; b_rd<=1;
    waitc=0;
    while (!(d_rd && !ddr_busy)) begin @(posedge clk); waitc=waitc+1;
      if (waitc>200) begin $display("RESULT: FAIL (blt cmd never accepted)"); $finish; end end
    b_rd<=0;
    // grant must be released by the abort well before the beat arrives...
    repeat(1200) @(posedge clk);
    if (arb.state != 3'd0) begin errors=errors+1;
      $display("FAIL: grant not released after abort (state=%0d)", arb.state); end
    // ...and the late beat must still reach the BLITTER (expectation kept).
    waitc=0;
    while (blt_beats==0 && waitc<1000) begin @(posedge clk); waitc=waitc+1; end
    if (blt_beats != 1) begin errors=errors+1;
      $display("FAIL: late blitter beat not delivered (blt_beats=%0d)", blt_beats); end
    if (cmds_seen != 1) begin errors=errors+1;
      $display("FAIL: %0d read commands (want exactly 1: no phantom retry)", cmds_seen); end

    // ── Phase 2: reader service after the event — 4-beat burst returns whole. ─
    next_lat = 16'd3;
    mark = rdr_beats;
    r_burst<=8'd4; r_addr<=29'h200; r_rd<=1;
    waitc=0;
    while (!(d_rd && !ddr_busy)) begin @(posedge clk); waitc=waitc+1;
      if (waitc>200) begin $display("RESULT: FAIL (rdr cmd never accepted)"); $finish; end end
    r_rd<=0;
    waitc=0;
    while ((rdr_beats-mark)<4 && waitc<500) begin @(posedge clk); waitc=waitc+1; end
    if (rdr_beats-mark != 4) begin errors=errors+1;
      $display("FAIL: reader burst after abort returned %0d/4 beats", rdr_beats-mark); end

    // ── Phase 3: LOST beat -> deep flush restores the arbiter + reader. ──────
    swallow<=1; next_lat=16'd3;
    b_addr<=29'h300; b_rd<=1;
    waitc=0;
    while (!(d_rd && !ddr_busy)) begin @(posedge clk); waitc=waitc+1;
      if (waitc>2200) begin $display("RESULT: FAIL (lost-beat cmd never accepted)"); $finish; end end
    b_rd<=0;
    // wait past FLUSH_QUIET_MAX(3000)+slack: expectations flushed, G_READER.
    repeat(3500) @(posedge clk);
    if (arb.state != 3'd0) begin errors=errors+1;
      $display("FAIL: not in G_READER after lost-beat flush (state=%0d)", arb.state); end
    mark = rdr_beats;
    r_addr<=29'h400; r_rd<=1;
    waitc=0;
    while (!(d_rd && !ddr_busy)) begin @(posedge clk); waitc=waitc+1;
      if (waitc>200) begin $display("RESULT: FAIL (post-flush rdr cmd never accepted)"); $finish; end end
    r_rd<=0;
    waitc=0;
    while ((rdr_beats-mark)<4 && waitc<500) begin @(posedge clk); waitc=waitc+1; end
    if (rdr_beats-mark != 4) begin errors=errors+1;
      $display("FAIL: reader burst after flush returned %0d/4 beats", rdr_beats-mark); end

    // ── Phase 4: burstcnt=0 arming guards (read, then write). ────────────────
    mark = blt_beats;
    b_burst<=8'd0; b_addr<=29'h500; b_rd<=1;
    waitc=0;
    while (!(d_rd && !ddr_busy)) begin @(posedge clk); waitc=waitc+1;
      if (waitc>500) begin $display("RESULT: FAIL (burst0 read never accepted)"); $finish; end end
    b_rd<=0;
    waitc=0;
    while ((blt_beats-mark)<1 && waitc<500) begin @(posedge clk); waitc=waitc+1; end
    if (blt_beats-mark != 1) begin errors=errors+1;
      $display("FAIL: burstcnt=0 read deadlocked"); end
    b_burst<=8'd0; b_addr<=29'h600; b_we<=1;
    waitc=0;
    while (!(d_we && !ddr_busy)) begin @(posedge clk); waitc=waitc+1;
      if (waitc>500) begin errors=errors+1; $display("FAIL: burstcnt=0 write never granted"); waitc=0; end end
    b_we<=0;
    repeat(8) @(posedge clk);
    if (arb.state != 3'd0) begin errors=errors+1;
      $display("FAIL: arbiter not back in G_READER (state=%0d)", arb.state); end

    if (errors == 0) $display("RESULT: PASS");
    else             $display("RESULT: FAIL (%0d errors)", errors);
    $finish;
  end

  initial begin #400000; $display("RESULT: FAIL (timeout)"); $finish; end
endmodule
`default_nettype wire
