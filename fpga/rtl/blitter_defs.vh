// blitter_defs.vh — REAL hardware DDR addresses for blitter_top in the Solarus
// core (qword = phys>>3). The framebuffers + video control word stay in the proven
// 1 MiB f2h region at 0x3A000000 (the blitter is a drop-in producer on the existing
// scanout buffers). The blitter COMMAND region (ctrl/ring + source-surface heap) now
// lives in a dedicated 4 MiB region at 0x3B000000 so a full SCENE TRANSITION's
// working set (two scenes co-resident, ~1 MiB) fits without overflow — the 1 MiB
// region's pre-audio gap only afforded a 352 KiB heap, too small for heavy scenes.
// 0x3B000000..0x3B400000 was HW-verified reserved-safe (64/64 pattern words survive
// Linux + engine + video/audio activity).
//
// Layout (v4 — [#52] big command ring):
//   BLTCTRL 0x3B000000 | RING 0x3B000040..0x3B080000 (512 KiB, ~16382 cmds) |
//   SRC heap 0x3B080000 | bg-cache 0x3BF00000 | end 0x3C000000
//   Ring grown from 32 KiB (1022 cmds) — 8x8-tile heavy areas emit >1022 cmds/frame.
//
// (The mister-fpga-blitter repo's sim copy uses small windowed addresses; this
//  HW copy is the source of truth for the synthesized core.)
`ifndef BLITTER_DEFS_VH
`define BLITTER_DEFS_VH

// GEOMETRY ROOT (this repo's Verilog domain). MUST equal the refmodel's
// BLT_FB_WIDTH/HEIGHT — enforced by fpga/sim/gen_tri_golden.mk contract-check.
`define FB_W        288
`define FB_H        216
// Derived — never retype a dimension (native-288x216 single-source rule).
`define FB_QWORDS   (`FB_W * `FB_H / 4)   // 15552 (2 B/px, 8 B/qword)
`define FB_PIXELS   (`FB_W * `FB_H)       // 62208
`define FB_STRIDE_QW (`FB_W / 4)          // 72 qwords per framebuffer row

`define FB0_QW      29'h07400008          // 0x3A000040 (BUF0, existing)
`define FB1_QW      29'h07408008          // 0x3A040040 (BUF1, existing)
`define VCTRL_QW    29'h07400000          // 0x3A000000 (video control word)
`define BLTCTRL_QW  29'h07600000          // 0x3B000000 (blitter control block)
// [Phase 1 A3] DOUBLE-BUFFERED command ring. The 512 KiB region is split into two
// 256 KiB rings so the host can build frame N+1 while the fabric reads N. Selected by
// C_SRCSEL bit 2 (see C_RINGSEL_BIT below).
//
// CROSS-REPO ABI — these four values must match gmloader-next exactly. A mismatch is
// invisible to BOTH sides' test suites (each is internally consistent; only the pairing
// is wrong) and shows up only as the fabric reading a ring the host never wrote:
//   ring A base 0x3B000040, ring B base 0x3B040000, selector = C_SRCSEL bit 2,
//   SRC_QW unmoved at 0x3B080000.
//
// Capacity, derived from these addresses rather than asserted (commands are 4 qwords
// = 32 B): ring A spans 0x3B040000-0x3B000040 = 0x3FFC0 B = 8190 cmds; ring B spans
// 0x3B080000-0x3B040000 = 0x40000 B = 8192 cmds. Down from ~16382 for the single ring.
// The overflow that forced the original 32 KiB -> 512 KiB growth was >1022 cmds in
// Solarus tile-heavy areas, so this keeps ~8x headroom. The host logs a cmd_count
// high-water mark so an approach to the cap is visible rather than silent.
//
// SRC_QW is deliberately NOT moved — see the must-match-across-repos note on it below.
`define RING_QW     29'h07600008          // 0x3B000040 (ring A, 256 KiB)
`define RING_B_QW   29'h07608000          // 0x3B040000 (ring B, 256 KiB)
`define SRC_QW      29'h07610000          // 0x3B080000 ([#52] heap base moved up 480 KiB to grow the
                                          // command ring 32 KiB->512 KiB: 8x8-tile heavy areas emit
                                          // >1022 cmds/frame and overflowed the old ring -> black.
                                          // MUST MATCH host OFF_HEAP=0x80000 in mister_blitter_renderer.cpp)
`define MEM_QW      29'h07800000          // 0x3C000000 (region end; sim guard only —
                                          // engine heap grown to 16 MiB, issue #14)
