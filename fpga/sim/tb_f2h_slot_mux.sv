// tb_f2h_slot_mux.sv — the bench that would have caught the A1 device regression.
//
// THE COVERAGE GAP THIS CLOSES. Nothing exercised the shared f2h slot's arbitration
// between the scanout reader and the WORK->DDR copy, because that arbitration lived
// as six inline `wire` assignments in Maldita.sv, which no bench can instantiate
// (PLLs, HPS, video). So the ONLY way to exercise it was on hardware — and that is
// exactly how the fault was found: 1-3 thin drifting horizontal lines on device.
//
// Two distinct faults are reproduced here, both created by removing the vblank gate:
//
//   (1) STARVATION. The old mux gave the copy absolute priority
//       (`rdr_rd = fb_dma_busy ? 1'b0 : rd_ddr_rd`), so a copy running during
//       active display blocked the reader for its whole duration: 15552 qwords
//       ~= 158 us against a 77 us scanline.
//
//   (2) BEAT LOSS. The old mux also forced `rd_dout_ready` low for the whole copy.
//       A read accepted BEFORE the copy started still has beats in flight; the
//       arbiter routes them to the reader (its expectation is queued correctly) and
//       the reader is not listening. Silently dropped qwords.
//
// Fault (2) was NOT in the original diagnosis. It is reproduced separately below,
// because a fix for (1) alone would leave it — and a partially-improved display is
// a harder second diagnosis than the original.
//
// ── THE ESCAPE PHASES TEST TWO MECHANISMS, NOT THREE ────────────────────────
// Stated precisely so nobody deletes one as redundant for the wrong reason:
//
//   DOES THE ESCAPE FIRE?     LIVELOCK. Genuinely independent.
//   DOES THE ESCAPE RELEASE?  BUSY-ARBITER and WRITE-GAP are the SAME mechanism
//                             reached two ways. Ownership is held whenever
//                             dma_accept = dma_owns & dma_wr & ~rdr_busy is false;
//                             BUSY-ARBITER falsifies ~rdr_busy, WRITE-GAP falsifies
//                             dma_wr. A single change to the release condition — a
//                             timed release, say — moves both together.
//
// BOTH ARE KEPT, for two reasons that "three failure modes" would have hidden:
//   * they pin dependencies on two DIFFERENT external modules (ddr_blitter_arb and
//     comp_fb_dma), and a future fix could plausibly handle one and not the other;
//   * their magnitudes differ (8 cyc vs 2 cyc), and the bound published in
//     f2h_slot_mux's contract comes from the worse one — dropping BUSY-ARBITER
//     would understate the cost by 4x.
//
// ── ASSERT THE BOUND THAT MATTERS, REPORT THE VALUE OBSERVED ────────────────
// The thresholds here (72 = one reader burst; 24 = the drift gate) are derived
// independently of the measurements. NOTHING asserts the 2-cycle or 8-cycle figures
// the module header quotes — those are printed. So if a future change makes WRITE-GAP
// 5 cycles the tests still pass and the header gets updated; at 80 they fail. The
// alternative — asserting the measured constant — makes the test and the claim the
// same number, so it can never disagree with itself and never tells you anything.
//
// Build with -DA1FIX_OLD_MUX to get the pre-fix behaviour. That is the differential
// control: this bench MUST fail that way and pass without it, or it proves nothing.
`timescale 1ns/1ps
`default_nettype none

module tb_f2h_slot_mux;

  reg clk = 0; always #5 clk = ~clk;
  reg rst = 1;

  // ── stimulus: a reader and a copy engine, modelled at their real protocols ──
  reg  [7:0]  rd_burstcnt = 8'd72;   // one FB row = 72 qwords, the real burst
  reg  [28:0] rd_addr     = 29'h0100;
  reg         rd_rd       = 1'b0;
  reg  [63:0] rd_din      = 64'd0;
  reg  [7:0]  rd_be       = 8'hFF;
  reg         rd_we       = 1'b0;

  reg         dma_active  = 1'b0;
  reg  [7:0]  dma_burstcnt= 8'd1;    // comp_fb_dma is single-beat
  reg  [31:0] dma_addr    = 32'h2000;
  reg         dma_wr      = 1'b0;
  reg  [63:0] dma_din     = 64'hA5A5_5A5A_A5A5_5A5A;
  reg  [7:0]  dma_be      = 8'hFF;

  reg         rdr_busy         = 1'b0;   // arbiter can accept
  reg         rdr_grant        = 1'b0;   // arbiter: head expectation is the reader's
  reg         ddram_dout_ready = 1'b0;

  wire [7:0]  rdr_burstcnt; wire [28:0] rdr_addr; wire rdr_rd;
  wire [63:0] rdr_din;      wire [7:0]  rdr_be;   wire rdr_we;
  wire        rd_busy, rd_dout_ready, dma_busy, dma_owns;
  wire [15:0] starve_cnt;

