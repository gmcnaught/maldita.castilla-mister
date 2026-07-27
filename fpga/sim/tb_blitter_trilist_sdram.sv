// tb_blitter_trilist_sdram.sv — TRILIST texel fetch through the REAL sdram_fb_cache
// + mt48 SDRAM chip model (Bug A follow-through: no prior bench co-simulated the
// rasterizer's P_SRC path with the real cache — texel reads always hit a behavioral
// stub). Phase 1 stages the tri_uvfull 32 KiB coordinate texture DDR3->SDRAM via a
// real BLT_OP_STAGE (ch1, ~126 evictions); phase 2 runs the tri_uvfull TRILIST with
// blitter p0_* wired to the cache ch5, and diffs comp_fbram against the golden.
// If this bench FAILS with row-constant/column-pinned texels, it has REPRODUCED
// Bug A in sim — capture the pattern and report; do not "fix" the bench.
//
// HISTORY (2026-07-26): on first landing, BOTH this bench (bad=175/76800) and the
// pure-BRAM sibling tb_blitter_trilist_uvfull (bad=173) were RED with a column-
// constant wrong-qword band at screen x~51 — root-caused to the pa/pb tri_p0_addr
// clobber in blitter_top (pb B_FILL overwrote pa's A_ADDR2->A_ISSUE pipeline reg)
// and fixed by the pa-private pa_qtag register. Post-fix both benches are bad=0
// (the 2 extra real-cache pixels were the same bug via fetch timing). The uvfull
// sibling GATES again; this bench stays NONGATING as a slower (~45s+) dev tool.
// DELTA SEMANTICS today: any future mismatch HERE while uvfull stays green
// implicates sdram_fb_cache/SDRAM/timing specifically, not the rasterizer.
`timescale 1ns/1ps
`default_nettype none
`include "blitter_defs.vh"
`include "vram_defs.vh"

