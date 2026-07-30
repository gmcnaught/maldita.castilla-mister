// a2_cycle_gate.vh — [Phase 1 A2] shared per-pixel throughput gate.
//
// Included by the TRILIST benches that need to measure pb's per-pixel cost. Factored
// into one file rather than triplicated so the three copies cannot drift apart.
// Requires the including bench to provide `clk`, `rst`, and a blitter_top instance
// named `blt` (all three TRILIST benches do).
//
// WHY A HIERARCHICAL PROBE: unlike A1's assertion — which deliberately watched a PORT
// so the verdict rested on blitter_top's published interface — the SUBJECT here IS
// internal microarchitecture: pb's state occupancy. `pb` is an FSM state, not an
// interface, and should not become a port to make a test convenient.
//
// TWO numbers, because either alone misleads:
//
//   pb-occupancy = cycles pb is actually working / pixels retired.
//     This is what A2 changes, and ONLY on the dst-read path: 8.00 -> 6.00.
//
//   wall-clock   = cycles from first pb activity to the LAST pixel retiring, / pixels.
//     pa and pb run CONCURRENTLY behind the depth-8 payload FIFO, so end-to-end
//     throughput is max(pa, pb), not pb.
//     [span walk, Phase 3A Task 6] pa USED to cost ~8 cyc per retired pixel: 7 states
//     plus ~1 bbox-rejection cycle, because A_PIX re-entered itself for every
//     non-covered bbox column. The walk now derives each row's covered interval
//     instead of scanning the bbox (A_SEEK/A_PIX/A_ROWY), which deleted that ~1
//     cycle/pixel and replaced it with ~2.9 cycles per ROW: pa fell to ~7.1 cyc/px.
//     [pipeline stage 3b, Phase 3A Task 7] The EXPIRY note below has now FIRED. pa's
//     six mul/addr/issue states became a 6-deep pipeline, so pa dispatches 1 px/cyc
//     (credit-limited) and costs ~1.1 cyc per retired pixel. pa is no longer the
//     binding constraint: wall-clock now tracks pb, and the two printed numbers should
//     agree to ~0.01 cyc/px on a hit-path bench (measured 6.00 / 6.00 on
//     tb_blitter_trilist_add). A wall figure that drifts ABOVE pb again means either
//     texel stalls (B_WAIT) or a regression in the dispatcher's credit accounting.
//
// Reporting only pb-occupancy would overstate the win as 1.33x; reporting only wall
// would make a correctly working A2 look like a no-op. The gate is on pb-occupancy —
// the thing A2 controls — and wall is printed unconditionally so pa's limit cannot hide.
//
// EXPIRY: (FIRED at Task 7 — see above.) The wall commentary held only while pa >= pb;
// pa is now ~1.1 cyc/px, so wall tracks pb and the two numbers converge. The pb figure
// itself does not expire — it measures pb occupancy directly, independent of pa. pb's
// six states are now the whole story for per-pixel throughput.
//
// pb states are referenced HIERARCHICALLY (blt.B_IDLE / blt.B_WR3), not as literals.
// With literals, renumbering pb would make this gate MISCOUNT rather than error — a
// silent wrong number — and that hazard had leaked back into blitter_top.sv as a comment
// forbidding renumbering *because of this file*. A test-side shortcut had become a
// constraint on future RTL work. Binding to the localparams removes both: renumber pb
// freely and this follows.

integer a2_pb_cyc, a2_wall_cyc, a2_pixels, a2_wall_at_last_retire;
reg     a2_started;
initial begin
  a2_pb_cyc = 0; a2_wall_cyc = 0; a2_pixels = 0;
  a2_wall_at_last_retire = 0; a2_started = 1'b0;
end
always @(posedge clk) if (!rst) begin
  // pb is "occupied" whenever it is not parked in B_IDLE with an empty FIFO.
  if ((blt.pb != blt.B_IDLE) || !blt.pf_empty) begin
    a2_pb_cyc  <= a2_pb_cyc + 1;
    a2_started <= 1'b1;
  end
  if (a2_started) a2_wall_cyc <= a2_wall_cyc + 1;
  if (blt.pb == blt.B_WR3) begin             // B_WR3 is single-cycle: one pixel retires
    a2_pixels <= a2_pixels + 1;
    // Anchor the wall span's END at the last retire. Without this the counter keeps
    // running through the frame-end FSM until $finish, inflating wall/px with trailing
    // idle that no pixel paid for — and wall/px is the number the headline delta rests on.
    a2_wall_at_last_retire <= a2_wall_cyc + 1;
  end
end

task a2_report_cycles;
  real pb_avg, wall_avg;
  begin
    if (a2_pixels == 0) begin
      $display("FAIL A2: no pixels retired");
      $finish;
    end
    pb_avg   = $itor(a2_pb_cyc)              / $itor(a2_pixels);
    wall_avg = $itor(a2_wall_at_last_retire) / $itor(a2_pixels);
    $display("A2 pb-occupancy: %0d cyc / %0d px = %.2f cyc/px", a2_pb_cyc, a2_pixels, pb_avg);
    $display("A2 wall-clock  : %0d cyc / %0d px = %.2f cyc/px  (max(pa,pb)-limited)",
             a2_wall_at_last_retire, a2_pixels, wall_avg);
    if (pb_avg > `A2_PB_MAX) begin
      $display("FAIL A2: pb %.2f cyc/px exceeds the %.1f-cycle budget", pb_avg, $itor(`A2_PB_MAX));
      $finish;
    end
    $display("PASS A2: pb %.2f cyc/px", pb_avg);
  end
endtask

// Each including bench `define`s its own budget immediately before the `include`; undef it
// here so a second bench in the SAME compilation unit redefines cleanly instead of erroring.
//
// NO INCLUDE GUARD, deliberately. This is a per-MODULE include, not a per-compilation-unit
// header: every including bench needs its own copy of the counters and the task inside its
// own scope. A `ifndef guard would emit the body only for the FIRST bench — verified, not
// assumed: with a guard, compiling tb_blitter_trilist_add.sv and tb_blitter_trilist_calpha.sv
// in one iverilog invocation fails with
//     tb_blitter_trilist_calpha.sv:129: error: Enable of unknown task `a2_report_cycles'
// i.e. the guard breaks exactly the multi-bench compilation it was meant to protect. The
// `undef` alone is what makes that case work.
`undef A2_PB_MAX
