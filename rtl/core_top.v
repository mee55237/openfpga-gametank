//============================================================================
//  core_top -- the APF wrapper around the GameTank console (rtl/gametank.sv).
//
//  apf_top instantiates this by name, so the port list is the platform's and is
//  unchanged from the Minicube64 core this tree grew from.
//============================================================================

module core_top (

    //
    // physical connections
    //

    ///////////////////////////////////////////////////
    // clock inputs 74.25mhz. not phase aligned, so treat these domains as asynchronous

    input wire clk_74a,  // mainclk1
    input wire clk_74b,  // mainclk1

    ///////////////////////////////////////////////////
    // cartridge interface
    // switches between 3.3v and 5v mechanically
    // output enable for multibit translators controlled by pic32

    // GBA AD[15:8]
    inout  wire [7:0] cart_tran_bank2,
    output wire       cart_tran_bank2_dir,

    // GBA AD[7:0]
    inout  wire [7:0] cart_tran_bank3,
    output wire       cart_tran_bank3_dir,

    // GBA A[23:16]
    inout  wire [7:0] cart_tran_bank1,
    output wire       cart_tran_bank1_dir,

    // GBA [7] PHI#
    // GBA [6] WR#
    // GBA [5] RD#
    // GBA [4] CS1#/CS#
    //     [3:0] unwired
    inout  wire [7:4] cart_tran_bank0,
    output wire       cart_tran_bank0_dir,

    // GBA CS2#/RES#
    inout  wire cart_tran_pin30,
    output wire cart_tran_pin30_dir,
    // when GBC cart is inserted, this signal when low or weak will pull GBC /RES low with a special circuit
    // the goal is that when unconfigured, the FPGA weak pullups won't interfere.
    // thus, if GBC cart is inserted, FPGA must drive this high in order to let the level translators
    // and general IO drive this pin.
    output wire cart_pin30_pwroff_reset,

    // GBA IRQ/DRQ
    inout  wire cart_tran_pin31,
    output wire cart_tran_pin31_dir,

    // infrared
    input  wire port_ir_rx,
    output wire port_ir_tx,
    output wire port_ir_rx_disable,

    // GBA link port
    inout  wire port_tran_si,
    output wire port_tran_si_dir,
    inout  wire port_tran_so,
    output wire port_tran_so_dir,
    inout  wire port_tran_sck,
    output wire port_tran_sck_dir,
    inout  wire port_tran_sd,
    output wire port_tran_sd_dir,

    ///////////////////////////////////////////////////
    // cellular psram 0 and 1, two chips (64mbit x2 dual die per chip)
    // Minicube64 has a flat 64 KB inside the FPGA and uses none of it.

    output wire [21:16] cram0_a,
    inout  wire [ 15:0] cram0_dq,
    input  wire         cram0_wait,
    output wire         cram0_clk,
    output wire         cram0_adv_n,
    output wire         cram0_cre,
    output wire         cram0_ce0_n,
    output wire         cram0_ce1_n,
    output wire         cram0_oe_n,
    output wire         cram0_we_n,
    output wire         cram0_ub_n,
    output wire         cram0_lb_n,

    output wire [21:16] cram1_a,
    inout  wire [ 15:0] cram1_dq,
    input  wire         cram1_wait,
    output wire         cram1_clk,
    output wire         cram1_adv_n,
    output wire         cram1_cre,
    output wire         cram1_ce0_n,
    output wire         cram1_ce1_n,
    output wire         cram1_oe_n,
    output wire         cram1_we_n,
    output wire         cram1_ub_n,
    output wire         cram1_lb_n,

    ///////////////////////////////////////////////////
    // sdram, 512mbit 16bit -- unused

    output wire [12:0] dram_a,
    output wire [ 1:0] dram_ba,
    inout  wire [15:0] dram_dq,
    output wire [ 1:0] dram_dqm,
    output wire        dram_clk,
    output wire        dram_cke,
    output wire        dram_ras_n,
    output wire        dram_cas_n,
    output wire        dram_we_n,

    ///////////////////////////////////////////////////
    // sram, 1mbit 16bit -- unused

    output wire [16:0] sram_a,
    inout  wire [15:0] sram_dq,
    output wire        sram_oe_n,
    output wire        sram_we_n,
    output wire        sram_ub_n,
    output wire        sram_lb_n,

    ///////////////////////////////////////////////////
    // vblank driven by dock for sync in a certain mode

    input wire vblank,

    ///////////////////////////////////////////////////
    // i/o to 6515D breakout usb uart

    output wire dbg_tx,
    input  wire dbg_rx,

    ///////////////////////////////////////////////////
    // i/o pads near jtag connector user can solder to

    output wire user1,
    input  wire user2,

    ///////////////////////////////////////////////////
    // RFU internal i2c bus

    inout  wire aux_sda,
    output wire aux_scl,

    ///////////////////////////////////////////////////
    // RFU, do not use
    output wire vpll_feed,


    //
    // logical connections
    //

    ///////////////////////////////////////////////////
    // video, audio output to scaler
    output wire [23:0] video_rgb,
    output wire        video_rgb_clock,
    output wire        video_rgb_clock_90,
    output wire        video_de,
    output wire        video_skip,
    output wire        video_vs,
    output wire        video_hs,

    output wire audio_mclk,
    input  wire audio_adc,
    output wire audio_dac,
    output wire audio_lrck,

    ///////////////////////////////////////////////////
    // bridge bus connection
    // synchronous to clk_74a
    output wire        bridge_endian_little,
    input  wire [31:0] bridge_addr,
    input  wire        bridge_rd,
    output reg  [31:0] bridge_rd_data,
    input  wire        bridge_wr,
    input  wire [31:0] bridge_wr_data,

    ///////////////////////////////////////////////////
    // controller data
    //
    // key bitmap:
    //   [0]    dpad_up
    //   [1]    dpad_down
    //   [2]    dpad_left
    //   [3]    dpad_right
    //   [4]    face_a
    //   [5]    face_b
    //   [6]    face_x
    //   [7]    face_y
    //   [8]    trig_l1
    //   [9]    trig_r1
    //   [10]   trig_l2
    //   [11]   trig_r2
    //   [12]   trig_l3
    //   [13]   trig_r3
    //   [14]   face_select
    //   [15]   face_start
    // joy values - unsigned
    //   [ 7: 0] lstick_x
    //   [15: 8] lstick_y
    //   [23:16] rstick_x
    //   [31:24] rstick_y
    // trigger values - unsigned
    //   [ 7: 0] ltrig
    //   [15: 8] rtrig
    //
    input wire [15:0] cont1_key,
    input wire [15:0] cont2_key,
    input wire [15:0] cont3_key,
    input wire [15:0] cont4_key,
    input wire [31:0] cont1_joy,
    input wire [31:0] cont2_joy,
    input wire [31:0] cont3_joy,
    input wire [31:0] cont4_joy,
    input wire [15:0] cont1_trig,
    input wire [15:0] cont2_trig,
    input wire [15:0] cont3_trig,
    input wire [15:0] cont4_trig
);

  // ===========================================================================
  //  GameTank for the Analogue Pocket.
  //
  //  rtl/gametank.sv is the console -- 65C02 + VIA, blitter, ACP, pads, video
  //  controller and cartridge -- and this file is the platform around it: two
  //  PLLs, the Pocket's bridge, the cartridge download, the pads and the
  //  audio/video pins. Nothing in here changes what the console does.
  //
  //  Its Minicube64 ancestor (rtl/core_top_mc64.v) is the same wrapper around a
  //  different machine, and the parts that are platform knowledge rather than
  //  machine knowledge are reused as they were: the PLL-lock and boot-timer
  //  handshake, the reset command, the bridge command block, and -- the one
  //  that cost two flashes on that core -- the cartridge loader's FIFO.
  // ===========================================================================

  // ------------------------------------------------------------------ tie-offs
  assign port_ir_tx              = 0;
  assign port_ir_rx_disable      = 1;

  // Little-endian: the first file byte of each bridge word is in [7:0].
  assign bridge_endian_little    = 1;

  assign cart_tran_bank3         = 8'hzz;
  assign cart_tran_bank3_dir     = 1'b0;
  assign cart_tran_bank2         = 8'hzz;
  assign cart_tran_bank2_dir     = 1'b0;
  assign cart_tran_bank1         = 8'hzz;
  assign cart_tran_bank1_dir     = 1'b0;
  assign cart_tran_bank0         = 4'hf;
  assign cart_tran_bank0_dir     = 1'b1;
  assign cart_tran_pin30         = 1'b0;
  assign cart_tran_pin30_dir     = 1'bz;
  assign cart_pin30_pwroff_reset = 1'b0;
  assign cart_tran_pin31         = 1'bz;
  assign cart_tran_pin31_dir     = 1'b0;

  assign port_tran_so            = 1'bz;
  assign port_tran_so_dir        = 1'b0;
  assign port_tran_si            = 1'bz;
  assign port_tran_si_dir        = 1'b0;
  assign port_tran_sck           = 1'bz;
  assign port_tran_sck_dir       = 1'b0;
  assign port_tran_sd            = 1'bz;
  assign port_tran_sd_dir        = 1'b0;

  // chip 1, the DRAM and the SRAM are not fitted to this core
  assign cram1_a                 = 6'h0;
  assign cram1_dq                = {16{1'bZ}};
  assign cram1_clk               = 0;
  assign cram1_adv_n             = 1;
  assign cram1_cre               = 0;
  assign cram1_ce0_n             = 1;
  assign cram1_ce1_n             = 1;
  assign cram1_oe_n              = 1;
  assign cram1_we_n              = 1;
  assign cram1_ub_n              = 1;
  assign cram1_lb_n              = 1;

  assign dram_a                  = 13'h0;
  assign dram_ba                 = 2'h0;
  assign dram_dq                 = {16{1'bZ}};
  assign dram_dqm                = 2'h3;
  assign dram_clk                = 0;
  assign dram_cke                = 0;
  assign dram_ras_n              = 1;
  assign dram_cas_n              = 1;
  assign dram_we_n               = 1;

  assign sram_a                  = 17'h0;
  assign sram_dq                 = {16{1'bZ}};
  assign sram_oe_n               = 1;
  assign sram_we_n               = 1;
  assign sram_ub_n               = 1;
  assign sram_lb_n               = 1;

  assign dbg_tx                  = 1'bZ;
  assign user1                   = 1'bZ;
  assign aux_scl                 = 1'bZ;
  assign vpll_feed               = 1'bZ;

  // the scaler is fed one picture at the frame origin and nothing else
  assign video_skip              = 1'b0;

  // ------------------------------------------------------------------- clocks
  //
  // TWO PLLs, and they are unrelated. The console gets 28.636364 MHz (the NTSC
  // colour subcarrier x 8); the picture gets 2.25 MHz, which is 150 x 250 x
  // 60 Hz -- 128 x 128 of picture, a 15 kHz line and the blanking the scaler
  // needs around it
  // (rtl/gt_video.sv has the arithmetic). Neither is chosen to divide out of the
  // other: the frame store in rtl/gt_video.sv is a genuine dual-clock RAM and
  // the only place they meet. See rtl/mf_pll_gt_console.v and
  // rtl/mf_pll_gt_video.v.

  wire        clk_core;      // 28.636364 MHz console
  // The console PLL's second output is no longer the audio clock: the I2S is
  // generated in clk_74a at exactly 48.000 kHz (see rtl/gt_audio.sv), so its
  // 12.272727 MHz is left unconnected rather than divided into 47.94 kHz.
  wire        clk_pix;       // 2.25 MHz, one pixel per cycle
  wire        clk_pix_90;    // ... +90 degrees, for the DDR launch
  wire        pll_locked_c, pll_locked_v, pll_locked;

  // A real reset for both PLLs: held for ~14 us after configuration. Quartus
  // warns (and is right to) when a PLL's rst is tied off -- a PLL that loses
  // lock can only re-acquire it through this pin -- so the pulse is REPEATED
  // every ~56 ms while the lock is missing (14 us of stopped clocks out of 56 ms
  // is a duty cycle the machine cannot feel, and it only happens when a lock is
  // already gone). One pulse at configuration covers the ordinary case; the
  // repeat is the difference between a lock lost to a transient coming back by
  // itself and a core that stays dead until the power is cycled. Nothing here
  // fires while the lock is good.
  reg [9:0]  pll_rst_cnt = 10'h3FF;
  reg [21:0] pll_retry   = 22'h0;
  wire       pll_rst     = (pll_rst_cnt != 10'h0);

  /* ONE PLL'S RESET IS NOT THE OTHER'S BUSINESS (2026-10-25).
   *
   * The panel: a save state completes -- the .sta on the card is 596 bytes of
   * Pocket header plus the entire 36,920-byte blob, tag 36,912, `saves 1`,
   * `drops 0`, `resets 0` -- and then the screen goes black, the backlight
   * cycles and the Pocket reloads the core. A save is the biggest sustained
   * burst of bus activity this core makes (~8 ms of the engine walking 36 KB
   * while the machine is held), so it is also the moment a marginal lock on the
   * console PLL is most likely to drop.
   *
   * Until now a single `pll_rst` drove BOTH PLLs' rst pins. So a console-clock
   * glitch -- which only means "the machine stopped" and is recoverable -- also
   * held the VIDEO PLL in reset: clk_pix stops, the picture dies, `scal_vs`/
   * `scal_de` stop toggling, and the Pocket's scaler sees a dead video link and
   * does what it does with one -- terminates the core and reloads it. That is
   * precisely "black screen, backlight cycling, reboot", and it is precisely
   * the moment the file is already on the card.
   *
   * Each PLL now resets only itself, and only while ITS OWN lock is missing. A
   * console PLL that dies for 56 ms still gets the retry pulse above and comes
   * back; meanwhile the frame store keeps scanning out the last complete frame
   * from the video PLL (it is a dual-clock RAM with its own port), so the
   * picture freezes for that moment instead of vanishing. A dead picture is not
   * recoverable from inside the core; a frozen one is.
   *
   * AND THE VIDEO PLL IS NEVER RESET AFTER IT HAS LOCKED (2026-10-28). The
   * split above stopped the CONSOLE's lock from resetting the video PLL, but
   * the video PLL's own `locked` pin still drove its own `rst` -- and that is
   * the one recovery action this core cannot survive. `pll_rst_v` holds the PLL
   * in reset for 1,023 clk_74a (14 us), during which `clk_pix` stops: there are
   * no DE/HS/VS edges at all, so the Pocket's scaler loses the video link and
   * does what it does with a dead one -- terminates the core and reloads it.
   *
   * That is the same failure the split was meant to prevent, reached from the
   * other side, and it is reachable by a one-cycle glitch: a PLL lock detector
   * may drop and re-assert (this file already relies on that being possible --
   * `pll_locked_sticky` exists for it), and here such a report does not just
   * mislead a status bit, it turns the picture off. The save-state file on the
   * card is the shape of the result: a complete, correct 36,920-byte blob in a
   * 596-byte APF container, and then nothing -- the OS died before it could
   * append the 52,764-byte screen capture it takes next, because the screen it
   * was about to capture had gone away.
   *
   * A video PLL that has genuinely stopped cannot be brought back this way
   * anyway: the scaler has already terminated the core, so the retry pulse
   * resets a dead design. A video PLL that has NOT stopped must not be
   * touched. So the video side gets the sticky gate and the console side keeps
   * its retry -- a stopped console is a machine that can come back, a stopped
   * picture is a core that cannot. */
  wire       pll_rst_c  = pll_rst & ~pll_locked_c;

  // The video PLL's own lock, sticky: the reset pulse above is allowed only
  // until the clock has locked ONCE. Sampled on clk_74a, which is its own
  // reference, so this is a two-flop synchroniser and not a clock crossing.
  reg pll_locked_v_s1 = 1'b0;
  reg pll_locked_v_s2 = 1'b0;
  reg [7:0]  pll_v_lock_run = 8'h0;
  reg        pll_v_sticky   = 1'b0;

  always @(posedge clk_74a) begin
    pll_locked_v_s1 <= pll_locked_v;
    pll_locked_v_s2 <= pll_locked_v_s1;

    // 256 consecutive samples, the same filter `pll_locked_sticky` uses: one
    // good sample is not a lock, and the gate it opens is permanent.
    if (pll_locked_v_s2) begin
      if (pll_v_lock_run != 8'hFF)
        pll_v_lock_run <= pll_v_lock_run + 8'd1;
      else
        pll_v_sticky <= 1'b1;
    end else
      pll_v_lock_run <= 8'h0;
  end

  wire       pll_rst_v  = pll_rst & ~pll_v_sticky;

  always @(posedge clk_74a) begin
    if (pll_rst_cnt != 10'h0)
      pll_rst_cnt <= pll_rst_cnt - 10'd1;

    if (!pll_locked) begin
      if (pll_retry == 22'h3F_FFFF) begin    // ~56 ms at 74.25 MHz
        pll_retry   <= 22'h0;
        pll_rst_cnt <= 10'h3FF;               // the pulse above, again
      end else
        pll_retry <= pll_retry + 22'd1;
    end else
      pll_retry <= 22'h0;
  end

  assign pll_locked = pll_locked_c & pll_locked_v;

  assign video_rgb_clock    = clk_pix;
  assign video_rgb_clock_90 = clk_pix_90;

  mf_pll_gt_console pll_console (
      .refclk   (clk_74a),
      .rst      (pll_rst_c),
      .outclk_0 (clk_core),
      .outclk_1 (),
      .locked   (pll_locked_c)
  );

  mf_pll_gt_video pll_video (
      .refclk   (clk_74a),
      .rst      (pll_rst_v),
      .outclk_0 (clk_pix),
      .outclk_1 (clk_pix_90),
      .locked   (pll_locked_v)
  );

  // The lock is asynchronous to clk_74a even though clk_74a is its reference,
  // so it is sampled into the bridge's own domain before anything uses it.
  reg pll_locked_s1 = 1'b0;
  reg pll_locked_s2 = 1'b0;

  always @(posedge clk_74a) begin
    pll_locked_s1 <= pll_locked;
    pll_locked_s2 <= pll_locked_s1;
  end

  /* ---- and the lock, LATCHED, for everything that holds this core down ----
   *
   * `pll_locked` is a LIVE level, and a lock detector on a fractional-N PLL can
   * drop for a few reference cycles and re-assert. This core used to build
   * BOTH of its releases out of that live level -- `reset_74a` for the whole
   * APF side (the bridge, the save-state controller, the loader, the audio) and
   * the machine's own reset -- so a glitch undid everything in flight.
   *
   * C:/Code/Minicube64 found this on this panel and wrote it down in its own
   * source: "run_core = pll_locked && por_done && cart_ready" meant "every
   * glitch of the lock reset the whole machine: run_core dropped, the POR window
   * restarted, the machine fell back to its held picture -- a picture that
   * flickers instead of a machine that runs, with a perfect bitstream, a locked
   * PLL and every harness green." Its answer, and now this core's, is the split
   * it documents there: the live level is for reporting (the OS status bits, the
   * debug tap), a latched level is for holding anything down.
   *
   * WHAT IT COSTS ON THE PANEL WHEN IT IS WRONG, and this is the report that put
   * this comment here (2026-10-25, "saves crash the APF and the Pocket itself"):
   * a save state is the one flow that leaves the OS polling 0x00A0 for a final
   * code AFTER the biggest burst of current this core draws (8,711 words out of
   * PSRAM in a few milliseconds). A lock glitch inside that window asserted
   * `reset_74a`, which clears `ss_start_ok`/`busy`/`err` in
   * rtl/save_state_controller.sv to "none of the above" -- and core_bridge_cmd
   * turns that into result code 0, which is not one of the three the OS waits
   * for. The state file on the card is complete, the picture is fine, the game
   * is fine, and the menu spins until the OS gives up and cycles the backlight:
   * a save that "worked" and a Pocket that froze. Latched, a glitch costs one
   * frame of a stale lock report and nothing else. A PLL that is genuinely down
   * is not hidden by it -- every clock in the machine comes from it, and the
   * retry above keeps the reset pin working on it. */
  reg [7:0] pll_lock_run      = 8'h0;
  reg       pll_locked_sticky = 1'b0;

  // 256 CONSECUTIVE samples, not one: a config-time blip of `locked` is a real
  // thing too, and latching on a single sample would make a PLL that never
  // really locks look alive for the rest of the session -- the opposite of what
  // this latch is for. 256 clk_74a is 3.4 us, far shorter than any lock the
  // machine can use.
  always @(posedge clk_74a) begin
    if (pll_locked_s2) begin
      if (pll_lock_run != 8'hFF)
        pll_lock_run <= pll_lock_run + 8'd1;
      else
        pll_locked_sticky <= 1'b1;
    end else
      pll_lock_run <= 8'h0;
  end

  // ... and a timer on clk_74a reports the truth about the bridge even if the
  // PLLs never lock, so "no file list" and "dead video link" stay distinct.
  localparam [19:0] BOOT_WAIT_MAX = 20'h3FFFF;   // ~7 ms at 74.25 MHz

  reg  [19:0] boot_wait  = 20'h0;
  wire        boot_timer = (boot_wait == BOOT_WAIT_MAX);
  // Sticky, not live: see the note on pll_locked_sticky. The boot timer still
  // covers the one case sticky cannot -- a PLL that never locks at all -- so
  // the handshake happens and the panel can say which side is dead.
  wire        core_ready = pll_locked_sticky | boot_timer;

  always @(posedge clk_74a) begin
    if (!boot_timer)
      boot_wait <= boot_wait + 20'd1;
  end

  // -------------------------------------------------------------- host control

  reg [31:0] reset_delay = 0;

  always @(posedge clk_74a) begin
    if (reset_delay > 0)
      reset_delay <= reset_delay - 1;

    if (bridge_wr && bridge_addr == 32'h00000050)
      reset_delay <= 32'h100000;
  end

  wire external_reset = reset_delay > 0;

  wire [31:0] cmd_bridge_rd_data;

  // ---- save states ---------------------------------------------------------
  // The blob is 8,711 64-bit words: header + both CPUs' registers and
  // microcode + banking/dma_ctl + 68 KB of RAM. The buffer is the 0x4 window
  // (the OS reads and writes it there); `savestate_size` is the blob and
  // `savestate_maxloadsize` the largest file the OS will hand back.
  //
  // THE MAXIMUM IS NOT THE SIZE. It is the size PLUS 4 KB, which is the shape
  // agg23's NES controller (which runs states on this panel) declares, and the
  // slack is load-bearing in three places:
  //
  //   * the OS is allowed to hand back a file written by an earlier build, or
  //     one it padded itself. A declaration of exactly the state's size makes
  //     any such file a refusal BEFORE the engine can check its own header, so
  //     an older save is rejected as "foreign" rather than as "not this
  //     build's state";
  //   * the buffer is sized from this number, so the save's own copy (8,711
  //     words) no longer ends exactly where `save_full` rises. With the old
  //     equality that boundary was the ONLY thing keeping a save from being
  //     one word short, which is not a margin to ship;
  //   * the engine's transfer watchdog (rtl/gt_savestates.sv) can then be
  //     told a maximum in words that is strictly larger than any real state.
  // 8,714 words: header + both CPUs + the ACP + 32 KB of system RAM + 4 KB of
  // audio RAM + the 32 KB framebuffer + the 6522. The framebuffer is machine
  // state (the CPU reads it back through $4000); leaving it out made a load
  // resume with the previous screen wherever the game did not repaint
  // (2026-10-31). The VIA is machine state too -- it is how a game keeps time
  // without a frame clock -- and it went in on 2026-11-03.
  localparam [31:0] SS_BYTES    = 32'd69712;
  localparam [31:0] SS_MAX_LOAD = SS_BYTES + 32'd2048;   // 8,970 words
  localparam [31:0] SS_TAG      = 32'd69704;

  wire        ss_rd_hit;
  wire [31:0] ss_rd_data;

  /* THE WRITER'S FLYING LEADS ARE GONE WITH IT (2026-11-03). rtl/gt_save_file.sv
   * and every net it owned -- its 0x0300_0000 struct windows, its target-command
   * outputs, its [0180] restore, its interact hook -- are removed. The save path
   * is the platform's: the OS reads the Save data slot out at exit ([0080]) and
   * writes it back at launch ([0082]), and this core only serves that window.
   * See the note where the writer used to be, further down. */

  /* DECLARED HERE BECAUSE THE SAVE SLOT IS ABOVE THEM (2026-11-02).
   * The slot instance sits at the top of this file's APF section and the video
   * stage further down reads the cartridge's presence, while the loader reads
   * the capture FIFO's emptiness; both are produced below. A net declared later
   * in a module is visible to an instantiation earlier in it, but only if it is
   * DECLARED -- an implicit net would be a different one. */
  wire        cart_present;       // 1 once a .gtr is in PSRAM (rtl/cart.sv)
  wire        cf_empty;           // the cartridge capture FIFO has drained

  wire        savestate_start, savestate_load;
  wire        ss_start_ack, ss_start_busy, ss_start_ok, ss_start_err;
  wire        ss_load_ack, ss_load_busy, ss_load_ok, ss_load_err;
  wire        ss_save_tog, ss_load_tog, ss_abort_tog;
  wire        ss_busy, ss_load_done, ss_engine_err;
  wire [63:0] ss_save_data;
  wire        ss_save_wr, ss_save_full;
  wire        ss_load_rd, ss_load_empty;
  wire [63:0] ss_load_data;
  wire        ss_underrun, ss_overrun;

  assign ss_rd_hit = (bridge_addr[31:28] == 4'h4);

  /* ------------------------------------------------------------------ *
   * THE BLACK BOX (2026-10-25): five counters of the APF's side of a save,
   * carried in the 56 spare bits of the state's last special word.
   *
   * A save state is the only channel this core has to say anything after the
   * Pocket has crashed: the OS writes the .sta file to the card itself, and the
   * crash comes after it. So the file a failed save leaves behind now also
   * carries what the APF side went through -- and the next attempt's file
   * carries what the previous one did. Everything here is clk_74a, and every
   * one can be read off a .sta at byte 596 + 6x8, or with
   * tools/gt_sta_diag.py (see rtl/gt_savestates.sv's note on `diag`):
   *
   *   drops  the PLL's lock detector fell this many times AFTER it first
   *          locked. A fractional-N output's `locked` is the suspect; before
   *          2026-10-25 it also reset this whole side of the core.
   *   resets `core_ready` came back after the boot timer -- i.e. the APF side,
   *          the save controller included, was held in reset mid-session. With
   *          the latched lock in place this can no longer happen, so 0 is the
   *          EXPECTED value and this counter is the witness for it: anything
   *          else means something other than the lock is resetting that side.
   *   saves  load  0x00A0 / 0x00A4 commands the bridge has seen.
   *   code   the verdict of the newest COMPLETED command: {5'h0, err, ok,
   *          busy}. 2 = the core answered ok, 3 = it refused (see below for
   *          why the command-arrival sample this used to be was meaningless).
   *   reads  the 32-bit reads the host made of the 0x4 window since the
   *          PREVIOUS save command -- 17,422 is a whole state read out. This is
   *          what tells a read-out that stopped halfway from one that finished
   *          and was followed by a crash somewhere else.
   * ------------------------------------------------------------------ */
  /* `drops` and `resets` are 4 bits, not 8 (2026-11-01). Both exist to be ZERO
   * -- "the PLL never lost lock", "the APF side was never reset mid-session" --
   * so 15 is as good as 255, and the eight bytes they give up are what the save
   * file's own record below needs. `diag` stays 56 bits and the state's word 6
   * still carries all of it, so no .sta format changes. */
  reg [3:0] diag_drops  = 4'h0;
  reg [3:0] diag_resets = 4'h0;
  reg [7:0] diag_saves  = 8'h0;
  reg [7:0] diag_loads  = 8'h0;
  reg [7:0] diag_code   = 8'h0;
  /* THE TWO COUNTERS BELOW EXIST BECAUSE THE FIRST VERSION'S `code` WAS
   * USELESS, AND THE CARD'S OWN FILE SAID SO (2026-10-25, the 17:11 state).
   *
   * `diag_code` used to be sampled ON THE COMMAND'S EDGE -- i.e. in the cycle
   * before the controller has looked at the command at all -- so it recorded
   * the status the PREVIOUS command left, which for the first save of a session
   * is the reset value, `{err, ok, busy} = 0`. The card's state read exactly
   * that, and the tool has to print "NONE, the code the OS cannot use", which is
   * the one conclusion that is always wrong for a first save. A field that reads
   * "hang" on every clean save is worse than no field: it would have sent me
   * after the handshake for a third time.
   *
   * It is now the VERDICT OF THE NEWEST COMPLETED COMMAND -- captured where the
   * controller asserts it (`ok` or `err` rising), so 2 means the core answered
   * "done" and 3 means it answered "refused". Those are the only two answers
   * the OS acts on, and they are the two worth carrying off a crashed panel.
   *
   * `reads` is the number of 32-bit reads the host made of the 0x4 window SINCE
   * THE PREVIOUS SAVE COMMAND, latched into the word when a save command
   * arrives (and the live counter restarted). That is the one number that
   * separates "the OS stopped reading partway" from "the OS read every word and
   * died afterwards": a full state is 17,422 reads, and the next save's file
   * carries what the previous one's read-out actually reached. 16 bits because
   * 17,422 fits and the field has no more room.
   */
  reg [15:0] diag_reads    = 16'h0;   // ... of the previous save's read-out
  reg [15:0] reads_live    = 16'h0;   // ... of this session, since that save
  reg [25:0] rd_key_q      = 26'h3FF_FFFF;  // the window word last counted
  // 0, not 1: with 1 the first sampled cycle would compare against a lock that
  // never existed and count a phantom drop at power-on.
  reg       pll_locked_q = 1'b0;
  reg       core_ready_q = 1'b0;
  reg       ss_start_q   = 1'b0;
  reg       ss_load_q    = 1'b0;
  reg       ss_ok_q      = 1'b0;
  reg       ss_err_q     = 1'b0;
  reg       ss_lok_q     = 1'b0;
  reg       ss_lerr_q    = 1'b0;

  always @(posedge clk_74a) begin
    pll_locked_q <= pll_locked_s2;
    core_ready_q <= core_ready;
    ss_start_q   <= savestate_start;
    ss_load_q    <= savestate_load;
    ss_ok_q      <= ss_start_ok;
    ss_err_q     <= ss_start_err;
    ss_lok_q     <= ss_load_ok;
    ss_lerr_q    <= ss_load_err;

    if (pll_locked_q && !pll_locked_s2 && diag_drops != 4'hF)
      diag_drops <= diag_drops + 4'd1;

    if (core_ready_q && !core_ready && diag_resets != 4'hF)
      diag_resets <= diag_resets + 4'd1;

    /* ONE PER WORD, NOT PER BUS CYCLE. `bridge_rd` is a level the bridge holds
     * for both cycles of an access, so counting it per cycle counted every word
     * twice (the harness read 34,844 for a 17,422-word state, which is how this
     * was found). The key is the same one the controller keys its holding
     * register with -- bits [27:2], one per 32-bit word -- so a word read twice
     * is one read here too, exactly as it is one word there. */
    if (ss_rd_hit && bridge_rd && (bridge_addr[27:2] != rd_key_q))
      reads_live <= reads_live + 16'd1;

    rd_key_q <= bridge_addr[27:2];

    if (savestate_start & ~ss_start_q) begin
      // The previous save's read-out, then a fresh count for this one.
      diag_reads <= reads_live;
      reads_live <= 16'h0;
      rd_key_q   <= 26'h3FF_FFFF;   // the next read-out starts at its own word 0
      if (diag_saves != 8'hFF)
        diag_saves <= diag_saves + 8'd1;
    end

    if (savestate_load & ~ss_load_q) begin
      if (diag_loads != 8'hFF)
        diag_loads <= diag_loads + 8'd1;
    end

    // The verdict, where the controller gives it -- not at the command.
    if ((ss_start_ok & ~ss_ok_q) || (ss_start_err & ~ss_err_q))
      diag_code <= {5'h0, ss_start_err, ss_start_ok, ss_start_busy};
    else if ((ss_load_ok & ~ss_lok_q) || (ss_load_err & ~ss_lerr_q))
      diag_code <= {5'h0, ss_load_err, ss_load_ok, ss_load_busy};
  end

  wire [7:0]  save_diag = 8'h0;      // the core-side writer is gone (see above)

  wire [55:0] ss_diag = {diag_drops, diag_resets, diag_saves, diag_loads,
                         save_diag, diag_code, diag_reads};

  always @(*) begin
    if (ss_rd_hit)
      bridge_rd_data = ss_rd_data;
    else if (bridge_addr[31:24] == 8'h02)
      bridge_rd_data = ps_bridge_rdata;      // the Save data slot
    else if (bridge_addr[31:24] == 8'hF8)
      bridge_rd_data = cmd_bridge_rd_data;
    else
      bridge_rd_data = 32'h0;
  end

  wire reset_n;                 // host has taken us out of reset

  /* THE BRIDGE GOES QUIET WHEN THE HOST TAKES US DOWN (2026-11-02).
   *
   * "Exiting the core crashes." The quit sequence is [0010 Reset Enter] (and a
   * write to 0x50), and from that instant the OS is tearing the core down: it is
   * not answering target commands, it is not reading data slots, and it will not
   * answer either again. Anything still holding a conversation with it over the
   * bridge at that point is holding a conversation with nobody, and every attempt
   * at this quit so far left one behind -- a `cm` marker waiting for a reply, a
   * stream filling a FIFO for a reader that has gone, a writer waiting for a
   * `done` that is never coming.
   *
   * One level, then, means "the host is gone", and everything that talks to it is
   * cancelled from it rather than left to time out: rtl/core_bridge_cmd.v drops
   * its own target command (that is where the register lives), and the data-slot
   * write handshake is granted without waiting for the boot gate. Declared here,
   * above its use, because rtl/core_top.v is compiled as Verilog-2001: a use
   * before the declaration would be an implicit 1-bit net and a different
   * signal. */
  wire apf_quiesce = ~reset_n | external_reset;

  /* THE SAVE STREAM IS STARTED BY THE SHUTDOWN ITSELF (2026-11-03).
   *
   * `~reset_n` is `[0010 Reset Enter]`, which the OS sends FIRST at quit; the
   * save read-out (`[0080]`) follows it. Giving rtl/gt_save_slot.sv that edge
   * means the image is already moving when the OS asks for it, so the request
   * is answered instead of waited on -- and the wait is the one thing this core
   * can impose on the Pocket's shutdown that a stock core cannot (they tie
   * `dataslot_requestread_ack` to 1; this one waits for its first 2 KB).
   *
   * It is `~reset_n` and NOT `apf_quiesce`: the 0x50 write that comes AFTER the
   * read-out also raises `external_reset`, and re-arming there would throw the
   * window away in the middle of the OS reading it. `[0010]` is the edge that
   * is always before the transfer and never inside it. */
  wire sf_prearm = ~reset_n;

  // The data-slot write handshake, named so it can be probed (see the note at
  // its use, further down): the OS is told to stream only once the machine's
  // clock has a PLL behind it.
  /* ... AND IT IS GRANTED UNCONDITIONALLY ONCE THE HOST IS TAKING US DOWN
   * (2026-11-02).
   *
   * Same reasoning as the read ack below: `[0082]` waits for this to rise, and
   * `core_ready` is a boot gate. During a shutdown the OS may reload a slot
   * (data.json bit 7 / the "restart with new data" path in Analogue's Core Boot
   * Process), and a core that withholds this ack then leaves the OS waiting on
   * a handshake at the exact moment it is closing -- which is a black screen and
   * a power cycle. `apf_quiesce` is `[0010] Reset Enter` or the 0x50 hold, so
   * anything arriving after the goodbye is answered at once. The normal case is
   * untouched: `core_ready` still paces the launch download. */
  wire dataslot_reqwrite_ack = core_ready | apf_quiesce;

  wire dataslot_requestread;
  wire [15:0] dataslot_requestread_id;
  wire dataslot_requestwrite;
  wire [15:0] dataslot_requestwrite_id;
  wire [31:0] dataslot_requestwrite_size;
  wire dataslot_update;
  wire [15:0] dataslot_update_id;
  wire [31:0] dataslot_update_size;
  wire dataslot_allcomplete;

  wire osnotify_inmenu;
  wire osnotify_pause_req;

  /* THE WRITER STOPS AT THE FIRST SIGN OF A SHUTDOWN, NOT ONLY AT `[0010]`
   * (2026-11-02).
   *
   * `apf_quiesce` is `[0010] Reset Enter` plus a write to 0x50, and the whole
   * quit design leans on one of those arriving before the OS stops answering.
   * That is an assumption about the host's order, and the panel keeps saying it
   * is not always true: a core that is still issuing `[0184]` when the OS turns
   * away leaves `cm` in the target register of a framework that has stopped
   * running target commands, and the quit ends in a black screen that needs a
   * power cycle.
   *
   * So a second, earlier signal is added -- `[0080 Data slot request read]` on
   * the Save slot. Nothing but a shutdown reads a nonvolatile slot out: at
   * launch the OS WRITES that slot (`[0082]`), and the game never touches the
   * bridge at all. So the read-out IS the OS saying goodbye, and it arrives
   * before the reset does (Analogue's boot document: "on exit Pocket sends
   * [0080] to read out any nonvolatile data ... and the FPGA is reset shortly
   * afterwards").
   *
   * With this, there is no window left in which this core can be talking to a
   * host that has begun to close: `[0010]`, 0x50 and `[0080]` all cancel the
   * writer, and the slot's own stream -- which the OS is reading at that
   * moment and must keep -- is untouched by any of them. */

  // ---- the Save data slot (data slot 2, nonvolatile) --------------------
  //
  // A GameTank save is the cartridge image (see rtl/gt_save_slot.sv). The
  // slot's id and its position in data.json are different things: the OS
  // indexes the size table by the slot's POSITION, so this core writes the
  // slot's size at word 2*1+1 = 3 of the Dataslot ID/Size Table (slot 0 is the
  // cartridge). It is written continuously because the OS may clobber the same
  // word through the bridge, and this is the value it has to see when it reads
  // the slot out at shutdown. WHAT that value is -- and why it is a constant and
  // not `cart_size` -- is the note below, and it is the save crash.
  //
  // AND THE SLOT'S ID GATES NOTHING (2026-11-02). It used to, and each place it
  // did failed the same way when it did not match: silently and completely. The
  // address says which slot a word belongs to, so the id is no longer consulted
  // anywhere -- see the notes at `cart_decl_size` and `ps_slot2_seen`.

  /* THE SIZE IN THIS TABLE MUST NEVER CHANGE, AND THAT IS THE SAVE CRASH.
   * (2026-10-25, from the card's own files -- the first real evidence in three
   * days, and it was already on it.)
   *
   * THE EVIDENCE. Every .sta this core has ever written for a SMALL cartridge
   * is truncated at exactly 596 (Pocket header) + the state blob: tetris, a
   * 32 KB image, 17 attempts, all 37,516 or 70,284 bytes. The two .sta files
   * written for Kachi's Pond, a 2 MB image, are 123,048 bytes -- complete, with
   * the 52,764-byte block the OS appends after the blob (a 121x109x4 screen
   * capture, the same size in every core's .sta on this card). So the OS reads
   * the whole state, writes it to the card, and dies before appending that
   * block -- and it only ever dies for carts whose size is not 2 MB.
   *
   * THE MECHANISM. The only thing this core tells the OS about the cartridge is
   * this word, and until now it was `cart_size`: 32,768 for a 32 KB cart,
   * 2,097,152 for a 2 MB one. The OS writes the slot's declared maximum
   * (data.json's size_maximum, also 2 MB) into this table at boot, reads it
   * back "during a flush operation" and updates the file size on the card if it
   * changed (Analogue's host/target command spec, 0x2000-0x20FF). A save is a
   * flush -- it is the moment the OS writes to the SD card -- so for a 2 MB cart
   * the word reads back exactly what the OS wrote and nothing happens; for a
   * 32 KB cart it reads back 32,768 and the OS acts on the change while it is
   * finishing the .sta. It crashes there, before the screen capture, which is
   * the file we keep finding.
   *
   * THE RULE. What this word declares is the SLOT, not the cartridge: the .sav
   * is the 2 MB image region at PSRAM 0x100000 (rtl/gt_save_slot.sv streams the
   * whole of it), data.json declares that slot at 2 MB, and the OS wrote 2 MB
   * there itself. Declaring anything else would be the core telling the OS that
   * the save file changed size, which is a different operation with its own file
   * handling. */
  /* WHAT THIS WORD HAS TO BE, FOR THE SECOND TIME (2026-10-26).
   *
   * It went from `cart_size` to a constant 2 MB on the theory that the .sta
   * files truncated for SMALL cartridges were the OS reacting to a size change.
   * The theory is not what the host documentation says: *"When core is loaded,
   * Pocket will write the filesize as loaded. Core may update the value during
   * setup, idle, or run. Pocket will read the value back during a flush
   * operation and update the filesize on SD if it changed"* -- a revised size is
   * the documented mechanism, not an error path.
   *
   * And a constant 2 MB is actively wrong, in the way this tree has already paid
   * for once ("apf tetris dont work"): the .sav IS the cartridge image, so the
   * file's size is what the restore downloads, and rtl/cart.sv infers the
   * cartridge's type from that download's size. Declare 2 MB for a 32 KB
   * cartridge and the next boot restores its image as a 2 MB Flash2M part, with
   * the fixed bank at the wrong offset -- the game fails to boot.
   *
   * So it is the image's own size: what `cart.sv` actually received. Before a
   * download has told us anything the slot reads its maximum, which is what the
   * OS would write itself; the OS only reads this word again during a flush, by
   * which time the image has been downloaded and the value is the real one. */
  /* AND WHERE THAT SIZE COMES FROM, FOR THE THIRD TIME (2026-10-26, second pass).
   *
   * "What cart.sv actually received" was still a measurement, and this port
   * carries the .sav as well: the save IS a cartridge image, so a restore
   * writes one through the same download port the .gtr used. Measured, a 2 MB
   * .sav written into a 32 KB EEPROM game makes the image 2 MB -- `cart.sv`
   * infers Flash2M from that and the game stops booting ("apf tetris dont
   * work"), and this word then tells the OS the save is 2 MB, so the next save
   * is 2 MB as well and every boot after it measures 2 MB again. The mistake is
   * self-sustaining on the card.
   *
   * The OS declares the cartridge slot's size before its data moves ([0082 Data
   * slot request write] carries it), so the core keeps that number and hands it
   * to `rtl/cart.sv` as the cart's identity. The .sav's size can then never
   * reach the type inference or this table, whatever is on the card. */

  /* THE CARTRIDGE'S SIZE IS THE FIRST SLOT'S, NOT THE FIRST MATCHING ID'S
   * (2026-11-02).
   *
   * This used to compare the request's slot id, and the boot
   * doc settles why that is fragile: the APF "sends [0082 Data slot request
   * write] and loads all data slots in order" -- slot index 0 (the cartridge)
   * first, then slot index 1 (the save). So the FIRST [0082] after reset is the
   * cartridge's, whatever number the `id` field carries and whatever the host
   * puts in the parameter word. Every later one belongs to some other slot.
   *
   * Why it matters: `cart_decl_size` is the cartridge's IDENTITY to
   * rtl/cart.sv (a 32 KB EEPROM cart and a 2 MB flash cart are different
   * hardware), and the save slot's request carries the SAVE's size -- which
   * `size_maximum` makes 2 MB. If the id test misses slot 0 and lands on slot
   * 1 instead, this word becomes 2 MB on every boot: wrong for the cartridge,
   * and the Dataslot ID/Size Table then reports 2 MB back to the OS as the
   * .sav's size, so the file grows and never shrinks. The card shows exactly
   * that (Minicraft, tanks and multi are 2 MB; the two files written before
   * this path existed are 16 KB and 32 KB).
   *
   * Ordering is the one thing the APF guarantees here, so it is what is used. */
  reg [21:0] cart_decl_size = 22'd0;
  reg        cart_decl_seen = 1'b0;

  always @(posedge clk_74a) begin
    if (~core_ready) begin
      cart_decl_size <= 22'd0;
      cart_decl_seen <= 1'b0;
    end
    else if (dataslot_requestwrite && !cart_decl_seen) begin
      cart_decl_seen <= 1'b1;
      cart_decl_size <= dataslot_requestwrite_size[21:0];
    end
  end

  localparam [31:0] SAVE_SLOT_MAX = 32'd2097152;
  wire [31:0] save_slot_size = (cart_size != 22'd0) ? {10'd0, cart_size}
                                                    : SAVE_SLOT_MAX;

  wire [9:0]  datatable_addr;
  wire        datatable_wren;
  wire [31:0] datatable_data;
  wire [31:0] datatable_q;

  /* WRITTEN WHEN IT CHANGES, NOT EIGHTEEN MILLION TIMES A SECOND
   * (2026-11-02).
   *
   * This used to raise `datatable_wren` once every four clk_74a, forever --
   * 18.5 million writes a second into a dual-port RAM whose OTHER PORT is the
   * one the OS reads the table through. Two things follow, and they are the
   * shape of a core that quits badly only sometimes:
   *
   *   * a read that lands on the same clock as one of those writes is a
   *     read-during-write on the same address (`mf_datatable` is one clock,
   *     one write port per side), and what it returns is not a value this core
   *     chose. The table's word 3 is the SIZE the OS writes the `.sav` at, so a
   *     torn read there is a flush told to write an arbitrary number of bytes;
   *   * the hazard is invisible in every harness, because a harness reads the
   *     table once at a moment it picks. It is a coin flip at 74 MHz on the
   *     panel, which is why this class of bug keeps surviving a green run.
   *
   * The value is a constant for the whole session -- it is the cartridge image's
   * size, latched once the download has told us what it is. So it is written
   * when it CHANGES, plus a slow refresh (one write per 2^16 clocks, ~0.9 ms) so
   * that a value the OS clobbers through its own port is still put back. The
   * collision window goes from one clock in four to one in sixty-five thousand,
   * and an unchanged session writes the table about a thousand times in ten
   * minutes instead of eleven billion. */
  localparam [15:0] DT_REFRESH = 16'hFFFF;

  reg [15:0] dt_tick = 16'h0;
  reg [31:0] dt_last = 32'hFFFF_FFFF;
  reg        dt_wr   = 1'b0;

  always @(posedge clk_74a) begin
    dt_tick <= (dt_tick == DT_REFRESH) ? 16'h0 : dt_tick + 16'd1;

    if ((save_slot_size != dt_last) || (dt_tick == DT_REFRESH)) begin
      dt_last <= save_slot_size;
      dt_wr   <= 1'b1;
    end else
      dt_wr   <= 1'b0;
  end

  assign datatable_addr = 10'd3;
  assign datatable_wren = dt_wr;
  /* NATIVE, NOT BYTE-REVERSED -- AND THE REVERSAL WAS THE SAVE CRASH
   * (2026-10-26, fourth pass: this word is why every earlier attempt "changed
   * nothing").
   *
   * A value written by the core has TWO byte swaps between it and the host:
   *
   *   core_bridge_cmd.v:119   bridge_rd_data   <= swap(bridge_rd_data_out)
   *   io_bridge_peripheral:133 pmp_rd_data_e  <= swap(pmp_rd_data)
   *
   * ...and the second one is handed straight to the SPI shifter
   * (io_bridge_peripheral:217 `spis_word_tx <= pmp_rd_data_e`). Two swaps are
   * an identity, so THE HOST SEES EXACTLY THE WORD STORED IN THE TABLE. That
   * is measurable in the one file this core has already produced: the OS wrote
   * `savestate_size` (rtl/core_top.v's SS_BYTES, stored natively) into every
   * .sta as the state blob's size -- 596-byte header + SS_BYTES, which was
   * 37,516 for the old 36,920-byte format and is 70,284 for this one
   * bytes, which is exactly the length of the small-cart .sta files on the
   * card. A single swap would have asked it for 948,961,280 bytes.
   *
   * The previous version pre-swapped this word to compensate for the first of
   * those two stages, which double-counted the second: the OS was told
   * 8,388,608 bytes for a 32 KB cartridge (reverse(0x0000_8000)) and 8,192 for
   * a 2 MB one (reverse(0x0020_0000)). So a small cart's flush tried to write
   * an 8 MB .sav, and a 2 MB cart's wrote an 8 KB one -- "tetris crashes APF"
   * and "some carts save but with issues", from one line. It also means every
   * experiment with this word (cart_size, a 2 MB constant, the boot-time
   * maximum) reached the card as its own byte reversal, which is why they all
   * behaved identically and all failed.
   *
   * The byte order is therefore NOT this word's business: the two bridge stages
   * already cancel, and storing the size natively is what the APF's own
   * reference core does (rtl/core_top_template.v: `datatable_data <= has_save ?
   * 32'h40_000 : 32'h0`, never reversed). */
  assign datatable_data = save_slot_size;

  // ---- save-slot read request/ack --------------------------------------
  /* THE READ REQUEST IS NOT ADDRESSED TO ONE SLOT (2026-11-02).
   *
   * This used to require `dataslot_requestread_id == 2`. Only one slot in this
   * core can be read out at all -- slot 2, the cartridge image -- so the id
   * test bought nothing and had exactly one failure mode: a `[0080]` whose id
   * did not match (an index instead of an id, a slot renumbered in data.json)
   * answered the host immediately through the tie-off below, armed nothing, and
   * left the OS walking 2 MB of a window that answers zero. That is a 100%-zero
   * `.sav` with the correct size, which is every `.sav` on the panel's card.
   *
   * Slot 1 is not readable (it is not nonvolatile), so arming the image stream
   * for any read request can only ever be the save slot. */
  wire ps_req_read  = dataslot_requestread;
  /* ... AND THE WRITE DIRECTION IS NOT ADDRESSED TO ONE SLOT EITHER
   * (2026-11-02). `ps_req_write` was `dataslot_requestwrite && id == 2`, and it
   * armed two things that both fail COMPLETELY when it is false: `ps_slot2_seen`
   * (which gates the restore into PSRAM) and the sixteen-byte probe in the
   * cartridge FIFO writer. A restore that is armed by nothing is not a slow
   * restore, it is a dropped one -- the game boots from the .gtr, plays, and
   * the save is simply not there. The address already says which slot a word
   * belongs to, so the gate is gone. */
  wire [31:0] ps_bridge_rdata;
  wire        ps_ack, ps_underrun;
  wire        ps_mem_rd, ps_mem_busy;
  wire [21:0] ps_mem_addr;
  wire [7:0]  ps_mem_burstcnt;
  wire [63:0] ps_mem_dout;
  wire        ps_mem_dout_ready;

  // The cartridge's `$90` pulse, out of rtl/gametank.sv (console clock).

  /* THE WRITE WINDOW IS STICKY, NOT PER-TRANSFER (2026-10-31). It used to be
   * -- [0082] opened it and [008F] closed it -- and that cost restores on the
   * launches where the cartridge slot's [008F] arrived before the save's bytes
   * did, because the window had already closed. The APF may send [008F] once,
   * for all slots, or per slot; nothing in this core can tell. So the window is
   * armed by the slot's first request and stays armed until the OS resets the
   * core -- and the only thing that can write 0x02 anyway is the Save slot's
   * own transfer (its read direction uses `bridge_rd`). */
  /* THE SAVE WINDOW HAS NO ARM AT ALL, AND THAT IS THE FIX (2026-11-02).
   *
   * This was `ps_slot2_seen`, a flag raised by `[0082]` for slot 2 and cleared by
   * a host reset. Every byte of a restore was dropped until it was up, which
   * works at launch and fails everywhere else:
   *
   *   * the MANUAL load (interact.json's action, and `[0180]` under it) sends no
   *     `[0082]` at all -- so on a boot where slot 1's request never matched, or
   *     after any host reset, the button restored nothing and the screen did not
   *     change. "It doesn't even pop up."
   *   * "Play Cartridge", or a build where slot 1 is the only slot the OS loads,
   *     leaves it down for the whole session.
   *
   * A flag that gates a datapath and is cleared by something unrelated to it is
   * the same shape as the `sv_start` bug below, and it has the same symptom: no
   * error, no partial image, nothing. The address is the arm. `bridge_wr` to
   * 0x02xxxxxx is a save byte and nothing else in this core writes that window
   * -- data.json puts exactly one slot there -- so there is nothing left for a
   * flag to disambiguate. (The read side was de-addressed for the same reason.) */

  // Declared here (rather than beside its assignment, further down) because
  // the save slot's memory stream is reset by the same machine reset and the
  // instance appears above the machine's own section.
  wire machine_reset;

  // ---- the cartridge image, streamed out for the save slot -------------
  gt_save_slot save_slot (
      .clk_74a      (clk_74a),
      .reset_74a    (~core_ready),

      .req          (ps_req_read),
      .allcomplete  (dataslot_allcomplete),
      .pre_arm      (sf_prearm),
      .ack          (ps_ack),

      .bridge_addr  (bridge_addr),
      .bridge_rd    (bridge_rd),
      .rd_data      (ps_bridge_rdata),

      .clk_core     (clk_core),
      /* THE FLUSH IS NOT THE CONSOLE'S (2026-10-31).
       *
       * This was `machine_reset`, and that is the bug the panel reports as
       * "when I exit the core it goes black and I have to power cycle":
       * quitting is a FLUSH (the OS reads the nonvolatile slot out of the core
       * and writes the .sav), and `machine_reset` is asserted by exactly the
       * things the OS does around that moment -- a host reset (a write to 0x50
       * holds it for 2^20 clocks, 14 ms) and any download in flight
       * (`dl_wait`). While it is high this block's stream FSM is held at
       * S_IDLE with `fifo_wrst` ASSERTED, so the FIFO's write side never moves:
       * every word the OS reads through the 0x02 window is an underrun and
       * answers zero, `active` never has a word to serve, and the flush the OS
       * is waiting on produces nothing. The stream is a PSRAM read that happens
       * to live in this core; it has nothing to do with the machine, and
       * `rtl/mem_bus.sv` -- the thing it reads through -- has no reset port at
       * all, so the console being held is no reason for it to stop.
       *
       * So the stream gets the APF's own power-up reset and nothing else. A new
       * request still restarts it at image byte 0 (the `flush_core` toggle, in
       * its own domain), so nothing about re-arming depends on this pin. */
      .reset_core   (~core_ready_c2),

      .mem_rd         (ps_mem_rd),
      .mem_addr       (ps_mem_addr),
      .mem_burstcnt   (ps_mem_burstcnt),
      .mem_dout       (ps_mem_dout),
      .mem_dout_ready (ps_mem_dout_ready),
      .mem_busy       (ps_mem_busy),

      .underrun     (ps_underrun)
  );

  /* ONE SAVE MECHANISM: THE PLATFORM'S (2026-11-03).
   *
   * There used to be a second one here -- rtl/gt_save_file.sv, which wrote
   * `<rom>save.gtr` beside the cartridge with the host's data-slot target
   * commands and read it back at launch. It had been switched off (both
   * SF_WRITE_EN and SF_RESTORE_EN 0) once the OS's own nonvolatile writeback
   * was proven on the card; it is removed now rather than left compiled.
   *
   * WHY REMOVED AND NOT JUST DISABLED. Every command it could still issue was a
   * `cm` marker in the framework's target register, and a core holding one of
   * those while the OS closes it is a core the framework will not close -- the
   * black screen at quit, by the framework's own rules. A GameTank has no
   * battery-backed RAM: a save IS the cartridge image, and the OS already reads
   * that image out of the Save data slot at exit and writes it back at launch.
   * One mechanism, the documented one, and nothing of this core's on the target
   * channel.
   *
   * WHAT IS LOST: a save is committed when the core is quit, not at the instant
   * the game writes its flash, so pulling the power mid-session loses it. That
   * was already true with the writer switched off. */

  core_bridge_cmd icb (
      .clk(clk_74a),
      .reset_n(reset_n),

      .bridge_endian_little(bridge_endian_little),
      .bridge_addr         (bridge_addr),
      .bridge_rd           (bridge_rd),
      .bridge_rd_data      (cmd_bridge_rd_data),
      .bridge_wr           (bridge_wr),
      .bridge_wr_data      (bridge_wr_data),

      .status_boot_done (core_ready),
      .status_setup_done(core_ready),
      .status_running   (reset_n),

      .dataslot_requestread    (dataslot_requestread),
      .dataslot_requestread_id (dataslot_requestread_id),
      // The save slot only grants a read once its first word is in the FIFO
      // (rtl/gt_save_slot.sv); every other slot is granted at once.
      /* A QUIT NEVER WAITS ON THIS CORE (2026-11-02).
       *
       * This is the one handshake that can strand the OS at shutdown: it asks
       * for the save slot with `[0080]` and blocks until the core acks, and the
       * ack here is `ps_ack` -- the stream's own "word 0 is in the FIFO". Every
       * other core ties this to 1. If the stream is slow or dead, the core makes
       * the OS wait for a reader that has nothing to give, at the exact moment
       * it is trying to close.
       *
       * So during a takeover (`apf_quiesce`: the host's reset, or its 0x50 hold)
       * the ack is granted unconditionally: the OS reads whatever the window has
       * and unloads. That can cost the .sav its content, and it is the right
       * trade -- a save that is wrong is recoverable from the card, a Pocket that
       * has to be power-cycled is not. `ps_ack` still paces the normal case, so a
       * flush the OS starts while the core is still running is answered exactly
       * as before. */
      /* WHY THE TERNARY IS THERE, AND WHY IT MUST STAY (2026-11-02, MEASURED).
       *
       * The `: 1'b1` arm looks like a bug -- `[0080]` sets `dataslot_requestread`
       * non-blocking and tests this in the same cycle, so the first cycle answers
       * "ready" before the stream is armed. Removing it so the command waits for
       * `ps_ack` was tried and MEASURED here: `tools/gt_core_ss.sh` then fails
       * with the save read-out underrunning (`tb_core_ss.cpp:1308`), because the
       * OS's answer and the stream's arm then race instead of being ordered.
       *
       * So the immediate answer is deliberate and matches every other core: the
       * OS's request IS the arm (rtl/gt_save_slot.sv arms on the request's rising
       * edge), and the window answers a read that arrives before word 0 is in the
       * FIFO with zero rather than a stall. The documented cost is small and
       * visible on the card: the first three words of a `.sav` are zero. It is
       * not a hang and not a shifted file, and it is cheaper than the race. */
      /* THE ACK WAITS FOR WORD 0, EVEN AT QUIT (2026-11-02).
       *
       * `[0080]` blocks the OS until this rises, and the OS starts reading the
       * window the instant it does. Granting it early therefore buys nothing and
       * costs the first words of every save: the stream needs ~200 clk_74a to
       * produce its first burst, so the OS's first three reads were answered
       * from an empty window. That is the race the old comment here warned about
       * and then accepted.
       *
       * It is not a race any more because the window is addressed (see
       * rtl/gt_save_slot.sv): a read that arrives before the word exists answers
       * zero and does not move anything, so the OS skipping ahead can no longer
       * shift the file. And it is safe to wait at quit as well -- Pocket's
       * shutdown order is `[0010]` FIRST and `[0080]` after it (Analogue, Core
       * Boot Process, Shutdown), so the OS is sitting in the command waiting for
       * this handshake, not doing anything with the answer. A PSRAM that never
       * answers is still covered by the stream's own 0.88 ms ack cap. */
      .dataslot_requestread_ack(ps_ack),
      .dataslot_requestread_ok (1'b1),

      .dataslot_requestwrite    (dataslot_requestwrite),
      .dataslot_requestwrite_id (dataslot_requestwrite_id),
      .dataslot_requestwrite_size(dataslot_requestwrite_size),
      // THE HOST IS NOT TOLD TO STREAM UNTIL THE MACHINE'S CLOCK IS UP
      // (2026-10-30). [0082] is the handshake that starts a cartridge download:
      // the OS holds the request until this ack rises, then sends the file. It
      // used to be a constant 1, so the file could arrive in the first
      // microseconds after configuration, while clk_core -- the only clock the
      // loader's drain and PSRAM run on -- was still coming out of the console
      // PLL's reset. The 32-entry capture FIFO then filled and dropped, and the
      // start of the image was missing: the machine booted a cartridge whose
      // first 128 bytes were zeros, i.e. it did not boot, and loading the same
      // cart again from the core menu (PLL already up) worked. That is the
      // panel's "load the cart again and again before it boots".
      //
      // `core_ready` is the boot gate: the sticky PLL lock, or the 3.5 ms boot
      // timer if the PLL never reports one. Deferring the ack by that long is
      // harmless to the OS (a host command waits), and it makes the capture
      // race impossible rather than unlikely.
      .dataslot_requestwrite_ack(dataslot_reqwrite_ack),
      .dataslot_requestwrite_ok (1'b1),

      .dataslot_update     (dataslot_update),
      .dataslot_update_id  (dataslot_update_id),
      .dataslot_update_size(dataslot_update_size),

      .dataslot_allcomplete(dataslot_allcomplete),

      .rtc_epoch_seconds(),
      .rtc_date_bcd     (),
      .rtc_time_bcd     (),
      .rtc_valid        (),

      // Save states are declared, and this is the half of the protocol the OS
      // sees: supported, the buffer's address, the blob's size, and the largest
      // file it may hand back. The transfer itself is rtl/save_state_controller
      // (0x4 window, ack/busy/ok/err) and rtl/gt_savestates (the machine walk).
      .savestate_supported  (1'b1),
      .savestate_addr       (32'h40000000),
      .savestate_size       (SS_BYTES),
      .savestate_maxloadsize(SS_MAX_LOAD),

      .osnotify_inmenu    (osnotify_inmenu),
      .osnotify_pause_req (osnotify_pause_req),

      .savestate_start     (savestate_start),
      .savestate_start_ack (ss_start_ack),
      .savestate_start_busy(ss_start_busy),
      .savestate_start_ok  (ss_start_ok),
      .savestate_start_err (ss_start_err),

      .savestate_load     (savestate_load),
      .savestate_load_ack (ss_load_ack),
      .savestate_load_busy(ss_load_busy),
      .savestate_load_ok  (ss_load_ok),
      .savestate_load_err (ss_load_err),

      // THE TARGET DIRECTION IS DEAD, ON PURPOSE (2026-11-03). This core asks
      // the host for nothing: a save is the OS's own nonvolatile writeback of
      // the Save slot, and there is no second mechanism left to issue
      // [0184]/[0192] at. That matters most at quit -- a `cm` marker standing
      // in `target_0` while the OS closes the core is a core it will not close.
      .target_dataslot_read      (1'b0),
      .target_dataslot_write     (1'b0),
      .target_dataslot_getfile   (1'b0),
      .target_dataslot_openfile  (1'b0),
      .target_dataslot_flush     (1'b0),
      .target_dataslot_id        (16'h0),
      .target_dataslot_slotoffset(32'h0),
      .target_dataslot_bridgeaddr(32'h0),
      .target_dataslot_length    (32'h0),
      .target_buffer_param_struct(32'h0),
      .target_buffer_resp_struct (32'h0),

      .datatable_addr(datatable_addr),
      .datatable_wren(datatable_wren),
      .datatable_data(datatable_data),
      .datatable_q   (datatable_q)
  );

  // ------------------------------------------------------------------ cartridge
  //
  // The OS streams the .gtr over the bridge as 32-bit writes into data slot 1
  // (0x1xxxxxxx). Each write carries the byte address in bridge_addr[20:0] and
  // four bytes of file in bridge_wr_data, first file byte in [7:0].
  //
  // THE HOST CANNOT BE PACED, SO THE ONLY SAFE CAPTURE IS A FIFO. The bridge
  // hands a slot write to the core as a one-cycle pulse and never waits
  // (io_bridge_peripheral.v: "writes are immediate"), so a word the loader
  // cannot take is gone. That is exactly the fault that made every Minicube64
  // cartridge show its own private noise on the panel while every simulation
  // passed (2026-10-11); the fix is the same one: capture in the bridge's
  // domain into a small gray-pointer FIFO, drain in the machine's domain, and
  // count drops so an incomplete image is a number, not a mystery.

  wire slot1_write = bridge_wr && (bridge_addr[31:28] == 4'h1);

  /* THE SAVE SLOT'S BYTES ARE THE CARTRIDGE IMAGE, SO THEY LAND WHERE THE IMAGE
   * LANDS (2026-10-31).
   *
   * A GameTank save is a flash cartridge that the game has rewritten in place:
   * the reference emulator persists it as a diff of the ROM image
   * (`SaveModifiedFlash`, gte.cpp:135) and the MiSTer wrapper persists it as the
   * image (`rtl/savectl.sv`). On the Pocket the same file is data slot 2, and
   * rtl/gt_save_slot.sv streams the whole 2 MB at PSRAM CART_BASE back out for
   * it -- so the .sav IS the image, which is why the size table reports the
   * cartridge's own size and why a restore downloads the image again.
   *
   * THE RESTORE DIRECTION IS THE SAME PORT. data.json declares the slot
   * `nonvolatile` with `deferload: false`, so the OS writes the .sav INTO the
   * core at launch: [0082] with the slot id, the bytes into the 0x02 window,
   * then [008F]. Those bytes are image bytes at offset 0, exactly like slot 1's,
   * so they go into the same FIFO and the same drain -- rtl/cart.sv writes at
   * CART_BASE either way, then sweeps the cache, re-copies the fixed bank and
   * re-presents the console when the transfer ends. That is the restore: the
   * machine is held in reset for the length of the transfer (dl_wait) and boots
   * from the restored image instead of a half-written one.
   *
   * It was dropped for two days (2026-10-29) because routing it this way looked
   * like the cause of the cold-boot block pattern. It was not: that pattern was
   * M10K powering up undefined in the frame store, and it survived with the
   * writes dropped. Dropping them instead cost every restore -- the game booted
   * from the cartridge file and never saw the save on the card.
   *
   * Only the size inference must stay slot-1's (`dl_img_size`, above): a 2 MB
   * .sav written over a 32 KB EEPROM game must not turn it into a flash cart.
   */
  wire slot2_write = bridge_wr && (bridge_addr[31:24] == 8'h02);

  // Bytes of image restored through the save slot, for the harnesses and the
  // debug tag: a save that arrives and is not counted is a save that did not.
  reg [21:0] save_bytes /* verilator public_flat_rd */ = 22'd0;

  /* A SAVE THAT IS NOT AN IMAGE MUST NEVER BE RESTORED (2026-10-31).
   *
   * WHAT THE CARD SAYS. Every .sav this core has written is 100% zeros:
   * AERIAL 16,384 bytes, tetris 32,768, tanks and multi 2,097,152 each -- four
   * files, three builds, 0 nonzero bytes in any of them. data.json declares
   * the Save slot nonvolatile with `deferload: false`, so the OS writes that
   * file back into the core at EVERY launch, right after the cartridge, and
   * this port -- rtl/cart.sv's download port, shared with the restore by
   * design -- wrote it at CART_BASE, over the image that had just arrived.
   *
   * WHAT THAT LOOKS LIKE ON THE PANEL. Slot 1 streams the .gtr and the machine
   * boots it; slot 2 then streams 32 KB of zeros over the same addresses,
   * `dl_start` clears `present_r`, the FIFO drains, `dl_end` re-copies the
   * fixed bank FROM THOSE ZEROS, and the console comes back with a reset
   * vector of $0000. The 65C02 sits in its BRK loop, the fixed bank is zeros,
   * and the panel stays black. Picking the cartridge again from Core Settings
   * streams slot 1 alone, with no restore, and the game boots. "I have to load
   * it twice", exactly -- and it is not the download handshake, which is held
   * for `core_ready` and no longer overflows the capture FIFO.
   *
   * THE GUARD CHECKS THE SAVE AGAINST THE CARTRIDGE IT BELONGS TO (2026-11-02).
   *
   * The old test was "is the first sixteen bytes all zero", which only catches
   * an empty file. It does NOT catch the failure the card actually has: a save
   * that is the right size, full of the right bytes, and four or eight bytes out
   * of position -- or a save belonging to a different game. Restoring either one
   * writes it over the cartridge, and the panel's "the save loads and the game
   * is corrupted / won't boot" is that write.
   *
   * A GameTank save IS a copy of the cartridge with the game's own flash writes
   * applied, and those writes are never in the first thirty-two bytes -- that is
   * the entry code in the $8000 window. So the FIRST EIGHT WORDS of the image
   * are copied out of slot 1's download as it streams in, and a slot-2 stream
   * is accepted only if its own first eight words match them. A shifted save
   * fails on every word; a save from another cartridge fails on nearly all of
   * them; a genuine save passes and is restored exactly as before. At most one
   * of the eight may differ, so a game that legitimately rewrites a word there
   * still restores.
   *
   * What that buys: a wrong .sav can no longer destroy a cartridge. The worst a
   * bad file can do is be ignored -- the game boots from its cartridge and the
   * panel keeps its picture, instead of booting a black screen that needs the
   * cart loaded twice.
   *
   * `save_refused` counts what was dropped, for the harnesses: a restore that
   * is silently ignored is otherwise a mystery, and this tree has paid for
   * those before. */
  localparam SV_PROBE = 8;                 // words held: 32 bytes
  localparam [2:0] SV_IDLE = 3'd0, SV_HEAD = 3'd1, SV_REPLAY = 3'd2,
                   SV_PASS = 3'd3, SV_DROP = 3'd4;

  reg  [20:0] sv_haddr [0:SV_PROBE-1];
  reg  [31:0] sv_hdata [0:SV_PROBE-1];
  reg  [2:0]  sv_st    = SV_IDLE;
  reg  [2:0]  sv_hidx  = 3'd0;             // words held so far
  reg  [2:0]  sv_rp    = 3'd0;             // replay cursor
  reg  [3:0]  sv_bad   = 4'd0;             // ... of which these did not match (four
                                           // bits: eight mismatches is 8, not 0)
  reg  [19:0] sv_quiet = 20'd0;            // clk_74a since the last slot-2 word
  reg  [15:0] save_refused = 16'd0;

  /* THE CARTRIDGE'S OWN FIRST WORDS. Captured from slot 1 as it streams in,
   * because that is the only moment the cartridge is guaranteed to be the file
   * the user picked rather than whatever a previous restore left behind.
   * `ch_ok` says the capture is complete -- and it is deliberately NOT cleared
   * by `[0082]`, which arrives before the SAVE's download too. */
  reg  [31:0] ch_data  [0:SV_PROBE-1];
  reg  [3:0]  ch_idx   = 4'd0;             // four bits: three cannot hold 8
  reg         ch_ok    = 1'b0;

  always @(posedge clk_74a) begin
    if (dataslot_requestwrite)
      ch_idx <= 4'd0;
    else if (slot1_write && (ch_idx < SV_PROBE)) begin
      ch_data[ch_idx[2:0]] <= bridge_wr_data;
      ch_idx <= ch_idx + 4'd1;
      if (ch_idx == (SV_PROBE - 1))
        ch_ok <= 1'b1;
    end
  end

  wire        sv_live   = slot2_write && (sv_st == SV_PASS);
  wire        sv_replay = (sv_st == SV_REPLAY);
  wire [20:0] cf_waddr  = sv_replay ? sv_haddr[sv_rp] : bridge_addr[20:0];
  wire [31:0] cf_wdata  = sv_replay ? sv_hdata[sv_rp] : bridge_wr_data;

  always @(posedge clk_74a) begin
    if (external_reset) begin
      sv_st   <= SV_IDLE;
      sv_hidx <= 3'd0;
      sv_bad  <= 4'd0;
    end
    /* A SAVE STREAM BEGINS AT ITS REQUEST, NOT AT THE FIRST WORD AFTER ONE
     * (2026-11-02).
     *
     * The probe above holds the first thirty-two bytes of a slot-2 stream
     * before deciding whether the stream is an image. Without this clear it
     * holds the first thirty-two bytes it EVER sees, which is not the same: a write to
     * 0x02xxxxxx that arrives outside a request -- a stray host write, or the
     * tail of a previous session's window -- sits in those four registers, and
     * when the real `[0082]` download begins the probe replays the stray word
     * into the image at ITS offset and the download's own first three words
     * behind it. Measured in sim/gt/tb_core_ss.cpp: one stray word before the
     * request and `save_bytes` came out 32,772 for a 32 KB image, with the
     * spare word written at image offset 0.
     *
     * `[0082]` is the OS saying a download starts. Nothing can be in flight
     * across it, so discarding what the probe held costs nothing and makes the
     * bytes under test the ones that were actually sent. */
    else if (dataslot_requestwrite) begin
      sv_st   <= SV_IDLE;
      sv_hidx <= 3'd0;
      sv_bad  <= 4'd0;
    end
    else begin
      if (slot2_write) sv_quiet <= 20'd0;
      else if (sv_quiet != 20'hF_FFFF) sv_quiet <= sv_quiet + 20'd1;

      case (sv_st)
      /* THE PROBE STARTS ON THE STREAM'S FIRST WORD, NOT ON A COMMAND
       * (2026-11-02). It used to start on `sv_start`, i.e. a `[0082]` whose
       * slot id matched -- the same arm that gated the restore, so the same
       * silent failure, and it cost the replay too: with the probe never
       * entered, the sixteen bytes were neither checked nor passed on.
       *
       * A slot-2 stream begins when its first word arrives, and that word has to
       * be captured in THIS cycle: starting in SV_HEAD and capturing on the next
       * one would leave word 0 out of the replay and shift the head of the image
       * by eight -- an image restored eight bytes to the left, which boots and
       * plays wrong. */
      SV_IDLE, SV_HEAD: if (slot2_write) begin
        sv_haddr[sv_hidx] <= bridge_addr[20:0];
        sv_hdata[sv_hidx] <= bridge_wr_data;
        if (bridge_wr_data != ch_data[sv_hidx])
          sv_bad <= sv_bad + 4'd1;
        if (sv_hidx == (SV_PROBE-1)) begin
          /* THE LAST WORD DECIDES, AND IT IS COUNTED HERE rather than a cycle
           * later: `sv_bad` does not yet include the comparison above. One
           * mismatch is tolerated (a game may legitimately rewrite a word of
           * its own entry code); any more is not this cartridge's save. */
          if (!ch_ok ||
              ((sv_bad + ((bridge_wr_data != ch_data[sv_hidx]) ? 4'd1 : 4'd0)) > 4'd1)) begin
            sv_st <= SV_DROP;
            if (save_refused != 16'hFFFF)
              save_refused <= save_refused + 16'd1;
          end else begin
            sv_st <= SV_REPLAY;
            sv_rp <= 3'd0;
          end
        end else begin
          sv_hidx <= sv_hidx + 3'd1;
        end
      end

      SV_REPLAY: begin
        if (sv_rp == (SV_PROBE-1)) sv_st <= SV_PASS;
        else                         sv_rp <= sv_rp + 3'd1;
      end

      /* ONE TRANSFER ENDS ON SILENCE, NOT ON A COMMAND (2026-11-02).
       *
       * `[008F]` is what a launch sends at the end of the slots. A manual load
       * sends none -- and the boot's own `[008F]` is STILL HIGH when the button
       * is pressed, because only `[0080]`/`[0082]` clear it, so ending on it
       * would return to SV_IDLE on the very first clock of the very first
       * restore. A state machine that can only leave through a command nobody
       * sent never probes twice.
       *
       * 2^20 clk_74a is 14 ms against a bridge access every ~1.2 us, so a gap
       * between two chunks of the same restore is never mistaken for the end of
       * it -- and re-probing mid-image would replay the held words at the wrong
       * offset, i.e. an image restored with its head shifted. */
      SV_PASS, SV_DROP: if (sv_quiet == 20'hF_FFFF) begin
        sv_st   <= SV_IDLE;
        sv_hidx <= 3'd0;
        sv_bad  <= 4'd0;
      end

      default: ;                          // only SV_IDLE / SV_HEAD
    endcase
    end
  end

  wire cf_push      = slot1_write || sv_live || sv_replay;
  wire cf_push_save = sv_live || sv_replay;

  // 32 entries, not the four Minicube64 needed. GameTank's download drains into
  // PSRAM through a state machine (~5.5 clocks per byte once rtl/cart.sv pairs
  // a halfword), against a bridge that hands over 4 bytes every ~7.2 clocks of
  // this clock, so the drain runs close to the stream rate rather than far
  // ahead of it; the depth is what absorbs the APF's bursts. 32 x (21 + 32)
  // bits is 1.7 kbit of registers.
  localparam CF_AW = 5;                 // 32 entries
  localparam CF_N  = 1 << CF_AW;

  reg  [20:0] cf_addr [0:CF_N-1];
  reg  [31:0] cf_data [0:CF_N-1];
  reg         cf_save [0:CF_N-1];      // 1 = slot 2 (a restore), 0 = slot 1

  reg  [CF_AW:0] cf_wbin  = 3'b0;
  reg  [CF_AW:0] cf_wgray = 3'b0;
  reg  [CF_AW:0] cf_rbin  = 3'b0;
  reg  [CF_AW:0] cf_rgray = 3'b0;

  wire [CF_AW:0] cf_wbin_n  = cf_wbin + 1'b1;
  wire [CF_AW:0] cf_wgray_n = (cf_wbin_n >> 1) ^ cf_wbin_n;
  wire [CF_AW:0] cf_rbin_n  = cf_rbin + 1'b1;
  wire [CF_AW:0] cf_rgray_n = (cf_rbin_n >> 1) ^ cf_rbin_n;

  reg [CF_AW:0] cf_rgray_s1 = 3'b0, cf_rgray_s2 = 3'b0;
  reg [CF_AW:0] cf_wgray_s1 = 3'b0, cf_wgray_s2 = 3'b0;

  wire [CF_AW:0] cf_full_cmp = {~cf_rgray_s2[CF_AW],
                                ~cf_rgray_s2[CF_AW-1],
                                 cf_rgray_s2[CF_AW-2:0]};

  wire cf_full  = (cf_wgray_n == cf_full_cmp);
  assign cf_empty = (cf_rgray == cf_wgray_s2);

  reg [15:0] cart_drop = 16'd0;

  always @(posedge clk_74a) begin
    cf_rgray_s1 <= cf_rgray;
    cf_rgray_s2 <= cf_rgray_s1;

    if (cf_push) begin
      if (!cf_full) begin
        cf_addr[cf_wbin[CF_AW-1:0]] <= cf_waddr;
        cf_data[cf_wbin[CF_AW-1:0]] <= cf_wdata;
        cf_save[cf_wbin[CF_AW-1:0]] <= cf_push_save;
        cf_wbin  <= cf_wbin_n;
        cf_wgray <= cf_wgray_n;
      end else begin
        cart_drop <= cart_drop + 16'd1;
      end
    end
  end

  // ---- drain side, in the console's clock: one word = four byte writes, and
  //      each byte waits for the cartridge controller to take the previous one
  //      (dl_wr is a one-cycle strobe, dl_busy is the backpressure).
  reg  [20:0] dl_cur_addr = 21'h0;
  reg  [31:0] dl_cur_data = 32'h0;
  reg  [ 1:0] dl_byte     = 2'd0;
  reg  [ 1:0] dl_state    = 2'd0;
  reg         dl_wr_r     = 1'b0;
  reg  [20:0] dl_addr_r   = 21'h0;
  reg  [ 7:0] dl_data_r   = 8'h00;

  localparam DL_IDLE = 2'd0, DL_SEND = 2'd1, DL_GAP = 2'd2, DL_WAIT = 2'd3;

  wire dl_take = (dl_state == DL_IDLE) && !cf_empty;

  always @(posedge clk_core) begin
    cf_wgray_s1 <= cf_wgray;
    cf_wgray_s2 <= cf_wgray_s1;

    dl_wr_r <= 1'b0;

    case (dl_state)
      DL_IDLE: if (dl_take) begin
        dl_cur_addr <= cf_addr[cf_rbin[CF_AW-1:0]];
        dl_cur_data <= cf_data[cf_rbin[CF_AW-1:0]];
        if (cf_save[cf_rbin[CF_AW-1:0]])
          save_bytes <= save_bytes + 22'd4;     // four image bytes per word
        dl_byte     <= 2'd0;
        dl_addr_r   <= cf_addr[cf_rbin[CF_AW-1:0]];
        dl_data_r   <= cf_data[cf_rbin[CF_AW-1:0]][7:0];
        dl_state    <= DL_SEND;
      end

      DL_SEND: begin
        dl_wr_r  <= 1'b1;
        dl_state <= DL_GAP;
      end

      DL_GAP: dl_state <= DL_WAIT;   // one cycle for dlw_pend to appear

      DL_WAIT: if (!dl_busy) begin
        if (dl_byte == 2'd3) begin
          cf_rbin  <= cf_rbin_n;
          cf_rgray <= cf_rgray_n;
          dl_state <= DL_IDLE;
        end else begin
          dl_byte   <= dl_byte + 2'd1;
          dl_addr_r <= dl_cur_addr + {19'b0, dl_byte} + 21'd1;
          dl_data_r <= (dl_byte == 2'd0) ? dl_cur_data[15: 8] :
                       (dl_byte == 2'd1) ? dl_cur_data[23:16] :
                                           dl_cur_data[31:24];
          dl_state  <= DL_SEND;
        end
      end

      default: dl_state <= DL_IDLE;
    endcase
  end

  // The stream envelope for rtl/cart.sv: high from the first byte until the OS
  // says the file is complete AND the FIFO has drained. Its falling edge is
  // what latches the image size and starts the cartridge controller's fill.
  //
  // SILENCE ALSO ENDS IT (2026-10-29). `dl_stream` gates `machine_reset`, so a
  // completion command the OS never sends is not a slow boot, it is a core with
  // no picture and no way out: the panel's "loading a cart the first time just
  // shows the loader, relaunch it" is exactly that shape. The bridge cannot
  // deliver anything during a silence, so an empty FIFO that has seen no word
  // for 2^24 clocks (0.59 s at 28.636 MHz) is the end of the transfer whoever
  // is holding the other end; the normal completion path runs from there.
  reg  allcomplete_s1 = 1'b0, allcomplete_s2 = 1'b0;
  reg  dl_stream = 1'b0;
  reg  [23:0] dl_quiet = 24'h0;
  wire dl_stalled = (dl_quiet == 24'hFF_FFFF);

  always @(posedge clk_core) begin
    allcomplete_s1 <= dataslot_allcomplete;
    allcomplete_s2 <= allcomplete_s1;

    if (dl_take || (dl_state != DL_IDLE))
      dl_quiet <= 24'h0;
    else if (dl_stream && !dl_stalled)
      dl_quiet <= dl_quiet + 24'd1;
    else if (!dl_stream)
      dl_quiet <= 24'h0;

    if (dl_take || (dl_state != DL_IDLE))
      dl_stream <= 1'b1;
    else if (cf_empty && (allcomplete_s2 || dl_stalled))
      dl_stream <= 1'b0;
  end

  // ------------------------------------------------------------------- pause
  //
  // The Pocket's START button is the game's Start, and the Pocket's SELECT
  // button is the core's pause. The pad's Start is D5 of its select-low read
  // (rtl/pads.sv), so it is a game button and has to stay one -- a GameTank
  // game reads it and does something (a menu, a pause of its own). Select has
  // no counterpart on the console's pad at all, so that is the free button, and
  // it is the one this core takes for its own pause.
  //
  // WHAT A PAUSE IS. A LEVEL into rtl/gametank.sv, which holds the 65C02's RDY
  // and the ACP's timebase. Nothing else stops: the raster, the frame snapshot
  // and the video PLL free-run, because the scaler is locked to them (a stopped
  // raster is a lost picture, not a paused one). The DAC's last byte is held by
  // the hardware, so the output stage ramps it to silence -- a pause must not
  // drone a note.
  //
  // THE BUTTON IS A TOGGLE, with the two guards the MiniCube64 core needed and
  // the panel taught it (spec 21.12):
  //   * ARMED ON RELEASE. A press only counts once the button has been seen up
  //     since the machine ran, so a button held through power-on or through a
  //     core reset cannot freeze the next boot.
  //   * THE MENU'S PAUSE IS ESCAPABLE. Opening the core menu asserts
  //     `osnotify_inmenu`, which pauses the machine so it is not running
  //     underneath the menu; pressing the pause button while the menu is open
  //     takes that pause back (and a second press re-applies it), and closing
  //     the menu releases it either way. A level owned by the OS with no way
  //     out is a latch, and one spurious notify would leave the panel stopped
  //     with the menu gone.
  //
  // A host reset (command 0x50) drops the user's pause: the next boot must not
  // start frozen.
  wire pause_btn = cont1_key[14];          // the Pocket's Select

  reg pause_prev   = 1'b0;
  reg pause_armed  = 1'b0;
  reg pause_user   = 1'b0;
  reg menu_escaped = 1'b0;

  wire menu_pause = osnotify_inmenu & ~menu_escaped;

  always @(posedge clk_74a) begin
    pause_prev <= pause_btn;

    if (!pause_btn)
      pause_armed <= 1'b1;               // seen up: the next press is a press

    if (external_reset) begin
      pause_user   <= 1'b0;
      menu_escaped <= 1'b0;
    end
    // Loading a cartridge takes the pause back too. A pause left standing over
    // a download would be a console that boots frozen: `dl_wait` holds the
    // machine in reset for the whole transfer, and the level would still be up
    // when the new game's first instruction is fetched.
    else if (cf_push) begin
      pause_user <= 1'b0;
    end
    else if (pause_btn && !pause_prev && pause_armed) begin
      pause_user <= ~pause_user;
      if (osnotify_inmenu)
        menu_escaped <= ~menu_escaped;   // the user takes the menu's pause back
    end
    else if (!osnotify_inmenu)
      menu_escaped <= 1'b0;              // the OS let go: so do we
  end

  /* A QUIT IS NOT THIS CORE'S BUSINESS (2026-11-03).
   *
   * This used to hold the machine in RESET for `[0010 Reset Enter]`, and then --
   * once that was found to kill the picture -- in PAUSE instead, on Analogue's
   * words "core stops execution". It now does neither, and the reason is that
   * the thing the pause was protecting is protected by construction:
   * rtl/gt_video.sv's reset is tied to 1'b0, so the raster, DE, HS and VS come
   * from its own counters and no reset or pause in this core can stop them. A
   * paused machine and a running one look identical out of the scaler.
   *
   * What is left is the difference between this core's quit and every other
   * core's: they do nothing at all on `[0010]`, and now so does this one. The
   * console runs until the bitstream is wiped, which is exactly what a stock
   * core on this card does, and what quits cleanly on it.
   *
   * The two pauses that remain are the ones with a reason:
   *   * `pause_user` -- the console's own Select, the player's pause;
   *   * `menu_pause` -- the OS opened its menu over the picture, so the game must
   *     not run underneath it.
   *
   * `[0010]` still does its documented job, in rtl/core_bridge_cmd.v: it latches
   * `reset_n` (which stops the data-slot write handshake waiting for the boot
   * gate) and drops any target marker the core might be holding. The machine is
   * not touched. */
  wire pause_req = pause_user | menu_pause;

  // ---- into the machine's clock ----
  reg [1:0] pause_s = 2'b0;

  always @(posedge clk_core)
    pause_s <= {pause_s[0], pause_req};

  wire machine_pause = pause_s[1];

  // ------------------------------------------------------------------- machine
  //
  // One console. The machine is held in reset until the PLLs are locked (or
  // the boot timer has expired), while the OS resets the core, and for as long
  // as the cartridge loader says it is running (dl_wait).
  wire [14:0] cart_addr;
  wire [ 7:0] cart_data;
  wire        dl_busy, dl_wait;
  wire [21:0] cart_size;
  wire [21:16] cram_a;
  wire [15:0]  cram_dq_out;
  wire         cram_dq_oe;
  wire [15:0]  cram_dq_in;
  wire [7:0]  joy1, joy2;
  wire        m_ce, m_de, m_hs, m_vs;
  wire [23:0] m_rgb;
  wire [15:0] m_audio_l, m_audio_r;

  reg core_ready_c1 = 1'b0, core_ready_c2 = 1'b0, dl_wait_c = 1'b0;

  always @(posedge clk_core) begin
    core_ready_c1 <= core_ready;
    core_ready_c2 <= core_ready_c1;
    dl_wait_c     <= dl_wait;
  end

  /* THE MACHINE IS NOT PART OF THE SHUTDOWN (2026-11-03).
   *
   * Analogue's Core Boot Process, under Shutdown, says "Pocket sends [0010 Reset
   * Enter] and core stops execution", and this core has now tried both ways of
   * honouring it: holding the machine in RESET (which stops the raster, which
   * loses the scaler), and holding it in PAUSE (which stops only the CPUs, and
   * which nothing here needs). Both are gone. rtl/gt_video.sv's reset is tied to
   * 1'b0, so the picture is not the machine's to stop, and the console running
   * through a teardown is what every stock core on this card does.
   *
   * `[0010]` is still honoured where it belongs: rtl/core_bridge_cmd.v latches
   * `reset_n` on it. What that latch does here, and all it does here, is grant
   * the data-slot write handshake without waiting for the boot gate (below) and
   * mark the host as gone for the write ack. At launch `reset_n` powers up 1,
   * and neither command is sent around a load unless a slot sets data.json bit 6
   * (this package's slots do not), so nothing about booting changes.
   *
   * THE SAVE READ-OUT IS NOT AFFECTED, and that is the reason this is safe to
   * add now: rtl/gt_save_slot.sv's stream is reset by `core_ready_c2` and reads
   * through rtl/mem_bus.sv directly, not through the console. It serves the
   * whole 2 MB with the machine held -- sim/gt/tb_core_ss.cpp checks that case
   * by name ("save out/held: 8192 words read with the console in reset"). */
  /* THE HOST RESET IS HONOURED ONLY WHILE THE HOST IS STILL RUNNING (2026-11-03).
   *
   * `external_reset` is a write to 0x50, which holds the machine in reset for
   * 2^20 clk_74a -- 14 ms, about a frame. Since rtl/gt_video.sv's reset is tied
   * to 1'b0 that can no longer stop the picture, so this is not about the scaler
   * any more; it is about not resetting the console in the middle of the OS
   * reading the save slot out, which is what 0x50 is written for during a quit.
   * A reset there clears the frame store and puts the machine's own bus traffic
   * back on PSRAM while the read-out is streaming for no benefit at all -- the
   * console is about to be unloaded anyway.
   *
   * During a reload from the Core menu `reset_n` is high and this behaves
   * exactly as every other core's does, which is the case the write exists for. */
  wire external_reset_run = external_reset & reset_n;

  assign machine_reset = ~core_ready_c2 | external_reset_run | dl_wait_c;

  /* ---- THE BISECT SWITCH (2026-10-25) ---------------------------------
   * The panel: a save writes a complete, correct 36,920-byte state -- the .sta
   * on the card is 596 bytes of Pocket header plus the whole blob, tag 36,912,
   * `saves 1`, `drops 0`, `resets 0` -- and the Pocket reloads the core right
   * after it. Everything that differs from the core that saves fine on this
   * same hardware has been removed, so what is left is two halves and this one
   * build separates them:
   *
   *   1'b0  the engine produces the same word count through the same 0x4 window
   *         at the same rate, but takes nothing from the machine and never holds
   *         the CPU.   survives -> the WALK is the fault.
   *   1'b1  normal.    dies     -> the WALK is innocent, it is the transfer.
   *
   * It is a compile-time flag and not a constant so that this build can carry
   * it while every harness still runs the real engine: the sims never define
   * GT_SS_BISECT_NO_WALK, so they walk. Remove the VERILOG_MACRO from
   * rtl/ap_core.qsf for a real build. */
`ifdef GT_SS_BISECT_NO_WALK
  localparam GT_SS_WALK = 1'b0;
`else
  localparam GT_SS_WALK = 1'b1;
`endif

  gametank #(.SS_WALK(GT_SS_WALK)) machine (
      .clk_sys (clk_core),
      .reset   (machine_reset),
      .pause   (machine_pause),
      .clk_pix (clk_pix),
      .pix_ce  (1'b1),

      // Boot cart until a .gtr has been downloaded, rtl/cart.sv after that.
      .cart_addr (cart_addr),
      .cart_data (cart_data),
      .cart_present (cart_present),

      .dl_active (dl_stream),
      .dl_wr     (dl_wr_r),
      .dl_addr   (dl_addr_r),
      .dl_data   (dl_data_r),
      .dl_img_size (cart_decl_size),
      .dl_busy   (dl_busy),
      .dl_wait   (dl_wait),
      .cart_size (cart_size),

      // The game's `$90` "save finished" pulse. Nothing here consumes it now
      // that the core-side writer is gone; the port stays connected because the
      // machine still produces it and the harnesses instantiate the same module.
      .save_trig (),

      // The save state's black box (see THE BLACK BOX above).
      .ss_diag   (ss_diag),

      .sd_lba        (),
      .sd_rd         (),
      .sd_wr         (),
      .sd_ack        (1'b0),
      .sd_buff_addr  (9'h0),
      .sd_buff_dout  (8'h0),
      .sd_buff_din   (),
      .sd_buff_wr    (1'b0),
      .img_mounted   (1'b0),
      .img_readonly  (1'b1),
      .img_size      (64'h0),
      .bk_load       (1'b0),
      .bk_save       (1'b0),
      .autosave      (1'b0),
      .osd_open      (1'b0),

      .cram_a     (cram_a),
      .cram_dq_out(cram_dq_out),
      .cram_dq_oe (cram_dq_oe),
      .cram_dq_in (cram_dq_in),
      .cram_wait  (cram0_wait),
      .cram_clk   (cram0_clk),
      .cram_adv_n (cram0_adv_n),
      .cram_cre   (cram0_cre),
      .cram_ce0_n (cram0_ce0_n),
      .cram_ce1_n (cram0_ce1_n),
      .cram_oe_n  (cram0_oe_n),
      .cram_we_n  (cram0_we_n),
      .cram_ub_n  (cram0_ub_n),
      .cram_lb_n  (cram0_lb_n),

      .joy1 (joy1),
      .joy2 (joy2),

      .video_ce (m_ce),
      .video_de (m_de),
      .video_hs (m_hs),
      .video_vs (m_vs),
      .video_rgb(m_rgb),

      .audio_l (m_audio_l),
      .audio_r (m_audio_r),

      .ss_save_tog  (ss_save_tog),
      .ss_load_tog  (ss_load_tog),
      .ss_abort_tog (ss_abort_tog),
      .ss_save_data (ss_save_data),
      .ss_save_wr   (ss_save_wr),
      .ss_save_full (ss_save_full),
      .ss_load_rd   (ss_load_rd),
      .ss_load_data (ss_load_data),
      .ss_load_empty(ss_load_empty),
      .ss_busy      (ss_busy),
      .ss_load_done (ss_load_done),
      .ss_engine_err(ss_engine_err),

      .ps_rd       (ps_mem_rd),
      .ps_addr     (ps_mem_addr),
      .ps_burstcnt (ps_mem_burstcnt),
      .ps_dout     (ps_mem_dout),
      .ps_dout_ready(ps_mem_dout_ready),
      .ps_busy     (ps_mem_busy)
  );

  // ---------------------------------------------------------------------------
  //  Save states: the APF end
  //
  //  The OS reads and writes the blob through the 0x4 window, so the controller
  //  owns that decode; this core only has to answer its ack/busy/ok/err
  //  handshake (core_bridge_cmd's commands 0x00A0 / 0x00A4) and carry the two
  //  streams to the engine in the machine's clock domain.
  //
  //  The staging buffer is the load side: the OS fills the 0x4 window with the
  //  whole file and only then commands the load, so every word of it has to fit.
  //  A 4,096-word buffer was tried on 2026-11-01 and dropped the tail. The save
  //  direction streams instead -- GameTank's engine is faster than the host (a
  //  byte per clock against two bridge accesses per word) and honours
  //  `ss_save_full` -- which is why only the load sets the size.
  save_state_controller #(
      .STAGE_WORDS (SS_MAX_LOAD / 8),
      .MAX_WORDS   (SS_MAX_LOAD / 8),
      .TAG         (SS_TAG),
      // A load is only armed once the state's own word count has arrived, so a
      // short file is refused before the machine is touched (21.27).
      .STATE_WORDS (SS_BYTES / 8)
  ) save_state_controller (
      .clk_74a      (clk_74a),
      .reset_74a    (~core_ready),

      .bridge_wr      (bridge_wr),
      .bridge_rd      (bridge_rd),
      .bridge_addr    (bridge_addr),
      .bridge_wr_data (bridge_wr_data),
      .ss_rd_data     (ss_rd_data),

      .ss_start       (savestate_start),
      .ss_start_ack   (ss_start_ack),
      .ss_start_busy  (ss_start_busy),
      .ss_start_ok    (ss_start_ok),
      .ss_start_err   (ss_start_err),

      .ss_load        (savestate_load),
      .ss_load_ack    (ss_load_ack),
      .ss_load_busy   (ss_load_busy),
      .ss_load_ok     (ss_load_ok),
      .ss_load_err    (ss_load_err),

      .clk_core       (clk_core),
      .reset_core     (machine_reset),
      .save_tog       (ss_save_tog),
      .load_tog       (ss_load_tog),
      .abort_tog      (ss_abort_tog),
      .ss_busy        (ss_busy),
      .ss_load_done   (ss_load_done),
      .ss_engine_err  (ss_engine_err),

      .ss_save_data   (ss_save_data),
      .ss_save_wr     (ss_save_wr),
      .ss_save_full   (ss_save_full),
      .ss_load_rd     (ss_load_rd),
      .ss_load_data   (ss_load_data),
      .ss_load_empty  (ss_load_empty),

      .underrun       (ss_underrun),
      .overrun        (ss_overrun)
  );

  // ------------------------------------------------------------ no boot cart
  //
  // THIS CORE USED TO SERVE rtl/bootcart.mem (pads_demo.gtr) ON THIS BUS UNTIL
  // A .gtr ARRIVED. It is gone on purpose (2026-10-30): the pads demo's two
  // rows of eight blocks read as a fault or as a game, and a core that has not
  // been given a cartridge should look like one. The bus is tied to zero, so the
  // 65C02 never leaves its BRK loop; with the frame store cleared at power-up
  // (rtl/gt_video.sv) that is an empty machine, and core_top's video stage now
  // blanks the active window outright while `cart_present` is low, so the panel
  // is black -- not grey, not a pattern -- until rtl/cart.sv has a complete
  // image and its fixed bank.
  //
  // The raster is untouched: sync, DE and the scaler's lock come from
  // gt_video's own counters, not from the CPU, so a black picture is still a
  // legal picture and the download's ~0.5 s costs no video lock. The boot cart
  // lives on for the harnesses (tools/gt_sim.sh drives it into `cart_data`
  // directly), so the machine it exercises is unchanged.
  //
  // `cart_addr` is still driven by the machine even though nothing listens to
  // it now; leaving the port connected keeps the harness's view of the machine
  // identical.
  assign cart_data = 8'h00;

  assign cram0_a    = cram_a;
  assign cram0_dq   = cram_dq_oe ? cram_dq_out : 16'hzzzz;
  assign cram_dq_in = cram0_dq;

  // --------------------------------------------------------------------- pads
  //
  // The pad's three buttons are A, B and C, and the Pocket's face has four, so
  // C is on both X and Y: whichever of the two the hand finds, the pad sees the
  // third button. Start is the Pocket's Start, straight through -- the pad's
  // Start is D5 of its select-low read, a real game button. The Pocket's Select
  // is the core's pause instead (see above) and never reaches the pad.
  //
  //   joy1[7] Start   <- Start        joy1[3] Up    <- Up
  //   joy1[6] C       <- X or Y       joy1[2] Down  <- Down
  //   joy1[5] B       <- B            joy1[1] Left  <- Left
  //   joy1[4] A       <- A            joy1[0] Right <- Right
  assign joy1 = { cont1_key[15],                 // Start
                  cont1_key[6] | cont1_key[7],   // C (X or Y)
                  cont1_key[5],                  // B
                  cont1_key[4],                  // A
                  cont1_key[0],                  // Up
                  cont1_key[1],                  // Down
                  cont1_key[2],                  // Left
                  cont1_key[3] };                // Right

  assign joy2 = { cont2_key[15],
                  cont2_key[6] | cont2_key[7],
                  cont2_key[5],
                  cont2_key[4],
                  cont2_key[0],
                  cont2_key[1],
                  cont2_key[2],
                  cont2_key[3] };

  // --------------------------------------------------------------------- video
  //
  // The picture arrives registered on clk_pix, one pixel per cycle, and is
  // re-registered here so the bits that go to the DDR pads all come from one
  // pixel; the launch itself is apf_top's.
  reg [23:0] v_rgb = 24'h0;
  reg        v_de  = 1'b0;
  reg        v_hs  = 1'b0;
  reg        v_vs  = 1'b0;

  // The blanking is a level that changes when a download completes, i.e. at
  // most a few times a session. It is synchronised into the pixel domain rather
  // than used raw so a transition cannot land mid-word in the DDR launch.
  reg cp_s1 = 1'b0, cp_s2 = 1'b0, cp_seen = 1'b0;

  always @(posedge clk_pix) begin
    cp_s1 <= cart_present;
    cp_s2 <= cp_s1;
    // ONCE A CARTRIDGE HAS BEEN SHOWN, NEVER BLANK AGAIN. The black window is
    // for the start of a session, where there is genuinely nothing to show; a
    // reload or a slot access later on must not turn a running (or just
    // finished) game into a black screen -- the frozen last frame is the honest
    // picture there, and it is what the panel had before this gate existed.
    if (cp_s2) cp_seen <= 1'b1;
  end

  always @(posedge clk_pix) begin
    v_rgb <= (cp_s2 | cp_seen) ? m_rgb : 24'h0;
    v_de  <= m_de;
    v_hs  <= m_hs;
    v_vs  <= m_vs;
  end

  assign video_rgb = v_rgb;
  assign video_de  = v_de;
  assign video_hs  = v_hs;
  assign video_vs  = v_vs;

  // --------------------------------------------------------------------- audio
  gt_audio audio_out (
      .clk       (clk_core),
      .reset     (machine_reset),
      .level     (m_audio_l),
      .mute      (machine_pause),
      .clk_74a   (clk_74a),
      .audio_mclk(audio_mclk),
      .audio_lrck(audio_lrck),
      .audio_dac (audio_dac)
  );

endmodule
