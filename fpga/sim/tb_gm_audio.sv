//
//  tb_gm_audio -- gm_audio: fractional resampler + closed-loop rate matching
//
//  The DUT is instantiated with SCALED timing parameters (CLK_RATE=384000
//  instead of 24576000, so OUT_DIV=8 instead of 512, and the slew loop's window
//  and bands shortened). Cycle counts are what the RTL reasons about, so the
//  scaling changes only how long the simulation takes, not what is exercised.
//  Every ratio the DUT actually computes -- INC_NOM, the phase accumulator, the
//  band comparisons -- is identical to the device build.
//
//  Gates:
//    A  constant source            -> output is EXACTLY that constant
//    B  ramp source, across a ring -> per-sample deltas are the fractional
//       wrap                          interpolation, not zero-order hold
//    C  producer fast / slow       -> slew takes the right sign and the ring
//                                     occupancy stays bounded
//    D  producer stops             -> output holds, no glitch, clean recovery
//
//  Gate B is the one that would catch a regression to ZOH: a held sample would
//  give deltas of {0, RAMP_SLOPE}, not {0,1} with a 0.4594 mean.
//

`timescale 1ns/1ps
`default_nettype none

module tb_gm_audio;

// ---------------------------------------------------------------------------
// Scaled DUT parameters
// ---------------------------------------------------------------------------
localparam int    CLK_RATE    = 384000;     // OUT_DIV = 8
localparam int    OUT_RATE    = 48000;
localparam int    SRC_RATE    = 22050;
localparam int    RING_QWORDS = 8192;
localparam [31:3] RING_QW     = 29'h0741A000;
localparam [31:3] WPTR_QW     = 29'h07400006;
localparam int    TARGET_QW   = 64;
localparam int    POLL_TICKS  = 16;
localparam int    WIN_TICKS   = 128;
localparam int    BAND_QW     = 4;
localparam int    SLEW_STEP   = 64;         // +/-4 steps = +/-0.85% capture

// The exact ratio the DUT resamples by, in the same fixed point.
localparam int    INC_NOM     = (65536 * SRC_RATE + OUT_RATE/2) / OUT_RATE;

integer errors = 0;

task chk(input cond, input [1023:0] what);
begin
    if (!cond) begin
        $display("FAIL: %0s", what);
        errors = errors + 1;
    end
end
endtask

// ---------------------------------------------------------------------------
// Clock / reset
// ---------------------------------------------------------------------------
reg clk = 0;
always #5 clk = ~clk;           // 100 MHz sim time; the DUT only counts cycles

reg reset = 1;

// ---------------------------------------------------------------------------
// DUT
// ---------------------------------------------------------------------------
wire [31:3] ram_address;
reg  [63:0] ram_data;
wire        ram_req;
reg         ram_ready;
wire [15:0] pcm_l, pcm_r;

gm_audio #(
    .CLK_RATE   (CLK_RATE),
    .OUT_RATE   (OUT_RATE),
    .SRC_RATE   (SRC_RATE),
    .RING_QW    (RING_QW),
    .WPTR_QW    (WPTR_QW),
    .RING_QWORDS(RING_QWORDS),
    .TARGET_QW  (TARGET_QW),
    .POLL_TICKS (POLL_TICKS),
    .WIN_TICKS  (WIN_TICKS),
    .BAND_QW    (BAND_QW),
    .SLEW_STEP  (SLEW_STEP)
) dut (
    .reset      (reset),
    .clk        (clk),
    .ram_address(ram_address),
    .ram_data   (ram_data),
    .ram_req    (ram_req),
    .ram_ready  (ram_ready),
    .pcm_l      (pcm_l),
    .pcm_r      (pcm_r)
);

// ---------------------------------------------------------------------------
// Ring + DDR channel model. ram_req is a toggle; ram_ready is a 1-cycle pulse
// a variable number of cycles later, which is how ddr_svc behaves when it is
// arbitrating our channel against ch1.
// ---------------------------------------------------------------------------
reg [63:0] ring [0:RING_QWORDS-1];
reg [31:0] wr_ptr_bytes = 0;

reg        req_ack = 0;
reg        pending = 0;
reg [7:0]  lat     = 0;
reg [31:3] addr_lat;
integer    lfsr = 32'h1234_5678;

