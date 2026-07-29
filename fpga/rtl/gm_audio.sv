//
//  gm_audio -- native-rate audio consumer for the gmloader DDR3 ring
//
//  Structurally MiSTer's sys/alsa.sv, with three deliberate differences:
//
//    1. alsa.sv gets buf_addr/buf_len/buf_wptr free over SPI from Main_MiSTer.
//       Nothing on the HPS side plays that role here -- gmloader writes the ring
//       from userspace -- so the write pointer is POLLED over this module's own
//       DDR channel. Base and length are compile-time constants, so wr_ptr is
//       the only thing that moves.
//
//    2. alsa.sv pops one frame per ce_sample and hands it straight to
//       audio_out. The ring here carries the game's NATIVE rate (SRC_RATE,
//       22.05 kHz for the GameMaker runner), so this module resamples to the
//       48 kHz output with a fractional phase accumulator and linear
//       interpolation. Zero-order hold would put images from SRC_RATE/2 upward,
//       and aud_mix_top sums the alsa port UNFILTERED (sys/audio_out.v:225-250)
//       -- which is also why pcm_l/pcm_r must drive audio_out's core_l/core_r,
//       not its alsa_l/alsa_r.
//
//    3. alsa.sv's hurryup only ever ramps the consumer FASTER. The slew here is
//       symmetric, because the producer is a userspace pump rather than the
//       kernel's ALSA engine and can fall behind as easily as it runs ahead.
//
//  The phase accumulator does double duty: it is both the interpolator's
//  position and the rate-matching loop. `slew` adds to the increment, which is
//  exactly alsa.sv's closed loop expressed in the resampler's units. Because
//  the consumer tracks the producer's real long-run rate, the drift that the
//  old fixed-48-kHz drain accumulated cannot build up here.
//
//  Runs entirely in clk_audio. No clock crossing, no dcfifo.
//
//  Declaration order in this file is dependency order, not narrative order:
//  Icarus in -g2012 mode rejects use-before-declaration for nets.
//
//  Copyright (C) 2026 -- GPL-3.0
//

