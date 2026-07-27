// tb_fb_dma.sv — comp_fb_dma (double-buffered WORK→DDR DMA) bench.
//
// A reader model owns the "displayed buffer" (disp_active), swapping to the last control word's
// active bit at its OWN vblank (period configurable). comp_fb_dma is triggered continuously
// (whenever !busy). Two phases:
//   Phase 1 — reader swaps promptly (1:1): every produced frame writes the BACK buffer byte-exact,
//     control word {frame_counter, 1'b0, target} lands AFTER the buffer (ordering), be=0x0F ctrl /
//     0xFF beats, no cross-buffer write.
//   Phase 2 — reader lags (producer ~2x): comp_fb_dma DROPS frames (skips) rather than overwrite the
//     buffer it just published, so it NEVER writes the buffer the reader is displaying (no tear).
// TEARING INVARIANT (both phases, every accepted buffer beat): the buffer being written is never the
// one disp_active points at — even when the reader vblank lands mid-copy.
//
// Copyright (C) 2026 — GPL-3.0
`default_nettype none
`timescale 1ns/1ps
`include "blitter_defs.vh"
module tb_fb_dma;
    // Frame size derived from the FB geometry root (blitter_defs.vh) — never retype it.
    localparam integer FB_QWORDS = `FB_QWORDS;
    localparam integer AW        = 15;
    localparam integer MAW       = 32;
    localparam [28:0]  FB        = 29'd0;
    localparam [31:0]  BUF0_BASE = 32'd8;
    localparam [31:0]  BUF1_BASE = 32'd8 + 32'h8000;

    reg clk = 1'b0; reg rst = 1'b1; always #5 clk = ~clk;

    // reader model
    reg          reader_active = 1'b0;   // buffer currently displayed
    reg [31:0]   last_ctrl = 32'd0;      // last control word comp_fb_dma wrote
    reg          tear_err = 1'b0;
    reg [31:0]   rvbl_period = 32'd3000;  // reader vblank period (cycles); small=prompt, large=lag
    reg [31:0]   rv_cnt = 32'd0;

    // ── DUT ─────────────────────────────────────────────────────────────────────
    reg              start = 1'b0;
    wire             disp_active = reader_active;
    wire             busy;
    wire             work_rd_en; wire [AW-1:0] work_rd_qw; reg [63:0] work_rd_qword_r;
    wire             mem_wr; wire [MAW-1:0] mem_addr; wire [7:0] mem_burstcnt;
    wire [63:0]      mem_din; wire [7:0] mem_be; reg mem_busy;

    comp_fb_dma #(.FB_QWORDS(FB_QWORDS), .AW(AW), .MAW(MAW)) dut (
        .clk(clk), .rst(rst),
        .start(start), .busy(busy), .fb_qw_base(FB), .disp_active(disp_active),
        .work_rd_en(work_rd_en), .work_rd_qw(work_rd_qw), .work_rd_qword(work_rd_qword_r),
        .mem_wr(mem_wr), .mem_addr(mem_addr), .mem_burstcnt(mem_burstcnt),
        .mem_din(mem_din), .mem_be(mem_be), .mem_busy(mem_busy)
    );

    // WORK RAM
    reg [63:0] work [0:FB_QWORDS-1];
    integer i;
    initial for (i=0;i<FB_QWORDS;i=i+1) begin
        work[i][15:0]=i*4+0; work[i][31:16]=i*4+1; work[i][47:32]=i*4+2; work[i][63:48]=i*4+3;
    end
    always @(posedge clk) if (work_rd_en) work_rd_qword_r <= work[work_rd_qw];

    // DDR capture + scripted back-pressure
    localparam integer DDR_SZ = 32'h10000;
    reg [63:0] ddr [0:DDR_SZ-1];
    reg [15:0] bcnt = 16'd0;
    always @(posedge clk) bcnt <= bcnt + 16'd1;
    always @(*) mem_busy = (bcnt[2:0] == 3'd0);   // ~1-in-8 stall

    wire wr_is_buf0 = (mem_addr >= BUF0_BASE) && (mem_addr < BUF0_BASE + FB_QWORDS);
    wire wr_is_buf1 = (mem_addr >= BUF1_BASE) && (mem_addr < BUF1_BASE + FB_QWORDS);

    // per-frame bookkeeping
    integer buf_writes = 0;
    reg     order_err = 0, be_err = 0, cross_err = 0, oob_err = 0;
    reg     cur_target;           // the buffer this frame is writing (dut.wr_target)
    integer frames_done = 0, skips = 0, buf0_writes_total = 0, buf1_writes_total = 0;

    always @(posedge clk) begin
        if (!rst && mem_wr && !mem_busy) begin
            // TEARING INVARIANT: never write the buffer the reader is currently displaying.
            if ((wr_is_buf1 && disp_active==1'b1) || (wr_is_buf0 && disp_active==1'b0)) tear_err <= 1'b1;

            if (mem_addr == {3'b0, FB}) begin                     // control word
                if (mem_be !== 8'h0F) be_err <= 1'b1;
                if (buf_writes != FB_QWORDS) order_err <= 1'b1;   // must come AFTER the buffer
                last_ctrl <= mem_din[31:0];
                if (mem_din[0] !== cur_target) be_err <= 1'b1;    // ctrl active == written buffer
            end else if (wr_is_buf0 || wr_is_buf1) begin
                if (mem_be !== 8'hFF) be_err <= 1'b1;
                if (wr_is_buf1 != cur_target) cross_err <= 1'b1;  // wrote the wrong buffer
                ddr[mem_addr] <= mem_din;
                buf_writes <= buf_writes + 1;
                if (wr_is_buf0) buf0_writes_total <= buf0_writes_total + 1;
                else            buf1_writes_total <= buf1_writes_total + 1;
            end else oob_err <= 1'b1;
        end
    end

    // reader vblank: swap displayed buffer to the last published control word's active bit.
    always @(posedge clk) begin
        if (rst) begin reader_active <= 1'b0; rv_cnt <= 0; end
        else begin
            rv_cnt <= rv_cnt + 1;
            if (rv_cnt >= rvbl_period) begin rv_cnt <= 0; reader_active <= last_ctrl[0]; end
        end
    end

    // ── producer: pulse `start` whenever the DUT is idle; catch skips (busy may not assert) ──
    integer errs = 0;
    task produce_one(input integer gap);   // wait `gap` cycles (compositor pacing), then one attempt
        integer w;
        begin
            repeat (gap) @(posedge clk);
            cur_target = ~disp_active;    // what the DUT WILL target if it accepts
            buf_writes = 0; order_err = 0; be_err = 0; cross_err = 0; oob_err = 0;
            @(posedge clk); start <= 1'b1; @(posedge clk); start <= 1'b0;
            // wait up to a bounded window for busy to assert (accept) or not (skip)
            w = 0;
            while (busy !== 1'b1 && w < 8) begin @(posedge clk); w = w + 1; end
            if (busy === 1'b1) begin
                w = 0;
                while (busy === 1'b1) begin
                    @(posedge clk); w = w + 1;
                    if (w > 400000) begin $display("RESULT: FAIL — TIMEOUT"); $fatal; end
                end
                @(posedge clk);
                frames_done = frames_done + 1;
                if (buf_writes != FB_QWORDS) errs = errs + 1;
                if (order_err || be_err || cross_err || oob_err) errs = errs + 1;
            end else begin
                skips = skips + 1;             // DUT dropped this frame (reader behind)
            end
        end
    endtask

    integer k;
    initial begin
        for (i=0;i<DDR_SZ;i=i+1) ddr[i] = 64'hxxxx_xxxx_xxxx_xxxx;
        repeat (4) @(posedge clk); rst <= 1'b0; @(posedge clk);

        // Phase 1: PROMPT reader (swaps every cycle to the last publish) -> 1:1, every frame writes.
        rvbl_period = 32'd1;
        for (k=0;k<8;k=k+1) produce_one(100);
        $display("phase1: frames=%0d skips=%0d tear=%0b buf0w=%0d buf1w=%0d",
                 frames_done, skips, tear_err, buf0_writes_total, buf1_writes_total);
        if (tear_err) errs = errs + 1;
        if (skips != 0) errs = errs + 1;                       // prompt reader -> no drops
        if (buf0_writes_total == 0 || buf1_writes_total == 0) errs = errs + 1;  // both buffers used
        // both buffers hold the byte-exact WORK pattern (spot-check the head)
        for (k=0;k<400;k=k+1) begin
            if (ddr[BUF0_BASE+k] !== work[k]) errs = errs + 1;
            if (ddr[BUF1_BASE+k] !== work[k]) errs = errs + 1;
        end

        // Phase 2: LAGGY reader (period 90000 >> frame time) with the producer attempting ~every
        // 8000 cycles -> producer ~2-4x the reader -> comp_fb_dma DROPS frames instead of tearing.
        rvbl_period = 32'd90000;
        skips = 0;
        for (k=0;k<40;k=k+1) produce_one(8000);
        $display("phase2: frames=%0d skips=%0d tear=%0b (producer lapped -> expect skips>0)",
                 frames_done, skips, tear_err);
        if (tear_err) errs = errs + 1;
        if (skips == 0) begin $display("  WARN: no skips — rate mismatch not exercised"); errs = errs + 1; end

        if (errs != 0) begin $display("RESULT: FAIL — errs=%0d", errs); $fatal; end
        $display("fb_dma: byte-exact double-buffer + ordering; rate-mismatch DROPS frames, NEVER writes the displayed buffer (no tear)");
        $display("RESULT: PASS");
        $finish;
    end

    initial begin #2_000_000_000 $display("RESULT: FAIL — TIMEOUT(top)"); $fatal; end
endmodule
`default_nettype wire
