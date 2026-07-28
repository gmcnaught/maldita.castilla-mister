//============================================================================
//
//  Menu for MiSTer.
//  Copyright (C) 2017-2020 Sorgelig
//
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 2 of the License, or (at your option)
//  any later version.
//
//  This program is distributed in the hope that it will be useful, but WITHOUT
//  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
//  FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
//  more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program; if not, write to the Free Software Foundation, Inc.,
//  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
//
//============================================================================

module emu
(
	//Master input clock
	input         CLK_50M,

	//Async reset from top-level module.
	//Can be used as initial reset.
	input         RESET,

	//Must be passed to hps_io module
	inout  [48:0] HPS_BUS,

	//Base video clock. Usually equals to CLK_SYS.
	output        CLK_VIDEO,

	//Multiple resolutions are supported using different CE_PIXEL rates.
	//Must be based on CLK_VIDEO
	output        CE_PIXEL,

	//Video aspect ratio for HDMI. Most retro systems have ratio 4:3.
	//if VIDEO_ARX[12] or VIDEO_ARY[12] is set then [11:0] contains scaled size instead of aspect ratio.
	output [12:0] VIDEO_ARX,
	output [12:0] VIDEO_ARY,

	output  [7:0] VGA_R,
	output  [7:0] VGA_G,
	output  [7:0] VGA_B,
	output        VGA_HS,
	output        VGA_VS,
	output        VGA_DE,    // = ~(VBlank | HBlank)
	output        VGA_F1,
	output [1:0]  VGA_SL,
	output        VGA_SCALER, // Force VGA scaler
	output        VGA_DISABLE, // analog out is off

	input  [11:0] HDMI_WIDTH,
	input  [11:0] HDMI_HEIGHT,
	output        HDMI_FREEZE,
	output        HDMI_BLACKOUT,
	output        HDMI_BOB_DEINT,

`ifdef MISTER_FB
	// Use framebuffer in DDRAM
	// FB_FORMAT:
	//    [2:0] : 011=8bpp(palette) 100=16bpp 101=24bpp 110=32bpp
	//    [3]   : 0=16bits 565 1=16bits 1555
	//    [4]   : 0=RGB  1=BGR (for 16/24/32 modes)
	//
	// FB_STRIDE either 0 (rounded to 256 bytes) or multiple of pixel size (in bytes)
	output        FB_EN,
	output  [4:0] FB_FORMAT,
	output [11:0] FB_WIDTH,
	output [11:0] FB_HEIGHT,
	output [31:0] FB_BASE,
	output [13:0] FB_STRIDE,
	input         FB_VBL,
	input         FB_LL,
	output        FB_FORCE_BLANK,

`ifdef MISTER_FB_PALETTE
	// Palette control for 8bit modes.
	// Ignored for other video modes.
	output        FB_PAL_CLK,
	output  [7:0] FB_PAL_ADDR,
	output [23:0] FB_PAL_DOUT,
	input  [23:0] FB_PAL_DIN,
	output        FB_PAL_WR,
`endif
`endif

	output        LED_USER,  // 1 - ON, 0 - OFF.

	// b[1]: 0 - LED status is system status OR'd with b[0]
	//       1 - LED status is controled solely by b[0]
	// hint: supply 2'b00 to let the system control the LED.
	output  [1:0] LED_POWER,
	output  [1:0] LED_DISK,

	// I/O board button press simulation (active high)
	// b[1]: user button
	// b[0]: osd button
	output  [1:0] BUTTONS,

	input         CLK_AUDIO, // 24.576 MHz
	output [15:0] AUDIO_L,
	output [15:0] AUDIO_R,
	output        AUDIO_S,   // 1 - signed audio samples, 0 - unsigned
	output  [1:0] AUDIO_MIX, // 0 - no mix, 1 - 25%, 2 - 50%, 3 - 100% (mono)

	//ADC
	inout   [3:0] ADC_BUS,

	//SD-SPI
	output        SD_SCK,
	output        SD_MOSI,
	input         SD_MISO,
	output        SD_CS,
	input         SD_CD,

	//High latency DDR3 RAM interface
	//Use for non-critical time purposes
	output        DDRAM_CLK,
	input         DDRAM_BUSY,
	output  [7:0] DDRAM_BURSTCNT,
	output [28:0] DDRAM_ADDR,
	input  [63:0] DDRAM_DOUT,
	input         DDRAM_DOUT_READY,
	output        DDRAM_RD,
	output [63:0] DDRAM_DIN,
	output  [7:0] DDRAM_BE,
	output        DDRAM_WE,

	//SDRAM interface with lower latency
	output        SDRAM_CLK,
	output        SDRAM_CKE,
	output [12:0] SDRAM_A,
	output  [1:0] SDRAM_BA,
	inout  [15:0] SDRAM_DQ,
	output        SDRAM_DQML,
	output        SDRAM_DQMH,
	output        SDRAM_nCS,
	output        SDRAM_nCAS,
	output        SDRAM_nRAS,
	output        SDRAM_nWE,

`ifdef MISTER_DUAL_SDRAM
	//Secondary SDRAM
	//Set all output SDRAM_* signals to Z ASAP if SDRAM2_EN is 0
	input         SDRAM2_EN,
	output        SDRAM2_CLK,
	output [12:0] SDRAM2_A,
	output  [1:0] SDRAM2_BA,
	inout  [15:0] SDRAM2_DQ,
	output        SDRAM2_nCS,
	output        SDRAM2_nCAS,
	output        SDRAM2_nRAS,
	output        SDRAM2_nWE,
`endif

	input         UART_CTS,
	output        UART_RTS,
	input         UART_RXD,
	output        UART_TXD,
	output        UART_DTR,
	input         UART_DSR,

	// Open-drain User port.
	// 0 - D+/RX
	// 1 - D-/TX
	// 2..6 - USR2..USR6
	// Set USER_OUT to 1 to read from USER_IN.
	input   [6:0] USER_IN,
	output  [6:0] USER_OUT,

	input         OSD_STATUS,

	// Native video active signal for sys_top.v vsync routing
	output        NATIVE_VID_ACTIVE
);

