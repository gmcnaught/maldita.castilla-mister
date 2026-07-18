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

// CE_PIXEL: exact Genesis H40 timing from CLK_VIDEO (53.693 MHz).
// Active pixels: /8 (6.712 MHz). Blanking uses variable /8,/9,/10 widths
// so that total MCLK per line = 3420, matching Genesis exactly (H_TOTAL=420).
// Pattern per line: 320 active @/8 + blanking @mixed = 3420 MCLK total.
reg [3:0] ce_cnt;
reg ce_pix_gen;
reg [9:0] pix_in_line;

// Blanking pixel width schedule: Genesis uses 28@/10 + 4@/9 + 68@/8 = 100 blanking pixels
// 28*10 + 4*9 + 68*8 = 280+36+544 = 860 MCLK blanking. 320*8 + 860 = 3420 total.
wire in_active = (pix_in_line < 10'd320);
wire in_blank_10 = (pix_in_line >= 10'd320) && (pix_in_line < 10'd348);
wire in_blank_9  = (pix_in_line >= 10'd348) && (pix_in_line < 10'd352);
wire [3:0] pix_width = in_active   ? 4'd7 :   // /8: count 0-7
                        in_blank_10 ? 4'd9 :   // /10: count 0-9
                        in_blank_9  ? 4'd8 :   // /9: count 0-8
                                      4'd7;    // /8: remaining blanking

always @(posedge CLK_VIDEO) begin
	if (RESET) begin
		ce_cnt <= 4'd0;
		ce_pix_gen <= 1'b0;
		pix_in_line <= 10'd0;
	end
	else begin
		ce_pix_gen <= (ce_cnt == 4'd0);
		if (ce_cnt == pix_width) begin
			ce_cnt <= 4'd0;
			if (pix_in_line == 10'd419)
				pix_in_line <= 10'd0;
			else
				pix_in_line <= pix_in_line + 10'd1;
		end
		else begin
			ce_cnt <= ce_cnt + 4'd1;
		end
	end
end
assign CE_PIXEL = ce_pix_gen;

assign VGA_SL = 0;
assign VGA_F1 = 0;
// OpenBOR renders at 320x240, 4:3 aspect ratio. When Vertical Crop (status[18])
// is off, freak_arx/freak_ary (video_freak, instantiated below near h_pos/v_pos)
// equal these same fixed values, so this is a no-op until the option is enabled.
assign VIDEO_ARX = NATIVE_VID_ACTIVE ? freak_arx : 13'd4;
assign VIDEO_ARY = NATIVE_VID_ACTIVE ? freak_ary : 13'd3;
assign VGA_DISABLE = 0;

// ── [DDR-scanout] DDR framebuffer address map ────────────────────────────────────────
// The framework's ascal scans a DDR3 framebuffer this fabric writes. Placed in the 768 KiB
// region ABOVE the host texture heap, at MF_DEV_TLBUF_OFF (0xF40000) within the 16 MiB
// blitter window (0x3B000000): the host writes only ctrl(+0)/ring(+0x40)/SRC-heap(+0x80000..
// +0xF40000) and never above 0xF40000 (raster_backend_mfgpu.cpp), and the RTL has no
// TL_BUF/FRT/CFT reads — so this slot is disjoint from control block, ring, and heap, and
// the host never allocates here. No host-constant change needed.
//   FB byte range: 0x3BF40000 .. 0x3BF40000 + 320*240*2 (0x25800) = 0x3BF65800  (< 0x3C000000)
localparam [28:0] FB_QW_BASE   = 29'h077E8000;  // 0x3BF40000 >> 3 (qword base; DMA mem_addr = base+qw)
localparam [31:0] FB_BYTE_BASE = 32'h3BF40000;  // ascal FB_BASE (byte address)

// ── [DDR-scanout] framework framebuffer (FB_EN + ascal) scanout ──────────────────────
// The fabric writes a 320x240 RGB565 framebuffer to DDR (FB_BASE, via comp_fb_dma) and the
// framework's ascal scales it to HDMI (VGA_SCALER=1), replacing the retired custom openbor
// scanout. Triple-buffered by ascal (lowlat=0, framework default). FB_* ports exist only
// under MISTER_FB (set in Maldita.qsf). CROP/ASPECT — DEVICE-CONFIRM (Task 4): presenting
// the FULL 320x240 frame (FB_HEIGHT=240); the game's usual 320x224 crop (status[18]) no
// longer sits on the analog path — VIDEO_ARX/ARY (above) drives the HDMI aspect. If the
// crop/aspect regresses on device, switch to FB_HEIGHT=224 + adjust FB_BASE/aspect here.
`ifdef MISTER_FB
assign VGA_SCALER    = 1'b1;          // route scanout through ascal (HDMI from FB_BASE)
assign FB_EN         = 1'b1;
assign FB_FORMAT     = 5'b00100;      // 16bpp RGB565 ([2:0]=100 16bpp, [3]=0 565, [4]=0 RGB)
assign FB_WIDTH      = 12'd320;
assign FB_HEIGHT     = 12'd240;
assign FB_STRIDE     = 14'd640;       // 320 px * 2 B/px, contiguous (matches comp_fb_dma layout)
assign FB_BASE       = FB_BYTE_BASE;  // 0x3BF40000 (above the host texture heap)
assign FB_FORCE_BLANK = 1'b0;
// FB_VBL / FB_LL are framework INPUTS: FB_VBL sources fb_vs (the DMA trigger, above); FB_LL
// (low-latency select) is framework-driven and observed only — the emu does not drive it.
`else
assign VGA_SCALER    = 1'b0;          // FB path disabled build — analog scanout
`endif

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
	"SC0,SOL,Load Quest;",
	"-;",
	"OCE,H Position (CRT),0,+1,+2,+3,-3,-2,-1;",
	"OFH,V Position (CRT),0,+1,+2,+3,-3,-2,-1;",
	"OI,Vertical Crop (224p),Disabled,Enabled;",
	"-;",
	"OK,FPS Overlay,Off,On;",
	"TJ,Restart Quest;",
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

// SC0 mounted image — config file created instantly, no ioctl streaming.
// We only need the filename (from .s0 config). No disk I/O needed.
wire        img_mounted;
wire [63:0] img_size;

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
	.ioctl_wait(ioctl_wait),
	// SC0 mount signals
	.img_mounted(img_mounted),
	.img_size(img_size),
	// Tie off disk I/O — we never read/write sectors
	.sd_lba('{32'd0}),
	.sd_rd(1'b0),
	.sd_wr(1'b0),
	.sd_buff_din('{8'd0})
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
// clk_sys-domain vblank for the coherency flush + the WORK->DDR DMA trigger (blitter_top
// edge-detects the rising edge -> S_SNAP_* pulses fb_dma_start). [DDR-scanout] Sourced from
// the framework FB_VBL: ascal's framebuffer vblank. Triggering the copy on FB_VBL lands the
// WORK->DDR write between ascal's reads of FB_BASE (ascal triple-buffers the single FB_BASE,
// lowlat=0), minimizing tearing; the ~0.2 ms copy fits well inside the vblank. FB_VBL is
// clk_vid-domain (sys_top registers ascal o_vbl on clk_vid), so double-flop into clk_sys.
// DEVICE-CONFIRM (Task 4): verify no tear vs ascal's FB_BASE read cadence; if it tears,
// gate the writer more tightly on FB_VBL width or add a second FB_BASE ping-pong.
`ifdef MISTER_FB
wire        fb_vs_src = FB_VBL;
`else
wire        fb_vs_src = VSync;   // FB path disabled build — generic-timing fallback
`endif
reg  [1:0]  fb_vs_sync = 2'b0;
always @(posedge clk_sys) fb_vs_sync <= {fb_vs_sync[0], fb_vs_src};
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
	// framework FB_EN + ascal path from DDR (Task 3). This cache channel stays tied idle.
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
// WORK->DDR copy (external comp_fb_dma) reads WORK via the same rd_* port (wired in Task 3).
// Scanout is now the framework FB_EN + ascal path from a DDR framebuffer (Task 3).
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
comp_fb_dma #(.FB_QWORDS(19200), .AW(15), .MAW(32)) u_fb_dma (
	.clk          (clk_sys),
	.rst          (RESET),
	.start        (fb_dma_start),
	.busy         (fb_dma_busy),
	.fb_base_qw   (FB_QW_BASE),
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

// [DDR-scanout] The custom openbor video reader (native_video) is retired, so its DDR3
// reader master is gone. The arbiter's reader slot is tied IDLE below; the blitter is the
// sole DDR master. Task 3 repurposes this freed reader slot for the comp_fb_dma writer.
wire use_nv = NATIVE_VID;

// --- Blitter arbiter + blitter_top (fpga-hw-blitter #003 iteration 5) ---
// The hardware blitter (blitter_top) shares the single f2h port with the
// UNMODIFIED video reader via a 2-master priority arbiter (reader = default
// owner; blitter borrows idle gaps). blitter_top walks a command ring at
// 0x3A0E0000 (in the proven 1 MiB region), composites into the existing
// double-buffer, and writes the video control word as a drop-in producer.
// Set ENABLE=0 for a normal core (blitter inert, reader owns the bus).
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
	// S_SNAP_* pulses fb_dma_start at vblank (fb_vs = ascal FB_VBL) and waits on fb_dma_busy
	// while comp_fb_dma streams WORK out to the DDR framebuffer.
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
	.dbg            ()              // #34 debug probe stripped for shipping core
);

ddr_blitter_arb #(.ENABLE(1'b1)) blitter_arb
(
	.clk          (clk_sys),
	.reset        (RESET),
	// [DDR-scanout] the freed openbor reader slot is repurposed as comp_fb_dma's DDR WRITE
	// master (WORK->framebuffer). The reader slot is the arbiter's DEFAULT/priority owner, and
	// the blitter can't borrow while rdr_we is asserted — but there's no contention anyway: the
	// DMA runs only at vblank while the blitter is parked in S_SNAP_*. rdr_rd tied 0 (write-only);
	// mem_busy = rdr_busy (write accepted when ~rdr_busy = state==G_READER & ~ddram_busy).
	.rdr_burstcnt (dma_mem_burstcnt),
	.rdr_addr     (dma_mem_addr[28:0]),
	.rdr_rd       (1'b0),
	.rdr_din      (dma_mem_din),
	.rdr_be       (dma_mem_be),
	.rdr_we       (dma_mem_wr),
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

// [DDR-scanout] The FPGA-side native audio (openbor_video_reader's DDR3 ring / MT32pi I2S)
// is retired with native_video. Audio in the gmloader-GPU core is owned by the HPS loader,
// not the FPGA, so the emu audio outputs are tied silent.
assign AUDIO_L = 16'd0;
assign AUDIO_R = 16'd0;
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
wire       crop_on     = status[18];  // OSD Vertical Crop (224p): 0=off, 1=on (Task 2: video_freak)
wire       osd_restart = status[19];  // OSD Restart Quest (momentary toggle); mirrored to ARM
                                       // via C_STATUS low32 bit0 (blitter_top S_WR_STATUS below)
wire       osd_fps_on  = status[20];  // OSD FPS Overlay: 0=off, 1=on; mirrored to ARM via
                                       // C_STATUS low32 bit1 (blitter_top S_WR_STATUS below)

// [320x224 crop] video_freak recomputes VGA_DE + VIDEO_ARX/ARY for a 224-line
// active window. CROP_SIZE=0 is video_freak's own "disabled" convention (the
// same pattern sonic-mania-mister uses: `status[32] ? 12'd216 : 12'd0`) — tying
// it to crop_on gates the whole feature with no separate enable port. CROP_OFF
// is tied to 0: video_freak's internal math centers the window symmetrically at
// offset 0 (8 lines blanked top and bottom of the 240-line frame -> 224 visible).
// SCALE is tied to 0 (Normal / no integer rescale) — non-goal per the design doc;
// the framework's ascal (fpga/sys/sys_top.v) does the final HDMI scale from
// whatever VIDEO_ARX/ARY this produces, same as it already does for h_pos/v_pos.
// HW-confirmed 2026-07-08: a drastic diagnostic crop (160 lines) was visibly
// obvious on real hardware, proving the video_freak/ascal auto-detect mechanism
// works end-to-end. 224 (a ~7% reduction) is subtle by comparison — a small
// zoom, not a letterbox — but is the correct, spec'd value.
wire [11:0] freak_crop_size = crop_on ? 12'd224 : 12'd0;
wire        vga_de_cropped;
wire [12:0] freak_arx, freak_ary;

video_freak video_freak
(
	.CLK_VIDEO    (CLK_VIDEO),
	.CE_PIXEL     (ce_pix_gen),
	// [DDR-scanout] nv_vs/nv_de (native_video) retired -> generic video timing (WIP; the
	// crop/aspect path is bypassed once Task 3 sets FB_EN=1 + VGA_SCALER=1).
	.VGA_VS       (VSync),
	.HDMI_WIDTH   (HDMI_WIDTH),
	.HDMI_HEIGHT  (HDMI_HEIGHT),
	.VGA_DE       (vga_de_cropped),
	.VIDEO_ARX    (freak_arx),
	.VIDEO_ARY    (freak_ary),

	.VGA_DE_IN    (~(HBlank | VBlank)),
	.ARX          (12'd4),
	.ARY          (12'd3),
	.CROP_SIZE    (freak_crop_size),
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

// --- [DDR-scanout] custom openbor scanout (native_video) RETIRED ---------------------
// openbor_video_top bundled the custom scanout reader with the FPGA-side audio ring, the
// ioctl/cart-load handshake, the joystick->DDR3 forward, and a DDR3 reader master. All of
// that is retired: scanout moves to the framework FB_EN + ascal path from a DDR framebuffer
// (wired in Task 3), and audio/input/content are owned by the HPS gmloader, not the FPGA.
// This is a WIP intermediate: there is NO scanout driver until Task 3 drives FB_EN/ascal +
// instantiates comp_fb_dma (device gate is Task 4). The analog VGA_* outputs are driven from
// the generic video timing here (they are bypassed once Task 3 sets FB_EN=1 + VGA_SCALER=1).
// The freed audio/ioctl/reader tie-offs are above; the arbiter reader slot is idled and
// repurposed for the comp_fb_dma writer in Task 3.
assign VGA_DE  = ~(HBlank | VBlank);
assign VGA_HS  = HSync;
assign VGA_VS  = VSync;
assign VGA_R   = comp_v;
assign VGA_G   = comp_v;
assign VGA_B   = comp_v;

endmodule
