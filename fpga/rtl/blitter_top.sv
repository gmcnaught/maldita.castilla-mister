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
    parameter AW = 32
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
    output wire          fb_rd_en,        // muxed: comp_pipeline RMW read, OR the snapshot source read
    output wire [14:0]   fb_rd_qw,
    input  wire [63:0]   fb_rd_qword,
    // ---- snapshot (work->scan) write port to comp_fbram [FB-in-BRAM double-buffer] ----
    // Once per frame, during vblank, the entire WORK buffer is copied to the SCAN buffer
    // so the scanout reads a stable (tear-free) image. Driven by u_snap (fbram_snapshot).
    output wire          fb_snap_we,
    output wire [14:0]   fb_snap_qw,
    output wire [63:0]   fb_snap_qword,
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
                     F_COLORMOD=8'h40;   // [v2 escape-elim] _pad bytes carry an RGB888 tint
                                         // (cr,cg,cb) modulating the SOURCE before the blend.
    // Source pixel formats (cmd.format). Both are 16bpp: RGB565 and ARGB4444
    // ({A4,R4,G4,B4}); BLEND_PALPHA just reinterprets the fetched 16-bit source
    // pixel. comp_pipeline owns the source addressing/fetch now.
    localparam [7:0] FMT_RGB565=8'd0, FMT_ARGB4444=8'd1;

    reg  [5:0]  state, rd_ret, wr_ret;
    reg         rd_issued;   // read accepted by the bus, now awaiting dout_ready
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
    wire          snap_busy, snap_rd_en; wire [14:0] snap_rd_qw;
    // [app-surface v1] composite RMW-read result seen by the renderer: the off-screen
    // surface when compositing APPSURF, else the WORK framebuffer. Assigned in the
    // target-routing mux at the bottom; fed to comp_pipeline + the TRILIST dst read.
    wire [63:0]   comp_rd_qword;
    reg           snap_start;    // 1-cycle work->scan snapshot trigger
    // [#104] Synchronize vs (scanout vblank; may cross from the video clock) through a
    // 3-FF chain BEFORE the rising-edge detect, detecting between the two RESOLVED stages
    // ([2]&[1]). The old single vs_q edge-detected a still-async vs -> a metastable sample
    // could mis-time the WORK->SCAN snapshot trigger (S_SNAP_WAIT). +1-2 clk latency is
    // negligible for a per-frame vblank.
    reg   [2:0]   vs_sync;
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
    assign dbg = {dbg_stuck[23:16], rd_issued, 8'd0, 9'd0, state};

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
    reg  [15:0]  tri_ox;                               // bbox-min x (row-wrap target)
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
    reg  signed [63:0] row_w0, row_w1, row_w2;         // coverage edges at row start (x=ox)
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
    reg  [15:0]  texel_q, dst_q;           // fetched texel + dst pixel
    reg  [14:0]  dst_qw_q;                 // comp_fbram qword index for this pixel
    reg  [1:0]   dst_lane_q;               // x[1:0]

    // [pipeline stage 3a] The per-pixel S_TRI_* walk is split into two concurrent
    // sub-FSMs that run every cycle while the main state sits at the umbrella
    // S_TRI_RUN, overlapping one pixel's blend/write (B) with the next pixel's
    // address-gen + texel fetch (A):
    //   pa (address-gen): walk coverage -> W*recip mul -> texel addr -> issue P_SRC read
    //   pb (consume+blend): wait texel -> dst read -> 3-stage blend -> comp_fbram write
    // They rendezvous through a depth-TEXFIFO_D payload FIFO (pf_mem), so A can run up
    // to TEXFIFO_D pixels ahead of B. Because A computes pixel N+1 (clobbering the live
    // cr_q/dst_qw_q/... regs) while B is still blending pixel N, B consumes the payload
    // popped from the FIFO (b_* regs) rather than the live regs. Triangle
    // constants (c_blend/c_alpha/c_src_*) are stable while pixels are in flight (the
    // pipe drains before the next triangle's setup), so they need no snapshot.
    localparam [2:0] A_PIX=3'd0, A_MUL0=3'd1, A_MUL1=3'd2, A_MUL=3'd3,
                     A_ADDR=3'd4, A_ADDR2=3'd5, A_ISSUE=3'd6, A_DONE=3'd7;
    // pb widened to 4 bits: the qword-BRAM read is pipelined through B_LOOK (present the
    // slot as a REGISTERED read address so tq_data infers M10K) and B_WAIT (stall on a
    // demand/prefetch fill, then re-read). This breaks the b_qtag -> 256-entry distributed
    // tag/data mux -> dst_q combinational path that failed STA at -1.732ns on the fabric clk.
    localparam [3:0] B_IDLE=4'd0, B_LOOK=4'd1, B_FILL=4'd2, B_WAIT=4'd3,
                     B_DSTW=4'd4, B_DSTC=4'd5, B_WR=4'd6, B_WR2=4'd7, B_WR3=4'd8;
    reg  [2:0]   pa;                       // address-gen sub-FSM state
    reg  [3:0]   pb;                       // consume+blend sub-FSM state
    // [Task 2] depth-D payload FIFO decouples pa from pb: pa pushes each pixel's
    // payload as it finishes address-gen and races ahead up to TEXFIFO_D pixels; pb
    // pops the head and resolves/blends. Replaces the old single-deep h_full handoff.
    // Payload = {ca,cb,cg,cr[8b each]=32, dst_qw[15], dst_lane[2], qtag[24], texlane[2]}
    // = 75 bits. Pointer-with-extra-MSB scheme gives full/empty disambiguation.
    localparam integer TEXFIFO_D  = 8;
    localparam integer TEXFIFO_AW = 3;      // $clog2(TEXFIFO_D)
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
    // tq_data + tq_tag are read ONLY by pb (B_LOOK, registered) and written ONLY by the
    // catcher -> both infer M10K (registered-read BRAM), so neither the 64-bit data nor
    // the 18-bit tag read is a distributed 256:1 mux on the fabric clock. This is only
    // possible because pa no longer reads the tag RAM (it uses the last_pf_qtag filter
    // below instead of a full residency check) — a registered+combinational mixed read of
    // tq_tag previously crashed Quartus 17.0 Verific ("read to RAM wasn't mapped to a
    // specific read port"), which is why the tag was distributed before.
    (* ramstyle = "no_rw_check, M10K" *) reg [63:0] tq_data [0:TEXQ_N-1];        // cached qwords
    (* ramstyle = "no_rw_check, M10K" *) reg [TEXQ_TW-1:0] tq_tag [0:TEXQ_N-1];  // qtag[23:TEXQ_AW]
    reg  [TEXQ_N-1:0] tq_valid;             // per-slot valid; packed for a 1-cycle SYNCHRONOUS clear on the per-command barrier
    // registered qword-cache read (B_LOOK -> B_FILL): raw tag/valid/data captured, hit
    // compare done in B_FILL off the registers (short path).
    reg  [63:0]  tq_rdata;                  // registered tq_data[slot] (M10K read)
    reg  [TEXQ_TW-1:0] tq_rtag;             // registered tq_tag[slot]  (M10K read)
    reg          tq_rvalid;                 // registered tq_valid[slot]
    // pa best-effort prefetch de-dup: skip re-issuing a fill for the qword it just
    // prefetched (catches the dominant consecutive-same-qword case; 4 texels share a
    // qword). NOT a residency check — pb's B_LOOK/B_FILL demand path is the correctness
    // backbone, so a missed skip only costs a redundant fill, never a wrong texel.
    reg  [23:0]  last_pf_qtag;              // last qword tag pa issued a prefetch for
    // P_SRC fill arbiter: sole owner of tri_p0_rd/tri_p0_addr, single-outstanding.
    reg         fill_busy;                  // a fill is in flight (p0_ok pending)
    reg  [TEXQ_AW-1:0] fill_slot;           // slot the in-flight fill targets
    reg  [TEXQ_TW-1:0] fill_tag;            // tag the in-flight fill will stamp

    wire tri_need_dst = (c_blend==BLEND_ALPHA)||(c_blend==BLEND_ADD)||(c_blend==BLEND_MULTIPLY);

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
    function automatic [5:0] red255(input [16:0] t); reg [17:0] m; begin m={1'b0,t}+18'd128; red255=(m+(m>>8))>>8; end endfunction
    function automatic [4:0] red31 (input [11:0] t); reg [12:0] m; begin m={1'b0,t}+13'd16;  red31 =(m+(m>>5))>>5; end endfunction
    function automatic [5:0] red63 (input [12:0] t); reg [13:0] m; begin m={1'b0,t}+14'd32;  red63 =(m+(m>>6))>>6; end endfunction
    // per-channel colour-mod: div255_round(ch*mod)
    function automatic [5:0] modch(input [5:0] ch, input [7:0] mod); modch = red255(ch*mod); endfunction

    // bbox-max (from raw verts, matching blt_tri.c: (hx+ONE-1)>>SUB clamp FB-1)
    wire signed [15:0] tri_hx = (tri_vx0>tri_vx1)?((tri_vx0>tri_vx2)?tri_vx0:tri_vx2)
                                                 :((tri_vx1>tri_vx2)?tri_vx1:tri_vx2);
    wire signed [15:0] tri_hy = (tri_vy0>tri_vy1)?((tri_vy0>tri_vy2)?tri_vy0:tri_vy2)
                                                 :((tri_vy1>tri_vy2)?tri_vy1:tri_vy2);
    wire signed [31:0] tri_maxx_c = ($signed(tri_hx) + 32'sd15) >>> 4;
    wire signed [31:0] tri_maxy_c = ($signed(tri_hy) + 32'sd15) >>> 4;
    wire [15:0] tri_maxx_cl = (tri_maxx_c > 32'sd319) ? 16'd319 : (tri_maxx_c < 0 ? 16'd0 : tri_maxx_c[15:0]);
    wire [15:0] tri_maxy_cl = (tri_maxy_c > 32'sd239) ? 16'd239 : (tri_maxy_c < 0 ? 16'd0 : tri_maxy_c[15:0]);

    // [pipeline stage 1] advance the walk cursor one pixel: within a row step the
    // running edge/attr accumulators by their per-x deltas; at row end wrap x to the
    // bbox-min and step the row-start latches by the per-y deltas; past the last row
    // clear tri_cv (cursor exhausted). Bit-identical to the former S_TRI_ADV tail,
    // but now invoked at DISPATCH time so the cursor is decoupled from datapath depth.
    // The <= assignments schedule on the calling always block's clock edge.
    task automatic advance_cursor;
        begin
            if (tri_px < tri_maxx) begin
                tri_px <= tri_px + 16'd1;
                w0<=w0+ts_dw0dx; w1<=w1+ts_dw1dx; w2<=w2+ts_dw2dx;
                Wu<=Wu+ts_dWudx; Wv<=Wv+ts_dWvdx; Wr<=Wr+ts_dWrdx;
                Wg<=Wg+ts_dWgdx; Wb<=Wb+ts_dWbdx; Wa<=Wa+ts_dWadx;
            end else if (tri_py < tri_maxy) begin
                tri_py <= tri_py + 16'd1;
                tri_px <= tri_ox;
                row_w0<=row_w0+ts_dw0dy; w0<=row_w0+ts_dw0dy;
                row_w1<=row_w1+ts_dw1dy; w1<=row_w1+ts_dw1dy;
                row_w2<=row_w2+ts_dw2dy; w2<=row_w2+ts_dw2dy;
                row_Wu<=row_Wu+ts_dWudy; Wu<=row_Wu+ts_dWudy;
                row_Wv<=row_Wv+ts_dWvdy; Wv<=row_Wv+ts_dWvdy;
                row_Wr<=row_Wr+ts_dWrdy; Wr<=row_Wr+ts_dWrdy;
                row_Wg<=row_Wg+ts_dWgdy; Wg<=row_Wg+ts_dWgdy;
                row_Wb<=row_Wb+ts_dWbdy; Wb<=row_Wb+ts_dWbdy;
                row_Wa<=row_Wa+ts_dWady; Wa<=row_Wa+ts_dWady;
            end else begin
                tri_cv <= 1'b0;
            end
        end
    endtask

    always @(posedge clk) begin
        if (rst) begin
            state<=S_POLL_SUBMIT; bm_rd<=0; bm_wr<=0; bm_be<=0;
            bm_addr<=0; bm_din<=0; idle<=1; frame_counter<=0;
            cmd_idx<=0; fetch_k<=0; submit_reg<=0; done_reg<=0; rd_issued<=0;
            perf_frame_cyc<=32'd0; perf_pipe_cyc<=32'd0;
            perf_tri_cyc<=32'd0; perf_texwait_cyc<=32'd0;
            throttle_cnt<=8'd0; throttle_cfg<=8'd0;
            pipe_start<=1'b0;
            src_sdram_we<=1'b0; src_sdram_din<=16'd0; stage_waddr_fsm<=27'd0;
            stage_we_burst_fsm<=1'b0; stage_din64_fsm<=64'd0;
            stage_barrier<=1'b0; barrier_seen_busy<=1'b0;
            snap_start<=1'b0;   // [#104] vs edge-detect moved to the dedicated vs_sync 3-FF chain
            tri_busy<=1'b0; tri_setup_start<=1'b0;
            comp_target<=`BLT_TARGET_WORK;   // [app-surface v1] default target = WORK
            tri_p0_rd<=1'b0; tri_fb_rd_en<=1'b0; tri_fb_wr_en<=1'b0;
            pa<=A_PIX; pb<=B_IDLE; pf_wr<=0; pf_rd<=0;
            fill_busy<=1'b0; tq_valid<={TEXQ_N{1'b0}}; last_pf_qtag<=24'hFFFFFF;
        end else begin
            bm_rd<=1'b0;
            pipe_start<=1'b0;     // single-cycle blit_start pulse to comp_pipeline
            tri_setup_start<=1'b0;// single-cycle setup start pulse
            tri_p0_rd<=1'b0;      // single-cycle P_SRC texel read pulse
            tri_fb_rd_en<=1'b0;   // single-cycle comp_fbram dst read
            tri_fb_wr_en<=1'b0;   // single-cycle comp_fbram composite write
            stage_barrier<=1'b0;  // single-cycle barrier request unless re-asserted in S_STAGE_BARRIER
            src_sdram_we<=1'b0;   // single-cycle write request unless re-asserted (held in S_STAGE_WR_WAIT)
            stage_we_burst_fsm<=1'b0; // single-cycle burst-write request unless re-asserted
            snap_start<=1'b0;     // single-cycle work->scan snapshot trigger
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
                    c_w         <= 16'd320; c_h <= 16'd240;
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
                    fetch_k<=0; bm_rd<=1; bm_addr<=`RING_QW+cmd_idx*4;
                    rd_ret<=S_COLLECT; state<=S_RD_WAIT;
                end
            end
            S_COLLECT: begin
                cmd_qw[fetch_k]<=rd_data;
                if (fetch_k==2'd3) state<=S_DECODE;
                else begin
                    bm_rd<=1; bm_addr<=`RING_QW+cmd_idx*4+(fetch_k+2'd1);
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
                state<=S_TRI_SWAIT;
            end
            // Wait for setup valid; seed bbox + running accumulators at (ox,oy).
            // Skip degenerate or fully-off (min>max) triangles.
            S_TRI_SWAIT: if (ts_valid) begin
                // guard against registered bbox-max (set at S_TRI_SETUP)
                if (ts_degenerate || (ts_ox > tri_maxx) || (ts_oy > tri_maxy))
                    state<=S_TRI_NEXT;
                else begin
                    tri_ox <= ts_ox;
                    tri_px <= ts_ox;      tri_py <= ts_oy;
                    tri_cv <= 1'b1;        // cursor starts inside the bbox
                    // tri_maxx/tri_maxy already registered at S_TRI_SETUP
                    w0<=ts_w0_0; w1<=ts_w1_0; w2<=ts_w2_0;
                    row_w0<=ts_w0_0; row_w1<=ts_w1_0; row_w2<=ts_w2_0;
                    Wu<=ts_Wu_0; Wv<=ts_Wv_0; Wr<=ts_Wr_0; Wg<=ts_Wg_0; Wb<=ts_Wb_0; Wa<=ts_Wa_0;
                    row_Wu<=ts_Wu_0; row_Wv<=ts_Wv_0; row_Wr<=ts_Wr_0;
                    row_Wg<=ts_Wg_0; row_Wb<=ts_Wb_0; row_Wa<=ts_Wa_0;
                    // [pipeline stage 3a] arm both sub-FSMs empty for this triangle
                    // (the qword cache persists across triangles in a command; it is
                    // dropped only at the per-command STAGE barrier, not here.)
                    pa<=A_PIX; pb<=B_IDLE; pf_wr<=0; pf_rd<=0;
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
                end
                // ==== sub-FSM A: coverage walk -> W*recip mul -> texel addr -> issue P_SRC ====
                case (pa)
                // Evaluate coverage at (tri_px,tri_py). If covered, LATCH the multiply
                // operands into single-fanout regs (the six W*area_recip products happen
                // in A_MUL0 -> pipelined DSP) and dispatch down A; always advance the walk
                // cursor now (stage-1 decoupling). Non-covered pixels skip in 1 cyc.
                A_PIX: begin
                    if (!tri_cv) begin
                        pa<=A_DONE;           // cursor exhausted; let B drain
                    end else if ((w0>=0) && (w1>=0) && (w2>=0)) begin
                        pxs <= tri_px; pys <= tri_py;
                        wu_q <= Wu; wv_q <= Wv; wr_q <= Wr;
                        wg_q <= Wg; wb_q <= Wb; wa_q <= Wa;
                        recip_q <= $signed(ts_area_recip);
                        advance_cursor;
                        pa<=A_MUL0;
                    end else begin
                        advance_cursor;       // non-covered: skip in 1 cyc, stay in A_PIX
                    end
                end
            // Interpolation stage 1b: two 48x24 partial products per lane, split on
            // recip's 24-bit halves (operands >= 0 -> unsigned). Registered -> each
            // is a shallow pipelined multiply; the tile-adder tree of a full 48x48
            // is broken up and finished in S_TRI_MUL1.
            A_MUL0: begin
                pp_u_lo <= $unsigned(wu_q) * recip_q[23:0];  pp_u_hi <= $unsigned(wu_q) * recip_q[47:24];
                pp_v_lo <= $unsigned(wv_q) * recip_q[23:0];  pp_v_hi <= $unsigned(wv_q) * recip_q[47:24];
                pp_r_lo <= $unsigned(wr_q) * recip_q[23:0];  pp_r_hi <= $unsigned(wr_q) * recip_q[47:24];
                pp_g_lo <= $unsigned(wg_q) * recip_q[23:0];  pp_g_hi <= $unsigned(wg_q) * recip_q[47:24];
                pp_b_lo <= $unsigned(wb_q) * recip_q[23:0];  pp_b_hi <= $unsigned(wb_q) * recip_q[47:24];
                pp_a_lo <= $unsigned(wa_q) * recip_q[23:0];  pp_a_hi <= $unsigned(wa_q) * recip_q[47:24];
                pa<=A_MUL1;
            end
            // Interpolation stage 1c: recombine the partial products (adds only).
            // mul_X = pp_lo + (pp_hi << 24) == wX_q * recip_q (bit-exact).
            A_MUL1: begin
                mul_u <= {24'd0,pp_u_lo} + {pp_u_hi,24'd0};
                mul_v <= {24'd0,pp_v_lo} + {pp_v_hi,24'd0};
                mul_r <= {24'd0,pp_r_lo} + {pp_r_hi,24'd0};
                mul_g <= {24'd0,pp_g_lo} + {pp_g_hi,24'd0};
                mul_b <= {24'd0,pp_b_lo} + {pp_b_hi,24'd0};
                mul_a <= {24'd0,pp_a_lo} + {pp_a_hi,24'd0};
                pa<=A_MUL;
            end
            // Interpolation stage 2: round the products and do the nearest-texel
            // clamp; register the clamped coords. The texel-ADDRESS multiply
            // (itv*stride) is deferred to S_TRI_ADDR so it is NOT chained with the
            // wide 96-bit W*recip rounding here in one cycle — that chain was the
            // reported worst path (mul_v[40] -> tri_p0_addr, -5.576 ns).
            A_MUL: begin
                // texel coords (u12.4) then nearest-texel with clamp
                rnd_u = (mul_u + (96'sd1<<<39)) >>> 40;
                rnd_v = (mul_v + (96'sd1<<<39)) >>> 40;
                itu   = (rnd_u + 64'sd8) >>> 4;
                itv   = (rnd_v + 64'sd8) >>> 4;
                tw1r  = c_src_x - 16'd1;
                th1r  = c_src_y - 16'd1;
                if (itu < 0) itu = 0; else if (itu > $signed({16'd0,tw1r})) itu = $signed({16'd0,tw1r});
                if (itv < 0) itv = 0; else if (itv > $signed({16'd0,th1r})) itv = $signed({16'd0,th1r});
                itu_q <= itu; itv_q <= itv;   // registered for the S_TRI_ADDR multiply
                // per-vertex colour
                rnd_r = (mul_r + (96'sd1<<<39)) >>> 40;
                rnd_g = (mul_g + (96'sd1<<<39)) >>> 40;
                rnd_b = (mul_b + (96'sd1<<<39)) >>> 40;
                rnd_a = (mul_a + (96'sd1<<<39)) >>> 40;
                cr_q <= rnd_r[7:0]; cg_q <= rnd_g[7:0];
                cb_q <= rnd_b[7:0]; ca_q <= rnd_a[7:0];
                // comp_fbram destination qword/lane for this pixel (independent of
                // the texel-address multiply, so it stays here). Uses the dispatched
                // pixel's snapshot (pxs/pys), since the walk cursor has already moved on.
                dst_qw_q   <= pys*16'd80 + (pxs>>2);
                dst_lane_q <= pxs[1:0];
                pa<=A_ADDR;
            end
            // Interpolation stage 3a: the texel-row multiply itv*stride, REGISTERED
            // in its own cycle. itv_q is a clamped texel row (<= tex_h-1), so the
            // low 16 bits carry the whole value -> a single 16x16 DSP; registering
            // the product (input itv_q + output tex_row) makes it a pipelined DSP.
            // Doing it combinationally into the address add was an ~8.9 ns multiply
            // feeding tri_p0_addr (the -2.0 ns worst path).
            A_ADDR: begin
                tex_row <= itv_q[15:0] * c_src_stride;
                pa<=A_ADDR2;
            end
            // Interpolation stage 3b: texel byte address add + P_SRC read (adds
            // only; no multiply). One extra cycle per covered pixel, negligible vs.
            // the SDRAM texel-read wait.
            A_ADDR2: begin
                // texel byte address (8-byte aligned; lane = byte[2:1]). Only the
                // adds + register writes live here; the prefetch fill-kick moved to
                // A_ISSUE so tq_hit's tag lookup is not chained behind texbyte's adder.
                texbyte = c_src_off + tex_row + (itu_q<<<1);
                tri_p0_addr <= texbyte[26:0] & ~27'h7;
                tex_lane_q  <= texbyte[2:1];
                pa<=A_ISSUE;
            end
            // Push this pixel's payload into the depth-D FIFO. Stall only when the FIFO
            // is full (pa may run up to TEXFIFO_D pixels ahead of pb). Payload packing
            // MUST match pb's B_IDLE unpack exactly. tri_p0_addr is now updated
            // (texbyte&~7), so its [26:3] qtag is correct.
            A_ISSUE: if (!pf_full) begin
                // best-effort prefetch: kick a fill for this qword when the arbiter is idle
                // and it isn't the qword we just prefetched (last_pf_qtag skips the common
                // 4-consecutive-pixels-share-a-qword case). No tag-RAM read here — that lets
                // tq_tag be a single-reader M10K (see decl). Prefetch is best-effort; pb's
                // B_LOOK/B_FILL demand path is the correctness backbone (bit-exact either way).
                if ((tri_p0_addr[26:3] != last_pf_qtag) && !fill_busy) begin
                    tri_p0_rd    <= 1'b1;
                    fill_busy    <= 1'b1;
                    fill_slot    <= tri_p0_addr[3+:TEXQ_AW];
                    fill_tag     <= tri_p0_addr[3+TEXQ_AW +: TEXQ_TW];
                    last_pf_qtag <= tri_p0_addr[26:3];
                end
                pf_mem[pf_wr[TEXFIFO_AW-1:0]] <=
                    {ca_q, cb_q, cg_q, cr_q, dst_qw_q, dst_lane_q, tri_p0_addr[26:3], tex_lane_q};
                pf_wr <= pf_wr + 1'b1;
                pa<=A_PIX;
            end
            // Address-gen drained (cursor exhausted). Idle until B finishes.
            A_DONE: ;
            default: pa<=A_PIX;
            endcase

            // ==== sub-FSM B: wait texel -> dst read -> 3-stage blend -> comp_fbram write ====
            case (pb)
            // Wait for a queued pixel; unpack the FIFO head into B-local regs and pop.
            // Packing order MUST match pa's A_ISSUE push exactly.
            B_IDLE: if (!pf_empty) begin
                {b_ca, b_cb, b_cg, b_cr, b_dst_qw, b_dst_lane, b_qtag, b_tex_lane} <= pf_head;
                pf_rd <= pf_rd + 1'b1;
                pb <= B_LOOK;
            end
            // Registered qword-cache read (the M10K read cycle): capture data/tag/valid for
            // b_qtag's slot into registers — an atomic snapshot. tq_data + tq_tag are
            // single-reader here -> both infer M10K, so neither is a distributed mux on the
            // fabric clock. b_qtag was registered in B_IDLE so the address carries no adder.
            B_LOOK: begin
                tq_rdata  <= tq_data [b_qtag[TEXQ_AW-1:0]];
                tq_rtag   <= tq_tag  [b_qtag[TEXQ_AW-1:0]];
                tq_rvalid <= tq_valid[b_qtag[TEXQ_AW-1:0]];
                pb <= B_FILL;
            end
            // Resolve the texel off the REGISTERED snapshot. HIT (valid & tag match) -> latch
            // texel_q and go to dst/blend. MISS -> demand-fetch through the single-outstanding
            // arbiter (if idle), then B_WAIT for the in-flight fill and re-read via B_LOOK.
            B_FILL: begin
                if (tq_rvalid && (tq_rtag == b_qtag[23:TEXQ_AW])) begin
                    texel_q <= tq_rdata[b_tex_lane*16 +: 16];
                    if (tri_need_dst) begin
                        tri_fb_rd_en <= 1'b1; tri_fb_rd_qw <= b_dst_qw; pb<=B_DSTW;
                    end else begin dst_q <= 16'd0; pb<=B_WR; end
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
            B_WAIT: if (!fill_busy) pb <= B_LOOK;
            // comp_fbram read has 1-cycle latency: B_DSTW presents rd_en, B_DSTC
            // captures the registered qword and lane-selects the dst pixel.
            B_DSTW: pb<=B_DSTC;
            B_DSTC: begin
                dst_q <= comp_rd_qword[b_dst_lane*16 +: 16];   // [app-surface v1] WORK or surface
                pb<=B_WR;
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

            // Triangle drained when address-gen is done, the blend pipe is empty, and
            // no texel is outstanding -> advance to the next triangle / finish.
            if ((pa==A_DONE) && (pb==B_IDLE) && pf_empty && !fill_busy)
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
                // Publish the new frame: write vctrl + bump frame_counter, then signal
                // C_DONE. (The retired off-screen cache pass used to skip this for
                // target==2; that path no longer exists.)
                bm_wr<=1; bm_be<=8'h0F; bm_addr<=`VCTRL_QW;
                bm_din<={32'd0, vctrl_val};
                frame_counter<=frame_counter+1;
                wr_ret<=S_WR_DONE; state<=S_WR_WAIT;
            end
            S_WR_DONE: begin
                // low32 = done_seq (handshake); high32 = fabric-busy cyc this frame.
                bm_wr<=1; bm_be<=8'hFF; bm_addr<=`BLTCTRL_QW+`C_DONE;
                bm_din<={perf_frame_cyc, submit_reg};
                wr_ret<=S_WR_STATUS; state<=S_WR_WAIT;
            end
            S_WR_STATUS: begin
                // low32 = OSD mirror bits (bit0=osd_restart_pending, the sticky-latched
                // trigger — see the latch above; bit1=osd_fps_on, a genuine persistent
                // level so it's read raw); high32 = compositor-busy (pipe_busy) cyc this
                // frame — unchanged.
                // [profiling] high32 repurposed perf_pipe_cyc -> perf_texwait_cyc (the
                // per-pixel texel-fetch stall). perf_pipe_cyc (~2.45ms) is already known.
                bm_wr<=1; bm_be<=8'hFF; bm_addr<=`BLTCTRL_QW+`C_STATUS;
                bm_din<={perf_texwait_cyc, 30'd0, osd_fps_on, osd_restart_pending};
                wr_ret<=S_WR_PERF;
                state<=S_WR_WAIT;
            end
            S_WR_PERF: begin
                // [profiling] publish perf_tri_cyc to the SPARE high 32 of C_SRCSEL (qw7);
                // low 32 (throttle_cfg[15:8]) preserved via byte-enable. Host reads at
                // C_SRCSEL+4. Then proceed to the vblank work->scan snapshot as before.
                bm_wr<=1; bm_be<=8'hF0; bm_addr<=`BLTCTRL_QW+`C_SRCSEL;
                bm_din<={perf_tri_cyc, 32'd0};
                // [FB-in-BRAM double-buffer] after the frame, snapshot the completed work
                // buffer into the scan buffer (during vblank). C_DONE was already written
                // (S_WR_DONE), so the engine's handshake completes and its next-frame prep
                // overlaps the snapshot; we hold off polling the next submit until it ends.
                wr_ret<=S_SNAP_WAIT;
                state<=S_WR_WAIT;
            end

            // Wait for vblank to start (scanout not fetching scan-buffer lines), then
            // trigger the work->scan copy.
            S_SNAP_WAIT: if (vs_rise) begin snap_start<=1'b1; state<=S_SNAP_BUSY; end
            // snap_start pulsed; wait for the controller to raise busy.
            S_SNAP_BUSY: if (snap_busy) state<=S_SNAP_DRAIN;
            // hold here (not compositing, so the work buffer is stable) until the copy
            // completes, then resume polling for the next frame.
            S_SNAP_DRAIN: if (!snap_busy) state<=S_POLL_SUBMIT;

            // Backpressure-safe generic read: hold bm_rd until the bus accepts
            // it (~mem_busy), then await dout_ready. (mem_busy = ddram busy OR not
            // granted by the arbiter; on the never-busy sim model this is a no-op.)
            S_RD_WAIT: begin
                if (!rd_issued) begin
                    bm_rd <= 1'b1;                       // hold request
                    if (!mem_busy) rd_issued <= 1'b1;     // accepted this cycle
                end else if (mem_dout_ready) begin
                    rd_data <= mem_dout; rd_issued <= 1'b0; state <= rd_ret;
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
        // The work WRITE port is comp_pipeline's alone; the work READ port is shared with
        // the snapshot controller (mux below), so comp_pipeline drives pipe_fb_rd_*.
        .fb_wr_en(pipe_fb_wr_en), .fb_wr_qw(pipe_fb_wr_qw), .fb_wr_lane(pipe_fb_wr_lane), .fb_wr_pix(pipe_fb_wr_pix),
        .fb_rd_en(pipe_fb_rd_en), .fb_rd_qw(pipe_fb_rd_qw), .fb_rd_qword(comp_rd_qword),
        .blit_done(p_blit_done));

    // ── work->scan snapshot controller [FB-in-BRAM double-buffer] ────────────────
    // Streams the completed WORK buffer into the SCAN buffer once per frame during
    // vblank (state S_SNAP_* sequences it). It borrows comp_fbram's work read port, so
    // fb_rd_* is muxed: the snapshot owns it while snap_busy (comp_pipeline is idle
    // between frames), otherwise comp_pipeline's RMW read drives it.
    fbram_snapshot #(.FB_QWORDS(`FB_QWORDS), .AW(15)) u_snap (   // [#97] single-source from blitter_defs.vh
        .clk(clk), .rst(rst), .start(snap_start), .busy(snap_busy),
        .rd_en(snap_rd_en), .rd_qw(snap_rd_qw), .rd_qword(fb_rd_qword),
        .snap_we(fb_snap_we), .snap_qw(fb_snap_qw), .snap_qword(fb_snap_qword));
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
    // APPSURF surface by comp_target. The work->scan snapshot ALWAYS targets WORK and
    // keeps priority on the WORK read port. When comp_target==WORK (every frame that
    // never emits SET_TARGET) the WORK paths are byte-identical to before and the
    // surface ports are idle.

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

    // WORK read port: snapshot (always WORK) wins; else the compositor when target==WORK.
    assign fb_rd_en = snap_busy ? snap_rd_en : (appsurf_active ? 1'b0 : cr_en);
    assign fb_rd_qw = snap_busy ? snap_rd_qw : cr_qw;
    // SURFACE read port: the compositor when target==APPSURF (snapshot never reads it).
    assign surf_rd_en = (!snap_busy && appsurf_active) ? cr_en : 1'b0;
    assign surf_rd_qw = cr_qw;

    // Read result back to the renderer: surface when compositing APPSURF, else WORK.
    // comp_target is stable across a whole blit (it only moves at SET_TARGET, between
    // fully-drained blits), so the 1-cycle read latency never straddles a target change.
    // The snapshot reads fb_rd_qword directly and is unaffected by this mux.
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
