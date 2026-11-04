/*
 * The console's audio output stage: the ACP's DAC level to the Pocket's I2S.
 *
 * WHAT COMES IN. rtl/acp.sv re-latches the audio coprocessor's staged byte into
 * the AD7524 once per sample tick, so the level is an 8-bit word held until the
 * next tick: a zero-order hold at the ACP's sample rate (3.579545 MHz divided by
 * the game's `period + 1`, typically 15..30 kHz). rtl/gametank.sv turns that
 * unsigned byte into the signed 16-bit sample the byte means -- (dac - 128) *
 * 256, so 0x80 is the centre of the waveform and therefore silence -- and this
 * module turns that into the serial stream the scaler wants.
 *
 * WHY THERE ARE TWO CLOCK DOMAINS, AND WHY THE FRAMES COME FROM clk_74a.
 *
 * The filter has to run at the console's 28.636364 MHz: that is 700x the
 * highest audio frequency and 1000x the ACP's own sample rate, and the whole
 * point of it is to reconstruct the waveform between the DAC's steps.
 *
 * The FRAMES, though, must not come from the console clock. This module used to
 * divide the console PLL's 12.272727 MHz audio output by 256, which is 47.94
 * kHz, not 48: an 0.12% shortfall against the rate the framework's audio path
 * runs at. Over one second that is sixty samples the Pocket has to invent, and
 * they are not free -- they are the rattle underneath everything. The Pocket's
 * own master clock is clk_74a (74.25 MHz) and 12.288 * 2 / 74.25 = 245760 /
 * 742500 exactly, so a fractional accumulator on clk_74a makes a 12.288000 MHz
 * master clock to the part in 10^9, and 256 of its half-periods per frame is
 * 48.000 kHz exactly. This is the same accumulator agg23's `sound_i2s.sv`
 * (refs/agg23-pocket-utils/ip) uses for every one of their Pocket cores, and it
 * is the reason their audio does not tick.
 *
 * So: the level is filtered and muted in the console domain, and handed to the
 * clk_74a domain through a toggle handshake, where it is shifted out. Nothing
 * in the serial path depends on the console clock at all, which also means a
 * paused machine (see the mute) cannot drag the audio clock with it.
 *
 * THE LEVEL IS CENTRED BEFORE IT GETS HERE. `{dac, 8'h00}` looked like a signed
 * sample and is not: the AD7524 is an *unsigned* byte and 0x80 is its midpoint,
 * so the old form put silence at -32768 -- full-scale negative -- and the whole
 * waveform in the bottom half of the range. That is inaudible on its own (the
 * output is AC coupled) but it is not harmless: it leaves only the negative
 * half of the range for the music, so any stage that adds, boosts or saturates
 * downstream clips one side of the waveform and not the other, which is exactly
 * the buzz this was reported as. rtl/gametank.sv now emits (dac - 128) * 256,
 * and this module's dc-gain-of-one filter keeps it centred.
 *
 * WHY THE FILTER MATTERS, AND WHERE ITS CORNER IS. The DAC's steps carry the
 * waveform's image spectrum: harmonics of the sample rate folded around every
 * harmonic of the signal. Some of those images land *inside* the band -- nothing
 * downstream can remove them, and real hardware has them too -- but the ones
 * above 24 kHz fold back down when the level is resampled, and those are the
 * fizz. The old chain was Minicube64's single pole at `>>>6`, which on a 6.4 MHz
 * machine was 16 kHz and here is 71 kHz: no filtering at all where it matters.
 *
 * Six cascaded one-poles -- four at 17.8 kHz and two at 35.6 kHz (shifts
 * 8,8,8,8,7,7) -- put the chain at -3 dB at 6.9 kHz, -4.9 dB at 9 kHz, -10.9 dB
 * at 14 kHz and -21.1 dB at 20 kHz. That is still darker than the old chain on
 * purpose: an 8-bit zero-order hold has a staircase that a Pocket's digital
 * output reproduces exactly, and the console's own LM358 stage is a low-pass of
 * the same order -- the crunch is that staircase. The two 35.6 kHz sections are
 * what buys the top octave back without giving up the images: against the old
 * four-pole 17.8/17.8/17.8/8.9 chain they are 1.1-1.7 dB brighter from 7 to
 * 14 kHz and *better* above it (the 49 kHz image folds into 19 kHz at -32.6 dB,
 * where the old chain left it at -31.7).
 *
 * THE FILTER KEEPS ITS FRACTIONS. The obvious `y += (x - y) >> 6` on a 16-bit y
 * is broken in a way that is invisible until you listen: the error term
 * truncates, so it reaches zero while the output is still up to 63 counts away,
 * and for any input under 64 counts the term is zero from the first cycle. A
 * quiet tail or a fade would simply disappear. Each stage therefore holds 16.6
 * fixed point (the level scaled by 2^6) and rounds at every step, so a settled
 * filter returns exactly the level it was given and the smallest real input
 * still converges.
 *
 * MUTE. The pause freezes the CPUs with the picture still running (see
 * core_top's PAUSE section), and a frozen console must go quiet rather than hold
 * whatever note the ACP last latched. A hard gate would click, so the level is
 * multiplied by a 10-bit gain that ramps over 2.3 ms (one step per 64 clocks),
 * before the filter so the ramp is smoothed as well.
 *
 * THE RESAMPLE. One value per frame, moved with a two-toggle handshake rather
 * than a bare synchroniser: a 16-bit word crossing domains while it changes can
 * be read as a mix of old and new bits, and a mix of 0x07FF and 0x0800 is 4095
 * counts -- audible. The request is issued in the frame's second half, the
 * console domain latches the filtered level into `held` and flips `held_tog` on
 * the same edge, and the frame domain copies `held` when it sees that toggle
 * arrive. The request lands 128 master-clock half-periods (5.2 us) before the
 * reload that starts the next frame's first slot, and the second slot's reload
 * re-reads the same `sample`, so one frame carries one sample on both channels.
 *
 * RESET. Only the console side is reset. The frame registers come up at zero,
 * which is silence: the first slot is loaded 20 us after the clocks start, and
 * until then the DAC shifts out zeroes.
 */
