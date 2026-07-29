// tb_blitter_trilist_stream.sv — [Phase 3A Task 5] CAPTURED-DEVICE-FRAME replay
// for BLT_OP_TRILIST, with per-state cycle buckets.
//
// Replays one real frame of Maldita's draw stream (an MFTRACE capture from the
// device, turned into a ring + heap + golden framebuffer by gen_tri_stream.c)
// through the production blitter_top, then reports (a) bit-exactness against the
// refmodel golden and (b) a cycle decomposition of the frame. It is the sim-side
// oracle the Stage-B span-walk / occupancy work (Tasks 6-8) predicts against.
//
// ── HARNESS PROVENANCE ──────────────────────────────────────────────────────
// The DUT harness is NOT new. Copied verbatim:
//   - from tb_blitter_trilist_quad.sv: the behavioral DDR3 model (single-beat
//     reads, 3-cycle latency, `bp`-rotated d_busy backpressure -- this is the
//     poll-before-issue gate; blitter_top only issues bm_rd when !mem_busy, and
//     a bench that lets every read issue immediately mis-models the real f2h
//     slot arbitration), the P_SRC "cache-ok" texel source model (P_SRC_LAT=3
//     shift register, edge-detected read pulse), the done_seq==submit_seq
//     completion poll, and the golden compare (+-1 LSB per RGB565 channel with
//     the x-propagation trap for a short golden / unwritten FB pixel).
//   - from tb_blitter_surface_src.sv: the comp_fbram surf_* port wiring and the
//     surface-bank backdoor load. The captured stream contains exactly one
//     BLT_F_SRC_SURFACE draw per frame (the app-surface composite), so without
//     this the replay would sample an uninitialised surface bank.
// The blitter_top instance is named `blt`, matching all eight sibling TRILIST
// benches (and a2_cycle_gate.vh's contract) rather than the `dut` the task brief
// sketched; the CYC output contract below is unchanged by that.
//
// ── WHY THE BUCKETS ARE NOT A `case (state)` ────────────────────────────────
// The task brief sketched `case (dut.state)` over S_TRI_PIX/GOTTEX/WR/WR2/WR3/
// MUL/... That encoding is PRE-PIPELINE. In the shipping RTL (blitter_top.sv
// "[pipeline stage 3a]") the per-pixel walk was split into two CONCURRENT
// sub-FSMs, pa (coverage -> mul -> texel address -> P_SRC issue) and pb (texel
// wait -> dst -> 3-stage blend -> write), and the top-level `state` sits in a
// single UMBRELLA value for the whole walk:
//     S_TRI_PIX: begin ... // umbrella S_TRI_RUN: tick pa || pb
// Verified against fpga/rtl/blitter_top.sv lines 177-198 (encodings) and the
// state<= assignments: the only REACHABLE top-level TRILIST states are
//   S_TRI_VFETCH=45, S_TRI_VCOLLECT=46, S_TRI_DECV=47, S_TRI_SETUP=48,
//   S_TRI_SWAIT=49, S_TRI_PIX=50 (umbrella), S_TRI_NEXT=56.
// S_TRI_GOTTEX=51, S_TRI_DSTW=52, S_TRI_DSTC=53, S_TRI_WR=54, S_TRI_ADV=55,
// S_TRI_MUL=57, S_TRI_WR2=58, S_TRI_WR3=59, S_TRI_ADDR=60, S_TRI_MUL0=61,
// S_TRI_ADDR2=62 and S_TRI_MUL1=63 are DEAD (no `state<=` targets them). A
// literal `case (state)` bucketing would therefore report every per-pixel cycle
// as "pix" and zero for texwait/wr -- a plausible-looking, wrong answer. The
// buckets below key off `blt.pa` / `blt.pb` inside the umbrella instead, and
// every state/sub-state name is referenced HIERARCHICALLY (blt.S_TRI_PIX,
// blt.A_PIX, blt.B_WAIT) so a renumbering breaks the build instead of silently
// miscounting -- the rule a2_cycle_gate.vh already established.
//
// ── OUTPUT CONTRACT (consumed by Tasks 6/7/8) ───────────────────────────────
//   CYC total=<n> tri=<n> pix_visits=<n> pix_covered=<n> texwait=<n> wr=<n> \
//       setup=<n> vfetch=<n> pix=<n> other=<n>
// total : cycles the fabric is busy on the frame == blt.perf_frame_cyc, the SAME
//         definition as the device's C_STATUS-published `frame` counter, so
//         total/98.4375e6 is directly comparable to the device's frame ms.
// tri   : cycles with state >= S_TRI_VFETCH == blt.perf_tri_cyc (device `tri`).
//         NOTE tri EXCLUDES the vertex-fetch memory stalls: S_TRI_VFETCH hands
//         off to S_RD_WAIT (=23), which is below the >=45 window. Those cycles
//         are in the `vfetch` bucket (below) but not in `tri` -- that asymmetry
//         is the RTL's, not this bench's, and it is why total > tri by more than
//         the CLEAR.
// pix_visits  : bbox coverage TESTS, i.e. cycles with pa==A_PIX && tri_cv. Each
//         such cycle evaluates exactly one candidate pixel and advances the
//         cursor (both A_PIX branches call advance_cursor), so this equals the
//         analyzer's bbox_px. It is an OCCUPANCY count, not a partition bucket
//         (pa runs concurrently with pb).
// pix_covered : dispatched covered pixels == blt.perf_covered_px (the A_PIX
//         branch that latches the multiply operands). Equals the analyzer's
//         covered_px. Independently re-counted TB-side and cross-asserted.
// The five PARTITION buckets -- texwait, wr, setup, vfetch, pix, other -- are
// assigned by strict priority, one bucket per busy cycle, and sum to total:
//   1 vfetch : state in {VFETCH,VCOLLECT,DECV} or (S_RD_WAIT for a tri return)
//   2 setup  : state in {SETUP,SWAIT}
//   3 texwait: umbrella && pb==B_WAIT      (== blt.perf_texwait_cyc)
//   4 wr     : umbrella && pb in {B_WR,B_WR2,B_WR3}
//   5 pix    : umbrella && pa==A_PIX && tri_cv   (bbox tests NOT shadowed by pb)
//   6 other  : everything else -- pa's mul/addr/issue cycles, pb's LOOK/FILL/
//              SURF cycles, S_TRI_NEXT, the CLEAR fill, ring/control fetch and
//              the perf publish tail.
// A second line, CYCX, breaks `other` down by pa and pb sub-state (raw
// occupancy, overlapping) plus the non-TRILIST frame cost -- that is the
// pipeline-occupancy data Task 7 needs and it is deliberately NOT squeezed into
// the CYC contract.
//
// ── SELECTING A FRAME ───────────────────────────────────────────────────────
// Default vectors are stream_quiet_f0 (mftrace-quiet.txt frame 0). To replay a
// different capture, regenerate its vectors and recompile with the tag:
//   make -f gen_tri_golden.mk gen_tri_stream
//   ./gen_tri_stream ../../../mister-gmloader/docs/superpowers/findings/data/mftrace-quiet.txt 1 stream_quiet_f1
//   iverilog -g2012 -DSTREAM_VEC='"stream_quiet_f1"' -o /tmp/s.vvp \
//     -I ../rtl -I ../rtl/jtframe -I ../sys -I . -y ../rtl -y ../rtl/jtframe \
//     -y ../sys -y . -Y .sv -Y .v *_stub.sv tb_blitter_trilist_stream.sv && vvp /tmp/s.vvp
//
// ── TEXTURE-CONTENT CAVEAT ──────────────────────────────────────────────────
// The capture carries texture geometry but no texel data; gen_tri_stream.c fills
// referenced pages with a deterministic address hash and places each page
// CONGRUENT to its device offset modulo the 2048-byte texel-cache index period,
// so every cache hit/miss the device took is reproduced. Bit-exactness is
// asserted RTL-vs-refmodel over the SAME DDR image, so the golden gate holds;
// and no cycle in this design depends on a texel VALUE (the COLORKEY cull only
// suppresses fb_wr_en in stage B_WR -- the pixel still traverses B_WR/2/3).
// What is NOT reproduced is device memory LATENCY: P_SRC here is the fixed
// 3-cycle stub, not sdram_fb_cache + mt48, so `texwait` is a FLOOR. See
// gen_tri_stream.c's header and the Task 5 calibration table.
`timescale 1ns/1ps
`default_nettype none
`include "blitter_defs.vh"

// Vector tag (see "SELECTING A FRAME").
`ifndef STREAM_VEC
`define STREAM_VEC "stream_quiet_f0"
`endif

