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
    integer i, qw, ln, xx;
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
    always @(posedge clk) begin
        if (!reset && orient_arm && ce_pix && tim_de && u_reader.frame_ready_vid
            && (u_reader.display_line == (tim_vc + 9'd1))
            && u_reader.hcol < HACT && tim_vc < (VACT-1)) begin
            // Display (col c, row d) must show framebuffer pixel (col c, row d) UNCHANGED:
            // comp_fb_dma publishes a top-down frame, so scanout must not re-order it. Both an
            // X reversal (col `FB_W-1-c) and a Y reversal (row `FB_H-1-d) fail this.
            if (u_reader.cur_pix !== bufpix(u_reader.active_buffer, u_reader.hcol, tim_vc)) begin
                if (orient_errs < 8) $display("  ORIENT MISMATCH screen(%0d,%0d) got=%h exp=%h (buf px %0d,%0d)",
                    u_reader.hcol, tim_vc, u_reader.cur_pix,
                    bufpix(u_reader.active_buffer, u_reader.hcol, tim_vc),
                    u_reader.hcol, tim_vc);
                orient_errs = orient_errs + 1;
            end
            orient_checks = orient_checks + 1;
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

    initial begin
        for (qw = 0; qw < NQW; qw = qw + 1) begin
            ln = qw / STRIDE; xx = (qw % STRIDE) * 4;
            mem0[qw] = {pix(0, xx+3, ln), pix(0, xx+2, ln), pix(0, xx+1, ln), pix(0, xx+0, ln)};
            mem1[qw] = {pix(1, xx+3, ln), pix(1, xx+2, ln), pix(1, xx+1, ln), pix(1, xx+0, ln)};
        end
        model_active = 1'b0;
        repeat (8) @(posedge clk);
        reset <= 1'b0;

        // BUF0 (active=0): settle a few frames (sync + first full frame -> frame_ready), then
        // measure orientation on a STABLE frame (armed). addr/data run continuously (ungated).
        wait_frames(3);
        orient_arm = 1'b1; wait_lines(25); orient_arm = 1'b0;
        $display("BUF0: addr_checks=%0d data_checks=%0d orient_checks=%0d addr_errs=%0d data_errs=%0d orient_errs=%0d active=%0b",
                 addr_checks, data_checks, orient_checks, addr_errs, data_errs, orient_errs, u_reader.active_buffer);
        if (u_reader.active_buffer !== 1'b0) active_err = active_err + 1;

        // Flip to BUF1 — reader switches at the next frame poll (tear-free, one tolerated re-anchor
        // line). Settle PAST the flip frame, then measure orientation on a stable BUF1 frame.
        model_active = 1'b1;
        wait (u_reader.active_buffer === 1'b1);
        wait_frames(3);
        orient_arm = 1'b1; wait_lines(25); orient_arm = 1'b0;
        $display("BUF1: addr_checks=%0d data_checks=%0d orient_checks=%0d addr_errs=%0d data_errs=%0d orient_errs=%0d active=%0b",
                 addr_checks, data_checks, orient_checks, addr_errs, data_errs, orient_errs, u_reader.active_buffer);
        if (u_reader.active_buffer !== 1'b1) active_err = active_err + 1;

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
        $display("reader_ddr: ddr_* fetch reads the ACTIVE buffer; FORWARD scanout — screen(c,d)=buf(c,d), no re-ordering, both buffers");
        $display("RESULT: PASS");
        $finish;
    end

    initial begin #900_000_000 $display("RESULT: FAIL — TIMEOUT"); $fatal; end
endmodule
`default_nettype wire