always @(posedge clk) begin
    ram_ready <= 1'b0;
    if (reset) begin
        req_ack <= ram_req;
        pending <= 0;
    end
    else if (!pending && (ram_req != req_ack)) begin
        req_ack  <= ram_req;
        addr_lat <= ram_address;
        // 3..18 cycles, deterministic but uncorrelated with the DUT's cadence.
        lfsr     <= {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
        lat      <= 8'd3 + (lfsr[3:0]);
        pending  <= 1;
    end
    else if (pending) begin
        if (lat != 0) lat <= lat - 8'd1;
        else begin
            ram_data  <= (addr_lat == WPTR_QW) ? {32'd0, wr_ptr_bytes}
                                               : ring[addr_lat - RING_QW];
            ram_ready <= 1'b1;
            pending   <= 0;
        end
    end
end

// ---------------------------------------------------------------------------
// Producer. Two behaviours:
//   PUMP -- tops the ring back up to TARGET_QW, like gmloader's pump pass.
//   FREE -- emits frames at prod_rate, so the DUT's loop has something to lock
//           onto. This is the mode that would expose an open-loop consumer.
// ---------------------------------------------------------------------------
localparam int P_OFF = 0, P_PUMP = 1, P_FREE = 2;

integer prod_mode = P_OFF;
integer prod_rate = SRC_RATE;
integer prod_acc  = 0;

// A TRIANGLE, not a sawtooth: a sawtooth's reset is a discontinuity the
// interpolator legitimately smears across, which would make the delta gate
// below untestable. RAMP_SLOPE must be large enough that linear interpolation
// and zero-order hold give DIFFERENT deltas -- at slope 1 they are identical
// (both land on {0,1}) and gate B would be vacuous. At slope 16, linear gives
// |d| in {7,8} and ZOH would give {0,16}.
localparam int M_CONST = 0, M_RAMP = 1;
localparam int RAMP_SLOPE = 16;
localparam int RAMP_PEAK  = 16384;

integer src_mode  = M_CONST;
integer src_const = 0;
integer ramp_val  = 0;
integer ramp_dir  = 1;

// Frames land two-per-qword; wr_ptr advances 4 bytes at a time, so the DUT sees
// a new qword only once both halves are written -- same as the real host.
reg [15:0] half_l, half_r;
reg        half_pend = 0;

integer fill_qw;

task emit_frame;
    reg [15:0] v;
    integer    qi;
begin
    if (src_mode == M_CONST) v = src_const[15:0];
    else begin
        v        = ramp_val[15:0];
        ramp_val = ramp_val + ramp_dir * RAMP_SLOPE;
        if (ramp_val >= RAMP_PEAK) ramp_dir = -1;
        if (ramp_val <= 0)         ramp_dir =  1;
    end

    qi = (wr_ptr_bytes >> 3) % RING_QWORDS;
    if (!half_pend) begin
        half_l          = v;
        half_r          = v;
        ring[qi][31:0]  = {v, v};
        half_pend       = 1;
    end
    else begin
        ring[qi][63:32] = {v, v};
        half_pend       = 0;
    end
    wr_ptr_bytes = wr_ptr_bytes + 4;
end
endtask

always @(posedge clk) begin
    if (reset) begin
        prod_acc  = 0;
        half_pend = 0;
    end
    else begin
        fill_qw = ((wr_ptr_bytes >> 3) - dut.rptr) & (RING_QWORDS - 1);

        case (prod_mode)
            P_PUMP: begin
                // One frame per cycle until back at target; the burstiness is
                // deliberate -- it is what the fill-minimum window exists for.
                if (dut.got_first && fill_qw < TARGET_QW) emit_frame;
            end
            P_FREE: begin
                prod_acc = prod_acc + prod_rate;
                if (prod_acc >= CLK_RATE) begin
                    prod_acc = prod_acc - CLK_RATE;
                    emit_frame;
                end
            end
            default: ;
        endcase
    end
end

// ---------------------------------------------------------------------------
// Output observation
// ---------------------------------------------------------------------------
reg  [15:0] prev_pcm  = 0;
reg         have_prev = 0;
integer     n_out     = 0;
integer     d_sum     = 0;
integer     d_bad     = 0;
integer     d_zoh     = 0;
integer     d_min     = 999;
integer     d_max     = -999;
integer     hold_run  = 0;
integer     hold_max  = 0;
integer     watch     = 0;      // 0 off, 1 constant, 2 ramp, 3 hold

// out_ce is one cycle wide; sample pcm on the cycle after the DUT registers it.
reg out_ce_d;
always @(posedge clk) out_ce_d <= dut.out_ce && dut.primed;

integer d, ad;
always @(posedge clk) begin
    if (reset) begin
        have_prev <= 0;
        hold_run  <= 0;
    end
    else if (out_ce_d && watch != 0) begin
        n_out = n_out + 1;
        if (watch == 1) begin
            if (pcm_l !== src_const[15:0]) d_bad = d_bad + 1;
        end
        else if (watch == 2) begin
            if (have_prev) begin
                d  = $signed(pcm_l) - $signed(prev_pcm);
                ad = (d < 0) ? -d : d;
                if (ad < d_min) d_min = ad;
                if (ad > d_max) d_max = ad;
                d_sum = d_sum + ad;
                // Steady state on either leg of the triangle is |d| in {7,8}.
                // Only the samples straddling an apex may fall outside.
                if (ad != 7 && ad != 8) d_bad = d_bad + 1;
                // Anti-ZOH: a held source sample gives |d| of exactly 0 or
                // RAMP_SLOPE, never the fractional step in between. d_max
                // covers the full-slope half; d_zoh counts the held half,
                // which a triangle apex can also produce legitimately.
                if (d == 0) d_zoh = d_zoh + 1;
            end
        end
        else if (watch == 3) begin
            if (have_prev && (pcm_l === prev_pcm)) hold_run = hold_run + 1;
            else hold_run = 0;
            if (hold_run > hold_max) hold_max = hold_run;
        end
        prev_pcm  <= pcm_l;
        have_prev <= 1;
    end
end

task reset_stats;
begin
    n_out = 0; d_sum = 0; d_bad = 0; d_zoh = 0; d_min = 999; d_max = -999;
    hold_run = 0; hold_max = 0; have_prev = 0;
end
endtask

// ---------------------------------------------------------------------------
// Cases
// ---------------------------------------------------------------------------
integer i;
integer fill_lo, fill_hi;
real    mean_d, want_d;

task do_reset;
begin
    watch     = 0;
    prod_mode = P_OFF;
    reset     = 1;
    repeat (20) @(posedge clk);
    wr_ptr_bytes = 0;
    ramp_val     = 0;
    for (i = 0; i < RING_QWORDS; i = i + 1) ring[i] = 64'd0;
    repeat (5) @(posedge clk);
    reset = 0;
    // Let the DUT poll, adopt the pointer, and the pump establish the target.
    prod_mode = P_PUMP;
    wait (dut.got_first);
    repeat (4000) @(posedge clk);
end
endtask

initial begin
    $display("tb_gm_audio: INC_NOM=%0d (%0d/%0d)", INC_NOM, SRC_RATE, OUT_RATE);
    chk(INC_NOM == 30106, "INC_NOM must be 30106 for 22050->48000");

    // -- A: a constant source must come out bit-exact ------------------------
    src_mode  = M_CONST;
    src_const = 1000;
    do_reset;
    reset_stats;
    watch = 1;
    repeat (200000) @(posedge clk);
    watch = 0;
    $display("A: %0d outputs, %0d not equal to %0d", n_out, d_bad, src_const);
    chk(n_out > 10000, "A produced too few output samples");
    chk(d_bad == 0,    "A: constant source did not come out bit-exact");

    // -- B: triangle source, run long enough to wrap the ring twice ----------
    src_mode = M_RAMP;
    do_reset;
    reset_stats;
    watch = 2;
    // 8192 qwords = 16384 frames per wrap; ~2.4 wraps at 22050 frames/s.
    repeat (700000) @(posedge clk);
    watch = 0;
    mean_d = (n_out > 1) ? (d_sum * 1.0) / (n_out - 1) : 0.0;
    want_d = (INC_NOM * 1.0) / 65536.0 * RAMP_SLOPE;
    $display("B: %0d outputs, |delta| in [%0d,%0d], mean=%0.5f want=%0.5f, off-band=%0d zoh=%0d",
             n_out, d_min, d_max, mean_d, want_d, d_bad, d_zoh);
    chk(n_out > 80000, "B produced too few output samples");
    // Apex samples are the only legitimate off-band deltas: ~20 apexes over the
    // run, at most a couple of samples each.
    chk(d_bad < 200, "B: too many deltas outside {7,8} -- window slid wrong");
    // Under zero-order hold every delta would be 0 or RAMP_SLOPE, so d_max
    // would equal RAMP_SLOPE and d_zoh would be ~54% of n_out. Both gates are
    // three orders of magnitude away from the ZOH outcome.
    chk(d_max < RAMP_SLOPE,
        "B: saw a full-slope delta -- output is zero-order hold, not interpolated");
    chk(d_zoh < 100,
        "B: too many held deltas -- output is zero-order hold, not interpolated");
    chk(mean_d > want_d * 0.995 && mean_d < want_d * 1.005,
        "B: mean slope is not SRC_RATE/OUT_RATE -- resample ratio is wrong");

    // -- C: free-running producer 0.4% FAST; the loop must ABSORB it ---------
    //
    // The gate is ring occupancy in the LAST quarter of the run, not slew's
    // sign: slew is computed from the fill regardless of whether `inc` acts on
    // it, so a sign check alone passes an open-loop consumer. A +0.4% producer
    // drifts the occupancy ~44 qwords/second when the loop is open, so the
    // settled-window bound below separates the two by a wide margin.
    src_mode  = M_CONST;
    src_const = 0;
    do_reset;
    prod_mode = P_FREE;
    prod_rate = (SRC_RATE * 1004) / 1000;
    fill_lo   = RING_QWORDS; fill_hi = 0;
    for (i = 0; i < 600000; i = i + 1) begin
        @(posedge clk);
        if (i > 450000) begin
            if (fill_qw < fill_lo) fill_lo = fill_qw;
            if (fill_qw > fill_hi) fill_hi = fill_qw;
        end
    end
    $display("C-fast: slew=%0d inc=%0d (nom %0d) settled fill=[%0d,%0d] target=%0d",
             $signed(dut.slew), $signed(dut.inc), INC_NOM, fill_lo, fill_hi, TARGET_QW);
    chk($signed(dut.slew) > 0, "C-fast: slew did not go positive for a fast producer");
    chk($signed(dut.inc) > INC_NOM,
        "C-fast: inc ignored slew -- the consumer is open-loop");
    chk(fill_hi <= TARGET_QW + 5*BAND_QW,
        "C-fast: occupancy drifted up -- the loop is not absorbing the producer");

    // -- C': free-running producer 0.4% SLOW ---------------------------------
    do_reset;
    prod_mode = P_FREE;
    prod_rate = (SRC_RATE * 996) / 1000;
    fill_lo   = RING_QWORDS; fill_hi = 0;
    for (i = 0; i < 600000; i = i + 1) begin
        @(posedge clk);
        if (i > 450000) begin
            if (fill_qw < fill_lo) fill_lo = fill_qw;
            if (fill_qw > fill_hi) fill_hi = fill_qw;
        end
    end
    $display("C-slow: slew=%0d inc=%0d (nom %0d) settled fill=[%0d,%0d] target=%0d",
             $signed(dut.slew), $signed(dut.inc), INC_NOM, fill_lo, fill_hi, TARGET_QW);
    chk($signed(dut.slew) < 0, "C-slow: slew did not go negative for a slow producer");
    chk($signed(dut.inc) < INC_NOM,
        "C-slow: inc ignored slew -- the consumer is open-loop");
    chk(fill_lo + 5*BAND_QW >= TARGET_QW,
        "C-slow: occupancy drifted down -- the loop is not absorbing the producer");

    // -- D: producer stops -> hold, then recovers without a re-sync ----------
    src_mode  = M_CONST;
    src_const = 4321;
    do_reset;
    reset_stats;
    prod_mode = P_OFF;
    watch     = 3;
    repeat (100000) @(posedge clk);
    watch = 0;
    $display("D: longest hold run = %0d, final pcm_l=%0d, got_first=%0b",
             hold_max, $signed(pcm_l), dut.got_first);
    chk(hold_max > 1000, "D: output did not hold through starvation");
    chk(pcm_l === src_const[15:0], "D: held at something other than the last sample");
    chk(dut.got_first === 1'b1, "D: starvation cleared got_first -- would replay stale ring");

    // Recovery: the pump comes back, output must follow the new value.
    src_const = -8000;
    prod_mode = P_PUMP;
    repeat (100000) @(posedge clk);
    $display("D-recover: pcm_l=%0d want=%0d", $signed(pcm_l), src_const);
    chk($signed(pcm_l) == src_const, "D: did not recover after the producer returned");

    if (errors == 0) $display("RESULT: PASS");
    else             $display("RESULT: FAIL (%0d errors)", errors);
    $finish;
end

initial begin
    #200_000_000;
    $display("FAIL: tb_gm_audio timed out");
    $display("RESULT: FAIL");
    $finish;
end

endmodule

`default_nettype wire
