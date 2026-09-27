// tb_blitter_trilist_palpha.sv — [TRILIST PALPHA] per-texel alpha on BLT_OP_TRILIST.
//
// Gates blitter_top's BLEND_PALPHA path and the ARGB4444 texel decode bit-exact
// against the golden (sim/blt_tri.c, the mirror of mister-fpga-blitter's refmodel
// blt_tri.c [TRILIST PALPHA] blocks) — see gen_tri_golden.c section 3 for the scene.
//
// Semantics under test (per covered pixel):
//   * ARGB4444 page ({A4,R4,G4,B4}), not a surface source: decode to RGB565
//     (R5={r4,r4[3]}, G6={g4,g4[3:2]}, B5={b4,b4[3]}), a8={a4,a4}, for EVERY blend
//     mode; the tint uses the decoded colour; COLORKEY compares the RAW texel.
//   * PALPHA: a8==0 -> no write; else pa=div255_round(a8*ea), ea=(ca*g_alpha)/255,
//     then the CONST_ALPHA blend with pa.
//
// Default scene = tri_palpha (5 passes over a patterned full-screen bg: PALPHA
// ARGB4444 quad with a vertex-alpha gradient to 0 + tint + header alpha 200;
// COLORKEY ARGB4444; COPY ARGB4444; PALPHA on an RGB565 page). The wrapper
// tb_blitter_trilist_palpha_miss.sv re-runs this harness on tri_palpha_miss
// (tri_missdst's cache-thrash geometry under PALPHA) with PALPHA_EXPECT_MISS set.
//
// GATE: bit-EXACT (not +-1 LSB) — see the note at the verdict.
// NON-VACUITY: every path the scene exists for is counted and ASSERTED below, so a
// scene or RTL change that stops reaching it fails instead of passing vacuously.
//
// CYCLE CONTRACT (the design's "other modes unchanged" claim): for every pixel that
// took no B_WAIT, pb latency pop->B_WR3 inclusive must be exactly 6 cycles for
// non-PALPHA modes and exactly 7 for PALPHA (the one B_WRP cycle). Checked per pixel.
`timescale 1ns/1ps
`default_nettype none
`include "blitter_defs.vh"
`ifndef PALPHA_VEC
`define PALPHA_VEC "tri_palpha"
`endif
`ifndef PALPHA_TB_NAME
`define PALPHA_TB_NAME tb_blitter_trilist_palpha
`endif
module `PALPHA_TB_NAME;
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

  // ── [TRILIST PALPHA] coverage + per-pixel cycle contract ─────────────────────
  // Sampled at B_WR3 (one retire per pixel): b2_we is the pixel's final write-enable.
  // pa is sampled at B_WR2 (b1_ea holds pa there on PALPHA pixels).
  localparam [7:0] BL_COPY=8'd0, BL_KEY=8'd1, BL_PALPHA=8'd3;
  integer pp_skip, pp_part, pp_a15, pp_zero, pp_px, pp_wrp, pp_wrp_bad;
  integer k4_cull, k4_px, c4_a0_wr, c4_px, p565_px;
  integer bwait_cyc, retry_reissue;
  integer lat, lat_bad, hit_px_pal, hit_px_oth, lat_cyc_pal, lat_cyc_oth;
  reg     px_waited;
  reg [7:0] pa_seen;
  initial begin
    pp_skip=0; pp_part=0; pp_a15=0; pp_zero=0; pp_px=0; pp_wrp=0; pp_wrp_bad=0;
    k4_cull=0; k4_px=0; c4_a0_wr=0; c4_px=0; p565_px=0; bwait_cyc=0; retry_reissue=0;
    lat=0; lat_bad=0; hit_px_pal=0; hit_px_oth=0; lat_cyc_pal=0; lat_cyc_oth=0;
    px_waited=1'b0; pa_seen=8'd0;
  end
  always @(posedge clk) if (!rst) begin
    if (blt.pb == blt.B_WAIT) begin
      bwait_cyc <= bwait_cyc + 1; px_waited <= 1'b1;
      if (!blt.fill_busy && blt.tri_need_dst) retry_reissue <= retry_reissue + 1;
    end
    // B_WRP must be entered by PALPHA pixels ONLY
    if (blt.pb == blt.B_WRP) begin
      pp_wrp <= pp_wrp + 1;
      if (blt.c_blend != BL_PALPHA) pp_wrp_bad <= pp_wrp_bad + 1;
    end
    // per-pixel latency: the pop is B_IDLE with a non-empty FIFO
    if ((blt.pb == blt.B_IDLE) && !blt.pf_empty) begin lat <= 1; px_waited <= 1'b0; end
    else if (blt.pb != blt.B_IDLE) lat <= lat + 1;
    if (blt.pb == blt.B_WR2) pa_seen <= blt.b1_ea;
    if (blt.pb == blt.B_WR3) begin
      if (!px_waited) begin
        if (blt.c_blend == BL_PALPHA) begin
          hit_px_pal <= hit_px_pal + 1; lat_cyc_pal <= lat_cyc_pal + lat + 1;
          if (lat + 1 != 7) lat_bad <= lat_bad + 1;
        end else begin
          hit_px_oth <= hit_px_oth + 1; lat_cyc_oth <= lat_cyc_oth + lat + 1;
          if (lat + 1 != 6) lat_bad <= lat_bad + 1;
        end
      end
      if (blt.c_blend == BL_PALPHA) begin
        if (blt.tri_is4444) begin
          pp_px <= pp_px + 1;
          if (!blt.b2_we)               pp_skip <= pp_skip + 1;
          else if (pa_seen == 8'd0)     pp_zero <= pp_zero + 1;
          else                          pp_part <= pp_part + 1;
          if (blt.b2_we && (blt.b1_a4 == 4'hF)) pp_a15 <= pp_a15 + 1;   // a8=255: pa==ea
        end else p565_px <= p565_px + 1;
      end
      if ((blt.c_blend == BL_KEY) && blt.tri_is4444) begin
        k4_px <= k4_px + 1; if (!blt.b2_we) k4_cull <= k4_cull + 1;
      end
      if ((blt.c_blend == BL_COPY) && blt.tri_is4444) begin
        c4_px <= c4_px + 1; if (blt.b2_we && (blt.b1_a4 == 4'd0)) c4_a0_wr <= c4_a0_wr + 1;
      end
    end
  end

  integer cov_fail;
  task palpha_check_coverage;
    begin
      cov_fail = 0;
      $display("PALPHA coverage: ARGB4444 px=%0d skip(a4=0)=%0d blended=%0d pa0=%0d a4=15=%0d | B_WRP=%0d (non-PALPHA entries=%0d)",
               pp_px, pp_skip, pp_part, pp_zero, pp_a15, pp_wrp, pp_wrp_bad);
      $display("PALPHA coverage: RGB565-page PALPHA px=%0d | KEY4444 px=%0d culled=%0d | COPY4444 px=%0d a4=0-written=%0d",
               p565_px, k4_px, k4_cull, c4_px, c4_a0_wr);
      $display("PALPHA coverage: B_WAIT=%0d cyc  miss+dst re-issues=%0d", bwait_cyc, retry_reissue);
      if (pp_px == 0 || pp_skip == 0 || pp_part == 0) begin
        $display("palpha coverage: ARGB4444 PALPHA never reached skip AND partial blend"); cov_fail = 1;
      end
      if (pp_wrp_bad != 0) begin
        $display("palpha coverage: B_WRP entered by a non-PALPHA pixel"); cov_fail = 1;
      end
`ifdef PALPHA_EXPECT_MISS
      if (bwait_cyc == 0 || retry_reissue == 0) begin
        $display("palpha coverage: miss + dst never reached together"); cov_fail = 1;
      end
`else
      // pa==0 with a8>0 (vertex alpha interpolated to 0) must still go through the blend
      // and write dst back unchanged; A4==15 (a8=255) must give pa==ea exactly.
      if (pp_zero == 0 || pp_a15 == 0) begin
        $display("palpha coverage: pa==0-with-a8>0 or A4==15 never reached"); cov_fail = 1;
      end
      if (p565_px == 0) begin
        $display("palpha coverage: PALPHA on an RGB565 page never reached"); cov_fail = 1;
      end
      if (k4_cull == 0 || k4_cull == k4_px) begin
        $display("palpha coverage: ARGB4444 COLORKEY did not both cull and write"); cov_fail = 1;
      end
      if (c4_a0_wr == 0) begin
        $display("palpha coverage: ARGB4444 COPY never wrote an A4==0 texel"); cov_fail = 1;
      end
`endif
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

  integer x,y,idx,bad,nexact;
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
    $readmemh({"vectors/", `PALPHA_VEC, "_ddr.hex"}, mem);
    $readmemh({"vectors/", `PALPHA_VEC, "_exp.hex"}, exp);
  end

  integer to;
  initial begin
    repeat(8) @(posedge clk); rst<=0;
    to=0;
    while (mem[32'h200005][31:0] !== mem[32'h200000][31:0] && to<4000000) begin @(posedge clk); to=to+1; end
    repeat(10) @(posedge clk);
    $display("=== %s done_seq=%0d submit=%0d (to=%0d) ===", `PALPHA_VEC,
             mem[32'h200005][31:0], mem[32'h200000][31:0], to);

    // Per-pixel cost on the hit path (pixels with no B_WAIT), pop -> B_WR3 inclusive.
    $display("=== CYC hit-path: PALPHA %0d px, %.2f cyc/px | other modes %0d px, %.2f cyc/px | contract violations=%0d ===",
             hit_px_pal, (hit_px_pal>0) ? $itor(lat_cyc_pal)/$itor(hit_px_pal) : 0.0,
             hit_px_oth, (hit_px_oth>0) ? $itor(lat_cyc_oth)/$itor(hit_px_oth) : 0.0, lat_bad);
    $display("=== PERF tri=%0d texwait=%0d covered_px(last frame)=%0d ===",
             blt.perf_tri_cyc, blt.perf_texwait_cyc, blt.perf_covered_px);

    palpha_check_coverage;

    bad=0; nexact=0;
    for (y=0;y<`FB_H;y=y+1) for (x=0;x<`FB_W;x=x+1) begin
      idx = y*`FB_STRIDE_QW + (x>>2);
      got = ((x&3)==0) ? fbram.bank0[idx] : ((x&3)==1) ? fbram.bank1[idx] :
            ((x&3)==2) ? fbram.bank2[idx] : fbram.bank3[idx];
      e   = exp[y*`FB_W+x];
      // x/z on either side is a mismatch, never a silent skip (see tb_blitter_trilist_missdst)
      if ((^e === 1'bx) || (^got === 1'bx)) begin
        bad=bad+1;
        if (bad<=20) $display("  UNDEFINED at (%0d,%0d): got=%04h exp=%04h", x,y,got,e);
      end
      else if (!chan_ok(got,e)) begin
        bad=bad+1;
        if (bad<=20) $display("  MISMATCH (%0d,%0d): got %04h exp %04h", x,y,got,e);
      end
      else if (got !== e) nexact=nexact+1;
    end
    $display("=== bad pixels = %0d / %0d (within-1LSB-but-not-exact = %0d) ===", bad, `FB_PIXELS, nexact);
    // EXACT gate, stricter than the suite's +-1 LSB: measured by mutation, a wrong
    // 4->5-bit channel expansion ({r4,r4[0]} for {r4,r4[3]}) and a truncating pa
    // (no +128) both land ENTIRELY inside +-1 LSB (bad=0, 6371 / 1132 inexact px) and
    // pass a tolerance gate. The RTL matches the golden exactly, so demand it.
    if (mem[32'h200005][31:0]==mem[32'h200000][31:0] && bad==0 && nexact==0 && cov_fail==0 && lat_bad==0)
      $display("RESULT: PASS");
    else $display("RESULT: FAIL (bad=%0d inexact=%0d coverage=%0d cycle-contract=%0d)", bad, nexact, cov_fail, lat_bad);
    $finish;
  end
  initial begin #200000000 $display("RESULT: FAIL (timeout)"); $finish; end
endmodule
`default_nettype wire
