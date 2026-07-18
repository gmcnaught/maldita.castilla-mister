// comp_fb_dma.sv — vblank WORK→DDR framebuffer raster burst-DMA.
//
// Replaces the on-chip WORK→SCAN(BRAM) snapshot (fbram_snapshot) with a copy of the
// composited WORK buffer out to a reserved DDR3 framebuffer, which the MiSTer
// framework's `ascal` then scans out (FB_EN + FB_FORMAT=RGB565). This frees the 160
// M10K of the SCAN buffer so the app-surface BRAM fits (see the DDR-scanout plan).
//
// On a `start` pulse (issued at scanout vblank), it walks WORK in raster order
// qw = 0..FB_QWORDS-1 (19200 qwords = 320x240 @ 4 RGB565 px/qword; lane0 = leftmost),
// reading the WORK read port (registered, 1-cycle latency, same shape as comp_fbram
// rd_*), and burst-writes each 64-bit qword to DDR at mem_addr = fb_base_qw + qw via a
// mem_* write master that mirrors blitter_top's existing master (single-beat writes,
// mem_be=0xFF). It honours mem_busy back-pressure exactly like blitter_top's S_WR_WAIT:
// mem_wr/addr/din are HELD until the bus accepts (~mem_busy), so a stalled f2h write
// FIFO can never drop a beat. `busy` is asserted from `start` until the final accepted
// write.
//
// Byte/lane order is identical to the WORK qword layout ({lane3,lane2,lane1,lane0},
// lane0 = leftmost pixel) written linearly, which is exactly how ascal reads
// FB_FORMAT=5'b00100 (16bpp RGB565) at FB_STRIDE=640 bytes (row = 320 px = 80 qwords;
// 240 rows = 19200 qwords; contiguous, no inter-row padding since 80 qwords/row).
//
// Copyright (C) 2026 — GPL-3.0
`default_nettype none
module comp_fb_dma #(
    parameter integer FB_QWORDS = 19200,  // 320*240/4
    parameter integer AW        = 15,     // WORK qword-address width (2^15 > 19200)
    parameter integer MAW       = 32      // DDR mem_* qword-address width (mirrors blitter_top master)
)(
    input  wire            clk,
    input  wire            rst,

    // ── trigger / status ───────────────────────────────────────────────────────
    input  wire            vs,          // scanout vblank (reserved; caller edge-detects → start, per fbram_snapshot)
    input  wire            start,       // 1-cyc pulse: begin a WORK→DDR copy
    output reg             busy,        // high for the duration of the copy
    input  wire [MAW-1:0]  fb_base_qw,  // DDR qword base of the framebuffer slot

    // ── WORK read port (mux onto comp_fbram rd_* while busy) ─────────────────────
    output reg             work_rd_en,
    output reg  [AW-1:0]   work_rd_qw,
    input  wire [63:0]     work_rd_qword,   // registered, valid 1 cyc after work_rd_qw/en

    // ── DDR write master (mirrors blitter_top's mem_* master) ────────────────────
    output wire            mem_wr,
    output wire [MAW-1:0]  mem_addr,        // qword address = fb_base_qw + write index
    output wire [7:0]      mem_burstcnt,    // single-beat (8'd1); power-of-2 runs are a later opt
    output wire [63:0]     mem_din,
    output wire [7:0]      mem_be,
    input  wire            mem_busy         // held high while the bus cannot accept a beat
);
    localparam [AW:0] NQW = FB_QWORDS[AW:0];
    localparam [AW:0] ONE = {{(AW){1'b0}}, 1'b1};

    // ── cursor state ──────────────────────────────────────────────────────────────
    reg [AW:0]   rptr;         // next WORK qw to READ  (0..NQW)
    reg [AW:0]   wcnt;         // qwords WRITTEN so far (0..NQW) == current write index

    // ── read-latency pipeline ─────────────────────────────────────────────────────
    // The WORK read has a TWO-cycle latency to captured data: one cycle for this module's
    // registered `work_rd_en` output, one for comp_fbram's registered read (same as
    // fbram_snapshot's documented v1→v2). rd_v1 marks the read issued last cycle; rd_v2 is
    // STICKY ("data ready on work_rd_qword") — it stays high until captured, so if the write
    // is back-pressured the datum simply waits (work_rd_qword persists while no new read is
    // issued). rd_busy holds while a single read is outstanding — one at a time keeps the
    // capture order == write order == address order.
    reg          rd_busy;
    reg          rd_v1, rd_v2;

    // ── write-side hold slot ──────────────────────────────────────────────────────
    reg          hold_valid;   // a captured qword is waiting to be written to DDR
    reg [63:0]   hold_data;    // the qword currently presented to the mem master

    // ── mem master: drive DIRECTLY from the hold slot (mem_wr held until accepted) ──
    // A write is ACCEPTED the cycle (hold_valid & ~mem_busy). Until then addr/din/wr are
    // stable — the blitter_top S_WR_WAIT discipline (drop wr only once ~mem_busy).
    assign mem_wr       = busy & hold_valid;
    assign mem_addr     = fb_base_qw + {{(MAW-(AW+1)){1'b0}}, wcnt};
    assign mem_din      = hold_data;
    assign mem_be       = 8'hFF;
    assign mem_burstcnt = 8'd1;

    // The hold slot is free THIS cycle iff it is empty, or its write is accepted now.
    wire wr_accept = hold_valid & ~mem_busy;
    wire hold_free = ~hold_valid | wr_accept;
    // Capture the ready read datum into the hold slot this cycle.
    wire cap_fire  = rd_v2 & hold_free;
    // Issue the next read when nothing is outstanding, or the outstanding datum is being
    // captured this very cycle (overlap read[j+1] with write[j]).
    wire can_issue = (rptr < NQW) & (~rd_busy | cap_fire);

    always @(posedge clk) begin
        if (rst) begin
            busy       <= 1'b0;
            work_rd_en <= 1'b0;
            rptr       <= {(AW+1){1'b0}};
            wcnt       <= {(AW+1){1'b0}};
            rd_busy    <= 1'b0;
            rd_v1      <= 1'b0;
            rd_v2      <= 1'b0;
            hold_valid <= 1'b0;
        end else begin
            work_rd_en <= 1'b0;   // default: single-cycle read strobe

            if (!busy) begin
                rd_busy <= 1'b0; rd_v1 <= 1'b0; rd_v2 <= 1'b0; hold_valid <= 1'b0;
                if (start) begin
                    busy <= 1'b1;
                    rptr <= {(AW+1){1'b0}};
                    wcnt <= {(AW+1){1'b0}};
                end
            end else begin
                // 1) read-latency shift: v1 → v2 (v2 sticky until captured).
                if (rd_v1) begin rd_v2 <= 1'b1; rd_v1 <= 1'b0; end

                // 2) WRITE acceptance — drain the hold slot into DDR (in-order == wcnt).
                if (wr_accept) begin
                    hold_valid <= 1'b0;          // may be re-set by capture below (last-wins)
                    wcnt       <= wcnt + ONE;
                end

                // 3) CAPTURE — move the ready read datum into the (now-free) hold slot.
                if (cap_fire) begin
                    hold_valid <= 1'b1;
                    hold_data  <= work_rd_qword;
                    rd_v2      <= 1'b0;          // consumed
                    rd_busy    <= 1'b0;          // may be re-set by issue below (last-wins)
                end

                // 4) ISSUE — start the next WORK read (registered strobe → data 2 cyc later).
                if (can_issue) begin
                    work_rd_en <= 1'b1;
                    work_rd_qw <= rptr[AW-1:0];
                    rptr       <= rptr + ONE;
                    rd_busy    <= 1'b1;
                    rd_v1      <= 1'b1;
                end

                // 5) DONE — every qword written.
                if (wcnt == NQW) busy <= 1'b0;
            end
        end
    end
endmodule
`default_nettype wire