module tb_blitter_trilist_sdram;
  localparam [28:0] WBASE = 29'h07400000;
  // Same heap sizing as tb_blitter_trilist_uvfull (proven sufficient for the
  // tri_uvfull hex: SRC_OFF + TEX_OFF(0x100) + 32768-byte texture fits well
  // inside the +0x8000 qword headroom).
  localparam        MEMQW = (`SRC_QW - 29'h07400000) + 29'h8000;

  reg clk_sys = 0;   always #5 clk_sys   = ~clk_sys;
  reg clk_sdram = 1; always #5 clk_sdram = ~clk_sdram;
  reg reset = 1;

  // phase-1 STAGE parameters: copy the tri_uvfull coordinate texture DDR3->SDRAM
  // at the SAME offset (flags=0 variant — no F_STAGE_DST), matching TEX_OFF used
  // by the TRILIST command already baked into the hex (gen_tri_golden.c: TEX_OFF).
  localparam [26:0] STAGE_OFF   = 27'h100;   // == TEX_OFF: same-offset staging
  localparam integer STAGE_BYTES = 32768;    // 128*128*2 (128x128 RGB565 texture)

  // ---- blitter -> vram_demux ----
  wire [31:0] bt_addr; wire bt_rd, bt_wr; wire [63:0] bt_din; wire [7:0] bt_be;
  wire [7:0]  bt_burstcnt; wire bt_idle; wire [31:0] blt_dbg;
  wire [63:0] blt_demux_dout; wire blt_demux_dready, blt_busy_w;
  wire [28:0] bd_addr; wire bd_rd, bd_wr; wire [63:0] bd_din; wire [7:0] bd_be;
  wire        b_grant; wire blt_arb_busy;
  // blitter STAGING-write outputs (BLT_OP_STAGE ch1 burst-write path).
  wire        bs_we;        wire [15:0] bs_din;  wire [26:0] bs_waddr;
  wire        bs_we_burst;  wire [63:0] bs_din64;
  wire        stage_ok;
  wire        blt_stage_barrier; wire blt_stage_busy;
  wire [3:0]  vdemux_dbg;

  // blitter <-> cache P_SRC texel port — the real thing this bench exists to cover:
  // unlike tb_stage_psrc (TB drives p0 itself), here the blitter's own p0_* drives
  // the cache directly, so the TRILIST texel walk goes through ch5 + real SDRAM.
  wire [26:0] p0_addr; wire p0_rd; wire [63:0] p0_dout; wire p0_ok;

  // vs (scanout vblank) pulse — shared by blt.vs (post-command snapshot FSM, see the
  // blitter_top instance comment below) and the cache's coherency vs (declared here
  // so it exists before the blitter_top instantiation that consumes it).
  reg vs_r = 1'b0;

  wire fb_wr_en; wire [14:0] fb_wr_qw; wire [1:0] fb_wr_lane; wire [15:0] fb_wr_pix;
  wire fb_rd_en; wire [14:0] fb_rd_qw; wire [63:0] fb_rd_qword;
  comp_fbram fbram(.clk(clk_sys),
    .wr_en(fb_wr_en), .wr_qw(fb_wr_qw), .wr_lane(fb_wr_lane), .wr_pix(fb_wr_pix),
    .rd_en(fb_rd_en), .rd_qw(fb_rd_qw), .rd_qword(fb_rd_qword));

  blitter_top blt (
    .clk(clk_sys), .rst(reset),
    .mem_addr(bt_addr), .mem_rd(bt_rd), .mem_wr(bt_wr), .mem_burstcnt(bt_burstcnt),
    .mem_din(bt_din), .mem_be(bt_be),
    .mem_dout(blt_demux_dout), .mem_dout_ready(blt_demux_dready), .mem_busy(blt_busy_w),
    // [bugfix, 2026-07-26] blitter_top's OWN post-command FSM (S_FRAME_VCTRL ->
    // S_SNAP_WAIT -> S_SNAP_BUSY -> S_SNAP_DRAIN -> back to S_POLL_SUBMIT) gates on
    // its `vs` INPUT (scanout vblank), completely separate from the cache's `vs`
    // coherency pulse below. Leaving it unconnected (as the single-submission
    // siblings tb_blitter_trilist_pipe/uvfull/tb_stage_psrc harmlessly do — they
    // never poll a SECOND submission so they never notice blt wedges in
    // S_SNAP_WAIT=42 forever afterward) is fatal HERE: this bench submits STAGE
    // then TRILIST, and blt never returns to S_POLL_SUBMIT to see submission 2
    // without a vs pulse. Reusing vs_r (below) for both jobs is safe: by the time
    // it fires, phase 1's STAGE has already completed (done_seq==1 observed).
    .vs(vs_r), .fb_dma_busy(1'b0),   // no comp_fb_dma model in this bench; SNAP_GUARD bounds it
    .p0_addr(p0_addr), .p0_rd(p0_rd), .p0_dout(p0_dout), .p0_ok(p0_ok),
    .src_sdram_we(bs_we), .src_sdram_din(bs_din), .src_sdram_waddr(bs_waddr),
    .src_sdram_we_burst(bs_we_burst), .src_sdram_din64(bs_din64),
    .src_sdram_ok(stage_ok),
    .stage_barrier(blt_stage_barrier), .stage_barrier_busy(blt_stage_busy),
    .fb_wr_en(fb_wr_en), .fb_wr_qw(fb_wr_qw), .fb_wr_lane(fb_wr_lane), .fb_wr_pix(fb_wr_pix),
    .fb_rd_en(fb_rd_en), .fb_rd_qw(fb_rd_qw), .fb_rd_qword(fb_rd_qword),
    .idle(bt_idle), .dbg(blt_dbg));

  wire [26:0] dst_addr; wire dst_rd, dst_wr;
  wire [63:0] dst_din;  wire [7:0] dst_wdsn;
  wire [63:0] dst_dout; wire dst_ok;
  wire [7:0] d_burst; wire [28:0] d_addr; wire d_rd; wire [63:0] d_din;
  wire [7:0] d_be;    wire d_we;
  wire       d_busy;  reg d_dready = 0; reg [63:0] d_dout = 0;

  vram_demux vdemux (
    .clk(clk_sys), .reset(reset),
    .blt_addr(bt_addr), .blt_rd(bt_rd), .blt_wr(bt_wr), .blt_din(bt_din), .blt_be(bt_be),
    .blt_burstcnt(bt_burstcnt),
    .blt_dout(blt_demux_dout), .blt_dout_ready(blt_demux_dready), .blt_busy(blt_busy_w),
    .ddr_addr(bd_addr), .ddr_rd(bd_rd), .ddr_wr(bd_wr), .ddr_din(bd_din), .ddr_be(bd_be),
    .ddr_dout(d_dout), .ddr_dout_ready(d_dready & b_grant), .ddr_busy(blt_arb_busy),
    .sd_addr(dst_addr), .sd_rd(dst_rd), .sd_wr(dst_wr),
    .sd_din(dst_din), .sd_wdsn(dst_wdsn), .sd_dout(dst_dout), .sd_ok(dst_ok),
    .dbg(vdemux_dbg));

  ddr_blitter_arb #(.ENABLE(1'b1)) arb_ddr (
    .clk(clk_sys), .reset(reset),
    .rdr_burstcnt(8'd0), .rdr_addr(29'd0), .rdr_rd(1'b0), .rdr_din(64'd0),
    .rdr_be(8'd0), .rdr_we(1'b0), .rdr_busy(), .rdr_grant(),
    .blt_burstcnt(bt_burstcnt), .blt_addr(bd_addr), .blt_rd(bd_rd), .blt_din(bd_din),
    .blt_be(bd_be), .blt_we(bd_wr), .blt_busy(blt_arb_busy), .blt_grant(b_grant),
    .ddram_busy(d_busy), .ddram_dout_ready(d_dready),
    .ddram_burstcnt(d_burst), .ddram_addr(d_addr), .ddram_rd(d_rd),
    .ddram_din(d_din), .ddram_be(d_be), .ddram_we(d_we), .dbg());

  // ---- SDRAM cache: real ch1 (STAGE write-back) + real ch5 (P_SRC, driven by
  // the blitter's own p0_* now) + vs coherency pulse ----
  wire        coh_busy;   // vs_r declared earlier (feeds both blt.vs and this cache's vs)
  wire [15:0] SDQ; wire [12:0] SA; wire SDQML, SDQMH; wire [1:0] SBA;
  wire        SnCS, SnWE, SnRAS, SnCAS, SCKE, cache_sdram_clk;
  wire        sdram_init;   // high while the SDRAM controller runs power-up init

  sdram_fb_cache fbcache (
    .clk(clk_sys), .clk_sdram(clk_sys), .rst(reset), .init(sdram_init),
    .dst_addr(dst_addr), .dst_rd(dst_rd), .dst_wr(dst_wr),
    .dst_din(dst_din), .dst_wdsn(dst_wdsn), .dst_dout(dst_dout), .dst_ok(dst_ok),
    .scan_addr(27'd0), .scan_rd(1'b0), .scan_dout(), .scan_ok(),
    .p0_addr(p0_addr), .p0_rd(p0_rd), .p0_dout(p0_dout), .p0_ok(p0_ok),
    // STAGE (ch1) write channel <- blitter src_sdram burst-write outputs.
    .stage_addr(bs_waddr), .stage_wr(bs_we_burst), .stage_din(bs_din64),
    .stage_wdsn(8'h00), .stage_ok(stage_ok),
    .vs(vs_r), .coh_busy(coh_busy),
    .stage_barrier(blt_stage_barrier), .stage_busy(blt_stage_busy),
    .dst_barrier(1'b0), .dst_busy(),       // no carry-forward in this bench
    .sdram_dq(SDQ), .sdram_a(SA), .sdram_dqml(SDQML), .sdram_dqmh(SDQMH),
    .sdram_ba(SBA), .sdram_nwe(SnWE), .sdram_ncas(SnCAS), .sdram_nras(SnRAS),
    .sdram_ncs(SnCS), .sdram_cke(SCKE), .sdram_clk(cache_sdram_clk));

  mt48lc16m16a2 #(.addr_bits(13), .col_bits(10)) schip (
    .Dq(SDQ), .Addr(SA), .Ba(SBA), .Clk(clk_sdram), .Cke(SCKE),
    .Cs_n(SnCS), .Ras_n(SnRAS), .Cas_n(SnCAS), .We_n(SnWE), .Dqm({SDQMH, SDQML}),
    .downloading(1'b0), .VS(1'b0), .frame_cnt(32'd0));

  // ---- behavioral DDR3 (serves the blitter control/ring + STAGE source reads) ----
  reg [63:0] mem [0:MEMQW-1];
  reg [1:0] bp=0; always @(posedge clk_sys) bp <= (bp==2'd2)?2'd0:bp+2'd1;
  integer i;
  reg [7:0] rbeats; reg [28:0] raddr; reg [2:0] rlat;
  assign d_busy = (bp != 2'd2) | (rbeats != 8'd0) | (rlat != 3'd0);
  always @(posedge clk_sys) begin
    d_dready <= 1'b0;
    if (reset) begin rbeats<=0; rlat<=0; end
    else begin
      if (rlat != 3'd0) rlat <= rlat - 3'd1;
      else if (rbeats != 8'd0) begin
        if (bp == 2'd2) begin
          d_dout <= mem[raddr-WBASE]; d_dready <= 1'b1;
          raddr <= raddr + 29'd1; rbeats <= rbeats - 8'd1;
        end
      end else if (!d_busy) begin
        if (d_rd) begin rbeats <= d_burst; raddr <= d_addr; rlat <= 3'd3; end
        else if (d_we) for(i=0;i<8;i=i+1) if(d_be[i]) mem[(d_addr-WBASE)][i*8 +:8]<=d_din[i*8 +:8];
      end
    end
  end

  task wmem(input [31:0] idx, input [63:0] val); mem[idx]=val; endtask
  wire [31:0] done_seq = mem[32'h200005][31:0];

  // ring qwords saved at time 0, BEFORE phase 1's submit_stage stomps @0x200008+.
  reg [63:0] ring_save [0:7];

  // submit phase-1 BLT_OP_STAGE: DDR3 SRC_QW+STAGE_OFF -> SDRAM STAGE_OFF (same-off).
  task submit_stage;
    begin
      wmem(32'h200002, 64'd0);           // target
      wmem(32'h200004, 64'd0);           // flags: no CLEAR
      wmem(32'h200007, 64'd1);           // C_SRCSEL
      wmem(32'h200001, 64'd2);           // STAGE + END
      // STAGE flags=0 (same-offset): u32[0]=op4, u32[1]=src_off=STAGE_OFF.
      wmem(32'h200008, {32'(STAGE_OFF), 32'h0000_0004});
      // qw1: u32[2]=src_stride|src_x<<16 (unused, 0); u32[3]=w|h<<16=size bytes.
      // VERIFIED against blitter_top.sv S_DECODE: c_w=cmd_qw[1][47:32] (u32[3] low
      // 16b), c_h=cmd_qw[1][63:48] (u32[3] high 16b), stage_size<={c_h,c_w}. So
      // u32[3] (the HIGH 32 bits of this qword) must carry STAGE_BYTES, and u32[2]
      // (LOW 32 bits) is the unused src_stride/src_x word — the opposite order from
      // a naive reading of tb_stage_psrc's F_STAGE_DST comment, which packs
      // {size(high), dest_off(low)} the same way. STAGE_BYTES=32768 < 0x1_0000 so
      // it fits entirely in c_w with c_h=0.
      wmem(32'h200009, {32'(STAGE_BYTES), 32'd0});
      wmem(32'h20000A, 64'd0); wmem(32'h20000B, 64'd0);
      wmem(32'h20000C, 64'd1);           // END
      wmem(32'h20000D, 64'd0); wmem(32'h20000E, 64'd0); wmem(32'h20000F, 64'd0);
      wmem(32'h200000, 64'd1);           // submit seq 1
    end
  endtask

  // ---- golden framebuffer (`FB_PIXELS RGB565 pixels, index = y*`FB_W+x) ----
  reg [15:0] exp [0:`FB_PIXELS-1];

  integer x,y,idx,bad,ncov;
  reg [15:0] got, e;
  // +-1 LSB per RGB565 channel
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
    for (i=0;i<MEMQW;i=i+1) mem[i]=64'd0;
    $readmemh("vectors/tri_uvfull_ddr.hex", mem);
    $readmemh("vectors/tri_uvfull_exp.hex", exp);
    for (i=0;i<8;i=i+1) ring_save[i] = mem[32'h200008+i];
  end

  integer settle;
  initial begin
    repeat (16) @(posedge clk_sys); reset = 1'b0; repeat (8) @(posedge clk_sys);

    // wait for SDRAM controller power-up init before any SDRAM access
    settle=0;
    while (sdram_init) begin @(posedge clk_sys); settle=settle+1;
      if (settle>2_000_000) begin $display("RESULT: FAIL - SDRAM init never completed"); $finish; end end
    $display("SDRAM init done after %0d cyc", settle);

    // ---- phase 1: STAGE the tri_uvfull texture DDR3 -> SDRAM ----
    submit_stage;
    settle=0;
    while (done_seq !== 32'd1 && settle < 20_000_000) begin @(posedge clk_sys); settle=settle+1; end
    if (done_seq !== 32'd1) begin $display("RESULT: FAIL - STAGE never completed (blt.state=%0d)", blt.state); $finish; end
    $display("PHASE1 STAGE completed in %0d cyc", settle);

    // coherency: flush ch1 to SDRAM + invalidate ch5 (P_SRC) so the TRILIST texel
    // walk re-reads the freshly staged data (mirrors tb_stage_psrc.sv:224-226). This
    // SAME pulse also feeds blt.vs (see the blitter_top instance comment above) —
    // give blt a little margin to settle into S_SNAP_WAIT after its done_seq==1
    // write before asserting, and hold the pulse generously so the vs_sync 3-FF
    // edge detector cannot miss it.
    repeat (32) @(posedge clk_sys);
    @(posedge clk_sys); #1; vs_r=1'b1; repeat(8) @(posedge clk_sys); #1; vs_r=1'b0;
    settle=0; while (coh_busy) begin @(posedge clk_sys); settle=settle+1;
      if (settle>2_000_000) begin $display("RESULT: FAIL - coh_busy stuck"); $finish; end end
    $display("PHASE1 coherency flush+invalidate done in %0d cyc", settle);

    // let blt finish draining S_SNAP_WAIT->BUSY->DRAIN->POLL_SUBMIT (bounded by
    // SNAP_GUARD; no comp_fb_dma model here) before checking/submitting phase 2.
    settle=0; while (blt.state != 6'd0 /* S_POLL_SUBMIT */ && settle < 100_000) begin
      @(posedge clk_sys); settle=settle+1; end
    if (blt.state != 6'd0) begin
      $display("RESULT: FAIL - blt never returned to S_POLL_SUBMIT after phase 1 (state=%0d)", blt.state);
      $finish;
    end
    $display("blt back at S_POLL_SUBMIT after %0d cyc (post-STAGE snapshot drain)", settle);

    // ---- phase 2: restore the hex's original ring + submit the TRILIST frame ----
    for (i=0;i<8;i=i+1) wmem(32'h200008+i, ring_save[i]);
    wmem(32'h200001, 64'd2);      // TRILIST + END
    wmem(32'h200004, 64'd1);      // FLAGS bit0 = CLEAR before list
    wmem(32'h200003, 64'h001f);   // clear color blue (matches golden)
    wmem(32'h200000, 64'd2);      // submit seq 2

    settle=0;
    while (done_seq !== 32'd2 && settle < 40_000_000) begin
      @(posedge clk_sys); settle=settle+1;
      // [debug heartbeat, 2026-07-26] this bench co-simulates the real cache/SDRAM
      // and can be VERY slow under Icarus; print progress every 100k cycles so a
      // long-running instance is distinguishable from a hang.
      if (settle % 100_000 == 0)
        $display("  ...settle=%0d blt.state=%0d tri_busy=%0d tri_idx=%0d tri_count=%0d p0_rd=%0d p0_ok=%0d coh_busy=%0d",
                 settle, blt.state, blt.tri_busy, blt.tri_idx, blt.tri_count, p0_rd, p0_ok, coh_busy);
    end
    if (done_seq !== 32'd2) begin $display("RESULT: FAIL - TRILIST never completed (blt.state=%0d)", blt.state); $finish; end
    $display("PHASE2 TRILIST completed in %0d cyc", settle);

    // [profiling] same perf-counter line as the sibling benches, for cross-bench diff.
    ncov=0;
    for (y=0;y<`FB_H;y=y+1) for (x=0;x<`FB_W;x=x+1) if (exp[y*`FB_W+x]!==exp[0]) ncov=ncov+1;
    $display("=== PERF tri=%0d texwait=%0d dpath=%0d covered_px=%0d | dpath_cyc/px=%0d ===",
             blt.perf_tri_cyc, blt.perf_texwait_cyc, blt.perf_tri_cyc-blt.perf_texwait_cyc,
             ncov, (ncov>0)?((blt.perf_tri_cyc-blt.perf_texwait_cyc)/ncov):0);

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
      if (e === 16'hxxxx) begin
        bad=bad+1;
        if (bad<=1000) $display("  GOLDEN SHORT at (%0d,%0d) — vectors not regenerated for this canvas?", x,y);
      end
      else if (!chan_ok(got,e)) begin
        bad=bad+1;
        if (bad<=1000) $display("  MISMATCH (%0d,%0d): got %04h exp %04h", x,y,got,e);
      end
    end
    $display("=== bad pixels = %0d / %0d ===", bad, `FB_PIXELS);
    if (bad==0) $display("RESULT: PASS");
    else        $display("RESULT: FAIL (bad=%0d)", bad);
    $finish;
  end

  // global watchdog backstop (this bench co-simulates the real SDRAM chip model
  // and may legitimately be slower than the pure-BRAM siblings).
  initial begin
    #900_000_000;
    $display("RESULT: FAIL - global timeout (done=%0d)", done_seq);
    $finish;
  end
endmodule
`default_nettype wire
