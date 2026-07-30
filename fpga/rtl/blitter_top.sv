// VENDORED from github.com/gmcnaught/mister-fpga-blitter (rtl/blitter_top.sv)
// HW addresses come from blitter_defs.vh (this dir). Do not edit here; edit upstream + re-copy.
//============================================================================
//  blitter_top.sv — MiSTer fabric 2D blitter: functional spike (#003)
//
//  Walks a DDR command ring (until END / cmd_count), composites into a
//  framebuffer in DDR per the host<->fabric contract (docs/blitter-protocol.md),
//  then writes the video control word as a DROP-IN PRODUCER for the existing
//  scanout reader. Verified bit-exact in simulation against the C reference
//  model (refmodel/blitter_ref.c) over the full v1 command set.
//
//  SCOPE NOTE: this spike uses a single Avalon-MM master with simple per-pixel
//  reads/writes (byte-enable lane writes) — deliberately FUNCTIONAL, not yet
//  bandwidth-optimal. The on-chip line/tile buffer + burst-DMA refinement (the
//  CV1000 pattern, see docs/) is the #004/#005 perf work and does not change
//  these command/handshake/pixel semantics.
//
//  Command word on-wire layout (32 bytes = 4 qwords, little-endian):
//    u32[0] = opcode[7:0] | blend[15:8] | format[23:16] | flags[31:24]
//    u32[1] = src_off[31:0]
//    u32[2] = src_stride[15:0] | src_x[31:16]
//    u32[3] = w[15:0] | h[31:16]
//    u32[4] = src_y[15:0] | resv
//    u32[5] = dst_x[15:0] | dst_y[31:16]   (signed16)
//    u32[6] = colorkey[15:0] | alpha[23:16] | priority[31:24]
//    u32[7] = color[15:0] | resv
//    qw_k = {u32[2k+1], u32[2k]}
//
//  Copyright (C) 2026 — GPL-3.0
//============================================================================
`default_nettype none
`include "blitter_defs.vh"
`include "comp_clut.vh"

module blitter_top #(
    parameter AW = 32,
    // [startup-wedge fix] S_RD_WAIT reissue watchdog window. MUST stay > the
    // arbiter's FLUSH_QUIET_MAX (2^20 cyc) — see the S_RD_WAIT comment for the
    // ordering proof. Parameter so the sim can exercise the reissue without
    // multi-million-cycle waits (same pattern as ddr_blitter_arb FLUSH_QUIET_MAX).
    parameter [21:0] RW_WD_MAX = 22'h3FFFFF   // 2^22-1 cyc ~42.6ms @98.4375MHz
) (
    input  wire          clk,
    input  wire          rst,
    input  wire          vs,          // scanout vblank (synced) — gates the work->scan snapshot
    // [OSD mirror] raw status[] levels sampled once per frame (S_WR_STATUS) into
    // C_STATUS low32 bits[1:0] — this reuses the control block's dead low32 (it
    // was always written 0 and never read by the ARM side) instead of adding a
    // new register/offset. See docs/superpowers/specs/2026-07-07-osd-driven-
    // features-design.md for why a new register was the original sketch.
    input  wire          osd_restart, // status[19]: Restart Quest (momentary toggle)
    input  wire          osd_fps_on,  // status[20]: FPS Overlay on/off
    // Avalon-MM-ish master to shared DDR (qword addressed). Driven by an OWNER
    // MUX (see bottom of module): the FSM drives them via its bm_* regs for ring/
    // clear/STAGE/status traffic; while a render runs, comp_pipeline drives them.
    output wire [AW-1:0] mem_addr,
    output wire          mem_rd,
    output wire          mem_wr,
    output wire [7:0]    mem_burstcnt,   // burst beats while comp_pipeline owns the bus; 8'd1 for FSM traffic
    output wire [63:0]   mem_din,
    output wire [7:0]    mem_be,
    input  wire [63:0]   mem_dout,
    input  wire          mem_dout_ready,
    input  wire          mem_busy,    // reserved (sim model never busy)
    // ---- P_SRC cache-ok channel (Task 5 controller pivot) ----------------------
    // SOURCE pixel reads now use the sdram_fb_cache P_SRC channel (read-only).
    // Protocol: pulse p0_rd with p0_addr for one cycle; capture p0_dout on p0_ok.
    // No busy/backpressure: the cache-ok channel is always ready to accept a read
    // and returns data (p0_ok=1 with p0_dout) after a fixed cache-hit latency.
    // comp_pipeline (u_pipe) is the sole renderer and drives these ports directly
    // (see bottom); they are idle (p0_rd=0) outside a source fetch.
    output wire [26:0]   p0_addr,          // byte address (qword-aligned) of the source beat
    output wire          p0_rd,            // one-cycle read pulse (cache-ok: no hold needed)
    input  wire [63:0]   p0_dout,          // 64-bit read data (valid when p0_ok asserts)
    input  wire          p0_ok,            // per-beat valid strobe from the cache channel
    // ---- on-chip framebuffer (comp_fbram) dest port [FB-in-BRAM] ----------------
    // comp_pipeline's composite destination now lives in on-chip M10K (comp_fbram),
    // wired up at the integration layer (Solarus.sv). u_pipe drives these directly.
    // (Threaded out in Task 1; the mixer is routed through them at the Task 2 cutover.)
    output wire          fb_wr_en,
    output wire [14:0]   fb_wr_qw,
    output wire [1:0]    fb_wr_lane,
    output wire [15:0]   fb_wr_pix,
    output wire          fb_rd_en,        // comp_pipeline RMW read of the WORK framebuffer
    output wire [14:0]   fb_rd_qw,
    input  wire [63:0]   fb_rd_qword,
    // ---- vblank WORK->DDR framebuffer-DMA handshake [DDR-scanout] ----------------------
    // The SCAN buffer + WORK->SCAN snapshot are retired: scanout now reads a DDR3
    // framebuffer written by the external comp_fb_dma. Once per frame — as soon as the frame
    // completes, NOT at vblank (that wait was deleted in Phase 1 A1) — the
    // S_SNAP_* FSM pulses fb_dma_start and waits on fb_dma_busy for comp_fb_dma to copy the
    // completed WORK buffer out to DDR (which the framework's ascal then scans). The WORK
    // read during the copy is comp_fb_dma's own port, muxed onto comp_fbram at the emu top.
    output reg           fb_dma_start,    // 1-cyc pulse: kick the WORK->DDR framebuffer copy
    input  wire          fb_dma_busy,     // comp_fb_dma is mid-copy (WORK held stable meanwhile)
    // ---- off-screen APP-SURFACE render-target port to comp_fbram (app-surface v1) ----
    // When BLT_OP_SET_TARGET binds APPSURF, the composite write/read is routed to this
    // independent off-screen surface instead of the WORK banks. The surface is never
    // scanned (no scan/snapshot). Task 7 adds a texel read of it via surf_rd_*.
    output wire          surf_wr_en,
    output wire [14:0]   surf_wr_qw,
    output wire [1:0]    surf_wr_lane,
    output wire [15:0]   surf_wr_pix,
    output wire          surf_rd_en,
    output wire [14:0]   surf_rd_qw,
    input  wire [63:0]   surf_rd_qword,
    // ---- SDRAM STAGE WRITE path (issue #19, BLT_OP_STAGE) ----------------------
    // A BLT_OP_STAGE command copies a source region from DDR3 (SRC_QW + off) into
    // SDRAM at the heap-relative byte offset `off` (exactly the address the SDRAM
    // source read uses). These single-16-bit-word write outputs route through the
    // cache STAGE channel (ch1). They are IDLE (we=0) outside staging.
    output reg           src_sdram_we,     // request one 16-bit word write (held until granted)
    output reg  [15:0]   src_sdram_din,    // the word to write
    // [gmloader-GPU slim] the 3 burst-write outputs are driven by the OP_STAGE
    // atlas FSM's stage_*_fsm regs via a continuous assign (see near the bottom
    // of this file); they were `wire` rather than FSM-driven `reg` to support a
    // now-retired priority mux with the OP_BGPLANE_WRITE bake stream.
    output wire [26:0]   src_sdram_waddr,  // byte address (bit0=0, 16-bit mode) of the word
    // ---- BL=4 BURST staging write (issue #19) ----
    // One 64-bit DDR3 beat -> ONE SDRAM burst write (4 words) instead of 4 single
    // writes. src_sdram_waddr carries the 8-byte-aligned beat byte address.
    output wire          src_sdram_we_burst, // request one 4-word burst write (held until granted)
    output wire [63:0]   src_sdram_din64,    // the 64-bit beat to burst-write
    input  wire          src_sdram_ok,       // [#44] cache-ok: STAGE burst write accepted (hold we_burst until this)
    // ---- intra-frame STAGE->P_SRC coherency barrier ---------------------------
    // After a STAGE command finishes copying its atlas into SDRAM cache ch1, the
    // dirty ch1 lines are NOT yet in SDRAM and ch5 (P_SRC) may hold STALE lines for
    // the same addresses. The engine consumes a freshly-staged surface in the SAME
    // frame (STAGE then BLIT in one command ring), so we cannot wait for vsync to
    // flush. On STAGE completion we pulse stage_barrier and HOLD the FSM until
    // stage_barrier_busy clears (ch1 committed + ch5 invalidated) before processing
    // the next command — guaranteeing the consuming BLIT's P_SRC fetch is coherent.
    output reg           stage_barrier,       // one-cycle request: commit ch1 + invalidate ch5
    input  wire          stage_barrier_busy,  // high while the barrier flush/invalidate runs
    // [retired 2026-06-26] The ch0->P_SRC carry-forward coherency barrier (dst_barrier)
    // is gone: FB-in-BRAM composites into the on-chip comp_fbram, so the engine no longer
    // emits the F_SRC_FB SDRAM FB->FB carry-forward copy (single_buf full-redraw) and ch0
    // (P_DST) is never written. The stage_barrier (ch1 STAGE atlas -> ch5 P_SRC) stays.
    output reg           idle,
    // ---- DEBUG snapshot (issue #34 HW wedge probe) -----------------------------
    // Continuously-driven live state for HW post-mortem: published by the scanout
    // reader into VSYNC_ADDR's HIGH 32 bits (0x3A070004) each frame — the reader
    // stays alive when the blitter wedges, so devmem 0x3A070004 reveals WHERE the
    // blitter is stuck. dbg[5:0]=state, [22:15]=0, [14:6]=0 (legacy dx/dy retired with
    // the per-pixel renderer), [23]=rd_issued, [31:24]=stuck-count (cycles-in-state >>
    // 16, saturates 0xFF = frozen). No effect on the datapath.
    output wire [31:0]   dbg
);
    localparam [5:0]
        S_POLL_SUBMIT=6'd0, S_POLL_DONE=6'd1, S_CHK_NEW=6'd2,
        S_GOT_CMDCNT=6'd3,  S_GOT_TARGET=6'd4, S_GOT_FLAGS=6'd5, S_GOT_CLEAR=6'd6,
        S_CLR_WR=6'd7,      S_FETCH=6'd8,  S_COLLECT=6'd9, S_DECODE=6'd10,
        S_SETUP=6'd11,      S_NEXT_CMD=6'd19,
        // [FB-in-BRAM] CLEAR routes through comp_pipeline as a full-screen FILL
        S_CLR_FILL=6'd12,   S_CLR_FILL_WAIT=6'd13,
        S_FRAME_VCTRL=6'd20, S_WR_DONE=6'd21, S_WR_STATUS=6'd22,
        S_RD_WAIT=6'd23,    S_WR_WAIT=6'd24,
        S_WR_PERF=6'd25,    // [profiling] publish perf_tri_cyc to C_SRCSEL.hi (spare qw7 high)
        S_GOT_SRCSEL=6'd30, // control-fetch: latch C_SRCSEL after C_FLAGS
        S_WR_COVPX=6'd31,   // [Phase 1 A4] publish perf_covered_px to C_FLAGS.hi
        // ---- BLT_OP_STAGE DDR3->SDRAM copy FSM (issue #19) ----
        S_STAGE_RD=6'd32,     // issue the DDR3 read of beat i (SRC_QW + off + i*8)
        S_STAGE_GOT=6'd33,    // capture the beat; begin writing its 4 words to SDRAM
        S_STAGE_WR=6'd34,     // issue one 16-bit SDRAM word write
        S_STAGE_WR_WAIT=6'd35,// hold the SDRAM write until the arbiter accepts it
        S_WR_THROTTLE=6'd36,  // [#34] idle WR_THROTTLE cycles after a write (scanout bandwidth)
        S_PIPE_WAIT=6'd37,    // FILL/BLIT handed to comp_pipeline; await blit_done
        // ---- intra-frame STAGE->P_SRC coherency barrier (commit ch1 + inval ch5) ----
        S_STAGE_BARRIER=6'd38,     // pulse stage_barrier after a STAGE completes
        S_STAGE_BARRIER_WAIT=6'd39,// HOLD until the barrier flush/invalidate completes
        // (6'd40/6'd41 retired with the dst_barrier carry-forward barrier)
        // ---- work->scan snapshot [FB-in-BRAM double-buffer] -------------------------
        S_SNAP_WAIT=6'd42,         // frame composited: wait for vblank rising, then trigger
        S_SNAP_BUSY=6'd43,         // snapshot started: wait for busy to assert
        S_SNAP_DRAIN=6'd44,        // wait for the work->scan copy to finish, then poll submit
        // ---- BLT_OP_TRILIST textured-triangle rasterizer (Task 5) -------------------
        S_TRI_VFETCH=6'd45,        // issue the DDR read of vertex qword 0 for this triangle
        S_TRI_VCOLLECT=6'd46,      // collect the 6 vertex qwords (3 verts x 2 qw)
        S_TRI_DECV=6'd47,          // unpack qwords -> the 3 vertices (x,y,u,v,rgba)
        S_TRI_SETUP=6'd48,         // pulse blt_tri_setup.start
        S_TRI_SWAIT=6'd49,         // wait for setup valid; seed bbox + accumulators
        S_TRI_PIX=6'd50,           // evaluate coverage; if covered, register the W*area_recip products
        S_TRI_GOTTEX=6'd51,        // wait p0_ok; latch texel; (maybe) issue comp_fbram dst read
        S_TRI_DSTW=6'd52,          // comp_fbram read latency cycle
        S_TRI_DSTC=6'd53,          // capture dst lane
        S_TRI_WR=6'd54,            // drive blt_blend; write comp_fbram on write_en
        S_TRI_ADV=6'd55,          // step w*/attributes by per-x deltas, wrap rows by per-row deltas
        S_TRI_NEXT=6'd56,         // triangle done: next triangle or finish the command
        S_TRI_MUL=6'd57,          // round the W*recip products, clamp texel, issue P_SRC read
        // [pipeline] per-pixel blend/write path staged like comp_mixer (LAT=3) for
        // timing closure: the old single-cycle S_TRI_WR (tint+alpha-combine+MAC+/255+
        // pack) is split into three register stages A/B/C.
        S_TRI_WR2=6'd58,          // stage B: per-channel MAC/add/mul intermediate
        S_TRI_WR3=6'd59,          // stage C: /255,/31,/63 reduce + RGB565 pack + fb write
        S_TRI_ADDR=6'd60,         // registered texel-row multiply (itv*stride)
        S_TRI_MUL0=6'd61,         // W*area_recip partial products (operands latched in S_TRI_PIX)
        S_TRI_ADDR2=6'd62,        // texel byte address add + P_SRC read (split from S_TRI_ADDR)
        S_TRI_MUL1=6'd63;         // sum the W*area_recip partial products -> mul_*

    localparam [7:0] OP_NOP=8'd0, OP_END=8'd1, OP_FILL=8'd2, OP_BLIT=8'd3, OP_STAGE=8'd4,
                     OP_TRILIST=8'd10,
                     OP_SET_TARGET=`OP_SET_TARGET;   // [app-surface v1] bind composite target
    // [v2 escape-elim] blend_mode now spans 0..5 (ADD=4, MULTIPLY=5). The decode just
    // forwards c_blend to comp_pipeline, which maps it onto comp_mixer modes.
    localparam [7:0] BLEND_KEY=8'd1, BLEND_ALPHA=8'd2, BLEND_PALPHA=8'd3,
                     BLEND_ADD=8'd4, BLEND_MULTIPLY=8'd5;
    localparam [7:0] F_HFLIP=8'h01, F_VFLIP=8'h02, F_COLORKEY=8'h04, F_STAGE_DST=8'h08,
                     F_SRC_SDRAM=8'h10,  // [#34] per-command source mux: this BLIT reads SDRAM
                     F_SRC_FB=8'h20,     // [retired] was the carry-forward FB->FB copy flag;
                                         // no longer emitted (FB-in-BRAM), now a no-op. Kept in
                                         // the protocol constants for ring-format compatibility.
                     F_COLORMOD=8'h40,   // [v2 escape-elim] _pad bytes carry an RGB888 tint
                                         // (cr,cg,cb) modulating the SOURCE before the blend.
                     F_SRC_SURFACE=`BLT_F_SRC_SURFACE; // [app-surface v1] TRILIST: sample the
                                         // off-screen APPSURF render target as this draw's texel
                                         // source instead of the SDRAM heap (0x80).
    // Source pixel formats (cmd.format). Both are 16bpp: RGB565 and ARGB4444
    // ({A4,R4,G4,B4}); BLEND_PALPHA just reinterprets the fetched 16-bit source
    // pixel. comp_pipeline owns the source addressing/fetch now.
    localparam [7:0] FMT_RGB565=8'd0, FMT_ARGB4444=8'd1;

    reg  [5:0]  state, rd_ret, wr_ret;
    reg         rd_issued;   // read accepted by the bus, now awaiting dout_ready
    // [startup-wedge fix] S_RD_WAIT reissue watchdog (window = RW_WD_MAX param).
    reg  [21:0] rw_wd;           // cycles spent in S_RD_WAIT since entry/reissue
    reg  [7:0]  rd_reissue_cnt;  // saturating diagnostic: reissues since reset
    // ---- legacy-FSM master signals (muxed onto mem_* at the bottom) ----
    reg  [AW-1:0] bm_addr;
    reg           bm_rd, bm_wr;
    reg  [63:0]   bm_din;
    reg  [7:0]    bm_be;
    // ---- comp_pipeline (Spec A) routing — the sole render datapath ----
    reg           pipe_start;    // 1-cycle blit_start pulse to comp_pipeline
    reg           pipe_busy;     // 1 while a comp_pipeline blit owns the mem_* bus
    reg           pipe_busy_q;   // [#44 timing] lockstep duplicate of pipe_busy for the owner-mux select (low fanout)
    // ---- work->scan snapshot routing [FB-in-BRAM double-buffer] ----
    wire          pipe_fb_rd_en; wire [14:0] pipe_fb_rd_qw;  // comp_pipeline's work-read (pre-mux)
    // comp_pipeline's composite-write outputs (pre-mux); muxed with tri_fb_wr_* below.
    wire          pipe_fb_wr_en; wire [14:0] pipe_fb_wr_qw; wire [1:0] pipe_fb_wr_lane; wire [15:0] pipe_fb_wr_pix;
    // [app-surface v1] composite RMW-read result seen by the renderer: the off-screen
    // surface when compositing APPSURF, else the WORK framebuffer. Assigned in the
    // target-routing mux at the bottom; fed to comp_pipeline + the TRILIST dst read.
    wire [63:0]   comp_rd_qword;
    // fb_dma_start (the vblank WORK->DDR trigger) is a top-level output reg, driven by the
    // S_SNAP_* FSM below (declared in the port list); fb_dma_busy is its return handshake.
    // [#104] Synchronize vs (scanout vblank; may cross from the video clock) through a
    // 3-FF chain BEFORE the rising-edge detect, detecting between the two RESOLVED stages
    // ([2]&[1]). The old single vs_q edge-detected a still-async vs -> a metastable sample
    // could mis-time the WORK->SCAN snapshot trigger (S_SNAP_WAIT). +1-2 clk latency is
    // negligible for a per-frame vblank.
    reg   [2:0]   vs_sync;
    // [DDR-scanout] S_SNAP_BUSY guard: bounded wait for comp_fb_dma to acknowledge fb_dma_start.
    // The real comp_fb_dma raises fb_dma_busy at start+1 (guard reaches 1). If NO DMA engine
    // responds — sim benches with no comp_fb_dma, or the Task-2 WIP core where fb_dma_busy is
    // tied idle — the FSM proceeds after SNAP_GUARD cycles instead of wedging. Purely a
    // no-DMA fallback; invisible whenever a DMA engine is present.
    localparam [5:0] SNAP_GUARD = 6'd32;
    // Framebuffer row stride in qwords, explicitly 16-bit so the row multiplies
    // below stay single 16x16 DSPs (timing-closed pipeline — do not widen).
    localparam [15:0] FB_STRIDE_QW16 = `FB_STRIDE_QW;
    reg   [5:0]   snap_guard;
    // [Phase 1 A1] vs_rise now has NO consumer: S_SNAP_WAIT was its sole user and no longer
    // gates on it. The vs input, the vs_sync chain and this edge-detect are RETAINED
    // deliberately — dropping them would change blitter_top's port list and every
    // instantiation (emu top + benches) for no functional gain, and synthesis strips the
    // unused logic anyway. Kept so a future task can re-derive frame timing if needed.
    wire          vs_rise = ~vs_sync[2] & vs_sync[1];
    always @(posedge clk or posedge rst) begin
        if (rst) vs_sync <= 3'b0;
        else     vs_sync <= {vs_sync[1:0], vs};
    end
    // comp_pipeline master outputs + done (instantiated at the bottom)
    wire [31:0]   p_mem_addr;
    wire          p_mem_rd, p_mem_wr;
    wire  [7:0]   p_mem_burstcnt;
    wire [63:0]   p_mem_din;
    wire  [7:0]   p_mem_be;
    wire          p_blit_done;
    // comp_pipeline is the only consumer of the read-only SDRAM source port.
    wire [26:0]   p_src_sdram_addr;
    wire          p_src_sdram_rd;
    reg  [7:0]  throttle_cnt;// [#34] f2h write-throttle countdown (S_WR_THROTTLE)
    // [#34] RUNTIME f2h write-throttle: idle cycles after each accepted f2h write before
    // the next bus transaction. Latched from C_SRCSEL[15:8] each frame (spare bits; the
    // engine publishes it from SOLARUS_BLT_THROTTLE) so the value is HW-tunable without a
    // rebuild. Re-introduces the pacing the DDR3 path got "for free" from interleaved f2h
    // source reads (moving reads to SDRAM un-throttled the blitter -> write storm ->
    // ddram_busy -> scanout FIFO underflow -> rolling image). jtframe lfbuf discipline:
    // the writer must not steal the display's bus window. 0 = no throttle.
    reg  [7:0]  throttle_cfg;
    // [Phase 1 A3] Command-ring select. 0 -> `RING_QW (ring A), 1 -> `RING_B_QW (ring B).
    // Latched once per frame from C_SRCSEL bit 2 in the control-block prologue, so a frame
    // can never straddle two rings. See blitter_defs.vh C_RINGSEL_BIT for the ABI note.
    reg         ring_sel;
    wire [28:0] ring_base = ring_sel ? `RING_B_QW : `RING_QW;
    reg  [63:0] rd_data;

    reg  [31:0] submit_reg, done_reg, cmd_count, cmd_idx, frame_counter;
    // ── per-frame perf counters (HW attribution: A9 vs fabric) ──────────────────
    // perf_frame_cyc counts clk_sys cycles the fabric is busy on a frame (from the
    // submit/done mismatch that starts it, through the done write-back); perf_pipe_cyc
    // counts the subset where comp_pipeline owns the bus (pipe_busy). Both reset at
    // frame start and are published in the HIGH 32 bits of the C_DONE / C_STATUS
    // control qwords (the low 32 hold done_seq / status; high 32 were unused). The A9
    // reads them via devmem at C_DONE+4 / C_STATUS+4. fabric_busy/pipe_busy vs the
    // vsync interval (0x3A070000) tells you whether the A9 or the fabric is the limit.
    reg  [31:0] perf_frame_cyc, perf_pipe_cyc;
    // [profiling] TRILIST per-state attribution to locate the ~46 cyc/px cost:
    //   perf_tri_cyc     = cycles in any S_TRI_* state (published to C_SRCSEL.hi)
    //   perf_texwait_cyc = cycles blocked in S_TRI_GOTTEX waiting on p0_ok (texel
    //                      fetch) — published to C_STATUS.hi (replaces perf_pipe_cyc,
    //                      whose value is already known ~2.45ms). frame - tri = ring/
    //                      clear/setup overhead; tri - texwait = rasterizer datapath.
    reg  [31:0] perf_tri_cyc, perf_texwait_cyc;
    // [Phase 1 A4] EXACT covered-pixel count, replacing the host's cov_px_est (a
    // Sutherland-Hodgman clip estimate, blind to per-pixel rejection). It is the
    // DENOMINATOR of cyc/px — the metric the datapath lever is judged on — so it must not
    // itself be an estimate: Phase 0's ~1.2x measured-vs-sim residual could not be settled
    // while the denominator was approximate.
    // Incremented once per pixel DISPATCHED from A_PIX, which is where coverage is
    // actually decided (the edge-function test), not at retire.
    reg  [31:0] perf_covered_px;
    reg  [1:0]  target_buf;   // 0/1 = framebuffer; 2 = off-screen bg-cache (no flip)
    // [app-surface v1] Active COMPOSITE render target, bound by BLT_OP_SET_TARGET mid-ring.
    // DECOUPLED from target_buf on purpose: target_buf is the DISPLAY double-buffer / flip
    // selector (drives vctrl_val's flip bit) and must not be perturbed by a mid-ring target
    // bind. comp_target only steers the composite write/read mux (WORK vs off-screen surface)
    // and is reset to WORK at every frame start, so a frame that never emits SET_TARGET is
    // byte-identical to today. Values: BLT_TARGET_WORK / BLT_TARGET_APPSURF.
    reg  [1:0]  comp_target;
    wire        appsurf_active = (comp_target == `BLT_TARGET_APPSURF);
    // [collapse-single-source] The per-blit source read is ALWAYS from SDRAM now
    // (single source pipeline). The old C_SRCSEL bit0 (DDR3-vs-SDRAM source mux,
    // `srcsel`) and the DDR3 live-source datapath were removed; the C_SRCSEL control
    // word is still read but ONLY for its throttle field (bits[15:8]).
    reg  [31:0] target_base, cfg_flags, clr_idx;
    reg  [15:0] clear_color;
    reg  [63:0] cmd_qw [0:3];
    reg  [1:0]  fetch_k;

    reg  [7:0]  c_opcode, c_blend, c_format, c_flags, c_alpha;
    reg  [31:0] c_src_off;
    reg  [15:0] c_src_stride, c_src_x, c_src_y, c_w, c_h, c_colorkey, c_color;
    reg  signed [15:0] c_dst_x, c_dst_y;
    // [v2 escape-elim] color-mod (tint) bytes, valid when c_flags & F_COLORMOD.
    reg  [7:0]  c_cmod_r, c_cmod_g, c_cmod_b;

    // ---- DEBUG: live state snapshot for the #34 HW wedge probe (no datapath effect)
    reg  [5:0]  dbg_state_q;
    reg  [23:0] dbg_stuck;            // cycles since `state` last changed (saturating)
    always @(posedge clk) begin
        if (rst) begin dbg_state_q <= 6'd0; dbg_stuck <= 24'd0; end
        else begin
            dbg_state_q <= state;
            if (state != dbg_state_q) dbg_stuck <= 24'd0;
            else if (~&dbg_stuck)     dbg_stuck <= dbg_stuck + 24'd1;
        end
    end
    // [31:24]=stuck>>16 (0xFF=frozen >~167ms), [23]=rd_issued (read accepted, waiting
    // for data = NOT starved), [5:0]=state. The legacy dx/dy fields are retired with
    // the per-pixel renderer; comp_pipeline owns per-pixel progress now, so those
    // bits are zeroed (state+stuck+rd_issued remain the HW wedge post-mortem signal).
    // [startup-wedge fix] bits[22:15] now carry rd_reissue_cnt (reissue watchdog
    // fires since reset) — 0 in a clean run, >0 means a lost f2h beat was healed.
    assign dbg = {dbg_stuck[23:16], rd_issued, rd_reissue_cnt, 9'd0, state};
    // [wedge probe v2] declared/defined AFTER the tri sub-FSM regs (pa/pb/fill_busy/tri_maxx/y),
    // since `default_nettype none` forbids forward references — see the block below ~L590.

    // ---- OSD Restart Quest: sticky pulse latch ----------------------------------
    // status[19] (T[19] CONF_STR type) is a MOMENTARY TRIGGER: Main_MiSTer pulses it
    // briefly then clears it — it is not held as a persistent level. S_WR_STATUS only
    // samples once per composited frame (~60Hz), far slower than the pulse width, so a
    // raw level read (the original implementation) essentially never catches it. This
    // latch runs every clk_sys cycle (~98MHz) so it cannot miss the pulse, and holds
    // the pending flag until S_WR_STATUS consumes (and clears) it — guaranteeing the
    // ARM side sees exactly one clean rising edge per OSD activation.
    reg osd_restart_pending;
    reg osd_restart_prev;
    always @(posedge clk) begin
        if (rst) begin
            osd_restart_pending <= 1'b0;
            osd_restart_prev    <= 1'b0;
        end else begin
            osd_restart_prev <= osd_restart;
            if (osd_restart && !osd_restart_prev)
                osd_restart_pending <= 1'b1;
            else if (state == S_WR_STATUS)
                osd_restart_pending <= 1'b0;
        end
    end

    // ---- BLT_OP_STAGE copy state (issue #19) ----
    // size = {c_h, c_w} (w=size[15:0], h=size[31:16]); copy `stage_size` bytes from
    // DDR3 SRC_QW+off into SDRAM[off..]. stage_byte = bytes already copied (multiple
    // of 8 = whole beats); stage_beat holds the current DDR3 beat being drained word
    // by word (stage_wj = 0..3).
    reg  [31:0] stage_off;     // DDR3 read (heap/bounce) byte offset (= c_src_off)
    reg  [31:0] stage_sdram_off;// SDRAM dest byte offset (#32: decoupled from the DDR3 read base)
    reg  [31:0] stage_size;    // total bytes to copy = {c_h, c_w}
    reg  [31:0] stage_byte;    // bytes copied so far (beat-granular until a write lands)
    reg  [63:0] stage_beat;    // the current DDR3 beat
    reg  [1:0]  stage_wj;      // which 16-bit word of the beat is being written (0..3)
    // [gmloader-GPU slim] the OP_STAGE atlas FSM's private copies of the three
    // burst-write outputs; the port wires src_sdram_we_burst/din64/waddr now
    // drive them unconditionally (see near the bottom of this file).
    reg          stage_we_burst_fsm;
    reg  [63:0]  stage_din64_fsm;
    reg  [26:0]  stage_waddr_fsm;
    // [stage-barrier] tracks that stage_barrier_busy was observed HIGH after a
    // barrier request, so S_STAGE_BARRIER_WAIT releases only on the busy FALLING
    // edge (flush+invalidate complete) — never racing past a not-yet-asserted busy.
    reg         barrier_seen_busy;

    // [collapse-single-source] The per-blit source read is HARDWIRED to SDRAM. The
    // old per-command mux (C_SRCSEL `srcsel` & F_SRC_SDRAM) and the DDR3 live-source
    // datapath are gone: every BLIT now fetches its source through comp_pipeline's
    // P_SRC (ch5) cache-ok port. The engine stages all atlas sources DDR3->SDRAM
    // unconditionally, so there is a single source datapath to debug. F_SRC_SDRAM is
    // therefore a no-op (kept in the protocol constants for ring-format compatibility).
    wire src_in_sdram = 1'b1;

    // ---- clip (combinational off decoded c_*) --------------------------
    wire signed [31:0] sdx = c_dst_x, sdy = c_dst_y;
    wire signed [31:0] xe = sdx + c_w, ye = sdy + c_h;
    wire signed [31:0] clip_x0 = (sdx<0)?0:sdx;
    wire signed [31:0] clip_y0 = (sdy<0)?0:sdy;
    wire signed [31:0] clip_x1 = (xe>`FB_W)?`FB_W:xe;
    wire signed [31:0] clip_y1 = (ye>`FB_H)?`FB_H:ye;
    wire empty = (clip_x0>=clip_x1) || (clip_y0>=clip_y1);

    // video control word (drop-in producer): frame_counter[31:2] | buf[1:0]
    wire [31:0] vctrl_val = ((frame_counter + 32'd1) << 2) | {31'd0, target_buf[0]};

    // ════════════════════════════════════════════════════════════════════════
    //  BLT_OP_TRILIST datapath (Task 5) — third bus owner: tri_busy
    // ════════════════════════════════════════════════════════════════════════
    reg          tri_busy;                 // set on OP_TRILIST decode, cleared at S_NEXT_CMD
    reg  [15:0]  tri_count, tri_idx;        // triangle count (cmd.w) + current triangle
    reg  [31:0]  tri_entry_qw;             // SRC_QW + (EOFF>>3) : first vertex qword (real qw addr)
    reg  [2:0]   tri_vk;                    // vertex-qword collect index 0..5
    reg  [63:0]  tri_vqw [0:5];             // the 6 fetched vertex qwords
    // the 3 unpacked vertices (screen 12.4 signed; u/v 12.4 unsigned; rgba 8b/ch)
    reg  signed [15:0] tri_vx0,tri_vy0, tri_vx1,tri_vy1, tri_vx2,tri_vy2;
    reg         [15:0] tri_vu0,tri_vv0, tri_vu1,tri_vv1, tri_vu2,tri_vv2;
    reg         [7:0]  tri_vr0,tri_vg0,tri_vb0,tri_va0;
    reg         [7:0]  tri_vr1,tri_vg1,tri_vb1,tri_va1;
    reg         [7:0]  tri_vr2,tri_vg2,tri_vb2,tri_va2;
    reg          tri_setup_start;           // 1-cycle pulse into blt_tri_setup

    // walk state
    reg  [15:0]  tri_px, tri_py, tri_maxx, tri_maxy;   // current pixel + bbox max
    reg  [15:0]  tri_ox;                               // bbox-min x (seek's left clamp)
    // [span walk] the ROW's first covered x, i.e. where A_ROWY restarts the next row.
    // The pre-span walk restarted every row at tri_ox and paid one coverage test per
    // bbox column; this holds the previous row's SPAN START so the seek only has to
    // travel |s(y+1)-s(y)| columns (see the span-walk block comment below).
    reg  [15:0]  row_px;
    // [pipeline stage 3b] row_pend is DELETED. It existed only to defer the
    // A_PIX -> A_ROWY hand-off for a pixel dispatched at tri_maxx until A_ISSUE had
    // queued it; with the chain pipelined, A_PIX takes that branch on the dispatch
    // cycle itself (the pixel's coords/attrs are already latched and A_ROWY touches
    // only the walk cursor), which also removes one hop per span that ended at tri_maxx.
    reg          sk_dir_set;                         // this row's seek direction is locked
    reg          sk_left;                              // locked direction: 1=leftward, 0=rightward
    reg          tri_bbox_neg;                         // bbox-max went NEGATIVE -> reject the triangle
    // [pipeline stage 1] The (px,py)+accumulator "cursor" is now advanced at the
    // moment a pixel is DISPATCHED from S_TRI_PIX (not 12 cycles later at the tail),
    // decoupling coverage/attr generation from the datapath depth so the walk can
    // eventually issue 1 px/cyc. tri_cv marks the cursor as still inside the bbox;
    // the covered pixel's (px,py) is snapshotted into pxs/pys so the datapath keeps
    // using this pixel's coords while the cursor moves on.
    reg          tri_cv;                               // cursor still within bbox
    reg  [15:0]  pxs, pys;                             // dispatched pixel's (px,py) snapshot
    reg  [31:0]  tri_vbase;                            // this triangle's first vertex-qword addr
    reg  signed [63:0] w0, w1, w2;                     // running coverage edges (this pixel)
    reg  signed [63:0] row_w0, row_w1, row_w2;         // coverage edges at row start (x=row_px)
    // [span walk] the same three edges one column to the LEFT (x = tri_px-1). The
    // leftward seek needs to know whether the left NEIGHBOUR is covered; carrying it
    // as a register keeps that decision a sign-bit test instead of putting three
    // 64-bit subtracts in front of the A_SEEK branch. Maintained by the same moves as
    // w0/w1/w2: a right step COPIES w->wm (no adder), a left step copies wm->w and
    // subtracts one dx from wm, a row step adds dy to both.
    reg  signed [63:0] w0m, w1m, w2m;                  // coverage edges at x = tri_px-1
    reg  signed [63:0] row_w0m, row_w1m, row_w2m;      // ... at x = row_px-1
    // [timing/DSP] weighted attr sums are 48-bit in the setup (ts_W*_0 / ts_dW*)
    // and stay within that envelope over the bbox walk (see blt_tri_setup header),
    // so hold them in 48-bit — not 64 — to keep the per-pixel W*area_recip
    // multiply a 48x48 (fewer DSP tiles, shallower) instead of 64x48. The stored
    // values never used bits [63:48] (sign extension only), so this is bit-exact.
    reg  signed [47:0] Wu, Wv, Wr, Wg, Wb, Wa;         // running weighted attr sums (this pixel)
    reg  signed [47:0] row_Wu,row_Wv,row_Wr,row_Wg,row_Wb,row_Wa; // at row start

    // per-pixel latched intermediates
    reg  [7:0]   cr_q, cg_q, cb_q, ca_q;   // interpolated colour for the blend
    reg  [1:0]   tex_lane_q;               // 16-bit lane within the fetched texel qword
    // Pipeline-private register carrying THIS pixel's texel qword tag from the addr2 stage
    // (ax_v[4]) to the issue stage (ax_v[5]). tri_p0_addr must NOT be (ab)used for this
    // hand-carry: pb's B_FILL demand-miss write (`tri_p0_addr <= {b_qtag,3'd0}`) is a second
    // writer of that register in the same always block and can clobber pa's in-flight address
    // on a same-cycle collision — see docs/superpowers/.../uvfull-rootcause-report.md.
    // [pipeline stage 3b] CORRECTION to this note: the second half of the original hazard,
    // "or during any pf_full stall in A_ISSUE", no longer exists — A_ISSUE is gone and the
    // issue STAGE cannot stall (the credit scheme makes pf_full unreachable at a push, see
    // ax_cred below). The same-cycle-collision half is unchanged and still the reason this
    // register exists, so do not fold pa_qtag back into tri_p0_addr on the strength of the
    // stall having gone away.
    reg  [23:0]  pa_qtag;                  // pa-private: this pixel's SDRAM qword tag
    reg  [15:0]  texel_q, dst_q;           // fetched texel + dst pixel
    reg  [14:0]  dst_qw_q;                 // comp_fbram qword index for this pixel
    reg  [1:0]   dst_lane_q;               // x[1:0]

    // [pipeline stage 3a] The per-pixel S_TRI_* walk is split into two concurrent
    // sub-FSMs that run every cycle while the main state sits at the umbrella
    // S_TRI_RUN, overlapping one pixel's blend/write (B) with the next pixel's
    // address-gen + texel fetch (A):
    //   pa (address-gen): span walk -> W*recip mul -> texel addr -> issue P_SRC read
    //       ([span walk] the walk is A_SEEK -> A_PIX* -> A_ROWY per row: locate the
    //        row's covered interval, emit it left-to-right, step the row. It no longer
    //        tests every bbox column -- see the span-walk block comment further down.)
    //   pb (consume+blend): wait texel -> dst read -> 3-stage blend -> comp_fbram write
    // They rendezvous through a depth-TEXFIFO_D payload FIFO (pf_mem), so A can run up
    // to TEXFIFO_D pixels ahead of B. Because A computes pixel N+1 (clobbering the live
    // cr_q/dst_qw_q/... regs) while B is still blending pixel N, B consumes the payload
    // popped from the FIFO (b_* regs) rather than the live regs. Triangle
    // constants (c_blend/c_alpha/c_src_*) are stable while pixels are in flight (the
    // pipe drains before the next triangle's setup), so they need no snapshot.
    // [span walk] pa widened 3 -> 4 bits for A_SEEK / A_ROWY. Encodings 0..7 are
    // UNCHANGED so historical wedge-probe pa values still decode as they always did;
    // the probe WORD LAYOUT did have to shift by one bit (see wedge_snap below).
    // [pipeline stage 3b] A_MUL0=1 / A_MUL1=2 / A_MUL=3 / A_ADDR=4 / A_ADDR2=5 /
    // A_ISSUE=6 are DELETED. The mul/addr/issue chain is no longer SEQUENCED by pa; it
    // is a 6-deep feed-forward PIPELINE clocked by the ax_v valid shifter (below), so
    // pa now only ever holds A_PIX / A_DONE / A_SEEK / A_ROWY and can dispatch one
    // covered pixel PER CYCLE instead of one per seven. Encodings 1..6 are left as a
    // HOLE rather than renumbered — exactly as B_DSTW/B_DSTC were — so a pre-stage-3b
    // wedge-probe dump whose pa_at_peak reads 1..6 still decodes as "somewhere in the
    // mul/addr chain" instead of silently meaning something else.
    localparam [3:0] A_PIX=4'd0, A_DONE=4'd7,
                     A_SEEK=4'd8,     // find this row's FIRST covered x
                     A_ROWY=4'd9;     // step to the next row from the row-start snapshot
    // pb widened to 4 bits: the qword-BRAM read is pipelined through B_LOOK (present the
    // slot as a REGISTERED read address so tq_data infers M10K) and B_WAIT (stall on a
    // demand/prefetch fill, then re-read). This breaks the b_qtag -> 256-entry distributed
    // tag/data mux -> dst_q combinational path that failed STA at -1.732ns on the fabric clk.
    // [Phase 1 A2] B_DSTW=4'd4 / B_DSTC=4'd5 are DELETED (the dst read is hoisted into
    // B_IDLE), leaving 4 and 5 as a hole.
    //
    // [Phase 1 2b] The sim cycle gate no longer constrains this encoding. a2_cycle_gate.vh
    // used to key off LITERAL pb values, so renumbering would have made it MISCOUNT rather
    // than error — and that test-side shortcut had leaked back HERE as a rule forbidding
    // renumbering, i.e. a testbench convenience had become a constraint on RTL. It now binds
    // hierarchically (blt.B_IDLE / blt.B_WR3) and follows any renumbering automatically.
    //
    // Still check the wedge-probe state_at_peak snapshots before renumbering: those raw pb
    // values are decoded by eye when reading device dumps, so a changed encoding silently
    // reinterprets historical probe data instead of failing loudly.
    localparam [3:0] B_IDLE=4'd0, B_LOOK=4'd1, B_FILL=4'd2, B_WAIT=4'd3,
                     B_WR=4'd6, B_WR2=4'd7, B_WR3=4'd8,
                     // [app-surface v1] surface texel read: issue surf_rd (B_SURF_W is the
                     // 1-cyc BRAM latency), latch the texel (B_SURF_C), then dst/blend.
                     B_SURF_W=4'd9, B_SURF_C=4'd10;
    reg  [3:0]   pa;                       // address-gen sub-FSM state
    reg  [3:0]   pb;                       // consume+blend sub-FSM state

    // ── [pipeline stage 3b] the A chain as a PIPELINE, not an FSM walk ───────────
    // The six ex-states A_MUL0..A_ISSUE had no stall and no branch between them: each
    // read the previous one's output registers and wrote its own. That is a pipeline
    // written as a sequencer, and it cost 6 cycles of pa occupancy per covered pixel on
    // top of the A_PIX dispatch cycle (7.15 cyc/px measured, vs pb's 6.0) — so pa, not
    // the blend path, set wall-clock throughput.
    //
    // ax_v[k] means "the register set written by stage k+1 holds a live pixel". It is a
    // pure shift register: ax_v <= {ax_v[4:0], ax_disp}. Stage bodies live after the
    // case(pa) below, each gated on its own ax_v bit, and they fire CONCURRENTLY — six
    // different pixels in flight.
    //
    // WHY NO BACK-PRESSURE INSIDE THE PIPELINE. pb consumes ~1 px / 6 cyc, so a 1 px/cyc
    // dispatcher would fill the payload FIFO and then have to stall mid-pipeline — a
    // clock-enable on ~2.5 kbit of wide multiply registers (and the DSP output regs),
    // i.e. a high-fanout enable on exactly the paths Task 6's timing discipline was
    // protecting. Instead the dispatcher takes a CREDIT: ax_cred counts pixels dispatched
    // but not yet popped off the FIFO by pb, and A_PIX only dispatches while
    // ax_cred < TEXFIFO_D. FIFO occupancy is then (ax_cred - pixels still in the pipe),
    // and the pushing pixel is itself still in the pipe, so occupancy at a push is
    // <= TEXFIFO_D-1: the push can NEVER find pf_full. The pipeline therefore shifts
    // unconditionally every cycle, the only hold is on the walk cursor in A_PIX, and
    // A_SEEK/A_ROWY are free to make row progress while the dispatcher is credit-starved.
    reg  [5:0]   ax_v;                     // stage valid bits (see above)
    // ax_cred is declared further down, immediately after TEXFIFO_D — its width is derived
    // from that depth and the two must not be editable apart. See the note there.
    // Carries for the values whose PRODUCER and CONSUMER are more than one stage apart
    // (everything else — wu_q.., pp_*, mul_*, itu_q/itv_q, tex_row, pa_qtag — is written
    // by stage k and read by stage k+1, so the existing single copy already IS that
    // pipeline register and needs no duplication: NBA read-before-write per cycle).
    //   pxs/pys      written at dispatch, read 3 stages later (dst_qw multiply)
    //   itu_q        written by the mul stage, read 2 stages later (A_ADDR2's byte add)
    //   cr_q..dst_*  written by the mul stage, read 3 stages later (the FIFO push)
    reg  [15:0]  ax2_px, ax2_py, ax3_px, ax3_py;
    reg  signed [31:0] ax5_itu;
    reg  [7:0]   ax5_cr, ax5_cg, ax5_cb, ax5_ca;
    reg  [7:0]   ax6_cr, ax6_cg, ax6_cb, ax6_ca;
    reg  [14:0]  ax5_dst_qw, ax6_dst_qw;
    reg  [1:0]   ax5_dst_lane, ax6_dst_lane;

    // [Task 2] depth-D payload FIFO decouples pa from pb: pa pushes each pixel's
    // payload as it finishes address-gen and races ahead up to TEXFIFO_D pixels; pb
    // pops the head and resolves/blends. Replaces the old single-deep h_full handoff.
    // Payload = {ca,cb,cg,cr[8b each]=32, dst_qw[15], dst_lane[2], qtag[24], texlane[2]}
    // = 75 bits. Pointer-with-extra-MSB scheme gives full/empty disambiguation.
    localparam integer TEXFIFO_D  = 8;
    localparam integer TEXFIFO_AW = 3;      // $clog2(TEXFIFO_D)
    // [pipeline stage 3b] ax_cred lives HERE, next to the depth it is derived from,
    // rather than up with the other ax_* registers: its width is a function of
    // TEXFIFO_D and the two must never be edited apart (see the issue stage's
    // "THREE THINGS MUST MOVE TOGETHER" note). Keeping them adjacent is the cheapest
    // way to make that impossible to miss -- and Verilog requires it anyway, since
    // $clog2(TEXFIFO_D+1) cannot reference a localparam declared further down.
    // ax_cred holds 0..TEXFIFO_D INCLUSIVE, so its width must be $clog2(TEXFIFO_D+1), NOT
    // $clog2(TEXFIFO_D). DERIVED, never hand-written: a fixed [3:0] happens to be right at
    // TEXFIFO_D=8 but becomes a WIDTH TRAP the moment the depth is raised (the obvious next
    // experiment — see the prefetch-lead note in the Task 7 report). At TEXFIFO_D=16 a 4-bit
    // ax_cred makes `ax_cred < TEXFIFO_D` a TAUTOLOGY (the reg cannot reach 16), so the
    // dispatcher would never throttle — and because the credit scheme is what let the
    // `if (!pf_full)` guard be removed from the issue stage, there is nothing downstream to
    // catch it: it would silently overrun the payload FIFO.
    localparam integer AX_CW = $clog2(TEXFIFO_D+1);
    reg  [AX_CW-1:0] ax_cred;              // dispatched-but-not-yet-popped pixels, 0..TEXFIFO_D
`ifndef SYNTHESIS
    // Belt-and-braces on the paragraph above, in case AX_CW is ever hand-overridden rather
    // than derived. Elaboration-time, so it costs nothing and cannot be missed.
    initial if ((1 << AX_CW) < (TEXFIFO_D + 1)) begin
        $display("FAIL 3B-CREDW: ax_cred is %0d bits, which cannot represent TEXFIFO_D=%0d; the ax_room compare is a tautology and the dispatcher will overrun the FIFO", AX_CW, TEXFIFO_D);
        $finish;
    end
`endif
    localparam integer PW = 32+15+2+24+2;   // payload width = 75
    reg  [PW-1:0] pf_mem [0:TEXFIFO_D-1];
    reg  [TEXFIFO_AW:0] pf_wr, pf_rd;       // extra MSB for full/empty disambiguation
    wire pf_empty = (pf_wr == pf_rd);
    wire pf_full  = (pf_wr[TEXFIFO_AW-1:0]==pf_rd[TEXFIFO_AW-1:0]) && (pf_wr[TEXFIFO_AW]!=pf_rd[TEXFIFO_AW]);
    wire [PW-1:0] pf_head = pf_mem[pf_rd[TEXFIFO_AW-1:0]];
    // [pipeline fix] p0_ok is a 1-cycle strobe and the P_SRC channel is single-
    // outstanding, so the texel for the ONE in-flight read must be caught the cycle it
    // arrives — regardless of where the blend FSM (pb) happens to be. This always-
    // listening catcher (top of S_TRI_PIX) fills the BRAM slot and clears fill_busy the
    // cycle p0_ok returns, so the strobe is never missed and pb resolves via the local
    // qword BRAM in B_FILL.
    // B-local copies of the popped FIFO payload. pb unpacks pf_head into these at B_IDLE
    // (then pops), and uses them through B_WR3 — pa may already be filling later FIFO
    // slots with the next pixels' payloads, so pb must read these private copies.
    reg  [7:0]   b_cr, b_cg, b_cb, b_ca;
    reg  [14:0]  b_dst_qw;
    reg  [1:0]   b_dst_lane;
    reg  [23:0]  b_qtag;                   // B-local: this pixel's texel qword tag
    reg  [1:0]   b_tex_lane;               // B-local: texel lane within the qword

    // registered bus-owner outputs (muxed onto p0_*/fb_* below when tri_busy)
    reg          tri_p0_rd;   reg [26:0] tri_p0_addr;
    reg          tri_fb_rd_en; reg [14:0] tri_fb_rd_qw;
    reg          tri_fb_wr_en; reg [14:0] tri_fb_wr_qw; reg [1:0] tri_fb_wr_lane; reg [15:0] tri_fb_wr_pix;

    // [app-surface v1] TRILIST texel-source = surface (BLT_F_SRC_SURFACE). Latched at
    // OP_TRILIST setup. The surface texel read is a 1-cyc comp_fbram surf_rd BRAM hit
    // (NO tq cache / P_SRC): surf_qw_q/lane computed in A_ADDR2, read in B_SURF_*.
    reg          tri_src_surface;
    reg          tri_surf_rd_en; reg [14:0] tri_surf_rd_qw;   // drive comp_fbram surf_rd port
    reg  [14:0]  surf_qw_q;      // A_ADDR2 surface qword (itv*stride + itu>>2), pushed to the FIFO

    // ── Lever 1: blitter-local prefetching qword texel cache ────────────────
    // Direct-mapped BRAM of TEXQ_N qwords; slot = qtag[TEXQ_AW-1:0]; a single
    // P_SRC read fills one slot. Decouples the rasterizer's texel read (1-cyc
    // BRAM hit) from the single-outstanding P_SRC latency. Bit-exact: same
    // texel bytes, fetched earlier. See docs .../2026-07-16-trilist-lever1-*.
    // 256 qwords. (A 64-entry variant closed the tq_hit tag mux but placed a fragile
    // comp_pipeline neighbor WORSE -1.146 vs 256's -0.427 — pure placement variance — so
    // the larger cache stays; the fabric-clock closure is addressed via a compositor-path
    // timing hint, not by shrinking this.) Tag width auto-tracks via TEXQ_TW below.
    localparam integer TEXQ_N     = 256;
    localparam integer TEXQ_AW    = 8;      // $clog2(TEXQ_N)
    localparam integer TEXQ_TW    = 24 - TEXQ_AW;  // tag width = qtag[23:TEXQ_AW] (widens as N shrinks)
    // tq_data + tq_tag are read ONLY via the dedicated read-port block below and written
    // ONLY by the catcher -> both infer M10K (registered-read BRAM), so neither the 64-bit
    // data nor the 16-bit tag read is a distributed 256:1 mux on the fabric clock. This is
    // only possible because pa no longer reads the tag RAM (it uses the last_pf_qtag filter
    // below instead of a full residency check) — a registered+combinational mixed read of
    // tq_tag previously crashed Quartus 17.0 Verific ("read to RAM wasn't mapped to a
    // specific read port"), which is why the tag was distributed before.
    //
    // [inference] The read MUST stay in its own unconditional `always @(posedge clk)` block
    // (see below) — NOT nested inside the main FSM's case(state)/case(pb) arms. When the read
    // lived in B_LOOK, Quartus 17.0 reported both arrays as "uninferred due to asynchronous
    // read logic" (map.rpt Info 276007) and built them from LABs instead: 256*64 + 256*16 =
    // 20,480 flops, ~45% of the whole design's registers, and b_qtag[7:0] became the top
    // non-global fan-out net in the design (~1,735) driving a real 256:1 distributed mux.
    // That cost -0.983ns setup on the fabric clock, a single 9.565ns route from the fbcache
    // mux straight into the flop array with no logic in between. Same AUTO-inference
    // fragility class as solarus-mister's frt_bram/clut_bram ("Task 3 LAB-overflow chase");
    // solarus's clut_bram uses exactly this dedicated-block form. Don't re-nest these reads.
    (* ramstyle = "no_rw_check, M10K" *) reg [63:0] tq_data [0:TEXQ_N-1];        // cached qwords
    (* ramstyle = "no_rw_check, M10K" *) reg [TEXQ_TW-1:0] tq_tag [0:TEXQ_N-1];  // qtag[23:TEXQ_AW]
    reg  [TEXQ_N-1:0] tq_valid;             // per-slot valid; packed for a 1-cycle SYNCHRONOUS clear on the per-command barrier
    // registered qword-cache read (B_LOOK -> B_FILL): raw tag/valid/data captured, hit
    // compare done in B_FILL off the registers (short path).
    reg  [63:0]  tq_rdata;                  // registered tq_data[slot] (M10K read)
    reg  [TEXQ_TW-1:0] tq_rtag;             // registered tq_tag[slot]  (M10K read)
    reg          tq_rvalid;                 // registered tq_valid[slot]
    // [RDW guard] With tq_data/tq_tag as real M10K under `no_rw_check`, a read that collides
    // with the catcher's write to the SAME slot in the SAME cycle returns UNDEFINED data --
    // unlike the old flop array, where non-blocking semantics guaranteed the old value. pa's
    // speculative prefetch shares fill_slot and can land in any cycle, including the one the
    // read port is sampling, so the collision is reachable (same slot index, different tag).
    // Flag it and force B_FILL to take the MISS path: B_WAIT re-reads once the fill has
    // landed, which is defined. Costs a redundant re-read on a rare event; without it a
    // garbage tag that happens to match (~1/65536) would silently yield a wrong texel.
    reg          tq_rdw_bad;                // snapshot cycle collided with a catcher write
    // pa best-effort prefetch de-dup: skip re-issuing a fill for the qword it just
    // prefetched (catches the dominant consecutive-same-qword case; 4 texels share a
    // qword). NOT a residency check — pb's B_LOOK/B_FILL demand path is the correctness
    // backbone, so a missed skip only costs a redundant fill, never a wrong texel.
    reg  [23:0]  last_pf_qtag;              // last qword tag pa issued a prefetch for
    // P_SRC fill arbiter: sole owner of tri_p0_rd/tri_p0_addr, single-outstanding.
    reg         fill_busy;                  // a fill is in flight (p0_ok pending)
    reg  [TEXQ_AW-1:0] fill_slot;           // slot the in-flight fill targets
    reg  [TEXQ_TW-1:0] fill_tag;            // tag the in-flight fill will stamp
    // [fill watchdog] self-heal a lost p0_ok strobe (permanent B_WAIT hang, no timeout).
    // Always compiled (distinct from the ifdef'd fill_run diag below).
    localparam [12:0] WD_TIMEOUT = 13'd4096;   // ~42us @98MHz; >> sim MISS_LAT=140 => never fires in sim
    reg  [12:0] wd_stall;                   // continuous (fill_busy && !p0_ok) cycles, saturates at WD_TIMEOUT
    reg  [23:0] wd_fire_count;              // saturating count of watchdog fires (reset only on rst)
    wire        wd_fire = (wd_stall == WD_TIMEOUT);

    // ---- texel-qword cache READ PORT (dedicated block -> clean M10K inference) -----------
    // Deliberately its OWN unconditional always block rather than an arm of the main FSM:
    // that is what lets Quartus extract a real BRAM read port (see the tq_data decl above for
    // what nesting it inside B_LOOK cost). Reading every cycle is free and safe -- b_qtag is
    // written ONLY in B_IDLE (the pf_head unpack), so it is stable across B_LOOK -> B_FILL and
    // the value B_FILL consumes is identical to the old B_LOOK-gated capture. tq_valid stays
    // flops (it needs the 1-cycle synchronous bulk clear) but is sampled here too, so all
    // three snapshot registers stay coherent with one another.
    always @(posedge clk) begin
        tq_rdata  <= tq_data [b_qtag[TEXQ_AW-1:0]];
        tq_rtag   <= tq_tag  [b_qtag[TEXQ_AW-1:0]];
        tq_rvalid <= tq_valid[b_qtag[TEXQ_AW-1:0]];
    end
    // RDW collision flag, kept OUT of the block above on purpose: that block must stay a bare
    // BRAM read port (a reset on it risks pushing the read back into LABs, which is the whole
    // bug being fixed here). This one carries the reset so the flag is never X out of reset --
    // an X would poison B_FILL's hit test and trip the suite's x-guards.
    always @(posedge clk) begin
        if (rst) tq_rdw_bad <= 1'b0;
        else     tq_rdw_bad <= (fill_busy && p0_ok) && (fill_slot == b_qtag[TEXQ_AW-1:0]);
    end

`ifdef SOLARUS_DBG_PROBES
    // [wedge probe v2] The fabric stall was PINNED to S_TRI_PIX (state 50) — the rasterizer's
    // per-pixel coverage-walk + texel-fetch umbrella state — NOT S_SNAP/comp_fb_dma. This probe
    // captures WHY S_TRI_PIX wedges: the sub-FSM states (pa/pb), the texel-fetch stall severity
    // (max continuous fill_busy), and the bbox (runaway-walk check), all latched at the peak of
    // dbg_stuck (deepest dwell) and published on the NEXT control-block write after recovery
    // (a stuck blitter writes nothing, so we can't publish DURING the stall — latch + defer).
    //   word A -> C_SRCSEL.hi  (host 0x3B00003C): [5:0]=state_at_peak [9:6]=pa [13:10]=pb
    //             [14]=fill_busy_at_peak [15]=fb_dma_busy_at_peak [31:16]=peak_stuck[23:8]
    // ⚠ LAYOUT CHANGED (span walk): pa grew 3 -> 4 bits (A_SEEK/A_ROWY), consuming the
    // one spare bit, so pb/fill/fbdma each shifted UP by one. pa/pb VALUES 0..7 still
    // mean what they always meant; the FIELD POSITIONS above do not match device dumps
    // taken before this commit. Decode pre-span-walk word A with the old layout
    // ([8:6]=pa [12:9]=pb [13]=fill [14]=fbdma).
    //   word B -> C_STATUS.hi  (host 0x3B000034): max_fbdma_run[31:0] (copy-stall severity)
    // Read (v3): state_at_peak==44 (S_SNAP_DRAIN) + fb_dma_busy_at_peak=1 + max_fbdma_run huge
    // => comp_fb_dma cannot finish its copy (its DDR writes are not being accepted => the
    // arbiter is not in G_READER; suspect ddr_blitter_arb G_BLT_RD, whose exit has no timeout).
    // state_at_peak==23 (S_RD_WAIT) => the blitter's own control-block read is starving instead.
    // state_at_peak==50 (S_TRI_PIX) => back to the rasterizer; pa/pb name the sub-state.
    // peak_stuck saturates at 0xFFFFFF (~0.17s @98.4MHz), so [31:16]==0xFFFF just means "deep".
    // Placed AFTER pa/pb/fill_busy/tri_max* decls: `default_nettype none` forbids forward refs.
    reg  [23:0] peak_stuck;
    reg  [5:0]  state_at_peak;
    reg  [3:0]  pa_at_peak;
    reg  [3:0]  pb_at_peak;
    reg         fill_at_peak;
    reg  [15:0] maxx_at_peak, maxy_at_peak;
    reg  [23:0] fill_run;        // current continuous fill_busy duration
    reg  [23:0] max_fill_run;    // persistent max continuous fill_busy (texel-fetch-stall severity)
    // [wedge probe v3, 2026-07-24] The device stall was re-measured with the fabric's OWN perf
    // counters: during an 18s host-observed stall perf_frame_cyc stays NORMAL (~34ms). That
    // counter spans S_CHK_NEW -> the C_DONE write, so a normal value proves the dwell is OUTSIDE
    // it — i.e. in the S_SNAP_* tail, not the rasterizer. Of those, S_SNAP_WAIT cannot park
    // (post-A1 it is an unconditional pass-through; it formerly could not park because vs_rise
    // was free-running off tim_vblank) and S_SNAP_BUSY is bounded by SNAP_GUARD, leaving
    // S_SNAP_DRAIN (:1543 `if (!fb_dma_busy)`) as the only unbounded wait. v3 therefore adds the
    // signal that confirms or kills that chain: how long fb_dma_busy stays continuously high.
    // If comp_fb_dma really is stuck mid-copy, max_fbdma_run reaches ~1.7e9 (18s @98.4MHz) and
    // fbdma_at_peak is set with state_at_peak==S_SNAP_DRAIN(44). 32-bit: 18s fits, 24 would not.
    reg  [31:0] fbdma_run;       // current continuous fb_dma_busy duration
    reg  [31:0] max_fbdma_run;   // persistent max continuous fb_dma_busy (copy-stall severity)
    reg         fbdma_at_peak;   // was comp_fb_dma mid-copy at the deepest dwell?
    always @(posedge clk) begin
        if (rst) begin
            peak_stuck<=24'd0; state_at_peak<=6'd0; pa_at_peak<=4'd0; pb_at_peak<=4'd0;
            fill_at_peak<=1'b0; maxx_at_peak<=16'd0; maxy_at_peak<=16'd0;
            fill_run<=24'd0; max_fill_run<=24'd0;
            fbdma_run<=32'd0; max_fbdma_run<=32'd0; fbdma_at_peak<=1'b0;
        end else begin
            if (fill_busy) begin
                if (fill_run != 24'hFFFFFF) fill_run <= fill_run + 24'd1;
                if (fill_run >= max_fill_run) max_fill_run <= fill_run + 24'd1;
            end else fill_run <= 24'd0;
            if (fb_dma_busy) begin
                if (fbdma_run != 32'hFFFFFFFF) fbdma_run <= fbdma_run + 32'd1;
                if (fbdma_run >= max_fbdma_run) max_fbdma_run <= fbdma_run + 32'd1;
            end else fbdma_run <= 32'd0;
            if (dbg_stuck > peak_stuck) begin
                peak_stuck    <= dbg_stuck;
                state_at_peak <= dbg_state_q;
                pa_at_peak    <= pa;
                pb_at_peak    <= pb;
                fill_at_peak  <= fill_busy;
                fbdma_at_peak <= fb_dma_busy;
                maxx_at_peak  <= tri_maxx;
                maxy_at_peak  <= tri_maxy;
            end
        end
    end
    // word A (host 0x3B00003C): peak_stuck magnitude replaces max_fill_run — device-measured
    // wd_fire_count==0 and fill_at_peak has never been the story, whereas the DWELL DEPTH is
    // what distinguishes "0.17s saturated" from a brief hiccup. bit14 = fbdma_at_peak (new).
    wire [31:0] wedge_snap  = {peak_stuck[23:8], fbdma_at_peak, fill_at_peak,
                               pb_at_peak, pa_at_peak, state_at_peak};
    // word B (host 0x3B000034): the bbox is retired (maxx/maxy read `FB_W-1/`FB_H-1 = 287/215,
    // the legitimate full-screen composite quad, never diagnostic). Carries the copy-stall
    // severity instead. (Pre-fix these saturated at the stale 319/239 clamp — see tri_maxx_cl.)
    wire [31:0] wedge_snap2 = max_fbdma_run;
`endif

    wire tri_need_dst = (c_blend==BLEND_ALPHA)||(c_blend==BLEND_ADD)||(c_blend==BLEND_MULTIPLY);

`ifndef SYNTHESIS
    // ── [Phase 1 A2] sim-only invariants for the hoisted dst read ─────────────────
    // Placed HERE, below tri_need_dst / tri_fb_* / pb, because iverilog binds by
    // declaration order. Both are `ifndef SYNTHESIS so they cost nothing on device,
    // and both are ASSERTIONS rather than hardware fixes on purpose: a forwarding mux
    // or a validity interlock would add combinational depth on the fabric clock, which
    // sits at -0.169 ns worst-case setup slack.
    reg          a2_rd_en_d;   // tri_fb_rd_en as it was during the PREVIOUS cycle
    always @(posedge clk) a2_rd_en_d <= tri_fb_rd_en;

    // ── [Phase 1 A2] On the same-cycle RW hazard: IT DOES NOT EXIST ──────────────
    // The spec asked for a RAW assertion here, on the premise that "pixel N's write is
    // presented during pixel N+1's B_IDLE, which is now also N+1's read cycle". That
    // premise is wrong: B_IDLE is the read ISSUE cycle, not the read cycle. Walking the
    // one-cycle registered outputs:
    //
    //   tri_fb_wr_en is set in B_WR3 (:1637)          -> HIGH during the next cycle,
    //                                                    which is pixel N+1's B_IDLE
    //   tri_fb_rd_en is set in B_IDLE (:1477) / B_WAIT -> HIGH during B_LOOK
    //   both self-clear every cycle (:912-913), and both come from the single pb FSM
    //
    // So the write is presented in B_IDLE and the read in B_LOOK — ALWAYS exactly one
    // cycle apart, never the same cycle. A `no_rw_check` bank is only unsafe on a
    // SAME-cycle read+write to one address; a write at T followed by a read at T+1 has
    // already committed, so even the overdraw case (N and N+1 the same pixel) correctly
    // returns N's result. The design is therefore safer than the spec claimed.
    //
    // An assertion was written for this and DELETED rather than kept, because it could
    // never fire: measured directly, `tri_fb_wr_en && tri_fb_rd_en` holds 0 times, and
    // the adjacent form (write at T, read at T+1, same qw AND lane) also occurs 0 times,
    // across trilist_add and trilist_quad. A dead assertion reads as coverage and is
    // worse than a correct explanation. No forwarding mux is needed either — which is
    // the outcome the spec wanted, for a better reason than it gave.
    //
    // RE-CHECK THIS IF pb IS EVER RE-TIMED so that the B_WR3 write and the B_IDLE read
    // issue land in the same cycle (e.g. collapsing B_WR3->B_IDLE->B_LOOK, or issuing
    // the dst read from B_WR3 to shave another cycle). The one-cycle separation above is
    // the entire safety argument; nothing else protects these banks.

    // [Phase 1 A2] DST-STALENESS invariant — a design-CONTRACT guard.
    // Contract: comp_rd_qword must be consumed in the cycle immediately after
    // tri_fb_rd_en was asserted, at every site that latches dst_q from it.
    //
    // [Phase 1 2b] WHAT THIS DOES AND DOES NOT CATCH — measured, after
    // tb_blitter_trilist_missdst made the miss+dst path reachable (1809 retry re-issues,
    // B_WAIT=39834). Moving the re-issue back into B_FILL's miss branch (the original,
    // rejected placement) gives:
    //     with this assertion   -> FAIL A2-DSTALE
    //     with it SUPPRESSED    -> bad = 0/62208, RESULT: PASS
    // So this assertion is the ONLY thing that distinguishes the two placements — the
    // golden diff does not, even on a bench that genuinely reaches the path.
    //
    // Be precise about why, because it is NOT that the pixels are silently corrupt: both
    // placements read the SAME address (b_dst_qw), and comp_fbram's read registers update
    // only under `if (rd_en)` (comp_fbram.sv:76), so rd_qword HOLDS its value until the
    // next read. During a triangle the tri path is the sole reader
    // (cr_en = tri_busy ? tri_fb_rd_en : pipe_fb_rd_en), so nothing can overwrite it in
    // between. The early read therefore still yields the correct data TODAY.
    //
    // The rejected placement is thus a LATENT fault, not an active one: it is correct only
    // by relying on (a) comp_fbram holding rd_qword and (b) the tri path having exclusive
    // read access for the whole stall. Break either — a shared read port, a client added
    // under tri_busy, a comp_fbram that returns X when rd_en is low — and it silently
    // reads someone else's qword. This assertion pins the invariant that makes the
    // correctness argument independent of both, which is why it is kept even though the
    // frame comes out bit-exact without it.
    always @(posedge clk) if (!rst && tri_need_dst && !a2_rd_en_d) begin
        if ((pb == B_FILL) && !tq_rdw_bad && tq_rvalid
                           && (tq_rtag == b_qtag[23:TEXQ_AW])) begin
            $display("FAIL A2-DSTALE: B_FILL latched dst_q with no dst read issued last cycle");
            $finish;
        end
        if (pb == B_SURF_C) begin
            $display("FAIL A2-DSTALE: B_SURF_C latched dst_q with no dst read issued last cycle");
            $finish;
        end
    end
`endif

    // per-pixel interpolation. The six W*area_recip products are PIPELINED across
    // a dedicated register layer: S_TRI_PIX latches the operands into single-fanout
    // regs (w*_q + recip_q), S_TRI_MUL0 does the multiply (mul_*), S_TRI_MUL rounds.
    // The dedicated input regs let Quartus pack the multiply as a pipelined DSP
    // (input reg + output reg) — Wu..Wa themselves have too much fanout (accumulate
    // + compare + multiply) to be absorbed as the DSP input register, which left the
    // 48x48 multiply combinational in one cycle and unable to close ~98 MHz.
    reg  signed [47:0] wu_q, wv_q, wr_q, wg_q, wb_q, wa_q;   // multiply operand A (single fanout)
    reg  signed [47:0] recip_q;                              // multiply operand B (shared)
    // W*area_recip as a two-stage split: a 48x48 done in one cycle was an ~8.9 ns
    // 4-tile combinational DSP (wv_q -> mul_v was -0.221 ns). Both operands are
    // >= 0 (W on covered pixels; recip < 2^41), so split recip into 24-bit halves,
    // register two 48x24 partial products, and sum them one cycle later -> each
    // lane is a shallower pipelined multiply + a registered add. Bit-exact:
    // wq*recip = wq*recip[23:0] + (wq*recip[47:24])<<24.
    reg         [71:0] pp_u_lo,pp_u_hi, pp_v_lo,pp_v_hi, pp_r_lo,pp_r_hi;
    reg         [71:0] pp_g_lo,pp_g_hi, pp_b_lo,pp_b_hi, pp_a_lo,pp_a_hi;
    reg  signed [95:0] mul_u, mul_v, mul_r, mul_g, mul_b, mul_a;
    reg  signed [63:0] rnd_u, rnd_v, rnd_r, rnd_g, rnd_b, rnd_a;
    reg  signed [31:0] itu, itv;
    reg  signed [31:0] itu_q, itv_q;   // clamped texel coords, registered for S_TRI_ADDR
    reg         [31:0] tex_row;        // registered itv_q*stride product (S_TRI_ADDR->ADDR2)
    reg         [15:0] tw1r, th1r;
    reg         [31:0] texbyte;

    // [pipeline] per-pixel blend/write pipeline registers (LAT=3, comp_mixer A/B/C):
    //   stage A (S_TRI_WR)  -> b1_*: tinted source channels + combined alpha ea/na + we
    //   stage B (S_TRI_WR2) -> b2_*: per-channel MAC / add / mul intermediate
    //   stage C (S_TRI_WR3) -> reduce (/255,/31,/63) + RGB565 pack -> fb write
    // (c_blend / c_colorkey / dst_qw_q / dst_lane_q are stable across the 3 stages, so
    //  they are used directly rather than re-registered per stage.)
    reg  [5:0]  b1_tsr, b1_tsg, b1_tsb, b1_dr, b1_dg, b1_db;
    reg  [7:0]  b1_ea, b1_na;
    reg         b1_we;
    reg  [16:0] b2_r, b2_g, b2_b;
    reg         b2_we;
    // combinational (blocking) temps: stage-A alpha-combine, stage-C reduce/clamp/pack
    reg  [15:0] xa_t;   // ca_q*c_alpha product, [0,65025]
    reg  [7:0]  ea_t;
    reg  [5:0]  bl_or, bl_og, bl_ob;
    reg  [6:0]  bl_ar, bl_ag, bl_ab;

    // blt_tri_setup registered outputs (stable from `valid` until the next start)
    wire               ts_valid, ts_degenerate;
    wire        [15:0] ts_ox, ts_oy;
    wire signed [47:0] ts_area, ts_area_recip;
    wire signed [47:0] ts_w0_0, ts_w1_0, ts_w2_0;
    wire signed [47:0] ts_dw0dx, ts_dw1dx, ts_dw2dx, ts_dw0dy, ts_dw1dy, ts_dw2dy;
    wire signed [47:0] ts_Wu_0, ts_Wv_0, ts_Wr_0, ts_Wg_0, ts_Wb_0, ts_Wa_0;
    wire signed [47:0] ts_dWudx, ts_dWvdx, ts_dWrdx, ts_dWgdx, ts_dWbdx, ts_dWadx;
    wire signed [47:0] ts_dWudy, ts_dWvdy, ts_dWrdy, ts_dWgdy, ts_dWbdy, ts_dWady;

    blt_tri_setup #(.SHIFT(40)) u_tri_setup (
        .clk(clk), .rst(rst), .start(tri_setup_start),
        .vx0(tri_vx0), .vy0(tri_vy0), .vx1(tri_vx1), .vy1(tri_vy1), .vx2(tri_vx2), .vy2(tri_vy2),
        .vu0(tri_vu0), .vv0(tri_vv0), .vu1(tri_vu1), .vv1(tri_vv1), .vu2(tri_vu2), .vv2(tri_vv2),
        .vr0(tri_vr0), .vg0(tri_vg0), .vb0(tri_vb0), .va0(tri_va0),
        .vr1(tri_vr1), .vg1(tri_vg1), .vb1(tri_vb1), .va1(tri_va1),
        .vr2(tri_vr2), .vg2(tri_vg2), .vb2(tri_vb2), .va2(tri_va2),
        .tex_w(c_src_x), .tex_h(c_src_y),
        .valid(ts_valid), .degenerate(ts_degenerate), .ox(ts_ox), .oy(ts_oy),
        .area(ts_area), .area_recip(ts_area_recip),
        .w0_0(ts_w0_0), .w1_0(ts_w1_0), .w2_0(ts_w2_0),
        .dw0dx(ts_dw0dx), .dw1dx(ts_dw1dx), .dw2dx(ts_dw2dx),
        .dw0dy(ts_dw0dy), .dw1dy(ts_dw1dy), .dw2dy(ts_dw2dy),
        .Wu_0(ts_Wu_0), .Wv_0(ts_Wv_0), .Wr_0(ts_Wr_0), .Wg_0(ts_Wg_0), .Wb_0(ts_Wb_0), .Wa_0(ts_Wa_0),
        .dWudx(ts_dWudx), .dWvdx(ts_dWvdx), .dWrdx(ts_dWrdx), .dWgdx(ts_dWgdx), .dWbdx(ts_dWbdx), .dWadx(ts_dWadx),
        .dWudy(ts_dWudy), .dWvdy(ts_dWvdy), .dWrdy(ts_dWrdy), .dWgdy(ts_dWgdy), .dWbdy(ts_dWbdy), .dWady(ts_dWady));

    // ── blend datapath (byte-identical to blt_tri.sv:121-148 / blt_blend.sv) ──────
    // [pipeline] The blend USED to be a single combinational block (blt_blend, driven
    // in one S_TRI_WR cycle): ca_q -> tint (texel*cr / red255) -> alpha-combine
    // ea=(ca*g_alpha)/255 -> per-channel MAC -> /255 reduce -> RGB565 pack ->
    // tri_fb_wr_pix. That whole chain in one fabric-clock cycle was the -27.884ns
    // setup violator. It is now split across three register stages A/B/C exactly like
    // comp_mixer (S_TRI_WR -> S_TRI_WR2 -> S_TRI_WR3). blt_blend.sv is kept UNCHANGED
    // (still used by the tb_tri_mixer_equiv combinational spike); the same arithmetic
    // is reproduced here, staged, with these identical divide-free reductions:
    // [STA] red255 was literally `(m + (m>>8)) >> 8` on the full 18-bit m, which
    // Quartus built as TWO cascaded 18-bit carry chains. Only bits [13:8] of the sum
    // survive the >>8, so the low byte matters solely through its carry. Splitting m
    // into mh=m>>8 / ml=m[7:0] gives the identity
    //     (m + (m>>8)) >> 8  ==  mh + ((ml + mh) >> 8)
    // — same result, but the adds are 10-bit instead of 18-bit. Verified BIT-EXACT by
    // exhaustive sweep over the whole 17-bit input domain (131072/131072 match).
    function automatic [5:0] red255(input [16:0] t);
        reg [17:0] m; reg [9:0] mh; reg [9:0] ml;
        begin
            m   = {1'b0,t} + 18'd128;
            mh  = m[17:8];
            ml  = {2'b0, m[7:0]};
            red255 = (mh + ((ml + mh) >> 8));
        end
    endfunction
    function automatic [4:0] red31 (input [11:0] t); reg [12:0] m; begin m={1'b0,t}+13'd16;  red31 =(m+(m>>5))>>5; end endfunction
    function automatic [5:0] red63 (input [12:0] t); reg [13:0] m; begin m={1'b0,t}+14'd32;  red63 =(m+(m>>6))>>6; end endfunction
    // per-channel colour-mod: div255_round(ch*mod)
    //
    // [STA] This is THE fabric-clock critical path: all 12 violated setup paths of the
    // 2026-07-28 build (worst -0.276 ns) ran b_c{r,g,b} -> DSP multiply -> Add72 (m+128,
    // 18 bit) -> Add73 (m+(m>>8), 18 bit) -> b1_ts{r,g,b}. Calling the generic 17-bit
    // red255() here threw away the operand bound: ch<=63 and mod<=255, so the product is
    // at most 16065 and m=t+128 at most 16193 — mh fits in 7 bits and ml+mh<=318, i.e.
    // the ">>8" is a single CARRY, not an adder. Written out that way the two 18-bit
    // chains collapse to one 9-bit add plus two conditional increments.
    //
    // Both simplifications are exact, not approximations:
    //   m  = t+128            -> ml = {~t[7], t[6:0]}   (t[7:0]+128 mod 256)
    //                            mh = t[13:8] + t[7]    (the carry out of that)
    // Verified BIT-EXACT against the previous red255(ch*mod) over ALL 64x256 = 16384
    // (ch,mod) pairs, and against round(ch*mod/255) over the same domain: 0 mismatches.
    function automatic [5:0] modch(input [5:0] ch, input [7:0] mod);
        reg [13:0] t; reg [6:0] mh; reg [8:0] ml_mh;
        begin
            t      = ch * mod;                       // <= 16065, 14 bits
            mh     = {1'b0, t[13:8]} + {6'd0, t[7]}; // (t+128) >> 8
            ml_mh  = {1'b0, ~t[7], t[6:0]} + {2'd0, mh}; // (t+128)[7:0] + mh
            modch  = mh[5:0] + {5'd0, ml_mh[8]};     // mh + carry
        end
    endfunction

    // bbox-max (from raw verts, matching blt_tri.c: (hx+ONE-1)>>SUB clamp FB-1)
    wire signed [15:0] tri_hx = (tri_vx0>tri_vx1)?((tri_vx0>tri_vx2)?tri_vx0:tri_vx2)
                                                 :((tri_vx1>tri_vx2)?tri_vx1:tri_vx2);
    wire signed [15:0] tri_hy = (tri_vy0>tri_vy1)?((tri_vy0>tri_vy2)?tri_vy0:tri_vy2)
                                                 :((tri_vy1>tri_vy2)?tri_vy1:tri_vy2);
    wire signed [31:0] tri_maxx_c = ($signed(tri_hx) + 32'sd15) >>> 4;
    wire signed [31:0] tri_maxy_c = ($signed(tri_hy) + 32'sd15) >>> 4;
    // Clamp to the ACTUAL framebuffer extent (`FB_W-1/`FB_H-1), never a retyped
    // dimension: the old hardcoded 319/239 was a stale 320x240 leftover. Because the
    // destination address (dst_qw_q = pys*`FB_STRIDE_QW + pxs>>2) has no bounds guard,
    // a walk that overran to px=288..319 wrote row py+1 columns 0..31 — device-visible
    // as the right-edge overhang of a scrolling layer wrapping onto the left of the
    // screen with a hard vertical seam at x=32. The refmodel (blt_tri.c: maxx>=
    // BLT_FB_WIDTH -> BLT_FB_WIDTH-1) always clamped correctly; no trilist bench places
    // a vertex past x=287, so the bit-exact gate had zero coverage of the overhang.
    localparam signed [31:0] TRI_MAXX_LIM = `FB_W - 1;   // 287
    localparam signed [31:0] TRI_MAXY_LIM = `FB_H - 1;   // 215
    wire [15:0] tri_maxx_cl = (tri_maxx_c > TRI_MAXX_LIM) ? TRI_MAXX_LIM[15:0]
                            : (tri_maxx_c < 0 ? 16'd0 : tri_maxx_c[15:0]);
    wire [15:0] tri_maxy_cl = (tri_maxy_c > TRI_MAXY_LIM) ? TRI_MAXY_LIM[15:0]
                            : (tri_maxy_c < 0 ? 16'd0 : tri_maxy_c[15:0]);
    // [span walk] ...and a bbox-max that came out NEGATIVE means the triangle is
    // entirely off-screen left/above. The clamps above cannot express that (tri_maxx
    // is unsigned) and used to RAISE it to 0, so S_TRI_SWAIT's (ts_ox > tri_maxx)
    // guard did not fire and the walk ground through a degenerate 1-column strip: 12
    // triangles / 1,160 wasted coverage tests per quiet frame (Task 5 §3.3). The
    // refmodel is unambiguous -- blt_tri.c clamps maxx only on the HIGH side, so
    // `for(px=minx; px<=maxx)` with minx clamped to 0 and maxx<0 runs ZERO iterations
    // -- hence rejecting here is bit-exact, not a behaviour change. Fixed with the span
    // walk rather than after it because the span walk would otherwise make those
    // triangles COST MORE (an empty row is a seek + a row step, i.e. ~2 cycles/row,
    // where the bbox walk paid 1): leaving it would have booked a regression.
    wire tri_bbox_neg_c = (tri_maxx_c < 0) || (tri_maxy_c < 0);

    // ══ [span walk] per-row covered-interval traversal ═════════════════════════
    //  Replaces the bbox scan (one coverage test per bbox column, ~2.03x the covered
    //  pixels on the captured quiet frame). Each edge function is LINEAR in x --
    //  w_k(x) = w_k(x0) + (x-x0)*dw_k/dx -- so per row the covered set {x : w0>=0 &&
    //  w1>=0 && w2>=0} is the intersection of three half-lines, i.e. a single
    //  CONTIGUOUS interval. The walk therefore only has to find that interval's LEFT
    //  end, emit rightward until coverage drops (or tri_maxx), and move on.
    //
    //  NO DIVIDE. The obvious closed form for the interval end is
    //  ceil(-w_k/dw_kdx) -- a per-row divide, and comb divide is this design's known
    //  STA failure mode (see blt_tri_setup's UNROLL=1 note). Instead the endpoint is
    //  found INCREMENTALLY from the PREVIOUS row's endpoint, using the same adders the
    //  walk already had: the left end s(y) of a triangle moves by |s(y+1)-s(y)|
    //  columns per row, and summed over the triangle that telescopes to the total
    //  variation of a convex boundary, i.e. O(bbox width) -- NOT O(width) per row.
    //  Measured: 2.9 seek+rowstep cycles per row on the quiet frame.
    //
    //  DIRECTION IS LOCKED per row (sk_dir_set/sk_left), which is a correctness
    //  requirement, not a tuning knob. Deciding the direction fresh each cycle from
    //  the violated edges LIVELOCKS on an EMPTY row: with a lower bound s=5 and an
    //  upper bound e=4, x=4 sees only the lower bound violated ("go right") and x=5
    //  only the upper ("go left"), forever. No single x sees both violated, so the
    //  conflict test cannot catch it. A locked direction makes px strictly monotone
    //  within a row, so the seek is bounded by the bbox width by construction. (This
    //  was found by the Python cycle-model of this FSM, which hit its runaway guard.)
    //
    //  BIT-EXACTNESS is by construction, not by tolerance: the emitted pixel SET and
    //  ORDER are identical to the bbox walk (same rows in increasing y, same covered
    //  x in increasing order), and the accumulator values are path-independent exact
    //  integer sums of the same per-x/per-y deltas. The seek never leaves
    //  [tri_ox, tri_maxx], so it visits no position the bbox walk did not.
    //  Cross-checked against the refmodel's own comparisons (blt_tri.c: edge() sign
    //  tests with top_left() bias at pixel centres) by the strict bit-exact gate.

    // Coverage of the current cursor, and of its LEFT NEIGHBOUR (the registered w*m).
    wire sk_cov  = (w0  >= 0) && (w1  >= 0) && (w2  >= 0);
    wire sk_covm = (w0m >= 0) && (w1m >= 0) && (w2m >= 0);
    // Which way an uncovered cursor must move to reach the interval. An edge violated
    // with dw/dx>0 is a LOWER bound (go right); with dw/dx<0 an UPPER bound (go left);
    // with dw/dx==0 the edge is x-independent, so a violation means the WHOLE row is
    // out (sk_block) -- that is the horizontal-edge case.
    wire sk_need_r = ((w0<0) && (ts_dw0dx>0)) || ((w1<0) && (ts_dw1dx>0)) || ((w2<0) && (ts_dw2dx>0));
    wire sk_need_l = ((w0<0) && (ts_dw0dx<0)) || ((w1<0) && (ts_dw1dx<0)) || ((w2<0) && (ts_dw2dx<0));
    wire sk_block  = ((w0<0) && (ts_dw0dx==0))|| ((w1<0) && (ts_dw1dx==0))|| ((w2<0) && (ts_dw2dx==0));
    // The row's direction: locked after the first A_SEEK cycle. A cursor that is
    // already covered can only be at-or-right-of the interval's left end, so it seeks
    // LEFT for minimality; an uncovered cursor with an upper bound violated is right
    // of the interval and also seeks left; otherwise it is left of it and seeks right.
    wire sk_l = sk_dir_set ? sk_left : (sk_cov || sk_need_l);

    // ── [pipeline stage 3b] A-pipeline flow control ───────────────────────────────
    // ax_room : a credit is available, so A_PIX may dispatch this cycle.
    // ax_disp : a covered pixel IS being dispatched this cycle (the single definition —
    //           A_PIX's dispatch branch, the credit increment and the ax_v shift all
    //           key off this one wire so they cannot drift out of step).
    // ax_pop  : pb takes a payload off the FIFO this cycle (returns the credit).
    // ax_busy : the pipeline still holds at least one pixel. LOAD-BEARING: the triangle
    //           drain test must include it, or S_TRI_NEXT can be entered with up to six
    //           pixels still in flight — they would be pushed into the FIFO after the
    //           next triangle's setup has already reset pf_wr/pf_rd, i.e. silently
    //           dropped or written with the wrong triangle's constants.
    wire ax_room = (ax_cred < TEXFIFO_D);
    wire ax_busy = |ax_v;
    wire ax_disp = (state==S_TRI_PIX) && (pa==A_PIX) && tri_cv && sk_cov && ax_room;
    wire ax_pop  = (state==S_TRI_PIX) && (pb==B_IDLE) && !pf_empty;

    // [span walk] one column right: the current edges BECOME the left-neighbour set
    // (a copy, no adder), and the live accumulators take one dx step.
    task automatic step_right;
        begin
            tri_px <= tri_px + 16'd1;
            w0m<=w0; w1m<=w1; w2m<=w2;
            w0<=w0+ts_dw0dx; w1<=w1+ts_dw1dx; w2<=w2+ts_dw2dx;
            Wu<=Wu+ts_dWudx; Wv<=Wv+ts_dWvdx; Wr<=Wr+ts_dWrdx;
            Wg<=Wg+ts_dWgdx; Wb<=Wb+ts_dWbdx; Wa<=Wa+ts_dWadx;
        end
    endtask
    // [span walk] one column left: the left-neighbour set BECOMES the current edges,
    // and the new left neighbour is one further dx back. Only the seek moves left, so
    // the attribute accumulators need the subtract only here.
    task automatic step_left;
        begin
            tri_px <= tri_px - 16'd1;
            w0<=w0m; w1<=w1m; w2<=w2m;
            w0m<=w0m-ts_dw0dx; w1m<=w1m-ts_dw1dx; w2m<=w2m-ts_dw2dx;
            Wu<=Wu-ts_dWudx; Wv<=Wv-ts_dWvdx; Wr<=Wr-ts_dWrdx;
            Wg<=Wg-ts_dWgdx; Wb<=Wb-ts_dWbdx; Wa<=Wa-ts_dWadx;
        end
    endtask
    // [span walk] pin the row-start snapshot to wherever the seek finished. This is
    // what makes the next row's seek short: A_ROWY restarts from the SPAN START, not
    // from tri_ox, and not from the row's right end either (that would cost a whole
    // span's worth of leftward steps per row -- the flaw that makes a naive span walk
    // no cheaper than the bbox scan). Register-to-register copies: no logic.
    task automatic snap_row;
        begin
            row_px<=tri_px;
            row_w0<=w0; row_w1<=w1; row_w2<=w2;
            row_w0m<=w0m; row_w1m<=w1m; row_w2m<=w2m;
            row_Wu<=Wu; row_Wv<=Wv; row_Wr<=Wr; row_Wg<=Wg; row_Wb<=Wb; row_Wa<=Wa;
        end
    endtask
    // [span walk] next row, from the row-start snapshot (NOT from the live cursor,
    // which the emit phase has already run to the span's right end). Same per-y delta
    // adds the old row-wrap did, feeding both the live and the snapshot copies.
    task automatic step_row;
        begin
            tri_py <= tri_py + 16'd1;
            tri_px <= row_px;
            row_w0<=row_w0+ts_dw0dy; w0<=row_w0+ts_dw0dy;
            row_w1<=row_w1+ts_dw1dy; w1<=row_w1+ts_dw1dy;
            row_w2<=row_w2+ts_dw2dy; w2<=row_w2+ts_dw2dy;
            row_w0m<=row_w0m+ts_dw0dy; w0m<=row_w0m+ts_dw0dy;
            row_w1m<=row_w1m+ts_dw1dy; w1m<=row_w1m+ts_dw1dy;
            row_w2m<=row_w2m+ts_dw2dy; w2m<=row_w2m+ts_dw2dy;
            row_Wu<=row_Wu+ts_dWudy; Wu<=row_Wu+ts_dWudy;
            row_Wv<=row_Wv+ts_dWvdy; Wv<=row_Wv+ts_dWvdy;
            row_Wr<=row_Wr+ts_dWrdy; Wr<=row_Wr+ts_dWrdy;
            row_Wg<=row_Wg+ts_dWgdy; Wg<=row_Wg+ts_dWgdy;
            row_Wb<=row_Wb+ts_dWbdy; Wb<=row_Wb+ts_dWbdy;
            row_Wa<=row_Wa+ts_dWady; Wa<=row_Wa+ts_dWady;
        end
    endtask

    always @(posedge clk) begin
        if (rst) begin
            state<=S_POLL_SUBMIT; bm_rd<=0; bm_wr<=0; bm_be<=0;
            bm_addr<=0; bm_din<=0; idle<=1; frame_counter<=0;
            cmd_idx<=0; fetch_k<=0; submit_reg<=0; done_reg<=0; rd_issued<=0;
            rw_wd<=22'd0; rd_reissue_cnt<=8'd0;
            perf_frame_cyc<=32'd0; perf_pipe_cyc<=32'd0;
            perf_tri_cyc<=32'd0; perf_texwait_cyc<=32'd0; perf_covered_px<=32'd0;
            throttle_cnt<=8'd0; throttle_cfg<=8'd0;
            ring_sel<=1'b0;                   // [Phase 1 A3] default to ring A
            pipe_start<=1'b0;
            src_sdram_we<=1'b0; src_sdram_din<=16'd0; stage_waddr_fsm<=27'd0;
            stage_we_burst_fsm<=1'b0; stage_din64_fsm<=64'd0;
            stage_barrier<=1'b0; barrier_seen_busy<=1'b0;
            fb_dma_start<=1'b0; // [#104] vs edge-detect moved to the dedicated vs_sync 3-FF chain
            snap_guard<=6'd0;
            tri_busy<=1'b0; tri_setup_start<=1'b0;
            tri_bbox_neg<=1'b0; sk_dir_set<=1'b0; sk_left<=1'b0;
            ax_v<=6'd0; ax_cred<={AX_CW{1'b0}};   // [pipeline stage 3b]
            comp_target<=`BLT_TARGET_WORK;   // [app-surface v1] default target = WORK
            tri_p0_rd<=1'b0; tri_fb_rd_en<=1'b0; tri_fb_wr_en<=1'b0;
            tri_surf_rd_en<=1'b0; tri_src_surface<=1'b0;   // [app-surface v1]
            pa<=A_PIX; pb<=B_IDLE; pf_wr<=0; pf_rd<=0;
            fill_busy<=1'b0; tq_valid<={TEXQ_N{1'b0}}; last_pf_qtag<=24'hFFFFFF;
            wd_stall<=13'd0; wd_fire_count<=24'd0;
        end else begin
            bm_rd<=1'b0;
            pipe_start<=1'b0;     // single-cycle blit_start pulse to comp_pipeline
            tri_setup_start<=1'b0;// single-cycle setup start pulse
            tri_p0_rd<=1'b0;      // single-cycle P_SRC texel read pulse
            tri_fb_rd_en<=1'b0;   // single-cycle comp_fbram dst read
            tri_fb_wr_en<=1'b0;   // single-cycle comp_fbram composite write
            tri_surf_rd_en<=1'b0; // [app-surface v1] single-cycle surface texel read
            stage_barrier<=1'b0;  // single-cycle barrier request unless re-asserted in S_STAGE_BARRIER
            src_sdram_we<=1'b0;   // single-cycle write request unless re-asserted (held in S_STAGE_WR_WAIT)
            stage_we_burst_fsm<=1'b0; // single-cycle burst-write request unless re-asserted
            fb_dma_start<=1'b0;   // single-cycle vblank WORK->DDR framebuffer-DMA trigger
            // [#104] vs_rise now comes from the dedicated vs_sync 3-FF synchronizer

            // per-frame perf accumulation (idle=1 only while polling between frames;
            // a frame-start reset in S_CHK_NEW overrides this on its cycle via NBA).
            if (!idle) begin
                perf_frame_cyc <= perf_frame_cyc + 32'd1;
                if (pipe_busy) perf_pipe_cyc <= perf_pipe_cyc + 32'd1;
                // [profiling] all TRILIST states are 45..63 (highest state values)
                if (state >= S_TRI_VFETCH) perf_tri_cyc <= perf_tri_cyc + 32'd1;
                // cycles the consume sub-FSM (pb) stalls in B_WAIT waiting on the per-pixel
                // texel fetch (a demand/prefetch fill in flight). With the A||B overlap
                // these are cycles where A may still be doing productive address-gen work,
                // so dpath=(tri-texwait) is a conservative proxy; tri_cyc/covered is the true
                // wall-clock throughput. (Counting B_WAIT rather than a tq_hit() read keeps
                // the wide tag mux off the perf-counter's combinational path.)
                if ((state==S_TRI_PIX) && (pb==B_WAIT))
                    perf_texwait_cyc <= perf_texwait_cyc + 32'd1;
            end

            // [fill watchdog] count continuous fill-stall cycles; saturate at WD_TIMEOUT.
            if (fill_busy && !p0_ok) begin
                if (wd_stall != WD_TIMEOUT) wd_stall <= wd_stall + 13'd1;
            end else wd_stall <= 13'd0;

            // [startup-wedge fix] S_RD_WAIT dwell counter (reissue watchdog). Reset
            // outside the state; S_RD_WAIT's reissue branch also clears it (that NBA
            // executes later in this block, so it wins on the reissue cycle).
            if (state != S_RD_WAIT) rw_wd <= 22'd0;
            else if (rw_wd != RW_WD_MAX) rw_wd <= rw_wd + 22'd1;

            case (state)
            S_POLL_SUBMIT: begin
                idle<=1; bm_rd<=1; bm_addr<=`BLTCTRL_QW+`C_SUBMIT;
                rd_ret<=S_POLL_DONE; state<=S_RD_WAIT;
            end
            S_POLL_DONE: begin
                submit_reg<=rd_data[31:0];
                bm_rd<=1; bm_addr<=`BLTCTRL_QW+`C_DONE;
                rd_ret<=S_CHK_NEW; state<=S_RD_WAIT;
            end
            S_CHK_NEW: begin
                done_reg<=rd_data[31:0];
                if (rd_data[31:0]==submit_reg) state<=S_POLL_SUBMIT;   // idle: keep polling
                else begin
                    idle<=0; bm_rd<=1; bm_addr<=`BLTCTRL_QW+`C_CMDCOUNT;
                    rd_ret<=S_GOT_CMDCNT; state<=S_RD_WAIT;
                    comp_target<=`BLT_TARGET_WORK;   // [app-surface v1] each frame begins targeting WORK
                    perf_frame_cyc<=32'd0; perf_pipe_cyc<=32'd0;   // frame start: reset perf
                    perf_tri_cyc<=32'd0; perf_texwait_cyc<=32'd0;   // [profiling] reset per-frame
                    perf_covered_px<=32'd0;                        // [Phase 1 A4] per-frame too
                end
            end
            S_GOT_CMDCNT: begin
                cmd_count<=rd_data[31:0];
                bm_rd<=1; bm_addr<=`BLTCTRL_QW+`C_TARGET;
                rd_ret<=S_GOT_TARGET; state<=S_RD_WAIT;
            end
            S_GOT_TARGET: begin
                target_buf<=rd_data[1:0];
                // 0/1 -> framebuffer BUF0/BUF1. (The off-screen bg-cache pass, C_TARGET==2
                // -> CACHE_QW, is retired: the bg-cache is disabled and single-buffer mode
                // never emits target 2.)
                target_base<=(rd_data[0] ? `FB1_QW : `FB0_QW);
                bm_rd<=1; bm_addr<=`BLTCTRL_QW+`C_FLAGS;
                rd_ret<=S_GOT_FLAGS; state<=S_RD_WAIT;
            end
            S_GOT_FLAGS: begin
                cfg_flags<=rd_data[31:0];
                // fetch C_SRCSEL next (appended control word). bit0 (source mux) is
                // now dead — source is always SDRAM — but the word still carries the
                // f2h write-throttle in bits[15:8], so we still read it.
                bm_rd<=1; bm_addr<=`BLTCTRL_QW+`C_SRCSEL;
                rd_ret<=S_GOT_SRCSEL; state<=S_RD_WAIT;
            end
            S_GOT_SRCSEL: begin
                // [collapse-single-source] bit0 (DDR3-vs-SDRAM source select) ignored:
                // the source read is hardwired to SDRAM. Only the throttle field is used.
                throttle_cfg<=rd_data[15:8];      // [#34] f2h write-throttle (spare bits)
                // [Phase 1 A3] Ring select. Latched here in the control-block prologue,
                // which runs before any command is fetched, so the whole frame reads one
                // ring. Bits 0/1 remain dead (see the comments above/below).
                ring_sel<=rd_data[`C_RINGSEL_BIT];
                // C_PIPE bit (bit1) is also a documented no-op: comp_pipeline is the
                // sole renderer and every FILL/BLIT routes to it unconditionally.
                bm_rd<=1; bm_addr<=`BLTCTRL_QW+`C_CLEAR;
                rd_ret<=S_GOT_CLEAR; state<=S_RD_WAIT;
            end
            S_GOT_CLEAR: begin
                clear_color<=rd_data[15:0];
                if (cfg_flags[0]) begin
                    // [FB-in-BRAM] CLEAR-before-list: the old bm_* SDRAM clear loop
                    // (S_CLR_WR, now dead) wrote the SDRAM FB, which is no longer the
                    // framebuffer. Route the clear through comp_pipeline as a full-screen
                    // FILL(clear_color) so it writes the on-chip comp_fbram via fb_wr_*.
                    c_opcode    <= 8'd2;          // OP_FILL
                    c_blend     <= 8'd0;
                    c_format    <= 8'd0;
                    c_flags     <= 8'd0;          // no colour-mod / flip / key
                    c_src_off   <= 32'd0; c_src_stride <= 16'd0;
                    c_src_x     <= 16'd0; c_src_y <= 16'd0;
                    c_w         <= `FB_W; c_h <= `FB_H;
                    c_colorkey  <= 16'd0; c_alpha <= 8'd0;
                    c_color     <= rd_data[15:0]; // clear_color is the FILL colour
                    c_cmod_r    <= 8'd255; c_cmod_g <= 8'd255; c_cmod_b <= 8'd255; // identity
                    c_dst_x     <= 16'sd0; c_dst_y <= 16'sd0;
                    state       <= S_CLR_FILL;
                end
                else begin cmd_idx<=0; fetch_k<=0; state<=S_FETCH; end
            end
            // Dispatch the full-screen clear FILL to comp_pipeline, then start the
            // ring command list (mirrors the FILL/BLIT dispatch in S_SETUP, but the
            // post-blit return is S_FETCH instead of S_NEXT_CMD).
            S_CLR_FILL: begin
                pipe_start <= 1'b1;
                state      <= S_CLR_FILL_WAIT;
            end
            S_CLR_FILL_WAIT: if (p_blit_done) begin
                cmd_idx<=0; fetch_k<=0; state<=S_FETCH;
            end
            // (dead since FB-in-BRAM — kept to avoid disturbing wr_ret references)
            S_CLR_WR: begin
                if (clr_idx==`FB_QWORDS) begin
                    cmd_idx<=0; fetch_k<=0; state<=S_FETCH;
                end else begin
                    bm_wr<=1; bm_be<=8'hFF; bm_addr<=target_base+clr_idx;
                    bm_din<={4{clear_color}}; clr_idx<=clr_idx+1;
                    wr_ret<=S_CLR_WR; state<=S_WR_WAIT;
                end
            end

            S_FETCH: begin
                if (cmd_idx>=cmd_count) state<=S_FRAME_VCTRL;
                else begin
                    fetch_k<=0; bm_rd<=1; bm_addr<=ring_base+cmd_idx*4;
                    rd_ret<=S_COLLECT; state<=S_RD_WAIT;
                end
            end
            S_COLLECT: begin
                cmd_qw[fetch_k]<=rd_data;
                if (fetch_k==2'd3) state<=S_DECODE;
                else begin
                    bm_rd<=1; bm_addr<=ring_base+cmd_idx*4+(fetch_k+2'd1);
                    fetch_k<=fetch_k+2'd1; rd_ret<=S_COLLECT; state<=S_RD_WAIT;
                end
            end
            S_DECODE: begin
                c_opcode    <= cmd_qw[0][7:0];
                c_blend     <= cmd_qw[0][15:8];
                c_format    <= cmd_qw[0][23:16];
                c_flags     <= cmd_qw[0][31:24];
                c_src_off   <= cmd_qw[0][63:32];
                c_src_stride<= cmd_qw[1][15:0];
                c_src_x     <= cmd_qw[1][31:16];
                c_w         <= cmd_qw[1][47:32];
                c_h         <= cmd_qw[1][63:48];
                c_src_y     <= cmd_qw[2][15:0];
                c_dst_x     <= cmd_qw[2][47:32];
                c_dst_y     <= cmd_qw[2][63:48];
                c_colorkey  <= cmd_qw[3][15:0];   // u32[6][15:0]
                c_alpha     <= cmd_qw[3][23:16];  // u32[6][23:16]
                c_color     <= cmd_qw[3][47:32];  // u32[7][15:0]
                // [v2 escape-elim] color-mod (tint) bytes. WIRE-ABI CONTRACT (host
                // blt_pack_cmd, RTL decode, and the C model MUST agree): the RGB888
                // tint reuses the two free reserved bytes of qw[3] —
                //   cb = u32[6][31:24]  (the legacy/unused "priority" byte)
                //   cr = u32[7][23:16]  (color high byte 0)
                //   cg = u32[7][31:24]  (color high byte 1)
                // i.e. u32[6] = colorkey | alpha<<16 | cb<<24,
                //      u32[7] = color    | cr<<16    | cg<<24.
                c_cmod_b    <= cmd_qw[3][31:24];  // u32[6][31:24]
                c_cmod_r    <= cmd_qw[3][55:48];  // u32[7][23:16]
                c_cmod_g    <= cmd_qw[3][63:56];  // u32[7][31:24]
                state<=S_SETUP;
            end
            S_SETUP: begin
                if (c_opcode==OP_END)       state<=S_FRAME_VCTRL;
                else if (c_opcode==OP_NOP)  state<=S_NEXT_CMD;
                else if (c_opcode==OP_SET_TARGET) begin
                    // [app-surface v1] Bind the composite render target. The target id
                    // rides the command's color low byte (c_color = cmd_qw[3][47:32]).
                    // Only comp_target moves — target_buf (display flip) is untouched.
                    comp_target <= c_color[1:0];   // BLT_TARGET_WORK(0) / BLT_TARGET_APPSURF(2)
                    state<=S_NEXT_CMD;
                end
                else if (c_opcode==OP_STAGE) begin
                    // BLT_OP_STAGE: copy {c_h,c_w} bytes from DDR3 SRC_QW+off into
                    // SDRAM. DDR3 read base = c_src_off. SDRAM dest = u32[2]
                    // ({c_src_x,c_src_stride}) when F_STAGE_DST is set (#32 decoupled),
                    // else c_src_off (#19 behavior). size = {h,w}; 0-byte = no-op.
                    stage_off  <= c_src_off;
                    stage_sdram_off <= (c_flags & F_STAGE_DST) ? {c_src_x, c_src_stride}
                                                               : c_src_off;
                    stage_size <= {c_h, c_w};
                    stage_byte <= 32'd0;
                    if ({c_h, c_w} == 32'd0) state<=S_NEXT_CMD;
                    else                     state<=S_STAGE_RD;
                end
                else if (c_opcode==OP_TRILIST) begin
                    // BLT_OP_TRILIST: composite `w` textured triangles into comp_fbram.
                    // Header reuse: w=tri_count, {c_dst_y,c_dst_x}=vertex byte offset (EOFF),
                    // c_src_off/stride=tex page+row bytes, c_src_x/y=tex_w/tex_h,
                    // c_blend/c_alpha/c_colorkey = blend params.
                    tri_count    <= c_w;
                    tri_idx      <= 16'd0;
                    tri_entry_qw <= `SRC_QW + ({c_dst_y, c_dst_x} >> 3);
                    tri_busy     <= 1'b1;
                    // [app-surface v1] texel source = off-screen APPSURF surface when set,
                    // else the SDRAM heap. Stable for the whole command (drains before next).
                    tri_src_surface <= (c_flags & F_SRC_SURFACE) != 8'd0;
                    if (c_w == 16'd0) begin tri_busy<=1'b0; state<=S_NEXT_CMD; end
                    else                    state<=S_TRI_VFETCH;
                end
                else if (empty)             state<=S_NEXT_CMD;
                else begin
                    // FILL/BLIT -> comp_pipeline, the sole render datapath. The decoded
                    // c_* + target_base are stable; pipe_start pulses one cycle and
                    // pipe_busy hands comp_pipeline the mem_* / src_sdram_* bus.
                    pipe_start <= 1'b1;
                    state      <= S_PIPE_WAIT;
                end
            end
            // ---- BLT_OP_STAGE DDR3->SDRAM copy (issue #19) ----
            // Read one 64-bit beat from DDR3 at SRC_QW + (off+stage_byte)>>3 (the
            // staged region is qword-aligned: off is qword-aligned in practice and
            // stage_byte advances by 8). The shared read master + S_RD_WAIT carry it.
            S_STAGE_RD: begin
                bm_rd<=1; bm_addr<=`SRC_QW + ((stage_off + stage_byte) >> 3);
                rd_ret<=S_STAGE_GOT; state<=S_RD_WAIT;
            end
            // Capture the beat, then issue ONE BL=4 SDRAM burst write of all 4
            // words (instead of 4 single-word writes). The beat is 8-byte aligned
            // (off is qword-aligned; stage_byte steps by 8), so its 4 words share
            // one row + 4 consecutive columns — a single SDRAM burst, never
            // crossing a row boundary.
            S_STAGE_GOT: begin
                stage_beat <= rd_data;
                state<=S_STAGE_WR;
            end
            // Issue one 4-word SDRAM burst write of the current beat at the
            // 8-byte-aligned heap byte address off + stage_byte.
            S_STAGE_WR: begin
                stage_waddr_fsm    <= (stage_sdram_off + stage_byte) & 27'h7FFFFF8; // 8-byte align (#32 decoupled dest)
                stage_din64_fsm    <= stage_beat;
                stage_we_burst_fsm <= 1'b1;
                state<=S_STAGE_WR_WAIT;
            end
            // [#44] cache-ok handshake: HOLD src_sdram_we_burst until the cache STAGE
            // channel (ch1) accepts the qword (src_sdram_ok). The default block
            // deasserts we_burst each cycle, so re-assert it while waiting; on ok,
            // let it drop and advance one beat (or finish). (Earlier this treated the
            // write as immediately accepted because the outputs were unconnected — that
            // dropped writes under cache backpressure -> garbage source atlas.)
            S_STAGE_WR_WAIT: begin
                if (src_sdram_ok) begin
                    // write accepted; advance one beat or finish.
                    if (stage_byte + 32'd8 >= stage_size) state<=S_STAGE_BARRIER;
                    else begin
                        stage_byte <= stage_byte + 32'd8;
                        state<=S_STAGE_RD;
                    end
                end else begin
                    stage_we_burst_fsm <= 1'b1;   // hold the request until ok
                end
            end

            // [stage-barrier] STAGE finished: the atlas is in cache ch1 but not yet
            // in SDRAM, and ch5 (P_SRC) may hold stale lines for these addresses.
            // Pulse stage_barrier (commit ch1 + invalidate ch5) and HOLD until it
            // completes, so the consuming BLIT's source fetch is coherent. (The engine
            // emits STAGE+BLIT in the same frame, so vsync is too late.)
            S_STAGE_BARRIER: begin
                stage_barrier     <= 1'b1;   // one-cycle request
                barrier_seen_busy <= 1'b0;
                // [Lever 1] drop the blitter-local qword cache exactly when jtframe ch5
                // is invalidated — per-command (triangles in a command share the atlas).
                tq_valid          <= {TEXQ_N{1'b0}};
                last_pf_qtag      <= 24'hFFFFFF;   // fresh prefetch filter after invalidation
                state<=S_STAGE_BARRIER_WAIT;
            end
            // Wait for the barrier to actually engage (busy rises) and then finish
            // (busy falls). Releasing on the falling edge guarantees ch1 is committed
            // and ch5 invalidated before the next command can read P_SRC.
            S_STAGE_BARRIER_WAIT: begin
                if (stage_barrier_busy)      barrier_seen_busy <= 1'b1;
                else if (barrier_seen_busy)  state<=S_NEXT_CMD;
            end

            // ════════════════════════════════════════════════════════════════
            //  BLT_OP_TRILIST textured-triangle walk (Task 5)
            // ════════════════════════════════════════════════════════════════
            // Fetch the current triangle's 6 vertex qwords via the shared bm_*
            // read master (S_RD_WAIT). Base qword = tri_entry_qw + tri_idx*6.
            S_TRI_VFETCH: begin
                tri_vk    <= 3'd0;
                tri_vbase <= tri_entry_qw + tri_idx*16'd6;
                bm_rd     <= 1'b1;
                bm_addr   <= tri_entry_qw + tri_idx*16'd6;
                rd_ret<=S_TRI_VCOLLECT; state<=S_RD_WAIT;
            end
            S_TRI_VCOLLECT: begin
                tri_vqw[tri_vk] <= rd_data;
                if (tri_vk==3'd5) state<=S_TRI_DECV;
                else begin
                    bm_rd   <= 1'b1;
                    bm_addr <= tri_vbase + {29'd0, tri_vk} + 32'd1;
                    tri_vk  <= tri_vk + 3'd1;
                    rd_ret<=S_TRI_VCOLLECT; state<=S_RD_WAIT;
                end
            end
            // Unpack the 6 qwords -> 3 vertices. Per vertex, 2 qwords:
            //   qw0 = {v[63:48], u[47:32], y[31:16], x[15:0]}  (x,y s12.4; u,v u12.4)
            //   qw1[31:0] = r | g<<8 | b<<16 | a<<24
            S_TRI_DECV: begin
                tri_vx0<=tri_vqw[0][15:0];  tri_vy0<=tri_vqw[0][31:16];
                tri_vu0<=tri_vqw[0][47:32]; tri_vv0<=tri_vqw[0][63:48];
                tri_vr0<=tri_vqw[1][7:0];   tri_vg0<=tri_vqw[1][15:8];
                tri_vb0<=tri_vqw[1][23:16]; tri_va0<=tri_vqw[1][31:24];
                tri_vx1<=tri_vqw[2][15:0];  tri_vy1<=tri_vqw[2][31:16];
                tri_vu1<=tri_vqw[2][47:32]; tri_vv1<=tri_vqw[2][63:48];
                tri_vr1<=tri_vqw[3][7:0];   tri_vg1<=tri_vqw[3][15:8];
                tri_vb1<=tri_vqw[3][23:16]; tri_va1<=tri_vqw[3][31:24];
                tri_vx2<=tri_vqw[4][15:0];  tri_vy2<=tri_vqw[4][31:16];
                tri_vu2<=tri_vqw[4][47:32]; tri_vv2<=tri_vqw[4][63:48];
                tri_vr2<=tri_vqw[5][7:0];   tri_vg2<=tri_vqw[5][15:8];
                tri_vb2<=tri_vqw[5][23:16]; tri_va2<=tri_vqw[5][31:24];
                state<=S_TRI_SETUP;
            end
            // Pulse blt_tri_setup.start (verts are registered/stable). Also
            // PRE-REGISTER the bbox-max here: tri_maxx_cl/tri_maxy_cl are a
            // combinational max->(+15)->>>4->clamp cloud off the raw verts, and
            // the verts are stable while setup runs its ~54 cycles. Registering
            // them now means the S_TRI_SWAIT seed compares/loads against a REGISTER
            // instead of chaining that whole vertex->bbox cloud into the 48-bit
            // accumulator loads (row_Wa etc.) in one cycle — that chain was the
            // -4.5 ns worst setup path.
            S_TRI_SETUP: begin
                tri_setup_start <= 1'b1;
                tri_maxx <= tri_maxx_cl; tri_maxy <= tri_maxy_cl;
                // [span walk] register the off-left/above reject alongside the clamps
                // it cannot express (see tri_bbox_neg_c), for the same reason: keep the
                // raw-vertex compare cloud out of the S_TRI_SWAIT seed cycle.
                tri_bbox_neg <= tri_bbox_neg_c;
                state<=S_TRI_SWAIT;
            end
            // Wait for setup valid; seed bbox + running accumulators at (ox,oy).
            // Skip degenerate, off-left/above (negative bbox-max) or fully-off
            // (min>max) triangles.
            S_TRI_SWAIT: if (ts_valid) begin
                // guard against registered bbox-max / bbox-neg (set at S_TRI_SETUP)
                if (ts_degenerate || tri_bbox_neg || (ts_ox > tri_maxx) || (ts_oy > tri_maxy))
                    state<=S_TRI_NEXT;
                else begin
                    tri_ox <= ts_ox;
                    tri_px <= ts_ox;      tri_py <= ts_oy;
                    row_px <= ts_ox;
                    tri_cv <= 1'b1;        // cursor starts inside the bbox
                    // tri_maxx/tri_maxy already registered at S_TRI_SETUP
                    w0<=ts_w0_0; w1<=ts_w1_0; w2<=ts_w2_0;
                    row_w0<=ts_w0_0; row_w1<=ts_w1_0; row_w2<=ts_w2_0;
                    // [span walk] left-neighbour edges at x = ox-1. One column outside
                    // the bbox, and never CONSULTED there (the seek's left move is
                    // gated on tri_px > tri_ox), but seeded exactly rather than left
                    // undefined so no branch can ever depend on an x.
                    w0m<=ts_w0_0-ts_dw0dx; w1m<=ts_w1_0-ts_dw1dx; w2m<=ts_w2_0-ts_dw2dx;
                    row_w0m<=ts_w0_0-ts_dw0dx; row_w1m<=ts_w1_0-ts_dw1dx;
                    row_w2m<=ts_w2_0-ts_dw2dx;
                    Wu<=ts_Wu_0; Wv<=ts_Wv_0; Wr<=ts_Wr_0; Wg<=ts_Wg_0; Wb<=ts_Wb_0; Wa<=ts_Wa_0;
                    row_Wu<=ts_Wu_0; row_Wv<=ts_Wv_0; row_Wr<=ts_Wr_0;
                    row_Wg<=ts_Wg_0; row_Wb<=ts_Wb_0; row_Wa<=ts_Wa_0;
                    // [pipeline stage 3a] arm both sub-FSMs empty for this triangle
                    // (the qword cache persists across triangles in a command; it is
                    // dropped only at the per-command STAGE barrier, not here.)
                    // [span walk] pa starts in A_SEEK, not A_PIX: even the FIRST row
                    // must have its span start located before any pixel is emitted.
                    pa<=A_SEEK; pb<=B_IDLE; pf_wr<=0; pf_rd<=0;
                    sk_dir_set<=1'b0;
                    // [pipeline stage 3b] arm the A pipeline empty with all credits free.
                    // Safe because the previous triangle could only reach S_TRI_NEXT with
                    // ax_busy low and pf_empty high (see the drain test), so nothing is
                    // being discarded here — this is belt-and-braces, matching the
                    // pre-existing pf_wr/pf_rd reset.
                    ax_v<=6'd0; ax_cred<={AX_CW{1'b0}};
                    state<=S_TRI_PIX;   // umbrella S_TRI_RUN: tick pa || pb
                end
            end
            // [pipeline stage 3a] Umbrella "run" state: tick the two concurrent
            // sub-FSMs (pa = address-gen || pb = consume+blend) every cycle until the
            // coverage walk is fully drained, overlapping pixel N's blend/write (pb)
            // with pixel N+1's mul/addr/texel-fetch (pa).
            S_TRI_PIX: begin
                // Always-listening fill catcher: the single outstanding P_SRC read's
                // p0_ok can strobe in ANY cycle after the fill was issued (variable
                // memory latency), possibly while pb is still blending the previous
                // pixel. Latch the returned qword into the BRAM here, independent of
                // pb's state, so the 1-cycle strobe is never missed and fill_busy is
                // cleared to admit the next single-outstanding fill.
                if (fill_busy && p0_ok) begin
                    tq_data[fill_slot]  <= p0_dout;
                    tq_tag[fill_slot]   <= fill_tag;
                    tq_valid[fill_slot] <= 1'b1;
                    fill_busy           <= 1'b0;
                end else if (fill_busy && wd_fire) begin
                    // [fill watchdog] synthesize a completion with STALE tq_data so the
                    // pb FSM re-reads a HIT and makes forward progress (few wrong texels
                    // vs a permanent hang). tq_data intentionally left unwritten.
                    tq_tag[fill_slot]   <= fill_tag;
                    tq_valid[fill_slot] <= 1'b1;
                    fill_busy           <= 1'b0;
                    wd_fire_count       <= (wd_fire_count==24'hFFFFFF) ? wd_fire_count
                                                                       : wd_fire_count + 24'd1;
                end
                // [pipeline stage 3b] credit accounting + the pipeline valid shifter.
                // Written ONCE here, outside both sub-FSM case statements, so there is
                // exactly one driver for each: a dispatch and a pop in the SAME cycle
                // net to zero, which a pair of separate increments/decrements in the two
                // case arms could not express (the later NBA would simply win).
                // Width-agnostic on purpose: the 1-bit ax_disp/ax_pop are zero-extended
                // to ax_cred's width by the assignment's context, so this line survives a
                // TEXFIFO_D change. It was `{3'd0, ax_disp}` -- correct at AX_CW==4 and a
                // silent truncation at any other width.
                ax_cred <= ax_cred + ax_disp - ax_pop;
                ax_v    <= {ax_v[4:0], ax_disp};
                // ==== sub-FSM A: coverage walk (pa) -> the ax_v-clocked mul/addr/issue
                //      pipeline (below the case) -> the payload FIFO ====
                case (pa)
                // [span walk] EMIT phase. A_PIX is only ever entered AT a covered pixel
                // (A_SEEK found the row's span start) or one column past the previous
                // one, so its coverage test is now the SPAN-END test rather than a bbox
                // rejection: the first uncovered cursor ends the row. If covered, LATCH
                // the multiply operands into single-fanout regs (the six W*area_recip
                // products happen in the ax_v[0] stage -> pipelined DSP) and dispatch,
                // advancing the cursor at dispatch (stage-1 decoupling).
                //
                // [pipeline stage 3b] A_PIX now RE-ENTERS ITSELF on a dispatch instead of
                // handing pa down the mul chain, so a span emits one pixel per cycle. Three
                // outcomes, in this priority order:
                //   span end (!sk_cov)        -> A_ROWY. Needs no credit: nothing is issued.
                //   covered  & ax_room        -> dispatch, step the cursor, stay in A_PIX
                //                               (or go straight to A_ROWY at tri_maxx).
                //   covered  & !ax_room       -> HOLD. No cursor step, no counter bump, no
                //                               state change: the cycle is a pure stall
                //                               waiting for pb to return a credit. This is
                //                               the steady state (pb is 6x slower), which is
                //                               why the bench must qualify its "productive
                //                               A_PIX cycle" count with ax_room — see the
                //                               pix_visits note in tb_blitter_trilist_stream.
                A_PIX: begin
                    // [span walk] UNREACHABLE BY CONSTRUCTION, kept as a defensive
                    // landing. tri_cv is now cleared in exactly one place -- A_ROWY's
                    // last row -- and that same cycle sets pa<=A_DONE, so pa is never
                    // A_PIX while tri_cv is 0. Pre-span-walk this WAS the live exit
                    // (advance_cursor cleared tri_cv when the bbox cursor ran out and
                    // A_PIX noticed on the next tick); do not read it as evidence that
                    // the walk still terminates that way. It survives only so a pa
                    // desync (or the `default:` arm) lands somewhere that drains pb
                    // instead of emitting pixels outside the bbox.
                    if (!tri_cv) begin
                        pa<=A_DONE;           // walk exhausted; let B drain
                    end else if (!sk_cov) begin
                        pa<=A_ROWY;           // past the span's right end: next row
                    end else if (ax_room) begin
                        pxs <= tri_px; pys <= tri_py;
                        wu_q <= Wu; wv_q <= Wv; wr_q <= Wr;
                        wg_q <= Wg; wb_q <= Wb; wa_q <= Wa;
                        recip_q <= $signed(ts_area_recip);
                        // A span may run to the bbox's right edge. Do NOT step past it
                        // (the cursor must stay inside the bbox so the seek's clamps and
                        // the accumulator range are unchanged). [pipeline stage 3b] the
                        // old row_pend hand-off through A_ISSUE is gone: pa is free to go
                        // to A_ROWY on the dispatch cycle itself, because the dispatched
                        // pixel's coords/attrs are already latched (pxs/pys/wu_q..) and
                        // A_ROWY's step_row touches only the walk cursor, never the
                        // in-flight pipeline. That also removes one A_PIX->A_ROWY hop.
                        if (tri_px < tri_maxx) step_right;
                        else                   pa<=A_ROWY;
                        // [Phase 1 A4] Count at DISPATCH. This branch is taken exactly once
                        // per COVERED pixel (all three edge functions non-negative), before
                        // any downstream work — the denominator cyc/px needs. Deliberately
                        // NOT counted in the non-covered path: that skips the pixel in one
                        // cycle and is not covered work.
                        perf_covered_px <= perf_covered_px + 32'd1;
                        // pa stays in A_PIX: the next column is tested next cycle.
                    end
                    // else: credit-starved. Hold everything; ax_disp is low so nothing
                    // enters the pipeline and the cursor does not move.
                end
                // [span walk] SEEK phase: find this row's FIRST covered x, one column
                // per cycle, in the row's locked direction. Costs ~2.9 cycles per row
                // (seek + row step) against the ~1 cycle per bbox COLUMN it replaces.
                // See the span-walk block comment above for why the direction is locked
                // and why this is division-free. Leaving the seek in either direction
                // pins the row-start snapshot (snap_row) to the cursor, so the next
                // row starts from THIS row's span start.
                A_SEEK: begin
                    if (!sk_dir_set) begin sk_left <= sk_l; sk_dir_set <= 1'b1; end
                    if (sk_block) begin
                        // an x-independent edge is violated: no x on this row is covered
                        snap_row; pa<=A_ROWY;
                    end else if (sk_l) begin
                        if (sk_cov) begin
                            // covered: this is the span start iff the left neighbour is
                            // NOT covered (or there is no left neighbour inside the bbox)
                            if ((tri_px == tri_ox) || !sk_covm) begin snap_row; pa<=A_PIX; end
                            else                                       step_left;
                        end else if (sk_need_r || (tri_px == tri_ox)) begin
                            // a LOWER bound became violated while walking left (the
                            // interval is empty), or the bbox's left edge was reached
                            snap_row; pa<=A_ROWY;
                        end else step_left;
                    end else begin
                        // rightward: approaching from the left, so the first covered x
                        // IS the span start -- no minimality check needed
                        if (sk_cov) begin snap_row; pa<=A_PIX; end
                        else if (sk_need_l || (tri_px == tri_maxx)) begin
                            snap_row; pa<=A_ROWY;   // interval empty / bbox right edge
                        end else step_right;
                    end
                end
                // [span walk] step to the next row from the row-start snapshot, or
                // finish the triangle. This is the ONLY place tri_cv is cleared.
                A_ROWY: begin
                    if (tri_py < tri_maxy) begin
                        step_row;
                        sk_dir_set <= 1'b0;   // the new row re-locks its own direction
                        pa<=A_SEEK;
                    end else begin
                        tri_cv <= 1'b0;
                        pa<=A_DONE;           // walk exhausted; let B drain
                    end
                end
            // Address-gen drained (cursor exhausted). Idle until B finishes.
            A_DONE: ;
            default: pa<=A_PIX;
            endcase

                // ==== [pipeline stage 3b] the A CHAIN, as six concurrent pipeline
                //      stages instead of six pa states ============================
                // Each block is the body of the ex-pa-state named beside it, verbatim,
                // with its `pa<=` hand-off replaced by the ax_v shift (done once above)
                // and its cross-stage reads re-pointed at the ax*_ carries. Every stage
                // fires INDEPENDENTLY, so up to six different pixels are in flight and a
                // covered pixel is dispatched every cycle the credit allows.
                //
                // BIT-EXACTNESS ARGUMENT (why this cannot change a pixel):
                //  * The arithmetic is byte-for-byte the code that was in the case arms —
                //    same operand widths, same signedness, same rounding constants.
                //  * A value written by stage k and read by stage k+1 keeps its single
                //    register: NBA semantics make the read see the PREVIOUS cycle's write,
                //    which is exactly the hand-off the sequencer had. The three values
                //    whose consumer is 2-3 stages downstream (pxs/pys, itu_q, the colour
                //    + dst pair) are the ONLY ones that had to be carried, and they are
                //    carried by plain register copies.
                //  * Pixels enter and leave in walk order (one FIFO, one push site), so
                //    pb sees the identical payload sequence it saw before.
                //  * The prefetch kick is unchanged and remains best-effort; pb's
                //    B_LOOK/B_FILL demand path is still the correctness backbone.

                // ── stage 1 -> 2 (ex-A_MUL0). Interpolation stage 1b: two 48x24 partial
                // products per lane, split on recip's 24-bit halves (operands >= 0 ->
                // unsigned). Registered -> each is a shallow pipelined multiply; the
                // tile-adder tree of a full 48x48 is broken up and finished next stage.
                if (ax_v[0]) begin
                    pp_u_lo <= $unsigned(wu_q) * recip_q[23:0];  pp_u_hi <= $unsigned(wu_q) * recip_q[47:24];
                    pp_v_lo <= $unsigned(wv_q) * recip_q[23:0];  pp_v_hi <= $unsigned(wv_q) * recip_q[47:24];
                    pp_r_lo <= $unsigned(wr_q) * recip_q[23:0];  pp_r_hi <= $unsigned(wr_q) * recip_q[47:24];
                    pp_g_lo <= $unsigned(wg_q) * recip_q[23:0];  pp_g_hi <= $unsigned(wg_q) * recip_q[47:24];
                    pp_b_lo <= $unsigned(wb_q) * recip_q[23:0];  pp_b_hi <= $unsigned(wb_q) * recip_q[47:24];
                    pp_a_lo <= $unsigned(wa_q) * recip_q[23:0];  pp_a_hi <= $unsigned(wa_q) * recip_q[47:24];
                    ax2_px <= pxs; ax2_py <= pys;   // carry: consumed 2 stages on
                end
                // ── stage 2 -> 3 (ex-A_MUL1). Interpolation stage 1c: recombine the
                // partial products (adds only). mul_X = pp_lo + (pp_hi << 24) ==
                // wX_q * recip_q (bit-exact).
                if (ax_v[1]) begin
                    mul_u <= {24'd0,pp_u_lo} + {pp_u_hi,24'd0};
                    mul_v <= {24'd0,pp_v_lo} + {pp_v_hi,24'd0};
                    mul_r <= {24'd0,pp_r_lo} + {pp_r_hi,24'd0};
                    mul_g <= {24'd0,pp_g_lo} + {pp_g_hi,24'd0};
                    mul_b <= {24'd0,pp_b_lo} + {pp_b_hi,24'd0};
                    mul_a <= {24'd0,pp_a_lo} + {pp_a_hi,24'd0};
                    ax3_px <= ax2_px; ax3_py <= ax2_py;
                end
                // ── stage 3 -> 4 (ex-A_MUL). Interpolation stage 2: round the products
                // and do the nearest-texel clamp; register the clamped coords. The
                // texel-ADDRESS multiply (itv*stride) is deferred to the next stage so it
                // is NOT chained with the wide 96-bit W*recip rounding here in one cycle —
                // that chain was the reported worst path (mul_v[40] -> tri_p0_addr,
                // -5.576 ns).
                if (ax_v[2]) begin
                    // texel coords (u12.4) then nearest-texel with clamp.
                    // FLOOR (plain >>>4), not +8 round: the interpolant is sampled
                    // at pixel centres so it already carries the destination's
                    // +half-pixel; the old +8 landed one texel down-right of GL/SW
                    // nearest on every 1:1 corner-UV draw (device-visible as
                    // mangled glyph text, 2026-07-26). MUST match refmodel
                    // blt_tri.c tex_nearest/tex_nearest_surface. Also drops one
                    // 64-bit add from the texel-address path.
                    rnd_u = (mul_u + (96'sd1<<<39)) >>> 40;
                    rnd_v = (mul_v + (96'sd1<<<39)) >>> 40;
                    itu   = rnd_u >>> 4;
                    itv   = rnd_v >>> 4;
                    // [app-surface v1] clamp bound: for a surface source the texel extent is the
                    // FIXED `FB_W x `FB_H surface (c_src_x/c_src_y are NOT consulted — they may be 0),
                    // matching the refmodel tex_nearest_surface; else the command's tex_w/tex_h.
                    tw1r  = tri_src_surface ? (`FB_W - 16'd1) : (c_src_x - 16'd1);
                    th1r  = tri_src_surface ? (`FB_H - 16'd1) : (c_src_y - 16'd1);
                    if (itu < 0) itu = 0; else if (itu > $signed({16'd0,tw1r})) itu = $signed({16'd0,tw1r});
                    if (itv < 0) itv = 0; else if (itv > $signed({16'd0,th1r})) itv = $signed({16'd0,th1r});
                    itu_q <= itu; itv_q <= itv;   // registered for the next stage's multiply
                    // per-vertex colour
                    rnd_r = (mul_r + (96'sd1<<<39)) >>> 40;
                    rnd_g = (mul_g + (96'sd1<<<39)) >>> 40;
                    rnd_b = (mul_b + (96'sd1<<<39)) >>> 40;
                    rnd_a = (mul_a + (96'sd1<<<39)) >>> 40;
                    cr_q <= rnd_r[7:0]; cg_q <= rnd_g[7:0];
                    cb_q <= rnd_b[7:0]; ca_q <= rnd_a[7:0];
                    // comp_fbram destination qword/lane for this pixel (independent of
                    // the texel-address multiply, so it stays here). Uses THIS pixel's
                    // (px,py), carried down from its dispatch cycle in ax3_px/ax3_py —
                    // pxs/pys now belong to a LATER pixel (the walk kept dispatching).
                    dst_qw_q   <= ax3_py*FB_STRIDE_QW16 + (ax3_px>>2);
                    dst_lane_q <= ax3_px[1:0];
                end
                // ── stage 4 -> 5 (ex-A_ADDR). Interpolation stage 3a: the texel-row
                // multiply itv*stride, REGISTERED in its own cycle. itv_q is a clamped
                // texel row (<= tex_h-1), so the low 16 bits carry the whole value -> a
                // single 16x16 DSP; registering the product (input itv_q + output tex_row)
                // makes it a pipelined DSP. Doing it combinationally into the address add
                // was an ~8.9 ns multiply feeding tri_p0_addr (the -2.0 ns worst path).
                if (ax_v[3]) begin
                    // [app-surface v1] row stride: a surface row is `FB_STRIDE_QW qwords
                    // (`FB_W px) wide; an SDRAM texture row is c_src_stride BYTES. Same
                    // registered 16x16 DSP.
                    tex_row <= itv_q[15:0] * (tri_src_surface ? FB_STRIDE_QW16 : c_src_stride);
                    ax5_itu <= itu_q;             // carry: the byte add is one stage on
                    ax5_cr  <= cr_q; ax5_cg <= cg_q; ax5_cb <= cb_q; ax5_ca <= ca_q;
                    ax5_dst_qw <= dst_qw_q; ax5_dst_lane <= dst_lane_q;
                end
                // ── stage 5 -> 6 (ex-A_ADDR2). Interpolation stage 3b: texel byte address
                // add + tag split (adds only; no multiply).
                if (ax_v[4]) begin
                    if (tri_src_surface) begin
                        // [app-surface v1] surface qword = itv*stride + (itu>>2), lane = itu[1:0].
                        // tex_row already holds itv*stride (qwords). No SDRAM byte address / P_SRC
                        // read — the texel is a 1-cyc comp_fbram surf_rd hit (B_SURF_*).
                        surf_qw_q  <= tex_row[14:0] + {2'b0, ax5_itu[14:2]};   // itu>>2
                        tex_lane_q <= ax5_itu[1:0];
                    end else begin
                        // texel byte address (8-byte aligned; lane = byte[2:1]). Only the
                        // adds + register writes live here; the prefetch fill-kick is in
                        // the issue stage so tq_hit's tag lookup is not chained behind
                        // texbyte's adder.
                        texbyte = c_src_off + tex_row + (ax5_itu<<<1);
                        pa_qtag     <= texbyte[26:3];
                        tex_lane_q  <= texbyte[2:1];
                    end
                    ax6_cr <= ax5_cr; ax6_cg <= ax5_cg; ax6_cb <= ax5_cb; ax6_ca <= ax5_ca;
                    ax6_dst_qw <= ax5_dst_qw; ax6_dst_lane <= ax5_dst_lane;
                end
                // ── stage 6 (ex-A_ISSUE). Push this pixel's payload into the depth-D
                // FIFO. Payload packing MUST match pb's B_IDLE unpack exactly. Uses
                // pa_qtag (pipeline-private) rather than tri_p0_addr: tri_p0_addr is a
                // shared bus-address register that pb's B_FILL demand-miss path also
                // writes, and a same-cycle collision would clobber the in-flight address —
                // see docs/superpowers/.../uvfull-rootcause-report.md.
                //
                // [pipeline stage 3b] the old `if (!pf_full)` stall is GONE, and its
                // absence is a load-bearing consequence of the credit scheme, not an
                // oversight: ax_cred <= TEXFIFO_D bounds (pixels in the pipe + pixels in
                // the FIFO), and the pixel being pushed is still counted in the pipe, so
                // FIFO occupancy here is at most TEXFIFO_D-1.
                //
                // THREE THINGS MUST MOVE TOGETHER, and only the first two are obvious:
                //   1. TEXFIFO_D / TEXFIFO_AW (the FIFO's own depth and pointer width)
                //   2. the `ax_room` bound at the ax_room declaration
                //   3. **ax_cred's WIDTH** — it must stay $clog2(TEXFIFO_D+1), i.e. wide
                //      enough for the INCLUSIVE value TEXFIFO_D. That is why AX_CW is
                //      derived rather than written: at TEXFIFO_D=16 a 4-bit ax_cred makes
                //      `ax_cred < TEXFIFO_D` a tautology, the dispatcher never throttles,
                //      and with this guard removed nothing downstream notices. Sim catches
                //      it (3B-CREDW at elaboration, then 3B-PFFULL below); synthesis will
                //      not. If any of the three is ever changed independently of the
                //      others, restore the `if (!pf_full)` guard.
                if (ax_v[5]) begin
`ifndef SYNTHESIS
                    // The credit invariant, ASSERTED rather than trusted: this is what
                    // replaced the `if (!pf_full)` stall, and a golden-framebuffer diff
                    // would only catch it once the overflow happened to change a pixel.
                    if (pf_full) begin
                        $display("FAIL 3B-PFFULL: A-pipeline push into a FULL payload FIFO at t=%0t (ax_cred=%0d) -- credit accounting is broken", $time, ax_cred);
                        $finish;
                    end
                    if (ax_cred == {AX_CW{1'b0}}) begin
                        $display("FAIL 3B-CRED0: A-pipeline push with zero credits outstanding at t=%0t", $time);
                        $finish;
                    end
`endif
                    // best-effort prefetch: kick a fill for this qword when the arbiter is idle
                    // and it isn't the qword we just prefetched (last_pf_qtag skips the common
                    // 4-consecutive-pixels-share-a-qword case). No tag-RAM read here — that lets
                    // tq_tag be a single-reader M10K (see decl). Prefetch is best-effort; pb's
                    // B_LOOK/B_FILL demand path is the correctness backbone (bit-exact either way).
                    // [app-surface v1] no SDRAM prefetch for a surface source (the texel is a
                    // 1-cyc surf_rd BRAM hit, no tq cache); guard the fill-kick on !surface.
                    // tri_p0_addr (the actual P_SRC bus address) is only written here, at the
                    // moment a read is actually issued — never as a pipeline hand-carry.
                    if (!tri_src_surface && (pa_qtag != last_pf_qtag) && !fill_busy) begin
                        tri_p0_rd    <= 1'b1;
                        tri_p0_addr  <= {pa_qtag, 3'd0};
                        fill_busy    <= 1'b1;
                        fill_slot    <= pa_qtag[TEXQ_AW-1:0];
                        fill_tag     <= pa_qtag[TEXQ_AW +: TEXQ_TW];
                        last_pf_qtag <= pa_qtag;
                    end
                    // qtag field carries the SDRAM qword tag, or (surface) surf_qw zero-extended.
                    pf_mem[pf_wr[TEXFIFO_AW-1:0]] <=
                        {ax6_ca, ax6_cb, ax6_cg, ax6_cr, ax6_dst_qw, ax6_dst_lane,
                         (tri_src_surface ? {9'd0, surf_qw_q} : pa_qtag), tex_lane_q};
                    pf_wr <= pf_wr + 1'b1;
                end

            // ==== sub-FSM B: wait texel -> dst read -> 3-stage blend -> comp_fbram write ====
            case (pb)
            // Wait for a queued pixel; unpack the FIFO head into B-local regs and pop.
            // Packing order MUST match pa's A_ISSUE push exactly.
            // [Phase 1 A2] Issue the comp_fbram dst read HERE, concurrently with the
            // texel read, instead of waiting for the texel to resolve in B_FILL. The
            // dst qword has no dependency on the texel — it arrives in the FIFO payload
            // — and comp_fbram and the tq texel M10K are different memories, so both
            // reads can be in flight together. This deletes B_DSTW/B_DSTC: 8 -> 6 cyc/px.
            //
            // b_dst_qw is not valid until the END of this cycle, so read it straight off
            // the FIFO head, exactly as the surface path already does for the texel qword.
            // Payload packing (from A_ISSUE's push at :1396, LSB up):
            //   tex_lane[1:0] qtag[25:2] dst_lane[27:26] dst_qw[42:28]
            // tri_need_dst is a TRIANGLE constant (derived from c_blend, stable while
            // pixels are in flight), so it is already valid this cycle.
            B_IDLE: if (!pf_empty) begin
                {b_ca, b_cb, b_cg, b_cr, b_dst_qw, b_dst_lane, b_qtag, b_tex_lane} <= pf_head;
                pf_rd <= pf_rd + 1'b1;
                if (tri_need_dst) begin
                    tri_fb_rd_en <= 1'b1; tri_fb_rd_qw <= pf_head[28 +: 15];
                end
                if (tri_src_surface) begin
                    // [app-surface v1] issue the surface texel read now. surf_qw is the low
                    // 15 bits of the qtag field (pf_head[16:2]); b_qtag isn't valid until
                    // next cycle so read the qword straight off the FIFO head.
                    tri_surf_rd_en <= 1'b1; tri_surf_rd_qw <= pf_head[2 +: 15];
                    pb <= B_SURF_W;
                end else pb <= B_LOOK;
            end
            // [app-surface v1] surface texel path: B_SURF_W is the 1-cyc surf_rd BRAM
            // latency; B_SURF_C latches the texel (lane-select), then dst-read/blend —
            // mirrors B_FILL's HIT tail (no tq cache, no P_SRC).
            B_SURF_W: pb <= B_SURF_C;
            // [Phase 1 A2] Surface path: the dst read was issued in B_IDLE and B_SURF_W
            // served as its latency cycle, so comp_rd_qword is valid alongside the
            // surface texel. Mirrors the B_FILL hit tail.
            B_SURF_C: begin
                texel_q <= surf_rd_qword[b_tex_lane*16 +: 16];
                if (tri_need_dst) dst_q <= comp_rd_qword[b_dst_lane*16 +: 16];
                else              dst_q <= 16'd0;
                pb<=B_WR;
            end
            // The M10K read cycle. The read itself lives in the dedicated read-port block near
            // the tq_data declaration (nesting it HERE is what broke M10K inference); this arm
            // only spends the cycle the BRAM needs, so tq_rdata/tq_rtag/tq_rvalid are the valid
            // snapshot of b_qtag's slot by the time B_FILL runs. b_qtag was registered in
            // B_IDLE, so the read address carries no adder.
            B_LOOK: pb <= B_FILL;
            // Resolve the texel off the REGISTERED snapshot. HIT (valid & tag match) -> latch
            // texel_q and go to dst/blend. MISS -> demand-fetch through the single-outstanding
            // arbiter (if idle), then B_WAIT for the in-flight fill and re-read via B_LOOK.
            B_FILL: begin
                if (!tq_rdw_bad && tq_rvalid && (tq_rtag == b_qtag[23:TEXQ_AW])) begin
                    texel_q <= tq_rdata[b_tex_lane*16 +: 16];
                    // [Phase 1 A2] The dst read was issued in B_IDLE and B_LOOK served as
                    // its latency cycle, so comp_rd_qword is valid NOW. Latch it and go
                    // straight to blend — B_DSTW/B_DSTC are gone.
                    if (tri_need_dst) dst_q <= comp_rd_qword[b_dst_lane*16 +: 16];
                    else              dst_q <= 16'd0;
                    pb<=B_WR;
                end else begin
                    if (!fill_busy) begin
                        // demand-fetch (arbiter idle): issue the read for b_qtag's qword.
                        tri_p0_rd  <= 1'b1;
                        tri_p0_addr<= {b_qtag, 3'd0};
                        fill_busy  <= 1'b1;
                        fill_slot  <= b_qtag[TEXQ_AW-1:0];
                        fill_tag   <= b_qtag[23:TEXQ_AW];
                    end
                    // wait for the in-flight fill (ours or pa's speculation) to land, then
                    // re-read via B_LOOK. Re-checking is required because our registered
                    // read is now stale, and pa's fill may have been for a different qword.
                    pb <= B_WAIT;
                end
            end
            // Stall until the single outstanding fill lands (catcher writes tq_data[slot]
            // and clears fill_busy), then re-issue the registered read. On device this is
            // the per-pixel texel-fetch wait; the perf counter attributes it to texwait.
            // [Phase 1 A2] Re-issue the dst read on the retry. The read issued in B_IDLE
            // did NOT survive this stall — comp_rd_qword is a shared, single-registered
            // output that other clients drive — so it must be re-issued.
            //
            // It is re-issued HERE, on the B_WAIT -> B_LOOK edge, and deliberately NOT in
            // B_FILL's miss branch: rd_en asserted from the miss branch would go high
            // during B_WAIT, making comp_rd_qword valid one cycle BEFORE B_FILL even in
            // the fastest case (miss -> 1-cyc B_WAIT -> B_LOOK -> B_FILL), and N-1 cycles
            // stale for an N-cycle stall. Issuing at this edge makes B_LOOK the latency
            // cycle again, exactly mirroring the B_IDLE -> B_LOOK path.
            //
            // NOTE: no bench currently exercises miss + tri_need_dst (every dst-path bench
            // — trilist_add/calpha — runs a pure 8.00 cyc/px hit path with zero B_WAIT),
            // so the framebuffer diff CANNOT catch a mistake here. That is why the
            // A2-DSTAGE assertion below guards it instead of relying on the golden.
            B_WAIT: if (!fill_busy) begin
                if (tri_need_dst) begin
                    tri_fb_rd_en <= 1'b1; tri_fb_rd_qw <= b_dst_qw;
                end
                pb <= B_LOOK;
            end
            // ── blend stage A (comp_mixer stage A analogue) ──────────────────────
            // Tint the source channels (red255(texel*c)), split the dst channels, and
            // combine the per-vertex alpha with the global alpha: ea=(ca*g_alpha)/255,
            // na=255-ea. Register everything the MAC needs. One small multiply-or-
            // reduce per lane, no chain — mirrors blt_tri.sv:122-129 exactly.
            B_WR: begin
                b1_tsr <= modch({1'b0, texel_q[15:11]}, b_cr);   // tinted source channels
                b1_tsg <= modch(texel_q[10:5],          b_cg);
                b1_tsb <= modch({1'b0, texel_q[4:0]},   b_cb);
                b1_dr  <= {1'b0, dst_q[15:11]};  // dst channels (dr/db 5-bit, dg 6-bit)
                b1_dg  <= dst_q[10:5];
                b1_db  <= {1'b0, dst_q[4:0]};
                // ea = (ca*g_alpha)/255, truncating (blt_tri.sv:128). The real /255
                // divider synthesised a long combinational path (the sole remaining
                // fabric-clock violator: From ca_q To b1_ea). Replaced with the
                // divide-free shift-add identity floor(x/255) == ((x<<8)+x+257)>>16,
                // verified BIT-EXACT over the full product range x in [0,65025]. Only
                // the divide changes; the 8x8 ca*g_alpha multiply is kept. na from the
                // same temp so the reduction is instantiated once.
                xa_t   = {8'd0, b_ca} * {8'd0, c_alpha};   // x = ca*g_alpha, [0,65025]
                ea_t   = ( ({8'd0, xa_t} << 8) + {8'd0, xa_t} + 24'd257 ) >> 16;
                b1_ea  <= ea_t;
                b1_na  <= 8'd255 - ea_t;
                // colorkey cull (stable inputs; carried to the write stage)
                b1_we  <= !((c_blend==BLEND_KEY) && (texel_q==c_colorkey));
                pb<=B_WR2;
            end
            // ── blend stage B (comp_mixer stage B analogue) ──────────────────────
            // Per-channel intermediate selected by blend mode: the weighted-sum MAC
            // (CALPHA), the saturating pre-sum (ADD), the product (MUL), or the tinted
            // source (COPY/KEY). One multiply-or-add layer, reduced next stage.
            B_WR2: begin
                case (c_blend)
                  BLEND_ALPHA: begin   // BM_CALPHA: tsr*ea + dr*na  (reduced /255 in C)
                    b2_r <= b1_tsr*b1_ea + b1_dr*b1_na;
                    b2_g <= b1_tsg*b1_ea + b1_dg*b1_na;
                    b2_b <= b1_tsb*b1_ea + b1_db*b1_na;
                  end
                  BLEND_ADD: begin     // src+dst (saturated in C)
                    b2_r <= {10'd0, b1_tsr} + {10'd0, b1_dr};
                    b2_g <= {10'd0, b1_tsg} + {10'd0, b1_dg};
                    b2_b <= {10'd0, b1_tsb} + {10'd0, b1_db};
                  end
                  BLEND_MULTIPLY: begin // src*dst (round-divided in C)
                    b2_r <= b1_tsr*b1_dr;
                    b2_g <= b1_tsg*b1_dg;
                    b2_b <= b1_tsb*b1_db;
                  end
                  default: begin        // COPY / COLORKEY: write tinted src
                    b2_r <= {11'd0, b1_tsr};
                    b2_g <= {11'd0, b1_tsg};
                    b2_b <= {11'd0, b1_tsb};
                  end
                endcase
                b2_we <= b1_we;
                pb<=B_WR3;
            end
            // ── blend stage C (comp_mixer stage C analogue) ──────────────────────
            // /255,/31,/63 reduce (or ADD saturate), RGB565 pack, and the comp_fbram
            // write if not culled. Byte-identical result to blt_tri.sv:132-148.
            B_WR3: begin
                case (c_blend)
                  BLEND_ALPHA: begin
                    bl_or = red255(b2_r); bl_og = red255(b2_g); bl_ob = red255(b2_b);
                  end
                  BLEND_ADD: begin
                    bl_ar = b2_r[6:0]; bl_ag = b2_g[6:0]; bl_ab = b2_b[6:0];
                    if (bl_ar > 7'd31) bl_ar = 7'd31;
                    if (bl_ag > 7'd63) bl_ag = 7'd63;
                    if (bl_ab > 7'd31) bl_ab = 7'd31;
                    bl_or = bl_ar[5:0]; bl_og = bl_ag[5:0]; bl_ob = bl_ab[5:0];
                  end
                  BLEND_MULTIPLY: begin
                    bl_or = red31(b2_r[11:0]); bl_og = red63(b2_g[12:0]); bl_ob = red31(b2_b[11:0]);
                  end
                  default: begin
                    bl_or = b2_r[5:0]; bl_og = b2_g[5:0]; bl_ob = b2_b[5:0];
                  end
                endcase
                if (b2_we) begin
                    tri_fb_wr_en   <= 1'b1;
                    tri_fb_wr_qw   <= b_dst_qw;
                    tri_fb_wr_lane <= b_dst_lane;
                    tri_fb_wr_pix  <= { bl_or[4:0], bl_og[5:0], bl_ob[4:0] };
                end
                pb<=B_IDLE;   // pixel written; ready for the next handoff
            end
            default: pb<=B_IDLE;
            endcase

            // Triangle drained when address-gen is done, the A pipeline has emptied, the
            // blend pipe is empty, and no texel is outstanding -> next triangle / finish.
            // [pipeline stage 3b] !ax_busy is REQUIRED here and is the mutation-checked
            // control signal for this change: pa now reaches A_DONE up to six cycles
            // BEFORE the last dispatched pixels have been pushed, and pf_empty is true
            // during that window (pb has drained everything pushed so far), so without
            // !ax_busy this test fires early and S_TRI_SWAIT's pf_wr/pf_rd/ax_v reset
            // discards them. See the "drop a pixel" mutation in the Task 7 report.
            if ((pa==A_DONE) && !ax_busy && (pb==B_IDLE) && pf_empty && !fill_busy)
                state<=S_TRI_NEXT;
            end
            // Triangle done: advance to the next triangle, else finish the command.
            S_TRI_NEXT: begin
                if (tri_idx + 16'd1 < tri_count) begin
                    tri_idx <= tri_idx + 16'd1;
                    state<=S_TRI_VFETCH;
                end else begin
                    tri_busy <= 1'b0;
                    state<=S_NEXT_CMD;
                end
            end

            S_NEXT_CMD: begin cmd_idx<=cmd_idx+1; state<=S_FETCH; end

            // C_PIPE: the FSM holds here (driving no bus traffic — bm_* idle,
            // pipe_busy hands mem_* to comp_pipeline) until the pipelined blit
            // signals blit_done, then advances to the next command.
            S_PIPE_WAIT: if (p_blit_done) state<=S_NEXT_CMD;

            S_FRAME_VCTRL: begin
                // [DDR-scanout custom-reader] The video control-word (VCTRL) write is RETIRED:
                // comp_fb_dma is now the SOLE control-word producer — it writes the frame_counter
                // + buffer-select word at FB_QW_BASE (0x3BF40000) AFTER its WORK->DDR copy, so the
                // reader's active_buffer flip happens once the new frame is fully in DDR. Writing a
                // second (stale, 0x3A) control word here would race that. This state no longer
                // touches DDR — it only bumps the perf/debug frame_counter, then signals C_DONE.
                frame_counter<=frame_counter+1;
                // [publish order] C_DONE is the host's RELEASE barrier — it must be written
                // LAST, after the perf words it releases. Enter the writeback chain at
                // S_WR_STATUS; S_WR_DONE is now the tail. See S_WR_DONE below.
                state<=S_WR_STATUS;
            end
            // [Phase 1 A4] Publish the exact covered-pixel count to the spare HIGH 32 of
            // C_FLAGS. be=0xF0 preserves the host-written LOW word carrying the frame's
            // flags: the host writes it 32-bit at qw*8 (raster_backend_mfgpu.cpp
            // mf_ctrl_wr), so producer and consumer never collide on the same bytes.
            // Sequenced BEFORE S_WR_DONE because C_DONE is the host's release barrier —
            // anything published after it is sampled one frame stale. Guarded by
            // tb_perf_publish_order.
            S_WR_COVPX: begin
                bm_wr<=1; bm_be<=8'hF0; bm_addr<=`BLTCTRL_QW+`C_FLAGS;
                bm_din<={perf_covered_px, 32'd0};
                wr_ret<=S_WR_DONE;
                state<=S_WR_WAIT;
            end
            S_WR_DONE: begin
                // low32 = done_seq (handshake); high32 = fabric-busy cyc this frame.
                // [publish order] TAIL of the writeback chain (was the head). The host
                // (raster_backend_mfgpu.cpp mf_device_submit) returns the instant C_DONE
                // matches submit_seq and then reads C_STATUS.hi (perf_texwait_cyc) and
                // C_SRCSEL.hi (perf_tri_cyc). Publishing C_DONE first left an 8-cycle window
                // in which those reads returned the PREVIOUS frame's counters, making the
                // derived ovhd = frame - tri mix two frames. Ringing the bell last closes it
                // — the same "doorbell LAST after a barrier" discipline the host uses on
                // submit. Guarded by tb_perf_publish_order.
                // Still ahead of S_SNAP_WAIT, so the engine's next-frame prep continues to
                // overlap the WORK->scan snapshot; this costs only the two qword writes.
                bm_wr<=1; bm_be<=8'hFF; bm_addr<=`BLTCTRL_QW+`C_DONE;
                bm_din<={perf_frame_cyc, submit_reg};
                wr_ret<=S_SNAP_WAIT; state<=S_WR_WAIT;
            end
            S_WR_STATUS: begin
                // low32 = OSD mirror bits (bit0=osd_restart_pending, the sticky-latched
                // trigger — see the latch above; bit1=osd_fps_on, a genuine persistent
                // level so it's read raw); high32 = compositor-busy (pipe_busy) cyc this
                // frame — unchanged.
                // [profiling] high32 repurposed perf_pipe_cyc -> perf_texwait_cyc (the
                // per-pixel texel-fetch stall). perf_pipe_cyc (~2.45ms) is already known.
                bm_wr<=1; bm_be<=8'hFF; bm_addr<=`BLTCTRL_QW+`C_STATUS;
`ifdef SOLARUS_DBG_PROBES
                // [wedge probe v2] high32 = wedge_snap2 (bbox at peak stuck: maxx|maxy<<16) for the
                // runaway-walk check; low32 OSD bits preserved. Host reads bbox at C_STATUS+4 = 0x3B000034.
                bm_din<={wedge_snap2, wd_fire_count, 6'd0, osd_fps_on, osd_restart_pending};
`else
                bm_din<={perf_texwait_cyc, wd_fire_count, 6'd0, osd_fps_on, osd_restart_pending};
`endif
                wr_ret<=S_WR_PERF;
                state<=S_WR_WAIT;
            end
            S_WR_PERF: begin
                // [profiling] publish perf_tri_cyc to the SPARE high 32 of C_SRCSEL (qw7);
                // low 32 (throttle_cfg[15:8]) preserved via byte-enable. Host reads at
                // C_SRCSEL+4. Then proceed to the vblank work->scan snapshot as before.
                bm_wr<=1; bm_be<=8'hF0; bm_addr<=`BLTCTRL_QW+`C_SRCSEL;
`ifdef SOLARUS_DBG_PROBES
                // [S_SNAP wedge probe] publish the persistent worst-stuck snapshot instead of
                // perf_tri_cyc (debug build only). Host reads at C_SRCSEL+4 = 0x3B00003C.
                bm_din<={wedge_snap, 32'd0};
`else
                bm_din<={perf_tri_cyc, 32'd0};
`endif
                // [publish order] proceed to S_WR_DONE, which rings the C_DONE doorbell now
                // that both perf words are in DDR, and then falls through to S_SNAP_WAIT.
                // [FB-in-BRAM double-buffer] after the frame, snapshot the completed work
                // buffer into the scan buffer (during vblank). C_DONE is written just ahead
                // of the snapshot, so the engine's handshake still completes and its
                // next-frame prep overlaps the snapshot; we hold off polling the next
                // submit until it ends.
                wr_ret<=S_WR_COVPX;   // [Phase 1 A4] covered_px, then the C_DONE doorbell
                state<=S_WR_WAIT;
            end

            // [Phase 1 A1] The vblank wait is DELETED. It cost up to a full 16.69 ms
            // scanout period per frame and guarded nothing: comp_fb_dma latches
            // wr_target = ~disp_active at `start` and writes only the BACK DDR buffer,
            // publishing its control word after the entire copy is accepted, so the
            // reader can never observe a partial frame. The `vs_rise` condition was
            // stale rationale from before that double buffer existed.
            //
            // Consequence to EXPECT, not debug: above 60 fps the compositor can finish
            // two frames inside one scanout period. comp_fb_dma gates on
            // (disp_active == published) and simply DROPS the surplus start pulse
            // (comp_fb_dma.sv:185/195) rather than copying twice — the reader has not yet
            // swapped onto the last publish, so re-writing that buffer would tear. Excess
            // frames are therefore dropped at the producer, never queued. A dropped start
            // does NOT stall us: fb_dma_busy simply never asserts, so S_SNAP_BUSY falls
            // through on SNAP_GUARD (32 cyc ~= 0.33 us @98.44 MHz).
            //
            // Those drops increment comp_fb_dma's skip_cnt, whose SKIP_MAX=32 watchdog
            // assumed `start` was vblank-gated. Still safe by a wide margin: tripping it
            // needs 33 starts inside ONE scanout period, i.e. a ~0.5 ms frame (~2000 fps).
            // Phase 1 targets ~90 fps, so worst case is 1 skip — ~22x of headroom.
            S_SNAP_WAIT: begin fb_dma_start<=1'b1; snap_guard<=6'd0; state<=S_SNAP_BUSY; end
            // fb_dma_start pulsed; wait for comp_fb_dma to raise busy — but bounded by
            // SNAP_GUARD so an absent DMA engine (sim/WIP, fb_dma_busy never asserts) proceeds
            // instead of wedging. The real comp_fb_dma asserts busy at start+1 (well inside).
            S_SNAP_BUSY:
                if      (fb_dma_busy)             state<=S_SNAP_DRAIN;
                else if (snap_guard==SNAP_GUARD)  state<=S_POLL_SUBMIT;
                else                              snap_guard<=snap_guard+6'd1;
            // hold here (not compositing, so the work buffer is stable) until the copy
            // completes, then resume polling for the next frame.
            S_SNAP_DRAIN: if (!fb_dma_busy) state<=S_POLL_SUBMIT;

            // Backpressure-safe generic read: hold bm_rd until the bus accepts
            // it (~mem_busy), then await dout_ready. (mem_busy = ddram busy OR not
            // granted by the arbiter; on the never-busy sim model this is a no-op.)
            //
            // [startup-wedge fix] REISSUE WATCHDOG: an f2h read accepted during the
            // core-load port-bring-up window can lose its response beat outright
            // (device evidence 2026-07-27: ~50% of launches park here on the FIRST
            // C_SUBMIT poll, rd_issued=1, C_DONE never written — the frame-1 wedge).
            // The arbiter's expectation queue self-heals a lost beat after
            // FLUSH_QUIET_MAX (2^20 cyc ~10.6ms), but the master never re-issued.
            // RW_WD_MAX is deliberately > FLUSH_QUIET_MAX so the reissue can only
            // fire AFTER the arb has flushed the dead expectation — a reissued
            // read can therefore never pair with a stale queue entry. Reads are
            // side-effect-free, so reissue is idempotent. bm_addr still holds the
            // original address (only S_RD_WAIT's issuing state writes it).
            S_RD_WAIT: begin
                if (!rd_issued) begin
                    bm_rd <= 1'b1;                       // hold request
                    if (!mem_busy) rd_issued <= 1'b1;     // accepted this cycle
                end else if (mem_dout_ready) begin
                    rd_data <= mem_dout; rd_issued <= 1'b0; state <= rd_ret;
                end else if (rw_wd == RW_WD_MAX) begin
                    rd_issued <= 1'b0;                   // response lost: re-arm the issue phase
                    bm_rd <= 1'b1;                       // request visible when the accept check runs
                    rw_wd <= 22'd0;
                    if (~&rd_reissue_cnt) rd_reissue_cnt <= rd_reissue_cnt + 8'd1;
                end
            end
            // Backpressure-safe generic write: bm_wr/addr/din/be held from the
            // issue state; clear + advance only once the bus accepts (~mem_busy).
            S_WR_WAIT: if (!mem_busy) begin
                bm_wr <= 1'b0; bm_be <= 8'h00;
                // [#34] after the write is accepted, idle the bus for throttle_cfg cycles
                // so the scanout reader can refill its FIFO (un-throttled back-to-back
                // writes saturate the f2h write FIFO -> ddram_busy -> scanout starves).
                if (throttle_cfg != 8'd0) begin
                    throttle_cnt <= throttle_cfg; state <= S_WR_THROTTLE;
                end else state <= wr_ret;
            end
            // [#34] bus held idle (bm_rd/bm_wr both 0 here) -> the arbiter sees the
            // blitter not requesting and the reader gets the bus. Then resume the FSM.
            S_WR_THROTTLE:
                if (throttle_cnt != 8'd0) throttle_cnt <= throttle_cnt - 8'd1;
                else state <= wr_ret;
            default: state<=S_POLL_SUBMIT;
            endcase
        end
    end

    // ════════════════════════════════════════════════════════════════════════
    //  comp_pipeline: the sole render datapath (Spec A) + mem_* OWNER MUX
    // ════════════════════════════════════════════════════════════════════════
    // comp_pipeline executes one FILL/BLIT at a time. It owns the shared mem_*
    // master ONLY while pipe_busy=1 (set when pipe_start pulses, cleared on
    // blit_done). Outside that window the FSM's bm_* drive the bus for the command
    // ring, screen-clear, STAGE, and status/vctrl writes.
    comp_pipeline u_pipe (
        .clk(clk), .rst(rst),
        .blit_start(pipe_start),
        .c_opcode(c_opcode), .c_blend(c_blend), .c_format(c_format), .c_flags(c_flags),
        .c_src_off(c_src_off), .c_src_stride(c_src_stride),
        .c_src_x(c_src_x), .c_src_y(c_src_y),
        .c_w(c_w), .c_h(c_h), .c_colorkey(c_colorkey), .c_alpha(c_alpha),
        .c_color(c_color),
        // [gmloader-GPU slim] PAL8/CLUT retired: gmloader never uses PAL8, so the
        // pipeline's CLUT ports are tied to constants instead of a live clut_bram
        // (deleted with the CLUT_UPLOAD FSM). clut_rd_addr is left unconnected.
        .c_pal_id(5'd0), .c_base_off(8'd0),
        .clut_rd_addr(), .clut_rd_data(32'd0),
        .c_cmod_r(c_cmod_r), .c_cmod_g(c_cmod_g), .c_cmod_b(c_cmod_b),  // [v2] tint
        .c_dst_x(c_dst_x), .c_dst_y(c_dst_y),
        .target_base(target_base),
        // shared mem_* inputs (same bus as the FSM)
        .mem_addr(p_mem_addr), .mem_rd(p_mem_rd), .mem_wr(p_mem_wr),
        .mem_burstcnt(p_mem_burstcnt),
        .mem_din(p_mem_din), .mem_be(p_mem_be),
        .mem_dout(mem_dout), .mem_dout_ready(mem_dout_ready), .mem_busy(mem_busy),
        // P_SRC cache-ok channel (Task 5). c_srcsel is hardwired to 1
        // (src_in_sdram=1): every source read goes through the SDRAM P_SRC port —
        // there is no DDR3 live-source path anymore (single source pipeline).
        .c_srcsel(src_in_sdram),
        .p0_addr(p_src_sdram_addr), .p0_rd(p_src_sdram_rd),
        .p0_dout(p0_dout), .p0_ok(p0_ok),
        // on-chip framebuffer (comp_fbram) dest port — threaded straight out [FB-in-BRAM].
        // The work WRITE port is comp_pipeline's alone; the work READ port is comp_pipeline's
        // RMW read (the WORK->DDR copy uses comp_fb_dma's own read port at the emu top).
        .fb_wr_en(pipe_fb_wr_en), .fb_wr_qw(pipe_fb_wr_qw), .fb_wr_lane(pipe_fb_wr_lane), .fb_wr_pix(pipe_fb_wr_pix),
        .fb_rd_en(pipe_fb_rd_en), .fb_rd_qw(pipe_fb_rd_qw), .fb_rd_qword(comp_rd_qword),
        .blit_done(p_blit_done));

    // ── vblank WORK->DDR framebuffer copy [DDR-scanout] ──────────────────────────
    // The on-chip WORK->SCAN snapshot controller (u_snap/fbram_snapshot) is retired. The
    // completed WORK buffer is now streamed to a DDR3 framebuffer by the external
    // comp_fb_dma (instantiated at the emu top), which the framework's ascal scans out.
    // The S_SNAP_* FSM above pulses fb_dma_start / waits on fb_dma_busy; comp_fb_dma reads
    // WORK via its own port (muxed onto comp_fbram at the emu top while fb_dma_busy), so
    // blitter_top no longer borrows the WORK read port for the copy.
    // [gmloader-GPU slim] OP_BGPLANE_WRITE + its fbram_to_sdram/bgplane_coverage
    // bake stream are retired: the STAGE burst-write outputs are now driven
    // unconditionally by the OP_STAGE atlas FSM's stage_*_fsm regs (the bake's
    // bgw_active priority mux is gone along with the bake itself).
    assign src_sdram_we_burst = stage_we_burst_fsm;
    assign src_sdram_din64    = stage_din64_fsm;
    assign src_sdram_waddr    = stage_waddr_fsm;

    // ── composite target routing [app-surface v1] ───────────────────────────────
    // The compositor's write + RMW-read (from the TRILIST walk while tri_busy, else
    // comp_pipeline FILL/BLIT) is steered to the WORK framebuffer or the off-screen
    // APPSURF surface by comp_target. When comp_target==WORK (every frame that never emits
    // SET_TARGET) the WORK paths are byte-identical to before and the surface ports are
    // idle. The vblank WORK->DDR copy runs while the compositor is idle (S_SNAP_*), so it
    // needs no share of the WORK read port here — comp_fb_dma reads WORK at the emu top.

    // shared composite write (tri owns while rasterizing; else comp_pipeline)
    wire        cw_en   = tri_busy ? tri_fb_wr_en   : pipe_fb_wr_en;
    wire [14:0] cw_qw   = tri_busy ? tri_fb_wr_qw   : pipe_fb_wr_qw;
    wire [1:0]  cw_lane = tri_busy ? tri_fb_wr_lane : pipe_fb_wr_lane;
    wire [15:0] cw_pix  = tri_busy ? tri_fb_wr_pix  : pipe_fb_wr_pix;
    // shared composite RMW-read address/enable (snapshot forces WORK below)
    wire        cr_en = tri_busy ? tri_fb_rd_en : pipe_fb_rd_en;
    wire [14:0] cr_qw = tri_busy ? tri_fb_rd_qw : pipe_fb_rd_qw;

    // WORK write port: enabled only when the composite target is WORK.
    assign fb_wr_en   = appsurf_active ? 1'b0 : cw_en;
    assign fb_wr_qw   = cw_qw;
    assign fb_wr_lane = cw_lane;
    assign fb_wr_pix  = cw_pix;
    // SURFACE write port: enabled only when the composite target is APPSURF.
    assign surf_wr_en   = appsurf_active ? cw_en : 1'b0;
    assign surf_wr_qw   = cw_qw;
    assign surf_wr_lane = cw_lane;
    assign surf_wr_pix  = cw_pix;

    // WORK read port: the compositor's RMW read when compositing into WORK.
    assign fb_rd_en = appsurf_active ? 1'b0 : cr_en;
    assign fb_rd_qw = cr_qw;
    // SURFACE read port: two mutually-exclusive users, selected by comp_target.
    //  - APPSURF (compositing INTO the surface): the composite RMW read (Task 6).
    //  - WORK (compositing into WORK): the TRILIST surface texel sample (Task 7,
    //    BLT_F_SRC_SURFACE) — the tri walk reads the surface as its texture. These
    //    never overlap (target is one or the other), so one 1W1R read port suffices.
    assign surf_rd_en = appsurf_active ? cr_en : tri_surf_rd_en;
    assign surf_rd_qw = appsurf_active ? cr_qw : tri_surf_rd_qw;

    // Read result back to the renderer: surface when compositing APPSURF, else WORK.
    // comp_target is stable across a whole blit (it only moves at SET_TARGET, between
    // fully-drained blits), so the 1-cycle read latency never straddles a target change.
    assign comp_rd_qword = appsurf_active ? surf_rd_qword : fb_rd_qword;

    // owner mux: comp_pipeline drives the bus only while pipe_busy; otherwise the
    // FSM's bm_* drive it for ring/clear/STAGE/status traffic.
    //
    // [#44 timing] The select uses pipe_busy_q — a LOCKSTEP DUPLICATE of pipe_busy
    // dedicated to these ~100 bits of owner mux. pipe_busy itself also fans out into
    // the FSM + dbg, so the fitter cannot isolate it; the critical setup path
    // pipe_busy -> mem_addr mux -> vram_demux is_fb -> ddr_blitter_arb ddram_we ->
    // HPS f2sdram failed setup by -0.068ns. pipe_busy_q is set/cleared by the SAME
    // conditions on the SAME cycle (identical value every cycle — no functional or
    // latency change), but as a low-fanout register the placer can put it next to the
    // demux, shortening the select routing. Source mux (p0_*) keeps pipe_busy: it is
    // not on the failing f2sdram path.
    assign mem_addr     = pipe_busy_q ? p_mem_addr     : bm_addr;
    assign mem_rd       = pipe_busy_q ? p_mem_rd       : bm_rd;
    assign mem_wr       = pipe_busy_q ? p_mem_wr       : bm_wr;
    assign mem_burstcnt = pipe_busy_q ? p_mem_burstcnt : 8'd1;   // FSM traffic is single-beat
    assign mem_din      = pipe_busy_q ? p_mem_din      : bm_din;
    assign mem_be       = pipe_busy_q ? p_mem_be       : bm_be;

    // P_SRC read port (read-only): comp_pipeline is the only renderer, so it drives
    // the cache-ok p0_* source port directly (idle p0_rd=0 when not fetching). The
    // write/STAGE source ports (src_sdram_we/din/waddr/we_burst/din64) stay driven by
    // the FSM's STAGE path — comp_pipeline never stages.
    // P_SRC source-read mux: the TRILIST walk fetches texels through p0_* while
    // tri_busy; otherwise comp_pipeline drives it.
    assign p0_addr = tri_busy ? tri_p0_addr : p_src_sdram_addr;
    assign p0_rd   = tri_busy ? tri_p0_rd   : p_src_sdram_rd;

    // pipe_busy bookkeeping: raised when pipe_start pulses (S_SETUP hands a blit
    // to the pipeline), lowered on blit_done. pipe_busy_q is a LOCKSTEP DUPLICATE
    // (same set/clear, same cycle) used ONLY for the owner-mux select — see the mux
    // above ([#44 timing] fanout-isolation for the f2sdram setup path).
    always @(posedge clk) begin
        if (rst) begin
            pipe_busy   <= 1'b0;
            pipe_busy_q <= 1'b0;
        end else begin
            if (pipe_start)       begin pipe_busy <= 1'b1; pipe_busy_q <= 1'b1; end
            else if (p_blit_done) begin pipe_busy <= 1'b0; pipe_busy_q <= 1'b0; end
        end
    end
endmodule
`default_nettype wire
