// tb_tri_mixer_equiv.sv — comp_mixer vs blt_blend equivalence SPIKE (Task 6, Milestone 2).
//
// This is a DATA-GATHERING spike, not a correctness gate for either module: it asks
// "if blt_tri's blend (blt_blend.sv) were collapsed onto the pipelined compositor's
// mixer (comp_mixer.sv), would the four production blend paths still agree?" and
// records the answer. It does NOT change blt_blend or comp_mixer.
//
// blt_blend takes a pre-tinted-source contract: it applies its own per-channel tint
// (cr/cg/cb) and combines per-vertex alpha `ca` with the global `g_alpha` as
// ea=(ca*g_alpha)/255 before blending. comp_mixer has no tint stage and blends
// in_src directly against in_alpha. To compare the shared blend ARITHMETIC (not the
// tint front-end, which comp_mixer simply doesn't have), this spike drives blt_blend
// with an IDENTITY tint (cr=cg=cb=8'd255, which modch() reduces to the input
// channel unchanged) and g_alpha=8'd255 (so ea=ca exactly, no truncation: ca*255 is
// always an exact multiple of 255). Under that setup texel==tinted-src, so both DUTs
// see the same effective (src,dst,mode,key,alpha) tuple and their raw blend math is
// directly comparable.
//
// Mode encodings are numerically identical between blt_blend's BM_* and comp_mixer's
// `COMP_* (both mirror blitter_ref.h: COPY=0, KEY=1, CALPHA/CA=2, ADD=4), so the same
// 8-bit in_mode/blend_mode value drives both DUTs.
//
// comp_mixer is a registered LAT=3 pipeline; blt_blend is purely combinational. The
// FIFO-checker pattern below (same shape as tb_comp_mixer.sv) makes the comparison
// latency-agnostic: a "golden" queue entry is pushed once per driven vector, sampling
// blt_blend's (by-then-settled) output for the PREVIOUS cycle's vector, and popped in
// order whenever comp_mixer.out_valid fires — so it works regardless of LAT.
`timescale 1ns/1ps
`default_nettype none
`include "comp_defs.vh"
module tb_tri_mixer_equiv;
  reg clk=0; always #5 clk=~clk;

  // ── DUT 1: comp_mixer (registered, LAT=3) ────────────────────────────────────
  reg         in_valid=0;
  reg  [15:0] in_src, in_dst, in_key;
  reg  [7:0]  in_mode, in_alpha;
  wire        out_valid, out_we;
  wire [15:0] out_pix;
  comp_mixer dut_mixer(.clk(clk), .in_valid(in_valid), .in_src(in_src), .in_dst(in_dst),
    .in_mode(in_mode), .in_fmt(`COMP_RGB565), .in_key(in_key), .in_alpha(in_alpha),
    .out_valid(out_valid), .out_pix(out_pix), .out_we(out_we));

  // ── DUT 2: blt_blend (combinational) — identity tint, g_alpha=255 -> ea=ca ──
  wire        blend_we;
  wire [15:0] blend_pix;
  blt_blend dut_blend(.texel(in_src), .dst(in_dst),
    .cr(8'd255), .cg(8'd255), .cb(8'd255), .ca(in_alpha), .g_alpha(8'd255),
    .blend_mode(in_mode), .colorkey(in_key),
    .write_en(blend_we), .out_pix(blend_pix));

  // ±1 LSB per RGB565 channel (same tolerance contract as the trilist pipe TBs).
  function integer chan_ok(input [15:0] a, input [15:0] b);
    integer dr,dg,db;
    begin
      dr = a[15:11] - b[15:11]; if (dr<0) dr=-dr;
      dg = a[10:5]  - b[10:5];  if (dg<0) dg=-dg;
      db = a[4:0]   - b[4:0];   if (db<0) db=-db;
      chan_ok = (dr<=1) && (dg<=1) && (db<=1);
    end
  endfunction

  // ── golden FIFO: {mode(8), we(1), pix(16)} sampled from blt_blend, order-matched
  // to comp_mixer's in_valid stream (see file header for why this is latency-agnostic).
  reg [24:0] q [0:31];
  integer qh=0, qt=0;

  localparam NV = 256;
  reg [7:0]  v_mode [0:NV-1];
  reg [15:0] v_src  [0:NV-1];
  reg [15:0] v_dst  [0:NV-1];
  reg [15:0] v_key  [0:NV-1];
  reg [7:0]  v_alpha[0:NV-1];

  // per-mode bookkeeping for the report (which of COPY/KEY/CALPHA/ADD, if any, diverges)
  integer cnt_copy=0, cnt_key=0, cnt_calpha=0, cnt_add=0;
  integer err_copy=0, err_key=0, err_calpha=0, err_add=0;

  integer i, seed;
  initial begin
    seed = 32'hC0FFEE;
    for (i=0;i<NV;i=i+1) begin
      case (i % 4)
        0: v_mode[i] = `COMP_COPY;
        1: v_mode[i] = `COMP_KEY;
        2: v_mode[i] = `COMP_CA;
        default: v_mode[i] = `COMP_ADD;
      endcase
      v_src[i]   = $random(seed);
      v_dst[i]   = $random(seed);
      v_alpha[i] = $random(seed);
      // KEY-mode coverage: every other KEY vector keys the exact src (cull path),
      // the rest use a random (almost-certainly non-matching) key (bypass path).
      if (v_mode[i]==`COMP_KEY && (i[3]==1'b0)) v_key[i] = v_src[i];
      else                                       v_key[i] = $random(seed);
    end
  end

  task drive; input [7:0] mode; input [15:0] s,d,key; input [7:0] alpha; begin
    in_valid<=1; in_mode<=mode; in_src<=s; in_dst<=d; in_key<=key; in_alpha<=alpha;
  end endtask

  // Push the golden entry for the vector that was applied on the PREVIOUS negedge
  // (blt_blend has now settled to reflect it), then drive the next vector.
  integer errs=0; integer ndrv=0;
  initial begin
    @(negedge clk); // t0, in_valid still 0
    for (i=0;i<NV;i=i+1) begin
      if (i>0) begin
        q[qt] <= {v_mode[i-1], blend_we, blend_pix}; qt <= (qt+1)%32;
      end
      drive(v_mode[i], v_src[i], v_dst[i], v_key[i], v_alpha[i]);
      ndrv = ndrv+1;
      @(negedge clk);
    end
    // push the last vector's (now-settled) golden entry
    q[qt] <= {v_mode[NV-1], blend_we, blend_pix}; qt <= (qt+1)%32;
    in_valid<=0;
    // drain: let comp_mixer's pipeline flush all in-flight pixels through the checker
    for (i=0;i<8;i=i+1) @(negedge clk);

    if (qh!==qt) begin
      errs=errs+1;
      $display("DEADLOCK: %0d driven, %0d golden entries never popped (qh=%0d qt=%0d)", ndrv, ((qt-qh+32)%32), qh, qt);
    end

    $display("=== per-mode: COPY %0d/%0d  KEY %0d/%0d  CALPHA %0d/%0d  ADD %0d/%0d (errs/total) ===",
              err_copy,cnt_copy, err_key,cnt_key, err_calpha,cnt_calpha, err_add,cnt_add);
    if (errs==0) $display("RESULT: PASS");
    else         $display("RESULT: FAIL errs=%0d", errs);
    $finish;
  end

  // Continuous output checker: every comp_mixer pixel (out_valid=1) is compared,
  // in FIFO order, to blt_blend's recorded output for the same driven vector.
  reg [24:0] g;
  reg [7:0]  g_mode;
  reg        g_we;
  reg [15:0] g_pix;
  always @(negedge clk) begin
    if (out_valid) begin
      g = q[qh]; qh <= (qh+1)%32;
      g_mode = g[24:17]; g_we = g[16]; g_pix = g[15:0];
      case (g_mode)
        `COMP_COPY: cnt_copy   = cnt_copy+1;
        `COMP_KEY:  cnt_key    = cnt_key+1;
        `COMP_CA:   cnt_calpha = cnt_calpha+1;
        `COMP_ADD:  cnt_add    = cnt_add+1;
        default: ;
      endcase
      if (out_we !== g_we || (g_we && !chan_ok(out_pix, g_pix))) begin
        errs = errs+1;
        case (g_mode)
          `COMP_COPY: err_copy   = err_copy+1;
          `COMP_KEY:  err_key    = err_key+1;
          `COMP_CA:   err_calpha = err_calpha+1;
          `COMP_ADD:  err_add    = err_add+1;
          default: ;
        endcase
        if (errs<=20) $display("MISMATCH mode=%0d we=%b/%b pix=%h/%h", g_mode, out_we, g_we, out_pix, g_pix);
      end
    end
  end
  // hard watchdog backstop
  initial begin #2000000 $display("RESULT: FAIL (timeout)"); $finish; end
endmodule
`default_nettype wire
