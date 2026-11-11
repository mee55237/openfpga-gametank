//============================================================================
//  gt_video -- the Pocket's 128x128 picture for GameTank.
//
//  Adapted from Minicube64's rtl/mc64_video.sv (same author, same panel, same
//  APF contract). This is NOT GameTank's own raster: rtl/gtvideo.sv stays
//  exactly as the MiSTer core has it, because the CPU's NMI, the blitter's
//  raster position and the 74564's dot clock all come out of that one, and it
//  draws 128x128 across a 227-cycle x 262-line raster at 60.18 Hz with a
//  border. What the Pocket wants is one thing: the picture, 128 pixels wide
//  and 128 lines tall, on a raster the scaler can lock to. Nothing else.
//
//  So this stage sits between the two and translates:
//
//    console side (clk_sys, 28.636 MHz)         panel side (video domain)
//    ------------------------------------       -------------------------
//    gtvideo's picture tap, one palette          one pixel per ce, on a
//    index per visible pixel (pic_we)            128x128 raster, exactly
//                                                60.000000 Hz, no blanking
//
//  WHAT CHANGED FROM mc64_video, and what did not:
//
//    mc64_video.sv                    gt_video.sv (this file)
//    -----------------------------    ------------------------------------
//    64x64 picture, 88x250 raster     128x128 picture, 128x128 raster
//    reads the framebuffer itself     captures gtvideo's picture tap, so no
//    (one RAM port, phase-locked to   memory-port contention at all -- the
//     the machine's frame)            console's framebuffer is internal BRAM
//    phase-locks the raster to the    holds a whole frame in a double buffer
//    CPU's frame (FRAME_CLOCKS)       and flips it at a scanout frame end
//
//  The frame store is the one substantive difference, and it is what makes
//  the phase lock unnecessary here: the console writes the picture into the
//  page that is NOT being scanned, and the page only becomes visible once a
//  complete console frame has landed (the rising edge of frame_sync). A swap
//  can therefore never show half a picture, whatever the two rates are doing.
//  It costs 32 KB of M10K and one frame of latency (~16.7 ms), and in exchange
//  none of mc64's phase-lock machinery is needed: nothing here has to align
//  the raster to the console's frame boundary, because the boundary is
//  absorbed by a buffer instead of by blanking arithmetic.
//
//  THE OUTPUT IS EXACTLY 128x128 ACTIVE PIXELS. That is the whole contract
//  with the APF scaler: the Pocket upscales 128x128 to its 1600x1440 panel
//  itself, and the core must NOT pad, letterbox, centre or scale anything.
//  There is no border here, no 246-line window and no 748-dot line: video_de
//  is high for 128 dots on 128 lines and low everywhere else. (An earlier
//  revision of this file emitted a bordered 748x246 window because it reused
//  gtvideo's own geometry; that is exactly wrong for the APF and is what this
//  file replaces.)
//
//  RASTER: 150 dots x 250 lines, of which 128 x 128 is picture. THE LINE AND
//  FRAME RATES ARE rtl/mc64_video.sv's, because that is the signal proven on
//  this panel and the geometry is not free to be invented: 15.000 kHz lines,
//  250 of them, 60.000000 Hz.
//
//    line  : 128 picture dots | 20 blank | HS (one dot) | 1 gap
//    frame : 128 picture lines | 121 blank | VS (one dot, on the last line)
//    rate  : 150 x 250 x 60 Hz = 2,250,000 Hz pixel clock
//
//  HS AND VS ARE ONE-CYCLE PULSES -- one HS per line, one VS per frame, VS
//  four dots before the HS that closes the same frame. That is the APF
//  contract verbatim (Developer Docs, Bus Communication / Timing Information:
//  "A frame starts with a single cycle pulse on VS. Each line starts with a
//  single cycle pulse on HS... HS may not be immediately sent until 3 cycles
//  after VS"), and it is what rtl/mc64_video.sv has always done on this panel
//  (`video_hs <= (hcd == H_SYNC)`, `video_vs <= (vcd == V_LAST) && (hcd ==
//  H_VS)`). An earlier revision of THIS file held HS for four dots and VS for
//  four whole LINES; a four-line VS is not a pulse, it reads as four frame
//  starts with an HS inside each of them, and the scaler's line count goes
//  with it -- the picture loses rows at the top and bottom and the integer
//  scaling that CRT modes derive from it comes out far too small.
//
//  `video_de` is high for exactly 128 dots on exactly 128 lines and low
//  everywhere else, so the scaler is handed 128x128 pixels. The picture starts
//  at the frame origin, the way rtl/mc64_video.sv's does: the scaler anchors
//  its capture on the sync, so a picture inset from the origin is a picture
//  cropped on the right and bottom (H_OFF/V_OFF carry the whole story). RGB is
//  zero on every dot where DE is low.
//
//  WHY 150 x 250 AND NOT 128 x 128 AT 60 Hz. Two reasons, and the first one
//  cost this core two hardware builds.
//
//  1. THE LINE RATE. 128 x 128 with no blanking is 983,040 Hz of pixels, but
//     that is 7,680 Hz of LINES, and a scaler's CRT modes are built for a
//     television: rtl/mc64_video.sv runs 88 dots x 250 lines = 15 kHz exactly,
//     and the real GameTank console's own raster (rtl/gtvideo.sv) is 227 x 262
//     at 3.58 MHz = 15.7 kHz. A 9 kHz / 150-line signal (what this file had)
//     is outside that family, and the panel showed it: a mis-registered window
//     on the CRT modes and a picture that shrank to a square. 150 x 250 keeps
//     mc64's line count and line rate and only widens the line to fit 128.
//
//  2. THE PLL. The Pocket's PLL has a VCO floor of 600 MHz and a 512 output
//     counter, so 983,040 Hz cannot be made at all. 2,250,000 Hz can: it is
//     74.25 MHz / 33 exactly, an integer division with no fractional-N.
//
//  The pixel clock is its own PLL output (rtl/mf_pll_gt_video.v), not a
//  division of the console's 28.636364 MHz. The two domains meet only at the
//  frame store above, which is a genuine dual-clock RAM.
//
//  APF PIN FORMAT, identical to mc64_video's because that part is proven on
//  the panel: RGB565 LEFT-ALIGNED in the 24-bit word -- red[23:19] (5 bits,
//  low three of the byte zero), green[15:10] (6 bits, low two zero),
//  blue[7:3] (5 bits, low three zero) -- video_de a LEVEL over the active
//  rectangle, video_hs/video_vs LEVELS during blanking, all four registered
//  on the same edge so a pixel's colour can never disagree with its syncs.
//
//  LATENCY, and why the syncs are delayed three times: address (cycle k) ->
//  BRAM read (k+1) -> palette ROM (k+2) -> output register (k+3). rgb, de,
//  hs and vs are latched in the last stage together, so one pixel leaves the
//  core as one pixel three ce periods after its address was presented. The
//  top level delays video_ce by the same three so the scaler samples the
//  window the syncs describe. (This is one stage longer than mc64_video's
//  path: that one decodes the palette combinationally, this one's palette is
//  a registered ROM in BRAM.)
//============================================================================

