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
   * and every net it owned -- its target-command outputs, its [0180] restore, its
   * interact hook -- are removed. The save path is the platform's: the OS reads
   * the Save data slot out at exit ([0080]) and writes it back at launch
   * ([0082]), and this core only serves that window. The 0x0300_0000 window it
   * used for a struct is gone; on a RAM32K cart the same 0x0200_0000 window
   * holds the 32 KB SRAM instead of the image (see the note below). */

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

  /* ---- ONE SAVE SLOT, TWO CARTRIDGE SAVE TYPES (2026-11-04) -----------
   *
   * A GameTank cartridge saves in one of two ways:
   *
   *   * a flash cart rewrites its own image. The save is the 2 MB cartridge,
   *     and the OS's Save slot carries that image (rtl/gt_save_slot.sv
   *     streams it back out of PSRAM at shutdown, rtl/cart.sv restores it at
   *     launch);
   *   * a RAM32K cart has 32 KB of battery-backed SRAM at $8000-$BFFF. The
   *     save is that array (rtl/gt_nvram.sv), and the emulator persists it
   *     as a 32 KB .sav as well.
   *
   * Both are the SAME data slot. The APF names a nonvolatile slot from slot
   * 0's filename plus that slot's first extension, so two slots whose first
   * extension is "sav" would be the same file on the card and would
   * overwrite each other. data.json therefore declares one Save slot, and
   * this core decides what it means from the cartridge in front of it: the
   * size word in the table below changes with it, and the OS writes the
   * 32 KB SRAM or the 2 MB image accordingly.
   *
   * THE CARTRIDGE SAYS WHICH, BEFORE THE SAVE ARRIVES. The signature is the
   * emulator's (gte.cpp, LoadRomFile): a 2 MB image whose bytes at $1FFFF0
   * are "SAVE" is Flash2M_RAM32K. It is captured here, on the slot-1 bridge
   * writes, not at the end of the download in rtl/cart.sv -- the OS starts
   * loading the Save slot as soon as the cartridge has been sent, and this
   * decision has to be made before the first save byte arrives. The first
   * word of a new cartridge clears it, so a different game cannot inherit
   * the last one's type. */
  wire slot1_hit = bridge_wr && (bridge_addr[31:28] == 4'h1);
  wire slot2_hit = bridge_wr && (bridge_addr[31:24] == 8'h02);

  reg [21:0] cart_decl_size = 22'd0;

  // The first word of any cartridge stream. Both the identity and the
  // signature restart here, so a new file cannot inherit either from the last
  // one -- see the capture below.
  wire cart_new = slot1_hit && (bridge_addr[20:0] == 21'h0000000);

  reg  [31:0] sig_word = 32'h0;
  always @(posedge clk_74a) begin
    if (cart_new)
      sig_word <= 32'h0;                  // a new image starts at offset 0
    else if (slot1_hit && (bridge_addr[20:0] == 21'h1FFFF0))
      sig_word <= bridge_wr_data;         // $1FFFF0..3 = "SAVE", little-endian
  end

  wire ram32k_s = (cart_decl_size == 22'h200000) &&
                  (sig_word == 32'h4556_4153);   // "SAVE" as a 32-bit word

  // The console sees the same decision through rtl/gametank.sv -> rtl/cart.sv.
  // It is latched at the end of the download there; by then this has been
  // stable for the whole cartridge transfer.
  reg ram32k_c1 = 1'b0, ram32k_c2 = 1'b0;
  always @(posedge clk_core) begin
    ram32k_c1 <= ram32k_s;
    ram32k_c2 <= ram32k_c1;
  end

  wire [31:0] nv_bridge_rdata;

  /* ---- the core's own save file (rtl/gt_save_file.sv) --------------------
   *
   * A save committed at the instant the game writes it, rather than at the
   * shutdown read-out -- see the module's own header. It needs three things
   * from here: the slot's window (it makes the HOST read it, through [0184), the
   * host's target-command channel, and a struct window at 0x0300_0000, which is
   * the second address below.
   */
  wire        sf_rd_hit;
  wire [31:0] sf_rd_data;
  wire        sf_slot_arm, sf_slot_full;
  wire [21:0] sf_slot_start;
  wire [8:0]  sf_slot_thresh;

  /* ---- what the game rewrote (2026-11-08) --------------------------------
   *
   * rtl/cart.sv counts the span in the machine's clock; the writer captures it
   * in clk_74a. `sf_span_req_c` is the request two flops into the machine's
   * clock, `sf_span_ack_c` is the answer back in its own, and the three values
   * are static from the ack until the next request -- so they cross as a bus
   * without a tear (the handshake is what makes that true; see rtl/cart.sv).
   */
  wire        sf_span_req, sf_span_ack_c, sf_span_any;
  wire [20:0] sf_span_lo, sf_span_hi;
  reg  [1:0]  sf_span_req_c = 2'b00;
  reg  [1:0]  sf_span_ack_s = 2'b00;
  wire [21:0] ss_win_words;
  wire        sf_t_write, sf_t_read, sf_t_getfile, sf_t_openfile, sf_t_flush;
  wire [15:0] sf_t_id;
  wire [31:0] sf_t_slotoffset, sf_t_bridgeaddr, sf_t_length;
  wire [31:0] sf_t_param, sf_t_resp;
  wire        sf_t_done;
  wire [2:0]  sf_t_err;
  wire        sf_busy, sf_done, sf_failed;

  /* ---- the launch restore, as a FALLBACK ONLY (2026-11-09) ---------------
   *
   * pocket/data.json marks the Save slot `"nonvolatile": false`, so the OS
   * never reads it out at quit: no read-out, no card traffic, no 2 MB write at
   * the end of a session. That is the whole point of the flag and it is what
   * makes the quit a command instead of a transfer.
   *
   * `"deferload"` STAYS FALSE, and that is the correction this build carries.
   * It was true, which told the framework not to load the `.sav` at launch --
   * so the boot had no save in it AND this core asked for one before the
   * framework had finished handing over the cartridge. The panel answered with
   * "error in framework: core not ready to run", which is the framework
   * waiting for a `[0140]` this core had already put in `target_0` and could
   * not get back to: the whole boot was being spent in data-slot commands.
   *
   * With it false the launch is the platform's own, exactly as in every build
   * of this core that booted: the framework loads the cartridge, then the
   * `.sav` into the same window, then sends `[008F]`. rtl/gt_save_file.sv only
   * has to write; it does not have to read the card back in.
   *
   * IT IS KEPT AS A FALLBACK, because that path is also what the note in
   * rtl/gt_save_file.sv is about: a build with this slot not nonvolatile wrote
   * nothing at all, and if that ever turns out to mean "not loaded either" the
   * core must still boot the game it has. So the restore runs only when the
   * framework did NOT put the slot in this launch -- see the arming below. In
   * the ordinary case it never runs, and the sim checks both cases by name.
   */

  // Declared above its use: this file is compiled as Verilog-2001, where a use
  // before the declaration is an implicit 1-bit net of the same name rather
  // than this signal.
  wire reset_n;                 // host has taken us out of reset

  wire sf_load_req;             // clk_74a pulse: restore the .sav; assigned below

  wire sf_load_busy;
  wire sf_load_done;
  wire        gt_save_trig;

  /* DECLARED HERE, DRIVEN FAR BELOW (2026-11-09). `sf_load_lost` is set when a
   * launch restore does not finish in time, and `save_trig_ok` is the writer's
   * trigger with it gated off -- a file that could not be read must not be
   * overwritten with a fresh game's save. Both are used at the save writer's
   * input, which is above the hold ceiling that drives them, and this file is
   * compiled as Verilog-2001: a use before the declaration would be an implicit
   * 1-bit net and a different signal. */
  reg         sf_load_lost = 1'b0;
  wire        save_trig_ok = gt_save_trig & ~sf_load_lost;

  // "the window holds this chunk": the writer's threshold is in 64-bit
  // entries, and the slot's count is the same unit.
  assign sf_slot_full = (ss_win_words >= {13'd0, sf_slot_thresh});

  // The span handshake, one synchroniser each way (see rtl/cart.sv's ports).
  always @(posedge clk_core)
    sf_span_req_c <= {sf_span_req_c[0], sf_span_req};

  always @(posedge clk_74a)
    sf_span_ack_s <= {sf_span_ack_s[0], sf_span_ack_c};

  always @(*) begin
    if (ss_rd_hit)
      bridge_rd_data = ss_rd_data;
    else if (sf_rd_hit)
      bridge_rd_data = sf_rd_data;          // gt_save_file's struct window
    else if (bridge_addr[31:24] == 8'h02)
      // The Save slot: the cartridge image, or the RAM32K SRAM.
      bridge_rd_data = ram32k_s ? nv_bridge_rdata : ps_bridge_rdata;
    else if (bridge_addr[31:24] == 8'hF8)
      bridge_rd_data = cmd_bridge_rd_data;
    else
      bridge_rd_data = 32'h0;
  end

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
   * is always before the transfer and never inside it.
   *
   * On a RAM32K cart the Save slot is the 32 KB array, which the bridge reads
   * directly; there is no stream to warm, and arming one would only make the
   * OS wait for PSRAM words it is not going to read. */
  wire sf_prearm = ~reset_n && !ram32k_s;

  // The slot's own "the host is reading the image out" level. Declared here with
  // `sf_prearm` rather than at its use below, because the machine's hold is
  // assembled from both (see `save_stream`).
  wire save_readout;
  // ... and whether the stream still needs the memory port (rtl/gt_save_slot.sv's
  // `hold_console`): the read-out outlives the FIFO's need for PSRAM by however
  // long the OS takes to write the card, and holding the CPU for that is a
  // frozen picture that looks like a crash.
  wire ss_hold_console;

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
   * THE RULE. What this word declares is the SLOT, and on a flash or EEPROM
   * cart the slot is the image region at PSRAM 0x100000 (rtl/gt_save_slot.sv
   * streams the whole of it), data.json declares that slot at 2 MB, and the OS
   * wrote the image there itself. Declaring anything else would be the core
   * telling the OS that the save file changed size, which is a different
   * operation with its own file handling. */
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

  /* AND NOW THE SLOT HAS TWO CONTENTS (2026-11-04).
   *
   * The paragraphs above are the history of the image case and are still
   * exactly right for it. What changed is that a RAM32K cart's save is its
   * 32 KB battery-backed SRAM, not the image. The same Save slot carries it --
   * two nonvolatile slots whose first extension is "sav" would be the same file
   * on the card -- the bridge routes the window to rtl/gt_nvram.sv, and this
   * word says 32,768 so the OS flushes 32 KB. `save_slot_size` below is the one
   * place that decides, and `ram32k_s` is known from the cartridge's own
   * signature before the Save slot loads. */

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
  /* ... AND A RUNTIME CARTRIDGE RELOAD IS STILL A CARTRIDGE (2026-11-04).
   *
   * `core_ready` is sticky, so "the first [0082] after reset" captured the
   * size once per power-up. A cartridge picked again from the core menu
   * without restarting the bitstream sends a new [0082] for slot 1, and the
   * old size stayed: a 2 MB RAM32K game launched after a 32 KB cart kept the
   * 32 KB identity (no SRAM save, 32 KB flush), and the reverse typed a
   * 32 KB cart as 2 MB. The size table is read at flush, so the save file
   * was the wrong size too.
   *
   * The capture is tied to the stream now: a [0082] records its size, and the
   * first byte written to slot 1 (offset 0) adopts it. That is the one moment
   * that is unambiguously the start of a cartridge transfer -- the Save slot
   * writes 0x02xxxxxx and never 0x1xxxxxxx -- and it happens on every load,
   * not only the first. The boot ordering still holds: slot 1's request is
   * the one in flight when its stream starts, and the capture below also
   * refuses the Save slot's id, so the Save slot's [0082] can never be the
   * size adopted. A request whose transfer never starts changes nothing. */
  /* ... AND ONLY THE CARTRIDGE SLOT'S REQUEST IS A DECLARATION (2026-11-04).
   *
   * The first version of the per-stream capture above recorded EVERY [0082],
   * and took whichever was last when a slot-1 stream began. Ordering makes
   * that the cartridge's request in every flow the APF documents, but a single
   * `[0082]` for the Save slot arriving before an unrequested slot-1 stream
   * would then hand this core the SAVE's size as the cartridge's identity: 32
   * KB for a RAM32K save types a 2 MB cartridge as an EEPROM, and the reverse
   * (a 2 MB save) types an EEPROM cart as Flash2M. The Save slot is id 2 in
   * data.json and every save path in this core already keys on that id, so a
   * request for it is never recorded here.
   *
   * A stream that begins with no cartridge request at all clears the identity
   * instead of inheriting the previous cartridge's. rtl/cart.sv then types the
   * image from what it actually received (`dl_size`), which is the fallback
   * used before the declared size existed -- wrong for a RAM32K save, but a
   * stale type from a different cartridge is worse: it would enable the SRAM
   * window, and flush, for a game that has none. */
  reg  [21:0] wr_req_size = 22'd0;        // last CARTRIDGE [0082]'s size
  reg         wr_req_seen = 1'b0;         // ... since the last capture

  always @(posedge clk_74a) begin
    if (~core_ready) begin
      cart_decl_size <= 22'd0;
      wr_req_seen    <= 1'b0;
    end
    else begin
      if (dataslot_requestwrite && (dataslot_requestwrite_id != 16'd2)) begin
        wr_req_size <= dataslot_requestwrite_size[21:0];
        wr_req_seen <= 1'b1;
      end
      // The first word of a slot-1 stream, on every load. Separate `if`, not
      // `else`: the request can still be high here (it is cleared when the
      // command FSM returns to idle, clocks after the ack), and it must not
      // mask the capture.
      if (cart_new) begin
        cart_decl_size <= wr_req_seen ? wr_req_size : 22'd0;
        wr_req_seen    <= 1'b0;
      end
    end
  end

  localparam [31:0] SAVE_SLOT_MAX = 32'd2097152;

  /* THE FILE IS THE IMAGE FROM ITS LOWEST CHANGED BYTE UP (2026-11-09).
   *
   * A 2 MB flash cartridge costs the player a 2 MB write on every quit, and
   * 92% of that file is the .gtr byte for byte: the game rewrote its save in
   * one corner of the flash and nothing else moved. The OS writes exactly the
   * number of bytes this table declares (Analogue, Core Boot Process: "taking
   * into account any changes the core may have written to the Dataslot
   * ID/Size Table, in case the file size should be expanded or shrunk"), so
   * the size is the lever, and the file becomes:
   *
   *     [the cartridge's first 128 bytes][the image from `sv_lo` to its end]
   *
   * The head is not padding, and it is a whole MEMORY BURST (2026-11-09).
   * rtl/core_top.v's restore probe compares a save's
   * first eight words against the cartridge's own and refuses the file if more
   * than one differs -- that is what stops one game's save being restored over
   * another. A file that began at `sv_lo` would fail that check by
   * construction, so it keeps the head, and the tail is found from the size:
   * `sv_lo = cart_size - (size - 128)`. No magic, no header word, and a file
   * written by an older build (size == cart_size) still reads as the raw image.
   *
   * 128 and not 32: rtl/gt_save_slot.sv fetches the window in sixteen-entry
   * bursts from consecutive image addresses, so the head/tail boundary has to
   * fall on a burst boundary or the rest of that burst answers the image where
   * the file wants the tail -- 96 wrong bytes at the start of every save. The
   * head is therefore one burst, and the eight words the probe compares are the
   * first eight of it.
   *
   * `sv_lo` is the lowest image byte changed since the cartridge loaded
   * (rtl/cart.sv's `worm_lo`), or the base the loaded file implies, whichever
   * is lower. It only falls: a byte the game rewrote stays rewritten.
   *
   * Only flash cartridges (over 1 MB) do this. An EEPROM cart's save is its
   * whole image and is a few KB, so the file stays exactly what it always was --
   * `diff`-able against the .gtr, and instant to write. */
  localparam [21:0] IMG_END = 22'h20_0000;

  wire [20:0] worm_lo;
  wire        worm_any;

  reg  [21:0] sv_lo      = IMG_END;   // lowest changed byte, or IMG_END: none
  reg  [21:0] sv_load_lo = 22'h0;     // ... the base the loaded file implies
  reg         sv_load_tail = 1'b0;    // ... and whether that file was a tail

  /* WHETHER A `.sav` WAS DELIVERED, AND WHAT IT SAID (2026-11-09).
   *
   * A flash cartridge that has never been written to has nothing to save: its
   * `.sav` would be the `.gtr` byte for byte, so it has nothing to declare and
   * the slot is not used: zero bytes (Analogue's own definition of the table's
   * size word). These two recognise the two ways a delivered file says it --
   * 128 bytes, the head alone with no tail, and 0 bytes with no data at all --
   * and both mean the loader mapped the file as the head and the rest of the
   * image is still the `.gtr`.
   *
   * The pair is needed because `sv_load_lo` cannot tell the two zero cases
   * apart: a whole-image `.sav` from an older build also leaves it at 0. Hence
   * `saw` (a [0082] for slot 2 arrived) and `head` (it announced a file no
   * bigger than the 128-byte head). A whole-image file is not touched: its
   * size stays the image's. */
  reg         sv_saw_req  = 1'b0;
  reg         sv_head_ok  = 1'b0;

  /* A BYTE THAT LANDED IN THE SLOT IS A DELIVERY, `[0082]` OR NOT (2026-11-09).
   *
   * The zero-byte answer below is keyed on "nothing was ever delivered", which
   * on paper is `~sv_saw_req`: the framework sends [0082] before any .sav it
   * loads, and a cartridge with no .sav at all sends nothing. But if a build of
   * the framework ever loads the slot without that command, the bytes alone
   * would restore the image while `sv_saw_req` stayed low -- and the quit would
   * then declare ZERO for a cartridge that had just had a save put in it, which
   * truncates the file. That is the one mistake in this path that destroys
   * data, so the fallback also demands that no slot-2 byte has landed: with a
   * write in the window the answer stays the image's size, i.e. a rewrite that
   * is merely slow, never a delete. */
  reg         sv_win_seen = 1'b0;     // any host byte into 0x02xxxxxx

  /* AN EMPTY FILE IS NOT A 2 MB IMAGE (2026-11-09).
   *
   * `head` used to mean "exactly 128", and 128 is only one of the two ways a
   * `.sav` says "this cartridge has not saved". The other is ZERO bytes: that
   * is what the OS leaves behind for a quit whose read-out never ran, and it
   * is the file a session that saved nothing starts from when the slot is
   * created empty. A zero-byte slot announces itself with `[0082]` and no
   * bytes at all, so `saw` rose and `head` did not -- and the table then said
   * `cart_size`, which makes the NEXT quit write back the whole 2 MB image of
   * a cartridge that had not changed. The panel read that as "there is already
   * a save and nothing to write, and the quit takes forever".
   *
   * A file of 1..127 bytes is in the same place: too short to be a tail
   * (`sv_pack_load` needs more than 128) and too short to be the image, so the
   * loader has mapped it as the head and the rest is still the `.gtr`. All
   * three sizes mean the same thing -- this cartridge has not saved -- and the
   * answer to them is the one below: zero bytes. */

  /* NOTHING TO SAVE IS STILL A SAVE, AND SAYING OTHERWISE IS AN ERROR
   * (2026-11-09, from the panel).
   *
   * There is no "skip this write-back" answer in the framework. `[0080 Data
   * slot request read]` takes a result code, and 1 is *not allowed ever* --
   * the protocol's "this slot can never be read", not "nothing changed". The
   * core answered it for a session that had written nothing since its save was
   * loaded, and the panel came back with `error in framework: slot 2 denied`:
   * the file was left alone, but the OS reported the slot as broken on the way
   * out. So the read-out always runs.
   *
   * What keeps it cheap is the SIZE, not a refusal, and the size for "nothing
   * happened" is ZERO (2026-11-09, the panel again). It used to be 128 -- the
   * file's head, "the image is still the .gtr" -- which is a true description
   * of the cartridge but still makes the OS create a 128-byte `.sav` for a
   * game that never saved, and the panel's next words were "there is still a
   * 128-byte file when there is no save".
   *
   * Analogue's Host/Target Commands defines the table's word 1: "Size of the
   * data slot. ZERO IF THE SLOT IS NOT USED." That is this case exactly, and
   * it is the only value that can mean it -- `[0080]`'s result codes have no
   * "skip" (1 is the `slot 2 denied` error, 2 is a hung quit), and the flush
   * "updates the filesize on SD if it changed", so 0 changes it to nothing.
   * rtl/gt_save_slot.sv's `empty` is the other half: a zero-byte file is zero
   * words to stream, so the read-out is answered at once instead of waiting
   * for a window that can never fill.
   *
   * A cartridge that DID save declares head + tail below its lowest written
   * byte, a RAM32K cart declares its 32 KB array, and 0 is never one of those
   * (see `sv_tail`, which any program or erase raises). */

  /* THE SIZE IS A PIPELINE, NOT A 22 ns CONE (2026-11-09).
   *
   * Measured, not guessed. The 14:40 fit's worst path on the host clock was:
   *
   *   cart_decl_size[11] -> ram32k_s -> cart_size -> sv_lo_use (min)
   *     -> sv_tail_base (max 128) -> sv_tail (<) -> save_slot_size
   *     -> empty (== 0) -> span_words_74 -> wbin_s (==) -> hold_console
   *
   * 22.214 ns of arrival against a 17.420 ns requirement, -4.794 ns. Every term
   * is quasi-static -- the cartridge's size, the lowest byte the game has
   * written -- and all of it was being recomputed combinationally inside the
   * save slot's hold decision, at 74 MHz. Raising the fitter's effort moved it
   * 0.38 ns: it is logic, not placement.
   *
   * So the arithmetic is a pipeline in clk_74a, one short stage per clock: the
   * size and the base, then the tail, then the file's size, then "is it
   * empty". A cartridge load or a game's write settles in a handful of clocks
   * instead of having to settle inside one. Nothing downstream notices: the
   * slot is armed tens of milliseconds before it is read, and the Dataslot
   * ID/Size Table is checked at the flush.
   *
   * Clamped to this cartridge, and only a tail when something is below the top.
   */
  reg  [21:0] sv_cs_q     = 22'd0;      // cart_size, one stage in
  reg         sv_ram_q    = 1'b0;       // ... and its RAM32K decision
  reg  [21:0] sv_lo_use_q = 22'h3F_FFFF;
  reg  [21:0] sv_base_q   = 22'd128;
  reg         sv_tail_q   = 1'b0;
  reg         sv_head_q   = 1'b0;
  reg  [31:0] sv_size_q   = SAVE_SLOT_MAX;
  reg         sv_empty_q  = 1'b0;

  /* THE HEAD IS NOT PART OF THE TAIL (2026-11-09).
   *
   * A chip erase ($10) reports its range from image byte 0, and so does a
   * program into the vector area, so `sv_lo` can be below the 128 bytes the
   * file's head already covers. Sizing the tail from there wrote
   * `cart_size + 128` bytes -- past the slot's `size_maximum` -- and the next
   * launch reads such a file raw (its size is not below the image's), so every
   * byte after the head landed 128 bytes high: the shift bug again, from a
   * save that did nothing wrong. Clamping the base to the head makes that case
   * exactly what it is, the whole image head-first, which is the file an older
   * build wrote and which the loader already maps without a tail. */
  wire [21:0] sv_base_c = (sv_lo_use_q < 22'd128) ? 22'd128 : sv_lo_use_q;
  wire        sv_tail_c = !sv_ram_q && (sv_cs_q > 22'h10_0000) &&
                          (sv_base_c < sv_cs_q);

  /* ... AND A FLASH CARTRIDGE WHOSE IMAGE IS STILL THE `.gtr`: NOTHING TO
   * WRITE, SO THE SLOT DECLARES ZERO BYTES AND THE OS HAS NO FILE TO MAKE.
   *
   * This used to hold only above 1 MB, on the argument that a small cartridge's
   * save IS its whole image and the format does not change there. That is true
   * of the FORMAT and false of the question being asked: an 8 KB Cubicle Knight
   * that has not saved is in exactly the same position as a 2 MB Minicraft, and
   * the panel's complaint -- "a .sav file when there is no save" -- is the same
   * complaint at 8 KB as at 2 MB, only cheaper. The tail format stays gated at
   * 1 MB because there the head+tail is what saves the transfer; the zero is
   * not a format, it is "the slot is not used", and it is available at any size.
   *
   * The safety of the zero is `sv_head_ok` (the framework announced a file no
   * bigger than the head) plus the fallback for a cartridge that has no `.sav`
   * at all, where the framework announces nothing. That fallback also demands
   * `~sv_win_seen`: if bytes landed in the slot without a `[0082]`, the slot is
   * NOT unused, and the answer has to stay the image's size. Declaring zero
   * there would truncate a save the framework had just restored. */
  wire        sv_head_c = !sv_ram_q && !sv_tail_c &&
                          (sv_head_ok | (~sv_saw_req && !sv_win_seen));

  /* THE CARTRIDGE WHOSE .sav MAY HAVE A TAIL (2026-11-09).
   *
   * The format above is only ever used on a flash cartridge over 1 MB, and only
   * for files this build wrote (an old whole-image .sav still reads as one, its
   * size being the image's). This is that cartridge, independent of whether a
   * save has happened yet -- the launch restore needs to know BEFORE any change
   * exists, see the arm far below. */
  wire        sf_tail_cart = !ram32k_s && (cart_size > 22'h10_0000);

  /* WHAT THIS SLOT HOLDS ON THIS CARTRIDGE (2026-11-04). A flash cart's save
   * is its image from the lowest changed byte; a RAM32K cart's is only the
   * 32 KB SRAM, and reporting 2 MB for it would make the OS flush 2 MB of
   * address space that aliases the same 32 KB over and over. Before a cartridge
   * is loaded the maximum is the only safe answer; the value settles by the end
   * of slot 1's transfer and is written by the FSM below. */
  /* ... and the four stages themselves. Each assignment reads only registers,
   * so each one has a single 22-bit compare or add to do in 13.5 ns. The HEAD
   * and the TAIL are decided on the SAME stage: `sv_size_q` reads both from
   * flops, so it can never see a new tail next to a stale head. */
  wire [21:0] sv_tword_q = sv_lo_use_q[21:3];

  always @(posedge clk_74a) begin
      sv_cs_q     <= cart_size;
      sv_ram_q    <= ram32k_s;

      sv_lo_use_q <= (sv_lo > sv_cs_q) ? sv_cs_q : sv_lo;
      sv_base_q   <= sv_base_c;

      sv_tail_q   <= sv_tail_c;
      sv_head_q   <= sv_head_c;

      sv_size_q   <= sv_ram_q ? 32'd32768 :
                     (sv_cs_q == 22'd0) ? SAVE_SLOT_MAX :
                     sv_tail_q ? (128 + {10'd0, sv_cs_q} - {10'd0, sv_base_q}) :
                     sv_head_q ? 32'd0 : {10'd0, sv_cs_q};

      sv_empty_q  <= (sv_size_q == 32'd0);
  end

  // The registered answer, under the name everything below already uses.
  wire [31:0] save_slot_size = sv_size_q;

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
   * The value is constant while a cartridge is loaded -- it is what the Save
   * slot holds for that cartridge, known by the end of slot 1's transfer. So
   * it is written when it CHANGES, plus a slow refresh (one write per 2^16
   * clocks, ~0.9 ms) so that a value the OS clobbers through its own port is
   * still put back. The
   * collision window goes from one clock in four to one in sixty-five thousand,
   * and an unchanged session writes the table about a thousand times in ten
   * minutes instead of eleven billion. */
  /* ... AND THE REFRESH IS HELD OFF WHILE THE HOST IS READING THE SLOT
   * (2026-11-07).
   *
   * `mf_datatable` is a true dual-port altsyncram with independent clocks and
   * no read-during-write bypass, so a host read that lands on the same clock as
   * one of these writes returns a value the core never chose -- and word 3 is
   * the SIZE the OS opens the `.sav` at. The refresh was already cut to one
   * write in 65,536 for that reason, but the exposure is proportional to how
   * long the flush lasts: an 8 KB save-out is ~18 refresh periods, a 2 MB one
   * is ~670, which is the only thing in this path that differs by cart size.
   * (The card has one of each: `Cubicle Knight.sav` 8,192 bytes perfect, and a
   * 0-byte `Minicraft.sav` from a 2 MB cart whose flush never wrote.)
   *
   * `save_readout` is the slot's own level and is high from `[0080]` until
   * `[008F]` -- exactly the window in which the OS reads the window and the
   * table. Suppressing the refresh there still leaves the write-on-change, so a
   * value the OS needs is never withheld; the periodic write is only there to
   * put back a value the OS clobbered through its own port, and the OS does not
   * write the table while it is reading a slot out. */
  wire dt_quiet = save_readout | sf_prearm;

  localparam [15:0] DT_REFRESH = 16'hFFFF;

  reg [15:0] dt_tick = 16'h0;
  reg [31:0] dt_last = 32'hFFFF_FFFF;
  reg        dt_wr   = 1'b0;

  /* THE SLOT'S SIZE IS THE FILE'S, AND IT IS THE LEVER (2026-11-09).
   *
   * The slot is `nonvolatile: true` (the only way a `.sav` exists at all), so
   * the OS reads it out at quit and writes the file at exactly this size:
   * "taking into account any changes the core may have written to the Dataslot
   * ID/Size Table, in case the file size should be expanded or shrunk". That
   * is why the tail above shrinks the file instead of only shortening the
   * core's own write: the platform's read-out obeys the same word. It is also
   * what makes [0190]/[0192] valid for the slot. */
  wire [31:0] dt_value = save_slot_size;

  always @(posedge clk_74a) begin
    dt_tick <= (dt_tick == DT_REFRESH) ? 16'h0 : dt_tick + 16'd1;

    if (dt_value != dt_last) begin
      dt_last <= dt_value;
      dt_wr   <= 1'b1;
    end else if ((dt_tick == DT_REFRESH) && !dt_quiet) begin
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
   * 32'h40_000 : 32'h0`, never reversed). The table FSM above stores it the
   * same way. */
  assign datatable_data = dt_value;

  // ---- save-slot read request/ack --------------------------------------
  /* THE SAVE SLOT IS READ IN TWO WAYS (2026-11-04).
   *
   * It is still slot id 2, and `[0080]` still names it. On a flash or EEPROM
   * cart it holds the cartridge image, which lives in PSRAM, so the read has
   * to arm rtl/gt_save_slot.sv's stream and wait for its first word. On a
   * RAM32K cart it holds the 32 KB array, which is always resident and sits
   * directly on the bridge, so the read is acked at once and served by the
   * window. An unknown id is acked immediately too, exactly like a
   * nonvolatile slot that has nothing to stream. */
  wire save_req_read = dataslot_requestread &&
                       (dataslot_requestread_id == 16'd2) &&
                       !ram32k_s;
  wire ps_req_read  = save_req_read;
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

  /* ---- the RAM32K save RAM, inside the Save slot -----------------------
   *
   * The console side comes up through rtl/gametank.sv; the bridge side is the
   * SAME window as the image (0x0200_0000), because on a RAM32K cart the Save
   * slot holds this array instead of the image. It needs no stream and no ack
   * beyond the one `[0080]` already gets: rtl/gt_nvram.sv reads the addressed
   * word every clock, so the bridge's four-cycle address-to-sample window is
   * already covered. On every other cart the window belongs to
   * rtl/gt_save_slot.sv and this array is never selected. */
  /* AN OLD IMAGE `.sav` IS NOT AN SRAM IMAGE (2026-11-04).
   *
   * Before this build, every GameTank save was the cartridge image, so a
   * RAM32K game on the card already has a 2 MB `<rom>.sav` next to it. That
   * file is now loaded into 0x0200_0000 too -- and on a RAM32K cart that
   * window is the 32 KB array, whose address is only `bridge_addr[14:2]`.
   * The stream would wrap every 32 KB and leave the array holding an
   * arbitrary slice of the cartridge, which the game reads as a corrupt
   * save.
   *
   * The slot's own `[0082]` says how many bytes are coming, so the array
   * accepts the transfer only when that is no larger than the part: a real
   * SRAM save is exactly 32 KB, and an image save is refused whole rather
   * than truncated (its first 32 KB are the cartridge's entry code, not
   * SRAM). The OS reads the size table back when it flushes, so the stale
   * file is rewritten at 32 KB on the first clean quit. */
  wire        nv_size_ok  = (dataslot_requestwrite_size <= 32'd32768);
  wire        nv_bridge_we = slot2_hit && ram32k_s && nv_size_ok;

  /* ... AND THE CONSOLE WAITS FOR IT, AS IT DOES FOR THE IMAGE (2026-11-04).
   *
   * On a flash cart the restore is pushed through the download FIFO, so
   * `dl_stream`/`dl_wait` hold the machine in reset for the length of the
   * transfer and the game boots from a complete save. The SRAM path does not
   * touch that FIFO -- the bytes go straight to rtl/gt_nvram.sv -- so nothing
   * held the console: the game's first instructions could run while the 32 KB
   * was still arriving and read a half-restored save.
   *
   * `nv_loading` is raised by the Save slot's own `[0082]` (after the
   * cartridge has been identified) and lowered when the declared number of
   * bytes has been accepted. The timeout is deliberately two different
   * lengths: 2^24 clk_74a (~226 ms) BEFORE the first word, because the host
   * still has to read the file off the card after acknowledging the request,
   * and 2^20 (~14 ms) between words once the stream is moving. Either way a
   * transfer that stops releases the console, so a bad load cannot leave a
   * black screen. A refused old image save (`nv_size_ok` false) never raises
   * it: that data is ignored, and the game should boot on the zeroed array
   * instead of waiting for it. */
  wire        nv_req    = dataslot_requestwrite &&
                          (dataslot_requestwrite_id == 16'd2) &&
                          ram32k_s && nv_size_ok;
  wire [15:0] nv_len    = dataslot_requestwrite_size[15:0];

  reg         nv_loading = 1'b0;
  reg  [15:0] nv_seen    = 16'd0;         // accepted bytes of this transfer
  reg  [23:0] nv_idle    = 24'd0;         // clk_74a since the last accepted word
  wire [23:0] nv_limit   = (nv_seen == 16'd0) ? 24'hFF_FFFF : 24'h0F_FFFF;

  always @(posedge clk_74a) begin
    if (~reset_n || external_reset) begin
      nv_loading <= 1'b0;
      nv_seen    <= 16'd0;
      nv_idle    <= 24'd0;
    end else if (nv_req) begin
      nv_loading <= 1'b1;
      nv_seen    <= 16'd0;
      nv_idle    <= 24'd0;
    end else if (nv_loading) begin
      if (nv_bridge_we) begin
        nv_seen <= nv_seen + 16'd4;
        nv_idle <= 24'd0;
      end else if (nv_idle != nv_limit) begin
        nv_idle <= nv_idle + 24'd1;
      end

      if ((nv_seen + (nv_bridge_we ? 16'd4 : 16'd0)) >= nv_len)
        nv_loading <= 1'b0;
      else if (nv_idle == nv_limit)
        nv_loading <= 1'b0;
    end
  end

  // The hold is a level into the machine's clock; two flops, like ram32k.
  reg nv_load_c1 = 1'b0, nv_load_c2 = 1'b0;
  always @(posedge clk_core) begin
    nv_load_c1 <= nv_loading;
    nv_load_c2 <= nv_load_c1;
  end
  wire [14:0] nvram_addr;
  wire        nvram_wr;
  wire [7:0]  nvram_wdata;
  wire [7:0]  nvram_q;
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
      .file_arm     (sf_slot_arm),      // the core's own writer, no ack
      .file_start   (sf_slot_start),    // ... from this image word
      .tail_en      (sv_tail_q),        // the file is [head][tail], not the image
      .tail_word    (sv_tword_q),       // ... from this image word
      .empty        (sv_empty_q),       // nothing saved: zero words
      .ack          (ps_ack),
      .readout      (save_readout),
      .hold_console (ss_hold_console),
      .win_words    (ss_win_words),

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

  /* ---- the core's own save file ----------------------------------------
   *
   * The $90 pulse is 35 ns wide in the console's clock; two flops here and the
   * edge detector inside the module are what make that a reliable trigger. */
  reg [1:0] sf_trig_s = 2'b00;
  always @(posedge clk_74a)
    sf_trig_s <= {sf_trig_s[0], save_trig_ok};

  assign sf_rd_hit = (bridge_addr[31:24] == 8'h03);

  gt_save_file sfile (
      .clk         (clk_74a),
      .reset       (~core_ready_c2),

      .trig        (sf_trig_s[1]),
      .inmenu      (osnotify_inmenu),
      .have_img    (cart_size != 22'd0),
      .img_bytes   (save_slot_size),
      // THE WINDOW IS ALREADY THE FILE (2026-11-09). It is the head plus the
      // tail, i.e. exactly the bytes the OS reads at quit, and it is small -- so
      // this writer writes all of it and neither a span nor a launch-load
      // vouching for the file can make it wrong. `known` low is that statement:
      // every save is a full write of `save_slot_size` bytes from word 0.
      .file_ok     (1'b0),
      .span_ok     (1'b0),

      .span_req    (sf_span_req),
      .span_ack    (sf_span_ack_s[1]),
      .span_lo     (sf_span_lo),
      .span_hi     (sf_span_hi),
      .span_any    (sf_span_any),

      .slot_arm    (sf_slot_arm),
      .slot_start  (sf_slot_start),
      .slot_thresh (sf_slot_thresh),
      .slot_full   (sf_slot_full),

      .bridge_addr (bridge_addr),
      .bridge_rd   (bridge_rd),
      .rd_data     (sf_rd_data),
      .bridge_wr   (bridge_wr),
      .bridge_wr_data (bridge_wr_data),

      .t_write      (sf_t_write),
      .t_read       (sf_t_read),
      .t_getfile    (sf_t_getfile),
      .t_openfile   (sf_t_openfile),
      .t_flush      (sf_t_flush),
      .t_id         (sf_t_id),
      .t_slotoffset (sf_t_slotoffset),
      .t_bridgeaddr (sf_t_bridgeaddr),
      .t_length     (sf_t_length),
      .t_param_struct(sf_t_param),
      .t_resp_struct (sf_t_resp),
      .t_done       (sf_t_done),
      .t_err        (sf_t_err),

      .busy        (sf_busy),
      .done        (sf_done),
      .failed      (sf_failed),

      .load_req    (sf_load_req),
      .load_busy   (sf_load_busy),
      .load_done   (sf_load_done)
  );

  /* ---- the RAM32K save RAM, on both sides ------------------------------
   *
   * The 32 KB array is shared by the 6502 (two 16 KB banks at $8000-$BFFF,
   * decoded in rtl/cart.sv) and by the OS's Save slot (0x0200_0000, this
   * window) when the cart is a RAM32K. gt_nvram is a true dual-port RAM: the
   * CPU side is one byte per access, the Pocket side one 32-bit word, and
   * both outputs are registered. The bridge holds the address for four clocks
   * before it samples, so a continuously registered read at `bridge_addr`
   * answers it without a handshake. */
  gt_nvram nvram (
      .clk_core   (clk_core),
      .cpu_addr   (nvram_addr),
      .cpu_q      (nvram_q),
      .cpu_we     (nvram_wr),
      .cpu_wdata  (nvram_wdata),

      .clk_74a    (clk_74a),
      .ap_addr    (bridge_addr[14:2]),
      .ap_q       (nv_bridge_rdata),
      .ap_we      (nv_bridge_we),
      .ap_wdata   (bridge_wr_data),
      // A new cartridge starts from a fresh part: the previous game's SRAM
      // must never be read (or flushed) as this one's save. The clear runs
      // with the machine held by the cartridge download; see rtl/gt_nvram.sv.
      .clr        (cart_new)
  );

  /* THE CORE WRITES THE SAVE ITSELF, FOR LATENCY AND NOT FOR CORRECTNESS
   * (2026-11-07).
   *
   * The platform's writeback is the mechanism that works -- it reads the image
   * out of the Save slot at exit and writes the .sav, and it is the path this
   * core relies on. What it cannot do is be quick: measured at the APF's own
   * pace, a 2 MB image is 649.6 ms of host reading plus the OS's card writes, and
   * all of it happens with the console already being torn down. So a save that
   * a game commits mid-session is not on the card until the player quits.
   *
   * rtl/gt_save_file.sv closes that gap: on the game's own save event it walks
   * the image out through the host's [0184 in chunks the slot can actually keep
   * fed, then flushes the card with [0188. It is not a second source of truth --
   * the platform's exit writeback still lands on the .sav exactly as it did, so
   * a writer that gives up (it has timeouts, and latches `failed` rather than
   * retrying for ever) costs nothing but the early copy.
   *
   * It was removed on 2026-11-03 for the reason recorded below, and it is back
   * because the shutdown hang that killed it -- a `cm` marker standing in the
   * framework's target register while the OS closes the core -- is now handled
   * in rtl/core_bridge_cmd.v: a reset drops whatever is in flight (error 7) and
   * clears the queues, so nothing of ours is left pointing at a core that is
   * about to be reconfigured. */
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
   * black screen at quit, by the framework's own rules. A flash GameTank cart
   * has no battery-backed RAM: its save IS the cartridge image, and the OS
   * already reads that image out of the Save data slot at exit and writes it
   * back at launch. (A RAM32K cart does have 32 KB of SRAM; that is the Save
   * slot's other content, the array below, not a second file writer.) One
   * mechanism, the documented one, and nothing of this core's on the target
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
      // The Save slot waits for its stream's first word when it holds the
      // image; on a RAM32K cart the array is always resident, so its ack is
      // immediate -- and so is any id this build does not know.
      .dataslot_requestread_ack(save_req_read ? ps_ack : 1'b1),
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
      // THE FILE COMMANDS ARE THE CORE'S OWN AGAIN (2026-11-07): rtl/gt_save_file.sv
      // writes the image out on the game's save event and reads it back at
      // launch, so all five are driven by it rather than tied off.
      .target_dataslot_read      (sf_t_read),
      .target_dataslot_write     (sf_t_write),
      .target_dataslot_getfile   (sf_t_getfile),
      .target_dataslot_openfile  (sf_t_openfile),
      .target_dataslot_flush     (sf_t_flush),
      .target_dataslot_id        (sf_t_id),
      .target_dataslot_slotoffset(sf_t_slotoffset),
      .target_dataslot_bridgeaddr(sf_t_bridgeaddr),
      .target_dataslot_length    (sf_t_length),
      .target_dataslot_done      (sf_t_done),
      .target_dataslot_err       (sf_t_err),
      .target_buffer_param_struct(sf_t_param),
      .target_buffer_resp_struct (sf_t_resp),

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

  wire slot1_write = slot1_hit;

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
  // On a RAM32K cart the bytes at 0x02 are the 32 KB SRAM, not an image, so
  // they go straight to rtl/gt_nvram.sv and never enter the probe below.
  wire slot2_write = slot2_hit && !ram32k_s;

  // Bytes of image restored through the save slot, for the harnesses and the
  // debug tag: a save that arrives and is not counted is a save that did not.
  reg  [21:0] save_bytes /* verilator public_flat_rd */ = 22'd0;

  /* ---- THE WRITER IS TOLD NOTHING ABOUT THE FILE (2026-11-09) -----------
   *
   * rtl/gt_save_file.sv's `known` lets a save write only the changed span,
   * which is safe only if the `.sav` already holds every byte outside it. A
   * launch load does not establish that: it delivers a whole-image file and a
   * head+tail file identically -- the same [0082], the same declared length,
   * the same bytes -- and nothing in the stream says which one arrived. So
   * `file_ok` is tied to 0 at the instance and the first save of a session
   * writes the whole image, exactly as it does when there is no file at all.
   *
   * The probe that used to compute this lived here and compared the requested
   * size against the DECLARED size, which is true of both formats and so
   * proved nothing; it was removed rather than left reading as a guarantee.
   * Distinguishing them is possible (`cart_size` is one of the two lengths)
   * but it changes when a whole-image write is allowed to become a span write,
   * so it is a decision to make against a harness, not a tidy-up. */

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
  reg  [15:0] save_refused = 16'd0;

  /* THE CARTRIDGE'S OWN FIRST WORDS. Captured from slot 1 as it streams in,
   * because that is the only moment the cartridge is guaranteed to be the file
   * the user picked rather than whatever a previous restore left behind.
   * `ch_ok` says the capture is complete -- and it is deliberately NOT cleared
   * by `[0082]`, which arrives before the SAVE's download too. */
  reg  [31:0] ch_data  [0:SV_PROBE-1];
  reg  [3:0]  ch_idx   = 4'd0;             // four bits: three cannot hold 8
  reg         ch_ok    = 1'b0;

  /* A REQUEST'S LEVEL LINGERS; ITS START IS THE EDGE (2026-11-04).
   *
   * [0082] sets `dataslot_requestwrite` and the command FSM clears it only
   * when it returns to idle, clocks after the ack -- the same note the size
   * capture above makes. Resetting these counters on the LEVEL therefore
   * discards every slot word that arrives while it is still high: the
   * cartridge's first words never reach `ch_data`, so the probe compares a
   * save against a shifted head and refuses every restore for that boot
   * (silently: the game just boots without its save), or the save probe
   * restarts mid-stream. Both are captures that must begin once, at the
   * request, and then run to their own end. */
  reg  req_seen  = 1'b0;
  wire req_start = dataslot_requestwrite && !req_seen;

  always @(posedge clk_74a)
    req_seen <= dataslot_requestwrite;

  always @(posedge clk_74a) begin
    if (req_start)
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

  /* A SHORTER FILE'S OFFSETS ARE NOT THE IMAGE'S (2026-11-09). Its first 32
   * bytes are the cartridge's head and everything after them starts at the
   * tail's base, so a restore lands where the save actually lives instead of
   * over the cartridge's entry code. A raw file (size >= the image) leaves the
   * offsets exactly as they were. */
  wire [20:0] cf_waddr_sv = (sv_load_tail && (bridge_addr[20:0] >= 21'd128))
                          ? (sv_load_lo[20:0] + (bridge_addr[20:0] - 21'd128))
                          : bridge_addr[20:0];

  wire [20:0] cf_waddr  = sv_replay ? sv_haddr[sv_rp]
                        : sv_live    ? cf_waddr_sv
                        :              bridge_addr[20:0];
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
    else if (req_start) begin
      sv_st   <= SV_IDLE;
      sv_hidx <= 3'd0;
      sv_bad  <= 4'd0;
    end
    else begin
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

      /* A RESTORE ENDS ON THE HOST SAYING SO, NOT ON A PAUSE (2026-11-05).
       *
       * This used to leave on 2^20 clk_74a (14 ms) with no slot-2 write, on the
       * argument that a gap between two chunks of one restore is never that
       * long. It is. The OS does not stream a .sav in one burst: it reads a
       * chunk off the card, writes it into this window, and comes back -- and a
       * card that has to retry, or a progress redraw between chunks, is tens of
       * milliseconds. Measured in sim/gt/tb_core_ss.cpp: a single 1.2 M-tick
       * pause at a quarter of the image left `save_bytes` at 8,196 of 32,768.
       * Everything after the pause left SV_PASS, so `sv_live` went false and
       * the rest of the file was DROPPED -- a save the card says is there, half
       * restored, with no error anywhere. That is the 2026-11-02 failure
       * (window disarmed itself on silence) in the other direction.
       *
       * `[008F]` is what ends it, and it is a level that only `[0080]`/`[0082]`
       * clear -- so a manual load pressed while it is still high from the boot
       * is covered by its own `[0082]`, which drops the FSM to SV_IDLE below
       * before the first byte arrives. `req_start` is therefore what makes this
       * safe: EVERY download begins with a `[0082]`, and that re-arms the probe
       * no matter what the previous session left behind. A stream that never
       * sends `[008F]` (a manual load) simply stays passing, which is the state
       * that forwards bytes -- the failure mode is "keeps working", not "stops". */
      SV_PASS, SV_DROP: if (dataslot_allcomplete) begin
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

  /* ---- the base of the tail, in the host's own clock -------------------
   *
   * Two sources, and the lower one wins for the rest of the session:
   *
   *   * the file the OS just loaded, whose size says where its tail begins
   *     (`sv_lo = cart_size - (size - 32)`), and
   *   * the game's own writes since the cartridge was loaded, through
   *     rtl/cart.sv's `worm_lo`.
   *
   * The loaded base has to be taken at the slot's `[0082]`, before its bytes
   * arrive, because that is what the restore's offsets are measured from.
   * `sv_load_*` is that transfer's mapping; it is left standing afterwards
   * (there is only ever one boot restore) and is what `cf_waddr` below uses.
   *
   * Crossing: `worm_lo` only falls, so a torn sample can only be lower than the
   * truth -- which costs a few extra bytes in the file, never a changed byte
   * left out. The opposite mistake is the one that would eat a save. */
  wire [21:0] sv_req_size  = dataslot_requestwrite_size[21:0];
  wire        sv_pack_load = (dataslot_requestwrite_id == 16'd2) && !ram32k_s &&
                             (cart_size > 22'h10_0000) &&
                             (sv_req_size > 22'd128) &&
                             (sv_req_size < {1'b0, cart_size}) &&
                             (sv_req_size[2:0] == 3'b000);
  wire [21:0] sv_pack_lo   = cart_size - (sv_req_size - 22'd128);

  reg  [1:0]  sv_req_q    = 2'b00;
  reg  [20:0] worm_lo_s1  = 21'h1F_FFFF, worm_lo_s2 = 21'h1F_FFFF;
  reg         worm_any_s1 = 1'b0,        worm_any_s2 = 1'b0;

  always @(posedge clk_74a) begin
    sv_req_q    <= {sv_req_q[0], dataslot_requestwrite};
    worm_lo_s1  <= worm_lo;    worm_lo_s2  <= worm_lo_s1;
    worm_any_s1 <= worm_any;   worm_any_s2 <= worm_any_s1;

    if (cart_new) begin
      sv_lo        <= IMG_END;
      sv_load_lo   <= 22'h0;
      sv_load_tail <= 1'b0;
      sv_saw_req   <= 1'b0;
      sv_head_ok   <= 1'b0;
      sv_win_seen  <= 1'b0;
    end
    else begin
      /* Independent of the two below, not a branch of them: a bridge write and
       * a [0082] can land on the same clock, and making this an `else if` would
       * swallow that request edge for the rest of the session. */
      if (slot2_hit)
        sv_win_seen <= 1'b1;           // see its declaration: a delivery

      if (dataslot_requestwrite && !sv_req_q[1] &&
          (dataslot_requestwrite_id == 16'd2)) begin
        sv_saw_req   <= 1'b1;
        sv_head_ok   <= (sv_req_size <= 22'd128);
        sv_load_tail <= sv_pack_load;
        sv_load_lo   <= sv_pack_load ? sv_pack_lo : 22'h0;
        if (sv_pack_load && (sv_pack_lo < sv_lo))
          sv_lo <= sv_pack_lo;
      end
      else if (worm_any_s2 && (({1'b0, worm_lo_s2} & 22'h3F_FFF8) < sv_lo)) begin
        sv_lo <= {1'b0, worm_lo_s2} & 22'h3F_FFF8;
      end
    end
  end

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
  /* THE READ-OUT OWNS THE MEMORY PORT WHILE IT RUNS (2026-11-05, corrected
   * 2026-11-06 by what the card did).
   *
   * The save slot's stream is a PSRAM read (rtl/gt_save_slot.sv) and the
   * console is a PSRAM read too (rtl/cart.sv's bank cache, rtl/gram.sv's row
   * prefetcher) off the same chip. `rtl/mem_bus.sv` gives the save slot the
   * first turn of every arbitration, but a turn is a sixteen-beat burst: while
   * the console is mid-burst the stream waits for it, and while the CPU is
   * fetching code it asks again immediately. Measured in sim/gt/tb_slot.cpp,
   * the stream alone is 24.3 clk_core per 8-byte beat (9.4 MB/s) and the host
   * reads a word every ~80 clk_74a (3.7 MB/s) -- a 2.5x margin that sharing
   * the port halves.
   *
   * So the CPU is HELD for the `[0010]` window and for the whole read-out. Not
   * reset: `pause` only takes the CPU's clock enable (rtl/gametank.sv, `cpu_ce`),
   * so the machine stops where it is and resumes when the host lets go, and
   * rtl/gt_video.sv's raster is not this signal's to stop -- it holds the last
   * frame, which is what a console looks like at quit anyway.
   *
   * `sf_prearm` ALONE WAS NOT ENOUGH, AND THAT IS WHAT THE CARD SHOWED
   * (2026-11-06). It covers `[0010 Reset Enter]`, but the OS closes that with
   * `[0011]` before it sends `[0080]`, so the machine was live for the transfer
   * itself -- still executing, still fetching code out of the same PSRAM. A
   * saved file from the card reads as one image word in four: the host, the CPU,
   * rtl/gram.sv's row prefetcher and rtl/blitter.sv were sharing the port four
   * ways, which is also why the ack's 0.88 ms deadline expired with only ~60
   * words resident instead of 240. `save_readout` (rtl/gt_save_slot.sv) is the
   * level that says the host is actually reading, and holding the CPU for it is
   * what restores the measured margin: sim/gt/tb_cart_ss.cpp's `GT_SAVE_LIVE=1`
   * runs the transfer with the cartridge executing, and the file is
   * byte-identical at the APF's pace and at 2.6x it.
   *
   * The remaining consumer is the row prefetcher, which is not this signal's to
   * stop -- it fetches about a megabyte a second against the stream's nine, so
   * it costs headroom rather than the margin. */
  /* THE HOLD ENDS WHEN THE STREAM STOPS NEEDING THE PORT (2026-11-07).
   *
   * It was `sf_prearm | save_readout` -- the console paused for the whole
   * read-out. Measured in sim/gt/tb_core_ss.cpp at the APF's own pace, a 2 MB
   * save is 649.6 ms of read-out with the picture stopped for 100% of it, and
   * the OS's card writes come on top of that. The reason for the hold is
   * PSRAM contention (`save_readout`'s note above), and contention only exists
   * while the stream is fetching: with the window full it is parked and the
   * port is idle.
   *
   * So the slot decides, from the window's own occupancy, and this is the
   * permissive direction of that decision: whenever the slot asks, the CPU is
   * held exactly as before; the console only gains the microseconds where the
   * slot has nothing to ask for. */
  wire save_stream = sf_prearm | (save_readout & ss_hold_console);

  wire pause_req = pause_user | menu_pause | save_stream;

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

  /* WHICH MOMENT MAY ASK FOR A FILE, AND WHICH MUST NOT (2026-11-09).
   *
   * The cartridge stream ending (`dl_wait` falling) used to arm the restore,
   * and that is one slot too early: the framework loads the slots IN ORDER, so
   * the `.sav` is still coming when the cartridge's last byte lands. Issuing a
   * target command there puts a `cm` in `target_0` while the framework is still
   * streaming, and the request that was supposed to come next is the one it has
   * already been told about. The boot stalls exactly the way the panel reported.
   *
   * `[008F Data slot access all complete]` is the framework saying it is done
   * with every slot, and Analogue's Core Boot Process has it as the step before
   * `[0140]`: "Core may still request more slot ops" from that point on. Its
   * RISING EDGE, then, and nothing earlier. It is a level that stays high for
   * the rest of the session, so the edge is the event.
   *
   * AND IT ASKS NOTHING IF THE SLOT WAS DELIVERED. `slot2_seen` is any bridge
   * write into the Save slot's window during this launch (0x02xxxxxx, which is
   * the framework copying the `.sav` in). When that happened the image already
   * IS the save, the card has been read once, and a restore would read the same
   * bytes back a second time -- from the file this core last wrote, on a
   * cartridge whose `[0190]` name may not even resolve. So it is not run.
   *
   * `sf_boot_done` makes it once per cartridge. `cart_new` (the first word of a
   * new image) clears the lot, so a cartridge chosen from the menu is restored
   * on its own terms rather than inheriting the last one's. */
  reg  [1:0] sf_ac_s      = 2'b00;   // [008F], sampled in clk_74a
  reg        sf_boot_done = 1'b0;    // ... dealt with for this cartridge
  reg        sf_load_pend = 1'b0;    // ... armed, and waiting out the boot
  reg        sf_load_ev   = 1'b0;    // one clk_74a cycle
  reg        slot2_seen   = 1'b0;    // the OS put the .sav in itself this launch
  reg [27:0] sf_settle    = 28'd0;   // ... the wait above, in clk_74a

  /* THE REQUEST IS NOT THE SAME CYCLE AS `[008F]` (2026-11-09).
   *
   * Asked on the edge itself, the restore's `[0190]` went out while the
   * framework was still finishing its boot, and the panel answered with
   * "error in framework: core not ready to run" -- twice, and only ever on the
   * configs where the framework had NOT loaded the slot itself. A core that
   * asks for a file in that window is a core the framework is still waiting to
   * see become ready.
   *
   * `[008F]` is followed by the RTC, by `[0140]` and by the framework moving the
   * core to [Running] (Analogue, Core Boot Process, steps 12-16). Those are
   * milliseconds, so this waits a quarter of a second -- `SF_SETTLE` -- with the
   * console already held, and asks after that. The cost is a dark screen at
   * boot, which a stock core also has; the alternative is a core that does not
   * start at all. In sim the wait is shortened by `GT_SIM_QUICK_BOOT`; the
   * ordering, which is what this is for, is the same either way. */
`ifdef GT_SIM_QUICK_BOOT
  localparam [27:0] SF_SETTLE = 28'd2000;            // sim: the ordering only
`else
  localparam [27:0] SF_SETTLE = 28'd18_562_500;      // 250 ms at 74.25 MHz
`endif

  always @(posedge clk_74a) begin
    sf_ac_s <= {sf_ac_s[0], dataslot_allcomplete};

    /* ... AND THE DECLARATION IS ENOUGH, NOT JUST THE BYTES (2026-11-09).
     *
     * This used to mean "a byte landed at 0x02xxxxxx". A 0-byte `.sav` has no
     * bytes to land, so the slot looked ABSENT, and the fallback below asked
     * the host for a file the framework had already delivered -- one `[0190]`
     * and an open, on every boot of a cartridge whose save is empty, with the
     * console held through `SF_SETTLE` for nothing. `sv_saw_req` is the same
     * `[0082]`-for-slot-2 edge the size rule uses, and an empty delivery is
     * still a delivery: the file exists, and it says the image is the `.gtr`. */
    if (slot2_hit || sv_saw_req)
      slot2_seen <= 1'b1;

    if (cart_new) begin
      sf_boot_done <= 1'b0;
      sf_load_pend <= 1'b0;
      sf_settle    <= 28'd0;
      slot2_seen   <= 1'b0;
    end

    /* AND A `[008F]` WITH NO CARTRIDGE BEHIND IT ARMS NOTHING (2026-11-09).
     *
     * `cart_size` is what says a cartridge is loaded at all, and the framework
     * can send `[008F]` for a data phase that carried no cartridge -- the
     * harness does it by name. Armed there, the wait below could never complete
     * (there is no size to wait for) and the console would stay in reset while
     * the core looked perfectly idle: the save-state engine then never starts
     * and the panel has a core that runs nothing. So the size is a condition of
     * ARMING, and a wait that somehow gets nowhere drops its hold instead of
     * keeping it. */
    /* ... AND NOT AT ALL ON A CARTRIDGE WHOSE SAVE MAY HAVE A TAIL (2026-11-09).
     *
     * This restore reads the .sav itself and drops the bytes into the window at
     * their FILE offsets, because that is the only mapping it can know: it
     * learns a file's length by running off the end of it, which is after the
     * bytes have landed. A tail file's byte 128 is image byte `sv_lo`, not
     * image byte 128, so that restore would put the save at the wrong addresses -- the
     * one failure nobody may have. It is also unnecessary there: the slot is
     * `deferload: false`, so the framework has already streamed the .sav in and
     * `slot2_seen` is high (the mapping for that path comes from [0082]'s size,
     * which is exact). If the framework did not deliver it, the game boots from
     * the cartridge, exactly as it would with no save file, and nothing has
     * been written over. */
    if (sf_ac_s[0] && !sf_ac_s[1] && !sf_boot_done && !slot2_seen && !slot2_hit &&
        (cart_size != 22'd0) && !sf_tail_cart) begin
      sf_load_pend <= 1'b1;
      sf_settle    <= 28'd0;
    end

    sf_load_ev <= 1'b0;
    if (sf_load_pend) begin
      if (sf_settle != SF_SETTLE)
        sf_settle <= sf_settle + 28'd1;
      else begin
        sf_load_pend <= 1'b0;            // one shot either way
        if (!sf_boot_done && (cart_size != 22'd0)) begin
          sf_boot_done <= 1'b1;
          sf_load_ev   <= 1'b1;
        end
      end
    end
  end

  assign sf_load_req = sf_load_ev;
  wire [21:16] cram_a;
  wire [15:0]  cram_dq_out;
  wire         cram_dq_oe;
  wire [15:0]  cram_dq_in;
  wire [7:0]  joy1, joy2;
  wire        m_ce, m_de, m_hs, m_vs;
  wire [23:0] m_rgb;
  wire [15:0] m_audio_l, m_audio_r;

  reg core_ready_c1 = 1'b0, core_ready_c2 = 1'b0, dl_wait_c = 1'b0;
  reg sf_restore_c1 = 1'b0, sf_restore_c2 = 1'b0;

  /* THE CONSOLE WAITS FOR ITS OWN SAVE (2026-11-08).
   *
   * `load_busy` is high from the cycle the restore is requested until its last
   * chunk is back, and never during a save. The restore's own [0180] writes
   * also raise `dl_wait`, which holds the machine for the whole transfer; this
   * level closes the few cycles between the request and the first of those
   * writes, so the game never starts on an image that is about to change.
   */
  // ... and the settle above holds it too: the game must not start on an image
  // that is about to be replaced 250 ms later.
  wire sf_restore = sf_load_busy | sf_load_pend;

  always @(posedge clk_core) begin
    core_ready_c1 <= core_ready;
    core_ready_c2 <= core_ready_c1;
    dl_wait_c     <= dl_wait;

    // The restore's own hold, in this domain: the arming/settle/request levels
    // are clk_74a signals and the machine's reset is decided here.
    sf_restore_c1 <= sf_restore;
    sf_restore_c2 <= sf_restore_c1;
  end

  /* A STUCK RESTORE MAY NOT HOLD THE CONSOLE FOR EVER (2026-11-09).
   *
   * The restore is a fallback, and a fallback that wedges is worse than one
   * that gives up: the machine never leaves reset, there is no picture change
   * and the framework has a core that will never run. Every command has its
   * own timeout in rtl/core_bridge_cmd.v, but a *sequence* of them does not, and
   * 1,092 chunks is a long sequence.
   *
   * So the hold has a ceiling. Past it the console is let out and boots on the
   * image the framework delivered -- which is the state every build before this
   * one booted in. 100 M clk_core is 3.5 s, well past a 2 MB restore on a slow
   * card, and it restarts from zero the moment the restore stops asserting. */
  localparam [27:0] SF_HOLD_MAX = 28'd100_000_000;
  reg        [27:0] sf_hold_cnt = 28'd0;

  always @(posedge clk_core) begin
    if (sf_restore_c2) begin
      if (sf_hold_cnt != SF_HOLD_MAX)
        sf_hold_cnt <= sf_hold_cnt + 28'd1;
    end else
      sf_hold_cnt <= 28'd0;
  end

  wire sf_restore_hold = sf_restore_c2 && (sf_hold_cnt != SF_HOLD_MAX);

  /* ... AND A RESTORE THAT DID NOT FINISH MUST NOT BE ABLE TO EAT THE SAVE
   * (2026-11-09).
   *
   * The console is let out at the ceiling above, so the game boots on whatever
   * image the framework delivered -- that part is deliberate. But if the load
   * never happened, the image is the cartridge with a stale or absent save, and
   * the first thing a game does is write its own new save: this core would take
   * the player's `.sav` and replace it with a fresh-game one, silently. So a
   * restore that hit the ceiling latches this, and the writer is not triggered
   * for the rest of the cartridge. A save that was not read is not a save that
   * may be overwritten. */
  reg [1:0] cart_new_s = 2'b00;      // cart_new, in clk_core

  always @(posedge clk_core) begin
    cart_new_s <= {cart_new_s[0], cart_new};

    if (cart_new_s[1])
      sf_load_lost <= 1'b0;
    else if (sf_restore_c2 && (sf_hold_cnt == SF_HOLD_MAX))
      sf_load_lost <= 1'b1;
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

  /* THE STREAM'S SPEED, MEASURED (2026-11-05).
   *
   * `fill` in sim/gt/tb_slot.cpp counts the console clock and the stream's
   * beats inside the core, so the number does not depend on the harness's own
   * pacing: **24.34 clk_core per 8-byte beat, 9.41 MB/s**. The APF reads a
   * 4-byte word every ~80 clk_74a (3.7 MB/s), so the stream is 2.5x the host
   * with the port to itself.
   *
   * It does not have the port to itself while the console runs. rtl/mem_bus.sv
   * gives this client the first turn of every arbitration, but a turn is a
   * sixteen-beat burst: a CPU fetching code takes turns between the stream's,
   * which halves the rate to ~4.7 MB/s -- inside 1.3x of the host, and a margin
   * that thin is what the card's `.sav` was showing (three words in four zero).
   *
   * So the machine is PAUSED for the read-out (see `save_stream` above), not
   * reset and not left running. With the port to itself the window fills to its
   * 1,920-byte high-water mark, the ack waits for that (rtl/gt_save_slot.sv,
   * `ACK_WORDS`), and the host then reads a window that is full and stays full.
   * sim/gt/tb_cart_ss.cpp checks the resulting file against the cartridge
   * itself: identical, and identical again with the host reading at 2.6x the
   * APF's pace. */
  assign machine_reset = ~core_ready_c2 | external_reset_run | dl_wait_c |
                         nv_load_c2 | sf_restore_hold;   // a RAM32K save, and
                         // our own file, are still loading

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
      // ... and the read-out, so a flash program waits for the OS's .sav rather
      // than landing in the middle of it (rtl/cart.sv's `ss_readout`).
      .ss_readout (save_readout),
      .cart_present (cart_present),

      .dl_active (dl_stream),
      .dl_wr     (dl_wr_r),
      .dl_addr   (dl_addr_r),
      .dl_data   (dl_data_r),
      .dl_img_size (cart_decl_size),
      .ram32k_decl (ram32k_c2),
      .dl_busy   (dl_busy),
      .dl_wait   (dl_wait),
      .cart_size (cart_size),

      .nvram_q     (nvram_q),
      .nvram_addr  (nvram_addr),
      .nvram_wr    (nvram_wr),
      .nvram_wdata (nvram_wdata),

      // The game's own save event: `$90`, or a completed flash program/erase.
      // It is what rtl/gt_save_file.sv commits the `.sav` on -- every write
      // restarts its 150 ms settle timer, so a save burst is one file write.
      // `sf_load_lost` vetoes it for a cartridge whose restore never finished;
      // see the note above.
      .save_trig (gt_save_trig),

      .dspan_req (sf_span_req_c[1]),
      .dspan_ack (sf_span_ack_c),
      .dspan_lo  (sf_span_lo),
      .dspan_hi  (sf_span_hi),
      .dspan_any (sf_span_any),
      .worm_lo   (worm_lo),
      .worm_any  (worm_any),

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
