// tb_blitter_trilist_uvfull.sv — full-UV-sweep TRILIST equivalence (Bug A sim gap).
// 128x128 stride-256 coordinate texture at non-zero src_off (vectors/tri_uvfull_*):
// verifies texbyte[7:1] (u), texbyte[15:8] (v), lane select and the tq cache under
// thousands of distinct qword fills — the 8x8 goldens covered one u bit and no lanes.
//
// The control block (@0x200000) requests a CLEAR-before-list (blue bg) followed
// by one textured triangle; the vertex array + texture live at SRC (@0x210000).
// The tri walk composites into comp_fbram via the tri_busy bus muxes.
`timescale 1ns/1ps
`default_nettype none
`include "blitter_defs.vh"
module tb_blitter_trilist_uvfull;
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

  // ── golden framebuffer (76800 RGB565 pixels, index = y*320+x) ────────────────
  reg [15:0] exp [0:320*240-1];

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
    $readmemh("vectors/tri_uvfull_ddr.hex", mem);
    $readmemh("vectors/tri_uvfull_exp.hex", exp);
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
    for (y=0;y<240;y=y+1) for (x=0;x<320;x=x+1) if (exp[y*320+x]!==exp[0]) ncov=ncov+1;
    $display("=== PERF tri=%0d texwait=%0d dpath=%0d covered_px=%0d | dpath_cyc/px=%0d ===",
             blt.perf_tri_cyc, blt.perf_texwait_cyc, blt.perf_tri_cyc-blt.perf_texwait_cyc,
             ncov, (ncov>0)?((blt.perf_tri_cyc-blt.perf_texwait_cyc)/ncov):0);

    bad=0;
    for (y=0;y<240;y=y+1) for (x=0;x<320;x=x+1) begin
      idx = y*80 + (x>>2);
      got = ((x&3)==0) ? fbram.bank0[idx] : ((x&3)==1) ? fbram.bank1[idx] :
            ((x&3)==2) ? fbram.bank2[idx] : fbram.bank3[idx];
      e   = exp[y*320+x];
      if (!chan_ok(got,e)) begin
        bad=bad+1;
        if (bad<=20) $display("  MISMATCH (%0d,%0d): got %04h exp %04h", x,y,got,e);
      end
    end
    $display("=== bad pixels = %0d / %0d ===", bad, 320*240);
    if (mem[32'h200005][31:0]==mem[32'h200000][31:0] && bad==0) $display("RESULT: PASS");
    else $display("RESULT: FAIL (bad=%0d)", bad);
    $finish;
  end
  // hard watchdog backstop
  initial begin #200000000 $display("RESULT: FAIL (timeout)"); $finish; end
endmodule
`default_nettype wire
