// comp_fb_dma.sv — vblank WORK→DDR DOUBLE-BUFFERED framebuffer raster burst-DMA.
//
// Streams the composited WORK buffer (comp_fbram rd_*) out to a DDR3 double-buffer that the
// custom openbor_video_reader scans out to VGA (the synchronous custom-reader path; the
// ascal path was dropped — see the DDR-scanout custom-reader plan). The fabric is now the
// producer that both writes the frame AND flips the buffer-select control word (the HPS did
// this in the original openbor core).
//
// On each `start` pulse (compositor vblank, from blitter_top's S_SNAP_* FSM) it:
//   (0) latches wr_target = ~disp_active — the BACK buffer, the one the reader is NOT
//       currently displaying (device-fix: double-buffer tearing — a free-running toggle could
//       write the front buffer if the compositor laps the 60 Hz scanout).
//   (1) bursts WORK qw 0..FB_QWORDS-1 (19200 qwords = 320x240 @ 4 RGB565 px/qword;
//       lane0 = leftmost) into the BACK buffer:
//         buf_base = fb_qw_base + 8 (0x40 B)  +  wr_target * 0x8000 (0x40000 B)
//         → BUF0 @ fb_qw_base+0x40, BUF1 @ fb_qw_base+0x40040  (openbor_video_reader layout),
//   (2) writes ONE control-word qword at fb_qw_base+0:
//         ctrl_word[31:0] = {frame_counter[29:0], 1'b0, wr_target}
//         (matches the reader: frame_counter = ctrl_word[31:2] watchdog, active = ctrl_word[0];
//          be=0x0F so only the low 32 bits are written, preserving the qword's high half),
//   (3) increments `frame_counter` (wr_target is re-latched from disp_active next start).
// ORDER IS LOAD-BEARING: the control word is written AFTER the whole buffer is accepted, so
// the reader (which polls the control word and picks active_buffer) never sees `active` point
// at a half-written buffer, and cannot swap onto the buffer being written mid-copy. `busy`
// spans the ENTIRE sequence (buffer + control word).
//
// Back-pressure: mem_wr/addr/din are HELD until the bus accepts (~mem_busy) — the blitter_top
// S_WR_WAIT discipline; a stalled f2h write FIFO can never drop a beat. The WORK read uses a
// 2-cycle-latency valid pipeline (registered work_rd_en + comp_fbram's registered read),
// single outstanding read so capture order == write order == address order.
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
    input  wire            start,       // 1-cyc pulse (compositor vblank): begin a WORK→DDR frame
    output reg             busy,        // high for the whole sequence (buffer copy + control word)
    input  wire [28:0]     fb_qw_base,  // DDR qword base: control word @+0, BUF0 @+8, BUF1 @+0x8008
    // [device-fix: double-buffer tearing] the buffer the reader is CURRENTLY displaying (its
    // latched active_buffer). We write the OTHER buffer (~disp_active), latched at `start`, so
    // even if the compositor laps the 60 Hz scanout we never write the buffer being displayed.
    input  wire            disp_active,

    // ── WORK read port (mux onto comp_fbram rd_* while busy) ─────────────────────
    output reg             work_rd_en,
    output reg  [AW-1:0]   work_rd_qw,
    input  wire [63:0]     work_rd_qword,   // registered, valid 1 cyc after work_rd_qw/en

    // ── DDR write master (mirrors blitter_top's mem_* master) ────────────────────
    output wire            mem_wr,
    output wire [MAW-1:0]  mem_addr,        // qword address
    output wire [7:0]      mem_burstcnt,    // single-beat (8'd1)
    output wire [63:0]     mem_din,
    output wire [7:0]      mem_be,          // 0xFF for buffer beats, 0x0F for the control word
    input  wire            mem_busy         // held high while the bus cannot accept a beat
);
    localparam [AW:0] NQW = FB_QWORDS[AW:0];
    localparam [AW:0] ONE = {{(AW){1'b0}}, 1'b1};
    // qword offsets within the framebuffer region (openbor_video_reader map):
    localparam [31:0] BUF0_OFF = 32'd8;         // 0x40 bytes  >> 3
    localparam [31:0] BUF1_STEP = 32'h0000_8000; // 0x40000 bytes >> 3 (buf1 = buf0 + this)

    // ── cursor state ──────────────────────────────────────────────────────────────
    reg [AW:0]   rptr;         // next WORK qw to READ  (0..NQW)
    reg [AW:0]   wcnt;         // qwords WRITTEN so far (0..NQW) == current buffer write index

    // ── double-buffer + control-word state ─────────────────────────────────────────
    // [device-fix: double-buffer tearing] wr_target = the buffer written THIS frame = the BACK
    // buffer = ~disp_active, LATCHED at `start` so it is stable across the whole copy (the
    // reader cannot swap the displayed buffer to the one being written until we write the
    // control word AFTER the buffer). No free-running toggle -> we never write the front buffer.
    reg          wr_target;
    // [device-fix: double-buffer tearing] `published` = the buffer we last published (wrote its
    // control word for). We only START a new copy once the reader has CONSUMED that publish
    // (disp_active == published) — i.e. it has swapped onto the published buffer, freeing the
    // OTHER one. Otherwise both buffers are in use (one displayed, one published-pending) and a
    // new copy would overwrite the published buffer the reader is about to show -> tear. So we
    // SKIP (drop the frame) until the reader catches up. This makes a producer faster than the
    // 60 Hz scanout drop frames cleanly instead of tearing.
    reg          published;
    reg [29:0]   frame_counter; // rider in control word [31:2]; increments per frame (reader watchdog)
    reg          ctrl_phase;    // 1 while writing the control word (after the buffer copy)
    reg          ctrl_pending;  // the control-word write is issued and awaiting acceptance

    // [wedge probe — SOLARUS_DBG_PROBES] copy-duration instrument. copy_cyc counts cycles
    // busy is held for the CURRENT copy (start -> control-word accepted); peak_copy_cyc is the
    // saturating max across copies, persistent. A normal copy is ~FB_QWORDS (~19200) cycles;
    // a value orders of magnitude larger means comp_fb_dma is STALLING mid-copy on the shared
    // f2h slot (the S_SNAP_DRAIN hard-stall hypothesis) rather than the stall living elsewhere
    // (blitter S_SNAP_WAIT / arbiter). Published into the control qword's otherwise-unused high
    // 32 bits (host reads at ctrl_addr+4 = 0x3BF40004); ship path leaves the high word 0.
    reg [31:0]   copy_cyc;
    reg [31:0]   peak_copy_cyc;

    // [startup-deadlock watchdog] The `disp_active == published` start gate deadlocks at boot
    // when the reader never swaps onto our first publish (stale DDR ctrl frame-counter collides
    // with our fc=0 first write — see the scanout-startup-deadlock analysis): we wait for an ack
    // that never comes. skip_cnt counts consecutive `start` pulses we DROP because the gate is
    // closed; after SKIP_MAX we force a control-word-only RE-PUBLISH of `published` (no recopy —
    // the buffer is already valid), which bumps frame_counter and thus guarantees the reader sees
    // a change and swaps onto `published`, restoring disp_active==published. Self-healing, and
    // safe vs legitimate fast-producer frame-drop: on hardware `start` is gated by the scanout
    // vblank (vs_rise), so the reader adopts within ~1 frame and consecutive skips stay tiny; a
    // TRUE deadlock skips UNBOUNDEDLY. SKIP_MAX is set FAR above any legit skip-run (incl. the
    // decoupled faster-producer the sim models) so the watchdog only fires on a real wedge —
    // ~32 blocked frames (~0.5s @ 60Hz) of heal latency, negligible for a one-time boot recovery.
    localparam [7:0] SKIP_MAX = 8'd32;
    reg [7:0]    skip_cnt;

    // ── read-latency pipeline (2-cycle) ────────────────────────────────────────────
    reg          rd_busy;
    reg          rd_v1, rd_v2;

    // ── write-side hold slot (buffer phase) ────────────────────────────────────────
    reg          hold_valid;
    reg [63:0]   hold_data;

    // ── addresses / control word ───────────────────────────────────────────────────
    wire [31:0]  buf_base  = {3'b000, fb_qw_base} + BUF0_OFF + (wr_target ? BUF1_STEP : 32'd0);
    wire [31:0]  ctrl_addr = {3'b000, fb_qw_base};                       // fb_qw_base + 0
    wire [31:0]  ctrl_word = {frame_counter, 1'b0, wr_target};           // [31:2]=fc, [1]=0, [0]=target

    // ── mem master (phase-aware): buffer beats vs the single control-word write ──────
    // A write is ACCEPTED the cycle mem_wr & ~mem_busy; until then addr/din/wr are stable.
    assign mem_wr       = busy & (ctrl_phase ? ctrl_pending : hold_valid);
    assign mem_addr     = ctrl_phase ? ctrl_addr
                                     : (buf_base + {{(MAW-(AW+1)){1'b0}}, wcnt});
`ifdef SOLARUS_DBG_PROBES
    // [wedge probe] carry peak_copy_cyc in the control qword's high 32 bits (be=0xFF). The
    // reader only consumes ctrl_word[31:0], so the low half is byte-identical to ship.
    assign mem_din      = ctrl_phase ? {peak_copy_cyc, ctrl_word} : hold_data;
    assign mem_be       = ctrl_phase ? 8'hFF : 8'hFF;
`else
    assign mem_din      = ctrl_phase ? {32'd0, ctrl_word} : hold_data;
    assign mem_be       = ctrl_phase ? 8'h0F : 8'hFF;
`endif
    assign mem_burstcnt = 8'd1;

    // buffer-phase pipeline control (naturally idle in ctrl_phase: hold_valid/rd_busy=0, rptr=NQW)
    wire wr_accept = hold_valid & ~mem_busy;
    wire hold_free = ~hold_valid | wr_accept;
    wire cap_fire  = rd_v2 & hold_free;
    wire can_issue = (rptr < NQW) & (~rd_busy | cap_fire);

    always @(posedge clk) begin
        if (rst) begin
            busy          <= 1'b0;
            work_rd_en    <= 1'b0;
            rptr          <= {(AW+1){1'b0}};
            wcnt          <= {(AW+1){1'b0}};
            rd_busy       <= 1'b0;
            rd_v1         <= 1'b0;
            rd_v2         <= 1'b0;
            hold_valid    <= 1'b0;
            wr_target     <= 1'b0;
            published     <= 1'b0;   // matches the reader's reset displayed buffer (BUF0)
            frame_counter <= 30'd0;
            ctrl_phase    <= 1'b0;
            ctrl_pending  <= 1'b0;
            copy_cyc      <= 32'd0;
            peak_copy_cyc <= 32'd0;
            skip_cnt      <= 8'd0;
        end else begin
            work_rd_en <= 1'b0;   // default: single-cycle read strobe
`ifdef SOLARUS_DBG_PROBES
            // [wedge probe] tick the current-copy duration while busy (saturating).
            if (busy && copy_cyc != 32'hFFFFFFFF) copy_cyc <= copy_cyc + 32'd1;
`endif

            if (!busy) begin
                rd_busy <= 1'b0; rd_v1 <= 1'b0; rd_v2 <= 1'b0; hold_valid <= 1'b0;
                ctrl_phase <= 1'b0; ctrl_pending <= 1'b0;
                // [device-fix] START only when the reader has CONSUMED our last publish
                // (disp_active == published): then the OTHER buffer (~disp_active) is free to
                // write. If the reader is still behind (hasn't swapped onto `published`), SKIP —
                // re-writing the published buffer would tear the frame it is about to display.
                if (start && (disp_active == published)) begin
                    busy <= 1'b1;
                    rptr <= {(AW+1){1'b0}};
                    wcnt <= {(AW+1){1'b0}};
                    // latch the BACK buffer (~ the reader's displayed buffer) for the whole copy.
                    wr_target <= ~disp_active;
                    skip_cnt  <= 8'd0;                 // [watchdog] gate open -> reset the stall counter
`ifdef SOLARUS_DBG_PROBES
                    copy_cyc <= 32'd0;   // [wedge probe] restart the current-copy duration counter
`endif
                end else if (start) begin
                    // [startup-deadlock watchdog] gate CLOSED (disp_active != published): the reader
                    // hasn't adopted our last publish. Count the dropped frames; after SKIP_MAX,
                    // force a control-word-only re-publish of `published` to nudge the reader.
                    if (skip_cnt >= SKIP_MAX) begin
                        busy         <= 1'b1;
                        ctrl_phase   <= 1'b1;          // skip the buffer copy: `published` is already valid
                        ctrl_pending <= 1'b1;
                        wr_target    <= published;     // re-publish the SAME buffer (bumps fc -> reader swaps)
                        skip_cnt     <= 8'd0;
                    end else begin
                        skip_cnt <= skip_cnt + 8'd1;
                    end
                end
            end else if (!ctrl_phase) begin
                // ─── BUFFER phase: raster-copy WORK into buffer `wr_target` ─────────
                // 1) read-latency shift: v1 → v2 (v2 sticky until captured).
                if (rd_v1) begin rd_v2 <= 1'b1; rd_v1 <= 1'b0; end
                // 2) WRITE acceptance — drain the hold slot into DDR (in-order == wcnt).
                if (wr_accept) begin
                    hold_valid <= 1'b0;
                    wcnt       <= wcnt + ONE;
                end
                // 3) CAPTURE — move the ready read datum into the (now-free) hold slot.
                if (cap_fire) begin
                    hold_valid <= 1'b1;
                    hold_data  <= work_rd_qword;
                    rd_v2      <= 1'b0;
                    rd_busy    <= 1'b0;
                end
                // 4) ISSUE — start the next WORK read (registered strobe → data 2 cyc later).
                if (can_issue) begin
                    work_rd_en <= 1'b1;
                    work_rd_qw <= rptr[AW-1:0];
                    rptr       <= rptr + ONE;
                    rd_busy    <= 1'b1;
                    rd_v1      <= 1'b1;
                end
                // 5) BUFFER DONE — every qword written; hand off to the control-word phase.
                //    (control word lands AFTER the buffer so `active` never points half-written.)
                if (wcnt == NQW) begin
                    ctrl_phase   <= 1'b1;
                    ctrl_pending <= 1'b1;
                end
            end else begin
                // ─── CONTROL-WORD phase: one held write of {frame_counter, 0, wr_target} ──
                if (ctrl_pending & ~mem_busy) begin
                    ctrl_pending  <= 1'b0;
                    ctrl_phase    <= 1'b0;
                    // record what we just published; the next copy is gated on the reader
                    // consuming it (disp_active == published). No free-running toggle.
                    published     <= wr_target;
                    frame_counter <= frame_counter + 30'd1;
                    busy          <= 1'b0;                 // whole frame (buffer + control) complete
`ifdef SOLARUS_DBG_PROBES
                    // [wedge probe] this copy just finished: fold its duration into the peak.
                    if (copy_cyc > peak_copy_cyc) peak_copy_cyc <= copy_cyc;
`endif
                end
            end
        end
    end
endmodule
`default_nettype wire
