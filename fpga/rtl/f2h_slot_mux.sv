//============================================================================
//  f2h_slot_mux.sv — arbitration for the SHARED f2h arbiter "reader" slot.
//
//  Two masters time-share one arbiter port: the openbor_video_reader (scanout
//  line fetch + its joy/beacon writebacks) and comp_fb_dma (the WORK->DDR
//  framebuffer copy). This module decides which one drives the slot each cycle.
//
//  ── WHY THIS EXISTS AS A MODULE ──────────────────────────────────────────
//  This logic used to be six inline `wire` assignments in Maldita.sv. That made
//  it UNTESTABLE: no bench can instantiate Maldita.sv (PLLs, HPS, video), so the
//  only way to exercise the arbitration was on hardware — and a device regression
//  is exactly how the previous version's fault was found. Extracted so
//  tb_f2h_slot_mux can drive it directly. Maldita.sv now only wires it up.
//
//  ── THE BUG THIS REPLACES ────────────────────────────────────────────────
//  The previous version gave the copy ABSOLUTE priority:
//      wire rdr_rd = fb_dma_busy ? 1'b0 : rd_ddr_rd;   // reader hard-blocked
//  Its comment justified that with "vblank is long vs the ~0.2 ms copy" — true
//  only while the copy was gated to vblank. Once the copy could run during active
//  display, that assumption died and the reader was starved for the whole copy:
//  15552 qwords ~= 158 us, against a 77 us scanline (16.69 ms / 216). Device
//  symptom: 1-3 thin horizontal lines, drifting because the fabric frame period
//  is not locked to scanout.
//
//  That comment also depended on a SECOND assumption it did not state: that the
//  reader has no reads OUTSTANDING when the copy starts. The old code forced
//  rd_dout_ready low for the whole copy, so any beat already in flight when the
//  copy began was silently DROPPED — the arbiter routed it to the reader (its
//  expectation was correctly queued) and the reader was not listening. At vblank
//  the reader was idle so nothing was in flight; during active display it is not.
//  Beat loss and starvation are separate faults with the same visible signature.
//
//  ── THE CONTRACT ─────────────────────────────────────────────────────────
//  1. The reader WINS the slot whenever it has a pending request. The copy fills
//     the gaps. The reader's duty cycle is ~2% (15552 qwords per 16.69 ms frame,
//     ~1.64M cycles), so the gaps are ample.
//  2. The reader ALWAYS receives its return beats. rd_dout_ready is never gated
//     on the copy — only on the arbiter's own exact-ownership grant.
//  3. The copy cannot be starved indefinitely: after STARVE_MAX consecutive
//     blocked cycles it takes one beat. This makes forward progress STRUCTURAL
//     rather than dependent on the reader's duty cycle, which a future scene or
//     resolution change could alter silently.
//
//     COST TO THE READER — measured, with the condition attached, because a bare
//     number here is a bound future changes must preserve. An earlier draft said
//     "ONE beat (~1 cycle)", which the bench then falsified: that figure holds only
//     when a beat is ready AND the arbiter can accept it immediately. Worst case is
//     8x larger. All three are per escape grant, under CONTINUOUS reader demand
//     (tb_f2h_slot_mux):
//
//       arbiter free, beat ready      ->  1 cycle   (LIVELOCK phase)
//       beat not ready (1 bubble in 4)->  2 cycles  (WRITE-GAP phase, see (c))
//       arbiter busy ~70%             ->  8 cycles  (BUSY-ARBITER phase)
//
//     So: <= 8 cycles measured, against a 72-cycle (one burst) budget and the 158 us
//     the old design cost. The comparison that matters is unchanged; the number is
//     now the one the bench actually produces.
//
//     Stating it this way on purpose. The comment this module replaces failed in
//     exactly this manner — "vblank is long vs the ~0.2 ms copy" was a true bound
//     under an unstated condition, and the condition is what died.
//
//  ── WHY A COMBINATIONAL OWNER SIGNAL IS SAFE HERE ────────────────────────
//  `dma_owns` changing mid-transfer would normally corrupt a burst. It does not
//  here, and ONLY because of two specific properties. If either changes, this
//  reasoning must be redone — do not treat the current safety as inherent:
//
//    (a) The reader's burst READ is issued in ONE cycle. ddr_blitter_arb accepts
//        with `rdr_acc = (state==G_READER) & rdr_rd & ~ddram_busy` and pushes
//        {owner, burstcnt} into its expectation queue at that instant. After that
//        cycle the command belongs to the DDR controller; rdr_addr/rdr_burstcnt
//        no longer matter, and the return beats are routed by QUEUE ORDER, not by
//        who holds the slot. So there is no multi-cycle issue window to protect.
//        (This is what ddr_blitter_arb's "exact read-beat ownership" rewrite buys.)
//
//    (b) comp_fb_dma is a SINGLE-BEAT writer (mem_burstcnt = 8'd1) that holds
//        addr/din/wr stable until accepted (`wr_accept = hold_valid & ~mem_busy`).
//        So revoking the slot between beats merely re-presents the same beat.
//
//    (c) THE ESCAPE RELEASES ON AN ACCEPTED BEAT, NOT ON A TIMER. dma_owns stays
//        asserted while dma_force is high, and dma_force clears only through
//        dma_accept (= dma_owns & dma_wr & ~rdr_busy). So if the escape fires in a
//        cycle where comp_fb_dma is NOT presenting a write, the reader stays blocked
//        until it presents one. The worst case is therefore set by a NEIGHBOURING
//        MODULE'S write cadence, not by anything in this file.
//        Bounded today by comp_fb_dma's read pipeline — work_rd_en -> rd_v1 -> rd_v2
//        -> hold_valid (comp_fb_dma.sv:136-166), a 2-cycle valid pipe plus the hold
//        register — so mem_wr is only low for the few cycles after an accept while the
//        next qword propagates. MEASURED at 2 cycles (tb_f2h_slot_mux WRITE-GAP phase,
//        one write bubble in four), against the 158 us this replaces.
//        If comp_fb_dma ever gains a longer stall — a deeper pipe, a source that can
//        back-pressure, a burst mode — this bound grows with it and must be re-derived.
//        A timer-based release would decouple it, at the cost of granting the slot with
//        no beat to put in it.
//
//  Writes never enter the arbiter's expectation queue ("Writes return no data, so
//  they never touch the expectation queue"), so interleaving a copy write between
//  a reader read-issue and its return beats cannot mis-route a beat.
//
//  Copyright (C) 2026 — GPL-3.0
//============================================================================
`default_nettype none

module f2h_slot_mux #(
    // Consecutive blocked cycles after which the copy is granted one beat. At
    // 98.4375 MHz, 1024 cycles ~= 10.4 us — far longer than any real reader burst
    // (72 qwords), so it never fires in normal operation, and far shorter than a
    // frame, so a pathological reader cannot stall the copy past its deadline.
    parameter [15:0] STARVE_MAX = 16'd1024
) (
    input  wire        clk,
    input  wire        rst,

    // ── copy engine (comp_fb_dma) ────────────────────────────────────────────
    input  wire        dma_active,        // fb_dma_busy: a copy is in progress
    input  wire [7:0]  dma_burstcnt,
    input  wire [31:0] dma_addr,
    input  wire        dma_wr,
    input  wire [63:0] dma_din,
    input  wire [7:0]  dma_be,
    output wire        dma_busy,          // -> comp_fb_dma.mem_busy

    // ── scanout reader (openbor_video_reader) ────────────────────────────────
    input  wire [7:0]  rd_burstcnt,
    input  wire [28:0] rd_addr,
    input  wire        rd_rd,
    input  wire [63:0] rd_din,
    input  wire [7:0]  rd_be,
    input  wire        rd_we,
    output wire        rd_busy,           // -> reader.ddr_busy
    output wire        rd_dout_ready,     // -> reader.ddr_dout_ready

    // ── arbiter reader slot ──────────────────────────────────────────────────
    output wire [7:0]  rdr_burstcnt,
    output wire [28:0] rdr_addr,
    output wire        rdr_rd,
    output wire [63:0] rdr_din,
    output wire [7:0]  rdr_be,
    output wire        rdr_we,
    input  wire        rdr_busy,          // arbiter reader-slot backpressure
    input  wire        rdr_grant,         // arbiter: head expectation is the reader's
    input  wire        ddram_dout_ready,
    input  wire        use_nv,            // native-video reader enabled

    // ── observability ────────────────────────────────────────────────────────
    output wire        dma_owns_o,        // for benches / probes
    output reg  [15:0] starve_cnt         // consecutive cycles the copy was blocked
);

    // The reader is REQUESTING whenever it has a read or a writeback ASSERTED. Once
    // asserted, both are registered and held until accepted (`if (!ddr_busy) ddr_rd
    // <= 1'b0;`), so this is stable across a stall rather than a one-cycle pulse.
    // But ASSERTION itself is poll-gated: the reader only raises ddr_rd/ddr_we
    // after observing !ddr_busy. rd_req therefore CANNOT be used as "the reader
    // wants the slot" — while rd_busy is high the reader wants it and stays
    // silent. That asymmetry is why rd_busy (below) must not report bare copy
    // ownership; the first version did, and the reader never spoke during a copy.
    wire rd_req = rd_rd | rd_we;

    // Anti-starvation: count cycles where the copy wants the slot and the reader is
    // holding it. Cleared when the copy is not blocked OR when it is GRANTED A BEAT.
    //
    // The beat-accept clear is essential, not tidiness. Without it, a reader that
    // requests continuously keeps dma_blocked asserted forever, so the counter never
    // clears, dma_force latches HIGH permanently, and the copy takes the slot for
    // good — the mirror-image starvation, with the reader now the victim. That is
    // exactly what this escape exists to avoid, and the first version of this module
    // had that bug: under continuous demand the reader stalled 2976 cycles and the
    // copy took 2976 beats. Clearing on accept makes the escape a ONE-BEAT release
    // valve: block for STARVE_MAX, take a single beat, hand the slot straight back.
    // Steady-state worst case is therefore 1 copy beat per STARVE_MAX cycles, so the
    // reader keeps >99.9% of the slot even against a pathological copy.
    // All four control wires are declared BEFORE the register that feeds them, because
    // iverilog binds continuous assignments in declaration order. There is no
    // combinational loop despite the apparent cycle (dma_accept -> dma_owns ->
    // dma_force -> starve_cnt -> dma_accept): starve_cnt is a REGISTER, so dma_accept
    // drives its next-state while dma_force reads its current value.
    wire dma_blocked = dma_active & rd_req;
    wire dma_force   = (starve_cnt >= STARVE_MAX);
    wire dma_owns    = dma_active & (~rd_req | dma_force);
    wire dma_accept  = dma_owns & dma_wr & ~rdr_busy;   // a copy beat was taken

    // Cleared when the copy is not blocked OR when it is GRANTED A BEAT.
    //
    // The beat-accept clear is essential, not tidiness. Without it, a reader that
    // requests continuously keeps dma_blocked asserted forever, so the counter never
    // clears, dma_force latches HIGH permanently, and the copy takes the slot for
    // good — the mirror-image starvation, with the reader now the victim. That is
    // exactly what this escape exists to avoid, and the FIRST version of this module
    // had that bug: under continuous demand the reader stalled 2976 cycles while the
    // copy took 2976 beats. Clearing on accept makes the escape a ONE-BEAT release
    // valve: block for STARVE_MAX, take a single beat, hand the slot straight back.
    // Steady-state worst case is 1 copy beat per STARVE_MAX cycles, so the reader
    // keeps >99.9% of the slot even against a pathological continuous copy.
    always @(posedge clk) begin
        if (rst)                            starve_cnt <= 16'd0;
        else if (!dma_blocked | dma_accept) starve_cnt <= 16'd0;
        else if (starve_cnt != 16'hFFFF)    starve_cnt <= starve_cnt + 16'd1;
    end

    assign dma_owns_o = dma_owns;

    assign rdr_burstcnt = dma_owns ? dma_burstcnt      : rd_burstcnt;
    assign rdr_addr     = dma_owns ? dma_addr[28:0]    : rd_addr;
    assign rdr_rd       = dma_owns ? 1'b0              : rd_rd;
    assign rdr_din      = dma_owns ? dma_din           : rd_din;
    assign rdr_be       = dma_owns ? dma_be            : rd_be;
    assign rdr_we       = dma_owns ? dma_wr            : rd_we;

    // THE READER'S VIEW OF BUSY MUST OPEN ITS POLL GATE. Every issue site in
    // openbor_video_reader polls `!ddr_busy` BEFORE asserting ddr_rd/ddr_we
    // (e.g. ST_READ_LINE `if (!fifo_aclr_ddr_active && !ddr_busy)`); only an
    // already-asserted request is held-until-accepted. The first version of this
    // line was `dma_owns ? 1'b1 : rdr_busy`, which is a CIRCULAR WAIT with that
    // protocol: ownership yields only on rd_req, rd_req rises only on !rd_busy,
    // and rd_busy was high whenever the copy owned the slot — so the reader
    // never asked, and the fetch blacked out for the whole 158 us copy exactly
    // as in the pre-module design. Device signature (2026-07-28, a1fix RBF):
    // 4-line bands that are byte-exact copies of lines L-2/L-1 (stale linebuf
    // parity), drifting with the copy phase. tb_f2h_slot_mux's POLL-GATED phase
    // reproduces it; faults 1/2 drove rd_rd directly and could not.
    //
    // So: report busy to the reader ONLY when its request genuinely cannot be
    // accepted this cycle — the escape is holding the slot (dma_owns & rd_req),
    // or the arbiter itself is backpressuring. When the copy owns the slot with
    // no reader request pending, report the ARBITER's state: a !rdr_busy cycle
    // lets the reader's poll gate open, its registered request asserts next
    // cycle, rd_req drops dma_owns combinationally, and the request is presented
    // — the priority rule finally engages. Acceptance semantics stay exact: in
    // every cycle the reader has a request presented (rd_req=1, ~dma_force),
    // rd_busy == rdr_busy, so `if (!ddr_busy) ddr_rd <= 1'b0` still fires
    // precisely on arbiter acceptance, never on a lie.
    assign rd_busy      = (dma_owns & rd_req) | rdr_busy;

    // The copy sees busy unless it owns the slot AND the arbiter can accept.
    // No combinational loop: comp_fb_dma's mem_wr does not depend on mem_busy, and
    // the arbiter's rdr_busy does not depend on rdr_we.
    assign dma_busy     = ~dma_owns | rdr_busy;

    // BEAT DELIVERY IS NEVER GATED ON THE COPY. The arbiter already routes each
    // returned beat to its exact owner via the expectation queue, so rdr_grant is
    // the complete and correct condition. The old design ANDed this with
    // ~fb_dma_busy, which dropped any beat that returned during a copy.
    assign rd_dout_ready = ddram_dout_ready & use_nv & rdr_grant;

endmodule

`default_nettype wire
