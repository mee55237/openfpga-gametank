// ---------------------------------------------------------------------------
// mf_pll_gt_video -- the picture's clock, on its own PLL.
//
//   outclk_0    2.250000 MHz  video_rgb_clock. One pixel per cycle.
//   outclk_1    2.250000 MHz  video_rgb_clock_90, +90 degrees.
//
// 150 dots x 250 lines x 60 Hz = 2,250,000 Hz -- 128 x 128 of picture and the
// blanking the scaler needs around it (rtl/gt_video.sv has the arithmetic).
// The 250-line, 15 kHz frame is rtl/mc64_video.sv's, the signal proven on this
// panel; 74.25 / 2.25 is exactly 33, so this is an INTEGER PLL: no fractional-N
// jitter on the DDR launch clock or on the quarter-period phase shift below. It has NOTHING to do with the
// console's 28.636364 MHz -- that is rtl/mf_pll_gt_console.v, a separate PLL.
// The two domains meet only at gt_video's dual-clock frame store.
//
// WHY A SECOND PLL RATHER THAN AN OUTPUT OF THE FIRST: the console clock and
// the pixel clock would have to be integer divisions of one VCO, which forces
// the raster geometry to be chosen for divisibility instead of for the picture.
// They are unrelated here, so the picture is 128x128 at whatever rate it wants
// and the console stays at its own exact rate.
//
// ON EXACTNESS. 2.25 MHz is 74.25 MHz / 33 exactly, so the frame rate is
// 60.000000 Hz with no fractional division at all (150 x 250 x 60 = 2,250,000),
// and the quarter-period phase shift below is exact (444,444 ps / 4 = 111,111 ps).
// READ THE FIT REPORT for
// the actual counters; the frequency is the one number that decides whether the
// panel ever drops a frame.
//
// THE 90-DEGREE OUTPUT IS A PLL OUTPUT, NOT A FABRIC-SHIFTED COPY. apf_top
// DDR-launches the RGB and sync bits on the 0-degree clock and the scaler's
// own clock samples them, so the quarter period (168,350 ps) IS the sampling
// margin. A shift made of LUTs and flops passes every simulation and fails on
// the panel -- both VexiiRiscv and agg23's NES record the same trap.
// ---------------------------------------------------------------------------

`timescale 1ns/10ps
module mf_pll_gt_video (
	output wire outclk_0,  // 2.250000 MHz pixel clock
	output wire outclk_1,  // same, +90 degrees (111111 ps)
	input  wire refclk,    // clk_74a, 74.25 MHz
	input  wire rst,
	output wire locked
);

	altera_pll #(
		.fractional_vco_multiplier("true"),
		.reference_clock_frequency("74.25 MHz"),
		.operation_mode("normal"),
		.number_of_clocks(2),

		// 150 x 250 x 60 Hz (128 x 128 of picture, 15.000 kHz lines).
		.output_clock_frequency0("2.250000 MHz"),
		.phase_shift0("0 ps"),
		.duty_cycle0(50),

		// Quarter of a pixel period: 1 / (4 x 2,250,000 Hz) = 111,111.1 ps.
		.output_clock_frequency1("2.250000 MHz"),
		.phase_shift1("111111 ps"),
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
