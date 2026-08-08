// tb_arb_rdrout_resync.sv — the frame-1 wedge, reproduced and fixed.
//
// DEVICE EVIDENCE (.62, 2026-08-08). A live probe caught the wedge with the
// arbiter in this exact state:
//
//     rdr_out=1  xq_level=0  rdr_idle=0  flush_sticky=0
//     blitter parked in S_RD_WAIT, rd_issued=0, C_DONE frozen forever
//
// The expectation queue — the authority on what is outstanding — was EMPTY,
// while rdr_out still held 1. rdr_idle is (rdr_out == 0) and the blitter is
// granted the bus only when rdr_idle, so that single leaked count locks the
// blitter out permanently while the reader carries on servicing itself. It is a
// deadlock between two working parties, and nothing else in the design catches
// it: `flush` cannot fire (fquiet is reset by every arriving beat) and
// blitter_top's S_RD_WAIT reissue watchdog is unreachable while rd_issued=0.
//
// The fix resyncs the cached counters to the queue: xq_empty => nothing is
// outstanding => both counts must be zero.
//
// This test forces the captured state directly (hierarchical poke of rdr_out
// with the queue empty) rather than trying to provoke whatever races the count
// in the first place — the wedge is ~36% per boot on hardware and not
// reproducible on demand, so the regression has to be written against the
// STATE, not the route into it.
//
// PASS iff the blitter is granted the bus after the poke. Without the resync
// rdr_idle stays low forever and the grant never comes.
//
// tb_arb_borrow.sv guards the opposite failure: an older self-correct cleared
// the count on a reader-idle TIMER and clobbered a blitter read in flight. That
// is why this clear is gated on xq_empty AND ~rdr_acc AND ~blt_acc — with a
// read in flight the queue is non-empty, so this never fires. Both benches must
// pass together or the fix has traded one wedge for the other.
`timescale 1ns/1ps
`default_nettype none
module tb_arb_rdrout_resync;
  reg clk=0, reset=1; always #5 clk=~clk;

  reg [7:0] r_burst=0; reg[28:0] r_addr=0; reg r_rd=0; reg[63:0] r_din=0; reg[7:0] r_be=8'hFF; reg r_we=0;
  wire r_busy, r_grant;
  reg [28:0] b_addr=0; reg b_rd=0; reg[63:0] b_din=0; reg[7:0] b_be=8'hFF; reg b_we=0;
  wire b_busy, b_grant;
  wire[7:0] d_burst; wire[28:0] d_addr; wire d_rd; wire[63:0] d_din; wire[7:0] d_be; wire d_we;
  reg d_busy=0; reg d_dready=0;
  wire [15:0] arb_dbg;

  ddr_blitter_arb #(.ENABLE(1'b1)) dut(.clk(clk),.reset(reset),
    .rdr_burstcnt(r_burst),.rdr_addr(r_addr),.rdr_rd(r_rd),.rdr_din(r_din),.rdr_be(r_be),.rdr_we(r_we),
    .rdr_busy(r_busy),.rdr_grant(r_grant),
    .blt_burstcnt(8'd1),.blt_addr(b_addr),.blt_rd(b_rd),.blt_din(b_din),.blt_be(b_be),.blt_we(b_we),
    .blt_busy(b_busy),.blt_grant(b_grant),
    .ddram_busy(d_busy),.ddram_dout_ready(d_dready),
    .ddram_burstcnt(d_burst),.ddram_addr(d_addr),.ddram_rd(d_rd),.ddram_din(d_din),.ddram_be(d_be),.ddram_we(d_we),
    .dbg(arb_dbg));

  integer t;
  initial begin
    repeat(6)@(posedge clk); reset<=0;
    repeat(20)@(posedge clk);

    // Sanity: idle arbiter, empty queue, counts zero, blitter grantable.
    if (dut.rdr_out !== 10'd0 || !dut.xq_empty) begin
      $display("RESULT: FAIL (setup: expected idle arbiter, rdr_out=%0d xq_empty=%0b)",
               dut.rdr_out, dut.xq_empty);
      $finish;
    end

    // Reproduce the captured wedge state: leaked count, empty queue.
    @(negedge clk);
    dut.rdr_out = 10'd1;
    @(posedge clk);
    if (dut.rdr_idle !== 1'b0)
      $display("NOTE: rdr_idle already high the cycle after the poke");

    // The resync must restore rdr_idle without any beat, accept or flush.
    t=0;
    while (dut.rdr_out !== 10'd0) begin
      @(posedge clk); t=t+1;
      if (t > 20) begin
        $display("RESULT: FAIL (rdr_out stuck at %0d with xq_empty=%0b — the wedge)",
                 dut.rdr_out, dut.xq_empty);
        $finish;
      end
    end

    // And the blitter must actually get the bus again.
    b_addr<=29'h07408008; b_rd<=1'b1;
    t=0;
    while (!(d_rd && !d_busy)) begin
      @(posedge clk); t=t+1;
      if (t > 50) begin
        $display("RESULT: FAIL (blitter read never accepted after resync)");
        $finish;
      end
    end
    $display("RESULT: PASS (rdr_out resynced to the empty queue in %0d cyc; blitter regained the bus)", t);
    $finish;
  end

  initial begin #500000; $display("RESULT: FAIL (timeout)"); $finish; end
endmodule
`default_nettype wire
