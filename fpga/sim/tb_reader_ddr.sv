// tb_reader_ddr.sv — [DDR-scanout custom-reader / Option A] verifies openbor_video_reader's
// NEW ddr_* burst line-fetch reads the correct ACTIVE DDR buffer (BUF0/BUF1 by active_buffer)
// at the correct per-line addresses, and captures the buffer's qwords into the line buffer 1:1.
//
// Setup: the real openbor_video_timing drives the reader (ce_pix full-rate). A behavioral DDR
// model backs the reader's ddr_* master with TWO distinct-patterned framebuffers + a control
// word. Each timing frame the bench bumps the control-word frame_counter (so the reader detects
// a new frame) and sets active_buffer. Checks, per fetched line:
//   (a) the reader's burst read address == (active ? BUF1 : BUF0) + line*80  (buffer + line select)
//   (b) every captured line-buffer qword == the active buffer's qword at that (line,beat)  (data 1:1)
// and that flipping active_buffer switches the displayed buffer.
//
// Copyright (C) 2026 — GPL-3.0
`default_nettype none
`timescale 1ns/1ps
module tb_reader_ddr;
    localparam [28:0] FB      = 29'd0;             // FB_QW_BASE: CTRL@0, BUF0@8, BUF1@0x8008
    localparam [28:0] CTRLA   = FB;                // 0
    localparam [28:0] BUF0    = FB + 29'd8;        // 8
    localparam [28:0] BUF1    = FB + 29'h8008;     // 0x8008
    localparam integer NQW    = 19200;             // 320x240/4
    localparam integer STRIDE = 80;                // qwords/line
    localparam integer VACT   = 240;

    reg clk = 1'b0; always #5 clk = ~clk;          // single clock (clk_vid == ddr_clk)
    reg reset = 1'b1;
    reg ce_pix = 1'b1;                             // full-rate pixel enable

    // ── timing ───────────────────────────────────────────────────────────────────
    wire        tim_hs, tim_vs, tim_hb, tim_vb, tim_de, tim_nf, tim_nl;
    wire [9:0]  tim_hc;
    wire [8:0]  tim_vc;
    openbor_video_timing u_timing (
        .clk(clk), .ce_pix(ce_pix), .reset(reset),
        .h_adj(5'sd0), .v_adj(4'sd0),
        .hsync(tim_hs), .vsync(tim_vs), .hblank(tim_hb), .vblank(tim_vb), .de(tim_de),
        .hcount(tim_hc), .vcount(tim_vc), .new_frame(tim_nf), .new_line(tim_nl)
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
        .joystick_0(32'd0), .joystick_1(32'd0), .joystick_2(32'd0), .joystick_3(32'd0),
        .joystick_l_analog_0(16'd0),
        .r_out(reader_r), .g_out(reader_g), .b_out(reader_b),
        .clk_audio(clk), .audio_l(), .audio_r(),
        .enable(1'b1), .frame_ready(),
        .dbg_blt(32'd0), .dbg_addr(32'd0), .dbg_diag(32'd0)
    );

    // ── DDR model: two framebuffers + control word, serves reads (busy=0) ──────────
    reg [63:0] mem0 [0:NQW-1];
    reg [63:0] mem1 [0:NQW-1];
    reg [31:0] ctrl_word;
    integer i;
    function [63:0] mem_read(input [28:0] a);
        begin
            if (a == CTRLA)                              mem_read = {32'd0, ctrl_word};
            else if (a >= BUF0 && a < BUF0 + NQW)        mem_read = mem0[a - BUF0];
            else if (a >= BUF1 && a < BUF1 + NQW)        mem_read = mem1[a - BUF1];
            else                                         mem_read = 64'hDEAD_DEAD_DEAD_DEAD;
        end
    endfunction

    // serve: on an accepted read (r_rd & ~busy) latch addr+cnt, stream cnt beats.
    reg        serving = 1'b0;
    reg [28:0] rd_addr_l;
    reg  [7:0] rd_cnt_l, rd_i;
    always @(posedge clk) begin
        r_dout_ready <= 1'b0;
        r_ddr_busy   <= 1'b0;                 // always ready to accept
        if (reset) begin serving <= 1'b0; end
        else if (!serving) begin
            if (r_rd) begin                    // accepted (busy held low)
                rd_addr_l <= r_addr; rd_cnt_l <= r_burstcnt; rd_i <= 8'd0; serving <= 1'b1;
            end
        end else begin
            r_dout       <= mem_read(rd_addr_l + {21'd0, rd_i});
            r_dout_ready <= 1'b1;
            rd_i         <= rd_i + 8'd1;
            if (rd_i == rd_cnt_l - 8'd1) serving <= 1'b0;
        end
    end

    // ── control-word producer: bump frame_counter each timing frame ───────────────
    reg [29:0] fc = 30'd0;
    reg        model_active = 1'b0;
    reg        nf_q = 1'b0;
    always @(posedge clk) begin
        nf_q <= tim_nf;
        if (!reset && tim_nf && !nf_q) fc <= fc + 30'd1;   // new displayed frame
    end
    always @(*) ctrl_word = {fc, 1'b0, model_active};

    // ── checks (each counter is written by EXACTLY ONE always block → race-free) ────
    integer addr_errs = 0, data_errs = 0, active_err = 0;
    integer addr_checks = 0, data_checks = 0;

    // (a) burst-address check: each 80-beat read must target the active buffer's line.
    wire burst_issue = r_rd && (r_burstcnt == 8'd80) && !serving;
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

    // (b) data 1:1: every line-buffer write must equal the active buffer's qword at (line,beat).
    //     The write's beat index is lb_waddr[6:0] (beat_count has already advanced by the time
    //     lb_we is observed), and lb_waddr[7] is the line-parity — both set with lb_wdata.
    always @(posedge clk) begin
        if (!reset && u_reader.lb_we) begin
            if (u_reader.lb_wdata !== (u_reader.active_buffer
                    ? mem1[u_reader.display_line * STRIDE + u_reader.lb_waddr[6:0]]
                    : mem0[u_reader.display_line * STRIDE + u_reader.lb_waddr[6:0]])) begin
                if (data_errs < 8) $display("  DATA MISMATCH line=%0d beat=%0d active=%0b got=%h",
                    u_reader.display_line, u_reader.lb_waddr[6:0], u_reader.active_buffer, u_reader.lb_wdata);
                data_errs = data_errs + 1;
            end
            data_checks = data_checks + 1;
        end
    end

    // wait until the reader has fetched at least `n` distinct lines of the CURRENT frame
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

    initial begin
        for (i = 0; i < NQW; i = i + 1) begin
            mem0[i] = {32'hA0A0_0000 | i[15:0], 16'hB0B0, i[15:0]};   // distinct BUF0 pattern
            mem1[i] = {32'hC1C1_0000 | i[15:0], 16'hD1D1, i[15:0]};   // distinct BUF1 pattern
        end
        model_active = 1'b0;
        repeat (8) @(posedge clk);
        reset <= 1'b0;

        // Frame 1 syncs the reader (captures prev counter, no display); frames after display.
        // Fetch a batch of lines from BUF0 (active=0).
        wait_lines(20);
        $display("after BUF0 batch: addr_checks=%0d data_checks=%0d addr_errs=%0d data_errs=%0d active=%0b",
                 addr_checks, data_checks, addr_errs, data_errs, u_reader.active_buffer);
        if (u_reader.active_buffer !== 1'b0) begin $display("  active!=0 during BUF0 phase"); active_err=active_err+1; end

        // Flip to BUF1: the reader picks up the new active_buffer at the NEXT frame's control
        // poll (not mid-frame — that's the tear-free property). Wait for that flip, then fetch.
        model_active = 1'b1;
        wait (u_reader.active_buffer === 1'b1);
        wait_lines(20);
        $display("after BUF1 batch: addr_checks=%0d data_checks=%0d addr_errs=%0d data_errs=%0d active=%0b",
                 addr_checks, data_checks, addr_errs, data_errs, u_reader.active_buffer);
        if (u_reader.active_buffer !== 1'b1) begin $display("  active!=1 during BUF1 phase"); active_err=active_err+1; end

        if (addr_checks < 30 || data_checks < 30) begin
            $display("RESULT: FAIL — too few checks (addr=%0d data=%0d) — reader never fetched",
                     addr_checks, data_checks);
            $fatal;
        end
        if (addr_errs != 0 || data_errs != 0 || active_err != 0) begin
            $display("RESULT: FAIL — addr_errs=%0d data_errs=%0d active_err=%0d", addr_errs, data_errs, active_err);
            $fatal;
        end
        $display("reader_ddr: ddr_* burst line-fetch reads the ACTIVE buffer 1:1 (BUF0 + BUF1), addresses + data exact");
        $display("RESULT: PASS");
        $finish;
    end

    initial begin #500_000_000 $display("RESULT: FAIL — TIMEOUT"); $fatal; end
endmodule
`default_nettype wire