module tb_blitter_trilist_stream;
  localparam [28:0] WBASE = 29'h07400000;
  // A captured frame's heap is far larger than the synthetic scenarios' (the quiet
  // frame interns 48 texture pages == ~219 KiB after the congruence padding), so the
  // SRC headroom is 0x10000 qwords (512 KiB) instead of the siblings' 0x8000. Keep in
  // step with SRC_HEADROOM_BYTES in gen_tri_stream.c, which refuses to emit a heap
  // that would overrun this window.
  localparam [28:0] SRC_HEADROOM_QW = 29'h10000;
  localparam        MEMQW = (`SRC_QW - 29'h07400000) + SRC_HEADROOM_QW;

  reg clk=0, rst=1; always #5 clk=~clk;

  wire [31:0] bt_addr; wire b_rd, b_we; wire [63:0] b_din; wire [7:0] b_be; wire bt_idle;
  reg  d_dready; reg [63:0] d_dout;

  // ── behavioral DDR (verbatim from tb_blitter_trilist_quad.sv) ──────────────
  // d_busy is the POLL GATE: blitter_top's read/write masters only fire when
  // mem_busy is low, so this 4-cycle rotation + in-flight-beat term is what makes
  // the bench model "poll before issue" instead of an infinitely available bus.
  reg [63:0] mem [0:MEMQW-1];
  reg [7:0] rbeats; reg [28:0] raddr; reg [2:0] rlat; reg [1:0] bp=0;
  always @(posedge clk) bp <= bp+2'd1;
  wire d_busy = (bp != 2'd2) | (rbeats != 8'd0) | (rlat != 3'd0);
  integer i;

  // ── P_SRC cache-ok source model (verbatim from tb_blitter_trilist_quad.sv) ──
  localparam P_SRC_LAT = 3;
  localparam [28:0] SRC_WIN = `SRC_QW - WBASE;
  wire [26:0] s_src_addr; wire s_src_rd;
  reg  [63:0] s_src_dout; reg s_src_ok=1'b0;
  reg         s_rd_d;
  reg [26:0]  s_lat_addr [0:P_SRC_LAT-1];
  reg         s_lat_v    [0:P_SRC_LAT-1];
  integer     sli;
  always @(posedge clk) s_rd_d <= s_src_rd;
  always @(posedge clk) begin
    s_src_ok <= 1'b0;
    s_lat_v   [0] <= s_src_rd & ~s_rd_d;
    s_lat_addr[0] <= s_src_addr;
    for (sli = 1; sli < P_SRC_LAT; sli = sli + 1) begin
      s_lat_v   [sli] <= s_lat_v   [sli-1];
      s_lat_addr[sli] <= s_lat_addr[sli-1];
    end
    if (s_lat_v[P_SRC_LAT-1]) begin
      s_src_dout <= mem[SRC_WIN + (s_lat_addr[P_SRC_LAT-1] >> 3)];
      s_src_ok   <= 1'b1;
    end
  end

  wire [7:0] bt_burst;
  wire fb_wr_en; wire [14:0] fb_wr_qw; wire [1:0] fb_wr_lane; wire [15:0] fb_wr_pix;
  wire fb_rd_en; wire [14:0] fb_rd_qw; wire [63:0] fb_rd_qword;
  // surf_* (from tb_blitter_surface_src.sv): the captured stream's one
  // BLT_F_SRC_SURFACE draw samples this bank.
  wire sf_wr_en; wire [14:0] sf_wr_qw; wire [1:0] sf_wr_lane; wire [15:0] sf_wr_pix;
  wire sf_rd_en; wire [14:0] sf_rd_qw; wire [63:0] sf_rd_qword;
  comp_fbram fbram(.clk(clk),
    .wr_en(fb_wr_en), .wr_qw(fb_wr_qw), .wr_lane(fb_wr_lane), .wr_pix(fb_wr_pix),
    .rd_en(fb_rd_en), .rd_qw(fb_rd_qw), .rd_qword(fb_rd_qword),
    .surf_wr_en(sf_wr_en), .surf_wr_qw(sf_wr_qw), .surf_wr_lane(sf_wr_lane), .surf_wr_pix(sf_wr_pix),
    .surf_rd_en(sf_rd_en), .surf_rd_qw(sf_rd_qw), .surf_rd_qword(sf_rd_qword));
  blitter_top blt(.clk(clk), .rst(rst),
    .mem_addr(bt_addr), .mem_rd(b_rd), .mem_wr(b_we), .mem_burstcnt(bt_burst),
    .mem_din(b_din), .mem_be(b_be),
    .mem_dout(d_dout), .mem_dout_ready(d_dready), .mem_busy(d_busy),
    .p0_addr(s_src_addr), .p0_rd(s_src_rd), .p0_dout(s_src_dout), .p0_ok(s_src_ok),
    .fb_wr_en(fb_wr_en), .fb_wr_qw(fb_wr_qw), .fb_wr_lane(fb_wr_lane), .fb_wr_pix(fb_wr_pix),
    .fb_rd_en(fb_rd_en), .fb_rd_qw(fb_rd_qw), .fb_rd_qword(fb_rd_qword),
    .surf_wr_en(sf_wr_en), .surf_wr_qw(sf_wr_qw), .surf_wr_lane(sf_wr_lane), .surf_wr_pix(sf_wr_pix),
    .surf_rd_en(sf_rd_en), .surf_rd_qw(sf_rd_qw), .surf_rd_qword(sf_rd_qword),
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

  // ══ cycle buckets (TB-side only; Stage A adds NO RTL counter) ══════════════
  // All state / sub-state names bind hierarchically to blitter_top's localparams.
  wire in_tri    = (blt.state >= blt.S_TRI_VFETCH);
  wire umbrella  = (blt.state == blt.S_TRI_PIX);
  wire in_vfetch = (blt.state == blt.S_TRI_VFETCH) || (blt.state == blt.S_TRI_VCOLLECT)
                || (blt.state == blt.S_TRI_DECV)
                // vertex-fetch memory stall: VFETCH/VCOLLECT park in S_RD_WAIT with
                // rd_ret pointing back into the TRILIST walk. Those cycles are NOT in
                // perf_tri_cyc (state 23 < 45), so charge them here or they vanish
                // into `other` and the vertex cost reads as free.
                || ((blt.state == blt.S_RD_WAIT) && (blt.rd_ret >= blt.S_TRI_VFETCH));
  wire in_setup  = (blt.state == blt.S_TRI_SETUP) || (blt.state == blt.S_TRI_SWAIT);
  wire in_texw   = umbrella && (blt.pb == blt.B_WAIT);
  wire in_wr     = umbrella && ((blt.pb == blt.B_WR) || (blt.pb == blt.B_WR2) || (blt.pb == blt.B_WR3));
  // one candidate pixel tested per cycle (both A_PIX branches advance the cursor)
  wire pix_test  = umbrella && (blt.pa == blt.A_PIX) && blt.tri_cv;
  // the covered-DISPATCH branch: coverage test passes on all three edge functions.
  // Same condition perf_covered_px increments on (blitter_top.sv ~line 1423);
  // re-derived here so the bench does not just echo the register it is checking.
  wire cov_disp  = pix_test && ($signed(blt.w0) >= 0) && ($signed(blt.w1) >= 0)
                            && ($signed(blt.w2) >= 0);

  integer cyc_total, cyc_tri, cyc_vfetch, cyc_setup, cyc_texw, cyc_wr, cyc_pix, cyc_other;
  integer pix_visits, tb_covered;
  // CYCX detail: pa/pb occupancy (overlapping, not a partition) + non-TRILIST cost
  integer occ_pa [0:7];
  integer occ_pb [0:15];
  integer cyc_nontri, cyc_vwait;
  integer bi;
  reg     counting;

  initial begin
    cyc_total=0; cyc_tri=0; cyc_vfetch=0; cyc_setup=0; cyc_texw=0; cyc_wr=0;
    cyc_pix=0; cyc_other=0; pix_visits=0; tb_covered=0; cyc_nontri=0; cyc_vwait=0;
    counting=0;
    for (bi=0;bi<8;bi=bi+1)  occ_pa[bi]=0;
    for (bi=0;bi<16;bi=bi+1) occ_pb[bi]=0;
  end

  // Gate on !blt.idle so cyc_total tracks perf_frame_cyc exactly (idle is 1 only
  // while polling between frames). `counting` suppresses the pre-reset x window.
  always @(posedge clk) if (counting && !rst && (blt.idle === 1'b0)) begin
    cyc_total <= cyc_total + 1;
    if (in_tri) cyc_tri <= cyc_tri + 1; else cyc_nontri <= cyc_nontri + 1;
    if ((blt.state == blt.S_RD_WAIT) && (blt.rd_ret >= blt.S_TRI_VFETCH)) cyc_vwait <= cyc_vwait + 1;
    // strict-priority partition (see header)
    if      (in_vfetch) cyc_vfetch <= cyc_vfetch + 1;
    else if (in_setup)  cyc_setup  <= cyc_setup  + 1;
    else if (in_texw)   cyc_texw   <= cyc_texw   + 1;
    else if (in_wr)     cyc_wr     <= cyc_wr     + 1;
    else if (pix_test)  cyc_pix    <= cyc_pix    + 1;
    else                cyc_other  <= cyc_other  + 1;
    // occupancy counts (independent of the partition)
    if (pix_test) pix_visits <= pix_visits + 1;
    if (cov_disp) tb_covered <= tb_covered + 1;
    if (umbrella) begin
      occ_pa[blt.pa] <= occ_pa[blt.pa] + 1;
      occ_pb[blt.pb] <= occ_pb[blt.pb] + 1;
    end
  end

  // ── golden framebuffer + surface source image ──────────────────────────────
  reg [15:0] exp     [0:`FB_PIXELS-1];
  reg [15:0] surfimg [0:`FB_PIXELS-1];

  integer x,y,idx,bad,exact_bad,sidx;
  reg [15:0] got, e;
  // +-1 LSB per RGB565 channel (same tolerance as every sibling TRILIST bench);
  // `exact_bad` additionally reports strict bit-exactness.
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
    $readmemh({"vectors/", `STREAM_VEC, "_ddr.hex"}, mem);
    $readmemh({"vectors/", `STREAM_VEC, "_exp.hex"}, exp);
    $readmemh("vectors/stream_surf.hex", surfimg);
    // backdoor-load the surface bank (linear -> qword/lane), from tb_blitter_surface_src
    for (y=0;y<`FB_H;y=y+1) for (x=0;x<`FB_W;x=x+1) begin
      sidx = y*`FB_STRIDE_QW + (x>>2);
      case (x&3)
        2'd0: fbram.surf_bank0[sidx] = surfimg[y*`FB_W+x];
        2'd1: fbram.surf_bank1[sidx] = surfimg[y*`FB_W+x];
        2'd2: fbram.surf_bank2[sidx] = surfimg[y*`FB_W+x];
        2'd3: fbram.surf_bank3[sidx] = surfimg[y*`FB_W+x];
      endcase
    end
  end

  integer to;
  real    ms_total, ms_tri, ms_texw;
  initial begin
    $display("=== stream replay: %0s ===", `STREAM_VEC);
    repeat(8) @(posedge clk); rst<=0;
    counting <= 1'b1;
    // A captured frame is ~1-3 M cycles (vs ~150 k for the synthetic scenarios), so
    // the completion budget is 40 M, not the siblings' 4 M.
    to=0;
    while (mem[32'h200005][31:0] !== mem[32'h200000][31:0] && to<40000000) begin @(posedge clk); to=to+1; end
    repeat(10) @(posedge clk);
    $display("=== done_seq=%0d submit=%0d (to=%0d) ===", mem[32'h200005][31:0], mem[32'h200000][31:0], to);

    bad=0; exact_bad=0;
    for (y=0;y<`FB_H;y=y+1) for (x=0;x<`FB_W;x=x+1) begin
      idx = y*`FB_STRIDE_QW + (x>>2);
      got = ((x&3)==0) ? fbram.bank0[idx] : ((x&3)==1) ? fbram.bank1[idx] :
            ((x&3)==2) ? fbram.bank2[idx] : fbram.bank3[idx];
      e   = exp[y*`FB_W+x];
      // Golden-short / unwritten-pixel trap (see tb_blitter_trilist_quad.sv for the
      // full rationale): x propagates through chan_ok and Verilog drops the if(),
      // so an uncompared pixel would silently pass.
      if ((^e === 1'bx) || (^got === 1'bx)) begin
        bad=bad+1; exact_bad=exact_bad+1;
        if (bad<=20) $display("  UNDEFINED at (%0d,%0d): got=%04h exp=%04h — short golden (regenerate vectors) or unwritten FB pixel", x,y,got,e);
      end else begin
        if (got !== e) exact_bad = exact_bad+1;
        if (!chan_ok(got,e)) begin
          bad=bad+1;
          if (bad<=20) $display("  MISMATCH (%0d,%0d): got %04h exp %04h", x,y,got,e);
        end
      end
    end
    $display("=== bad pixels = %0d / %0d (bit-exact mismatches = %0d) ===", bad, `FB_PIXELS, exact_bad);

    // ── cycle report ────────────────────────────────────────────────────────
    // Cross-check the TB buckets against the RTL's own per-frame counters. These
    // are independent derivations of the same quantities, so a divergence means a
    // bucket condition drifted from the RTL and every number below is suspect.
    if (cyc_total !== blt.perf_frame_cyc)
      $display("  NOTE: cyc_total=%0d vs blt.perf_frame_cyc=%0d (publish tail: the DONE/STATUS/PERF writes land after the counter is sampled)",
               cyc_total, blt.perf_frame_cyc);
    if (cyc_tri !== blt.perf_tri_cyc)
      $display("RESULT: FAIL (cyc_tri=%0d != perf_tri_cyc=%0d)", cyc_tri, blt.perf_tri_cyc);
    if (cyc_texw !== blt.perf_texwait_cyc)
      $display("RESULT: FAIL (cyc_texw=%0d != perf_texwait_cyc=%0d)", cyc_texw, blt.perf_texwait_cyc);
    if (tb_covered !== blt.perf_covered_px)
      $display("RESULT: FAIL (tb_covered=%0d != perf_covered_px=%0d)", tb_covered, blt.perf_covered_px);

    $display("CYC total=%0d tri=%0d pix_visits=%0d pix_covered=%0d texwait=%0d wr=%0d setup=%0d vfetch=%0d pix=%0d other=%0d",
             cyc_total, cyc_tri, pix_visits, blt.perf_covered_px, cyc_texw, cyc_wr,
             cyc_setup, cyc_vfetch, cyc_pix, cyc_other);
    $display("CYCX nontri=%0d vwait=%0d pa_pix=%0d pa_mul0=%0d pa_mul1=%0d pa_mul=%0d pa_addr=%0d pa_addr2=%0d pa_issue=%0d pa_done=%0d",
             cyc_nontri, cyc_vwait, occ_pa[0], occ_pa[1], occ_pa[2], occ_pa[3],
             occ_pa[4], occ_pa[5], occ_pa[6], occ_pa[7]);
    $display("CYCX pb_idle=%0d pb_look=%0d pb_fill=%0d pb_wait=%0d pb_wr=%0d pb_wr2=%0d pb_wr3=%0d pb_surfw=%0d pb_surfc=%0d",
             occ_pb[0], occ_pb[1], occ_pb[2], occ_pb[3], occ_pb[6], occ_pb[7],
             occ_pb[8], occ_pb[9], occ_pb[10]);
    // partition self-check: the six buckets must reconstruct total exactly.
    if ((cyc_vfetch + cyc_setup + cyc_texw + cyc_wr + cyc_pix + cyc_other) !== cyc_total)
      $display("RESULT: FAIL (bucket partition %0d != total %0d)",
               cyc_vfetch + cyc_setup + cyc_texw + cyc_wr + cyc_pix + cyc_other, cyc_total);
    // 98.4375 MHz fabric clock (the clk_sys these cycles are counted in).
    ms_total = cyc_total / 98437.5;
    ms_tri   = cyc_tri   / 98437.5;
    ms_texw  = cyc_texw  / 98437.5;
    $display("MS  total=%0.3f tri=%0.3f texwait=%0.3f  (@98.4375 MHz)", ms_total, ms_tri, ms_texw);
    if (blt.perf_covered_px != 0)
      $display("CPP cyc_per_covered_px total=%0.3f tri=%0.3f",
               cyc_total*1.0/blt.perf_covered_px, cyc_tri*1.0/blt.perf_covered_px);

    if (mem[32'h200005][31:0]==mem[32'h200000][31:0] && bad==0) $display("RESULT: PASS");
    else $display("RESULT: FAIL (bad=%0d)", bad);
    $finish;
  end
  // hard watchdog backstop (40 M cycles at 10 ns = 400 ms sim time; allow 2x)
  initial begin #900000000 $display("RESULT: FAIL (timeout)"); $finish; end
endmodule
`default_nettype wire