module gt_video #(
    // ---- geometry, in pixel periods (mc64_video's parameter names) ----
    parameter int H_ACT   = 128,   // picture width
    parameter int V_ACT   = 128,   // picture lines
    parameter int H_TOTAL = 150,   // 128 picture + 22 blank: mc64's 15 kHz line
    parameter int V_TOTAL = 250,   // 128 picture + 122 blank: mc64's 250 lines
    parameter int HS_END  = 150,   // HS: one dot, H_TOTAL-2, every line
    parameter int VS_END  = 250,   // VS: one dot, on the frame's last line

    /* WHERE THE PICTURE SITS INSIDE THE LINE AND THE FRAME (2026-10-29).
     *
     * THE ORIGIN. These were 4 and 2, on the theory that the panel wants a gap
     * between the HS and the DE that follows it; the picture then began four
     * dots into the line and two lines into the frame. That is a crop on real
     * hardware: the scaler anchors its capture on the SYNC, not on DE, so a
     * picture that starts four dots and two lines late loses exactly that much
     * at the right and the bottom -- "the top and bottom and a very small
     * amount of the sides are cut off", reported on the panel.
     *
     * What is proven on this panel is rtl/mc64_video.sv: DE from the first dot
     * of the frame, one HS on the last dot of the line, one VS on the last line
     * of the frame. That core's picture has never been cropped. So the picture
     * starts at the origin here too, and what the scaler needs is not a gap
     * BEFORE DE but the gap AFTER it: the picture ends at dot 127 with the HS
     * 35 dots later, and at line 127 with the VS 21 lines later. Those are the
     * gaps the platform's "no pulse inside DE" rule lives in.
     *
     * With the offsets at zero, the picture is what the frame's own coordinates
     * say it is: active for h < 128 and v < 128, black everywhere else. Whether
     * the scaler ends up counting from the sync or following DE, it captures
     * 128 x 128 pixels of picture.
     */
    parameter int H_OFF   = 0,
    parameter int V_OFF   = 0
) (
    // ---- clocks --------------------------------------------------------
    // Two domains, and they are genuinely two on the Pocket: the console's
    // 28.636364 MHz and the PLL's 1.350000 MHz pixel clock. In simulation
    // gametank.sv ties both to clk_sys and drives `ce`, because there is no
    // PLL to divide there; the arithmetic (and the frame store, which is the
    // only thing that crosses) is the same.
    input  logic        clk_sys,    // console domain: the picture tap
    input  logic        clk_pix,    // video domain: raster, read, output
    input  logic        ce,         // one pulse per pixel period (1 = clk_pix
                                    // IS the pixel clock, as on hardware)
    input  logic        reset,

    // ---- picture tap from gtvideo (console domain) ----------------------
    // Registered in gtvideo: pic_we is one clk_sys pulse per visible pixel,
    // with pic_x/pic_y/pic_index valid on it. pic_we is asynchronous to this
    // clock off a PLL, which is safe here because pic_we is a one-cycle
    // strobe: worst case it lands on the setup edge of one ce and is missed,
    // leaving that pixel as it was in the page from the previous frame --
    // a single stray pixel, not a tear (the page is not scanned until the
    // whole console frame has landed).
    input  logic        pic_we,
    input  logic [6:0]  pic_x,
    input  logic [6:0]  pic_y,
    input  logic [7:0]  pic_index,

    /* THE FIVE ROWS THE CONSOLE NEVER SCANS (2026-10-29).
     *
     * gtvideo's raster is 262 lines with 16 of vertical blank, and every
     * framebuffer row is scanned on TWO lines (16+2r, 17+2r), so rows 123..127
     * are never fetched at all and the frame store never hears about them.
     * That is faithful to the console -- a CRT never showed them either -- but
     * this stage is handing the scaler a 128-line picture, and the bottom five
     * of those lines were left at whatever the RAM powered up as: a dark band
     * under a picture whose own background is not palette entry 0.
     *
     * So the rows the console skips are read out of the frame snapshot itself
     * during vertical blank (rl/gametank.sv drives these three ports) and land
     * in both pages of the store, which is what makes the output the whole
     * 128x128 framebuffer rather than 123 rows and a band.
     */
    input  logic        tail_we,
    input  logic [14:0] tail_addr,   // {page, row, x}: 123..127 reached directly
    input  logic [7:0]  tail_index,
    input  logic        frame_sync, // console vsync level (vsync_nmi); the
                                    // rising edge is the frame boundary

    /* TV MASK, from pocket/interact.json via core_top. The console's picture
     * is 128 lines, but a real television only showed the middle 100: rows
     * 0..13 and 114..127 are overscan. With this bit set, those rows carry no
     * active data, so the scaler captures a 128x100 window and the rows arrive
     * as black border. The raster, HS and VS do not move -- the scaler must
     * keep locking to the same 250-line, 60 Hz frame. */
    input  logic        tv_mask,

    // ---- APF video ------------------------------------------------------
    output logic [23:0] video_rgb,
    output logic        video_de,
    output logic        video_hs,
    output logic        video_vs,

    // ---- one pulse per completed scanout frame (video domain) -----------
    output logic        frame_end
);

