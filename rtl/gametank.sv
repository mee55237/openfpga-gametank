//============================================================================
//  GameTank core top
//
//  Everything console-side lives under this module; the MiSTer `emu` wrapper
//  (GameTank.sv) and the Verilator sim-top (sim/) both instantiate it, so it
//  must never reference sys/ or Quartus-only IP.
//
//  clk_sys is 28.636364 MHz (8× NTSC colorburst); all console logic runs on
//  clock-enables derived from it (CPU/blitter/ACP at ÷8 = 3.579545 MHz,
//  pixel at ÷4 — see docs/HARDWARE.md §Clocks).
//
//  M1: test pattern video, silent audio. The console guts arrive in M2+.
//============================================================================

module gametank
#(
    /* The save-state engine's walk. 1 is the only correct value; 0 exists for
     * the one bisect described at its instantiation below (the panel writes a
     * complete state and then reloads the core). The harnesses take the
     * default, so everything they check is the real engine. */
    parameter bit SS_WALK = 1'b1
) (
    input  logic        clk_sys,    // console clock: 28.636364 MHz on hardware
    input  logic        reset,

    // Video clock, from its own PLL on hardware: 2.25 MHz, which is
    // 150 x 250 x 60 Hz -- a 15 kHz line, 250 lines, the rates rtl/mc64_video.sv
    // is proven at on this panel. The picture is 128x128 at the frame origin,
    // with the gap after it, where the HS/VS go.
    // `pix_ce` is 1 there, because clk_pix IS the pixel clock; simulation has
    // no PLL, so it ties clk_pix to clk_sys and pulses pix_ce every 21 clocks.
    input  logic        clk_pix,
    input  logic        pix_ce,

    // Boot-cart bus: the $8000-$FFFF window is served from this external
    // ROM (wrapper: bootcart BRAM; sim: harness array) until a .gtr
    // download completes — then rtl/cart.sv takes over the window.
    output logic [14:0] cart_addr,
    input  logic [7:0]  cart_data,

    // The OS is streaming this image out (rtl/gt_save_slot.sv), in clk_74a. It
    // is not a reset and not a pause: rtl/cart.sv only uses it to make a flash
    // program wait, so the .sav the OS is reading cannot change under it.
    input  logic        ss_readout,

    // .gtr download stream into the PSRAM cartridge (loader / sim harness)
    input  logic        dl_active,
    input  logic        dl_wr,
    input  logic [20:0] dl_addr,
    input  logic [7:0]  dl_data,
    // The cartridge slot's declared size ([0082]), 0 when nothing declared it.
    // rtl/cart.sv takes the cart's type and size from this, never from what
    // the port received -- a .sav restore writes through the same port.
    input  logic [21:0] dl_img_size,
    // RAM32K signature, decided on the bridge side before the Save slot loads
    // (see rtl/core_top.v); rtl/cart.sv latches it at the end of the download.
    input  logic        ram32k_decl,
    output logic        dl_busy,
    output logic        dl_wait,   // keep the console in reset (fill running)
    output logic [21:0] cart_size, // bytes in the image (APF save slot size)

    /* ---- RAM32K save RAM (Flash2M_RAM32K carts) ------------------------
     *
     * The 32 KB array itself lives in rtl/core_top.v, in the Pocket's
     * clk_74a domain, because it is also the Save slot's storage on a RAM32K
     * cart. The machine only supplies the 6502 side: the bank-selected byte
     * address, the read byte, and the write pulse/data. Nothing here knows
     * what a data slot is. */
    input  logic [7:0]  nvram_q,
    output logic [14:0] nvram_addr,
    output logic        nvram_wr,
    output logic [7:0]  nvram_wdata,

    // flash-save persistence (hps_io SD block interface / sim harness)
    output logic [31:0] sd_lba,
    output logic        sd_rd,
    output logic        sd_wr,
    input  logic        sd_ack,
    input  logic [8:0]  sd_buff_addr,
    input  logic [7:0]  sd_buff_dout,
    output logic [7:0]  sd_buff_din,
    input  logic        sd_buff_wr,
    input  logic        img_mounted,
    input  logic        img_readonly,
    input  logic [63:0] img_size,
    input  logic        bk_load,
    input  logic        bk_save,
    input  logic        autosave,
    input  logic        osd_open,

    // The save state's black box (rtl/gt_savestates.sv): APF-side counters that
    // ride in the state's last special word, so a .sta file the OS wrote carries
    // what happened before it. Tied to zero by anything that has no APF side.
    input  logic [55:0] ss_diag,

    // PSRAM chip 0 (cram0): GRAM at byte 0, cartridge image at 0x100000.
    // This is the console's entire memory outside the FPGA -- see
    // rtl/mem_bus.sv for the arbitration and rtl/psram.sv for the transport.
    output logic [21:16] cram_a,
    output logic [15:0]  cram_dq_out,
    output logic         cram_dq_oe,
    input  logic [15:0]  cram_dq_in,
    input  logic         cram_wait,
    output logic         cram_clk,
    output logic         cram_adv_n,
    output logic         cram_cre,
    output logic         cram_ce0_n,
    output logic         cram_ce1_n,
    output logic         cram_oe_n,
    output logic         cram_we_n,
    output logic         cram_ub_n,
    output logic         cram_lb_n,

    // The core's pause: both CPUs stop where they are and the DAC holds its
    // last byte. Everything the picture depends on -- the raster, the frame
    // snapshot, the phase lock between them -- keeps running, because the
    // Pocket's scaler is synced to this core and a stopped raster would take
    // the picture off the panel instead of holding it (core_top's PAUSE
    // section). This is a level, not an edge.
    input  logic        pause,

    /* The Pocket's TV-mask checkbox (pocket/interact.json -> core_top). One
     * bit, quasi-static: set blanks rows 0..13 and 114..127 in rtl/gt_video.sv,
     * leaving the console's 128x100 TV-safe window. */
    input  logic        tv_mask,

    // gamepads (active high: 0=Right 1=Left 2=Down 3=Up 4=A 5=B 6=C 7=Start)
    input  logic [7:0]  joy1,
    input  logic [7:0]  joy2,

    // APF video port: 128x128 native, RGB565 left-aligned in the 24-bit word,
    // one pixel per video_ce. See rtl/gt_video.sv and pocket/video.json.
    output logic        video_ce,
    output logic        video_de,
    output logic        video_hs,
    output logic        video_vs,
    output logic [23:0] video_rgb,

    // 1 once a cartridge image is in PSRAM and its fixed bank has been copied.
    // rtl/core_top.v blanks the active picture while this is low; the harnesses
    // run the boot cartridge through the `cart_data` input with this low, so
    // they still see whatever they drive.
    output logic        cart_present,

    output logic [15:0] audio_l,
    output logic [15:0] audio_r,

    /* ---- save states (rtl/gt_savestates.sv) ----------------------------
     *
     * The APF end lives in rtl/core_top.v (it owns clk_74a and the bridge);
     * this is the machine side of the same handshake, in clk_sys. `ss_sleep`
     * comes back the other way through the CPU clock-enable, which is the
     * stop: the 65C02's RDY is held low for the whole transfer.
     */
    input  logic        ss_save_tog,
    input  logic        ss_load_tog,
    input  logic        ss_abort_tog,
    output logic [63:0] ss_save_data,
    output logic        ss_save_wr,
    input  logic        ss_save_full,
    output logic        ss_load_rd,
    input  logic [63:0] ss_load_data,
    input  logic        ss_load_empty,
    output logic        ss_busy,
    output logic        ss_load_done,
    output logic        ss_engine_err,

    /* ---- the Pocket save slot's read-ahead (rtl/gt_save_slot.sv) --------
     *
     * The OS saves a GameTank game by reading the cartridge image out of
     * PSRAM, so the save slot needs a bulk read client. It is a level request:
     * `ps_rd` stays up for the whole stream, and the client asks for 128-byte
     * bursts until it drops. Nothing here knows what a data slot is.
     */
    input  logic        ps_rd,
    input  logic [21:0] ps_addr,
    input  logic [7:0]  ps_burstcnt,
    output logic [63:0] ps_dout,
    output logic        ps_dout_ready,
    output logic        ps_busy,

    /* ---- the game's own save idiom, for the Pocket-side file writer ------
     *
     * rtl/cart.sv pulses this on the flash `$90` command prefix -- the SDK's
     * "I have finished writing my save" marker, and the trigger rtl/savectl.sv
     * has used since the MiSTer port. rtl/gt_save_file.sv takes it in clk_74a
     * and writes the image out to the card itself, because the OS's
     * nonvolatile writeback does not work on this core (see that file).
     */
    output logic        save_trig,

    /* ---- what the game rewrote, for the Pocket-side file writer ----------
     *
     * rtl/cart.sv holds the lowest and highest image byte programmed or erased
     * since the last capture; rtl/gt_save_file.sv asks for it (a handshake, in
     * its own clock) and writes only that span to the card instead of the whole
     * cartridge. See the ports in rtl/cart.sv. */
    input  logic        dspan_req,
    output logic        dspan_ack,
    output logic [20:0] dspan_lo,
    output logic [20:0] dspan_hi,
    output logic        dspan_any,

    /* The lowest image byte rewritten SINCE THE IMAGE WAS LOADED, which is what
     * sizes the .sav (rtl/core_top.v's `sv_lo`). Different question from the
     * span above, which is "since the last save"; see rtl/cart.sv's ports. */
    output logic [20:0] worm_lo,
    output logic        worm_any
);