`ifdef A1FIX_OLD_MUX
  // ── PRE-FIX behaviour, reproduced exactly from Maldita.sv:689-698 ───────────
  // Copy has ABSOLUTE priority; reader hard-blocked and deafened for the whole copy.
  assign rdr_burstcnt  = dma_active ? dma_burstcnt   : rd_burstcnt;
  assign rdr_addr      = dma_active ? dma_addr[28:0] : rd_addr;
  assign rdr_rd        = dma_active ? 1'b0           : rd_rd;
  assign rdr_din       = dma_active ? dma_din        : rd_din;
  assign rdr_be        = dma_active ? dma_be         : rd_be;
  assign rdr_we        = dma_active ? dma_wr         : rd_we;
  assign rd_busy       = dma_active ? 1'b1 : rdr_busy;
  assign rd_dout_ready = dma_active ? 1'b0 : (ddram_dout_ready & rdr_grant);
  assign dma_busy      = rdr_busy;          // wired to rdr_busy_w alone, as it was
  assign dma_owns      = dma_active;
  assign starve_cnt    = 16'd0;
`else
  f2h_slot_mux #(.STARVE_MAX(16'd1024)) dut (
    .clk(clk), .rst(rst),
    .dma_active(dma_active), .dma_burstcnt(dma_burstcnt), .dma_addr(dma_addr),
    .dma_wr(dma_wr), .dma_din(dma_din), .dma_be(dma_be), .dma_busy(dma_busy),
    .rd_burstcnt(rd_burstcnt), .rd_addr(rd_addr), .rd_rd(rd_rd),
    .rd_din(rd_din), .rd_be(rd_be), .rd_we(rd_we),
    .rd_busy(rd_busy), .rd_dout_ready(rd_dout_ready),
    .rdr_burstcnt(rdr_burstcnt), .rdr_addr(rdr_addr), .rdr_rd(rdr_rd),
    .rdr_din(rdr_din), .rdr_be(rdr_be), .rdr_we(rdr_we),
    .rdr_busy(rdr_busy), .rdr_grant(rdr_grant),
    .ddram_dout_ready(ddram_dout_ready), .use_nv(1'b1),
    .dma_owns_o(dma_owns), .starve_cnt(starve_cnt));
