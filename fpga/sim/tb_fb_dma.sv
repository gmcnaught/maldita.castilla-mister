// tb_fb_dma.sv — byte-correctness bench for comp_fb_dma (WORK→DDR framebuffer DMA).
//
// Backs the DUT's WORK read port with a behavioral registered RAM preloaded with a
// distinctive per-lane pattern, and its mem_* write master with a DDR capture model
// whose mem_busy is scripted to toggle (proving back-pressure/stall handling). Pulses
// `start`, waits for `!busy`, then asserts:
//   (a) every captured DDR qword at fb_base_qw+qw == work[qw] for all 19200 qwords,
//   (b) no accepted write landed outside [fb_base_qw, fb_base_qw+19200),
//   (c) exactly 19200 writes, each address written exactly once (full coverage, no dups).
//
// Copyright (C) 2026 — GPL-3.0
`default_nettype none
`timescale 1ns/1ps
module tb_fb_dma;
    localparam integer FB_QWORDS = 19200;
    localparam integer AW        = 15;
    localparam integer MAW       = 32;
    localparam [MAW-1:0] BASE    = 32'h0000_0100;  // nonzero qword base — exercises the add

    reg clk = 1'b0;
    reg rst = 1'b1;
    always #5 clk = ~clk;   // 100 MHz

    // ── DUT I/O ──────────────────────────────────────────────────────────────────
    reg              start = 1'b0;
    wire             busy;
    reg  [MAW-1:0]   fb_base_qw = BASE;

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
        .start(start), .busy(busy), .fb_base_qw(fb_base_qw),
        .work_rd_en(work_rd_en), .work_rd_qw(work_rd_qw), .work_rd_qword(work_rd_qword_r),
        .mem_wr(mem_wr), .mem_addr(mem_addr), .mem_burstcnt(mem_burstcnt),
        .mem_din(mem_din), .mem_be(mem_be), .mem_busy(mem_busy)
    );

    // ── behavioral WORK RAM: registered 1-cycle read (matches comp_fbram rd_*) ─────
    reg [63:0] work [0:FB_QWORDS-1];
    integer i;
    initial begin
        for (i = 0; i < FB_QWORDS; i = i + 1) begin
            // four RGB565 lanes {lane3,lane2,lane1,lane0}; lane0 = leftmost pixel.
            // part-select assignment auto-truncates each lane to 16 bits.
            work[i][15:0]  = i*4 + 0;
            work[i][31:16] = i*4 + 1;
            work[i][47:32] = i*4 + 2;
            work[i][63:48] = i*4 + 3;
        end
    end
    always @(posedge clk)
        if (work_rd_en) work_rd_qword_r <= work[work_rd_qw];

    // ── DDR capture model + scripted mem_busy back-pressure ────────────────────────
    localparam integer DDR_SZ = BASE + FB_QWORDS + 64;
    reg [63:0] ddr      [0:DDR_SZ-1];
    reg        wrote    [0:DDR_SZ-1];
    integer    writes_seen = 0;
    reg        oob = 1'b0;   // an accepted write landed out of range
    reg        dup = 1'b0;   // an address was written more than once

    // mem_busy: assert busy 2 of every 8 cycles, PLUS one long ~40-cycle stall mid-copy.
    // The long stall is TIME-based (a cycle countdown), NOT gated on writes_seen — gating
    // it on writes_seen would deadlock (holding mem_busy=1 stops writes_seen advancing, so
    // the window would never close).
    reg [15:0] bcnt = 16'd0;
    reg [7:0]  stall_cnt = 8'd0;
    reg        stall_armed = 1'b1;
    always @(posedge clk) begin
        bcnt <= bcnt + 16'd1;
        if (stall_armed && writes_seen >= 5000) begin
            stall_cnt   <= 8'd40;   // one long mid-copy stall
            stall_armed <= 1'b0;
        end else if (stall_cnt != 8'd0) begin
            stall_cnt <= stall_cnt - 8'd1;
        end
    end
    always @(*)
        mem_busy = (bcnt[2:0] == 3'd0) || (bcnt[2:0] == 3'd1) || (stall_cnt != 8'd0);

    // capture an ACCEPTED write (mem_wr held, accepted when ~mem_busy).
    always @(posedge clk) begin
        if (!rst && mem_wr && !mem_busy) begin
            if (mem_addr < BASE || mem_addr >= (BASE + FB_QWORDS)) begin
                oob <= 1'b1;
            end else begin
                if (wrote[mem_addr]) dup <= 1'b1;
                ddr[mem_addr]   <= mem_din;
                wrote[mem_addr] <= 1'b1;
            end
            writes_seen <= writes_seen + 1;
            // sanity on the master's fixed fields
            if (mem_be !== 8'hFF)    $display("WARN: mem_be=%h (expected FF)", mem_be);
            if (mem_burstcnt !== 8'd1) $display("WARN: mem_burstcnt=%0d (expected 1)", mem_burstcnt);
        end
    end

    // ── stimulus + checks ──────────────────────────────────────────────────────────
    integer qw, bad, cover_missing;
    integer guard;
    initial begin
        for (i = 0; i < DDR_SZ; i = i + 1) begin ddr[i] = 64'hxxxx_xxxx_xxxx_xxxx; wrote[i] = 1'b0; end
        // reset
        repeat (4) @(posedge clk);
        rst <= 1'b0;
        @(posedge clk);
        // kick off the copy
        start <= 1'b1;
        @(posedge clk);
        start <= 1'b0;

        // wait for busy to assert, then for it to drop — with a timeout guard.
        guard = 0;
        wait (busy === 1'b1);
        while (busy === 1'b1) begin
            @(posedge clk);
            guard = guard + 1;
            if (guard > 400000) begin
                $display("RESULT: FAIL — TIMEOUT: busy never dropped after %0d cycles", guard);
                $fatal;
            end
        end
        @(posedge clk);

        // (a) byte-exact content
        bad = 0;
        for (qw = 0; qw < FB_QWORDS; qw = qw + 1)
            if (ddr[BASE + qw] !== work[qw]) begin
                if (bad < 8) $display("  MISMATCH qw=%0d addr=%0d got=%h exp=%h",
                                      qw, BASE+qw, ddr[BASE+qw], work[qw]);
                bad = bad + 1;
            end

        // (c) full coverage, no dups, exact count
        cover_missing = 0;
        for (qw = 0; qw < FB_QWORDS; qw = qw + 1)
            if (!wrote[BASE + qw]) cover_missing = cover_missing + 1;

        $display("fb_dma: writes_seen=%0d (exp %0d)  bad=%0d  cover_missing=%0d  oob=%0b  dup=%0b",
                 writes_seen, FB_QWORDS, bad, cover_missing, oob, dup);

        if (bad != 0 || cover_missing != 0 || oob || dup || writes_seen != FB_QWORDS) begin
            $display("RESULT: FAIL — bad=%0d cover_missing=%0d oob=%0b dup=%0b writes_seen=%0d",
                     bad, cover_missing, oob, dup, writes_seen);
            $fatal;
        end

        $display("fb_dma: all %0d qwords byte-exact, full coverage, stalls honored", FB_QWORDS);
        $display("RESULT: PASS");
        $finish;
    end
endmodule
`default_nettype wire