// Off-screen BG-CACHE compose target (issue #18 anti-flicker): C_TARGET==2 routes the
// blit destination here instead of a framebuffer, and the fabric does NOT flip the
// display for that pass — so the static-bg cache is composed OFF-SCREEN (invisible),
// and every DISPLAYED frame stays a consistent full frame (cache->fb + dynamic),
// never a static-only snapshot. 0x3BF00000 = near the top of the 16 MiB region, clear
// of the bump heap (grows from 0x3B008000). Also the SRC for the cache->fb blit.
`define CACHE_QW    29'h077E0000          // 0x3BF00000 (off-screen bg-cache, 288x216)

// control-block field offsets (qwords from BLTCTRL_QW), low 32 bits used
`define C_SUBMIT    29'd0
`define C_CMDCOUNT  29'd1
`define C_TARGET    29'd2
`define C_CLEAR     29'd3
`define C_FLAGS     29'd4
`define C_DONE      29'd5
`define C_STATUS    29'd6
// Source-read path select (issue #19). bit0=1 -> route blitter SOURCE pixel reads
// through the SDRAM line controller (sdram_src_arb -> sdram_psx); 0 (DEFAULT) ->
// the proven DDR3 readcache path. Only the source read moves; control-word reads,
// the command ring, blend dst-RMW reads, ALL writes and scanout stay on DDR3.
// NOTE: 7 is the next free offset (C_STATUS=6 is the last existing field). This is
// a NEW field appended past C_STATUS — it does NOT alias any shipping control word,
// and the host writes it 0 by default so the DDR3 path is unchanged when unset.
`define C_SRCSEL    29'd7
// Pipelined-compositor select (Spec A). Routes FILL/BLIT execution through
// comp_pipeline (per-blit, band-chunked RMW datapath) when set; 0 (DEFAULT) ->
// the legacy per-pixel FSM.
//
// IMPORTANT (memory-map correction): the command RING begins at RING_QW =
// BLTCTRL_QW + 8 (0x3B000040), so control-block qword offset 8 ALIASES the first
// ring command word — `C_PIPE = 29'd8` would read cmd0's opcode (bit0=1 for any
// BLIT) and spuriously force the pipe path on. The last free control-block qword
// before the ring is C_SRCSEL (offset 7). C_PIPE is therefore carried in a SPARE
// BIT of the C_SRCSEL control word: bit0 is srcsel, bits[15:8] are the throttle,
// and BIT 1 is the pipe-select. C_PIPE names that word; pipe_en = word[1].
`define C_PIPE      29'd7        // same word as C_SRCSEL; pipe_en = word bit 1
`define C_PIPE_BIT  1            // bit within the C_PIPE word that enables the pipe
// [Phase 1 A3] Ring select, carried in a SPARE BIT of the C_SRCSEL word for the same
// reason C_PIPE is: control-block offset 8 aliases ring command 0, so there is no free
// qword. Bit 0 (srcsel) and bit 1 (pipe) are both dead — the source read is hardwired
// to SDRAM (blitter_top.sv: `wire src_in_sdram = 1'b1;`) and comp_pipeline is the sole
// renderer — so bit 2 is unambiguous. Bits [15:8] are the LIVE f2h write-throttle and
// must be preserved by anything writing this word.
//   word bit 2 == 0 -> RING_QW (ring A);  == 1 -> RING_B_QW (ring B).
`define C_RINGSEL_BIT 2

// ── [v2 escape-elim] command-ABI mirror (values FROZEN in blitter_ref.h) ────────
// blend_mode (cmd byte 1) extends past PALPHA=3; F_COLORMOD is the next free flag.
// blitter_top.sv / comp_pipeline.sv keep these as module localparams (decode style);
// these `defines exist so the ABI values live in one shared header too.
`define BLT_BLEND_COPY        8'd0
`define BLT_BLEND_COLORKEY    8'd1
`define BLT_BLEND_CONST_ALPHA 8'd2
`define BLT_BLEND_PALPHA      8'd3
`define BLT_BLEND_ADD         8'd4   // saturating add: out = min(src+dst, chan_max)
`define BLT_BLEND_MULTIPLY    8'd5   // multiply:       out = round(src*dst / chan_max)
// ── [TRILIST v1] textured-triangle opcode (Task 5). opcodes 5-9 were removed in
// Task 2; 10 is free and matches the host ABI (blitter_ref.h BLT_OP_TRILIST).
`define OP_TRILIST            8'd10
`define BLT_F_COLORMOD        8'h40  // _pad bytes carry RGB888 src tint (cr,cg,cb)
// ── [app-surface v1] render-target select (step-1 plan Tasks 2/6). BLT_OP_SET_TARGET
// binds the composite destination among named surfaces; the target id rides the
// command's color low byte (cmd_qw[3][47:32], same field FILL uses for its color).
// opcodes 0-7 and 10 are taken in blitter_ref.h; 11 is the chosen free value.
// (These MUST match the host emitter + blitter_ref.h — locked protocol constants.)
`define OP_SET_TARGET         8'd11
`define BLT_TARGET_WORK       2'd0   // composite into the WORK framebuffer (default; scanned)
`define BLT_TARGET_APPSURF    2'd2   // composite into the off-screen app-surface (never scanned)
// [app-surface v1] TRILIST texel-source select (Task 7): when set, the triangle
// samples texels from the APPSURF render-target surface instead of the SDRAM heap.
// RESOLVED to 0x80 (lead correction 2026-07-17): the plan's original 0x40 collided
// with BLT_F_COLORMOD=0x40 (taken in blitter_ref.h:138 and blitter_top.sv); 0x80 is
// the only free flag bit. The RTL decode + golden mirror land in Task 7 (gated on the
// engine team's reference-model Task 3); Task 6 does not read this flag.
`define BLT_F_SRC_SURFACE     8'h80
// ── [PAL8 v1] source-format constants (mirror blitter_ref.h) ─────────────────────
`define BLT_FMT_RGB565        8'd0
`define BLT_FMT_ARGB4444      8'd1
`define BLT_FMT_PAL8          8'd2   // 8bpp palette-indexed; CLUT lookup by pal_id
// Wire layout of the tint triple in command qword[3] (host pack / RTL decode / C
// model MUST agree): u32[6]=colorkey|alpha<<16|cb<<24, u32[7]=color|cr<<16|cg<<24.

`endif
