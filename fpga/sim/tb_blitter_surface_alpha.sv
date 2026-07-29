// tb_blitter_surface_alpha.sv — [Phase 1 2c] the B_SURF_C arm of A2-DSTALE.
//
// THE GAP THIS CLOSES. A2-DSTALE has two arms; Task 2b covered the B_FILL one. The
// B_SURF_C arm needs tri_src_surface AND tri_need_dst together, and no bench had both:
// tb_blitter_surface_src is BLEND_COPY (tri_need_dst false), and every dst-reading bench
// uses an SDRAM texture (tri_src_surface false). So the arm was never evaluated in the
// meaningful direction.
//
// That matters because A2 CHANGED B_SURF_C: it used to run B_SURF_C -> B_DSTW -> B_DSTC
// and now latches comp_rd_qword directly, using B_SURF_W as the read-latency cycle. A2
// modified a production path with no coverage — the same shape as the miss+dst gap, one
// branch over.
//
// PRODUCTION-REACHABLE, not a synthetic corner: raster_backend_mfgpu.cpp:203-207 documents
// that obj_fade_in / obj_fade_out draw the app surface TRANSLUCENTLY over a cleared target
// (and the CRT-ghost strip deliberately does not fire on those, so a fade is never
// swallowed). Surface-source TRILISTs with dst-reading blends therefore reach the fabric on
// EVERY FADE TRANSITION. If A2 broke this path the symptom is corrupted fades —
// intermittent, transition-only, and easy to miss in a steady-gameplay screenshot.
//
// Scene = tri_surface's fullscreen surface-source quad at per-vertex alpha 128. Alpha 128
// not 255 is load-bearing (same reasoning as tri_missdst): at 255 the blend result is the
// source regardless of the destination, so a mis-sequenced dst read would still produce a
// bit-identical golden and this bench would be blind.
//
// RESULT: A2 did NOT break this path. Confirmed by building the pre-A2 RTL (911bb4c) and
// running this same bench against it: BYTE-IDENTICAL output to the current RTL.
//
// WHAT THE MUTATIONS SHOWED — two of them, because the obvious one proves nothing:
//
//   (A) Restore the pre-A2 B_SURF_C -> B_DSTW -> B_DSTC sequencing: the PIXEL DIFF passes,
//       and that is correct — with A2's B_IDLE hoist still in place the old tail simply
//       issues a SECOND read to the SAME address and latches that: two cycles slower,
//       identical pixels. It is a PERFORMANCE regression, not a correctness one, so a
//       golden diff has nothing to catch.
//       It is caught by the CYCLE GATE below, which is the instrument that should catch
//       it: pb 8.00 vs 6.00 -> "FAIL A2: pb 8.00 cyc/px exceeds the 7.0-cycle budget".
//       Before that gate was added here, this regression passed in EVERY bench — the gate
//       lived only in trilist_pipe/add/calpha, all of which take the SDRAM texel path.
//
//   (B) Keep A2's B_SURF_C latch but suppress the B_IDLE dst-read issue for the surface
//       path (`tri_need_dst && !tri_src_surface`) — hoist the latch and forget the read,
//       which is the way A2 could actually have broken this:
//           A2-DSTALE fires: "B_SURF_C latched dst_q with no dst read issued last cycle"
//           and with A2-DSTALE suppressed the pixel diff ALSO catches it: bad=62208/62208.
//
// So on THIS path both instruments discriminate — unlike the B_FILL/miss path in Task 2b,
// where only A2-DSTALE did. The difference is real: in 2b the mis-placed read still
// targeted the SAME address and comp_fbram holds rd_qword, so the data stayed correct;
// here the read is never issued at all, so comp_rd_qword carries an unrelated qword and
// the corruption is visible.
`timescale 1ns/1ps
`default_nettype none
`include "blitter_defs.vh"
module tb_blitter_surface_alpha;
  localparam [28:0] WBASE = 29'h07400000;
  localparam        MEMQW = (`SRC_QW - 29'h07400000) + 29'h8000;

  reg clk=0, rst=1; always #5 clk=~clk;

  wire [31:0] bt_addr; wire b_rd, b_we; wire [63:0] b_din; wire [7:0] b_be; wire bt_idle;
  reg  d_dready; reg [63:0] d_dout;

  // behavioral DDR: single-beat reads w/ latency + backpressure (clone of trilist_pipe).
  reg [63:0] mem [0:MEMQW-1];
  reg [7:0] rbeats; reg [28:0] raddr; reg [2:0] rlat; reg [1:0] bp=0;
  always @(posedge clk) bp <= bp+2'd1;
  wire d_busy = (bp != 2'd2) | (rbeats != 8'd0) | (rlat != 3'd0);
  integer i;

  // ── P_SRC cache-ok source model: trivial always-ready, returns 0. The surface
  // texel path issues NO p0 reads; this only keeps the PRE-implementation RTL (which
  // still samples SDRAM) from hanging — it reads 0 and mismatches, a clean FAIL. ──
  wire [26:0] s_src_addr; wire s_src_rd;
  reg  [63:0] s_src_dout=64'd0; reg s_src_ok=1'b0; reg s_rd_d=1'b0;
  always @(posedge clk) begin
    s_rd_d    <= s_src_rd;
    s_src_ok  <= s_src_rd & ~s_rd_d;   // 1-cycle ok after each read pulse
    s_src_dout<= 64'd0;
  end

  wire [7:0] bt_burst;
  wire fb_wr_en; wire [14:0] fb_wr_qw; wire [1:0] fb_wr_lane; wire [15:0] fb_wr_pix;
  wire fb_rd_en; wire [14:0] fb_rd_qw; wire [63:0] fb_rd_qword;
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

  // [Phase 1 2c-minor] A2's cycle win on the SURFACE path was pinned by nothing: the gate
  // lives only in trilist_pipe / add / calpha, all of which take the SDRAM texel path. So
  // reverting A2's B_SURF_C tail (mutation A in the header above) was a real 2-cycle
  // regression that no bench would have caught. It is caught here now.
  //   post-A2 surface+dst: B_IDLE B_SURF_W B_SURF_C B_WR B_WR2 B_WR3            = 6
  //   pre-A2  surface+dst: ... B_SURF_C B_DSTW B_DSTC B_WR B_WR2 B_WR3          = 8
  // The existing 7.0 budget sits between them, exactly as it does on add/calpha.
  `define A2_PB_MAX 7.0
  `include "a2_cycle_gate.vh"

  // ── [Phase 1 2c] NON-VACUITY: prove the B_SURF_C + dst arm was actually reached ──
  // Without this the bench could silently stop covering its one purpose (a blend-mode
  // edit, a flags change) and keep passing green — the failure mode Task 2b was created
  // to fix, and the reason this file exists at all.
  integer sa_surfc_dst_px, sa_surfc_px;
  initial begin sa_surfc_dst_px = 0; sa_surfc_px = 0; end
  always @(posedge clk) if (!rst) begin
    if (blt.pb == blt.B_SURF_C) begin
      sa_surfc_px <= sa_surfc_px + 1;
      if (blt.tri_need_dst) sa_surfc_dst_px <= sa_surfc_dst_px + 1;
    end
  end

  task sa_check_coverage;
    begin
      $display("SURFALPHA coverage: B_SURF_C=%0d px, of which dst-reading=%0d",
               sa_surfc_px, sa_surfc_dst_px);
      if (sa_surfc_px == 0) begin
        $display("FAIL surf-alpha: B_SURF_C never entered — the surface texel path was");
        $display("                 not taken, so this bench covers nothing");
        $finish;
      end
      if (sa_surfc_dst_px == 0) begin
        $display("FAIL surf-alpha: no pixel took the surface + dst path (tri_need_dst");
        $display("                 never true at B_SURF_C) — the A2-DSTALE B_SURF_C arm");
        $display("                 is still unexercised");
        $finish;
      end
      $display("PASS surf-alpha coverage: surface + dst reached %0d times", sa_surfc_dst_px);
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

  // ── golden framebuffer + surface source image ────────────────────────────────
  reg [15:0] exp     [0:`FB_PIXELS-1];
  reg [15:0] surfimg [0:`FB_PIXELS-1];

  integer x,y,idx,bad,sidx;
  reg [15:0] got, e;
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
    $readmemh("vectors/tri_surfalpha_ddr.hex", mem);
    $readmemh("vectors/tri_surfalpha_exp.hex", exp);
    $readmemh("vectors/tri_surfalpha_surf.hex", surfimg);
    // backdoor-load the surface bank with the golden's surface image (linear -> qword/lane)
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
  initial begin
    repeat(8) @(posedge clk); rst<=0;
    to=0;
    while (mem[32'h200005][31:0] !== mem[32'h200000][31:0] && to<4000000) begin @(posedge clk); to=to+1; end
    repeat(10) @(posedge clk);
    $display("=== done_seq=%0d submit=%0d (to=%0d) ===", mem[32'h200005][31:0], mem[32'h200000][31:0], to);

    // [Phase 1 2c] Prove the arm was reached BEFORE trusting the diff.
    sa_check_coverage;
    // [Phase 1 2c-minor] pin the surface path's cycle cost too.
    a2_report_cycles;

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
  initial begin #200000000 $display("RESULT: FAIL (timeout)"); $finish; end
endmodule
`default_nettype wire
