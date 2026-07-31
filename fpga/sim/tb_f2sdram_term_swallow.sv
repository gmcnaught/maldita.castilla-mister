// tb_f2sdram_term_swallow.sv — regression for the FIRST-FRAME F2H HANG.
//
// f2sdram_safe_terminator sits between the fabric's Avalon-MM master (here:
// ddr_blitter_arb -> ddram) and the f2sdram port. While a bridge/core reset is
// requested it enters `terminating` and stops forwarding commands:
//
//     read_master = read_terminating          (sys/f2sdram_safe_terminator.sv)
//
// but it passes waitrequest straight through:
//
//     assign waitrequest_slave = waitrequest_master;
//
// On Avalon-MM a command is ACCEPTED on any cycle where the command signal is
// high and waitrequest is low. So during the terminating window the user logic
// sees `read && !waitrequest` — accepted — while the command never reaches the
// port and no readdatavalid will ever come back. The read is swallowed, and any
// master that waits on the response parks forever.
//
// This is not hypothetical on this core. `reset` (sysmem_lite reset_out) reaches
// `emu` asynchronously, while the terminator's rst_req_sync is that same signal
// double-registered onto ram1_clk (sys/sysmem.sv:60-65). The terminator therefore
// UNLOCKS ~3 ram1_clk cycles AFTER the fabric leaves reset, and the blitter's
// C_SUBMIT poll issues its first f2h read immediately out of reset. Every read in
// that skew window is swallowed. Maldita is the first MiSTer core to put a
// free-running poller on f2h; stock cores only issue on demand, so no upstream
// core exercises this.
//
// The invariant under test is protocol-level and holds in every state:
//
//     a read accepted on the SLAVE side must be forwarded on the MASTER side.
//
// FAILs a passthrough waitrequest; PASSes when the terminator backpressures
// instead of swallowing. T3 guards the module's original purpose (finishing an
// interrupted write burst) against that change.
`timescale 1ns/1ps
`default_nettype none
module tb_f2sdram_term_swallow;

  reg clk = 1'b0; always #5 clk = ~clk;

  // Bridge/core reset REQUEST (not a testbench reset — the f2sdram model and the
  // counters below deliberately keep running across it, as the real port does).
  reg rst_req = 1'b1;

  // ── slave side: driven by this TB standing in for the fabric's master ──────
  reg  [7:0]  bc_s   = 8'd1;
  reg  [28:0] addr_s = 29'd0;
  reg         rd_s   = 1'b0;
  reg  [63:0] wd_s   = 64'd0;
  reg  [7:0]  be_s   = 8'hFF;
  reg         wr_s   = 1'b0;
  wire        wait_s;
  wire [63:0] rdata_s;
  wire        rvalid_s;

  // ── master side: the f2sdram port model ───────────────────────────────────
  wire [7:0]  bc_m;
  wire [28:0] addr_m;
  wire        rd_m, wr_m;
  wire [63:0] wd_m;
  wire [7:0]  be_m;
  wire        wait_m = 1'b0;      // port always ready; isolates the swallow path
  reg  [63:0] rdata_m = 64'd0;
  reg         rvalid_m = 1'b0;

  f2sdram_safe_terminator #(64, 8) dut (
    .clk                  (clk),
    .rst_req_sync         (rst_req),

    .waitrequest_master   (wait_m),
    .burstcount_master    (bc_m),
    .address_master       (addr_m),
    .readdata_master      (rdata_m),
    .readdatavalid_master (rvalid_m),
    .read_master          (rd_m),
    .writedata_master     (wd_m),
    .byteenable_master    (be_m),
    .write_master         (wr_m),

    .waitrequest_slave    (wait_s),
    .burstcount_slave     (bc_s),
    .address_slave        (addr_s),
    .readdata_slave       (rdata_s),
    .readdatavalid_slave  (rvalid_s),
    .read_slave           (rd_s),
    .writedata_slave      (wd_s),
    .byteenable_slave     (be_s),
    .write_slave          (wr_s)
  );

  // f2sdram model: latch one accepted read command, wait a first-beat latency,
  // then stream burstcount beats. Writes are accepted every cycle (wait_m = 0).
  reg [7:0] pend = 8'd0;
  reg [3:0] lat  = 4'd0;
  reg       serving = 1'b0;
  always @(posedge clk) begin
    rvalid_m <= 1'b0;
    if (serving) begin
      if (lat != 4'd0) lat <= lat - 4'd1;
      else if (pend != 8'd0) begin
        rvalid_m <= 1'b1;
        rdata_m  <= {56'd0, pend};
        pend     <= pend - 8'd1;
        if (pend == 8'd1) serving <= 1'b0;
      end
    end
    else if (rd_m && !wait_m) begin
      serving <= 1'b1; pend <= bc_m; lat <= 4'd5;
    end
  end

  // ── invariant + accounting ────────────────────────────────────────────────
  integer swallowed  = 0;   // read accepted on the slave side, not forwarded
  integer wr_acc_m   = 0;   // write beats accepted on the master side
  integer beats_s    = 0;   // read beats delivered to the slave side
  always @(posedge clk) begin
    if (rd_s && !wait_s && !rd_m) swallowed = swallowed + 1;
    if (wr_m && !wait_m)          wr_acc_m  = wr_acc_m  + 1;
    if (rvalid_s)                 beats_s   = beats_s   + 1;
  end

  integer errors = 0;
  task check(input cond, input string what);
    begin
      if (!cond) begin errors = errors + 1; $display("FAIL: %0s", what); end
      else                                  $display("ok  : %0s", what);
    end
  endtask

  initial begin
    // Leave the power-on reset once so the terminator arms itself
    // (init_reset_deasserted latches on the first deassert).
    repeat (8) @(posedge clk);
    rst_req <= 1'b0;
    repeat (8) @(posedge clk);

    // ── T1 sanity: with no reset pending, a read passes through and returns ──
    beats_s = 0;
    bc_s <= 8'd1; addr_s <= 29'h0100; rd_s <= 1'b1;
    @(posedge clk); rd_s <= 1'b0;
    repeat (20) @(posedge clk);
    check(beats_s == 1, "T1 normal read returns its beat");
    check(swallowed == 0, "T1 no swallowed command outside the reset window");

    // ── T2 the bug: a read issued while the terminator is locked ─────────────
    // The fabric leaves reset before the terminator's synchronized rst_req_sync
    // deasserts, so it issues here. The command must be BACKPRESSURED, never
    // accepted-and-dropped.
    rst_req <= 1'b1;
    repeat (4) @(posedge clk);          // lock_stage + terminating settled
    swallowed = 0; beats_s = 0;
    bc_s <= 8'd1; addr_s <= 29'h0200; rd_s <= 1'b1;
    repeat (20) @(posedge clk);
    check(swallowed == 0, "T2 locked terminator does not swallow a read command");

    // ── T3 no deadlock: the held read must complete once the lock clears ─────
    rst_req <= 1'b0;
    repeat (3) @(posedge clk);
    rd_s <= 1'b0;
    repeat (20) @(posedge clk);
    check(beats_s >= 1, "T3 the backpressured read completes after unlock");

    // ── T4 regression: an interrupted write burst still finishes on the port ─
    // This is the module's original purpose; the fix must not weaken it.
    repeat (4) @(posedge clk);
    wr_acc_m = 0;
    bc_s <= 8'd4; addr_s <= 29'h1000; wd_s <= 64'hA5A5_0000_0000_0000; wr_s <= 1'b1;
    @(posedge clk);                     // beat 1
    @(posedge clk);                     // beat 2
    rst_req <= 1'b1;                    // core reset lands mid-burst
    @(posedge clk);                     // beat 3 (terminating not yet active)
    repeat (30) @(posedge clk);
    wr_s <= 1'b0;
    check(wr_acc_m == 4, "T4 interrupted 4-beat write burst still completes");

    repeat (4) @(posedge clk);
    $display("errors=%0d", errors);
    if (errors == 0) $display("RESULT: PASS");
    else             $display("RESULT: FAIL");
    $finish;
  end

  initial begin
    #200000;
    $display("FAIL: timeout");
    $display("RESULT: FAIL");
    $finish;
  end

endmodule
`default_nettype wire