// ---------------------------------------------------------------------------
// The frame store: two 128x128 pages of palette indices, 16 KB each
//
// One write port in the console's clock domain, one read port in the video
// domain, so it infers as a simple dual-port M10K (two clocks, write-first on
// the write side only). The writer fills the page that is not being scanned;
// the reader walks the page that is.
//
// WHICH PAGE, ACROSS THE TWO DOMAINS. Only two single-bit levels cross, and
// neither is a bus:
//
//   frame_tog   console domain, toggles once per console frame. It is the
//               "a whole frame just landed" flag; the video domain syncs it
//               through two flops and compares it with what it last consumed.
//   wr_page     console domain, toggles at the same moment (the console's
//               vsync = the start of its next frame). It is the page the
//               console is filling RIGHT NOW, so the page that is complete --
//               and the only one safe to scan -- is ~wr_page.
//
// So the flip is `rd_page <= ~wr_page_sync`, and it happens at a scanout frame
// end only when frame_tog_sync says a new console frame arrived. Nothing is
// torn: the page being scanned is never the page being written, and a flip is
// always to a page whose last write was a whole console frame ago. wr_page
// starts at 1 so that page 0, which the console has not filled yet, is the one
// scanned out of reset.
// ---------------------------------------------------------------------------
logic [7:0] fb [0:32767];