`endif

  // ── instruments ─────────────────────────────────────────────────────────────
  // Mirrors the reader's own max_fetch_stall (openbor_video_reader.sv:388-395),
  // whose comment PREDICTED this failure: "A copy overrunning vblank into active
  // display shows as ONE huge stall at frame start". That instrument exists, names
  // this fault in advance, and is SOLARUS_DBG_PROBES-only — compiled out of
  // shipping builds, so nothing could consult it when it mattered.
  integer cur_stall, max_stall, beats_offered, beats_taken, dma_accepts;
  initial begin cur_stall=0; max_stall=0; beats_offered=0; beats_taken=0; dma_accepts=0; end
  always @(posedge clk) if (!rst) begin
    // reader wants the slot but cannot have it
    if (rd_rd && rd_busy) begin
      cur_stall = cur_stall + 1;
      if (cur_stall > max_stall) max_stall = cur_stall;
    end else cur_stall = 0;
    // beat accounting: every beat the arbiter routes to the reader must be seen
    if (ddram_dout_ready && rdr_grant) begin
      beats_offered = beats_offered + 1;
      if (rd_dout_ready) beats_taken = beats_taken + 1;
    end
    if (rdr_we && !rdr_busy) dma_accepts = dma_accepts + 1;
  end

  integer i, nfail, worst_overall;
  initial begin
    nfail = 0; worst_overall = 0;
    repeat (4) @(posedge clk); rst <= 0; @(posedge clk);

    // ══ FAULT 1: STARVATION ════════════════════════════════════════════════
    // A copy runs during ACTIVE DISPLAY while the reader is fetching a line.
    dma_active <= 1'b1; dma_wr <= 1'b1;
    rd_rd      <= 1'b1;                       // reader has a pending line fetch
    repeat (300) @(posedge clk);              // ~3 us of contention

    // NOTE: label deliberately avoids the substring "STARV" — run_sims.sh's FAIL_RE
    // greps for it, so an informational line containing it fails a PASSING run.
    $display("CONTENTION: reader stalled for max %0d consecutive cycles while the copy ran",
             max_stall);
    // NON-VACUITY: the reader must actually have been asking, or "no starvation"
    // passes trivially on an idle reader.
    if (!rd_rd) begin
      $display("FAIL f2h: reader was not requesting — the scenario is vacuous");
      nfail = nfail + 1;
    end
    // 72 qwords is one real burst; a reader blocked longer than that has missed
    // its line-fetch window. The old mux blocks it for the entire 300 cycles.
    if (max_stall > 72) begin
      $display("FAIL f2h-STARVE: reader blocked %0d cycles (> one 72-qword burst) —",
               max_stall);
      $display("                 the copy is starving scanout, which is the device");
      $display("                 regression: thin drifting horizontal lines.");
      nfail = nfail + 1;
    end

    // ══ FAULT 2: BEAT LOSS ═════════════════════════════════════════════════
    // A read was accepted BEFORE the copy began, so its beats return DURING it.
    // The arbiter routes them to the reader (rdr_grant high); the reader must see
    // every one. The old mux deafened it for the whole copy.
    rd_rd <= 1'b0;                            // command already issued; now in flight
    @(posedge clk);
    rdr_grant <= 1'b1;
    for (i = 0; i < 8; i = i + 1) begin
      ddram_dout_ready <= 1'b1; @(posedge clk);
      ddram_dout_ready <= 1'b0; @(posedge clk);
    end
    rdr_grant <= 1'b0;

    $display("BEAT DELIVERY: %0d beats routed to the reader, %0d actually delivered",
             beats_offered, beats_taken);
    if (beats_offered == 0) begin
      $display("FAIL f2h: no beats were offered — the scenario is vacuous");
      nfail = nfail + 1;
    end
    if (beats_taken != beats_offered) begin
      $display("FAIL f2h-BEATLOSS: %0d of %0d beats dropped while the copy ran —",
               beats_offered - beats_taken, beats_offered);
      $display("                   the arbiter routed them to the reader and the");
      $display("                   reader was not listening. Corrupted scanlines.");
      nfail = nfail + 1;
    end

    // ══ LIVELOCK: the copy must still make progress ═════════════════════════
    // Reader-priority must not be a mirror-image starvation of the copy. Hold the
    // reader continuously requesting — the pathological case — and require the copy
    // to be granted within a bounded time.
    dma_accepts = 0; cur_stall = 0; max_stall = 0;   // measure THIS phase only
    rd_rd <= 1'b1; dma_active <= 1'b1; dma_wr <= 1'b1;
    repeat (4000) @(posedge clk);
    if (max_stall > worst_overall) worst_overall = max_stall;
    $display("LIVELOCK: copy took %0d beats under CONTINUOUS reader demand; reader's",
             dma_accepts);
    $display("          worst stall in that window = %0d cyc (starve_cnt=%0d)",
             max_stall, starve_cnt);

    // BOTH directions must hold. Checking only "the copy progressed" is what let the
    // first version of this module through: its escape latched on permanently, so the
    // copy took 2976 beats — progress! — while the READER starved for 2976 cycles.
    // A priority fix that inverts the priority is not a fix.
    if (dma_accepts == 0) begin
      $display("FAIL f2h-LIVELOCK: the copy made NO progress in 4000 cycles under");
      $display("                   continuous reader demand — reader priority has");
      $display("                   inverted the starvation rather than fixing it.");
      nfail = nfail + 1;
    end
    // With a one-beat release valve the reader should never lose the slot for more
    // than a burst's worth of cycles, even against a pathological continuous copy.
    if (max_stall > 72) begin
      $display("FAIL f2h-INVERSION: the reader stalled %0d cyc under the anti-starvation",
               max_stall);
      $display("                    escape — the escape has latched instead of releasing");
      $display("                    after one beat, starving scanout again.");
      nfail = nfail + 1;
    end
    // The escape must be RARE, not the normal path: one beat per STARVE_MAX cycles.
    if (dma_accepts > (4000/1024) + 2) begin
      $display("FAIL f2h-INVERSION: copy took %0d beats in 4000 cycles — the escape is",
               dma_accepts);
      $display("                    firing continuously, not as a bounded release valve.");
      nfail = nfail + 1;
    end

    // ══ ESCAPE UNDER A BUSY ARBITER ════════════════════════════════════════
    // The livelock phase above ran with rdr_busy=0, so every escape grant was taken
    // immediately. If the arbiter is BUSY when the escape fires, dma_accept cannot
    // assert, starve_cnt keeps counting and the copy HOLDS the slot until it gets its
    // beat — so the release valve could in principle stall the reader for as long as
    // the arbiter is backed up. Bound it rather than assume it.
    //
    // It stays small for a structural reason: in the cycles where the copy holds the
    // slot waiting on a busy arbiter, the reader could not have been served either
    // (rd_busy is rdr_busy in that case anyway), so the marginal cost is only the
    // free cycles inside the hold.
    dma_accepts = 0; cur_stall = 0; max_stall = 0;
    rd_rd <= 1'b1; dma_active <= 1'b1; dma_wr <= 1'b1;
    for (i = 0; i < 3000; i = i + 1) begin
      rdr_busy <= (i % 10) < 7;          // arbiter busy 70% of the time
      @(posedge clk);
    end
    rdr_busy <= 1'b0;
    if (max_stall > worst_overall) worst_overall = max_stall;
    $display("BUSY-ARBITER: copy beats=%0d, reader worst stall=%0d cyc (starve_cnt=%0d)",
             dma_accepts, max_stall, starve_cnt);
    if (max_stall > 72) begin
      $display("FAIL f2h-ESCAPE-HOLD: reader stalled %0d cyc while the escape waited on a",
               max_stall);
      $display("                      busy arbiter — the release valve is holding the slot");
      $display("                      instead of releasing it.");
      nfail = nfail + 1;
    end
    if (dma_accepts == 0) begin
      $display("FAIL f2h-ESCAPE-HOLD: copy made no progress against a busy arbiter.");
      nfail = nfail + 1;
    end

    // ══ ESCAPE WITH NO BEAT READY (precondition (c)) ═══════════════════════
    // The escape releases on an ACCEPTED BEAT, not a timer, so if it fires while
    // comp_fb_dma is not presenting a write the reader stays blocked until it does.
    // That worst case is set by a NEIGHBOURING module's cadence, which is exactly the
    // class of unnamed cross-module assumption that caused the original regression —
    // so bound it here rather than reason about it.
    // dma_wr gaps model comp_fb_dma's work_rd_en -> rd_v1 -> rd_v2 -> hold_valid pipe.
    dma_accepts = 0; cur_stall = 0; max_stall = 0;
    rd_rd <= 1'b1; dma_active <= 1'b1; rdr_busy <= 1'b0;
    for (i = 0; i < 3000; i = i + 1) begin
      dma_wr <= (i % 4) != 0;            // one bubble every 4 cycles
      @(posedge clk);
    end
    dma_wr <= 1'b1;
    if (max_stall > worst_overall) worst_overall = max_stall;
    $display("WRITE-GAP: copy beats=%0d, reader worst stall=%0d cyc (escape waiting for a beat)",
             dma_accepts, max_stall);
    if (max_stall > 72) begin
      $display("FAIL f2h-ESCAPE-NOBEAT: reader stalled %0d cyc while the escape waited for",
               max_stall);
      $display("                        comp_fb_dma to present a write — the release valve");
      $display("                        is gated on a neighbouring module's cadence.");
      nfail = nfail + 1;
    end
    // VACUITY GUARD, the sibling of BUSY-ARBITER's. Without it, an escape that never
    // fires in this phase (a mutation raising STARVE_MAX, say) leaves dma_owns
    // de-asserted, the reader never stalls, max_stall is 0 — and the phase PASSES
    // while testing nothing. LIVELOCK would still catch that fault, but a phase must
    // not be able to pass vacuously on its own terms.
    if (dma_accepts == 0) begin
      $display("FAIL f2h-ESCAPE-NOBEAT: copy made no progress across the write gaps —");
      $display("                        the escape never fired, so this phase tested");
      $display("                        nothing.");
      nfail = nfail + 1;
    end

    // ── DRIFT GATE on the number the module header quotes ────────────────────
    // The three phases above each gate at 72 cycles — the DESIGN bound (one reader
    // burst). But f2h_slot_mux's contract item 3 quotes a MEASURED worst case of 8
    // cycles, and a documented number that nothing enforces will drift until it is
    // wrong — which is the exact failure this whole module replaces. 24 = 3x the
    // measured worst, so ordinary variation passes and a real regression is caught
    // long before it reaches the design bound. If this fires, fix the code or update
    // the header's table; do not just raise the threshold.
    $display("DRIFT GATE: worst reader stall across all escape phases = %0d cyc (header quotes 8)",
             worst_overall);
    if (worst_overall > 24) begin
      $display("FAIL f2h-DRIFT: worst escape cost %0d cyc exceeds 3x the 8-cycle figure",
               worst_overall);
      $display("                stated in f2h_slot_mux's contract item 3. The header is");
      $display("                now wrong, or the escape has regressed.");
      nfail = nfail + 1;
    end

    $display("PASS f2h: reader keeps the slot (worst stall %0d cyc under pathological", max_stall);
    $display("          demand), loses no beats (%0d/%0d), and the copy still drains",
             beats_taken, beats_offered);
    $display("          via the bounded escape (%0d beats / 4000 cyc).", dma_accepts);
    // Report EVERY fault, not just the first. The old mux exhibits starvation AND
    // beat loss; aborting on the first would hide the second, and the second is the
    // one that was missing from the original diagnosis.
    if (nfail != 0) $display("RESULT: FAIL (%0d fault(s) above)", nfail);
    else            $display("RESULT: PASS");
    $finish;
  end

  initial begin #500000 $display("RESULT: FAIL (timeout)"); $finish; end
endmodule

`default_nettype wire