assign ADC_BUS  = 'Z;
assign {UART_RTS, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;

assign DDRAM_CLK = clk_sys;

// CE_PIXEL: uniform /9 from CLK_VIDEO (53.693 MHz) — native 288-wide raster.
// 380 px/line x 9 MCLK = 3420 MCLK/line (same as the Genesis H40 line we used
// at 320 wide), so the 15,700 Hz H rate and 59.92 Hz refresh are unchanged.
// The old mixed /8,/9,/10 blanking schedule is gone: every pixel is 9 MCLK.
reg [3:0] ce_cnt;
reg ce_pix_gen;

always @(posedge CLK_VIDEO) begin
	if (RESET) begin
		ce_cnt <= 4'd0;
		ce_pix_gen <= 1'b0;
	end
	else begin
		ce_pix_gen <= (ce_cnt == 4'd0);
		ce_cnt <= (ce_cnt == 4'd8) ? 4'd0 : (ce_cnt + 4'd1);
	end
end
assign CE_PIXEL = ce_pix_gen;

assign VGA_SL = 0;
assign VGA_F1 = 0;
// The core renders at native 288x216, 4:3. freak_arx/freak_ary (video_freak,
// instantiated below near h_pos/v_pos) equal these same fixed values (CROP is
// permanently off at native 216p), so this is a no-op passthrough.
assign VIDEO_ARX = NATIVE_VID_ACTIVE ? freak_arx : 13'd4;
assign VIDEO_ARY = NATIVE_VID_ACTIVE ? freak_ary : 13'd3;
assign VGA_DISABLE = 0;

// ── [DDR-scanout custom-reader] DDR framebuffer base ─────────────────────────────────
// The custom openbor_video_reader scans a DDR3 double-buffer this fabric writes (comp_fb_dma)
// and drives VGA directly (VGA_SCALER=0, the timing the TV syncs to). Placed in the 768 KiB
// region ABOVE the host texture heap, at MF_DEV_TLBUF_OFF (0xF40000) within the 16 MiB
// blitter window (0x3B000000): the host writes only ctrl(+0)/ring(+0x40)/SRC-heap(+0x80000..
// +0xF40000) and never above 0xF40000 (raster_backend_mfgpu.cpp), disjoint from control
// block/ring/heap, and disjoint from gmloader's 0x3A NativeVideoWriter region. Both
// comp_fb_dma.fb_qw_base AND openbor_video_reader.FB_QW_BASE use this constant.
//   CTRL @ 0x3BF40000; BUF0 @ +0x40; BUF1 @ +0x40040; region end 0x3BFA5840 (< 0x3C000000)
localparam [28:0] FB_QW_BASE = 29'h077E8000;  // 0x3BF40000 >> 3

// [DDR-scanout custom-reader] ascal FB path reverted — analog/VGA scanout (custom reader).
assign VGA_SCALER = 1'b0;

assign AUDIO_MIX = 0;
assign HDMI_FREEZE = 0;
assign HDMI_BLACKOUT = 0;

assign LED_DISK = 0;
assign LED_POWER[1]= 1;
assign BUTTONS = 0;

reg  [26:0] act_cnt;
always @(posedge clk_sys) act_cnt <= act_cnt + 1'd1;
assign LED_USER    = FB ? led[0] : act_cnt[26]  ? act_cnt[25:18]  > act_cnt[7:0]  : act_cnt[25:18]  <= act_cnt[7:0];

wire [26:0] act_cnt2 = {~act_cnt[26],act_cnt[25:0]};
assign LED_POWER[0]= FB ? led[2] : act_cnt2[26] ? act_cnt2[25:18] > act_cnt2[7:0] : act_cnt2[25:18] <= act_cnt2[7:0];


`include "build_id.v"
localparam CONF_STR = {
	"Maldita Castilla;;",
	"-;",
	"OCE,H Position (CRT),0,+1,+2,+3,-3,-2,-1;",
	"OFH,V Position (CRT),0,+1,+2,+3,-3,-2,-1;",
	"-;",
	"OK,FPS Overlay,Off,On;",
	"TJ,Reset;",
	"-;",
	"J1,Sword,Action,Item 1,Item 2,Pause;",
	"jn,A,B,X,Y,Start;",
	"-;",
	"V,v",`BUILD_DATE
};

wire forced_scandoubler;
wire [31:0] status;
wire [31:0] joystick_0;
wire [31:0] joystick_1;
wire [31:0] joystick_2;
wire [31:0] joystick_3;
wire [15:0] joystick_l_analog_0;

// ioctl signals (still needed for core framework, but S0 doesn't stream)
wire        ioctl_download;
wire        ioctl_wr;
wire [26:0] ioctl_addr;
wire  [7:0] ioctl_dout;
wire [15:0] ioctl_index;
wire        ioctl_wait;
// [DDR-scanout] ioctl_wait was driven by native_video (retired); no FPGA-side cart-load
// backpressure in the gmloader-GPU core — the HPS loader owns content. Tie idle.
assign ioctl_wait = 1'b0;

hps_io #(.CONF_STR(CONF_STR)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),
	.forced_scandoubler(forced_scandoubler),
	.status(status),
	.status_menumask(cfg),
	.joystick_0(joystick_0),
	.joystick_1(joystick_1),
	.joystick_2(joystick_2),
	.joystick_3(joystick_3),
	.joystick_l_analog_0(joystick_l_analog_0),
	.ioctl_download(ioctl_download),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_index(ioctl_index),
	.ioctl_wait(ioctl_wait)
);

////////////////////   CLOCKS   ///////////////////
wire locked, clk_sys;
wire clk_20m;   // PLL outclk_1 (unused, kept for future use)
wire clk_pix;   // PLL outclk_2: 53.693 MHz (CLK_VIDEO, /8 active — exact Genesis MCLK)
wire clk_sdram; // PLL outclk_3: 98.4375 MHz, phase-shifted SDRAM capture clock (#34 fallback C)
pll pll
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(clk_sys),
	.outclk_1(clk_20m),
	.outclk_2(clk_pix),
	.outclk_3(clk_sdram),
	.locked(locked)
);

assign CLK_VIDEO = clk_pix;

// --- Native video control ---
wire NATIVE_VID = 1'b1;  // Always on -- this core exists for native video
assign NATIVE_VID_ACTIVE = NATIVE_VID;


/////////////////////   SDRAM   ///////////////////
//
// issue #19 — runtime-selectable blitter SOURCE controller on the SDRAM chip.
//
// The SDRAM_* pins were previously driven by the MiSTer-template `sdram sdr`
// RAM self-test (it wrote/read a pattern only to set the OSD `cfg` menu-mask
// bits — vestigial scaffolding, no role in Solarus video). That self-test is
// REPLACED here by the framebuffer/blitter SDRAM path (JT-T6: sdram_burst_arb
// over jtframe_burst_sdram), which owns the SDRAM_* pins. `cfg` is now a benign
// constant (0 = no menu masking; the cfg[15]-gated dummy DDR walker below stays
// inert, as it always was once the gate was satisfied — it touched only the
// legacy `addr/we` path used when NATIVE_VID is off).
//
// [collapse-single-source] The per-blit source read is ALWAYS from SDRAM now:
// blitter_top hardwires src_in_sdram=1 and the DDR3 live-source datapath was
// removed, so there is a SINGLE source pipeline (atlases staged DDR3->SDRAM, then
// read via P_SRC). The C_SRCSEL bit0 (DDR3-vs-SDRAM mux) is dead; the control word
// is still read by blitter_top for its throttle field (bits[15:8]).

wire [15:0] cfg = 16'd0;   // OSD menu-mask: 0 = show all (was SDRAM-presence probe)

// --- JC-T6: cache-ok SDRAM datapath nets (sdram_fb_cache, 3 channels) ------
// P_SRC (ch5, read-only): blitter source reads.
wire [26:0] src_p0_addr;
wire        src_p0_rd;
wire [63:0] src_p0_dout;
wire        src_p0_ok;
// P_DST (ch0, read/write): vram_demux SDRAM side (cache-ok: rd/wr/din/wdsn/dout/ok).
// [gmloader-GPU slim] The write side (wr/addr/din/wdsn) used to be a priority mux
// between vram_demux's vd_sd_* outputs and blitter_top's bgw_dst_* outputs (the
// Phase 3b bg-plane bake, retired with OP_BGPLANE_WRITE); vram_demux's vd_sd_*
// write side now drives ch0 directly. dst_rd/dst_dout are read-only and stay
// vram_demux's alone.
wire [26:0] dst_addr;
wire        dst_rd, dst_wr;
wire [63:0] dst_din;
wire  [7:0] dst_wdsn;
wire [63:0] dst_dout;
wire        dst_ok;
wire [26:0] vd_sd_addr;
wire        vd_sd_wr;
wire [63:0] vd_sd_din;
wire  [7:0] vd_sd_wdsn;
assign dst_wr   = vd_sd_wr;
assign dst_addr = vd_sd_addr;
assign dst_din  = vd_sd_din;
assign dst_wdsn = vd_sd_wdsn;
// [DDR-scanout] P_SCAN (ch4) scanout-reader fetch retired with the custom openbor scanout.
// vram_demux DDR side -> ddr_blitter_arb blt_*
wire [28:0] bd_addr;
wire        bd_rd, bd_wr;
wire [63:0] bd_din;
wire  [7:0] bd_be;
// vram_demux read-data back to the blitter mem_dout path
wire [63:0] blt_demux_dout;
wire        blt_demux_dready;
// [DDR-scanout custom-reader] openbor_video_timing outputs (clk_vid domain), declared here so
// the WORK->DDR DMA trigger (fb_vs, below) can be sourced from the scanout vblank. Driven by
// the openbor_video_timing instance near the video output.
wire        tim_hsync, tim_vsync, tim_hblank, tim_vblank, tim_de, tim_new_frame, tim_new_line;
wire [8:0]  tim_vcount;

// clk_sys-domain vblank for the coherency flush + the WORK->DDR DMA trigger (blitter_top
// edge-detects the rising edge -> S_SNAP_* pulses fb_dma_start). [DDR-scanout custom-reader]
// Sourced from the SCANOUT vblank (tim_vblank): the compositor copies WORK to the INACTIVE
// DDR buffer + flips the control word during scanout vblank, when the reader is not fetching
// the displayed (active) buffer -> tear-free double-buffer. tim_vblank is clk_vid-domain, so
// double-flop into clk_sys.
reg  [1:0]  fb_vs_sync = 2'b0;
always @(posedge clk_sys) fb_vs_sync <= {fb_vs_sync[0], tim_vblank};
wire        fb_vs = fb_vs_sync[1];

// [#44] SDRAM source-STAGING write path: the blitter's BLT_OP_STAGE FSM copies atlas
// surfaces DDR3->SDRAM via these burst-write outputs into sdram_fb_cache ch1 (a
// dedicated write channel; P_SRC ch5 stays read-only). Previously these were left
// open -> staging wrote nothing -> C_SRCSEL=1 read un-staged SDRAM (noise).
wire [26:0] stage_waddr;
wire        stage_we_burst;
wire [63:0] stage_din64;
wire        stage_ok;
// Intra-frame STAGE->P_SRC coherency barrier: blitter pulses stage_barrier after a
// STAGE batch; fbcache commits ch1 + invalidates ch5 and holds stage_busy until done.
wire        stage_barrier;
wire        stage_busy;

// JC-T6: sdram_fb_cache (jtframe_cache_mux over jtframe_burst_sdram) replaces
// sdram_burst_arb. Three cache-ok channels — ch0 P_DST (r/w, vram_demux), ch4
// P_SCAN (ro, scanout reader), ch5 P_SRC (ro, blitter source) — plus a coherency
// sequencer that flushes ch0 then invalidates ch0/4/5 on each vsync. The wrapper
// instantiates jtframe_burst_sdram, the refresh timer, and the SDRAM_CLK altddio
// forwarder internally and drives the SDRAM_* pins directly (so the old external
// sdramclk_ddr forwarder is gone). dst/scan/p0 are single-qword cache-ok requests;
// vram_demux/reader/blitter each hold their request until ok.
// [residency/XL] SDRAM_AW=25 -> jtframe XL 128MB. cache_mux XL activates at SDRAM_AW==25
// (FULL channels widen to EW=27 = 128MB byte reach); sdram_fb_cache feeds burst_sdram
// AW=SDRAM_AW-1=24 (its XL convention). 2nd 64MB half on the primary bus, top addr bit =
// chip select. Requires the 128MB SDRAM module. Was AW=23 (64MB); AW=24 was a WRONG
// intermediate (burst-XL-on but cache-non-XL -> upper-half aliased).
// [XL A/B RESULT] MISTER=1 (DQM/A[12:11] short) was HW-tested (commit f5a3b68) — NULL:
// title/menus render but the overworld 2nd-die garbage is UNCHANGED, and it does not
// regress. So MISTER mode is NOT the cause. Reverted to MISTER=0 (validated for 64MB).
sdram_fb_cache #(.SDRAM_AW(25)) fbcache
(
	.clk        (clk_sys),
	.clk_sdram  (clk_sdram),        // [#44] phase-shiftable SDRAM output clock (general[3])
	.rst        (RESET),
	.init       (),                 // jtframe SDRAM-init flag (unused here)
	// P_DST (ch0, r/w) <- vram_demux SDRAM side
	.dst_addr   (dst_addr),
	.dst_rd     (dst_rd),
	.dst_wr     (dst_wr),
	.dst_din    (dst_din),
	.dst_wdsn   (dst_wdsn),
	.dst_dout   (dst_dout),
	.dst_ok     (dst_ok),
	// P_SCAN (ch4) DEAD: SDRAM-cache scanout channel retired [DDR-scanout] — scanout is the
	// custom openbor_video_reader reading the DDR3 double-buffer. This cache channel stays idle.
	.scan_addr  (27'd0),
	.scan_rd    (1'b0),
	.scan_dout  (),
	.scan_ok    (),
	// P_SRC (ch5, ro) <- blitter source reads
	.p0_addr    (src_p0_addr),
	.p0_rd      (src_p0_rd),
	.p0_dout    (src_p0_dout),
	.p0_ok      (src_p0_ok),
	// STAGE (ch1, write-only) <- blitter BLT_OP_STAGE atlas DDR3->SDRAM writes (#44)
	.stage_addr (stage_waddr),
	.stage_wr   (stage_we_burst),
	.stage_din  (stage_din64),
	.stage_wdsn (8'h00),            // full-qword burst write
	.stage_ok   (stage_ok),
	// Coherency: vsync flushes ch0 (P_DST) + invalidates ch0/4/5; the intra-frame
	// stage barrier flushes ch1 (STAGE atlas) + invalidates ch5 (P_SRC).
	.vs            (fb_vs),
	.coh_busy      (),
	.stage_barrier (stage_barrier),
	.stage_busy    (stage_busy),
	// [retired] dst_barrier carry-forward coherency: ch0 (P_DST) is no longer written
	// (FB-in-BRAM), so the per-frame ch0->ch5 commit/invalidate is dead — tied off.
	.dst_barrier   (1'b0),
	.dst_busy      (),
	// SDRAM physical pins (incl. SDRAM_CLK forwarded internally)
	.sdram_dq   (SDRAM_DQ),
	.sdram_a    (SDRAM_A),
	.sdram_dqml (SDRAM_DQML),
	.sdram_dqmh (SDRAM_DQMH),
	.sdram_ba   (SDRAM_BA),
	.sdram_nwe  (SDRAM_nWE),
	.sdram_ncas (SDRAM_nCAS),
	.sdram_nras (SDRAM_nRAS),
	.sdram_ncs  (SDRAM_nCS),
	.sdram_cke  (SDRAM_CKE),
	.sdram_clk  (SDRAM_CLK)
);

// --- [FB-in-BRAM] on-chip framebuffer (comp_fbram) -------------------------
// [DDR-scanout] The on-chip SCAN buffer + WORK->SCAN snapshot + custom openbor scanout
// are RETIRED. comp_fbram now holds only WORK (bank0-3) + the off-screen APPSURF SURFACE
// (surf_*). blitter_top (comp_pipeline) writes/reads WORK via wr_*/rd_*; the vblank
// WORK->DDR copy (external comp_fb_dma) reads WORK via the same rd_* port (muxed by fb_dma_busy).
// Scanout is the custom openbor_video_reader reading the DDR3 double-buffer comp_fb_dma writes.
wire        fb_wr_en;  wire [14:0] fb_wr_qw; wire [1:0] fb_wr_lane; wire [15:0] fb_wr_pix;
// WORK read port (comp_fbram rd_*): time-shared between the compositor (blt_fb_rd_*) and
// the vblank WORK->DDR DMA (dma_work_rd_*). They are mutually exclusive in time — the DMA
// runs only while fb_dma_busy, during which blitter_top is parked in S_SNAP_* with the
// compositor idle (blt_fb_rd_en=0) — so a simple fb_dma_busy mux is race-free. [DDR-scanout]
wire        blt_fb_rd_en; wire [14:0] blt_fb_rd_qw;      // compositor's WORK read (blitter_top)
wire        dma_work_rd_en; wire [14:0] dma_work_rd_qw;  // comp_fb_dma's WORK read
wire        fb_rd_en  = fb_dma_busy ? dma_work_rd_en : blt_fb_rd_en;
wire [14:0] fb_rd_qw  = fb_dma_busy ? dma_work_rd_qw : blt_fb_rd_qw;
wire [63:0] fb_rd_qword;   // comp_fbram registered read data -> both readers

// [DDR-scanout] vblank WORK->DDR framebuffer-DMA handshake (blitter_top <-> comp_fb_dma).
wire        fb_dma_start;  // 1-cyc pulse from blitter_top's S_SNAP_* FSM
wire        fb_dma_busy;   // comp_fb_dma mid-copy (also the WORK-read mux select)
// [device-fix: double-buffer tearing] the reader's currently-displayed buffer -> comp_fb_dma,
// which writes the OTHER (back) buffer so it never overwrites the frame being scanned out.
wire        reader_disp_active;

// [app-surface v1] off-screen APP-SURFACE render-target port: blitter_top routes the
// composite write/read here (instead of the WORK banks) when SET_TARGET binds APPSURF,
// and (Task 7) reads it back as a texel source. Completes the Task-6 deferred emu-top
// routing — previously these floated (surf_wr_en -> z -> no write -> surface read black).
wire        surf_wr_en; wire [14:0] surf_wr_qw; wire [1:0] surf_wr_lane; wire [15:0] surf_wr_pix;
wire        surf_rd_en; wire [14:0] surf_rd_qw; wire [63:0] surf_rd_qword;

comp_fbram u_fbram (
	.clk        (clk_sys),
	.wr_en      (fb_wr_en),  .wr_qw(fb_wr_qw),  .wr_lane(fb_wr_lane), .wr_pix(fb_wr_pix),
	.rd_en      (fb_rd_en),  .rd_qw(fb_rd_qw),  .rd_qword(fb_rd_qword),
	// app-surface v1: off-screen APPSURF render target
	.surf_wr_en (surf_wr_en), .surf_wr_qw(surf_wr_qw), .surf_wr_lane(surf_wr_lane), .surf_wr_pix(surf_wr_pix),
	.surf_rd_en (surf_rd_en), .surf_rd_qw(surf_rd_qw), .surf_rd_qword(surf_rd_qword)
);

// ── [DDR-scanout] WORK -> DDR framebuffer burst-DMA (Task 1 comp_fb_dma) ──────────────
// On blitter_top's vblank pulse it streams the completed WORK buffer (comp_fbram rd_*) out
// to FB_BYTE_BASE via a DDR write master on the freed arbiter reader slot (rdr_*, below).
wire        dma_mem_wr;   wire [31:0] dma_mem_addr; wire [7:0] dma_mem_burstcnt;
wire [63:0] dma_mem_din;  wire [7:0]  dma_mem_be;
comp_fb_dma #(.AW(15), .MAW(32)) u_fb_dma (
	.clk          (clk_sys),
	.rst          (RESET),
	.start        (fb_dma_start),
	.busy         (fb_dma_busy),
	.fb_qw_base   (FB_QW_BASE),
	.disp_active  (reader_disp_active),   // [device-fix] write the BACK buffer (~reader's displayed)
	// WORK read (muxed onto comp_fbram rd_* by fb_dma_busy above)
	.work_rd_en   (dma_work_rd_en),
	.work_rd_qw   (dma_work_rd_qw),
	.work_rd_qword(fb_rd_qword),
	// DDR write master -> arbiter reader slot (rdr_*)
	.mem_wr       (dma_mem_wr),
	.mem_addr     (dma_mem_addr),
	.mem_burstcnt (dma_mem_burstcnt),
	.mem_din      (dma_mem_din),
	.mem_be       (dma_mem_be),
	.mem_busy     (rdr_busy_w)          // arbiter reader-slot busy = write not-yet-accepted
);

// --- DDR3 port sharing: old ddram (SDRAM clear) + native video reader ---
wire  [7:0] old_ddr_burstcnt;
wire [28:0] old_ddr_addr;
wire        old_ddr_rd;
wire [63:0] old_ddr_din;
wire  [7:0] old_ddr_be;
wire        old_ddr_we;

ddram ddr
(
	.DDRAM_CLK(clk_sys),
	.DDRAM_BUSY(DDRAM_BUSY),
	.DDRAM_BURSTCNT(old_ddr_burstcnt),
	.DDRAM_ADDR(old_ddr_addr),
	.DDRAM_DOUT(DDRAM_DOUT),
	.DDRAM_DOUT_READY(DDRAM_DOUT_READY & ~use_nv),
	.DDRAM_RD(old_ddr_rd),
	.DDRAM_DIN(old_ddr_din),
	.DDRAM_BE(old_ddr_be),
	.DDRAM_WE(old_ddr_we),
	.reset(RESET),
	.addr(addr),
	.dout(),
	.din(0),
	.we(we),
	.rd(0),
	.ready()
);

// [DDR-scanout] The arbiter's reader (m0) slot is TIME-SHARED (mux below): the
// openbor_video_reader READS the active DDR buffer during display, and comp_fb_dma WRITES the
// inactive buffer during vblank (fb_dma_busy). The blitter is the borrowing master on blt_*.
wire use_nv = NATIVE_VID;

// --- Blitter arbiter + blitter_top (fpga-hw-blitter #003 iteration 5) ---
// The hardware blitter (blitter_top) shares the single f2h port with the
// UNMODIFIED video reader via a 2-master priority arbiter (reader = default
// owner; blitter borrows idle gaps). blitter_top walks a command ring at
// 0x3A0E0000 (in the proven 1 MiB region), composites into the existing
// double-buffer, and writes the video control word as a drop-in producer.
// Set ENABLE=0 for a normal core (blitter inert, reader owns the bus).
// [wedge probe v4] live blitter FSM snapshot ({stuck>>16, rd_issued, state}) +
// live mem_addr, published by the READER (which survives a blitter park) into
// the vsync-writeback words: 0x3A070004 = blt_dbg, 0x3A070008 = blt mem_addr.
wire [31:0] blt_dbg_live;
wire  [7:0] arb_ddr_burstcnt;
wire [28:0] arb_ddr_addr;
wire        arb_ddr_rd;
wire [63:0] arb_ddr_din;
wire  [7:0] arb_ddr_be;
wire        arb_ddr_we;
wire        rdr_busy_w, rdr_grant_w;

// blitter master port
wire [31:0] blt_mem_addr;
wire        blt_mem_rd, blt_mem_wr;
wire [63:0] blt_mem_din;
wire  [7:0] blt_mem_be;
wire        blt_busy_w, blt_grant_w;
// busy from the DDR blitter arbiter into the demux DDR side (was blt_busy_w
// before the demux was inserted; demux now owns blt_busy_w toward the blitter)
wire        blt_arb_busy;

// comp_pipeline burst length on the blitter mem_* master. For FB (SDRAM) accesses
// vram_demux walks this many single-qword cache beats internally. For NON-FB DDR
// accesses (the command-ring reads and the BLT_OP_STAGE DDR3 atlas reads — the
// per-blit source read no longer hits DDR3) it must reach ddr_blitter_arb so the
// DDR burst returns the full beat count — otherwise a multi-beat DDR read returns
// one beat and comp_burst hangs in S_RDBEATS (the #1 wiring-review wedge).
wire [7:0]  blt_mem_burstcnt;

blitter_top blitter
(
	.clk            (clk_sys),
	.rst            (RESET),
	.mem_addr       (blt_mem_addr),
	.mem_rd         (blt_mem_rd),
	.mem_wr         (blt_mem_wr),
	.mem_din        (blt_mem_din),
	.mem_be         (blt_mem_be),
	.mem_burstcnt   (blt_mem_burstcnt),
	// mem read-data + busy now come from vram_demux (DDR or SDRAM per address)
	.mem_dout       (blt_demux_dout),
	.mem_dout_ready (blt_demux_dready),
	.mem_busy       (blt_busy_w),
	// SDRAM source path — now the SOLE source path (src_in_sdram hardwired 1).
	// P_SRC cache-ok source reads (JC-T5): p0_* is the per-blit source fetch.
	.p0_addr              (src_p0_addr),
	.p0_rd                (src_p0_rd),
	.p0_dout              (src_p0_dout),
	.p0_ok                (src_p0_ok),
	// [#44] STAGE (BLT_OP_STAGE) atlas DDR3->SDRAM burst writes -> cache ch1.
	// The single-word src_sdram_we/din path is unused (the FSM stages via the burst
	// variant); the burst outputs carry the staged beat + 8-byte-aligned dest addr.
	.src_sdram_we         (),
	.src_sdram_din        (),
	.src_sdram_waddr      (stage_waddr),
	.src_sdram_we_burst   (stage_we_burst),
	.src_sdram_din64      (stage_din64),
	.src_sdram_ok         (stage_ok),       // cache-ok: hold the burst write until accepted
	// intra-frame STAGE->P_SRC coherency barrier (commit ch1 + invalidate ch5)
	.stage_barrier        (stage_barrier),
	.stage_barrier_busy   (stage_busy),
	// (dst_barrier carry-forward coherency retired with FB-in-BRAM)
	// [gmloader-GPU slim] ch0 (P_DST) write port + bgw_active are retired along
	// with OP_BGPLANE_WRITE — blitter_top no longer has these ports.
	// [FB-in-BRAM] composite destination -> on-chip comp_fbram (replaces the SDRAM FB)
	.fb_wr_en       (fb_wr_en),
	.fb_wr_qw       (fb_wr_qw),
	.fb_wr_lane     (fb_wr_lane),
	.fb_wr_pix      (fb_wr_pix),
	.fb_rd_en       (blt_fb_rd_en),   // compositor WORK read (muxed with the DMA at u_fbram)
	.fb_rd_qw       (blt_fb_rd_qw),
	.fb_rd_qword    (fb_rd_qword),
	// [DDR-scanout] vblank WORK->DDR framebuffer-DMA handshake -> comp_fb_dma (u_fb_dma).
	// S_SNAP_* pulses fb_dma_start at vblank (fb_vs = tim_vblank, the reader's scanout vblank)
	// and waits on fb_dma_busy while comp_fb_dma streams WORK out to the DDR framebuffer.
	.vs             (fb_vs),
	.osd_restart    (osd_restart),
	.osd_fps_on     (osd_fps_on),
	.fb_dma_start   (fb_dma_start),
	.fb_dma_busy    (fb_dma_busy),
	// [app-surface v1] off-screen APPSURF render-target port -> comp_fbram u_fbram
	.surf_wr_en     (surf_wr_en),
	.surf_wr_qw     (surf_wr_qw),
	.surf_wr_lane   (surf_wr_lane),
	.surf_wr_pix    (surf_wr_pix),
	.surf_rd_en     (surf_rd_en),
	.surf_rd_qw     (surf_rd_qw),
	.surf_rd_qword  (surf_rd_qword),
	.idle           (),
	.dbg            (blt_dbg_live)  // [wedge probe v4] live state -> reader vsync writeback
);

// [DDR-scanout custom-reader] the arbiter reader slot (rdr_*, the DEFAULT/priority owner) is
// TIME-SHARED: comp_fb_dma WRITES the framebuffer during the scanout vblank (fb_dma_busy), the
// openbor_video_reader READS the active buffer during active display (!fb_dma_busy). Double-
// buffering guarantees the writer (inactive buffer) and reader (active buffer) never touch the
// same bytes; this mux just serializes the single f2h rdr slot. During fb_dma_busy the reader
// is forced busy (stalls) so comp_fb_dma owns the bus; its own reads resume after the copy
// (vblank is long vs the ~0.2 ms copy). rd_ddr_* are the reader's ddr_* master (below).
wire  [7:0] rd_ddr_burstcnt; wire [28:0] rd_ddr_addr; wire rd_ddr_rd;
wire [63:0] rd_ddr_din;      wire  [7:0] rd_ddr_be;   wire rd_ddr_we;
wire  [7:0] rdr_burstcnt = fb_dma_busy ? dma_mem_burstcnt   : rd_ddr_burstcnt;
wire [28:0] rdr_addr     = fb_dma_busy ? dma_mem_addr[28:0] : rd_ddr_addr;
wire        rdr_rd       = fb_dma_busy ? 1'b0               : rd_ddr_rd;
wire [63:0] rdr_din      = fb_dma_busy ? dma_mem_din        : rd_ddr_din;
wire  [7:0] rdr_be       = fb_dma_busy ? dma_mem_be         : rd_ddr_be;
wire        rdr_we       = fb_dma_busy ? dma_mem_wr         : rd_ddr_we;
// reader-side handshake: busy=1 (stall) + dout_ready=0 while comp_fb_dma owns the slot.
wire        rd_ddr_busy       = fb_dma_busy ? 1'b1 : rdr_busy_w;
wire        rd_ddr_dout_ready = fb_dma_busy ? 1'b0 : (DDRAM_DOUT_READY & use_nv & rdr_grant_w);

ddr_blitter_arb #(.ENABLE(1'b1)) blitter_arb
(
	.clk          (clk_sys),
	.reset        (RESET),
	// reader (m0): time-shared reader-read / comp_fb_dma-write master (mux above).
	.rdr_burstcnt (rdr_burstcnt),
	.rdr_addr     (rdr_addr),
	.rdr_rd       (rdr_rd),
	.rdr_din      (rdr_din),
	.rdr_be       (rdr_be),
	.rdr_we       (rdr_we),
	.rdr_busy     (rdr_busy_w),
	.rdr_grant    (rdr_grant_w),
	// blitter DDR side now comes from vram_demux (bd_*), not the raw mem_* bus
	.blt_burstcnt (blt_mem_burstcnt),  // #1 fix: real burst len (was 8'd1 -> multi-beat DDR read wedge)
	.blt_addr     (bd_addr),
	.blt_rd       (bd_rd),
	.blt_din      (bd_din),
	.blt_be       (bd_be),
	.blt_we       (bd_wr),
	.blt_busy     (blt_arb_busy),
	.blt_grant    (blt_grant_w),
	.ddram_busy       (DDRAM_BUSY),
	.ddram_dout_ready (DDRAM_DOUT_READY),
	.ddram_burstcnt   (arb_ddr_burstcnt),
	.ddram_addr       (arb_ddr_addr),
	.ddram_rd         (arb_ddr_rd),
	.ddram_din        (arb_ddr_din),
	.ddram_be         (arb_ddr_be),
	.ddram_we         (arb_ddr_we),
	.dbg              ()             // #34 debug probe stripped for shipping core
);

// --- Task 4: VRAM demux — route blitter mem_* by address -----------------
// FB0/FB1 region -> SDRAM (arbiter P_DST); everything else -> DDR (blitter_arb
// blt_* port).  blt_mem_addr is 32-bit qword-addressed; the demux uses [28:0].
vram_demux vdemux
(
	.clk            (clk_sys),
	.reset          (RESET),
	// blitter mem_* side
	.blt_addr       (blt_mem_addr),
	.blt_rd         (blt_mem_rd),
	.blt_wr         (blt_mem_wr),
	.blt_din        (blt_mem_din),
	.blt_be         (blt_mem_be),
	.blt_burstcnt   (blt_mem_burstcnt),
	.blt_dout       (blt_demux_dout),
	.blt_dout_ready (blt_demux_dready),
	.blt_busy       (blt_busy_w),
	// DDR side -> ddr_blitter_arb blt_* (bd_*)
	.ddr_addr       (bd_addr),
	.ddr_rd         (bd_rd),
	.ddr_wr         (bd_wr),
	.ddr_din        (bd_din),
	.ddr_be         (bd_be),
	.ddr_dout       (DDRAM_DOUT),
	.ddr_dout_ready (DDRAM_DOUT_READY & blt_grant_w),
	.ddr_busy       (blt_arb_busy),
	// SDRAM side -> arbiter P_DST (dst_*). Write-side (addr/wr/din/wdsn) is
	// wired straight through to dst_* (see the assigns near the dst_* wire
	// declarations) now that the bgw_active priority mux is retired.
	.sd_addr        (vd_sd_addr),
	.sd_rd          (dst_rd),
	.sd_wr          (vd_sd_wr),
	.sd_din         (vd_sd_din),
	.sd_wdsn        (vd_sd_wdsn),
	.sd_dout        (dst_dout),
	.sd_ok          (dst_ok),
	.dbg            ()             // #34 debug probe stripped for shipping core
);

// 2-way DDR3 mux: native video (via arbiter) > legacy
assign DDRAM_BURSTCNT = use_nv ? arb_ddr_burstcnt : old_ddr_burstcnt;
assign DDRAM_ADDR     = use_nv ? arb_ddr_addr     : old_ddr_addr;
assign DDRAM_RD       = use_nv ? arb_ddr_rd       : old_ddr_rd;
assign DDRAM_DIN      = use_nv ? arb_ddr_din      : old_ddr_din;
assign DDRAM_BE       = use_nv ? arb_ddr_be       : old_ddr_be;
assign DDRAM_WE       = use_nv ? arb_ddr_we       : old_ddr_we;

reg        we;
reg [28:0] addr = 0;

always @(posedge clk_sys) begin
	reg [4:0] cnt = 9;

	if(~RESET & cfg[15]) begin
		cnt <= cnt + 1'b1;
		we <= &cnt;
		if(cnt == 8) addr <= addr + 1'd1;
	end
end

////////////////////////////  MT32pi  //////////////////////////////////

//
// Pin | USB Name | Signal
// ----+----------+--------------
// 0   | D+       | I/O I2C_SDA / RX (midi in)
// 1   | D-       | O   TX (midi out)
// 2   | TX-      | I   I2S_WS (1 == right)
// 3   | GND_d    | I   I2C_SCL
// 4   | RX+      | I   I2S_BCLK
// 5   | RX-      | I   I2S_DAT
// 6   | TX+      | -   none
//

reg [15:0] mt32_i2s_r, mt32_i2s_l;
wire midi_rx;

// [native-audio] The FPGA owns the audio path again: openbor_video_reader drains
// the DDR3 ring the HPS loader fills (0x3A0D0000) into a dual-clock FIFO on
// CLK_AUDIO. MT32pi I2S capture stays retired.
wire [15:0] nv_audio_l, nv_audio_r;
assign AUDIO_L = nv_audio_l;
assign AUDIO_R = nv_audio_r;
assign AUDIO_S = 1;

assign USER_OUT[0]   = 1;
assign USER_OUT[1]   = UART_RXD;
assign USER_OUT[6:2] = '1;
assign UART_TXD      = midi_rx;


//
// crossed/straight cable selection
//

generate
genvar i;
for(i = 0; i<2; i++) begin : clk_rate
	wire clk_in = i ? USER_IN[6] : USER_IN[4];
	reg [4:0] cnt;
	always @(posedge CLK_AUDIO) begin : clkr
		reg       clk_sr, clk, old_clk;
		reg [4:0] cnt_tmp;

		clk_sr <= clk_in;
		if (clk_sr == clk_in) clk <= clk_sr;

		if(~&cnt_tmp) cnt_tmp <= cnt_tmp + 1'd1;
		else cnt <= '1;

		old_clk <= clk;
		if(~old_clk & clk) begin
			cnt <= cnt_tmp;
			cnt_tmp <= 0;
		end
	end
end

reg crossed;
always @(posedge CLK_AUDIO) crossed <= (clk_rate[0].cnt <= clk_rate[1].cnt);
endgenerate

wire   i2s_ws   = crossed ? USER_IN[2] : USER_IN[5];
wire   i2s_data = crossed ? USER_IN[5] : USER_IN[2];
wire   i2s_bclk = crossed ? USER_IN[4] : USER_IN[6];
assign midi_rx  = crossed ? USER_IN[6] : USER_IN[4];

always @(posedge CLK_AUDIO) begin : i2s_proc
	reg [15:0] i2s_buf = 0;
	reg  [4:0] i2s_cnt = 0;
	reg        clk_sr;
	reg        i2s_clk = 0;
	reg        old_clk, old_ws;
	reg        i2s_next = 0;

	// Debounce clock
	clk_sr <= i2s_bclk;
	if (clk_sr == i2s_bclk) i2s_clk <= clk_sr;

	// Latch data and ws on rising edge
	old_clk <= i2s_clk;
	if (i2s_clk && ~old_clk) begin

		if (~i2s_cnt[4]) begin
			i2s_cnt <= i2s_cnt + 1'd1;
			i2s_buf[~i2s_cnt[3:0]] <= i2s_data;
		end

		// Word Select will change 1 clock before the new word starts
		old_ws <= i2s_ws;
		if (old_ws != i2s_ws) i2s_next <= 1;
	end

	if (i2s_next) begin
		i2s_next <= 0;
		i2s_cnt <= 0;
		i2s_buf <= 0;

		if (i2s_ws) mt32_i2s_l <= i2s_buf;
		else        mt32_i2s_r <= i2s_buf;
	end

	if (RESET) begin
		i2s_buf    <= 0;
		mt32_i2s_l <= 0;
		mt32_i2s_r <= 0;
	end
end

/////////////////////   VIDEO   ///////////////////

localparam lfsr_n = 63;

wire PAL = status[4];
wire FB  = status[5];
wire [2:0] led = status[8:6];
wire [2:0] h_pos = status[14:12];  // OSD H Position (CRT): 0..6 → 0,+1,+2,+3,-3,-2,-1
wire [2:0] v_pos = status[17:15];  // OSD V Position (CRT): 0..6 → 0,+1,+2,+3,-3,-2,-1
// status[18] is unused (was OSD Vertical Crop (224p); removed — meaningless at 216
// active lines, the native height IS the full framebuffer now).
wire       osd_restart = status[19];  // OSD Reset (momentary toggle); taken by the wrapper (feat #4)
                                       // via C_STATUS low32 bit0 (blitter_top S_WR_STATUS below)
wire       osd_fps_on  = status[20];  // OSD FPS Overlay: 0=off, 1=on; mirrored to ARM via
                                       // C_STATUS low32 bit1 (blitter_top S_WR_STATUS below)

// CROP is permanently off at native 216p (video_freak's CROP_SIZE=0 convention):
// the active area already equals the full framebuffer, so there is nothing left
// to crop. SCALE is tied to 0 (Normal / no integer rescale) — non-goal per the
// design doc; the framework's ascal (fpga/sys/sys_top.v) does the final HDMI
// scale from whatever VIDEO_ARX/ARY this produces, same as it already does for
// h_pos/v_pos.
wire        vga_de_cropped;
wire [12:0] freak_arx, freak_ary;

video_freak video_freak
(
	.CLK_VIDEO    (CLK_VIDEO),
	.CE_PIXEL     (ce_pix_gen),
	// [DDR-scanout custom-reader] nv_vs/nv_de (native_video) retired -> generic video timing.
	// video_freak drives VIDEO_ARX/ARY (HDMI aspect); its vga_de_cropped is unused (VGA_DE
	// comes from the reader/timing tim_de). VGA_SCALER=0 (custom reader -> video_mixer path).
	.VGA_VS       (VSync),
	.HDMI_WIDTH   (HDMI_WIDTH),
	.HDMI_HEIGHT  (HDMI_HEIGHT),
	.VGA_DE       (vga_de_cropped),
	.VIDEO_ARX    (freak_arx),
	.VIDEO_ARY    (freak_ary),

	.VGA_DE_IN    (~(HBlank | VBlank)),
	.ARX          (12'd4),
	.ARY          (12'd3),
	.CROP_SIZE    (12'd0),
	.CROP_OFF     (5'd0),
	.SCALE        (3'd0)
);

reg   [9:0] hc;
reg   [9:0] vc;
reg   [9:0] vvc;

reg  [lfsr_n:0] rnd_reg;
wire [lfsr_n:0] rnd;

wire  [5:0] rnd_c = {rnd_reg[0],rnd_reg[1],rnd_reg[2],rnd_reg[2],rnd_reg[2],rnd_reg[2]};

lfsr #(lfsr_n) random(rnd);

always @(posedge CLK_VIDEO) begin
	ce_pix <= ce_pix_gen;

	if(ce_pix) begin
		if(hc == 499) begin
			hc <= 0;
			if(vc == (PAL ? (forced_scandoubler ? 623 : 311) : (forced_scandoubler ? 523 : 261))) begin
				vc <= 0;
				vvc <= vvc + 9'd6;
			end else begin
				vc <= vc + 1'd1;
			end
		end else begin
			hc <= hc + 1'd1;
		end

		rnd_reg <= rnd;
	end
end

reg HBlank;
reg HSync;
reg VBlank;
reg VSync;

reg ce_pix;
always @(posedge CLK_VIDEO) begin
	if (hc == 384) HBlank <= 1;
		else if (hc == 0) HBlank <= 0;

	if (hc == 410) begin
		HSync <= 1;

		if(PAL) begin
			if(vc == (forced_scandoubler ? 609 : 280)) VSync <= 1;
				else if (vc == (forced_scandoubler ? 617 : 283)) VSync <= 0;

			if(vc == (forced_scandoubler ? 601 : 270)) VBlank <= 1;
				else if (vc == 0) VBlank <= 0;
		end
		else begin
			if(vc == (forced_scandoubler ? 490 : 224)) VSync <= 1;
				else if (vc == (forced_scandoubler ? 496 : 227)) VSync <= 0;

			if(vc == (forced_scandoubler ? 480 : 224)) VBlank <= 1;
				else if (vc == 0) VBlank <= 0;
		end
	end

	if (hc == 448) HSync <= 0;
end

reg  [7:0] cos_out;
wire [5:0] cos_g = cos_out[7:3]+6'd32;
cos cos(vvc + {vc>>forced_scandoubler, 2'b00}, cos_out);

wire [7:0] comp_v = (cos_g >= rnd_c) ? {cos_g - rnd_c, 2'b00} : 8'd0;

// --- [DDR-scanout custom-reader] openbor synchronous DDR scanout -> VGA -----------------
// The custom openbor_video_timing (exact Genesis H40) + openbor_video_reader read the DDR3
// double-buffer that comp_fb_dma writes and drive VGA_* directly (VGA_SCALER=0 -> video_mixer/
// analog, the timing the TV syncs to). We instantiate the timing + reader DIRECTLY (NOT
// openbor_video_top) — its audio HPS-I/O is LIVE (at absolute 0x3A ring addresses), ioctl is
// DEFERRED (tied off). joystick_0/1 are LIVE
// ([joy-ddr-writeback]): the reader publishes them to DDR +0x008/+0x018 each frame,
// the OpenBOR-contract input path the engine reads. The reader's ddr_* master is the
// rd_ddr_* side of the rdr time-share mux above.
// OSD CRT position (status[14:12]/[17:15]) -> timing h_adj/v_adj, as openbor_video_top did.
wire signed [4:0] h_adj = (h_pos == 3'd0) ?  5'sd0 : (h_pos == 3'd1) ?  5'sd4 :
                          (h_pos == 3'd2) ?  5'sd8 : (h_pos == 3'd3) ?  5'sd12 :
                          (h_pos == 3'd4) ? -5'sd12 : (h_pos == 3'd5) ? -5'sd8 : -5'sd4;
wire signed [3:0] v_adj = (v_pos == 3'd0) ?  4'sd0 : (v_pos == 3'd1) ?  4'sd1 :
                          (v_pos == 3'd2) ?  4'sd2 : (v_pos == 3'd3) ?  4'sd3 :
                          (v_pos == 3'd4) ? -4'sd3 : (v_pos == 3'd5) ? -4'sd2 : -4'sd1;

openbor_video_timing u_timing (
	.clk       (CLK_VIDEO),
	.ce_pix    (ce_pix_gen),
	.reset     (RESET),
	.h_adj     (h_adj),
	.v_adj     (v_adj),
	.hsync     (tim_hsync),
	.vsync     (tim_vsync),
	.hblank    (tim_hblank),
	.vblank    (tim_vblank),
	.de        (tim_de),
	.hcount    (),                 // unused (reader uses vcount + new_line/new_frame)
	.vcount    (tim_vcount),
	.new_frame (tim_new_frame),
	.new_line  (tim_new_line)
);

wire [7:0] reader_r, reader_g, reader_b;
openbor_video_reader #(.FB_QW_BASE(FB_QW_BASE), .SCANOUT_ONLY(1'b1)) u_reader (
	// DDR3 master -> rd_ddr_* side of the rdr time-share mux (arbiter reader slot)
	.ddr_clk        (clk_sys),
	.ddr_busy       (rd_ddr_busy),
	.ddr_burstcnt   (rd_ddr_burstcnt),
	.ddr_addr       (rd_ddr_addr),
	.ddr_dout       (DDRAM_DOUT),
	.ddr_dout_ready (rd_ddr_dout_ready),
	.ddr_rd         (rd_ddr_rd),
	.ddr_din        (rd_ddr_din),
	.ddr_be         (rd_ddr_be),
	.ddr_we         (rd_ddr_we),
	// pixel clock + timing (from u_timing)
	.clk_vid        (CLK_VIDEO),
	.ce_pix         (ce_pix_gen),
	.reset          (RESET),
	.de             (tim_de),
	.hblank         (tim_hblank),
	.vblank         (tim_vblank),
	.new_frame      (tim_new_frame),
	.new_line       (tim_new_line),
	.vcount         (tim_vcount),
	// ioctl HPS-I/O DEFERRED — tied off; audio is LIVE (absolute ring map)
	.ioctl_download (1'b0),
	.ioctl_wr       (1'b0),
	.ioctl_addr     (27'd0),
	.ioctl_dout     (8'd0),
	.ioctl_wait     (),
	// [joy-ddr-writeback] LIVE hps_io joysticks: the reader publishes them to DDR
	// (+0x008/+0x018) each frame — the OpenBOR-contract input path the engine reads.
	.joystick_0     (joystick_0),
	.joystick_1     (joystick_1),
	.joystick_2     (32'd0),
	.joystick_3     (32'd0),
	.joystick_l_analog_0 (16'd0),
	// pixel output
	.r_out          (reader_r),
	.g_out          (reader_g),
	.b_out          (reader_b),
	// native audio: DDR3 ring -> dual-clock FIFO -> AUDIO_L/R
	.clk_audio      (CLK_AUDIO),
	.audio_l        (nv_audio_l),
	.audio_r        (nv_audio_r),
	.enable         (NATIVE_VID),
	.frame_ready    (),
	.disp_active    (reader_disp_active),   // [device-fix] displayed buffer -> comp_fb_dma back-buffer select
	.dbg_blt        (blt_dbg_live),          // [wedge probe v4] -> 0x3A070004
	.dbg_addr       (blt_mem_addr),          // [wedge probe v4] -> 0x3A070008
	.dbg_diag       (32'd0)
);

assign VGA_DE  = tim_de;
assign VGA_HS  = tim_hsync;
assign VGA_VS  = tim_vsync;
assign VGA_R   = reader_r;
assign VGA_G   = reader_g;
assign VGA_B   = reader_b;

endmodule
