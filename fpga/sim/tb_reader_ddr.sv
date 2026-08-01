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
// (c) is the make-or-break: it catches a wrong-axis fix (an accidental X reversal, or none).
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
    reg         r_ddr_busy;
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

    // serve: on an accepted read (r_rd & ~busy) latch addr+cnt, stream cnt beats.
    reg        serving = 1'b0;
    reg [28:0] rd_addr_l;
    reg  [7:0] rd_cnt_l, rd_i;
    always @(posedge clk) begin
        r_dout_ready <= 1'b0;
        r_ddr_busy   <= 1'b0;
        if (reset) begin serving <= 1'b0; end
        else if (!serving) begin
            if (r_rd) begin rd_addr_l <= r_addr; rd_cnt_l <= r_burstcnt; rd_i <= 8'd0; serving <= 1'b1; end
        end else begin
            r_dout       <= mem_read(rd_addr_l + {21'd0, rd_i});
            r_dout_ready <= 1'b1;
            rd_i         <= rd_i + 8'd1;
            if (rd_i == rd_cnt_l - 8'd1) serving <= 1'b0;
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
        for (r_i = 0; r_i < VACT; r_i = r_i + 1) rows_seen[r_i] = 0;
        model_active = 1'b0;
        repeat (8) @(posedge clk);
        reset <= 1'b0;

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
        $display("reader_ddr: ddr_* fetch reads the ACTIVE buffer; FORWARD scanout — screen(c,d)=buf(c,d), no re-ordering, both buffers");
        $display("RESULT: PASS");
        $finish;
    end

    initial begin #900_000_000 $display("RESULT: FAIL — TIMEOUT"); $fatal; end
endmodule
`default_nettype wire
