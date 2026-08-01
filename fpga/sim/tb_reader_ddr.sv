// tb_reader_ddr.sv — [DDR-scanout custom-reader] verifies openbor_video_reader's ddr_* burst
// line-fetch AND its vertical (Y) FLIP un-flip (device-fix). A behavioral DDR model backs the
// reader's ddr_* master with TWO distinct-patterned framebuffers + a control word; the real
// openbor_video_timing drives the reader. Each timing frame the bench bumps the control-word
// frame_counter and sets active_buffer.
//
// Checks:
//   (a) FETCH address (Y): each `FB_STRIDE_QW-beat read == buf_base + display_line*`FB_STRIDE_QW (FORWARD).
//   (b) FETCH data 1:1: every line-buffer qword == the active buffer's qword at the fetched
//       (Y-reversed) line.
//   (c) OUTPUT orientation (Y only): during active display, the output pixel cur_pix at screen
//       (hcol, vcount) == the active buffer's pixel at STORAGE (hcol AND vcount UNCHANGED).
//   (d) JOY writeback: each frame start publishes the live joystick words.
//   (e) [Phase 3 B2] SCANOUT-PERIOD COUNTER: the reader's scan_frame_cnt advances EXACTLY
//       once per scanout frame boundary, is published to SCANFRM_ADDR once per frame in the
//       SCANOUT_ONLY *ship* configuration (which skips VSYNC_ADDR entirely), each published
//       value is +1 on the last, and the published period equals the timing generator's
//       exact frame period in ddr_clk cycles (H_TOTAL x V_TOTAL x the ce_pix divider).
//   (f) [#15] LINE-BUFFER BANK COLLISION: a fill must never write the bank the display is
//       reading while active video is on. NOTE (measured): a collision is a LEADING
//       INDICATOR, not a defect — for inter-beat gaps 5..19 the fill collides but stays
//       ahead of the read and every pixel is still correct.
//   (g) [#15] DISPLAYED-ROW PROVENANCE: ungated by the (c) pacing gate — per active row,
//       pixels matching that row vs pixels matching ROW 0, cross-checked against the
//       fill-side bank_src[]. Catches the device symptom directly: row N byte-identical
//       to row 0.
//   (h) [#15] ST_WAIT_DISPLAY re-anchor (underflow) events, which the RTL only counts
//       under SOLARUS_DBG_PROBES.
// (c) is the make-or-break: it catches a wrong-axis fix (an accidental X reversal, or none).
//
// [#15 Task 3] The DDR model takes latency knobs (+DDR_G grant latency, +DDR_B inter-beat
// gap, +STALL_LEN/+STALL_ROW/+STALL_FRAME one-shot starvation) and the bench takes a +DIAG
// characterisation mode (+FRAMES, +BEACON_ROW/+BEACON_FRAME, +TRACE/+TRACE_FRAME) driven by
// fpga/sim/sweep_reader_ddr.sh. EVERY knob defaults to the pre-existing behaviour, so the
// plain `./run_sims.sh tb_reader_ddr` gate is unchanged. See .superpowers/sdd/task-3-report.md:
// with NO knobs at all, +DIAG +FRAMES=16 shows row 214 byte-identical to row 0 in frame 11 —
// the frame in which the reader's own 2^22-cycle liveness beacon first fires.
//
// Copyright (C) 2026 — GPL-3.0
`default_nettype none
`timescale 1ns/1ps
`include "blitter_defs.vh"
module tb_reader_ddr;
    localparam [28:0] FB      = 29'd0;             // FB_QW_BASE: CTRL@0, BUF0@8, BUF1@0x8008
    localparam [28:0] CTRLA   = FB;
    localparam [28:0] JOY0A   = FB + 29'd1;        // joystick P1 writeback (byte +0x008)
    localparam [28:0] JOY1A   = FB + 29'd3;        // joystick P2 writeback (byte +0x018)
    localparam [28:0] BUF0    = FB + 29'd8;
    localparam [28:0] BUF1    = FB + 29'h8008;
    // OpenBOR-contract input path: the reader must publish these each frame even in
    // SCANOUT_ONLY builds — the engine reads them from /dev/mem (P1 +0x008, P2 +0x018).
    localparam [31:0] JOY0_VAL = 32'h0000_0113;    // right+up+Sword+Pause pattern
    localparam [31:0] JOY1_VAL = 32'h0000_0025;    // right+down+Action pattern
    // Geometry from the FB root (blitter_defs.vh) — never retype a dimension.
    localparam integer NQW    = `FB_QWORDS;      // qwords per framebuffer (15552 @288x216)
    localparam integer STRIDE = `FB_STRIDE_QW;   // qwords per FB row (72 @288)
    localparam [7:0]   BURST_B = 8'(`FB_STRIDE_QW); // reader per-line burst-beat count (sized)
    localparam integer VACT   = `FB_H;
    localparam integer HACT   = `FB_W;

    reg clk = 1'b0; always #5 clk = ~clk;          // single clock (clk_vid == ddr_clk)
    reg reset = 1'b1;
    // ce_pix ~1-in-4 (paced): the display line-fetch is paced by new_line; a full-rate ce_pix
    // would let the pixel output outrun the fetch (linebuf underflow -> stale line), a sim
    // artifact, not device behavior (device ce_pix is the Genesis H40 rate).
    reg [1:0] ce_div = 2'd0;
    always @(posedge clk) ce_div <= ce_div + 2'd1;
    wire ce_pix = (ce_div == 2'd0);   // ~1-in-4: paced enough (fetch keeps up), faster sim

    // ── timing ───────────────────────────────────────────────────────────────────
    wire        tim_hs, tim_vs, tim_hb, tim_vb, tim_de, tim_nf, tim_nl;
    wire [8:0]  tim_vc;
    openbor_video_timing u_timing (
        .clk(clk), .ce_pix(ce_pix), .reset(reset),
        .h_adj(5'sd0), .v_adj(4'sd0),
        .hsync(tim_hs), .vsync(tim_vs), .hblank(tim_hb), .vblank(tim_vb), .de(tim_de),
        .hcount(), .vcount(tim_vc), .new_frame(tim_nf), .new_line(tim_nl)
    );

    // ── reader (SCANOUT_ONLY, base 0) ─────────────────────────────────────────────
    wire  [7:0] r_burstcnt;
    wire [28:0] r_addr;
    wire        r_rd, r_we;
    wire [63:0] r_din;
    wire  [7:0] r_be;
    reg  [63:0] r_dout;
    reg         r_dout_ready;
    wire        r_ddr_busy;      // [#15] driven by the delay model below (was a plain reg=0)
    wire [7:0]  reader_r, reader_g, reader_b;

    openbor_video_reader #(.FB_QW_BASE(FB), .SCANOUT_ONLY(1'b1)) u_reader (
        .ddr_clk(clk), .ddr_busy(r_ddr_busy),
        .ddr_burstcnt(r_burstcnt), .ddr_addr(r_addr), .ddr_dout(r_dout),
        .ddr_dout_ready(r_dout_ready), .ddr_rd(r_rd), .ddr_din(r_din), .ddr_be(r_be), .ddr_we(r_we),
        .clk_vid(clk), .ce_pix(ce_pix), .reset(reset),
        .de(tim_de), .hblank(tim_hb), .vblank(tim_vb), .new_frame(tim_nf), .new_line(tim_nl),
        .vcount(tim_vc),
        .ioctl_download(1'b0), .ioctl_wr(1'b0), .ioctl_addr(27'd0), .ioctl_dout(8'd0), .ioctl_wait(),
        .joystick_0(JOY0_VAL), .joystick_1(JOY1_VAL), .joystick_2(32'd0), .joystick_3(32'd0),
        .joystick_l_analog_0(16'd0),
        .r_out(reader_r), .g_out(reader_g), .b_out(reader_b),
        .enable(1'b1), .frame_ready(),
        .dbg_blt(32'd0), .dbg_addr(32'd0), .dbg_diag(32'd0)
    );

    // ── per-pixel test pattern: pix(buf,x,y) packed into the buffer (qw=y*`FB_STRIDE_QW+x/4, lane=x%4) ──
    function [15:0] pix(input integer b, input integer x, input integer y);
        pix = {b[0], x[7:0], y[6:0]};
    endfunction

    reg [63:0] mem0 [0:NQW-1];
    reg [63:0] mem1 [0:NQW-1];
    // ctrl_word must be a WIRE: an `always @(*)` version never evaluates at t=0
    // (declaration-time inits fire no change event in iverilog), leaving it X
    // until the first fc toggle at ~4.4ms. The POLL-anchored audio path issues
    // the first ctrl read at ~165us, which captured that X into
    // prev_frame_counter and poisoned frame detection for the whole run.
    wire [31:0] ctrl_word;
    integer i, qw, ln, xx, r_i, rows_missing;
    // active buffer pixel at STORAGE (x,y)
    function [15:0] bufpix(input integer act, input integer x, input integer y);
        reg [63:0] q;
        begin
            q = act ? mem1[y*STRIDE + (x/4)] : mem0[y*STRIDE + (x/4)];
            bufpix = q[(x%4)*16 +: 16];
        end
    endfunction

    function [63:0] mem_read(input [28:0] a);
        begin
            if (a == CTRLA)                              mem_read = {32'd0, ctrl_word};
            else if (a >= BUF0 && a < BUF0 + NQW)        mem_read = mem0[a - BUF0];
            else if (a >= BUF1 && a < BUF1 + NQW)        mem_read = mem1[a - BUF1];
            // Audio ring pointers (ABSOLUTE addresses since the native-audio PR):
            // model an IDLE ring (wr==rd==0) so the un-gated audio_wake takes the
            // backoff path instead of burst-reading a garbage 0xDEADDEAD wr_ptr —
            // which is what a real idle device reads there.
            else if (a == 29'h07400006 || a == 29'h07400007) mem_read = 64'd0;
            else                                         mem_read = 64'hDEAD_DEAD_DEAD_DEAD;
        end
    endfunction

    // ── [#15 Task 3] DDR delay model ─────────────────────────────────────────────
    // The original model was zero-latency: it accepted a read the cycle it saw r_rd,
    // streamed one beat per cycle, and never asserted ddr_busy. Three knobs give it
    // real latency. ALL default to 0/off, and at the defaults the model is cycle-for-
    // cycle identical to the original (grant_cnt/stall_cnt stay 0 -> ddr_busy stays 0,
    // gap_cnt stays 0 -> one beat per cycle starting the cycle after acceptance).
    //
    //   +DDR_G=<n>   GRANT LATENCY. After every accepted transaction (a completed read
    //                burst or an accepted write) the model holds ddr_busy for n cycles:
    //                "the arbiter is serving another master". The reader gates EVERY
    //                request on !ddr_busy (ST_READ_LINE:907, ST_POLL_CTRL:837, all the
    //                write states), so it stalls in-state exactly the way the device's
    //                max_fetch_stall instrument measures. Note the reader never asserts
    //                ddr_rd while busy, so latency must be modelled as bus occupancy
    //                BEFORE the request, not as a delayed response to one.
    //   +DDR_B=<n>   INTER-BEAT GAP. n idle cycles between burst beats once serving
    //                (a slow / shared f2h read stream).
    //   +STALL_LEN, +STALL_ROW, +STALL_FRAME
    //                ONE-SHOT stall: hold ddr_busy for STALL_LEN cycles starting when
    //                the display reaches STALL_ROW on frame STALL_FRAME (also freezes a
    //                burst mid-stream). Models a single long starvation event rather
    //                than a uniform per-access latency.
    // ── [#15 Task 3b] UNTAGGED-BEAT-CAPTURE injectors ────────────────────────────
    // The reader files every beat under whatever display_line is live when it
    // arrives (`lb_waddr <= {display_line[0], beat_count}`, :562) — there is no tag
    // matching a response to its request. These four knobs exercise every way a
    // response can be misattributed. All off by default.
    //
    //   +DEFER_LINE=<n> +DEFER_CYC=<c>   hold the burst requested for display_line n
    //                for c cycles before streaming it (a LATE response).
    //   +DROP_LINE=<n> +DROP_BEATS=<k>   deliver only (72-k) beats of line n's burst,
    //                so beat_count never reaches LINE_BURST and the reader ABANDONS
    //                it via ST_WAIT_LINE's TIMEOUT_MAX escape.
    //   +EXTRA_LINE=<n> +EXTRA_BEATS=<k> +EXTRA_DELAY=<d>   after line n's burst
    //                completes, emit k more UNREQUESTED beats of line n's data d
    //                cycles later (an OVER-delivering fabric); they land in whatever
    //                ST_WAIT_LINE is live then.
    //   +MISROUTE_LINE=<n> +MISROUTE_SRC=<m>  serve line n's request with line m's
    //                DATA (a stale/mis-routed response — the pure untagged failure).
    integer DDR_G = 0, DDR_B = 0;
    integer STALL_LEN = 0, STALL_ROW = -1, STALL_FRAME = 3;
    integer DEFER_LINE = -1, DEFER_CYC = 0;
    integer DROP_LINE  = -1, DROP_BEATS = 0;
    integer EXTRA_LINE = -1, EXTRA_BEATS = 0, EXTRA_DELAY = 0, EXTRA_AT_DLINE = -1;
    integer MISROUTE_LINE = -1, MISROUTE_SRC = 0;
    integer INJ_FRAME = 5;   // all four injectors are ONE-SHOT, on this frame
    integer mon_frame = 0;   // monitor-side frame index (declared here: used by the model)

    // serve: on an accepted read (r_rd & ~busy) latch addr+cnt, stream cnt beats.
    reg        serving = 1'b0;
    reg [28:0] rd_addr_l;
    reg  [7:0] rd_cnt_l, rd_i;
    integer    grant_cnt = 0;      // grant-latency countdown
    integer    gap_cnt   = 0;      // inter-beat gap countdown
    integer    stall_cnt = 0;      // one-shot injected stall countdown
    reg        stall_armed = 1'b1;
    integer    defer_cnt = 0;      // late-response countdown for THIS burst
    integer    drop_n    = 0;      // beats withheld from THIS burst
    reg [8:0]  req_line;           // display_line at acceptance (which line asked)
    // stray/unrequested beat stream, independent of `serving`
    integer    xtra_wait = 0, xtra_left = 0, xtra_i = 0;
    reg [28:0] xtra_addr;
    reg        xtra_armed = 1'b1;
    reg        def_armed = 1'b1, drop_armed = 1'b1, mis_armed = 1'b1;
    assign r_ddr_busy = (grant_cnt != 0) || (stall_cnt != 0);

    always @(posedge clk) begin
        r_dout_ready <= 1'b0;
        if (reset) begin
            serving <= 1'b0; grant_cnt <= 0; gap_cnt <= 0; stall_cnt <= 0;
            defer_cnt <= 0; drop_n <= 0; xtra_wait <= 0; xtra_left <= 0;
        end
        else begin
            if (grant_cnt != 0) grant_cnt <= grant_cnt - 1;
            if (stall_cnt != 0) stall_cnt <= stall_cnt - 1;
            // one-shot stall trigger (kept in THIS block so stall_cnt has one driver)
            if (stall_armed && STALL_LEN > 0 && STALL_ROW >= 0
                && mon_frame == STALL_FRAME && tim_de && tim_vc == 9'(STALL_ROW)) begin
                stall_cnt   <= STALL_LEN;
                stall_armed <= 1'b0;
                $display("DIAG stall injected len=%0d at frame=%0d row=%0d state=%0d dline=%0d",
                         STALL_LEN, mon_frame, tim_vc, u_reader.state, u_reader.display_line);
            end

            // ---- stray-beat emitter (has priority over the normal stream) ----
            // Release either after EXTRA_DELAY cycles, or (EXTRA_AT_DLINE >= 0) the
            // moment the reader is sitting in ST_WAIT_LINE for that display_line —
            // i.e. exactly "the stale beats land while display_line == 214".
            if (xtra_wait != 0
                && !(EXTRA_AT_DLINE >= 0 && u_reader.state == 5'd5
                     && u_reader.display_line == 9'(EXTRA_AT_DLINE)))
                xtra_wait <= (EXTRA_AT_DLINE >= 0) ? xtra_wait : xtra_wait - 1;
            else if (xtra_left != 0 && stall_cnt == 0) begin
                r_dout       <= mem_read(xtra_addr + 29'(xtra_i));
                r_dout_ready <= 1'b1;
                xtra_i       <= xtra_i + 1;
                xtra_left    <= xtra_left - 1;
                if (xtra_left == 1)
                    $display("DIAG XTRA %0d stray beats delivered, last at frame=%0d vc=%0d state=%0d dline=%0d",
                             EXTRA_BEATS, mon_frame, tim_vc, u_reader.state, u_reader.display_line);
            end
            else if (!serving) begin
                if (r_rd && !r_ddr_busy) begin
                    req_line  <= u_reader.display_line;
                    rd_cnt_l  <= r_burstcnt; rd_i <= 8'd0;
                    gap_cnt   <= DDR_B;      serving <= 1'b1;
                    // MISROUTE: same beat count, DATA of a different source line.
                    if (mis_armed && MISROUTE_LINE >= 0 && mon_frame >= INJ_FRAME
                        && u_reader.display_line == 9'(MISROUTE_LINE)) begin
                        mis_armed <= 1'b0;
                        rd_addr_l <= 29'(int'(r_addr) + (MISROUTE_SRC - MISROUTE_LINE) * STRIDE);
                        $display("DIAG MISROUTE serving dline=%0d with line %0d data (frame=%0d vc=%0d)",
                                 MISROUTE_LINE, MISROUTE_SRC, mon_frame, tim_vc);
                    end
                    else rd_addr_l <= r_addr;
                    if (def_armed && DEFER_LINE >= 0 && mon_frame >= INJ_FRAME
                        && u_reader.display_line == 9'(DEFER_LINE)) begin
                        defer_cnt <= DEFER_CYC; def_armed <= 1'b0;
                    end else defer_cnt <= 0;
                    if (drop_armed && DROP_LINE >= 0 && mon_frame >= INJ_FRAME
                        && u_reader.display_line == 9'(DROP_LINE)) begin
                        drop_n <= DROP_BEATS; drop_armed <= 1'b0;
                    end else drop_n <= 0;
                end
                else if (r_we && !r_ddr_busy) grant_cnt <= DDR_G;   // write accepted
            end
            else if (stall_cnt != 0) begin
                // injected stall freezes the burst mid-stream too
            end
            else if (defer_cnt != 0) begin
                defer_cnt <= defer_cnt - 1;      // late response: reader waits in ST_WAIT_LINE
                if (defer_cnt == 1)
                    $display("DIAG DEFER line %0d burst released at frame=%0d vc=%0d state=%0d dline=%0d",
                             DEFER_LINE, mon_frame, tim_vc, u_reader.state, u_reader.display_line);
            end
            else if (gap_cnt != 0) begin
                gap_cnt <= gap_cnt - 1;
            end
            else if (drop_n != 0 && rd_i == rd_cnt_l - 8'(drop_n)) begin
                serving <= 1'b0; grant_cnt <= DDR_G;   // burst truncated -> reader hangs
                $display("DIAG DROP line %0d truncated after %0d beats (frame=%0d vc=%0d)",
                         DROP_LINE, rd_i, mon_frame, tim_vc);
            end
            else begin
                r_dout       <= mem_read(rd_addr_l + {21'd0, rd_i});
                r_dout_ready <= 1'b1;
                rd_i         <= rd_i + 8'd1;
                gap_cnt      <= DDR_B;
                if (rd_i == rd_cnt_l - 8'd1) begin
                    serving <= 1'b0; grant_cnt <= DDR_G;
                    if (xtra_armed && EXTRA_BEATS > 0 && EXTRA_LINE >= 0
                        && mon_frame >= INJ_FRAME && req_line == 9'(EXTRA_LINE)) begin
                        xtra_armed <= 1'b0;
                        xtra_addr  <= rd_addr_l;
                        xtra_i     <= 0;
                        xtra_left  <= EXTRA_BEATS;
                        xtra_wait  <= (EXTRA_AT_DLINE >= 0) ? 1 : EXTRA_DELAY;
                    end
                end
            end
        end
    end

    // ── (d) joystick writeback: each frame start writes JOY0/JOY1 with the live values ──
    integer joy0_writes = 0, joy1_writes = 0, joy_errs = 0;
    always @(posedge clk) begin
        if (!reset && r_we && !r_ddr_busy) begin
            if (r_addr == JOY0A) begin
                joy0_writes = joy0_writes + 1;
                if (r_din !== {32'd0, JOY0_VAL}) begin
                    if (joy_errs < 8) $display("  JOY0 DATA MISMATCH got=%h exp=%h", r_din, {32'd0, JOY0_VAL});
                    joy_errs = joy_errs + 1;
                end
            end
            if (r_addr == JOY1A) begin
                joy1_writes = joy1_writes + 1;
                if (r_din !== {32'd0, JOY1_VAL}) begin
                    if (joy_errs < 8) $display("  JOY1 DATA MISMATCH got=%h exp=%h", r_din, {32'd0, JOY1_VAL});
                    joy_errs = joy_errs + 1;
                end
            end
        end
    end

    // ── (e) [Phase 3 B2] scanout frame counter + period ───────────────────────────
    // SCANFRM_ADDR = VSYNC_ADDR + 3 = FB + 0x0E003 (byte 0x3BFB0018 at the ship base).
    // This bench runs the reader in the SHIP configuration (SCANOUT_ONLY=1, no
    // SOLARUS_DBG_PROBES), which is exactly the build where VSYNC_ADDR is NOT written —
    // so reaching this address proves the counter publishes on the ship path.
    localparam [28:0] SCANFRMA = FB + 29'h0E003;
    // Exact scanout period in bench clk cycles: H_TOTAL(380) x V_TOTAL(262) x the 1-in-4
    // ce_pix divider above. Both the timing generator and the reader see the same clock
    // here, so this is an EXACT expectation, not a tolerance.
    localparam integer EXP_PERIOD = 380 * 262 * 4;   // 398,240

    integer tb_frames      = 0;   // bench-side count of tim_nf rising edges = ground truth
    integer scanfrm_writes = 0, scanfrm_errs = 0, period_checks = 0, track_checks = 0;
    reg [31:0] last_scanfrm = 32'hFFFF_FFFF;
    reg        nf_q2 = 1'b0;
    integer    rtl_cnt;

    // (e1) continuous tracking invariant: the reader's ddr_clk-domain counter equals the
    // bench's clk_vid-domain frame count, modulo the fixed new_frame CDC latency (a couple
    // of cycles, never a whole frame). Counting twice, counting on new_line, counting on a
    // level instead of an edge, or not counting all break this within the first frames.
    // tb_frames is updated (blocking) and read in this SAME always block, in program order,
    // so the check always sees the current-cycle value — no cross-block scheduling race
    // against the update. (Previously a separate always block read tb_frames from another
    // block's blocking assignment; iverilog's inter-block evaluation order for that pair is
    // not guaranteed, so the check could observe either the pre- or post-update value on a
    // frame-boundary cycle. That non-determinism was masked, not fixed, by the +-1 tolerance
    // below — the tolerance stays because the CDC latency is real, not because of the race.)
    always @(posedge clk) begin
        nf_q2 <= tim_nf;
        if (!reset && tim_nf && !nf_q2) tb_frames = tb_frames + 1;

        if (!reset) begin
            rtl_cnt = u_reader.scan_frame_cnt;
            track_checks = track_checks + 1;
            if (rtl_cnt > tb_frames || (tb_frames - rtl_cnt) > 1) begin
                if (scanfrm_errs < 8)
                    $display("  SCANFRM TRACK MISMATCH t=%0t rtl=%0d tb=%0d", $time, rtl_cnt, tb_frames);
                scanfrm_errs = scanfrm_errs + 1;
            end
        end
    end

    // (e2) the published qword: one write per frame, low word == the live counter and
    // exactly +1 on the previous write, high word == the exact frame period.
    always @(posedge clk) begin
        if (!reset && r_we && !r_ddr_busy && r_addr == SCANFRMA) begin
            scanfrm_writes = scanfrm_writes + 1;
            if (r_din[31:0] !== u_reader.scan_frame_cnt) begin
                if (scanfrm_errs < 8) $display("  SCANFRM PUBLISH MISMATCH got=%0d live=%0d",
                    r_din[31:0], u_reader.scan_frame_cnt);
                scanfrm_errs = scanfrm_errs + 1;
            end
            if (last_scanfrm !== 32'hFFFF_FFFF && r_din[31:0] !== (last_scanfrm + 32'd1)) begin
                if (scanfrm_errs < 8) $display("  SCANFRM DELTA != 1: prev=%0d now=%0d",
                    last_scanfrm, r_din[31:0]);
                scanfrm_errs = scanfrm_errs + 1;
            end
            last_scanfrm = r_din[31:0];
            // Period: frame 1's interval is measured from reset (not a real boundary), so
            // check from frame 2 on — those are true boundary-to-boundary intervals.
            if (r_din[31:0] >= 32'd2) begin
                period_checks = period_checks + 1;
                if (r_din[63:32] !== EXP_PERIOD) begin
                    if (scanfrm_errs < 8) $display("  SCANFRM PERIOD MISMATCH frame=%0d got=%0d exp=%0d",
                        r_din[31:0], r_din[63:32], EXP_PERIOD);
                    scanfrm_errs = scanfrm_errs + 1;
                end
            end
        end
    end

    // ── control-word producer: bump frame_counter each timing frame ───────────────
    reg [29:0] fc = 30'd0;
    reg        model_active = 1'b0;
    reg        nf_q = 1'b0;
    always @(posedge clk) begin
        nf_q <= tim_nf;
        if (!reset && tim_nf && !nf_q) fc <= fc + 30'd1;
    end
    assign ctrl_word = {fc, 1'b0, model_active};

    // ── checks ────────────────────────────────────────────────────────────────────
    integer addr_errs = 0, data_errs = 0, orient_errs = 0, active_err = 0;
    integer addr_checks = 0, data_checks = 0, orient_checks = 0;

    // (a) burst address: FORWARD source line (display_line).
    wire burst_issue = r_rd && (r_burstcnt == BURST_B) && !serving;
    always @(posedge clk) begin
        if (!reset && burst_issue) begin
            if (r_addr !== ((u_reader.active_buffer ? BUF1 : BUF0)
                            + (u_reader.display_line * STRIDE))) begin
                if (addr_errs < 8) $display("  ADDR MISMATCH line=%0d active=%0b got=%h exp=%h",
                    u_reader.display_line, u_reader.active_buffer, r_addr,
                    (u_reader.active_buffer ? BUF1 : BUF0) + (u_reader.display_line * STRIDE));
                addr_errs = addr_errs + 1;
            end
            addr_checks = addr_checks + 1;
        end
    end

    // (b) fetch data 1:1 vs the fetched (forward) source line.
    always @(posedge clk) begin
        if (!reset && u_reader.lb_we) begin
            if (u_reader.lb_wdata !== (u_reader.active_buffer
                    ? mem1[u_reader.display_line * STRIDE + u_reader.lb_waddr[6:0]]
                    : mem0[u_reader.display_line * STRIDE + u_reader.lb_waddr[6:0]])) begin
                if (data_errs < 8) $display("  DATA MISMATCH line=%0d beat=%0d",
                    u_reader.display_line, u_reader.lb_waddr[6:0]);
                data_errs = data_errs + 1;
            end
            data_checks = data_checks + 1;
        end
    end

    // (c) OUTPUT orientation (NO flip): cur_pix at screen (col c,row d) == buffer pixel (col c, row d).
    //     Gated to STABLE (non-flip) frames via orient_arm — the reader tolerates a single-line
    //     re-anchor glitch at a buffer flip (documented; tear-free on device), which is not an
    //     orientation error, so we measure orientation only on settled frames.
    // Gate on the reader's steady-state prefetch pacing (fetch exactly one line ahead:
    // display_line == vcount+1). In this single-clock bench the fetch can transiently lag the
    // display right after frame_ready asserts (startup phase), which reads a stale linebuf
    // line — a sim pacing artifact, not an orientation error. On correctly-paced lines the
    // linebuf[vcount%2] holds the line fetched for display_line=vcount (source vcount).
    reg orient_arm = 1'b0;
    // [#15] per-row coverage: a row that is never checked is a blind spot, not a pass.
    integer rows_seen [0:VACT-1];
    always @(posedge clk) begin
        if (!reset && orient_arm && ce_pix && tim_de && u_reader.frame_ready_vid
            && (u_reader.display_line == (tim_vc + 9'd1))
            && u_reader.hcol < HACT) begin
            // Display (col c, row d) must show framebuffer pixel (col c, row d) UNCHANGED:
            // comp_fb_dma publishes a top-down frame, so scanout must not re-order it. Both an
            // X reversal (col `FB_W-1-c) and a Y reversal (row `FB_H-1-d) fail this.
            // [#15] the `tim_vc < VACT-1` exclusion is GONE: row 215 is the last ACTIVE line,
            // not a vblank line, and rows 214/215 are exactly where the defect lives.
            if (u_reader.cur_pix !== bufpix(u_reader.active_buffer, u_reader.hcol, tim_vc)) begin
                if (orient_errs < 8) $display("  ORIENT MISMATCH screen(%0d,%0d) got=%h exp=%h (buf px %0d,%0d)",
                    u_reader.hcol, tim_vc, u_reader.cur_pix,
                    bufpix(u_reader.active_buffer, u_reader.hcol, tim_vc),
                    u_reader.hcol, tim_vc);
                orient_errs = orient_errs + 1;
            end
            orient_checks = orient_checks + 1;
            rows_seen[tim_vc] = rows_seen[tim_vc] + 1;
        end
    end

    // ── (f) [#15] line-buffer bank collision ─────────────────────────────────────
    // A fill must never write the bank the display is reading out of while active
    // video is on. lb_waddr[7] is the fill bank ({display_line[0], beat_count}),
    // tim_vc[0] is the read bank (linebuf[{vcount[0], hcol[8:2]}]). Ungated and
    // free-running for the whole sim — a collision anywhere is a defect.
    integer collide_errs = 0;
    always @(posedge clk) begin
        if (!reset && u_reader.lb_we && tim_de && (u_reader.lb_waddr[7] == tim_vc[0])) begin
            if (collide_errs < 8)
                $display("  LINEBUF COLLISION row=%0d bank=%0b beat=%0d display_line=%0d",
                         tim_vc, u_reader.lb_waddr[7], u_reader.lb_waddr[6:0],
                         u_reader.display_line);
            collide_errs = collide_errs + 1;
        end
    end

    // ── (g) [#15] displayed-row PROVENANCE monitor ───────────────────────────────
    // Check (c) is gated on the steady-state pacing (display_line == vcount+1), so it
    // is blind exactly when the fetch has fallen out of step — which is the condition
    // under investigation. This monitor is ungated (only frame_ready): for every active
    // row it counts pixels that match the SAME row of the active buffer, and pixels
    // that match ROW 0 of the active buffer. A row with dup0 == `FB_W and vc != 0 is
    // the device symptom itself: row N byte-identical to row 0.
    //
    // bank_src[] is the fill-side ground truth — the display_line whose data currently
    // occupies each line-buffer bank. It names provenance unambiguously; the 16-bit
    // test pattern {buf,x[7:0],y[6:0]} aliases source rows y and y+128, so a data
    // comparison alone cannot distinguish row 0 from row 128.
    integer row_pix [0:VACT-1];
    integer row_ok  [0:VACT-1];
    integer row_dup0[0:VACT-1];
    integer row_bsrc[0:VACT-1];      // bank_src sampled at the row's LAST checked pixel
    integer row_bsrc0[0:VACT-1];     // bank_src sampled at the row's FIRST checked pixel
    integer bank_src [0:1];
    integer dup_events = 0, dup_first_row = -1, dup_first_frame = -1, bad_rows_total = 0;
    integer alias_events = 0;        // content matched row 0 but the bank held row y+128
    integer diag_prints = 0;
    reg     diag_mode = 1'b0, diag_verbose = 1'b0;
    integer rr;
    reg     nf_q3 = 1'b0;

    always @(posedge clk) begin
        if (!reset && u_reader.lb_we) bank_src[u_reader.lb_waddr[7]] = u_reader.display_line;
    end

    always @(posedge clk) begin
        if (!reset && ce_pix && tim_de && u_reader.frame_ready_vid
            && u_reader.hcol < HACT && tim_vc < 9'(VACT)) begin
            if (row_pix[tim_vc] == 0) row_bsrc0[tim_vc] = bank_src[tim_vc[0]];
            row_pix[tim_vc]  = row_pix[tim_vc] + 1;
            if (u_reader.cur_pix === bufpix(u_reader.active_buffer, u_reader.hcol, tim_vc))
                row_ok[tim_vc] = row_ok[tim_vc] + 1;
            if (u_reader.cur_pix === bufpix(u_reader.active_buffer, u_reader.hcol, 0))
                row_dup0[tim_vc] = row_dup0[tim_vc] + 1;
            row_bsrc[tim_vc] = bank_src[tim_vc[0]];
        end
    end

    // frame boundary: classify + reset the per-row accumulators
    always @(posedge clk) begin
        nf_q3 <= tim_nf;
        if (!reset && tim_nf && !nf_q3) begin
            for (rr = 0; rr < VACT; rr = rr + 1) begin
                if (row_pix[rr] > 0 && row_ok[rr] != row_pix[rr]) begin
                    bad_rows_total = bad_rows_total + 1;
                    // Content match against row 0 is necessary but NOT sufficient: the
                    // {buf,x[7:0],y[6:0]} pattern makes source row y+128 bit-identical
                    // to row y, so a bank holding line 128 also "matches row 0".
                    // bank_src (fill-side ground truth) disambiguates.
                    if (row_dup0[rr] == row_pix[rr] && rr != 0) begin
                        if (row_bsrc[rr] == 0 && row_bsrc0[rr] == 0) begin
                            dup_events = dup_events + 1;
                            if (dup_first_row < 0) begin
                                dup_first_row = rr; dup_first_frame = mon_frame;
                            end
                            if (diag_prints < 200) begin
                                $display("DIAG ROWDUP frame=%0d row=%0d shows ROW 0 (all %0d px), bank_src=0",
                                         mon_frame, rr, row_pix[rr]);
                                diag_prints = diag_prints + 1;
                            end
                        end
                        else begin
                            alias_events = alias_events + 1;
                            if (diag_verbose && diag_prints < 200) begin
                                $display("DIAG ROWALIAS frame=%0d row=%0d content==row0 but bank_src=%0d..%0d",
                                         mon_frame, rr, row_bsrc0[rr], row_bsrc[rr]);
                                diag_prints = diag_prints + 1;
                            end
                        end
                    end
                    else if (diag_verbose && diag_prints < 200) begin
                        $display("DIAG ROWBAD frame=%0d row=%0d ok=%0d/%0d dup0=%0d bank_src=%0d",
                                 mon_frame, rr, row_ok[rr], row_pix[rr], row_dup0[rr], row_bsrc[rr]);
                        diag_prints = diag_prints + 1;
                    end
                end
                row_pix[rr] = 0; row_ok[rr] = 0; row_dup0[rr] = 0;
            end
            mon_frame = mon_frame + 1;
        end
    end

    // ── (h) [#15] ST_WAIT_DISPLAY re-anchor (underflow) events ───────────────────
    // The RTL only counts these under SOLARUS_DBG_PROBES; recompute the exact
    // condition (openbor_video_reader.sv:982) from the bench so the ship build is
    // instrumented too.
    integer anchor_events = 0, anchor_first_row = -1, anchor_last_row = -1;
    always @(posedge clk) begin
        if (!reset && u_reader.state == 5'd7 /*ST_WAIT_DISPLAY*/
            && u_reader.new_line_ddr && !u_reader.vblank_ddr
            && u_reader.display_line < (u_reader.vcount_ddr + 9'd1)
            && (u_reader.vcount_ddr + 9'd1) < 9'(VACT)) begin
            anchor_events   = anchor_events + 1;
            if (anchor_first_row < 0) anchor_first_row = u_reader.vcount_ddr;
            anchor_last_row = u_reader.vcount_ddr;
        end
    end

    // wait until the reader has fetched at least `n` distinct display lines this frame
    task wait_lines(input integer n);
        integer got; reg [8:0] last;
        begin
            got = 0; last = 9'h1FF;
            while (got < n) begin
                @(posedge clk);
                if (u_reader.state == 5'd6 /*ST_LINE_DONE*/ && u_reader.display_line != last) begin
                    last = u_reader.display_line; got = got + 1;
                end
            end
        end
    endtask

    // wait `n` timing frames (new_frame rising edges) — used to settle past a buffer flip
    task wait_frames(input integer n);
        integer got; reg q;
        begin
            got = 0; q = tim_nf;
            while (got < n) begin
                @(posedge clk);
                if (tim_nf && !q) got = got + 1;
                q = tim_nf;
            end
        end
    endtask

    // ── [#15 Task 3] DIAG mode ───────────────────────────────────────────────────
    // Off unless +DIAG is passed, so `./run_sims.sh tb_reader_ddr` runs exactly the
    // gate it ran before. In DIAG mode the bench does not $fatal on anything: it runs
    // N frames under the configured DDR delay / injected stall / injected beacon and
    // prints a machine-readable summary for the sweep harness (sweep_reader_ddr.sh).
    integer RUN_FRAMES = 20, BEACON_ROW = -1, BEACON_FRAME = 5, TRACE_FRAME = 0;
    reg     diag_trace = 1'b0;
    integer trace_prints = 0;
    reg [4:0] st_q = 5'd0;

    always @(posedge clk) begin
        st_q <= u_reader.state;
        if (!reset && diag_trace && mon_frame >= TRACE_FRAME && u_reader.state !== st_q
            && trace_prints < 6000) begin
            $display("DIAG FSM t=%0t f=%0d vc=%0d hc=%0d st=%0d->%0d dline=%0d ab=%0b bsrc=%0d/%0d",
                     $time, mon_frame, tim_vc, u_timing.hcount, st_q, u_reader.state,
                     u_reader.display_line, u_reader.active_buffer, bank_src[0], bank_src[1]);
            trace_prints = trace_prints + 1;
        end
    end

    task wait_row(input integer fr, input integer row);
        begin
            while (!(mon_frame == fr && tim_de && tim_vc == 9'(row))) @(posedge clk);
        end
    endtask

    task diag_run;
        begin
            $display("DIAG CFG G=%0d B=%0d stall_len=%0d stall_row=%0d stall_frame=%0d beacon_row=%0d beacon_frame=%0d frames=%0d",
                     DDR_G, DDR_B, STALL_LEN, STALL_ROW, STALL_FRAME, BEACON_ROW, BEACON_FRAME, RUN_FRAMES);
            $display("DIAG CFG2 defer=%0d@line%0d drop=%0d@line%0d extra=%0dx%0d@line%0d misroute=line%0d<-line%0d inj_frame=%0d",
                     DEFER_CYC, DEFER_LINE, DROP_BEATS, DROP_LINE, EXTRA_BEATS, EXTRA_DELAY,
                     EXTRA_LINE, MISROUTE_LINE, MISROUTE_SRC, INJ_FRAME);
            model_active = 1'b0;
            wait_frames(3);
            if (BEACON_ROW >= 0) begin
                wait_row(BEACON_FRAME, BEACON_ROW);
                $display("DIAG BEACON force frame=%0d row=%0d state=%0d dline=%0d",
                         mon_frame, tim_vc, u_reader.state, u_reader.display_line);
                // Emulate the free-running 2^22-cycle beacon timer firing HERE. The
                // real timer's phase relative to the scan position drifts by 211904
                // cycles per fire and would take ~2750 frames of sim to walk into any
                // chosen window; forcing the latch bit for one cycle is the same event.
                force u_reader.beacon_pending = 1'b1;
                @(posedge clk);
                #1 release u_reader.beacon_pending;
            end
            wait_frames(RUN_FRAMES);
            $display("DIAG SUM G=%0d B=%0d stall=%0d@%0d beacon=%0d dup_events=%0d dup_row=%0d dup_frame=%0d alias=%0d bad_rows=%0d collide=%0d anchors=%0d anchor_first=%0d anchor_last=%0d addr_errs=%0d data_errs=%0d frames=%0d",
                     DDR_G, DDR_B, STALL_LEN, STALL_ROW, BEACON_ROW, dup_events, dup_first_row,
                     dup_first_frame, alias_events, bad_rows_total, collide_errs, anchor_events,
                     anchor_first_row, anchor_last_row, addr_errs, data_errs, mon_frame);
            $display("DIAG DONE");
        end
    endtask

    // [#15] arm orientation checking across ONE complete active region (rows 0..VACT-1).
    // new_frame fires at the last pixel of the last active line, so the window between two
    // consecutive new_frame edges is exactly one frame of active video plus its vblank.
    task check_full_frame;
        begin
            wait_frames(1);          // sit at a frame boundary (start of vblank)
            orient_arm = 1'b1;
            wait_frames(1);          // one complete active region
            orient_arm = 1'b0;
        end
    endtask

    initial begin
        for (qw = 0; qw < NQW; qw = qw + 1) begin
            ln = qw / STRIDE; xx = (qw % STRIDE) * 4;
            mem0[qw] = {pix(0, xx+3, ln), pix(0, xx+2, ln), pix(0, xx+1, ln), pix(0, xx+0, ln)};
            mem1[qw] = {pix(1, xx+3, ln), pix(1, xx+2, ln), pix(1, xx+1, ln), pix(1, xx+0, ln)};
        end
        for (r_i = 0; r_i < VACT; r_i = r_i + 1) begin
            rows_seen[r_i] = 0;
            row_pix[r_i]   = 0; row_ok[r_i] = 0; row_dup0[r_i] = 0; row_bsrc[r_i] = -1;
        end
        bank_src[0] = -1; bank_src[1] = -1;
        // [#15 Task 3] plusargs — every one defaults to the pre-existing behaviour.
        void'($value$plusargs("DDR_G=%d",       DDR_G));
        void'($value$plusargs("DDR_B=%d",       DDR_B));
        void'($value$plusargs("STALL_LEN=%d",   STALL_LEN));
        void'($value$plusargs("STALL_ROW=%d",   STALL_ROW));
        void'($value$plusargs("STALL_FRAME=%d", STALL_FRAME));
        void'($value$plusargs("BEACON_ROW=%d",  BEACON_ROW));
        void'($value$plusargs("BEACON_FRAME=%d",BEACON_FRAME));
        void'($value$plusargs("FRAMES=%d",      RUN_FRAMES));
        void'($value$plusargs("TRACE_FRAME=%d", TRACE_FRAME));
        void'($value$plusargs("DEFER_LINE=%d",  DEFER_LINE));
        void'($value$plusargs("DEFER_CYC=%d",   DEFER_CYC));
        void'($value$plusargs("DROP_LINE=%d",   DROP_LINE));
        void'($value$plusargs("DROP_BEATS=%d",  DROP_BEATS));
        void'($value$plusargs("EXTRA_LINE=%d",  EXTRA_LINE));
        void'($value$plusargs("EXTRA_BEATS=%d", EXTRA_BEATS));
        void'($value$plusargs("EXTRA_DELAY=%d", EXTRA_DELAY));
        void'($value$plusargs("EXTRA_AT_DLINE=%d", EXTRA_AT_DLINE));
        void'($value$plusargs("MISROUTE_LINE=%d", MISROUTE_LINE));
        void'($value$plusargs("MISROUTE_SRC=%d",  MISROUTE_SRC));
        void'($value$plusargs("INJ_FRAME=%d",   INJ_FRAME));
        diag_mode    = $test$plusargs("DIAG");
        diag_verbose = $test$plusargs("VERBOSE");
        diag_trace   = $test$plusargs("TRACE");
        model_active = 1'b0;
        repeat (8) @(posedge clk);
        reset <= 1'b0;

        if (diag_mode) begin
            diag_run();
            $finish;
        end

        // BUF0 (active=0): settle a few frames (sync + first full frame -> frame_ready), then
        // measure orientation on a STABLE frame (armed). addr/data run continuously (ungated).
        wait_frames(3);
        check_full_frame();
        $display("BUF0: addr_checks=%0d data_checks=%0d orient_checks=%0d addr_errs=%0d data_errs=%0d orient_errs=%0d active=%0b",
                 addr_checks, data_checks, orient_checks, addr_errs, data_errs, orient_errs, u_reader.active_buffer);
        if (u_reader.active_buffer !== 1'b0) active_err = active_err + 1;

        // Flip to BUF1 — reader switches at the next frame poll (tear-free, one tolerated re-anchor
        // line). Settle PAST the flip frame, then measure orientation on a stable BUF1 frame.
        model_active = 1'b1;
        wait (u_reader.active_buffer === 1'b1);
        wait_frames(3);
        check_full_frame();
        $display("BUF1: addr_checks=%0d data_checks=%0d orient_checks=%0d addr_errs=%0d data_errs=%0d orient_errs=%0d active=%0b",
                 addr_checks, data_checks, orient_checks, addr_errs, data_errs, orient_errs, u_reader.active_buffer);
        if (u_reader.active_buffer !== 1'b1) active_err = active_err + 1;

        // [#15] every active row must have been orientation-checked. A row that the
        // pacing gate skipped is a hole in the test, and rows 214/215 are precisely the
        // rows the old 25-line window and the `tim_vc < VACT-1` exclusion left uncovered.
        rows_missing = 0;
        for (r_i = 0; r_i < VACT; r_i = r_i + 1)
            if (rows_seen[r_i] == 0) begin
                if (rows_missing < 8) $display("  ROW NEVER ORIENTATION-CHECKED: %0d", r_i);
                rows_missing = rows_missing + 1;
            end
        if (rows_missing) begin
            $display("RESULT: FAIL — %0d of %0d active rows were never checked", rows_missing, VACT);
            $fatal;
        end
        if (collide_errs) begin
            $display("RESULT: FAIL — %0d linebuf bank collisions (fill wrote the bank being displayed)",
                     collide_errs);
            $fatal;
        end
        if (addr_checks < 30 || data_checks < 30 || orient_checks < 300) begin
            $display("RESULT: FAIL — too few checks (addr=%0d data=%0d orient=%0d)",
                     addr_checks, data_checks, orient_checks);
            $fatal;
        end
        if (addr_errs || data_errs || orient_errs || active_err) begin
            $display("RESULT: FAIL — addr_errs=%0d data_errs=%0d orient_errs=%0d active_err=%0d",
                     addr_errs, data_errs, orient_errs, active_err);
            $fatal;
        end
        // (d) joystick writeback ran every settled frame with the live values (>=3 frames
        // measured across the BUF0+BUF1 phases; exact count depends on settle timing).
        if (joy0_writes < 3 || joy1_writes < 3 || joy_errs) begin
            $display("RESULT: FAIL — joystick writeback joy0_writes=%0d joy1_writes=%0d joy_errs=%0d",
                     joy0_writes, joy1_writes, joy_errs);
            $fatal;
        end
        // (e) [Phase 3 B2] scanout-period counter: published on the SHIP path, once per
        // frame, monotonic +1, exact period. rtl_cnt is re-read here for the final equality.
        rtl_cnt = u_reader.scan_frame_cnt;
        $display("SCANFRM: writes=%0d period_checks=%0d track_checks=%0d rtl_cnt=%0d tb_frames=%0d errs=%0d",
                 scanfrm_writes, period_checks, track_checks, rtl_cnt, tb_frames, scanfrm_errs);
        if (scanfrm_writes < 5 || period_checks < 3 || track_checks < 1000) begin
            $display("RESULT: FAIL — scanout counter under-exercised (writes=%0d period_checks=%0d track_checks=%0d)",
                     scanfrm_writes, period_checks, track_checks);
            $fatal;
        end
        if (scanfrm_errs || rtl_cnt > tb_frames || (tb_frames - rtl_cnt) > 1) begin
            $display("RESULT: FAIL — scanout frame counter errs=%0d rtl_cnt=%0d tb_frames=%0d",
                     scanfrm_errs, rtl_cnt, tb_frames);
            $fatal;
        end
        $display("reader_ddr: scanout counter @SCANFRM_ADDR advances exactly once per scanout frame (period=%0d cyc), published on the SCANOUT_ONLY ship path", EXP_PERIOD);
        // (g)/(h) [#15] informational: the ungated provenance monitor and the
        // ST_WAIT_DISPLAY re-anchor counter, over the whole standard run.
        $display("ROWPROV: dup_events=%0d dup_row=%0d bad_rows=%0d anchors=%0d (informational)",
                 dup_events, dup_first_row, bad_rows_total, anchor_events);
        $display("reader_ddr: ddr_* fetch reads the ACTIVE buffer; FORWARD scanout — screen(c,d)=buf(c,d), no re-ordering, both buffers");
        $display("RESULT: PASS");
        $finish;
    end

    initial begin #900_000_000 $display("RESULT: FAIL — TIMEOUT"); $fatal; end
endmodule
`default_nettype wire
