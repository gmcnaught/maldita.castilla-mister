// tb_arb_blt_timeout.sv — bounded-borrow (lost-beat) liveness for ddr_blitter_arb.
//
// Device evidence 2026-07-24/26: the arbiter parks in G_BLT_RD when a blitter
// read's return beat is lost (mis-steered/consumed elsewhere). That state gates
// ddram_rd/we off, so no master can issue the command whose beat would exit it:
// escape-free deadlock -> rdr_busy stuck -> comp_fb_dma stalls -> fb_dma_busy
// stuck -> blitter S_SNAP_DRAIN park (the recurring ~430-frame stalls).
//
//   RED  (today): DDR model swallows the first blitter read's beat -> arbiter
//                 sits in G_BLT_RD forever -> FAIL.
//   GREEN (fix):  BLT_QUIET_MAX bounded exit -> arbiter returns to G_READER,
//                 re-grants the still-asserted blt_rd (retry, reads idempotent),
//                 the retry's beat completes the blitter, and a subsequent
//                 reader burst is served in full -> PASS.
// Also covers the blt_burstcnt==0 arming guard (read AND write).
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

  ddr_blitter_arb #(.ENABLE(1'b1)) arb(.clk(clk),.reset(reset),
    .rdr_burstcnt(r_burst),.rdr_addr(r_addr),.rdr_rd(r_rd),.rdr_din(r_din),.rdr_be(r_be),.rdr_we(r_we),
    .rdr_busy(r_busy),.rdr_grant(r_grant),
    .blt_burstcnt(b_burst),.blt_addr(b_addr),.blt_rd(b_rd),.blt_din(b_din),.blt_be(b_be),.blt_we(b_we),
    .blt_busy(b_busy),.blt_grant(b_grant),
    .ddram_busy(ddr_busy),.ddram_dout_ready(ddr_dready),
    .ddram_burstcnt(d_burst),.ddram_addr(d_addr),.ddram_rd(d_rd),.ddram_din(d_din),.ddram_be(d_be),.ddram_we(d_we));

  // Behavioral DDR: accepts one read, latency 3, streams beats. `swallow` makes it
  // accept the NEXT read command but return ZERO beats (the lost-beat event).
  reg swallow=0;
  reg [7:0] beats_left=0; reg [3:0] lat_left=0;
  integer blt_beats=0, rdr_beats=0, cmds_seen=0;
  always @(posedge clk) begin
    ddr_dready <= 1'b0;
    if (reset) begin ddr_busy<=0; beats_left<=0; lat_left<=0; end
    else if (!ddr_busy) begin
      if (d_rd) begin
        cmds_seen = cmds_seen + 1;
        if (swallow) begin swallow<=0; ddr_busy<=0; end       // command eaten, no beats ever
        else begin beats_left<=d_burst; lat_left<=4'd3; ddr_busy<=1; end
      end
    end else if (lat_left != 0) lat_left <= lat_left - 4'd1;
    else if (beats_left != 0) begin
      ddr_dready <= 1'b1; ddr_dout <= 64'hFEED_0000 + beats_left;
      beats_left <= beats_left - 8'd1;
      if (beats_left == 8'd1) ddr_busy <= 1'b0;
    end
  end
  always @(posedge clk) if (ddr_dready) begin
    if (b_grant) blt_beats = blt_beats + 1;
    if (r_grant) rdr_beats = rdr_beats + 1;
  end

  integer errors=0, waitc;
  initial begin
    repeat(4) @(posedge clk); reset<=0; repeat(2) @(posedge clk);

    // ── Phase 1: lost-beat read. Model the real blitter: hold blt_rd through the wait.
    swallow<=1;
    b_burst<=8'd1; b_addr<=29'h100; b_rd<=1;
    // wait for the (doomed) command accept
    waitc=0; while(!(arb.state==3'd1 && !ddr_busy)) begin @(posedge clk); waitc=waitc+1;
      if (waitc>200) begin $display("RESULT: FAIL (blt cmd never accepted)"); $finish; end end
    // arbiter is now headed into G_BLT_RD with no beat ever coming.
    // GREEN: bounded exit + retry completes within ~BLT_QUIET_MAX + latency slack.
    waitc=0; while(blt_beats==0 && waitc<5000) begin @(posedge clk); waitc=waitc+1; end
    if (blt_beats==0) begin
      errors=errors+1;
      $display("FAIL: blitter beat never arrived (arb.state=%0d, parked %0d cyc) — G_BLT_RD unbounded", arb.state, waitc);
    end
    // the retry claim, made direct: exactly 2 read commands issued to the DDR model
    // (the swallowed original + the re-issued retry) — not zero, not a third phantom.
    if (cmds_seen != 2) begin
      errors=errors+1;
      $display("FAIL: expected 2 read commands (swallowed + retry), saw %0d", cmds_seen);
    end
    b_rd<=0;
    repeat(8) @(posedge clk);
    if (arb.state != 3'd0) begin errors=errors+1; $display("FAIL: arbiter not back in G_READER (state=%0d)", arb.state); end

    // ── Phase 2: reader service after the event — 4-beat burst must fully return.
    waitc=0; while(r_busy) begin @(posedge clk); waitc=waitc+1;
      if (waitc>5000) begin $display("RESULT: FAIL (reader locked out post-abort)"); $finish; end end
    r_addr<=29'h200; r_rd<=1; @(posedge clk);
    while(!(r_grant && !ddr_busy)) @(posedge clk);
    r_rd<=0;
    waitc=0; while(rdr_beats<4 && waitc<5000) begin @(posedge clk); waitc=waitc+1; end
    if (rdr_beats!=4) begin errors=errors+1; $display("FAIL: reader got %0d/4 beats", rdr_beats); end

    // ── Phase 3: blt_burstcnt==0 guard — read then write must both complete, not deadlock.
    blt_beats=0;
    b_burst<=8'd0; b_addr<=29'h140; b_rd<=1;      // pathological burstcnt=0 read
    waitc=0; while(blt_beats==0 && waitc<5000) begin @(posedge clk); waitc=waitc+1; end
    b_rd<=0;
    if (blt_beats==0) begin errors=errors+1; $display("FAIL: burstcnt=0 read deadlocked"); end
    repeat(8) @(posedge clk);
    if (arb.state != 3'd0) begin errors=errors+1; $display("FAIL: state=%0d after burstcnt=0 read", arb.state); end
    // Load-bearing bound: guarded, the 1-beat shortcut takes G_BLT->G_READER in a
    // single cycle after grant. Unguarded, blt_burstcnt-1 underflows blt_out to 255
    // and (needing blt_out==1 to exit G_BLT_WR) drains ~254 cycles before completing
    // (this DDR model never asserts ddram_busy on writes, so nothing else stalls it) —
    // well inside the 5000-cycle timeout, so an unbounded wait alone can't catch the
    // underflow. Bound the grant->drain span tightly instead.
    b_burst<=8'd0; b_addr<=29'h180; b_din<=64'hCAFE; b_we<=1;   // burstcnt=0 write
    waitc=0;
    while (arb.state != 3'd1) begin                  // wait for the write to be granted (G_BLT)
      @(posedge clk); waitc=waitc+1;
      if (waitc>200) begin $display("RESULT: FAIL (burstcnt=0 write never granted)"); $finish; end
    end
    waitc=0;
    while (arb.state != 3'd0) begin                  // measure cycles to drain back to G_READER
      @(posedge clk); waitc=waitc+1;
      if (waitc>5000) begin $display("RESULT: FAIL (burstcnt=0 write deadlocked, state=%0d)", arb.state); $finish; end
    end
    b_we<=0;
    if (waitc > 10) begin
      errors=errors+1;
      $display("FAIL: burstcnt=0 write drained in %0d cycles (>10) — unguarded 0-1 underflow (blt_out=255) not caught", waitc);
    end

    if (errors==0) $display("RESULT: PASS (bounded borrow: lost beat retried, reader restored, burstcnt=0 guarded)");
    else           $display("RESULT: FAIL (%0d errors)", errors);
    $finish;
  end
  initial begin #2000000 $display("RESULT: FAIL (timeout)"); $finish; end
endmodule
`default_nettype wire
