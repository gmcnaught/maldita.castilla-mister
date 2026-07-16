//============================================================================
//
//  OpenBOR Native Video Timing Generator
//
//  320x224 active area @ 59.92 Hz (420x262 total)
//  Exact Genesis H40 timing — NTSC-derived MCLK from colorburst crystal.
//  CLK_VIDEO: 53.693 MHz (exact Genesis MCLK), variable CE_PIXEL for H_TOTAL=420.
//
//  H: 320 active + 100 blanking = 420 total (exact Genesis H40)
//  V: 224 active +  10 FP + 3 sync + 25 BP = 262 total (Genesis NTSC V28, active 28..251, centered)
//
//  Refresh: 15,700 / 262 = 59.92 Hz (exact Genesis)
//  H freq:  53,693,182 / 3420 = 15,700 Hz (exact Genesis)
//  H active time: 320 × 8 / 53.693MHz = 47.68 µs (exact NES/SNES/Genesis)
//
//  Adapted from MiSTer_PICO-8 by MiSTer Organize
//  Copyright (C) 2026 MiSTer Organize -- GPL-3.0
//
//============================================================================

module openbor_video_timing (
    input  wire        clk,        // CLK_VIDEO (53.693 MHz)
    input  wire        ce_pix,     // pixel enable (variable rate — exact Genesis H40)
    input  wire        reset,

    // CRT position offset (signed: -3 to +3, from OSD)
    input  wire signed [4:0] h_adj,  // horizontal: positive = shift right
    input  wire signed [3:0] v_adj,  // vertical: positive = shift down

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
// 320x224 active, centered for 15kHz CRT, NTSC-compatible H rate.
// CRT-compatible blanking with balanced porches.
localparam H_ACTIVE = 320;
localparam H_FP     = 17;
localparam H_SYNC   = 38;
localparam H_BP     = 45;
localparam H_TOTAL  = 420;   // 320+17+38+45 (exact Genesis H40)

localparam V_ACTIVE = 224;   // [FO Task 5] Genesis NTSC V28 (224), CYCLE-EXACT per the
                             // MegaDrive core rtl/video_cond.sv: NTSC active = lines
                             // 28..251 of 262. V28 is V30's window (20..259) shrunk 8
                             // off the top AND 8 off the bottom == CENTERED, so the
                             // image sits identically to a real Genesis (not bottom-cropped).
localparam V_FP     = 10;    // V30's 2 + 8  (active ends 8 lines earlier: 259 -> 251)
localparam V_SYNC   = 3;     // Genesis NTSC vsync = 3 lines (unchanged)
localparam V_BP     = 25;    // V30's 17 + 8 (active starts 8 lines later: 20 -> 28)
localparam V_TOTAL  = 262;   // 224+10+3+25 (== Genesis NTSC; H rate + refresh unchanged)

// Derived boundaries — adjusted by OSD H/V position offset.
wire [9:0] h_sync_start = H_ACTIVE + H_FP + {{5{h_adj[4]}}, h_adj};
wire [9:0] h_sync_end   = h_sync_start + H_SYNC;
// [#107] Clamp v_sync_start to >= V_ACTIVE so vsync can never assert INSIDE active video
// (lines 0..V_ACTIVE-1). With V_FP=10 the raw value V_ACTIVE+V_FP+v_adj = 234+v_adj stays
// >= V_ACTIVE (224) for every OSD shift (v_adj>=-8 -> 226), so the floor no longer fires,
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
    end
    else if (ce_pix) begin
        new_frame <= 1'b0;
        new_line  <= 1'b0;

        // Horizontal counter
        if (hcount == H_TOTAL - 1) begin
            hcount <= 10'd0;
            if (vcount == V_TOTAL - 1)
                vcount <= 9'd0;
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
