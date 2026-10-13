//============================================================================
//
//  OpenBOR Native Video Timing Generator
//
//  320 x 224 (or 240) active @ 59.92 Hz, 420 x 262 total -- Genesis H40 raster,
//  15 kHz CRT-compatible, NTSC-derived MCLK, mixed /8,/9,/10 pixel clock
//  (see Maldita.sv ce_pix_gen).
//
//  H: 320 active + 100 blanking = 420 total (3420 MCLK)
//  V, OSD Vertical Lines = 224: 224 active (rows `DISP_Y0.. of the framebuffer)
//     + 11 FP + 3 sync + 24 BP = 262 (Genesis V28)
//  V, OSD Vertical Lines = 240: 240 active (every row) + 3 FP + 3 sync + 16 BP = 262;
//     the 16 extra lines come 8 from each porch, so vsync keeps its place relative
//     to the picture centre and a CRT does not re-lock
//
//  Refresh: 15,700 / 262 = 59.92 Hz (both modes)
//  H freq:  53,693,182 / 3420 = 15,700 Hz
//  H active time: 47.68 us (the standard console window)
//
//  Adapted from MiSTer_PICO-8 by MiSTer Organize
//  Copyright (C) 2026 MiSTer Organize -- GPL-3.0
//
//============================================================================

`include "blitter_defs.vh"

module openbor_video_timing (
    input  wire        clk,        // CLK_VIDEO (53.693 MHz)
    input  wire        ce_pix,     // pixel enable (uniform /9 from CLK_VIDEO)
    input  wire        reset,

    // CRT position offset (signed: -3 to +3, from OSD)
    input  wire signed [4:0] h_adj,  // horizontal: positive = shift right
    input  wire signed [3:0] v_adj,  // vertical: positive = shift down

    // OSD Vertical Lines (synced to clk): 0 = the `DISP_H-line window, 1 = all `FB_H
    // lines. Sampled at the end of active video into v_full_next, adopted at the end
    // of the frame, so every frame is scanned in one mode.
    input  wire        v_full,
    output reg         v_full_next, // the mode the NEXT frame uses (stable all vblank)

    output reg         hsync,      // active low
    output reg         vsync,      // active low
    output reg         hblank,
    output reg         vblank,
    output reg         de,         // data enable = ~(hblank | vblank)
    output reg  [9:0]  hcount,
    output reg  [8:0]  vcount,
    output reg         new_frame,  // pulse at vblank start
    output reg         new_line    // pulse at hblank start
);

// -- Timing constants --------------------------------------------------
// Native-resolution scanout: the active area IS the framebuffer (`FB_W x `FB_H,
// 288x216), 15 kHz CRT-compatible, NTSC H rate. Uniform /9 pixel clock:
// 380 px/line x 9 MCLK = 3420 MCLK/line (same total as Genesis H40 -> H rate
// 15,700 Hz and 59.92 Hz refresh unchanged). Active width 288 x 9 = 2592 MCLK
// = 48.3 us, ~= the standard 47.7 us console window.
localparam H_ACTIVE = `FB_W;
// [320x240] Genesis H40 geometry: 320 active + 100 blanking = 420 pixel clocks
// per line, with CE_PIXEL (Maldita.sv) issuing those 420 pixels in exactly 3420
// MCLK. Active time is the CRT-correct 47.68 us, matching NES/SNES/Genesis
// image width, and the line rate and refresh are unchanged from the 288-wide
// build. No PLL change: CLK_VIDEO was already the 53.693 MHz Genesis MCLK.
localparam H_FP     = 17;
localparam H_SYNC   = 38;
localparam H_BP     = 45;
localparam H_TOTAL  = H_ACTIVE + H_FP + H_SYNC + H_BP;   // 420 (3420 MCLK, mixed /8,/9,/10)

localparam V_ACTIVE_W = `DISP_H; // 224-line V28 window of the `FB_H framebuffer
                                 // (blitter_defs.vh: rows `DISP_Y0.. are scanned out)
localparam V_FP_W     = 11;     // Genesis V28 NTSC: 8 bottom border + 3 blank
localparam V_SYNC     = 3;      // NTSC vsync = 3 lines (unchanged)
localparam V_BP_W     = 24;     // Genesis V28 NTSC: 13 blank + 11 top border
localparam V_TOTAL    = V_ACTIVE_W + V_FP_W + V_SYNC + V_BP_W;   // 262 (H rate + refresh unchanged)

