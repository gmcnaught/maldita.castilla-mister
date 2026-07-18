// tb_fb_dma.sv — 2-frame parity bench for comp_fb_dma (double-buffered WORK→DDR DMA).
//
// Drives TWO start pulses and asserts the openbor_video_reader double-buffer contract:
//   frame A (sel=0): BUF0 (fb+0x08 qw) byte-exact 19200 qwords; control word @fb+0 =
//                    {frame_counter=0, 1'b0, sel=0}; NO write to BUF1's region.
//   frame B (sel=1): BUF1 (fb+0x8008 qw) byte-exact; control word @fb+0 =
//                    {frame_counter=1, 1'b0, sel=1}; NO write to BUF0's region (still frame-A data).
// Plus, every frame: the control-word write lands AFTER all 19200 buffer beats (ordering),
// the control write uses be=0x0F (low 32 only) and the buffer beats use be=0xFF, and the
// back-pressure (scripted mem_busy) is honoured.
//
// Copyright (C) 2026 — GPL-3.0
`default_nettype none
`timescale 1ns/1ps
module tb_fb_dma;
    localparam integer FB_QWORDS = 19200;
    localparam integer AW        = 15;
    localparam integer MAW       = 32;
    localparam [28:0]  FB        = 29'd0;             // fb_qw_base: ctrl@0, BUF0@8, BUF1@0x8008
    localparam [31:0]  BUF0_BASE = 32'd8;            // fb + 0x40 bytes
    localparam [31:0]  BUF1_BASE = 32'd8 + 32'h8000; // fb + 0x40040 bytes

    reg clk = 1'b0;
    reg rst = 1'b1;
    always #5 clk = ~clk;   // 100 MHz

    // ── DUT I/O ──────────────────────────────────────────────────────────────────
    reg              start = 1'b0;
    wire             busy;

    wire             work_rd_en;
    wire [AW-1:0]    work_rd_qw;
    reg  [63:0]      work_rd_qword_r;

    wire             mem_wr;
    wire [MAW-1:0]   mem_addr;
    wire [7:0]       mem_burstcnt;
    wire [63:0]      mem_din;
    wire [7:0]       mem_be;
    reg              mem_busy;

    comp_fb_dma #(.FB_QWORDS(FB_QWORDS), .AW(AW), .MAW(MAW)) dut (
        .clk(clk), .rst(rst),
        .start(start), .busy(busy), .fb_qw_base(FB),
        .work_rd_en(work_rd_en), .work_rd_qw(work_rd_qw), .work_rd_qword(work_rd_qword_r),
        .mem_wr(mem_wr), .mem_addr(mem_addr), .mem_burstcnt(mem_burstcnt),
        .mem_din(mem_din), .mem_be(mem_be), .mem_busy(mem_busy)
    );

    // ── behavioral WORK RAM: registered 1-cycle read (matches comp_fbram rd_*) ─────
    reg [63:0] work [0:FB_QWORDS-1];
    integer i;
    initial begin
        for (i = 0; i < FB_QWORDS; i = i + 1) begin
            work[i][15:0]  = i*4 + 0;
            work[i][31:16] = i*4 + 1;
            work[i][47:32] = i*4 + 2;
            work[i][63:48] = i*4 + 3;
        end
    end
    always @(posedge clk)
        if (work_rd_en) work_rd_qword_r <= work[work_rd_qw];

    // ── DDR capture model + scripted mem_busy back-pressure ────────────────────────
    localparam integer DDR_SZ = 32'h10000;   // covers ctrl(0), BUF0(8..), BUF1(0x8008..)
    reg [63:0] ddr [0:DDR_SZ-1];

    // per-frame bookkeeping, driven by exp_sel (set before each frame)
    reg         exp_sel;
    integer     buf_writes;
    reg         cross_err;    // a write landed in the OTHER buffer's region this frame
    reg         oob_err;      // a write landed outside ctrl/BUF0/BUF1
    reg         order_err;    // the control word was written before all buffer beats
    reg         be_err;       // a beat used the wrong byte-enable
    reg         ctrl_written;
    reg [31:0]  ctrl_captured;

    // scripted mem_busy: 2 of every 8 cycles, PLUS one long ~40-cycle mid-frame stall
    // (time-based countdown, NOT gated on writes — gating on writes would deadlock).
    reg [15:0] bcnt = 16'd0;
    reg [7:0]  stall_cnt = 8'd0;
    reg        stall_armed = 1'b1;
    always @(posedge clk) begin
        bcnt <= bcnt + 16'd1;
        if (stall_armed && buf_writes >= 5000) begin
            stall_cnt   <= 8'd40;
            stall_armed <= 1'b0;
        end else if (stall_cnt != 8'd0) begin
            stall_cnt <= stall_cnt - 8'd1;
        end
    end
    always @(*)
        mem_busy = (bcnt[2:0] == 3'd0) || (bcnt[2:0] == 3'd1) || (stall_cnt != 8'd0);

    // capture an ACCEPTED write (mem_wr held, accepted when ~mem_busy)
    wire [31:0] thisbase  = BUF0_BASE + (exp_sel ? 32'h8000 : 32'd0);
    wire [31:0] otherbase = BUF0_BASE + (exp_sel ? 32'd0 : 32'h8000);
    always @(posedge clk) begin
        if (!rst && mem_wr && !mem_busy) begin
            if (mem_addr == {3'b0, FB}) begin
                // control word (fb+0): be must be 0x0F (low 32 only)
                if (mem_be !== 8'h0F) be_err <= 1'b1;
                ctrl_written  <= 1'b1;
                ctrl_captured <= mem_din[31:0];
                if (buf_writes != FB_QWORDS) order_err <= 1'b1;   // ctrl before buffer done
            end else if (mem_addr >= thisbase && mem_addr < thisbase + FB_QWORDS) begin
                if (mem_be !== 8'hFF) be_err <= 1'b1;
                ddr[mem_addr] <= mem_din;
                buf_writes    <= buf_writes + 1;
            end else if (mem_addr >= otherbase && mem_addr < otherbase + FB_QWORDS) begin
                cross_err     <= 1'b1;
                ddr[mem_addr] <= mem_din;
            end else begin
                oob_err <= 1'b1;
            end
        end
    end

    // ── per-frame check ─────────────────────────────────────────────────────────────
    integer errs = 0;
    task check_frame(input integer sel_f, input [29:0] fc_f, input [255:0] tag);
        integer qw, bad, bbase;
        reg [31:0] exp_ctrl;
        begin
            bbase   = BUF0_BASE + (sel_f ? 32'h8000 : 32'd0);
            exp_ctrl = {fc_f, 1'b0, sel_f[0]};
            bad = 0;
            for (qw = 0; qw < FB_QWORDS; qw = qw + 1)
                if (ddr[bbase + qw] !== work[qw]) begin
                    if (bad < 4) $display("  [%0s] BUF MISMATCH qw=%0d addr=%0d got=%h exp=%h",
                                          tag, qw, bbase+qw, ddr[bbase+qw], work[qw]);
                    bad = bad + 1;
                end
            $display("frame[%0s]: buf_writes=%0d bad=%0d cross=%0b oob=%0b order=%0b be=%0b ctrl_wr=%0b ctrl=%h exp_ctrl=%h",
                     tag, buf_writes, bad, cross_err, oob_err, order_err, be_err,
                     ctrl_written, ctrl_captured, exp_ctrl);
            if (bad != 0)                       errs = errs + 1;
            if (buf_writes != FB_QWORDS)        errs = errs + 1;
            if (cross_err || oob_err)           errs = errs + 1;
            if (order_err || be_err)            errs = errs + 1;
            if (!ctrl_written)                  errs = errs + 1;
            if (ctrl_captured !== exp_ctrl)     errs = errs + 1;
        end
    endtask

    task run_frame(input integer sel_f);
        integer guard;
        begin
            exp_sel <= sel_f[0];
            buf_writes = 0; cross_err = 0; oob_err = 0; order_err = 0; be_err = 0;
            ctrl_written = 0; ctrl_captured = 32'hxxxx_xxxx;
            @(posedge clk);
            start <= 1'b1; @(posedge clk); start <= 1'b0;
            guard = 0;
            wait (busy === 1'b1);
            while (busy === 1'b1) begin
                @(posedge clk);
                guard = guard + 1;
                if (guard > 400000) begin
                    $display("RESULT: FAIL — TIMEOUT frame sel=%0d after %0d cycles", sel_f, guard);
                    $fatal;
                end
            end
            @(posedge clk);
        end
    endtask

    initial begin
        for (i = 0; i < DDR_SZ; i = i + 1) ddr[i] = 64'hxxxx_xxxx_xxxx_xxxx;
        exp_sel = 0;
        repeat (4) @(posedge clk);
        rst <= 1'b0;
        @(posedge clk);

        // frame A: sel=0 -> BUF0, control {fc=0, sel=0}
        run_frame(0);
        check_frame(0, 30'd0, "A");

        // frame B: sel=1 -> BUF1, control {fc=1, sel=1}. BUF0 must still hold frame-A data.
        run_frame(1);
        check_frame(1, 30'd1, "B");

        if (errs != 0) begin
            $display("RESULT: FAIL — errs=%0d", errs);
            $fatal;
        end
        $display("fb_dma: 2-frame double-buffer byte-exact, control-word packing + ordering OK");
        $display("RESULT: PASS");
        $finish;
    end
endmodule
`default_nettype wire