// Audio coprocessor: unsigned 8-bit DAC level on both channels (AUDIO_S=0
// in the wrapper); the reconstruction filter lives in rtl/gt_audio.sv.
logic       acp_reset_we, acp_nmi_we, acp_rate_we, aram_we;
logic [7:0] aram_q;
logic [7:0] dac;

logic [63:0] acp_ss_q, acp_ss_st_in, acp_ss_st_out;
logic  [7:0] acp_rate_q;          // the ACP's own rate register
logic  [7:0] acp_rate_w;          // ... and the copy a load writes back

acp acp
(
    .clk_sys      (clk_sys),
    .reset        (reset),
    .pause        (pause | ss_sleep),

    .reg_reset_we (acp_reset_we),
    .reg_nmi_we   (acp_nmi_we),
    .reg_rate_we  (acp_rate_we),
    .reg_data     (win_din),

    .win_addr     (win_addr[11:0]),
    .win_we       (aram_we),
    .win_din      (win_din),
    .win_dout     (aram_q),

    .dac          (dac),

    .ss_reg_we    (ss_reg_we),
    .ss_PC        (ss_acp_PC),
    .ss_A         (ss_acp_A),
    .ss_X         (ss_acp_X),
    .ss_Y         (ss_acp_Y),
    .ss_S         (ss_acp_S),
    .ss_P         (ss_acp_P),
    .ss_q         (acp_ss_q),
    .ss_st_we     (ss_st_we),
    .ss_st_in     (acp_ss_st_out),
    .ss_st        (acp_ss_st_in),
    .ss_rate_in   (acp_rate_w),
    .ss_rate_we   (ss_reg_we),
    .ss_rate      (acp_rate_q)
);