logic wr_page = 1'b1;       // console domain
logic frame_tog = 1'b0;     // console domain

// frame_sync is a LEVEL, not a strobe: gtvideo's vsync_nmi is high for the
// first eight clk_sys of line 0 (that is the shape the ACP's NMI wants). Take
// its rising edge, or toggling on the level would flip the page eight times
// and land back where it started.
logic frame_sync_d = 1'b0;
wire  frame_start  = frame_sync & ~frame_sync_d;

/* THE STORE IS NOT INITIALISED BY THE FPGA, SO IT IS CLEARED HERE.
 *
 * M10K contents at power-up are undefined, and until the console completes its
 * first frame the raster scans page 0 -- which nothing has written. That is the
 * panel's "first cartridge after power-on shows a block pattern" report: not
 * the game, not a timing fault, the RAM's power-up value being displayed
 * through the palette. The clear runs on this port only while nothing else is
 * using it (no picture strobe, no tail fill), which is all of the reset window
 * the machine spends waiting for a download: 32,768 bytes at 28.6 MHz is 1.1 ms
 * against a boot window of ~7 ms. It stops at the first picture strobe, so it
 * can never fight the console for the port, and `clr_done` never re-arms. */
logic [14:0] clr_cnt  = 15'h0;
logic        clr_done = 1'b0;