// [OSD Vertical Lines = 240] All `FB_H lines. The extra lines come out of the
// borders on both sides -- (`FB_H-`DISP_H)/2 = 8 from the front porch and 8 from
// the back porch -- so vsync keeps its position relative to the picture centre, the
// total stays 262 and a CRT does not have to re-lock (no roll beyond the one frame
// the counter origin moves on a switch). V_FP 3 with the OSD's v_adj = -3 puts
// vsync on the first blank line, never inside active video (the clamp below).
localparam V_ACTIVE_F = `FB_H;
localparam V_EXTRA    = (V_ACTIVE_F - V_ACTIVE_W) / 2;   // 8
localparam V_FP_F     = V_FP_W - V_EXTRA;                // 3
localparam V_BP_F     = V_TOTAL - V_ACTIVE_F - V_FP_F - V_SYNC;   // 16
// synthesis translate_off
initial begin
    if (V_ACTIVE_F + V_FP_F + V_SYNC + V_BP_F != V_TOTAL || V_FP_F < 3 || V_BP_F < 1)
        $error("openbor_video_timing: 240-line mode does not fit the 262-line frame");
end
// synthesis translate_on

reg        v_full_cur;   // the mode THIS frame is scanned in
wire [8:0] V_ACTIVE = v_full_cur ? 9'(V_ACTIVE_F) : 9'(V_ACTIVE_W);
wire [8:0] V_FP     = v_full_cur ? 9'(V_FP_F)     : 9'(V_FP_W);

// Derived boundaries — adjusted by OSD H/V position offset.
wire [9:0] h_sync_start = H_ACTIVE + H_FP + {{5{h_adj[4]}}, h_adj};
wire [9:0] h_sync_end   = h_sync_start + H_SYNC;
// [#107] Clamp v_sync_start to >= V_ACTIVE so vsync can never assert INSIDE active video
// (lines 0..V_ACTIVE-1). With V_FP=14 the raw value V_ACTIVE+V_FP+v_adj = 230+v_adj stays
// >= V_ACTIVE (216) for every OSD shift (v_adj>=-3 -> 227), so the floor no longer fires,
// but it is kept defensively: at the smaller V_FP=2 (V30) it prevented vsync asserting one
// line inside active on strict 15 kHz displays. Floor at V_ACTIVE.
wire [8:0] v_sync_start_raw = V_ACTIVE + V_FP + {{5{v_adj[3]}}, v_adj};
wire [8:0] v_sync_start = (v_sync_start_raw < V_ACTIVE[8:0]) ? V_ACTIVE[8:0] : v_sync_start_raw;
wire [8:0] v_sync_end   = v_sync_start + V_SYNC;

// Next-cycle blanking state, computed combinationally so `de` leads the registered
// hblank/vblank by one pixel. Kept in a dedicated `always @(*)` (NOT the clocked
// block below) so the intra-block temporaries stay blocking `=` without tripping the
// blocking-in-sequential HDL lint gate.
reg next_hblank, next_vblank;
always @(*) begin
    if (hcount == H_ACTIVE - 1)
        next_hblank = 1'b1;
    else if (hcount == H_TOTAL - 1)
        next_hblank = 1'b0;
    else
        next_hblank = hblank;

    if (hcount == H_TOTAL - 1) begin
        if (vcount == V_ACTIVE - 1)
            next_vblank = 1'b1;
        else if (vcount == V_TOTAL - 1)
            next_vblank = 1'b0;
        else
            next_vblank = vblank;
    end
    else
        next_vblank = vblank;
end

always @(posedge clk) begin
    if (reset) begin
        hcount    <= 10'd0;
        vcount    <= 9'd0;
        hsync     <= 1'b1;
        vsync     <= 1'b1;
        hblank    <= 1'b0;
        vblank    <= 1'b0;
        de        <= 1'b1;
        new_frame <= 1'b0;
        new_line  <= 1'b0;
        v_full_cur  <= v_full;   // come out of reset already in the requested mode
        v_full_next <= v_full;
    end
    else if (ce_pix) begin
        new_frame <= 1'b0;
        new_line  <= 1'b0;

        // Vertical Lines mode: sample at the end of active video (the reader re-arms
        // its fetch during this vblank and reads v_full_next), adopt at the frame wrap.
        if (hcount == H_TOTAL - 1 && vcount == V_ACTIVE - 1)
            v_full_next <= v_full;

        // Horizontal counter
        if (hcount == H_TOTAL - 1) begin
            hcount <= 10'd0;
            if (vcount == V_TOTAL - 1) begin
                vcount     <= 9'd0;
                v_full_cur <= v_full_next;
            end
            else
                vcount <= vcount + 9'd1;
        end
        else begin
            hcount <= hcount + 10'd1;
        end

        // Horizontal blanking
        if (hcount == H_ACTIVE - 1)
            hblank <= 1'b1;
        else if (hcount == H_TOTAL - 1)
            hblank <= 1'b0;

        // Horizontal sync (active low)
        if (hcount == h_sync_start - 1)
            hsync <= 1'b0;
        else if (hcount == h_sync_end - 1)
            hsync <= 1'b1;

        // Vertical blanking (transitions on line boundaries)
        if (hcount == H_TOTAL - 1) begin
            if (vcount == V_ACTIVE - 1)
                vblank <= 1'b1;
            else if (vcount == V_TOTAL - 1)
                vblank <= 1'b0;
        end

        // Vertical sync (active low)
        if (hcount == H_TOTAL - 1) begin
            if (vcount == v_sync_start - 1)
                vsync <= 1'b0;
            else if (vcount == v_sync_end - 1)
                vsync <= 1'b1;
        end

        // New line pulse
        if (hcount == H_ACTIVE - 1)
            new_line <= 1'b1;

        // New frame pulse
        if (hcount == H_TOTAL - 1 && vcount == V_ACTIVE - 1)
            new_frame <= 1'b1;

        // Data enable leads registered blanking by one pixel (next-cycle state
        // computed in the always @(*) above).
        de <= ~next_hblank & ~next_vblank;
    end
end

endmodule