// The AD7524 is an UNSIGNED byte with 0x80 at mid-scale (HARDWARE.md §Audio),
// so the level it means is (dac - 128) * 256, i.e. silence at 0 and +/-32768 at
// the ends. Writing `{dac, 8'h00}` instead sign-extends the top bit and puts
// silence at -32768 -- full-scale negative -- which leaves the music in the
// bottom half of the range where any downstream boost or sum clips one side of
// it. Flipping the top bit and letting the 16-bit word sign-extend IS that
// subtraction, so this is the whole fix.
assign audio_l = {dac ^ 8'h80, 8'h00};
assign audio_r = {dac ^ 8'h80, 8'h00};

// 3.579545 MHz clock-enable for the console (clk_sys / 8): the CPU's RDY
// strobe. All bus transactions latch at this strobe (see mainbus.sv).
// gram_stall/cart_stall freeze the cadence while a CPU read waits on PSRAM;
// blit_starve freezes it while the blitter waits on a GRAM row so the
// engine can never lag its exact-duration IRQ (documented deviations —
// real hardware never stalls; the raster keeps real time throughout).
logic [2:0] ce_div;
logic       cpu_ce  /*verilator public_flat_rd*/;
logic       blit_ce /*verilator public_flat_rd*/;
logic       gram_stall  /*verilator public_flat_rd*/;
logic       cart_stall  /*verilator public_flat_rd*/;
logic       blit_starve /*verilator public_flat_rd*/;

logic ss_sleep;

/* THE PAUSE STOPS THE CPUS, NOT A COPY ALREADY IN FLIGHT (2026-10-25).
 *
 * `pause` is the core menu (and the console's own Select), and `ss_sleep` is
 * the save-state engine holding the machine: both used to stop the blitter
 * dead in the middle of a copy, because the blitter took this same `cpu_ce`.
 * The engine then could not take a state at all -- it has to wait for
 * `blit_busy` to drop before it snapshots (rtl/gt_savestates.sv, FREEZE), and
 * the blitter was frozen by the very signal the engine was holding. A blit
 * still running when the menu opened was therefore a wedged core (tetris,
 * which blits continuously, every time), and a state saved while one was still
 * running carried half a copy of the framebuffer.
 *
 * So the copy gets its own clock-enable. It keeps the same cadence and the
 * same stalls (a starved GRAM row still stops the whole console, exactly as
 * before) and ignores only the pause and the engine's hold. A DMA engine that
 * finishes what it started is what the real hardware does; the CPUs stay
 * stopped, no new copy can be commanded while they are, and once `blit_busy`
 * falls the machine really is quiet. */