always_ff @(posedge clk_sys) begin
    frame_sync_d <= frame_sync;

    /* ONE WRITE PORT, ONE ADDRESS PER CLOCK. The picture tap owns it; the tail
     * fill takes a clock only when the tap has not asked for one. `tail_we` is
     * a level that rtl/gametank.sv's fill raises while its phase is "write",
     * and that fill advances only in the same clocks this test passes -- both
     * look at `pic_we` in the same clock, so a tail write can never be dropped
     * by a tap write landing in the same cycle, and the two can never present
     * two addresses in one clock.
     */
    if (pic_we) begin
        fb[{wr_page, pic_y, pic_x}] <= pic_index;
        clr_done <= 1'b1;      // the console is drawing: the clear loses
    end
    else if (tail_we)
        fb[tail_addr] <= tail_index;
    else if (!clr_done) begin
        fb[clr_cnt] <= 8'h00;
        if (clr_cnt == 15'h7FFF) clr_done <= 1'b1;
        else                     clr_cnt  <= clr_cnt + 15'd1;
    end

    if (frame_start) begin
        wr_page   <= ~wr_page;
        frame_tog <= ~frame_tog;
    end
end

// video domain: the two cross-domain levels, and what has been consumed
logic rd_page   = 1'b0;
logic tog_s1 = 1'b0, tog_s2 = 1'b0, wr_s1 = 1'b0, wr_s2 = 1'b0;
logic tog_seen = 1'b0;

always_ff @(posedge clk_pix) begin
    tog_s1 <= frame_tog;
    tog_s2 <= tog_s1;
    wr_s1  <= wr_page;
    wr_s2  <= wr_s1;
end

wire new_console_frame = (tog_s2 != tog_seen);

// ---------------------------------------------------------------------------
// Raster (video domain)
// ---------------------------------------------------------------------------
logic [7:0] h = 8'd0;   // 0..H_TOTAL-1
logic [7:0] v = 8'd0;   // 0..V_TOTAL-1

wire h_last = (h == 8'(H_TOTAL - 1));
wire v_last = (v == 8'(V_TOTAL - 1));


/* THREE DOTS AHEAD: the address presented on this cycle is the pixel that
 * leaves the core three ce periods later (BRAM read, palette ROM, output
 * register). Reading `h + 3` -- wrapping at the end of the line, where it is
 * row N+1's first pixels -- puts pixel 0 of every line on the pin at dot 0
 * instead of dot 3. DE is computed from the same lookahead and then passes
 * through the same three stages as the pixel, so it is high for dots 0..127.
 *
 * Why it matters: a scaler that counts active dots from HS rather than
 * following DE sees three blank dots at the head of each line and loses the
 * last three columns at the right -- which is the "very small amount of the
 * sides" the panel reported. mc64_video's picture starts at the line origin
 * for the same reason.
 */
wire [8:0] h3    = {1'b0, h} + 9'd3;
wire       wrap3 = (h3 >= 9'(H_TOTAL));
wire [7:0] ha    = wrap3 ? 8'(h3[7:0] - 8'(H_TOTAL)) : h3[7:0];
wire [7:0] va    = wrap3 ? (v_last ? 8'd0 : v + 8'd1) : v;

// H_OFF/V_OFF are applied to the lookahead coordinate, so they still mean
// "where the picture sits" rather than "where the pipeline sits".
wire [7:0] px = ha - 8'(H_OFF);
wire [7:0] py = va - 8'(V_OFF);

wire de_now = (px < 8'(H_ACT)) && (py < 8'(V_ACT));

/* THE 14-ROW OVERSCAN BANDS (2026-11-11). `py` is the picture row the
 * lookahead address belongs to, so gating de_now here keeps the mask aligned
 * with the three-stage output pipeline below. Only DE is lowered; RGB is
 * already forced to zero wherever DE is low, and HS/VS stay exactly where the
 * scaler expects them. Rows 14..113 remain: 100 lines, 128x100. */
wire tv_overscan = (py < 8'd14) || (py > 8'd113);
wire de_act      = de_now & ~(tv_mask & tv_overscan);

/* ONE-CYCLE SYNC PULSES, PLACED THREE DOTS BEFORE THEY LEAVE THE CORE.
 *
 * HS goes out on dot H_TOTAL-2 of every line and VS on dot H_TOTAL-6 of the
 * frame's last line -- four dots ahead of that HS, three of them from the
 * requirement and one for margin. Both are one dot wide on the pin, which is
 * what the APF asks for (see the header).
 *
 * They are generated three dots early because the read pipeline below delays
 * every signal by three ce periods: a one-dot pulse raised here comes out on
 * the dot it was aimed at, still one dot wide. Generating them where they
 * have to appear would put them three dots late -- HS would straddle the line
 * boundary (one dot at the end of the line, two at the start of the next),
 * which is two HS pulses to a scaler that counts edges, not one.
 */
wire hs_now = (h == 8'(H_TOTAL - 5));
wire vs_now = (v == 8'(V_TOTAL - 1)) && (h == 8'(H_TOTAL - 9));

always_ff @(posedge clk_pix) begin
    if (reset) begin
        h <= 8'd0;
        v <= 8'd0;
    end
    else if (ce) begin
        if (h_last) begin
            h <= 8'd0;
            v <= v_last ? 8'd0 : v + 8'd1;
        end
        else
            h <= h + 8'd1;
    end
end

always_ff @(posedge clk_pix) begin
    if (reset)
        frame_end <= 1'b0;
    else
        frame_end <= ce && h_last && v_last;
end

// Page flip at the end of a scanout frame, but only with a whole console
// frame waiting: repeating a frame is invisible, showing half of one is not.
always_ff @(posedge clk_pix) begin
    if (reset)
        tog_seen <= 1'b0;
    else if (ce && h_last && v_last && new_console_frame) begin
        rd_page  <= ~wr_s2;
        tog_seen <= tog_s2;
    end
end

// ---------------------------------------------------------------------------
// Read pipeline: page -> palette ROM -> APF word (three ce periods)
// ---------------------------------------------------------------------------
/* CLAMPED, because the lookahead runs past the picture: at dots H_TOTAL-3..
 * H_TOTAL-1 the address is the NEXT line's first pixels, and on the blank
 * lines of the frame `va` is 128..249 -- rows that are not in the 128-row
 * store. Truncating those to 7 bits aliased them onto real rows (harmless to
 * the picture, since DE is low and RGB is forced to zero there, but it is not
 * an address the RAM has and it should not be presented as one). */
wire [6:0] src_x = (ha < 8'(H_ACT)) ? ha[6:0] : 7'd0;
wire [6:0] src_y = (va < 8'(V_ACT)) ? va[6:0] : 7'd0;

logic [7:0]  rd_index;
logic [23:0] pal_rgb;

always_ff @(posedge clk_pix)
    if (ce)
        rd_index <= fb[{rd_page, src_y, src_x}];

palette u_palette
(
    .clk   (clk_pix),
    .ce    (ce),
    .index (rd_index),
    .rgb   (pal_rgb)
);

// syncs, walk down with the pixel: three ce periods from address to pin
logic de_1 = 1'b0, hs_1 = 1'b0, vs_1 = 1'b0;
logic de_2 = 1'b0, hs_2 = 1'b0, vs_2 = 1'b0;

always_ff @(posedge clk_pix) begin
    if (reset) begin
        video_rgb <= 24'h0;
        video_de  <= 1'b0;
        video_hs  <= 1'b0;
        video_vs  <= 1'b0;
        de_1 <= 1'b0; hs_1 <= 1'b0; vs_1 <= 1'b0;
        de_2 <= 1'b0; hs_2 <= 1'b0; vs_2 <= 1'b0;
    end
    else if (ce) begin
        /* stage 3: the pixel whose address went out three enables ago.
         *
         * RGB IS ZERO WHENEVER DE IS LOW (2026-10-28). The platform's rule, from
         * sim/tb_video.cpp: "a nonzero word outside the picture is either a held
         * colour or an end-of-line command (a scaler-slot switch request), and
         * neither belongs on this link." This module used to put the palette's
         * answer on the pins for the whole line, blanking included -- 37 dots of
         * command words per line to a scaler that reads them as instructions.
         * The pair is registered together, so `de_2` is the level `video_de` is
         * about to take and the colour that goes with it.
         */
        video_rgb <= !de_2    ? 24'h00_00_00
                              : {pal_rgb[23:19], 3'b000,
                                 pal_rgb[15:10], 2'b00,
                                 pal_rgb[7:3],   3'b000};
        video_de  <= de_2;
        video_hs  <= hs_2;
        video_vs  <= vs_2;

        de_2 <= de_1;  hs_2 <= hs_1;  vs_2 <= vs_1;
        de_1 <= de_act; hs_1 <= hs_now; vs_1 <= vs_now;
    end
end

endmodule
