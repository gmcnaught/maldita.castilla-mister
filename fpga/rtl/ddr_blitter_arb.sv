//============================================================================
//  ddr_blitter_arb.sv — 2-master f2h DDR arbiter (reader + blitter)
//
//  fpga-hw-blitter #003 iteration 7: EXACT read-beat ownership.
//
//  Iterations 2-6 routed read-return beats by GRANT STATE: rdr_grant/blt_grant
//  were state equalities the consumers AND with ddram_dout_ready. That is only
//  correct while every response lands inside its own grant window. Device
//  evidence 2026-07-26 (.62, SOLARUS_DBG_PROBES RBF): under game-side DDR
//  contention an f2h response can arrive later than the G_BLT_RD borrow window
//  (BLT_QUIET_MAX), and the old blt_abort then DISCARDED the expectation — the
//  late beat was delivered to whichever master happened to be granted next.
//  One mis-steered beat shifts every subsequent single-outstanding blitter
//  read by one qword (S_RD_WAIT captures the previous read's data), which
//  decodes as garbage TRILIST vertices: huge clipped triangles that grind
//  S_TRI_PIX for 0.6-14 s with no completion — the in-game "fabric pause"
//  (and, with the stock 200 ms host budget, the tearing that follows the
//  ring stomp). Engine-free soak never crossed the latency window, which is
//  why the fabric looked healthy as a sole producer.
//
//  Fix: the f2h port returns read data strictly IN COMMAND ORDER, so exact
//  routing is knowable at accept time. Every accepted read pushes
//  {owner, beats} into a small expectation queue; EVERY returned beat is
//  routed to the queue head's owner and drains it. The grant FSM still
//  serializes commands (reader = default owner, blitter borrows gaps), but
//  beat routing no longer depends on what state the FSM is in when the data
//  comes back:
//   - a late blitter beat is still delivered to the blitter (no S_RD_WAIT
//     park, no qword shift), even if the borrow window timed out long ago;
//   - reader beats can never be stolen by the blitter or vice versa;
//   - the borrow timeout (blt_abort) now releases only the GRANT so reader
//     service resumes — the expectation stays queued until its beat arrives.
//  The old rd_out/quiet/drift_clr heuristics are replaced by the queue's
//  exact per-owner outstanding counts. A truly LOST beat (never returned —
//  not observed on device; the f2h does not drop read data once the command
//  is accepted) would hold the queue head: a deep last-resort flush restores
//  arbiter sanity after FLUSH_QUIET_MAX beat-less cycles.
//
//  Set ENABLE=0 to make the blitter port inert (reader owns the bus = normal core).
//
//  Copyright (C) 2026 — GPL-3.0
//============================================================================
`default_nettype none

module ddr_blitter_arb #(
    parameter ENABLE = 1'b1,
    // lost-beat last-resort flush window (cycles with expectations queued and no
    // beat). Parameter so the sim can exercise the flush without 1M-cycle waits.
    parameter [19:0] FLUSH_QUIET_MAX = 20'hFFFFF   // ~10.6 ms @ 98.4375 MHz
) (
    input  wire        clk,
    input  wire        reset,

    // reader master (m0) — openbor_video_reader (time-shared with comp_fb_dma writes)
    input  wire [7:0]  rdr_burstcnt,
    input  wire [28:0] rdr_addr,
    input  wire        rdr_rd,
    input  wire [63:0] rdr_din,
    input  wire [7:0]  rdr_be,
    input  wire        rdr_we,
    output wire        rdr_busy,
    output wire        rdr_grant,        // AND with ddram_dout_ready for reader

    // blitter master (m1) — blitter_top (via vram_demux DDR side)
    input  wire [7:0]  blt_burstcnt,     // beats in the current blitter burst (>=1)
    input  wire [28:0] blt_addr,
    input  wire        blt_rd,
    input  wire [63:0] blt_din,
    input  wire [7:0]  blt_be,
    input  wire        blt_we,
    output wire        blt_busy,
    output wire        blt_grant,        // AND with ddram_dout_ready for blitter

    // shared DDRAM (f2h) port
    input  wire        ddram_busy,
    input  wire        ddram_dout_ready,
    output reg  [7:0]  ddram_burstcnt,
    output reg  [28:0] ddram_addr,
    output reg         ddram_rd,
    output reg  [63:0] ddram_din,
    output reg  [7:0]  ddram_be,
    output reg         ddram_we,
    // DEBUG (#34): {reader-beats-outstanding, state[1:0]} — grant-FSM state plus
    // whether the reader still has read beats in flight (lend gate closed).
    output wire  [2:0] dbg
);
    // gate the blitter off entirely when disabled
    wire b_rd = ENABLE & blt_rd;
    wire b_we = ENABLE & blt_we;

    // a burstcnt of 0 would underflow the write-beat counter / queue a 0-beat
    // expectation. No current master emits 0 (comp_pipeline ties mem_rd off
    // while its mem_burstcnt=0) — this is a guard, not a behavior change.
    wire [7:0] b_burst_eff = (blt_burstcnt == 8'd0) ? 8'd1 : blt_burstcnt;
    wire [7:0] r_burst_eff = (rdr_burstcnt == 8'd0) ? 8'd1 : rdr_burstcnt;

    localparam [2:0] G_READER=3'd0, G_BLT=3'd1, G_BLT_RD=3'd2, G_BLT_WR=3'd3;
    reg [2:0] state;

    // ── expectation queue: one entry per ACCEPTED read command, in accept order.
    // entry = {owner (1=blitter), beats[7:0]}. The f2h returns read data strictly
    // in command order, so the queue head names the owner of every arriving beat.
    // Depth 8 (5-bit wrap pointers): the reader keeps at most a handful of line
    // bursts in flight (the old rd_out counter topped out well under 8 commands)
    // and the grant FSM serializes blitter reads to one outstanding.
    localparam OWN_R = 1'b0, OWN_B = 1'b1;
    localparam XQ_AW = 3;                       // depth 8
    reg [8:0]        xq_mem [0:(1<<XQ_AW)-1];
    reg [XQ_AW:0]    xq_wr, xq_rd;
    wire             xq_empty = (xq_wr == xq_rd);
    wire [8:0]       xq_head  = xq_mem[xq_rd[XQ_AW-1:0]];
    wire             head_own = xq_head[8];

    // command accepts (same conditions the mux below forwards to the f2h)
    wire rdr_acc = (state == G_READER) & rdr_rd & ~ddram_busy;
    wire blt_acc = (state == G_BLT)    & b_rd   & ~ddram_busy;

    // beat arrival + head bookkeeping. head_rem mirrors the head entry's
    // remaining beats (the queue memory is written only at push).
    reg  [7:0] head_rem;
    wire       beat      = ddram_dout_ready & ~xq_empty;
    wire       head_last = beat & (head_rem == 8'd1);

    // per-owner outstanding read beats — exact (attributed by queue owner).
    // rdr_out gates lending (reader bursts are never interleaved with borrows);
    // blt_out is the G_BLT_RD hold/exit condition.
    reg [9:0] rdr_out;
    reg [9:0] blt_out;
    wire      rdr_idle = (rdr_out == 10'd0);

    // [bounded borrow, iteration 7] the borrow timeout releases only the GRANT:
    // the expectation stays queued, so the late beat still routes to the blitter.
    localparam [10:0] BLT_QUIET_MAX = 11'd1024;
    reg [10:0] bquiet;
    always @(posedge clk) begin
        if (reset)                                                   bquiet <= 11'd0;
        else if ((state != G_BLT_RD) | (beat & (head_own == OWN_B))) bquiet <= 11'd0;
        else if (bquiet != BLT_QUIET_MAX)                            bquiet <= bquiet + 11'd1;
    end
    wire blt_abort = (bquiet >= BLT_QUIET_MAX);

    // [lost-beat last resort] a response the f2h never returns (not device-
    // observed; guards boot-time bridge-down reads) would hold the queue head
    // and freeze both outstanding counts forever. After FLUSH_QUIET_MAX cycles
    // with expectations queued and no beat, drop everything and start clean.
    // The blitter's S_RD_WAIT stays parked in that pathological case (it has no
    // retry), but the READER regains full service instead of both wedging.
    reg [19:0] fquiet;
    wire       flush = (fquiet == FLUSH_QUIET_MAX);
    always @(posedge clk) begin
        if (reset | xq_empty | ddram_dout_ready) fquiet <= 20'd0;
        else if (~&fquiet)                       fquiet <= fquiet + 20'd1;
    end

    // queue + counters
    always @(posedge clk) begin
        if (reset | flush) begin
            xq_wr <= {(XQ_AW+1){1'b0}}; xq_rd <= {(XQ_AW+1){1'b0}};
            head_rem <= 8'd0; rdr_out <= 10'd0; blt_out <= 10'd0;
        end else begin
            // push (reader and blitter accepts are mutually exclusive by state)
            if (rdr_acc | blt_acc) begin
                xq_mem[xq_wr[XQ_AW-1:0]] <= rdr_acc ? {OWN_R, r_burst_eff}
                                                    : {OWN_B, b_burst_eff};
                xq_wr <= xq_wr + 1'b1;
                if (xq_empty) head_rem <= rdr_acc ? r_burst_eff : b_burst_eff;
            end
            // pop one beat off the head
            if (beat) begin
                if (head_last) begin
                    xq_rd <= xq_rd + 1'b1;
                    // arm the next head: the entry after xq_rd, or the one being
                    // pushed this same cycle when the queue would otherwise empty.
                    if ((xq_rd + 1'b1) != xq_wr)
                        head_rem <= xq_mem[xq_rd[XQ_AW-1:0] + 1'b1][7:0];
                    else if (rdr_acc | blt_acc)
                        head_rem <= rdr_acc ? r_burst_eff : b_burst_eff;
                    else
                        head_rem <= 8'd0;
                end else
                    head_rem <= head_rem - 8'd1;
            end
            // exact per-owner outstanding counts
            case ({rdr_acc, (beat & (head_own == OWN_R))})
                2'b10: rdr_out <= rdr_out + {2'd0, r_burst_eff};
                2'b01: rdr_out <= rdr_out - 10'd1;
                2'b11: rdr_out <= rdr_out + {2'd0, r_burst_eff} - 10'd1;
                default: ;
            endcase
            case ({blt_acc, (beat & (head_own == OWN_B))})
                2'b10: blt_out <= blt_out + {2'd0, b_burst_eff};
                2'b01: blt_out <= blt_out - 10'd1;
                2'b11: blt_out <= blt_out + {2'd0, b_burst_eff} - 10'd1;
                default: ;
            endcase
        end
    end

    // blitter WRITE burst progress (G_BLT_WR): beats counted by !busy accepts.
    // Writes return no data, so they never touch the expectation queue.
    reg [7:0] wr_left;
    always @(posedge clk) begin
        if (reset) wr_left <= 8'd0;
        else case (state)
            G_BLT:    if (b_we & ~ddram_busy) wr_left <= b_burst_eff - 8'd1;
            G_BLT_WR: if (b_we & ~ddram_busy & (wr_left != 8'd0)) wr_left <= wr_left - 8'd1;
            default: ;
        endcase
    end

    // grant FSM: reader is the DEFAULT owner; the blitter borrows a burst in a
    // proven-quiescent gap (no reader beats in flight), then yields. G_BLT_RD
    // is held until the blitter's beats drain — or blt_abort releases the GRANT
    // early (expectation kept; the beat routes by owner whenever it arrives).
    always @(posedge clk) begin
        if (reset | flush) state <= G_READER;
        else case (state)
            G_READER:
                // lend ONLY when the reader has no burst in flight (rdr_idle) and
                // isn't requesting — so its scanline fetches are never interrupted
                if (rdr_idle & ~rdr_rd & ~rdr_we & ~ddram_busy & (b_rd | b_we))
                    state <= G_BLT;
            G_BLT:
                if      (b_rd & ~ddram_busy)               state <= G_BLT_RD;  // await read beats
                else if (b_we & ~ddram_busy)
                    state <= (b_burst_eff==8'd1) ? G_READER : G_BLT_WR;        // 1-beat write done now
                else if (~b_rd & ~b_we)                    state <= G_READER;
                // else: blitter command stalled by ddram_busy -> hold G_BLT
            G_BLT_RD:
                // leave on the LAST blitter beat's cycle (same latency as iter 6),
                // or if the beats already drained, or on the borrow timeout.
                if      (beat & (head_own == OWN_B) & (blt_out == 10'd1)) state <= G_READER;
                else if (blt_out == 10'd0)                 state <= G_READER;  // already drained
                else if (blt_abort)                        state <= G_READER;  // grant released; expectation KEPT
            G_BLT_WR:
                if (b_we & ~ddram_busy & (wr_left == 8'd1)) state <= G_READER; // last write accepted
            default: state <= G_READER;
        endcase
    end

    assign dbg       = {~rdr_idle, state[1:0]};
    // Beat routing is by EXPECTATION OWNER, not grant state: consumers AND these
    // with ddram_dout_ready, so each must be high exactly when the arriving beat
    // belongs to that master — regardless of who currently holds the bus grant.
    assign rdr_grant = ~xq_empty & (head_own == OWN_R);
    assign blt_grant = ~xq_empty & (head_own == OWN_B);
    assign rdr_busy  = ddram_busy | (state != G_READER);
    assign blt_busy  = ddram_busy | ((state != G_BLT) & (state != G_BLT_WR));

    // mux to DDRAM. CRITICAL: assert ddram_rd ONLY in G_BLT. The blitter's
    // request may still be high into G_BLT_RD; forwarding it there could latch
    // a SECOND read during the latency window (a duplicate command the
    // expectation queue never saw). ddram_we is asserted in G_BLT and G_BLT_WR
    // for multi-beat write streaming.
    always @(*) begin
        if (state == G_READER) begin
            ddram_burstcnt = rdr_burstcnt; ddram_addr = rdr_addr; ddram_rd = rdr_rd;
            ddram_din = rdr_din; ddram_be = rdr_be; ddram_we = rdr_we;
        end else begin
            ddram_burstcnt = b_burst_eff; ddram_addr = blt_addr;
            ddram_rd = (state == G_BLT) ? b_rd : 1'b0;     // read command only in G_BLT
            ddram_we = ((state == G_BLT) | (state == G_BLT_WR)) ? b_we : 1'b0;
            ddram_din = blt_din; ddram_be = blt_be;
        end
    end
endmodule
`default_nettype wire