always_ff @(posedge clk_sys) begin
    if (reset) begin
        ce_div  <= '0;
        cpu_ce  <= 1'b0;
        blit_ce <= 1'b0;
    end
    else if (gram_stall || cart_stall || blit_starve) begin
        cpu_ce  <= 1'b0;
        blit_ce <= 1'b0;
    end
    else begin
        ce_div  <= ce_div + 3'd1;
        cpu_ce  <= (ce_div == 3'd7) && !pause && !ss_sleep;
        blit_ce <= (ce_div == 3'd7);
    end
end

logic [13:0] win_addr /*verilator public_flat_rd*/;
logic [7:0]  win_din;
logic        cpu_vram_we /*verilator public_flat_rd*/,
             cpu_gram_we /*verilator public_flat_rd*/,
             cpu_gram_rd /*verilator public_flat_rd*/,
             blit_param_we /*verilator public_flat_rd*/;
logic [7:0]  vram_a_dout, gram_b_dout;
logic [13:0] vram_b_addr;
logic [7:0]  vram_b_dout;
logic [13:0] scanout_addr;
logic [7:0]  scanout_data;
logic [13:0] gt_scan_addr;      // gtvideo's fetch address, before the tail mux
logic        snap_busy;         // frame_snapshot's copy/wait, which owns that read port
logic [7:0]  dma_ctl  /*verilator public_flat_rd*/;
logic [7:0]  bank_reg /*verilator public_flat_rd*/;
logic        blit_irq /*verilator public_flat_rd*/;
logic [1:0]  gram_mid;
logic        blit_busy;

mainbus mainbus
(
    .clk_sys       (clk_sys),
    .reset         (reset),
    .cpu_ce        (cpu_ce),

    .cart_addr     (cart_addr),
    .cart_rd       (cart_rd),
    .cart_wr       (cart_wr),
    .cart_wdata    (cart_wdata),
    .cart_data     (cart_present ? cart_int_data : cart_data),

    .win_addr      (win_addr),
    .win_din       (win_din),
    .vram_we       (cpu_vram_we),
    .gram_we       (cpu_gram_we),
    .gram_rd       (cpu_gram_rd),
    .blit_param_we (blit_param_we),
    .vram_dout     (vram_a_dout),
    .gram_dout     (gram_b_dout),

    .dma_ctl       (dma_ctl),
    .bank_reg      (bank_reg),

    .pad1_rd       (pad1_rd),
    .pad2_rd       (pad2_rd),
    .pad_q         (pad_q),

    .via_wen       (via_wen),
    .via_ren       (via_ren),
    /* THE REAL 6522 ANSWERS THE CPU AS OF 2026-11-03.
     *
     * Reads used to come from `via_shadow_q` -- the last byte written to each
     * of the sixteen registers -- because that is what the reference emulator
     * does (it has no timers at all) and every cartridge in the set was
     * developed against it. But the console has a real W65C22: the same
     * chip's model is instantiated below and driven with a 3.579545 MHz phi2,
     * and its `irq` is wire-OR'd into the CPU's IRQ line on the logic board
     * next to the blitter and the cartridge slot. A shadow read can never
     * return a counting timer, a pin, or an IFR bit a game can clear, so it
     * cannot be more right than the chip. What it buys is emulator parity;
     * what it costs is the only hardware-true interrupt path on the machine.
     *
     * The shadow itself stays: the cartridge bank SPI is driven from it
     * (the emulator ignores DDRA there and games depend on that), and it is
     * what a save state can carry. */
    .via_q         (via_q),

    .acp_reset_we  (acp_reset_we),
    .acp_nmi_we    (acp_nmi_we),
    .acp_rate_we   (acp_rate_we),
    .aram_we       (aram_we),
    .aram_q        (aram_q),

    /* Open-drain wire-OR on the logic board: blitter completion, the
     * cartridge slot's pin 21, and the 6522's IRQB all pull the CPU's IRQ
     * line. Only the first two were ever modelled here; the VIA's is real
     * now (it is the only interrupt a game can time against). */
    .irq           (blit_irq | via_irq),
    .nmi           (vsync_nmi && dma_ctl[2]),  // VSYNC_NMI enable

    // save-state engine: it borrows this bus while the machine is stopped
    .ss_bus_oe     (ss_bus_oe),
    .ss_ab         (ss_ab),
    .ss_we         (ss_we),
    .ss_do         (ss_do),
    .ss_di         (ss_di),
    .cpu_addr      (ss_cpu_addr),
    .cpu_sync_q    (),
    .ss_reg_we     (ss_reg_we),
    .ss_PC         (ss_PC),
    .ss_A          (ss_A),
    .ss_X          (ss_X),
    .ss_Y          (ss_Y),
    .ss_S          (ss_S),
    .ss_P          (ss_P),
    .cpu_q         (ss_cpu_q),
    .ss_st_we      (ss_st_we),
    .ss_st_in      (ss_st_out),
    .ss_st         (ss_st_in)
);

// ---------------------------------------------------------------------------
//  Save states
//
//  The engine walks the machine's own memory through the bus above while
//  `ss_sleep` holds the CPU's clock-enable off. Nothing else in this file is
//  stateful on its behalf: the walk banks the windows with ordinary writes to
//  $2005/$2007, and the engine writes the machine's own values back at the end.
// ---------------------------------------------------------------------------
logic        ss_bus_oe, ss_we, ss_reg_we, ss_st_we;
// the cartridge's bank latch, through the engine's restore port (rtl/cart.sv)
logic  [7:0] cart_bank_q, ss_cart_bank;
logic        ss_cart_bank_we;
logic [15:0] ss_ab, ss_PC, ss_cpu_addr;
logic  [7:0] ss_do, ss_di, ss_A, ss_X, ss_Y, ss_S, ss_P;
logic [63:0] ss_cpu_q, ss_st_in, ss_st_out;
logic        ss_mc_we;
logic [63:0] ss_mc_out, ss_mc_in;
// the ACP CPU's register-file restore, sliced out of the engine's 64-bit word
logic [63:0] ss_acp_regs;
logic [15:0] ss_acp_PC;
logic  [7:0] ss_acp_A, ss_acp_X, ss_acp_Y, ss_acp_S, ss_acp_P;
assign ss_acp_PC = ss_acp_regs[15:0];
assign ss_acp_A  = ss_acp_regs[23:16];
assign ss_acp_X  = ss_acp_regs[31:24];
assign ss_acp_Y  = ss_acp_regs[39:32];
assign ss_acp_S  = ss_acp_regs[47:40];
assign ss_acp_P  = ss_acp_regs[55:48];

gt_savestates #(.WALK(SS_WALK)) gt_savestates
(
    .clk        (clk_sys),
    .reset      (reset),

    .save_tog   (ss_save_tog),
    .load_tog   (ss_load_tog),
    .abort_tog  (ss_abort_tog),

    .sleep      (ss_sleep),
    .busy       (ss_busy),
    .loading    (),
    .load_done  (ss_load_done),
    .engine_err (ss_engine_err),
    .blit_busy  (blit_busy),
    .bus_busy   (cart_stall | gram_stall),

    .bus_oe     (ss_bus_oe),
    .bus_ab     (ss_ab),
    .bus_we     (ss_we),
    .bus_do     (ss_do),
    .bus_di     (ss_di),
    .cpu_addr   (ss_cpu_addr),

    .banking_q  (bank_reg),
    .dma_ctl_q  (dma_ctl),
    .cart_bank     (cart_bank_q),
    .cart_bank_out (ss_cart_bank),
    .cart_bank_we  (ss_cart_bank_we),

    .reg_we     (ss_reg_we),
    .reg_PC     (ss_PC),
    .reg_A      (ss_A),
    .reg_X      (ss_X),
    .reg_Y      (ss_Y),
    .reg_S      (ss_S),
    .reg_P      (ss_P),
    .cpu_q      (ss_cpu_q),
    .mc_we      (ss_mc_we),
    .mc_out     (ss_st_out),
    .mc_in      (ss_st_in),

    .acp_q        (acp_ss_q),
    .acp_regs_out (ss_acp_regs),
    .acp_mc_in    (acp_ss_st_in),
    .acp_mc_out   (acp_ss_st_out),
    .acp_rate     (acp_rate_q),
    .acp_rate_out (acp_rate_w),
    .diag         (ss_diag),

    .save_data  (ss_save_data),
    .save_wr    (ss_save_wr),
    .save_full  (ss_save_full),
    .load_rd    (ss_load_rd),
    .load_data  (ss_load_data),
    .load_empty (ss_load_empty),

    // The 6522 rides in the state as three of its own words (not a bus walk):
    // its load port exists so a restore cannot start a timer or clear an IFR
    // bit the way replaying the registers through $2800 would.
    .via_state   (via_ss_out),
    .via_load    (via_ss_in),
    .via_load_we (via_ss_we)
);

// The engine restores the microcode through its own port; mainbus carries it
// to the CPU whose `ss_st_we` also has to be the engine's strobe.
assign ss_st_we = ss_mc_we;

// Gamepads
logic       pad1_rd, pad2_rd;
logic [7:0] pad_q;

pads pads
(
    .clk_sys (clk_sys),
    .reset   (reset),
    .pad1_rd (pad1_rd),
    .pad2_rd (pad2_rd),
    .joy1    (joy1),
    .joy2    (joy2),
    .pad_q   (pad_q)
);

// 6522 VIA at $2800-$2FFF. Its phi2 is the CPU cycle: `falling` = the RDY
// strobe (end of cycle, when writes commit), `rising` = mid-window. Port A
// becomes the cartridge bank SPI in M7; until then ports float high.
logic       via_wen, via_ren /*verilator public_flat_rd*/;
logic [7:0] via_q;
logic       via_irq;
// its save-state word (rtl/gt_savestates.sv drives the load)
logic [191:0] via_ss_in, via_ss_out;
logic         via_ss_we;

// WHAT THE SHADOW IS NOW (2026-11-03). It remembers the last byte written to
// each of the sixteen registers. It no longer answers CPU reads -- the chip
// does (see the mainbus instance) -- but it is still the source of the
// cartridge bank SPI, because that is the one place where the reference
// emulator's behaviour, not the chip's, is what games were written against:
// it drives PA0..PA2 regardless of DDRA, which shipped cartridges rely on.
// It is also the only record of what the chip was programmed with: the state
// format does not carry the 6522, so a load leaves the VIA exactly as this
// session had already left it -- the same staleness the shadow had, so nothing
// got worse here, but nothing got saved either (a follow-up, not this change).
//
// The cost of reading the chip instead of this array is emulator parity:
// `Ganymede` sweeps all sixteen registers at boot as an entropy source, and a
// live 6522 returns timer values, pin states and IFR bits there, so its level
// generator comes out different. That difference is the machine's, not a bug.
logic [7:0] via_shadow [0:15];
// The array itself is still live: `via_pa` (register 1) drives the cartridge
// bank SPI. `via_shadow_q`, the read-byte alias, went with the shadow reads
// (2026-11-09) -- nothing has read it since the real 6522 started answering.
always_ff @(posedge clk_sys) begin
    if (reset) begin
        for (int i = 0; i < 16; i++) via_shadow[i] <= 8'h00;
    end
    else if (via_wen)
        via_shadow[win_addr[3:0]] <= win_din;
end
logic       via_rising;

always_ff @(posedge clk_sys)
    via_rising <= (ce_div == 3'd3);

// Port pins: reads return the VIA's own drive on output bits and pull-ups
// on inputs (the M7 cart SPI adds MISO on PA7).
logic [7:0] via_pa_o, via_pa_t, via_pb_o, via_pb_t;
wire  [7:0] via_pa_i = (via_pa_o & via_pa_t) | ~via_pa_t;
wire  [7:0] via_pb_i = (via_pb_o & via_pb_t) | ~via_pb_t;

/* verilator lint_off PINCONNECTEMPTY */
via6522 via
(
    .clock     (clk_sys),
    .rising    (via_rising),
    .falling   (cpu_ce),
    .reset     (reset),

    .addr      (win_addr[3:0]),
    .wen       (via_wen),
    .ren       (via_ren),
    .data_in   (win_din),
    .data_out  (via_q),

    .phi2_ref  (),

    .port_a_o  (via_pa_o),
    .port_a_t  (via_pa_t),
    .port_a_i  (via_pa_i),
    .port_b_o  (via_pb_o),
    .port_b_t  (via_pb_t),
    .port_b_i  (via_pb_i),

    .ca1_i     (1'b1),
    .ca2_o     (),
    .ca2_i     (1'b1),
    .ca2_t     (),
    .cb1_o     (),
    .cb1_i     (1'b1),
    .cb1_t     (),
    .cb2_o     (),
    .cb2_i     (1'b1),
    .cb2_t     (),

    .irq       (via_irq),

    .ss_we   (via_ss_we),
    .ss_in   (via_ss_in),
    .ss_out  (via_ss_out)
);
/* verilator lint_on PINCONNECTEMPTY */

// Blitter and GRAM
logic [18:0] blit_gram_addr;
logic [7:0]  blit_gram_q;
logic        blit_vram_we;
logic [13:0] blit_vram_addr;
logic [7:0]  blit_vram_din;

logic [18:0] blit_gram_paddr;
logic        blit_gram_want, blit_gram_ready;

blitter blitter
(
    .clk_sys    (clk_sys),
    .reset      (reset),
    .cpu_ce     (blit_ce),

    .param_we   (blit_param_we),
    .param_addr (win_addr[2:0]),
    .param_data (win_din),

    .dma_ctl    (dma_ctl),
    .banking    (bank_reg),

    .gram_paddr (blit_gram_paddr),
    .gram_want  (blit_gram_want),
    .gram_ready (blit_gram_ready),
    .gram_addr  (blit_gram_addr),
    .gram_q     (blit_gram_q),
    .starved    (blit_starve),

    .vram_we    (blit_vram_we),
    .vram_addr  (blit_vram_addr),
    .vram_din   (blit_vram_din),

    .irq        (blit_irq),
    .gram_mid   (gram_mid),
    .busy       (blit_busy)
);

gram gram
(
    .clk_sys        (clk_sys),
    .reset          (reset),
    .cpu_ce         (blit_ce),   // a copy may outlive the CPUs (see above)

    .param_we       (blit_param_we),
    .param_addr     (win_addr[2:0]),
    .param_data     (win_din),
    .dma_ctl        (dma_ctl),
    .banking        (bank_reg),

    .blit_paddr     (blit_gram_paddr),
    .blit_want      (blit_gram_want),
    .blit_ready     (blit_gram_ready),
    .blit_addr      (blit_gram_addr),
    .blit_q         (blit_gram_q),

    // CPU window: quadrant within the 64 KB bank comes from the blitter's
    // latched counter high bits (HARDWARE.md §Blitter, gram_mid_bits)
    .cpu_addr       ({bank_reg[2:0], gram_mid, win_addr}),
    .cpu_we         (cpu_gram_we),
    .cpu_wdata      (win_din),
    .cpu_rd         (cpu_gram_rd),
    .cpu_q          (gram_b_dout),
    .cpu_stall      (gram_stall),

    .mem_rd         (g_rd),
    .mem_we         (g_we),
    .mem_addr       (g_addr),
    .mem_din        (g_din),
    .mem_be         (g_be),
    .mem_burstcnt   (g_burstcnt),
    .mem_dout       (mem_dout),
    .mem_dout_ready (g_dout_ready),
    .mem_busy       (g_busy)
);

// Cartridge controller (M7): PSRAM-backed .gtr with VIA Port A bank SPI.
// Shares the memory port with the GRAM prefetcher through mem_bus.
logic        cart_rd, cart_wr /*verilator public_flat_rd*/;
logic  [7:0] cart_wdata /*verilator public_flat_rd*/;
logic [7:0]  cart_int_data /*verilator public_flat_rd*/;
logic        g_rd, g_we, g_dout_ready, g_busy;
logic [21:0] g_addr;
logic [63:0] g_din;
logic [63:0] mem_dout;
logic [7:0]  g_be, g_burstcnt;
logic        k_rd, k_we, k_dout_ready, k_busy;
logic [21:0] k_addr;
logic [63:0] k_din;
logic [7:0]  k_be, k_burstcnt;

cart cart
(
    .clk_sys        (clk_sys),
    .reset          (reset),

    .cart_addr      (cart_addr),
    .ss_readout     (ss_readout),
    .cart_rd        (cart_rd),
    .cart_wr        (cart_wr),
    .cart_wdata     (cart_wdata),
    .cart_data      (cart_int_data),
    .cart_stall     (cart_stall),
    .cart_present   (cart_present),

    // The emulator intentionally ignores DDRA here. Using resolved VIA
    // pins leaves PA0-2 pulled high after reset and makes the standard SDK
    // bank routine silently select bank 0 forever (GitHub issue #1).
    .via_pa         (via_shadow[1]),

    // The cartridge's bank latch is part of the save state: it is the only
    // thing that says which 32 KB of the image the CPU is executing from, and
    // no register write from the game can be replayed by a load.
    .ss_bank_q      (cart_bank_q),
    .ss_bank        (ss_cart_bank),
    .ss_bank_we     (ss_cart_bank_we),

    .save_trigger   (save_trigger),
    .flash_done     (flash_done),

    .dspan_req      (dspan_req),
    .dspan_ack      (dspan_ack),
    .dspan_lo       (dspan_lo),
    .dspan_hi       (dspan_hi),
    .dspan_any      (dspan_any),

    .worm_lo        (worm_lo),
    .worm_any       (worm_any),

    // ioctl downloads and savectl's restore stream share the port (they
    // are serialized: savectl only runs while no download is active)
    .dl_active      (dl_active || sv_active),
    .dl_wr          (dl_wr || sv_wr),
    .dl_addr        (sv_active ? sv_addr : dl_addr),
    .dl_data        (sv_active ? sv_data : dl_data),
    .dl_img_size    (dl_img_size),
    .ram32k_decl    (ram32k_decl),
    .dl_busy        (dl_busy),
    .dl_wait        (dl_wait),
    .cart_size      (cart_size),

    .nvram_q        (nvram_q),
    .nvram_addr     (nvram_addr),
    .nvram_wr       (nvram_wr),
    .nvram_wdata    (nvram_wdata),

    .mem_rd         (k_rd),
    .mem_we         (k_we),
    .mem_addr       (k_addr),
    .mem_din        (k_din),
    .mem_be         (k_be),
    .mem_burstcnt   (k_burstcnt),
    .mem_dout       (mem_dout),
    .mem_dout_ready (k_dout_ready),
    .mem_busy       (k_busy)
);

// Flash-save persistence (M9.1): $90-triggered save of the PSRAM cart
// image to the framework's .sav slot; restore replays the mounted file
// through the cart download port.
logic        save_trigger;
logic        flash_done;
assign save_trig = save_trigger | flash_done;

logic        sv_active /*verilator public_flat_rd*/, sv_wr;
logic [20:0] sv_addr;
logic [7:0]  sv_data;
logic        s_rd;
logic [21:0] s_addr;
logic [7:0]  s_burstcnt;
logic        s_dout_ready, s_busy;

savectl savectl
(
    .clk_sys        (clk_sys),

    .sd_lba         (sd_lba),
    .sd_rd          (sd_rd),
    .sd_wr          (sd_wr),
    .sd_ack         (sd_ack),
    .sd_buff_addr   (sd_buff_addr),
    .sd_buff_dout   (sd_buff_dout),
    .sd_buff_din    (sd_buff_din),
    .sd_buff_wr     (sd_buff_wr),
    .img_mounted    (img_mounted),
    .img_readonly   (img_readonly),
    .img_size       (img_size),

    .bk_load        (bk_load),
    .bk_save        (bk_save),
    .autosave       (autosave),
    .osd_open       (osd_open),
    .save_trigger   (save_trigger),
    .cart_dl_active (dl_active),
    .cart_busy      (dl_wait),
    .cart_present   (cart_present),

    .sv_active      (sv_active),
    .sv_wr          (sv_wr),
    .sv_addr        (sv_addr),
    .sv_data        (sv_data),
    .sv_busy        (dl_busy),

    .c2_rd          (s_rd),
    .c2_addr        (s_addr),
    .c2_burstcnt    (s_burstcnt),
    .mem_dout       (mem_dout),
    .c2_dout_ready  (s_dout_ready),
    .c2_busy        (s_busy)
);

mem_bus mem_bus
(
    .clk_sys        (clk_sys),

    .c0_rd          (g_rd),
    .c0_we          (g_we),
    .c0_addr        (g_addr),
    .c0_din         (g_din),
    .c0_be          (g_be),
    .c0_burstcnt    (g_burstcnt),
    .c0_dout_ready  (g_dout_ready),
    .c0_busy        (g_busy),

    .c1_rd          (k_rd),
    .c1_we          (k_we),
    .c1_addr        (k_addr),
    .c1_din         (k_din),
    .c1_be          (k_be),
    .c1_burstcnt    (k_burstcnt),
    .c1_dout_ready  (k_dout_ready),
    .c1_busy        (k_busy),

    .c2_rd          (s_rd),
    .c2_addr        (s_addr),
    .c2_burstcnt    (s_burstcnt),
    .c2_dout_ready  (s_dout_ready),
    .c2_busy        (s_busy),

    .c3_rd          (ps_rd),
    .c3_addr        (ps_addr),
    .c3_burstcnt    (ps_burstcnt),
    .c3_dout_ready  (ps_dout_ready),
    .c3_busy        (ps_busy),

    .dout           (mem_dout),

    .cram_a         (cram_a),
    .cram_dq_out    (cram_dq_out),
    .cram_dq_oe     (cram_dq_oe),
    .cram_dq_in     (cram_dq_in),
    .cram_wait      (cram_wait),
    .cram_clk       (cram_clk),
    .cram_adv_n     (cram_adv_n),
    .cram_cre       (cram_cre),
    .cram_ce0_n     (cram_ce0_n),
    .cram_ce1_n     (cram_ce1_n),
    .cram_oe_n      (cram_oe_n),
    .cram_we_n      (cram_we_n),
    .cram_ub_n      (cram_ub_n),
    .cram_lb_n      (cram_lb_n)
);

// The save slot's read-side data is the memory bus's beat output, qualified by
// c3_dout_ready (both change together, so a direct connection is the whole of
// it -- the client samples on the ready strobe).
assign ps_dout = mem_dout;

// VRAM port A: blitter writes win over the CPU window — they are never
// simultaneously active (blitter writes require COPY_ENABLE=1, CPU window
// access requires COPY_ENABLE=0), and the blitter's 1-clk pulse disturbs
// CPU reads for one clock mid-window only.
vram vram
(
    .clk    (clk_sys),

    .a_page (bank_reg[3]),
    .a_addr (blit_vram_we ? blit_vram_addr : win_addr),
    .a_we   (blit_vram_we | cpu_vram_we),
    .a_din  (blit_vram_we ? blit_vram_din : win_din),
    .a_dout (vram_a_dout),

    .b_page (vid_page),     // page being copied into the display snapshot
    .b_addr (vram_b_addr),
    .b_dout (vram_b_dout)
);

// The emulator presents one immutable framebuffer image per host frame.
// Snapshot the requested hardware page during vblank so a game can flip and
// immediately recycle the released page without scanout following its writes.
logic vid_page /*verilator public_flat_rd*/;
frame_snapshot frame_snapshot
(
    .clk            (clk_sys),
    .reset          (reset),
    .vblank         (vblank),
    .requested_page (dma_ctl[1]),

    .source_page    (vid_page),
    .source_addr    (vram_b_addr),
    .source_data    (vram_b_dout),

    .scan_addr      (scanout_addr),
    .scan_data      (scanout_data),
    .busy           (snap_busy)
);

logic vsync_nmi /*verilator public_flat_rd*/;
logic        ce_pix, hblank, hsync, vblank, vsync;
logic [7:0]  vid_r, vid_g, vid_b;
// The picture tap to gt_video. `public_flat_rd` so the harnesses can count
// what the console actually handed the Pocket stage -- one strobe per visible
// pixel -- instead of inferring it from the finished picture.
logic [6:0]  pic_x /*verilator public_flat_rd*/;
logic [6:0]  pic_y /*verilator public_flat_rd*/;
logic [7:0]  pic_index /*verilator public_flat_rd*/;
logic        pic_we /*verilator public_flat_rd*/;

gtvideo gtvideo
(
    .clk       (clk_sys),
    .reset     (reset),

    .fb_addr   (gt_scan_addr),
    .fb_data   (scanout_data),

    .ce_pix    (ce_pix),
    .hblank    (hblank),
    .hsync     (hsync),
    .vblank    (vblank),
    .vsync     (vsync),
    .r         (vid_r),
    .g         (vid_g),
    .b         (vid_b),

    .vsync_nmi (vsync_nmi),

    .pic_x     (pic_x),
    .pic_y     (pic_y),
    .pic_index (pic_index),
    .pic_we    (pic_we)
);

//============================================================================
//  THE FIVE ROWS THE CONSOLE NEVER SCANS  (2026-10-29)
//
//  Every framebuffer row is scanned on two raster lines, and the frame is 262
//  lines with 16 of vertical blank: 16 + 2 x 123 = 262, so rows 123..127 are
//  never fetched and the picture tap stops at row 122. That is what the real
//  console did (docs/gametank-hardware.md), but the Pocket stage hands the
//  scaler a 128-line window, and the bottom five lines stayed at the RAM's
//  power-up value -- a dark band under a picture whose own background is any
//  other palette entry.
//
//  So those rows are read out of the displayed page's snapshot during vertical
//  blank, when the console is not fetching and the snapshot's read port is
//  idle, and written into BOTH pages of gt_video's frame store (one port, one
//  address per clock, so two writes per pixel). The scanned page then has the
//  whole framebuffer for the frame about to be drawn; the other page gets the
//  same rows a frame early, which nothing ever reads.
//
//  The read is 640 bytes (5 x 128) at three clocks each -- under 2k clocks of
//  the 29k in vertical blank -- and it yields to the picture tap's write, which
//  has the only other claim on that port.
//============================================================================
logic        tail_go   = 1'b0;
logic [1:0]  tail_ph   = 2'd0;
logic [2:0]  tail_y    = 3'd0;
logic [6:0]  tail_x    = 7'd0;
logic [7:0]  tail_data = 8'd0;
logic        vblank_d  = 1'b0;

wire [6:0]  tail_row = 7'd123 + {4'd0, tail_y};
// The fill owns the snapshot's read port only while the snapshot is not copying
// into it. `frame_snapshot` writes that memory during vertical blank, and a read
// and a write to one address in the same clock is undefined -- and the fill runs
// in the same vblank. The phase machine below already holds while `snap_busy`,
// so this only makes the address agree with it: a copy that starts part-way
// through a row cannot collide with the pixel the fill is fetching. That
// collision was one wrong pixel at (0,127) on AERIAL's first picture, and 535
// pixels on Accursed Fiend's frame 308 (2026-10-29).
wire        tail_sel = tail_go && !snap_busy;
wire [14:0] tail_wr  = {(tail_ph == 2'd2), tail_row, tail_x};
wire [7:0]  tail_q   = (tail_ph == 2'd1) ? scanout_data : tail_data;

// A LEVEL, not a strobe: gt_video takes a clock for the tail only when its
// picture tap is not writing, and this fill advances on exactly the same test
// (below), so the two agree cycle for cycle about who owns the write port.
wire        tail_we = tail_go && (tail_ph != 2'd0);

assign scanout_addr = tail_sel ? {tail_row, tail_x} : gt_scan_addr;

always_ff @(posedge clk_sys) begin
    vblank_d <= vblank;

    if (reset) begin
        tail_go <= 1'b0;
        tail_ph <= 2'd0;
        tail_x  <= 7'd0;
        tail_y  <= 3'd0;
    end
    else if (vblank && !vblank_d) begin
        tail_go <= 1'b1;
        tail_ph <= 2'd0;
        tail_x  <= 7'd0;
        tail_y  <= 3'd0;
    end
    else if (!vblank) begin
        // Never into the active region: the fill owns the snapshot's read port
        // while it runs, and gtvideo's first fetch is at PX_BASE of line 16.
        // It needs ~2.1k of vblank's 29k clocks, so this is a guard, not a
        // schedule.
        tail_go <= 1'b0;
    end
    else if (tail_go && !snap_busy && !pic_we) begin
        // `!pic_we` here and gt_video's `else if (tail_we)` are the same test in
        // the same clock: these phase changes are exactly the clocks on which
        // the write port is free.
        case (tail_ph)
            2'd0: tail_ph <= 2'd1;            // address is on the port this clock
            2'd1: begin                       // snapshot data valid; page 0
                tail_data <= scanout_data;
                tail_ph   <= 2'd2;
            end
            default: begin                    // page 1, then the next pixel
                tail_ph <= 2'd0;
                if (tail_x == 7'd127) begin
                    tail_x <= 7'd0;
                    if (tail_y == 3'd4) tail_go <= 1'b0;
                    else                tail_y <= tail_y + 3'd1;
                end
                else tail_x <= tail_x + 7'd1;
            end
        endcase
    end
end

// The video domain comes in as a clock and a pixel enable: on the Pocket,
// clk_pix is the video PLL's 2.25 MHz output and pix_ce is constant 1; in
// simulation both come from the harness (clk_pix = clk_sys, pix_ce a divider).
//
// gt_video's outputs are three pixel enables behind the address it presents
// (BRAM read, palette ROM, output register), so the APF port's video_ce has
// to be delayed by those same three to mark the pixel the pins are carrying.
logic pix_ce_q1 = 1'b0, pix_ce_q2 = 1'b0, pix_ce_q3 = 1'b0;

always_ff @(posedge clk_pix) begin
    pix_ce_q1 <= pix_ce;
    pix_ce_q2 <= pix_ce_q1;
    pix_ce_q3 <= pix_ce_q2;
end

assign video_ce = pix_ce_q3;

/* THE PICTURE IS NEVER HELD IN RESET (2026-10-28).
 *
 * This used to be `reset`, the machine's own -- so every machine reset also
 * stopped the raster: `h`, `v` and the output pipeline were held at zero, which
 * is not a black picture but NO VIDEO AT ALL (no DE, no HS, no VS for as long as
 * the reset lasts). On a Pocket that is the one thing the scaler cannot be
 * given: it loses the link and terminates the core. The machine reset is
 * asserted for the whole of a download and for a save restore -- up to ~0.6 s
 * for a 2 MB image -- and any machine reset during a save state does the same.
 *
 * Nothing about the picture needs the machine to be running: the frame store is
 * written by the console's side of the dual-clock RAM and read by the raster,
 * so with the raster free-running the scaler keeps a locked, frozen picture for
 * however long the console is held, and picks up the next complete frame. That
 * is the same rule the PLL retry above follows: a frozen picture is
 * recoverable, a missing one is not. */
gt_video video
(
    .clk_sys    (clk_sys),
    .clk_pix    (clk_pix),
    .ce         (pix_ce),
    .reset      (1'b0),

    .pic_we     (pic_we),
    .pic_x      (pic_x),
    .pic_y      (pic_y),
    .pic_index  (pic_index),
    .frame_sync (vsync_nmi),
    .tv_mask    (tv_mask),

    .tail_we    (tail_we),
    .tail_addr  (tail_wr),
    .tail_index (tail_q),

    .video_rgb  (video_rgb),
    .video_de   (video_de),
    .video_hs   (video_hs),
    .video_vs   (video_vs),
    .frame_end  ()
);

endmodule
