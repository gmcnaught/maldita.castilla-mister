// tb_video_timing_vfull.sv — openbor_video_timing's OSD Vertical Lines mode (224 / 240).
//
// Checks, per frame (a frame = vcount 0 .. V_TOTAL-1):
//   (a) active lines == `DISP_H in 224 mode and `FB_H in 240 mode; total lines == 262 always.
//   (b) vsync stays put relative to the picture CENTRE: the 240 window adds
//       (`FB_H-`DISP_H)/2 lines on each side, so vsync starts (`FB_H-`DISP_H)/2 lines later
//       in vcount terms (vcount 0 moves up by the same amount) and lasts 3 lines.
//   (c) a mode switch never lands mid-frame: every frame is scanned entirely in one mode,
//       and the switch takes effect at the first frame boundary after the end of active
//       video that sampled it.
//   (d) v_full_next only changes at the end of active video (vblank start), so it is
//       stable for the whole vblank the reader re-arms in.
//   (e) vsync never asserts inside active video, for every OSD v_adj.
// Copyright (C) 2026 — GPL-3.0
`default_nettype none
`timescale 1ns/1ps
`include "blitter_defs.vh"
module tb_video_timing_vfull;
    localparam integer V_TOTAL = 262;
    localparam integer EXTRA   = (`FB_H - `DISP_H) / 2;

    reg clk = 1'b0; always #5 clk = ~clk;
    reg reset = 1'b1;
    reg v_full = 1'b0;
    reg signed [3:0] v_adj = 4'sd0;

    wire hs, vs, hb, vb, de, nf, nl, vfn;
    wire [9:0] hc;
    wire [8:0] vc;
    openbor_video_timing dut (
        .clk(clk), .ce_pix(1'b1), .reset(reset),
        .h_adj(5'sd0), .v_adj(v_adj),
        .hsync(hs), .vsync(vs), .hblank(hb), .vblank(vb), .de(de),
        .hcount(hc), .vcount(vc), .new_frame(nf), .new_line(nl),
        .v_full(v_full), .v_full_next(vfn)
    );

    integer errs = 0;
    integer frames = 0;

    // Per-frame measurements, taken once per line at hcount == 0.
    integer lines, act_lines, vs_start, vs_len, vs_in_active;
    reg     mode_seen, mode_mixed;
    reg     prev_vfn;
    reg     in_frame = 1'b0;

    // Expected mode of each frame, from what v_full_next held at that frame's start.
    reg     exp_mode;

    task end_frame;
        integer want_act, want_vs;
        begin
            want_act = exp_mode ? `FB_H : `DISP_H;
            // same absolute line: 240 mode's vcount 0 is EXTRA lines earlier
            want_vs  = (exp_mode ? (`FB_H + 11 - EXTRA) : (`DISP_H + 11)) + v_adj;
            if (want_vs < want_act) want_vs = want_act;   // the RTL's floor at V_ACTIVE
            if (lines != V_TOTAL) begin
                errs = errs + 1; $display("  frame %0d: %0d lines, want %0d", frames, lines, V_TOTAL);
            end
            if (act_lines != want_act) begin
                errs = errs + 1; $display("  frame %0d (mode %0d): %0d active lines, want %0d",
                                          frames, exp_mode, act_lines, want_act);
            end
            if (mode_mixed) begin
                errs = errs + 1; $display("  frame %0d: active-line count changed mid-frame", frames);
            end
            if (vs_start != want_vs || vs_len != 3) begin
                errs = errs + 1; $display("  frame %0d (mode %0d adj %0d): vsync at %0d len %0d, want %0d len 3",
                                          frames, exp_mode, v_adj, vs_start, vs_len, want_vs);
            end
            if (vs_in_active) begin
                errs = errs + 1; $display("  frame %0d: vsync inside active video", frames);
            end
            frames = frames + 1;
        end
    endtask

    always @(posedge clk) if (!reset && hc == 10'd0) begin
        if (vc == 9'd0) begin
            if (in_frame) end_frame();
            in_frame     = 1'b1;
            exp_mode     = dut.v_full_cur;
            lines = 0; act_lines = 0; vs_start = -1; vs_len = 0; vs_in_active = 0;
            mode_mixed = 1'b0; mode_seen = dut.v_full_cur;
        end
        if (in_frame) begin
            lines = lines + 1;
            if (!vb) act_lines = act_lines + 1;
            if (!vs) begin
                if (vs_start < 0) vs_start = vc;
                vs_len = vs_len + 1;
                if (!vb) vs_in_active = 1;
            end
            if (dut.v_full_cur !== mode_seen) mode_mixed = 1'b1;
        end
    end

    // (d) v_full_next changes only on the clock that raises vblank (end of active video).
    always @(posedge clk) if (!reset) begin
        if (vfn !== prev_vfn && !(hc == 10'd0 && vb && dut.vcount == (dut.v_full_cur ? `FB_H : `DISP_H))) begin
            errs = errs + 1;
            $display("  v_full_next changed at vcount %0d hcount %0d (want only at the start of vblank)", vc, hc);
        end
        prev_vfn <= vfn;
    end

    task wait_frames(input integer n);
        integer target;
        begin
            target = frames + n;
            while (frames < target) @(posedge clk);
        end
    endtask

    integer a;
    initial begin
        prev_vfn = 1'b0;
        repeat (4) @(posedge clk);
        reset = 1'b0;

        // 224 mode, then 240, then back; switch requests land mid-frame on purpose.
        wait_frames(3);
        repeat (420 * 100) @(posedge clk);   // middle of active video
        v_full = 1'b1;
        wait_frames(4);
        repeat (420 * 250) @(posedge clk);   // inside vblank: must wait a whole frame
        v_full = 1'b0;
        wait_frames(4);

        // (e) every OSD vertical offset, both modes.
        for (a = -3; a <= 3; a = a + 1) begin
            v_adj = a[3:0];
            v_full = 1'b1; wait_frames(3);
            v_full = 1'b0; wait_frames(3);
        end

        if (frames < 40) begin
            $display("RESULT: FAIL — only %0d frames checked", frames);
        end else if (errs) begin
            $display("RESULT: FAIL — %0d error(s) over %0d frames", errs, frames);
        end else begin
            $display("RESULT: PASS — %0d frames, both Vertical Lines modes, v_adj -3..+3", frames);
        end
        $finish;
    end

    initial begin #2_000_000_000 $display("RESULT: FAIL — TIMEOUT"); $finish; end
endmodule
