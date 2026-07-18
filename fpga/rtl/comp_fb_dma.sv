// comp_fb_dma.sv — vblank WORK→DDR DOUBLE-BUFFERED framebuffer raster burst-DMA.
//
// Streams the composited WORK buffer (comp_fbram rd_*) out to a DDR3 double-buffer that the
// custom openbor_video_reader scans out to VGA (the synchronous custom-reader path; the
// ascal path was dropped — see the DDR-scanout custom-reader plan). The fabric is now the
// producer that both writes the frame AND flips the buffer-select control word (the HPS did
// this in the original openbor core).
//
// On each `start` pulse (compositor vblank, from blitter_top's S_SNAP_* FSM) it:
//   (1) bursts WORK qw 0..FB_QWORDS-1 (19200 qwords = 320x240 @ 4 RGB565 px/qword;
//       lane0 = leftmost) into the INACTIVE buffer:
//         buf_base = fb_qw_base + 8 (0x40 B)  +  sel * 0x8000 (0x40000 B)
//         → BUF0 @ fb_qw_base+0x40, BUF1 @ fb_qw_base+0x40040  (openbor_video_reader layout),
//   (2) writes ONE control-word qword at fb_qw_base+0:
//         ctrl_word[31:0] = {frame_counter[29:0], 1'b0, sel}
//         (matches the reader: frame_counter = ctrl_word[31:2] watchdog, active = ctrl_word[0];
//          be=0x0F so only the low 32 bits are written, preserving the qword's high half —
//          same discipline as blitter_top's legacy VCTRL write),
//   (3) toggles `sel` and increments `frame_counter` for the next frame.
// ORDER IS LOAD-BEARING: the control word is written AFTER the whole buffer is accepted, so
// the reader (which polls the control word and picks active_buffer) never sees `active` point
// at a half-written buffer. `busy` spans the ENTIRE sequence (buffer + control word).
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

    // ── double-buffer + control-word state (persists across frames) ────────────────
    reg          sel;          // buffer being written THIS frame (0=BUF0, 1=BUF1); also active_buffer
    reg [29:0]   frame_counter; // rider in control word [31:2]; increments per frame (reader watchdog)
    reg          ctrl_phase;    // 1 while writing the control word (after the buffer copy)
    reg          ctrl_pending;  // the control-word write is issued and awaiting acceptance

    // ── read-latency pipeline (2-cycle) ────────────────────────────────────────────
    reg          rd_busy;
    reg          rd_v1, rd_v2;

    // ── write-side hold slot (buffer phase) ────────────────────────────────────────
    reg          hold_valid;
    reg [63:0]   hold_data;

    // ── addresses / control word ───────────────────────────────────────────────────
    wire [31:0]  buf_base  = {3'b000, fb_qw_base} + BUF0_OFF + (sel ? BUF1_STEP : 32'd0);
    wire [31:0]  ctrl_addr = {3'b000, fb_qw_base};                 // fb_qw_base + 0
    wire [31:0]  ctrl_word = {frame_counter, 1'b0, sel};           // [31:2]=fc, [1]=0, [0]=sel

    // ── mem master (phase-aware): buffer beats vs the single control-word write ──────
    // A write is ACCEPTED the cycle mem_wr & ~mem_busy; until then addr/din/wr are stable.
    assign mem_wr       = busy & (ctrl_phase ? ctrl_pending : hold_valid);
    assign mem_addr     = ctrl_phase ? ctrl_addr
                                     : (buf_base + {{(MAW-(AW+1)){1'b0}}, wcnt});
    assign mem_din      = ctrl_phase ? {32'd0, ctrl_word} : hold_data;
    assign mem_be       = ctrl_phase ? 8'h0F : 8'hFF;
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
            sel           <= 1'b0;
            frame_counter <= 30'd0;
            ctrl_phase    <= 1'b0;
            ctrl_pending  <= 1'b0;
        end else begin
            work_rd_en <= 1'b0;   // default: single-cycle read strobe

            if (!busy) begin
                rd_busy <= 1'b0; rd_v1 <= 1'b0; rd_v2 <= 1'b0; hold_valid <= 1'b0;
                ctrl_phase <= 1'b0; ctrl_pending <= 1'b0;
                if (start) begin
                    busy <= 1'b1;
                    rptr <= {(AW+1){1'b0}};
                    wcnt <= {(AW+1){1'b0}};
                end
            end else if (!ctrl_phase) begin
                // ─── BUFFER phase: raster-copy WORK into buffer `sel` ───────────────
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
                // ─── CONTROL-WORD phase: one held write of {frame_counter, 0, sel} ──
                if (ctrl_pending & ~mem_busy) begin
                    ctrl_pending  <= 1'b0;
                    ctrl_phase    <= 1'b0;
                    sel           <= ~sel;                 // next frame writes the other buffer
                    frame_counter <= frame_counter + 30'd1;
                    busy          <= 1'b0;                 // whole frame (buffer + control) complete
                end
            end
        end
    end
endmodule
`default_nettype wire
