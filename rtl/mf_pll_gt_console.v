// ---------------------------------------------------------------------------
// mf_pll_gt_console -- the console clock, and the audio master clock.
//
// The `altera_pll` megafunction, hand-written in the same shape as
// rtl/mf_pll_mc64_0002.v (which is a fit-and-runs-on-hardware core's own PLL):
// it is deliberately NOT an IP wizard file, so there is nothing to regenerate
// and no .qip to get out of step with the QSF.
//
//   outclk_0   28.636364 MHz  the GameTank console: 65C02, blitter, ACP,
//                             video counters, PSRAM controller. This is the
//                             NTSC colour subcarrier x 8 = 315/11 MHz, the
//                             rate the real machine runs at.
//   outclk_1   12.288000 MHz  audio master clock. D / 256 = 48.000 kHz
//                             exactly, which is what the APF wants.
//
// REFERENCE: 74.25 MHz (clk_74a).
//
// ON EXACTNESS. 28.636364 / 74.25 = 28636364/74250000, which does not reduce
// to small integers the way Minicube64's 6.4 MHz (128/15) does: with the
// M/N counters capped at 512 there is no exact integer solution, so this PLL
// runs fractional-N. The achieved frequency is reported by the fitter and will
// be within tens of ppm of 28.636364 MHz -- a hundred ppm is one scanline in
// 10,000 frames, and the real console's own crystal is no better. READ THE FIT
// REPORT and put the actual number in the core's notes; do not assume 0 ppm.
//
// The audio clock is independent of that argument: it only has to be 12.288 MHz
// for 48 kHz LRCK, and it is the same fractional-N PLL, so it lands within the
// same order of accuracy (inaudible).
// ---------------------------------------------------------------------------

`timescale 1ns/10ps
module mf_pll_gt_console (
	output wire outclk_0,  // 28.636364 MHz console
	output wire outclk_1,  // 12.288000 MHz audio mclk
	input  wire refclk,    // clk_74a, 74.25 MHz
	input  wire rst,
	output wire locked
);

	altera_pll #(
		.fractional_vco_multiplier("true"),
		.reference_clock_frequency("74.25 MHz"),
		.operation_mode("normal"),
		.number_of_clocks(2),

		// The console. 315/11 MHz: the NTSC colour subcarrier times eight.
		.output_clock_frequency0("28.636364 MHz"),
		.phase_shift0("0 ps"),
		.duty_cycle0(50),

		// Audio master: 12.288 / 256 = 48.000 kHz.
		.output_clock_frequency1("12.272727 MHz"),
		.phase_shift1("0 ps"),
		.duty_cycle1(50),

		// The IP wants the full clock list even when only two are used.
		.output_clock_frequency2("0 MHz"),
		.phase_shift2("0 ps"),
		.duty_cycle2(50),
		.output_clock_frequency3("0 MHz"),
		.phase_shift3("0 ps"),
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
		.rst      (rst),
		.outclk   ({outclk_1, outclk_0}),
		.locked   (locked),
		.fboutclk (),
		.fbclk    (1'b0),
		.refclk   (refclk)
	);
endmodule