`default_nettype none
`timescale 1ns / 1ps

module gt_audio #(
    // The filter, as the six one-pole sections' shifts. 16.6 fixed point; at
    // 28.636 MHz a shift of S puts a corner at fs/(2*pi*2^S): 7 -> 35.6 kHz,
    // 8 -> 17.8 kHz, 9 -> 8.9 kHz. Shift a stage DOWN to brighten the output.
    parameter int SHIFT0 = 8,
    parameter int SHIFT1 = 8,
    parameter int SHIFT2 = 8,
    parameter int SHIFT3 = 8,
    parameter int SHIFT4 = 7,
    parameter int SHIFT5 = 7
) (
    // ---- the machine's side: the DAC level, in its own clock domain ----
    input  logic        clk,        // console: 28.636364 MHz
    input  logic        reset,
    input  logic [15:0] level,      // signed: (dac - 128) * 256, 0 == silence
    input  logic        mute,       // the pause: ramp to silence and stay there

    // ---- the Pocket's side ----
    input  logic        clk_74a,    // 74.25 MHz: the frame clock's reference
    output logic        audio_mclk, // 12.288000 MHz
    output logic        audio_lrck, // audio_mclk / 256 = 48.000 kHz
    output logic        audio_dac   // serial data, MSB first
);

    /* ------------------------------------------------------------------ *
     * The mute ramp (clk domain): 10-bit gain, one step per 64 clocks
     * ------------------------------------------------------------------ */
    logic [5:0]  ramp_div = 6'd0;
    logic [10:0] gain     = 11'd1024;   // 1024 == unity, so full scale is exact

    always_ff @(posedge clk) begin
        ramp_div <= ramp_div + 6'd1;
        if (ramp_div == 6'd0) begin
            if (mute && gain != 11'd0)
                gain <= gain - 11'd1;
            else if (!mute && gain != 11'd1024)
                gain <= gain + 11'd1;
        end
    end

    // level * gain, back to 16 bits: one signed multiplier, 16 x 11.
    wire signed [26:0] scaled = $signed(level) * $signed({1'b0, gain});
    wire signed [15:0] lvl    = 16'(scaled >>> 10);

    /* ------------------------------------------------------------------ *
     * The filter (clk domain), 16.6 fixed point per stage
     * ------------------------------------------------------------------ */
    localparam signed [22:0] LPF_RND0 = 23'sd1 << (SHIFT0 - 1);
    localparam signed [22:0] LPF_RND1 = 23'sd1 << (SHIFT1 - 1);
    localparam signed [22:0] LPF_RND2 = 23'sd1 << (SHIFT2 - 1);
    localparam signed [22:0] LPF_RND3 = 23'sd1 << (SHIFT3 - 1);
    localparam signed [22:0] LPF_RND4 = 23'sd1 << (SHIFT4 - 1);
    localparam signed [22:0] LPF_RND5 = 23'sd1 << (SHIFT5 - 1);

    wire  signed [22:0] lpf_in = $signed({{7{lvl[15]}}, lvl}) <<< 6;

    logic signed [22:0] s0 = 23'sd0;
    logic signed [22:0] s1 = 23'sd0;
    logic signed [22:0] s2 = 23'sd0;
    logic signed [22:0] s3 = 23'sd0;
    logic signed [22:0] s4 = 23'sd0;
    logic signed [22:0] s5 = 23'sd0;

    always_ff @(posedge clk) begin
        if (reset) begin
            s0 <= 23'sd0;
            s1 <= 23'sd0;
            s2 <= 23'sd0;
            s3 <= 23'sd0;
            s4 <= 23'sd0;
            s5 <= 23'sd0;
        end
        else begin
            s0 <= s0 + ((lpf_in       - s0 + LPF_RND0) >>> SHIFT0);
            s1 <= s1 + ((s0           - s1 + LPF_RND1) >>> SHIFT1);
            s2 <= s2 + ((s1           - s2 + LPF_RND2) >>> SHIFT2);
            s3 <= s3 + ((s2           - s3 + LPF_RND3) >>> SHIFT3);
            s4 <= s4 + ((s3           - s4 + LPF_RND4) >>> SHIFT4);
            s5 <= s5 + ((s4           - s5 + LPF_RND5) >>> SHIFT5);
        end
    end

    wire [15:0] filt = 16'((s5 + 23'sd32) >>> 6);

    /* ------------------------------------------------------------------ *
     * The request: the frame domain asks, the console domain answers
     * ------------------------------------------------------------------ */
    logic        req = 1'b0;            // clk_74a: one toggle per frame

    logic [2:0]  req_s = 3'd0;          // clk
    logic [15:0] held = 16'd0;
    logic        held_tog = 1'b0;

    always_ff @(posedge clk) req_s <= {req_s[1:0], req};

    always_ff @(posedge clk) begin
        if (req_s[2] ^ req_s[1]) begin
            held     <= filt;
            held_tog <= ~held_tog;
        end
    end

    logic [2:0]  tog_s = 3'd0;          // clk_74a
    logic [15:0] sample = 16'd0;

    always_ff @(posedge clk_74a) tog_s <= {tog_s[1:0], held_tog};

    always_ff @(posedge clk_74a)
        if (tog_s[2] ^ tog_s[1])
            sample <= held;

    /* ------------------------------------------------------------------ *
     * The master clock: 12.288000 MHz out of 74.25, exactly
     *
     * 74.25 MHz x 245760/742500 = 24.576 MHz of half-periods = 12.288 MHz. The
     * accumulator wraps by subtraction, so it never drifts and never rounds:
     * the average is the exact ratio, and the only error is one clk_74a period
     * (13.5 ns) of edge placement, which is what agg23's bridge does too.
     * ------------------------------------------------------------------ */
    localparam logic [23:0] MCLK_STEP  = 24'd245760;
    localparam logic [23:0] MCLK_LIMIT = 24'd742500;

    logic [23:0] acc   = 24'd0;
    logic        mclk  = 1'b0;
    logic        tick  = 1'b0;          // one per master-clock half-period

    always_ff @(posedge clk_74a) begin
        acc <= acc + MCLK_STEP;
        if (acc >= MCLK_LIMIT) begin
            acc  <= acc - MCLK_LIMIT + MCLK_STEP;
            mclk <= ~mclk;
            tick <= 1'b1;
        end
        else
            tick <= 1'b0;
    end

    assign audio_mclk = mclk;

    /* ------------------------------------------------------------------ *
     * The frame plan
     *
     * div counts master-clock half-periods. div[2] is SCLK (period 8 halves =
     * 4 master clocks = 3.072 MHz), div[7:3] is the bit position inside the
     * 32-bit slot, div[8] is LRCK (period 512 halves = 256 master clocks =
     * 48.000 kHz). The request sits at 0x180: the second half of the frame,
     * 128 halves ahead of the reload that starts the next one.
     * ------------------------------------------------------------------ */
    logic [8:0] div = 9'd0;

    always_ff @(posedge clk_74a) begin
        if (tick) begin
            div <= div + 9'd1;
            if (div == 9'h180)
                req <= ~req;
        end
    end

    assign audio_lrck = div[8];

    /* ------------------------------------------------------------------ *
     * The serializer
     *
     * THE DATA EDGE IS THE SCLK FALLING EDGE, AND THAT IS THE WHOLE BUG
     * (2026-10-25). SCLK is div[2]: one period per 8 halves, high for
     * div[2:0] = 4..7 and low for 0..3. The panel samples on SCLK's RISING
     * edge, so the data line has to move on its FALLING edge -- div[2:0] == 0
     * -- and then sit still for the four halves before the scaler reads it and
     * the four after.
     *
     * This serializer used to move the line at div[2:0] == 3, which is LATE
     * in the bit and only one half-period before the sample point (that number
     * came from Minicube64's version, whose `div` counted something else). A
     * half-period of setup is not a receiver's setup time, and the effect is
     * exactly the one heard on the panel: the receiver takes the bit that is
     * still on the line from the previous period, so the sample arrives
     * shifted by one place -- half amplitude with the LSB gone, which is thin,
     * quiet and gritty rather than obviously broken. Moving the edge to
     * div[2:0] == 6 kept the same one-bit error. Only the falling edge is
     * right, and with it the decode is bit-exact: 8192 in comes back as 8192.
     *
     * div[7:3] is the bit position inside the 32-bit slot and div[8] is LRCK,
     * so bit 0 of a slot is the same tick LRCK changes.
     *
     * THE RELOAD IS ON BIT 0, AND THAT IS THE ONE-BIT ERROR (2026-10-25, the
     * second time). I2S puts the sample's MSB one BIT CLOCK AFTER the frame
     * sync edge, not on it. Reloading at bit 31 -- the previous version -- put
     * the MSB on the line in the very tick LRCK changed, so a receiver that
     * starts counting one clock after the edge took sample[14] as the MSB and
     * never saw sample[0]: the value arrives halved and one place off, which
     * is thin and gritty but not obviously broken, and it is exactly what the
     * panel reported. Reloading at bit 0 makes the frame edge a bit whose data
     * nobody reads (the previous sample's tail) and puts sample[15] out on the
     * next data edge, one bit clock later, which is the timing agg23's
     * sound_i2s drives on this panel (refs/agg23-pocket-utils/ip/sound_i2s.sv:
     * it reloads on the sync edge and lets the MSB leave on the following
     * SCLK). Bits 1..16 are then sample[15:0], and bits 17..31 are zeroes.
     *
     * The reload happens at bit 0 of EVERY slot, so both halves of the frame
     * carry the same `sample` -- the console is mono.
     * ------------------------------------------------------------------ */
    logic [15:0] shift = 16'd0;

    always_ff @(posedge clk_74a) begin
        if (tick && div[2:0] == 3'd0) begin
            audio_dac <= shift[15];
            if (div[7:3] == 5'd0)
                shift <= sample;      // sync edge: MSB leaves on the NEXT bit
            else
                shift <= {shift[14:0], 1'b0};
        end
    end

endmodule
