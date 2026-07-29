// tb_blitter_trilist_missdst.sv — [Phase 1 2b] the ONE combination no other bench reaches:
// a texel MISS on a triangle that ALSO reads its destination.
//
// WHY THIS EXISTS. A2 hoisted the comp_fbram dst read into B_IDLE and re-issues it on the
// texel-miss retry. The placement of that re-issue is subtle — one cycle out and the blend
// consumes a stale dst — and NOTHING in the suite covered it:
//   * trilist_add / trilist_calpha take the dst path on every pixel but measure pb EXACTLY
//     8.00 cyc/px, i.e. ZERO B_WAIT: they never miss.
//   * trilist_uvfull / trilist_sdram thrash the tq cache constantly (texwait ~39.8k) but
//     have tri_need_dst FALSE: they never read dst.
// So the ±1 LSB golden diff was structurally blind to the miss+dst path, which is exactly
// where the original brief placed the re-issue wrongly. That would have shipped silently.
//
// It is not a hypothetical path on device: Phase 0 measured texwait at 3.77 ms, ~20% of tri,
// so real gameplay misses constantly WHILE alpha-blending. The untested combination is the
// production common case.
//
// The scene is tri_uvfull's 128x128 stride-256 texture (thousands of distinct qwords through
// a direct-mapped cache -> constant misses) with CONST_ALPHA at per-vertex alpha 128 so
// tri_need_dst is true AND the destination materially changes every pixel. See the
// tri_missdst block in gen_tri_golden.c for why alpha must not be 255.
`timescale 1ns/1ps
`default_nettype none
`include "blitter_defs.vh"
module tb_blitter_trilist_missdst;
  localparam [28:0] WBASE = 29'h07400000;
  localparam        MEMQW = (`SRC_QW - 29'h07400000) + 29'h8000;

  reg clk=0, rst=1; always #5 clk=~clk;

  wire [31:0] bt_addr; wire b_rd, b_we; wire [63:0] b_din; wire [7:0] b_be; wire bt_idle;
  reg  d_dready; reg [63:0] d_dout;

  // behavioral DDR: single-beat reads w/ latency + backpressure.
  reg [63:0] mem [0:MEMQW-1];
  reg [7:0] rbeats; reg [28:0] raddr; reg [2:0] rlat; reg [1:0] bp=0;
  always @(posedge clk) bp <= bp+2'd1;
  wire d_busy = (bp != 2'd2) | (rbeats != 8'd0) | (rlat != 3'd0);
  integer i;

  // ── P_SRC cache-ok source model (serves texel reads from the SRC window) ─────
  localparam P_SRC_LAT = 3;
  localparam [28:0] SRC_WIN = `SRC_QW - WBASE;
  wire [26:0] s_src_addr; wire s_src_rd;
  reg  [63:0] s_src_dout; reg s_src_ok=1'b0;
  reg         s_rd_d;
  reg [26:0]  s_lat_addr [0:P_SRC_LAT-1];
  reg         s_lat_v    [0:P_SRC_LAT-1];
  integer     sli;
  always @(posedge clk) s_rd_d <= s_src_rd;
  // SINGLE-OUTSTANDING faithful line-cache model: hit=HIT_LAT, cold line-fill=MISS_LAT,
  // NLINES resident with LRU (rline[0]=MRU). Keyed by line = addr>>LINE_LOG2. Reproduces
  // the real jtframe ch5 behaviour (2 tiny lines the row-order texel walk thrashes) so a
  // prefetcher that issues reads AHEAD overlaps the miss latency and drops pb's stall
  // (texwait). Still single-outstanding + address-dependent variable phase, so it keeps
  // catching the p0_ok strobe-miss hang.
  localparam LINE_LOG2 = 8;    // 256-byte lines (tune with NLINES so texwait is ~30% of tri)
  localparam NLINES    = 2;    // faithful jtframe ch5 = 2 lines
  localparam HIT_LAT   = 4;
  localparam MISS_LAT  = 140;
  reg        so_busy = 1'b0;
  integer    so_cnt  = 0;
  reg [26:0] so_addr = 27'd0;
  reg [26:0] rline   [0:NLINES-1];   // resident line addrs, [0]=MRU
  reg        rline_v [0:NLINES-1];
  integer    li, hitpos;
  initial for (li=0; li<NLINES; li=li+1) begin rline[li]=27'h7FFFFFF; rline_v[li]=1'b0; end
  always @(posedge clk) begin
    s_src_ok <= 1'b0;
    if ((s_src_rd & ~s_rd_d) && !so_busy) begin
      so_busy <= 1'b1;
      so_addr <= s_src_addr;
      // LRU lookup on the accepted address' line.
      hitpos = -1;
      for (li=0; li<NLINES; li=li+1)
        if (rline_v[li] && (rline[li] == (s_src_addr >> LINE_LOG2))) hitpos = li;
      if (hitpos >= 0) begin
        so_cnt <= HIT_LAT;
        // promote to MRU
        for (li=0; li<NLINES; li=li+1) if (li <= hitpos && li>0) rline[li] <= rline[li-1];
        rline[0] <= (s_src_addr >> LINE_LOG2); rline_v[0] <= 1'b1;
      end else begin
        so_cnt <= MISS_LAT;
        // insert new line at MRU, shift others down, evict LRU
        for (li=NLINES-1; li>0; li=li-1) begin rline[li] <= rline[li-1]; rline_v[li] <= rline_v[li-1]; end
        rline[0] <= (s_src_addr >> LINE_LOG2); rline_v[0] <= 1'b1;
      end
    end
    if (so_busy) begin
      if (so_cnt <= 1) begin
        s_src_dout <= mem[SRC_WIN + (so_addr >> 3)];
        s_src_ok   <= 1'b1;
        so_busy    <= 1'b0;
      end else so_cnt <= so_cnt - 1;
    end
  end

  wire [7:0] bt_burst;
  wire fb_wr_en; wire [14:0] fb_wr_qw; wire [1:0] fb_wr_lane; wire [15:0] fb_wr_pix;
  wire fb_rd_en; wire [14:0] fb_rd_qw; wire [63:0] fb_rd_qword;
  comp_fbram fbram(.clk(clk),
    .wr_en(fb_wr_en), .wr_qw(fb_wr_qw), .wr_lane(fb_wr_lane), .wr_pix(fb_wr_pix),
    .rd_en(fb_rd_en), .rd_qw(fb_rd_qw), .rd_qword(fb_rd_qword));
  blitter_top blt(.clk(clk), .rst(rst),
    .mem_addr(bt_addr), .mem_rd(b_rd), .mem_wr(b_we), .mem_burstcnt(bt_burst),
    .mem_din(b_din), .mem_be(b_be),
    .mem_dout(d_dout), .mem_dout_ready(d_dready), .mem_busy(d_busy),
    .p0_addr(s_src_addr), .p0_rd(s_src_rd), .p0_dout(s_src_dout), .p0_ok(s_src_ok),
    .fb_wr_en(fb_wr_en), .fb_wr_qw(fb_wr_qw), .fb_wr_lane(fb_wr_lane), .fb_wr_pix(fb_wr_pix),
    .fb_rd_en(fb_rd_en), .fb_rd_qw(fb_rd_qw), .fb_rd_qword(fb_rd_qword),
    .idle(bt_idle));

  // ── [Phase 1 2b] coverage counters + NON-VACUITY gate ─────────────────────────
  // This bench exists ONLY to reach miss + tri_need_dst. If the scenario stops
  // missing (a bigger tq cache, a smaller texture) or stops reading dst (a blend-mode
  // change), it would keep passing while covering NOTHING — the exact failure mode
  // this task was created to fix. So the counters are ASSERTED, not just printed.
  // Both are cycle counts of single-cycle states, so each equals an event count:
  //   B_WAIT  (blt.B_WAIT)  — texel-miss stalls
  //   B_FILL-with-need_dst  — pixels that will latch a destination
  integer md_bwait_cyc, md_dst_px, md_retry_reissue;
  initial begin md_bwait_cyc=0; md_dst_px=0; md_retry_reissue=0; end
  always @(posedge clk) if (!rst) begin
    if (blt.pb == blt.B_WAIT) md_bwait_cyc <= md_bwait_cyc + 1;
    if ((blt.pb == blt.B_FILL) && blt.tri_need_dst) md_dst_px <= md_dst_px + 1;
    // the A2 re-issue itself: a dst read issued from the B_WAIT -> B_LOOK edge
    if ((blt.pb == blt.B_WAIT) && !blt.fill_busy && blt.tri_need_dst)
      md_retry_reissue <= md_retry_reissue + 1;
  end

  task md_check_coverage;
    begin
      $display("MISSDST coverage: B_WAIT=%0d cyc  dst-path B_FILL=%0d  retry-reissues=%0d",
               md_bwait_cyc, md_dst_px, md_retry_reissue);
      if (md_bwait_cyc == 0) begin
        $display("FAIL missdst: no B_WAIT cycles — the texel cache never missed, so this");
        $display("              bench covers nothing it was written for");
        $finish;
      end
      if (md_dst_px == 0) begin
        $display("FAIL missdst: no pixel took the dst path (tri_need_dst never true)");
        $finish;
      end
      if (md_retry_reissue == 0) begin
        $display("FAIL missdst: miss and dst both occur but never TOGETHER — the");
        $display("              B_WAIT -> B_LOOK dst re-issue was never exercised");
        $finish;
      end
      $display("PASS missdst coverage: miss + dst reached together %0d times", md_retry_reissue);
    end
  endtask

  always @(posedge clk) begin
    d_dready <= 1'b0;
    d_dout   <= 64'hDEAD_BEEF_DEAD_BEEF;
    if (rst) begin rbeats<=0; rlat<=0; end
    else begin
      if (rlat != 3'd0) rlat <= rlat - 3'd1;
      else if (rbeats != 8'd0) begin
        if (bp == 2'd2) begin
          d_dout <= mem[raddr-WBASE]; d_dready <= 1'b1;
          raddr <= raddr + 29'd1; rbeats <= rbeats - 8'd1;
        end
      end else if (!d_busy) begin
        if (b_rd) begin rbeats<=bt_burst; raddr<=bt_addr[28:0]; rlat<=3'd3; end
        else if (b_we) for(i=0;i<8;i=i+1) if(b_be[i]) mem[(bt_addr[28:0]-WBASE)][i*8 +:8]<=b_din[i*8 +:8];
      end
    end
  end

  // ── golden framebuffer (`FB_PIXELS RGB565 pixels, index = y*`FB_W+x) ────────────────
  reg [15:0] exp [0:`FB_PIXELS-1];

  integer x,y,idx,bad,ncov;
  reg [15:0] got, e;
  // ±1 LSB per RGB565 channel
  function integer chan_ok(input [15:0] a, input [15:0] b);
    integer dr,dg,db;
    begin
      dr = a[15:11] - b[15:11]; if (dr<0) dr=-dr;
      dg = a[10:5]  - b[10:5];  if (dg<0) dg=-dg;
      db = a[4:0]   - b[4:0];   if (db<0) db=-db;
      chan_ok = (dr<=1) && (dg<=1) && (db<=1);
    end
  endfunction

  initial begin
    for(i=0;i<MEMQW;i=i+1) mem[i]=64'd0;
    $readmemh("vectors/tri_missdst_ddr.hex", mem);
    $readmemh("vectors/tri_missdst_exp.hex", exp);
  end

  integer to;
  initial begin
    repeat(8) @(posedge clk); rst<=0;
    // run until done_seq == submit_seq, or timeout
    to=0;
    while (mem[32'h200005][31:0] !== mem[32'h200000][31:0] && to<4000000) begin @(posedge clk); to=to+1; end
    repeat(10) @(posedge clk);
    $display("=== done_seq=%0d submit=%0d (to=%0d) ===", mem[32'h200005][31:0], mem[32'h200000][31:0], to);

    // [profiling] datapath cyc/px from the S_TRI_* perf counters (this frame). The sim
    // stub gives P_SRC a fixed low latency, so texwait is small here; the DATAPATH cyc/px
    // (tri - texwait) is memory-independent and should track the device's ~41 cyc/px. Use
    // this as the iteration metric while pipelining the rasterizer toward 1 px/cyc.
    ncov=0;
    for (y=0;y<`FB_H;y=y+1) for (x=0;x<`FB_W;x=x+1) if (exp[y*`FB_W+x]!==exp[0]) ncov=ncov+1;
    $display("=== PERF tri=%0d texwait=%0d dpath=%0d covered_px=%0d | dpath_cyc/px=%0d ===",
             blt.perf_tri_cyc, blt.perf_texwait_cyc, blt.perf_tri_cyc-blt.perf_texwait_cyc,
             ncov, (ncov>0)?((blt.perf_tri_cyc-blt.perf_texwait_cyc)/ncov):0);

    // [Phase 1 2b] Prove the path was reached BEFORE trusting the diff below.
    md_check_coverage;

    bad=0;
    for (y=0;y<`FB_H;y=y+1) for (x=0;x<`FB_W;x=x+1) begin
      idx = y*`FB_STRIDE_QW + (x>>2);
      got = ((x&3)==0) ? fbram.bank0[idx] : ((x&3)==1) ? fbram.bank1[idx] :
            ((x&3)==2) ? fbram.bank2[idx] : fbram.bank3[idx];
      e   = exp[y*`FB_W+x];
      // Golden-short trap: an entry past the end of the loaded vectors/*.hex reads
      // back x; x propagates through chan_ok and Verilog treats the resulting x as
      // FALSE, so the pixel would be silently NOT compared. That is exactly how this
      // bench passed vacuously before the geometry root landed — if FB_W/FB_H move
      // without regenerating vectors, fail loudly instead of re-opening the hole.
      // Guard BOTH sides: chan_ok() is symmetric in x-propagation (dr/dg/db are 4-state
      // integers), so chan_ok(x, real) also returns x and `!x` is x, which if() drops.
      // comp_fbram's banks have no sim initialisation, so an unwritten DUT pixel really
      // does read x and would be silently skipped. Reduction-XOR catches any x/z bit.
      if ((^e === 1'bx) || (^got === 1'bx)) begin
        bad=bad+1;
        if (bad<=20) $display("  UNDEFINED at (%0d,%0d): got=%04h exp=%04h — short golden (regenerate vectors) or unwritten FB pixel", x,y,got,e);
      end
      else if (!chan_ok(got,e)) begin
        bad=bad+1;
        if (bad<=20) $display("  MISMATCH (%0d,%0d): got %04h exp %04h", x,y,got,e);
      end
    end
    $display("=== bad pixels = %0d / %0d ===", bad, `FB_PIXELS);
    if (mem[32'h200005][31:0]==mem[32'h200000][31:0] && bad==0) $display("RESULT: PASS");
    else $display("RESULT: FAIL (bad=%0d)", bad);
    $finish;
  end
  // hard watchdog backstop
  initial begin #200000000 $display("RESULT: FAIL (timeout)"); $finish; end
endmodule
`default_nettype wire
