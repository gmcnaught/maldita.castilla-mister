`timescale 1ns/10ps
module  pll_0002(

	// interface 'refclk'
	input wire refclk,

	// interface 'reset'
	input wire rst,

	// interface 'outclk0'
	output wire outclk_0,

	// interface 'outclk1'
	output wire outclk_1,

	// interface 'outclk2'
	output wire outclk_2,

	// interface 'outclk3'
	output wire outclk_3,

	// interface 'locked'
	output wire locked
);

	altera_pll #(
		.fractional_vco_multiplier("false"),
		.reference_clock_frequency("50.0 MHz"),
		.operation_mode("direct"),
		.number_of_clocks(4),
		.output_clock_frequency0("98.437500 MHz"),
		.phase_shift0("0 ps"),
		.duty_cycle0(50),
		.output_clock_frequency1("20.000000 MHz"),
		.phase_shift1("0 ps"),
		.duty_cycle1(50),
		.output_clock_frequency2("53.693182 MHz"),
		.phase_shift2("0 ps"),
		.duty_cycle2(50),
		.output_clock_frequency3("98.437500 MHz"),
		// [#44] SDRAM_CLK capture phase. MUST be a non-zero ~105.8ps PLL tap:
		// at 0 ps outclk_3 is bit-identical to outclk_0, so Quartus merges them
		// and SDRAM_CLK goes unconstrained (frame-wide banding).
		//
		// 2026-07-26 CROSS-BOARD SWEEP: the old 5079ps was tuned on ONE board and
		// is DEAD on the other. jtframe's burst controller runs CL=2 at clk_sys
		// 98.4375MHz (~2x the ~48MHz jtcores uses that stack at), so the data eye
		// is too narrow to be board-agnostic — each DE10-Nano+module pair has its
		// own dead zone. 8 phases x 2 boards, scored BIT-EXACT on the uvsym probe
		// u-ramp (period 10159ps; PASS=bit-exact, BADn=n/7 samples wrong):
		//
		//   phase    635   1270   2540   3809   5079   6349   8042   9313
		//   .62     PASS   PASS   PASS   BAD7   DEAD   PASS   PASS   PASS
		//   .81     PASS   PASS   PASS   PASS   PASS   BAD1   PASS   PASS
		//
		// One contiguous good arc wrapping through zero; the two dead zones are in
		// DIFFERENT places (.62 ~3100-5900, .81 ~5700-6800) and 5079 lands inside
		// .62's. 2540ps is in the arc common to both AND is the only candidate with
		// in-game evidence of sustained fabric advance on .62.
		//
		// CAUTION: the uvsym probe passing does NOT imply the game is stable — 635ps
		// is bit-exact on both boards yet wedged the fabric far sooner in-game.
		// Re-sweep against the GAME, not just the probe. And do not trust STA here:
		// Maldita.sdc:90-100 multicycles both SDRAM directions, reporting +15.5ns
		// slack on a 10.159ns clock, so CI cannot catch a phase regression today.
		.phase_shift3("2540 ps"),
		.duty_cycle3(50),
		.output_clock_frequency4("0 MHz"),
		.phase_shift4("0 ps"),
		.duty_cycle4(50),
		.output_clock_frequency5("0 MHz"),
		.phase_shift5("0 ps"),
		.duty_cycle5(50),
		.output_clock_frequency6("0 MHz"),
		.phase_shift6("0 ps"),
		.duty_cycle6(50),
		.output_clock_frequency7("0 MHz"),
		.phase_shift7("0 ps"),
		.duty_cycle7(50),
		.output_clock_frequency8("0 MHz"),
		.phase_shift8("0 ps"),
		.duty_cycle8(50),
		.output_clock_frequency9("0 MHz"),
		.phase_shift9("0 ps"),
		.duty_cycle9(50),
		.output_clock_frequency10("0 MHz"),
		.phase_shift10("0 ps"),
		.duty_cycle10(50),
		.output_clock_frequency11("0 MHz"),
		.phase_shift11("0 ps"),
		.duty_cycle11(50),
		.output_clock_frequency12("0 MHz"),
		.phase_shift12("0 ps"),
		.duty_cycle12(50),
		.output_clock_frequency13("0 MHz"),
		.phase_shift13("0 ps"),
		.duty_cycle13(50),
		.output_clock_frequency14("0 MHz"),
		.phase_shift14("0 ps"),
		.duty_cycle14(50),
		.output_clock_frequency15("0 MHz"),
		.phase_shift15("0 ps"),
		.duty_cycle15(50),
		.output_clock_frequency16("0 MHz"),
		.phase_shift16("0 ps"),
		.duty_cycle16(50),
		.output_clock_frequency17("0 MHz"),
		.phase_shift17("0 ps"),
		.duty_cycle17(50),
		.pll_type("General"),
		.pll_subtype("General")
	) altera_pll_i (
		.rst	(rst),
		.outclk	({outclk_3, outclk_2, outclk_1, outclk_0}),
		.locked	(locked),
		.fboutclk	( ),
		.fbclk	(1'b0),
		.refclk	(refclk)
	);
endmodule