`default_nettype none

module gm_audio #(
    // clk_audio, and the fixed 48 kHz output tick derived from it.
    parameter int    CLK_RATE   = 24576000,
    parameter int    OUT_RATE   = 48000,
    // Native rate of the PCM in the ring. Must match the host's NA_SAMPLE_RATE
    // (gmloader native_audio_writer.h).
    parameter int    SRC_RATE   = 22050,

    // Absolute qword addresses. These are byte>>3 and are NOT relative to any
    // framebuffer base -- see the [audio-map] note in openbor_video_reader.sv.
    parameter [31:3] RING_QW    = 29'h0741A000,  // byte 0x3A0D0000
    parameter [31:3] WPTR_QW    = 29'h07400006,  // byte 0x3A000030

    // Ring size in qwords. 64 KiB / 8 = 8192 -> 13-bit pointers.
    parameter int    RING_QWORDS = 8192,

    // Ring occupancy the host pump aims to hold, in qwords. The slew loop pulls
    // the measured trough toward this. Must track kTargetFillFrames/2 in
    // gmloader's mister_native_audio.cpp.
    parameter int    TARGET_QW   = 1102,

    // Slew-loop tuning. Defaults are the device values; the testbench shortens
    // them so the closed loop can be exercised in tractable simulated time.
    //   POLL_TICKS -- output ticks between wr_ptr polls (512 ~= 10.7 ms)
    //   WIN_TICKS  -- output ticks per fill-minimum window (8192 ~= 170 ms)
    //   BAND_QW    -- width of the innermost slew band, in qwords
    //   SLEW_STEP  -- phase-increment units per slew step (16 -> 0.053% each)
    parameter int    POLL_TICKS  = 512,
    parameter int    WIN_TICKS   = 8192,
    parameter int    BAND_QW     = 128,
    parameter int    SLEW_STEP   = 16
) (
    input  wire        reset,
    input  wire        clk,           // clk_audio, 24.576 MHz

    // ddr_svc channel (burst of 1). ram_req is a TOGGLE, ram_ready a pulse.
    output reg  [31:3] ram_address,
    input  wire [63:0] ram_data,
    output reg         ram_req,
    input  wire        ram_ready,

    output reg  [15:0] pcm_l,
    output reg  [15:0] pcm_r
);

localparam int PW   = $clog2(RING_QWORDS);          // 13
localparam int PMAX = RING_QWORDS - 1;

// Phase increment, 1.0 == 65536. round(65536 * 22050/48000) = 30106.
// The 0.4-LSB rounding error is +6.1e-6 relative (~0.13 Hz at 22050), an order
// of magnitude below one slew step, and the loop absorbs it regardless.
localparam int INC_NOM = (65536 * SRC_RATE + OUT_RATE/2) / OUT_RATE;
localparam signed [17:0] INC_BASE = INC_NOM;

// Output tick divider: 24576000 / 48000 = 512, exact.
localparam int OUT_DIV = CLK_RATE / OUT_RATE;

// Staging: 4 qwords = 8 stereo frames. alsa.sv gets by with a single qword;
// the extra depth covers ddr_svc arbitration against ch1 without ever stalling
// a sample tick.
localparam int ST_DEPTH = 4;

localparam logic S_IDLE = 1'b0,
                 S_WAIT = 1'b1;

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------
reg [1:0] rst_sync;

reg [$clog2(OUT_DIV)-1:0] out_div;
reg                       out_ce;

reg [PW-1:0] rptr;              // qword index we will fetch next
reg [PW-1:0] wptr;              // qword index the host has filled up to
reg          got_first;         // dropped the stale ring contents yet?

reg [63:0] stage [ST_DEPTH];
reg  [1:0] st_wr, st_rd;
reg  [2:0] st_cnt;
reg        st_half;             // which stereo frame of stage[st_rd]

reg  state;
reg  is_poll;                   // what the in-flight request is for
reg  poll_ack;                  // clears poll_due when the poll is issued
reg  poll_due;
reg [$clog2(POLL_TICKS)-1:0] poll_div;

reg [PW-1:0]                fill_min;
reg [PW-1:0]                fill_acc;
reg [$clog2(WIN_TICKS)-1:0] win_cnt;

reg signed [3:0] slew;

reg [15:0] phase;
reg [15:0] s0_l, s0_r, s1_l, s1_r;
reg  [1:0] prime;               // frames loaded into the window so far (0..2)

// ---------------------------------------------------------------------------
// Combinational, in dependency order
// ---------------------------------------------------------------------------
wire rst = rst_sync[1];

wire [PW-1:0] backlog = wptr - rptr;            // natural mod-RING_QWORDS

wire st_full  = (st_cnt == ST_DEPTH[2:0]);
wire st_empty = (st_cnt == 3'd0);
wire st_push  = (state == S_WAIT) && ram_ready && !is_poll;

// The frame the interpolator will pull next.
wire [63:0] st_q  = stage[st_rd];
wire [15:0] nxt_l = st_half ? st_q[47:32] : st_q[15:0];
wire [15:0] nxt_r = st_half ? st_q[63:48] : st_q[31:16];

wire want_data = !st_full && (backlog != '0) && got_first;

wire signed [17:0] inc = INC_BASE + slew * SLEW_STEP;

wire [16:0] phase_nxt = {1'b0, phase} + inc[16:0];
wire        step      = phase_nxt[16];          // crossed into the next frame
wire        primed    = (prime == 2'd2);

// One path pulls a source frame, whether priming the window or sliding it.
// Gating on !st_empty is what makes starvation a hold rather than a glitch.
wire frame_pull = out_ce && !st_empty && (!primed || step);

// Which staging slot that pull consumes: first half advances, second retires.
wire st_adv = frame_pull && !st_half;
wire st_pop = frame_pull &&  st_half;

// Linear interpolation. s1-s0 is 17-bit signed, phase is 16-bit unsigned;
// one 17x17 signed multiply per channel, ~40 ns of budget at 24.576 MHz.
// The result lies between s0 and s1, so it always fits back into 16 bits.
wire signed [16:0] d_l = $signed({s1_l[15], s1_l}) - $signed({s0_l[15], s0_l});
wire signed [16:0] d_r = $signed({s1_r[15], s1_r}) - $signed({s0_r[15], s0_r});
wire signed [33:0] m_l = d_l * $signed({1'b0, phase});
wire signed [33:0] m_r = d_r * $signed({1'b0, phase});
wire signed [16:0] o_l = $signed({s0_l[15], s0_l}) + m_l[32:16];
wire signed [16:0] o_r = $signed({s0_r[15], s0_r}) + m_r[32:16];

// ---------------------------------------------------------------------------
// Reset synchroniser -- `reset` arrives from other domains.
// ---------------------------------------------------------------------------
always @(posedge clk or posedge reset)
    if (reset) rst_sync <= 2'b11;
    else       rst_sync <= {rst_sync[0], 1'b0};

// ---------------------------------------------------------------------------
// 48 kHz output tick
// ---------------------------------------------------------------------------
always @(posedge clk) begin
    if (rst) begin
        out_div <= '0;
        out_ce  <= 1'b0;
    end
    else begin
        out_div <= out_div + 1'b1;
        out_ce  <= (out_div == '0);
    end
end

// ---------------------------------------------------------------------------
// Write-pointer poll cadence. Also forced before the first fetch, so a stale
// wptr can never be the thing that looks like starvation.
// ---------------------------------------------------------------------------
always @(posedge clk) begin
    if (rst) begin
        poll_div <= '0;
        poll_due <= 1'b1;
    end
    else begin
        if (out_ce) begin
            poll_div <= poll_div + 1'b1;
            if (poll_div == '0) poll_due <= 1'b1;
        end
        if (poll_ack) poll_due <= 1'b0;
    end
end

// ---------------------------------------------------------------------------
// DDR fetch FSM. Two jobs on one channel: refill staging, and refresh wptr.
// The poll wins ties -- a fetch issued against a stale wptr is the one thing
// that can read past what the host has actually written.
// ---------------------------------------------------------------------------
always @(posedge clk) begin
    poll_ack <= 1'b0;

    if (rst) begin
        state       <= S_IDLE;
        is_poll     <= 1'b0;
        ram_req     <= 1'b0;
        ram_address <= '0;
        rptr        <= '0;
        wptr        <= '0;
        got_first   <= 1'b0;
        st_wr       <= 2'd0;
        st_rd       <= 2'd0;
        st_cnt      <= 3'd0;
        st_half     <= 1'b0;
    end
    else begin
        case (state)
            S_IDLE:
                if (poll_due || !got_first) begin
                    ram_address <= WPTR_QW;
                    ram_req     <= ~ram_req;
                    is_poll     <= 1'b1;
                    poll_ack    <= 1'b1;
                    state       <= S_WAIT;
                end
                else if (want_data) begin
                    ram_address <= RING_QW + {{(29-PW){1'b0}}, rptr};
                    ram_req     <= ~ram_req;
                    is_poll     <= 1'b0;
                    state       <= S_WAIT;
                end

            S_WAIT:
                if (ram_ready) begin
                    if (is_poll) begin
                        // Host writes a BYTE offset into the ring; the low 3
                        // bits are always zero (it submits whole frames, and
                        // this FSM only ever consumes whole qwords).
                        wptr <= ram_data[3 +: PW];
                        // alsa.sv:113-117 -- on the first look, adopt the
                        // host's pointer rather than replaying stale ring
                        // contents from before this core came up.
                        if (!got_first) begin
                            rptr      <= ram_data[3 +: PW];
                            got_first <= 1'b1;
                        end
                    end
                    else begin
                        stage[st_wr] <= ram_data;
                        st_wr        <= st_wr + 1'b1;
                        rptr         <= (rptr == PMAX[PW-1:0]) ? '0 : rptr + 1'b1;
                    end
                    state <= S_IDLE;
                end
        endcase

        // st_cnt is written from both sides; resolve it in one place so a
        // simultaneous push and pop cannot lose or double-count an entry.
        case ({st_push, st_pop})
            2'b10:   st_cnt <= st_cnt + 1'b1;
            2'b01:   st_cnt <= st_cnt - 1'b1;
            default: ;   // 2'b11 nets out, 2'b00 idle
        endcase

        if (st_pop) begin
            st_rd   <= st_rd + 1'b1;
            st_half <= 1'b0;
        end
        else if (st_adv) begin
            st_half <= 1'b1;
        end
    end
end

// ---------------------------------------------------------------------------
// Fill measurement: the MINIMUM backlog over a ~170 ms window. The host pump
// tops the ring up in bursts, so the instantaneous backlog sawtooths; the
// trough is what actually predicts starvation, and taking a min over a window
// gives the slew loop its hysteresis for free.
// ---------------------------------------------------------------------------
always @(posedge clk) begin
    if (rst) begin
        fill_min <= TARGET_QW[PW-1:0];
        fill_acc <= '1;
        win_cnt  <= '0;
    end
    else if (out_ce) begin
        if (backlog < fill_acc) fill_acc <= backlog;
        win_cnt <= win_cnt + 1'b1;
        if (win_cnt == '0) begin
            fill_min <= fill_acc;
            fill_acc <= '1;
        end
    end
end

// Symmetric slew, +/-4 steps of SLEW_STEP -> +/-0.21% around INC_NOM at the
// defaults. Bands are +/-1x, 2x, 4x BAND_QW qwords around the host's target
// occupancy (2.9 / 5.8 / 11.6 ms at SRC_RATE with BAND_QW=128).
localparam [PW-1:0] TGT = TARGET_QW[PW-1:0];
localparam [PW-1:0] B1  = BAND_QW[PW-1:0];
localparam [PW-1:0] B2  = (2*BAND_QW);
localparam [PW-1:0] B4  = (4*BAND_QW);

always @(posedge clk) begin
    if (rst) slew <= 4'sd0;
    else begin
        if      (fill_min > TGT + B4) slew <=  4'sd4;
        else if (fill_min > TGT + B2) slew <=  4'sd2;
        else if (fill_min > TGT + B1) slew <=  4'sd1;
        else if (fill_min + B4 < TGT) slew <= -4'sd4;
        else if (fill_min + B2 < TGT) slew <= -4'sd2;
        else if (fill_min + B1 < TGT) slew <= -4'sd1;
        else                          slew <=  4'sd0;
    end
end

// ---------------------------------------------------------------------------
// Resampler window + output
// ---------------------------------------------------------------------------
always @(posedge clk) begin
    if (rst) begin
        phase <= 16'd0;
        s0_l  <= 16'd0;
        s0_r  <= 16'd0;
        s1_l  <= 16'd0;
        s1_r  <= 16'd0;
        prime <= 2'd0;
        pcm_l <= 16'd0;
        pcm_r <= 16'd0;
    end
    else begin
        if (frame_pull) begin
            s0_l <= s1_l;  s0_r <= s1_r;
            s1_l <= nxt_l; s1_r <= nxt_r;
            if (!primed) prime <= prime + 1'b1;
        end

        if (out_ce && primed) begin
            pcm_l <= o_l[15:0];
            pcm_r <= o_r[15:0];

            // Advance phase only when the window actually slid. Holding it on
            // starvation freezes the output at the last sample instead of
            // interpolating toward whatever lands next.
            if (!step || !st_empty) phase <= phase_nxt[15:0];
        end
    end
end

endmodule

`default_nettype wire
