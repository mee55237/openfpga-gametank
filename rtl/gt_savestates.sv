/*============================================================================
 *  gt_savestates -- the GameTank's save-state engine.
 *
 *  WHAT A STATE IS. The console is a 65C02 with everything it can reach in
 *  BRAM: 32 KB of system RAM behind the $0000 window (four 8 KB banks chosen
 *  by banking[7:6]), two 16 KB framebuffer pages behind the $4000 window
 *  (chosen by banking[3]), 4 KB of audio RAM at $3000, and a handful of
 *  registers. A state carries the CPU's register file and microcode, the two
 *  window registers, 32 KB of system RAM and 4 KB of audio RAM.
 *
 *      word 0     { TAG, 32'd1 }             TAG (bytes behind the header =
 *                                             savestate_size - 8) and version
 *      word 1     the CPU: {8'h0, P, S, Y, X, A, PC}
 *      word 2     {32'h0, cart_valid, 7'h0, cart_bank, dma_ctl, banking}
 *                 -- the window registers and, when `cart_valid` is set, the
 *                 cartridge's 74HC595 bank latch (rtl/cart.sv). A file written
 *                 before the latch was carried has the flag clear and leaves
 *                 the latch alone, so an older Memory still loads.
 *      word 3     its microcode: {39'h0, NMI_edge, AZ2, DIHOLD,
 *                                 IRHOLD, IRHOLD_valid, state}
 *      word 4     the ACP's CPU, same two shapes
 *      word 5     the ACP's microcode
 *      word 6     {56'h0, acp rate}
 *      words 7..4102       system RAM, bank 0 first, $0000-$1FFF each
 *      words 4103..4614    audio RAM, $3000-$3FFF
 *      words 4615..8710    framebuffer, page 0 first, $4000-$7FFF each
 *      words 8711..8713   the 6522 VIA: its register file, both timers, the
 *                         shift register and the timer's own flags
 *
 *  8,714 words = 69,712 bytes. The framebuffer IS in it: the CPU can read
 *  VRAM back through the $4000 window, and a load that left it out resumed
 *  with the previous screen wherever the game did not repaint (see WORDS).
 *  The VIA is in it for the same reason one step further: it is the machine's
 *  clock. A game that keeps time on timer A has an interval running when the
 *  state is taken, and a load that left the chip where the session had it
 *  would either lose that interrupt or restart a different interval -- with
 *  no way for the game to notice except that its timing is wrong.
 *
 *  Every word is little-endian in the file, byte 0 in bits 7:0, which is what
 *  the APF bridge's `bridge_endian_little` means for the cartridge too -- a
 *  state written here is the machine's own address order, not a MiSTer file.
 *
 *  WHY THE MICROCODE IS IN IT. Minicube64 takes its states at an instruction
 *  boundary and needs a machine reset on a load to get the 65C02 back to one.
 *  GameTank cannot reset on a load -- reset here is the BRK/vector sequence,
 *  which would boot the cartridge over the state just written. Saving the
 *  cycle counter and the two prefetched bytes instead makes a state exact
 *  wherever it was taken: the freeze is immediate, and a load resumes in the
 *  middle of the same instruction it was stopped in.
 *
 *  WHY GRAM IS NOT IN IT. The blitter's 512 KB of source bitmaps live in
 *  PSRAM. Including it would make a state ~580 KB, and a save has to hand the
 *  host a 64-bit word every ~68 clk_sys (two 32-bit bridge reads at its own
 *  88 clk_74a ceiling). GRAM reads through rtl/mem_bus.sv cost ~92 clk_sys a
 *  word, so a GRAM walk cannot keep ahead of the host, and the M10K needed to
 *  buffer the shortfall (~21,000 words) is two thirds of the whole RAM budget.
 *  What a state carries for the picture is VRAM, which is what is scanned out;
 *  GRAM is source art a cart uploads at boot, so a state loaded into a running
 *  session (the normal case) has the right art already. Adding it is the
 *  74.25 MHz PSRAM port in docs/gametank-port.md, not a change here.
 *
 *  HOW IT GETS AT THE MEMORY. Not with a port of its own: the machine is
 *  stopped, so its bus is idle, and the engine drives it (rtl/mainbus.sv's
 *  `ss_bus_*` port group muxes the engine's address/data/write strobes into
 *  the same decoders the CPU uses, at one byte per clock instead of the CPU's
 *  1-in-8). Banking the windows is then just writing $2005/$2007, exactly as
 *  software would, which is why this module has no idea what a bank is -- it
 *  writes the register it needs whenever the walk crosses a boundary, and
 *  writes the machine's own values back at the end.
 *
 *  Reads take three clocks a byte: present the address (the decoders latch it
 *  and the RAM's output register loads), let it settle, then sample. 8714
 *  words is ~209 K clocks -- 7.3 ms -- against a host that needs ~20 ms to
 *  read the same blob, so the host is the limit and the machine is frozen for
 *  that one transfer. The engine waits on `save_full` rather than needing a
 *  shadow of the state behind it (see the APF end's note).
 *============================================================================*/

`default_nettype none

module gt_savestates #(
    parameter logic [31:0] VERSION   = 32'd1,
    parameter int          SRAM_SIZE = 32768,
    parameter int          VRAM_SIZE = 32768,
    parameter int          ARAM_SIZE = 4096,

    /* WALK = 0 IS A BISECT, NOT A MODE (2026-10-25).
     *
     * The panel's saves complete and then the Pocket reloads the core: the OS
     * reads all 8,711 words (a whole .sta is its 596-byte Pocket header plus
     * the 69,688-byte blob, tag 69,680, `saves 1`, `drops 0`, `resets 0`), so
     * everything the APF side is asked to do, it does. What is
     * left is either the transfer itself or the walk behind it, and one build
     * with this at 0 separates them: the engine produces the same number of
     * words over the same window in the same time, but touches no bus at all and
     * never holds the CPU.
     *
     *   survives with WALK = 0  ->  the walk is the fault (its $2005 writes)
     *   dies with WALK = 0      ->  the transfer is the fault (size/rate/APF)
     *
     * The harnesses instantiate this module without it, so they still walk. */
    parameter bit          WALK      = 1'b1
) (
    input  logic        clk,          // clk_sys, the console clock
    input  logic        reset,        // machine reset: aborts a state in flight

    // ---- requests, from the APF end (crossed into clk_sys there) ----------
    input  logic        save_tog,
    input  logic        load_tog,
    input  logic        abort_tog,

    // ---- the stop -------------------------------------------------------
    output logic        sleep,        // hold the CPU (RDY low) while this is up
    output logic        busy,
    output logic        loading,
    output logic        load_done,    // one pulse: a state was restored
    output logic        engine_err,   // bad header, or a transfer the host gave up
    input  logic        blit_busy,    // a copy is in flight (rtl/blitter.sv)
    // A bus read is still waiting on memory (the cartridge cache or the GRAM
    // row buffer). While either is up the machine is not quiet, and the walk's
    // first bank-register write would land in the middle of somebody's fetch.
    input  logic        bus_busy,

    // ---- the CPU bus, borrowed (rtl/mainbus.sv) -------------------------
    output logic        bus_oe,
    output logic [15:0] bus_ab,
    output logic        bus_we,
    output logic  [7:0] bus_do,
    input  logic  [7:0] bus_di,

    // The address the stopped CPU is holding. RDY low freezes the core with
    // its address register still pointing at the cycle it was in the middle of,
    // and that cycle's read data is the byte it samples the moment it is let
    // go -- so the last thing this engine does is present it again (see BUSR).
    input  logic [15:0] cpu_addr,

    // ---- the machine's own window registers -----------------------------
    input  logic  [7:0] banking_q,
    input  logic  [7:0] dma_ctl_q,

    /* ---- the cartridge's bank latch (rtl/cart.sv's 74HC595) --------------
     *
     * THE ONE PIECE OF MACHINE STATE THE CPU CANNOT PUT BACK ITSELF (2026-10-28).
     *
     * A state that has always loaded "fine" can still be wrong here, because the
     * cart is not memory: `rtl/cart.sv` serves $8000-$BFFF from whichever bank
     * the 74HC595 is holding, and only a bit-banged write through VIA Port A can
     * change it. A save leaves the latch where it is, so a load that lands after
     * the game switched banks resumes its saved PC against the WRONG 32 KB of
     * cartridge -- wrong code, immediately, and only on a cart that banks (this
     * is the tetris shape).
     *
     * It rides in the 32 spare bits of the state's word 2, with a valid flag, so
     * the latch alone left the blob the same size and tag: a file written before
     * this existed has the flag clear and leaves the latch alone, exactly as it
     * used to. Nothing else about the format moves. */
    input  logic  [7:0] cart_bank,
    output logic  [7:0] cart_bank_out,
    output logic        cart_bank_we,

    // ---- the CPU's register file and microcode --------------------------
    output logic        reg_we,
    output logic [15:0] reg_PC,
    output logic  [7:0] reg_A,
    output logic  [7:0] reg_X,
    output logic  [7:0] reg_Y,
    output logic  [7:0] reg_S,
    output logic  [7:0] reg_P,
    input  logic [63:0] cpu_q,        // {8'h0, P, S, Y, X, A, PC}
    output logic        mc_we,
    output logic [63:0] mc_out,
    input  logic [63:0] mc_in,

    // ---- the ACP's CPU and rate register (the second 65C02) --------------
    input  logic [63:0] acp_q,
    output logic [63:0] acp_regs_out,
    input  logic [63:0] acp_mc_in,
    output logic [63:0] acp_mc_out,
    input  logic  [7:0] acp_rate,
    output logic  [7:0] acp_rate_out,

    /* ---- the black box --------------------------------------------------
     *
     * FIVE COUNTERS OF WHAT THE APF'S SIDE WENT THROUGH, carried in the 56 spare
     * bits of the state's last special word (word 6, see the `default:` case
     * below). They are
     * not part of the state -- the load path takes only the low byte of that
     * word for the ACP's rate, exactly as before -- and they cost one 64-bit
     * lane, no memory, no format change: a file written by this build loads in
     * the previous one and vice versa.
     *
     * WHY THEY ARE IN THE STATE AT ALL. A save state is the only channel this
     * core has to tell the owner anything after a crash: the OS writes the .sta
     * to the card itself, and the crash comes after it. So the file the crash
     * left behind also carries: how many times the PLL's lock detector dropped
     * after it first locked, how many times the APF side's reset came back, how
     * many save and load commands the bridge saw, and the status bits the core
     * was answering when the next command arrived. On the panel that turns
     * "saving crashes the Pocket" into a number to read off the file, instead of
     * a hypothesis. 0 everywhere means none of it happened and the next
     * suspect is what the OS does after the transfer. */
    input  logic [55:0] diag,

    // ---- the two streams ------------------------------------------------
    output logic [63:0] save_data,
    output logic        save_wr,
    input  logic        save_full,
    output logic        load_rd,
    input  logic [63:0] load_data,
    input  logic        load_empty,

    // ---- the 6522, straight from the chip (rtl/via6522.v) --------------
    // Not walked over the CPU bus: a write to $2805 starts timer A and one to
    // $280D clears IFR bits, so restoring through the bus would restart the
    // timers and drop pending interrupts. The chip has a load port for it.
    input  logic [191:0] via_state,
    output logic [191:0] via_load,
    output logic         via_load_we
);

    localparam int SRAM_WORDS = SRAM_SIZE / 8;
    localparam int VRAM_WORDS = VRAM_SIZE / 8;
    localparam int ARAM_WORDS = ARAM_SIZE / 8;
    // Three words carry the whole 6522: sixteen register bytes, both timer
    // latches and counters, the shift register and the timer's reload/toggle
    // flags. It sits AFTER the framebuffer so every offset that already existed
    // keeps its number; only the tag moves, which is what refuses an old file.
    localparam int VIA_WORDS  = 3;
    // 7 header/register words, then three memory regions: system RAM, audio
    // RAM, and the 32 KB framebuffer. THE FRAMEBUFFER IS MACHINE STATE: the CPU
    // can read VRAM back through the $4000 window, so a load that leaves it out
    // resumes with the previous screen wherever the game does not repaint
    // (hardware 2026-10-31: `tanks` came back with the title screen's dithered
    // field over the restored tan playfield). It is 4,096 more words -- 8,711
    // in all, with a load staging buffer of 8,967 words, the M10K the removal
    // bought back in October. The one price is that a load cut short can leave
    // half the picture from one state and half from another; the transfer
    // watchdog and the staged load already answer for that.
    localparam int WORDS      = 7 + SRAM_WORDS + ARAM_WORDS + VRAM_WORDS + VIA_WORDS;
    localparam int VIA_BASE   = WORDS - VIA_WORDS;

    /* THE STATE'S FORMAT TAG, COMPUTED AND NOT TYPED (2026-10-25).
     *
     * It is the number of BYTES BEHIND THE HEADER WORD -- `savestate_size` - 8 --
     * and the APF end uses the same number (core_top's SS_TAG) to tell which of
     * the host's two 32-bit halves is the upper one, so a mismatch is not a
     * cosmetic difference: the controller then decides the file's half order
     * wrongly and every 64-bit word the host reads is swapped. The old format
     * was a literal 36,912 while the controller had already been told a
     * different number, so a file's header disagreed with its own length and a
     * load of it was refused by this same check.
     *
     * Deriving it from WORDS makes that impossible: the tag is the state's own
     * size by construction. Adding the framebuffer moves it to 69,680, which
     * is why a pre-2026-10-31 .sta is refused rather than half-applied. */
    localparam logic [31:0] TAG = (WORDS - 1) * 8;

    typedef enum logic [3:0] {
        IDLE, LWAIT, FREEZE, WSTART, CFG, BRD, BWAIT, BREAD, BREAD2, ADVW, EMIT,
        REST, RESR, BUSR, BUSS, DONE
    } st_t;

    st_t         st      = IDLE;
    logic        is_load = 1'b0;
    // "this transfer was cut short": the machine's own window registers are put
    // back instead of the state's, and an interrupted load never installs the
    // CPU's register file (its memory is a mix of two states by then).
    logic        aborted = 1'b0;
    logic [31:0] wid     = 32'd0;
    logic  [2:0] lane    = 3'd0;

    logic [63:0] word    = 64'h0;     // save: being assembled; load: in hand
    logic [63:0] cpu_q_l = 64'h0;
    logic [63:0] mc_l    = 64'h0;
    logic [63:0] cpu_q_w = 64'h0;
    logic [63:0] mc_w    = 64'h0;
    logic [63:0] acp_q_l = 64'h0;
    logic [63:0] acp_mc_l = 64'h0;
    logic  [7:0] acp_rate_l = 8'h00;
    logic [63:0] acp_q_w = 64'h0;
    logic [63:0] acp_mc_w = 64'h0;
    logic  [7:0] acp_rate_w = 8'h00;
    logic [191:0] via_l = 192'h0;     // the chip's state, captured at the stop
    logic [191:0] via_w = 192'h0;     // ... and the one a load brings back
    logic  [7:0] bank_w  = 8'h00;     // the state's copy of the window regs
    logic  [7:0] dma_w   = 8'h00;
    logic  [7:0] cart_w  = 8'h00;     // ... and of the cartridge's bank latch
    logic        cart_v  = 1'b0;      // ... whether this file actually carries it
    logic  [7:0] bank_m  = 8'h00;     // the machine's own, captured at the stop
    logic  [7:0] dma_m   = 8'h00;
    logic  [7:0] cfg_bank = 8'h00;    // what the machine has been told so far
    logic  [7:0] cfg_dma  = 8'h00;

    // ---- the walk's address ---------------------------------------------
    logic [31:0] off32;
    logic [31:0] base;
    logic  [1:0] region;
    logic [15:0] byte_addr;
    logic  [7:0] want_bank;
    logic  [7:0] want_dma;
    logic        word_is_reg;

    always_comb begin
        region = 2'd0;
        base   = 32'd7;
        if (wid >= 7) begin
            if (wid < 7 + SRAM_WORDS) begin
                region = 2'd1;
                base   = 32'd7;
            end
            else if (wid < 7 + SRAM_WORDS + ARAM_WORDS) begin
                // audio RAM, straight after system RAM
                region = 2'd3;
                base   = 32'd7 + SRAM_WORDS;
            end
            else begin
                // framebuffer, after audio RAM: two 16 KB pages, page 0 first
                region = 2'd2;
                base   = 32'd7 + SRAM_WORDS + ARAM_WORDS;
            end
        end
        off32 = (wid - base) * 32'd8 + {29'd0, lane};
    end

    always_comb begin
        word_is_reg = (region == 2'd0);
        byte_addr   = 16'h0000;
        want_bank   = bank_w;
        want_dma    = dma_w;
        case (region)
            2'd1: begin                       // system RAM, $0000-$1FFF
                byte_addr = {3'b000, off32[12:0]};
                want_bank = {off32[14:13], bank_w[5:0]};
            end
            2'd2: begin                       // framebuffer, $4000-$7FFF
                byte_addr = {2'b01, off32[13:0]};
                want_bank = {bank_w[7:4], off32[14], bank_w[2:0]};
                // COPY_ENABLE=0 so the window is memory, CPU_TO_VRAM=1
                want_dma  = (dma_w & 8'b1101_1110) | 8'b0010_0000;
            end
            2'd3: begin                       // audio RAM, $3000-$3FFF
                byte_addr = {2'b00, 2'b11, off32[11:0]};
            end
            default: ;
        endcase
    end

    // ---- the bus driver -------------------------------------------------
    logic        drive      = 1'b0;
    logic        drive_we   = 1'b0;
    logic [15:0] drive_addr = 16'h0000;
    logic  [7:0] drive_do   = 8'h00;

    assign bus_oe = drive;
    assign bus_ab = drive_addr;
    assign bus_we = drive_we;
    assign bus_do = drive_do;

    // ---- the streams ----------------------------------------------------
    // Both strobes are combinational in the state that owns the word, so the
    // data they carry (`word`) is stable on the edge that consumes it.
    assign save_data = word;
    assign save_wr   = (st == EMIT) && !save_full;
    assign load_rd   = (st == WSTART) && is_load && !load_empty;

    // The window registers this transfer has to leave behind: the machine's
    // own on a save (the walk moved them), the state's on a load.
    logic [7:0] tgt_dma, tgt_bank;
    // THE MACHINE'S OWN ON EVERY SAVE, AND ON ANYTHING THAT WAS CUT SHORT. A
    // load that completes is the only case that leaves the STATE's windows
    // selected -- that is what the memory it just wrote belongs to. An aborted
    // load keeps the CPU where it was, so it must keep the windows it was using.
    assign tgt_dma  = (is_load && !aborted) ? dma_w  : dma_m;
    assign tgt_bank = (is_load && !aborted) ? bank_w : bank_m;

    // One cycle of register restore, with the CPU stopped.
    logic restore_r = 1'b0;
    assign reg_we = restore_r;
    assign mc_we  = restore_r;
    assign reg_PC = cpu_q_w[15:0];
    assign reg_A  = cpu_q_w[23:16];
    assign reg_X  = cpu_q_w[31:24];
    assign reg_Y  = cpu_q_w[39:32];
    assign reg_S  = cpu_q_w[47:40];
    assign reg_P  = cpu_q_w[55:48];
    assign mc_out = mc_w;
    assign acp_mc_out   = acp_mc_w;
    assign acp_rate_out = acp_rate_w;
    assign acp_regs_out = acp_q_w;

    // The cartridge's latch is restored alongside the CPU's register file, on
    // the same stopped cycle -- and only when the file says it carries one.
    assign cart_bank_we  = restore_r && cart_v;
    assign cart_bank_out = cart_w;

    // ---- status ---------------------------------------------------------
    logic busy_q = 1'b0, loading_q = 1'b0, done_q = 1'b0, err_q = 1'b0;
    assign busy       = busy_q;
    assign loading    = loading_q;
    // ... and a save that does not touch the machine must not hold its CPUs
    // either: the hold is the walk's, and with WALK = 0 there is no walk.
    assign sleep      = busy_q && (WALK || loading_q);
    assign load_done  = done_q;
    assign engine_err = err_q;

    // ---- the special words (0..6) ---------------------------------------
    //
    // An if/else chain and not a `case`: `wid` is 32 bits wide, and Quartus
    // answers a case on that with "can't check case statement for completeness
    // because the case expression has too many possible states" (Warning 10762)
    // on every fit. Same logic, no warning, and the word numbers read as what
    // they are -- an address into the header.
    logic [63:0] special_word;
    always_comb begin
        if      (wid == 32'd0) special_word = {TAG, VERSION};
        else if (wid == 32'd1) special_word = cpu_q_l;
        // word 2: the two window registers, plus (bits 23:16, flag 31) the
        // cartridge's bank latch -- see the port note. A file written by a
        // build without the latch has bit 31 clear and the load leaves it alone.
        else if (wid == 32'd2)
            special_word = {32'h0, 1'b1, 7'h0, cart_bank, dma_m, bank_m};
        else if (wid == 32'd3) special_word = mc_l;
        else if (wid == 32'd4) special_word = acp_q_l;
        else if (wid == 32'd5) special_word = acp_mc_l;
        // The low byte is the ACP's rate (the only part a load restores). The
        // rest is the black box: {pll drops, APF resets, save commands, load
        // commands, the status the last command was answered with}.
        else                   special_word = {diag, acp_rate_l};
    end

    // ---- request crossings ----------------------------------------------
    logic [2:0] save_s = 3'd0, load_s = 3'd0, abort_s = 3'd0;
    wire        save_ev  = save_s[1]  ^ save_s[2];
    wire        load_ev  = load_s[1]  ^ load_s[2];
    wire        abort_ev = abort_s[1] ^ abort_s[2];

    /* THE THREE SHIFTERS ARE RESET HERE AND NOWHERE ELSE. They are part of the
     * handshake, so a power-up value of anything but 0 (or an X in simulation)
     * is an EDGE -- and an edge is a save command nobody sent, so the engine
     * walks the machine at boot and holds it for the whole transfer. Clearing
     * them from the FSM's own block as well is a second driver: Quartus
     * Error 10028, "can't resolve multiple constant drivers for net
     * save_s[0]", which is exactly what it said. */
    always_ff @(posedge clk) begin
        if (reset) begin
            save_s  <= 3'd0;
            load_s  <= 3'd0;
            abort_s <= 3'd0;
        end
        else begin
            save_s  <= {save_s[1:0],  save_tog};
            load_s  <= {load_s[1:0],  load_tog};
            abort_s <= {abort_s[1:0], abort_tog};
        end
    end

    logic [19:0] freeze_cnt = 20'd0;
    logic  [2:0] busr_cnt   = 3'd0;

    /* THE TRANSFER'S OWN CLOCK (2026-10-24).
     *
     * `sleep` is this engine's `busy`, and it holds BOTH CPUs' clock enables
     * off for as long as it is up (rtl/gametank.sv), so an engine that stops
     * for any reason the FSM does not model leaves the console frozen with the
     * screen still scanning -- from the outside a crash, with the panel's own
     * menu still working and only a cartridge reload to get out of it.
     *
     * The APF end has a watchdog of its own, but it is a watchdog on the
     * COMMAND (did the first word arrive, did the stream stall) and it answers
     * the host, not this engine: before the abort path above was connected it
     * could not release the machine at all, and even now it only fires while a
     * command is in flight. This one is unconditional: a transfer that has not
     * reached DONE in 2^22 clocks (146 ms at 28.6 MHz, against ~10 ms for a
     * whole state in either direction) walks to REST -- which puts the
     * machine's window registers back -- and reports `engine_err`, so the
     * console comes back running from an unfinished state instead of never
     * coming back at all.
     *
     * TWO CLOCKS SHORTER THAN THE HOST'S OWN PATIENCE (2026-10-25). It was
     * 2^22 (146 ms here), which is LONGER than the APF's own watchdog on a
     * save-state command (2^23 clk_74a = 113 ms, rtl/save_state_controller.sv).
     * Whichever side notices first owns the outcome: if the OS's fires, the OS
     * has already been told its save failed while this engine is still walking
     * the machine with `sleep` up -- and the panel's own report of that is the
     * screen's brightness cycling and then a freeze, i.e. an OS crash rather
     * than a save that errored. 2^20 (36 ms at 28.6 MHz) is still twelve times
     * the whole state's copy (~3 ms measured), so no good transfer is ever cut,
     * and this engine now always answers the command before the host gives up. */
    localparam int XFER_BIT = 20;
    logic [XFER_BIT:0] xfer_wd = '0;

    /* AND THE HOLD HAS A CEILING NOTHING ELSE CAN RAISE (2026-11-02).
     *
     * `xfer_wd` above has one hole in it on purpose: a load blocked on an empty
     * stream holds it at zero, because the host may legitimately take seconds
     * to read the file off the card. What releases that case is the APF end's
     * abort -- and an abort is ONE TOGGLE crossing two clock domains. A toggle
     * that is lost, or two that land close enough together to cancel, leaves
     * this engine in WSTART with `sleep` up: the picture stays, nothing
     * responds, and only a power cycle gets out of it. From the panel that is
     * "it crashes after a while", and it is the worst outcome this file has --
     * a save or load that fails is recoverable, a console that never comes back
     * is not.
     *
     * So a transfer that has spent 2^29 clk_core (18.8 s) IN ONE STATE ends
     * here no matter what state that is, stalled or not, whether anybody asked
     * or not. It counts being STUCK, not being slow: every step the FSM takes
     * clears it, so a load arriving in chunks -- however long the file takes to
     * read -- never reaches it. Only a transfer that has not moved a single
     * state in eighteen seconds does, and the APF end's own longest wait is
     * 7.23 s (before a load's first word), so nothing that is still being fed
     * can get near it. It goes through REST like every other abort, so the
     * window registers the walk moved are put back before the CPU is handed
     * over.
     */
    localparam int HOLD_BIT = 29;
    logic [HOLD_BIT:0] hold_wd = '0;
    logic       [4:0]  st_prev = 5'd0;

    /* THE WATCHDOG COUNTS THE ENGINE'S WORK, NOT THE HOST'S READING (2026-11-02).
     *
     * It was a plain 2^20 clocks from `busy_q`, sized when the state was half
     * this size: "twelve times the whole state's copy (~3 ms measured)". With
     * the framebuffer in the state the copy is ~7 ms, and -- far worse -- the
     * clock kept running while this engine sat in WSTART waiting for a word the
     * OS had not sent yet. The OS reads the .sta off the SD card ITSELF, in
     * chunks: rtl/save_state_controller.sv allows 1.81 s of silence from it
     * (LOAD_STALL_MAX) precisely because "a pause in the middle of the stream is
     * what reading a file in chunks looks like". A pause longer than 36 ms
     * therefore timed this engine out MID-WALK.
     *
     * A transfer cut mid-walk is not a failed load: `err_q` suppresses RESR, so
     * the register file is never installed, and the machine resumes on the mix
     * of two states that the walk had written so far. What that looks like
     * depends entirely on where it was cut -- in the framebuffer half the
     * picture comes back with a strip of the old one (the bottom row and right
     * column reported 2026-11-01), in the RAM half the CPU resumes into one
     * state's variables with another's stack and dies, and the audio CPU holds
     * whatever note the dead main CPU last gave it. Load-only, because a save
     * that is cut just writes a short file.
     *
     * So the clock stops while this engine is blocked on the host -- an empty
     * load stream, or a save stream with nowhere to go. It then measures what it
     * was written to measure (the walk, 7 ms against a 36 ms limit), and a host
     * that has really gone away is the CONTROLLER's to catch: its 1.81 s stall
     * window and 7.23 s first-word window are sized for exactly that, and its
     * abort reaches the REST path above with `aborted` set. */
    /* LOADS ONLY, AND THAT IS DELIBERATE. A save that stalls on a full buffer
     * keeps its timer running: a save cut short writes a short file, which the
     * OS stores and the next load refuses by tag -- nothing is damaged -- while
     * this timer is the ONLY thing that releases the machine if the host stops
     * draining and never comes back. A load is the other way round: its abort
     * corrupts (see above), and a host that has really gone away is caught by
     * the controller's own 1.81 s stall window, which is watching the stream
     * rather than this engine's own progress. */
    wire xfer_stalled = is_load && (st == WSTART) && load_empty;

    // (2026-11-01: an experiment here waited the copy out -- `blit_busy` shares
    // the 1,024-clock cap below, which is 128 pixels of a copy -- on the theory
    // that a blit still in flight when the walk clears COPY_ENABLE is muted and
    // leaves a half-drawn rect (see LWAIT). It did not change what the panel
    // showed, so it is out again; the checkpoint commit f8e4992 has it.)

    always_ff @(posedge clk) begin
        done_q      <= 1'b0;
        restore_r   <= 1'b0;
        via_load_we <= 1'b0;   // one-clock default; RESR is the only state that raises it

        // Paused work is not a timeout -- see xfer_stalled above.
        if (busy_q && !xfer_stalled) xfer_wd <= xfer_wd + 1'b1;
        else                         xfer_wd <= '0;

        // ... but the hold itself is never unbounded: it counts clocks in the
        // SAME state, so progress clears it and a stall does not (see
        // HOLD_BIT).
        if (busy_q && (st == st_prev)) hold_wd <= hold_wd + 1'b1;
        else                           hold_wd <= '0;
        st_prev <= st;

        if (reset) begin
            st        <= IDLE;
            busy_q    <= 1'b0;
            loading_q <= 1'b0;
            drive     <= 1'b0;
            err_q     <= 1'b0;
            // (save_s/load_s/abort_s are reset in their own block -- see the
            // note there: driving them here too is Quartus Error 10028.)
        end
        /* THE WATCHDOG'S ABORT WAS ARRIVING AND DOING NOTHING (2026-10-24).
         * `abort_tog` is the APF end's "drop it" -- it fires when a command
         * timed out waiting for the machine to stop, or when a load's stream
         * stalled -- and the comment there says it stops whatever the engine
         * is doing. The synchronised edge was computed here (`abort_ev`) but
         * never read, so a timed-out transfer left the engine walking the
         * machine with `drive` asserted and the CPU held: the host was told
         * "error" while the console stayed frozen. Drop to IDLE and release
         * the bus; the machine runs again, which is the whole point. */
        /* AN ABORT USED TO DROP THE MACHINE ON A BANK IT NEVER CHOSE (2026-10-28).
         *
         * `abort_tog` is the APF end giving up on a transfer (a command that
         * timed out, a load's stream that stopped arriving), and the branch
         * below used to jump straight to IDLE with the bus released. But the
         * walk changes `$2005`/`$2007` as it goes -- that is how it reaches all
         * four 8 KB banks of system RAM -- so an abort in the middle of one left
         * the console's window registers pointing wherever the walk had got to,
         * and the CPU resumed with its stack and variables in a bank nobody
         * selected. From the panel that is "saving failed and now the game is
         * broken until I reload the cartridge", which is the worst outcome a
         * timeout can have.
         *
         * So an abort with a transfer in flight goes to REST instead: the same
         * state a completed save ends in, which writes the machine's OWN windows
         * back and only then hands the CPU over. `busy_q` stays up for it, so
         * the CPU stays held while the bus is still borrowed -- dropping to IDLE
         * would release `sleep` while this engine was still driving the bus.
         *
         * A load is the other half: its memory has been half overwritten, so its
         * register file must NOT be installed (`err_q` suppresses RESR, see
         * REST) -- rewinding the PC into a state that is half applied is how a
         * failed load becomes a crash rather than a failed load. */
        else if (abort_ev) begin
            if (busy_q) begin
                st      <= REST;
                aborted <= 1'b1;
                err_q   <= is_load;
                drive   <= 1'b0;
            end
            else begin
                st        <= IDLE;
                loading_q <= 1'b0;
                drive     <= 1'b0;
                err_q     <= 1'b0;
                aborted   <= 1'b0;
            end
        end
        /* A transfer that never finishes is ended here (see XFER_BIT above).
         * REST is deliberately the target and not IDLE: the walk banks the
         * machine's windows with ordinary writes, and a timeout in the middle
         * of one would otherwise leave the game looking at another bank. */
        else if (busy_q && (st != DONE) && xfer_wd[XFER_BIT]) begin
            st      <= REST;
            err_q   <= 1'b1;
            aborted <= 1'b1;   // the machine's own windows, as above
            drive   <= 1'b0;
        end
        /* The backstop: the machine comes back even if the release never
         * arrived (see HOLD_BIT). Same destination as the timeout above --
         * REST puts the machine's own bank registers back before the CPU is
         * handed over -- but with no stall exemption and no way to disarm it. */
        else if (busy_q && (st != DONE) && hold_wd[HOLD_BIT]) begin
            st      <= REST;
            err_q   <= 1'b1;
            aborted <= 1'b1;
            drive   <= 1'b0;
        end
        else begin
            case (st)
                IDLE: begin
                    drive     <= 1'b0;
                    busy_q    <= 1'b0;
                    loading_q <= 1'b0;
                    if (save_ev || load_ev) begin
                        is_load     <= load_ev;
                        wid         <= 32'd0;
                        lane        <= 3'd0;
                        word        <= 64'h0;
                        err_q       <= 1'b0;
                        freeze_cnt  <= 20'd0;
                        busy_q      <= 1'b1;
                        loading_q   <= load_ev;
                        bank_m      <= banking_q;
                        dma_m       <= dma_ctl_q;
                        bank_w      <= banking_q;
                        dma_w       <= dma_ctl_q;
                        cfg_bank    <= banking_q;
                        cfg_dma     <= dma_ctl_q;
                        aborted     <= 1'b0;
                        cart_v      <= 1'b0;
                        // A load has nothing to snapshot, but it has the same
                        // reason to wait for the machine to be quiet (LWAIT).
                        st          <= load_ev ? LWAIT : FREEZE;
                    end
                end

                // Hold the CPU still (sleep is up, so its RDY is low) and let
                // its registers settle, then take the snapshot.
                /* THE MACHINE IS NOT QUIET WHEN THE CPU IS.
                 *
                 * Three clocks only waited for the CPU's own registers to
                 * settle. Two things outlive the stop and both matter:
                 *
                 *   a COPY IN FLIGHT -- the blitter's counters are working
                 *   storage, not state, so `blit_busy` is up until the copy
                 *   lands; snapshotting before that writes half a framebuffer
                 *   into the file. `blit_ce` (rtl/gametank.sv) is what lets
                 *   that copy finish while the CPUs are held, so this wait
                 *   cannot deadlock on the menu's own pause.
                 *
                 *   A BUS READ IN FLIGHT -- `bus_busy` is the cartridge cache
                 *   or the GRAM row buffer still fetching the byte the CPU had
                 *   asked for. The walk's first act is to write the bank
                 *   register (`$2005`), and doing that while the cartridge has
                 *   a fetch outstanding re-tags the line under it: the game
                 *   then executes the wrong bytes the moment it is released.
                 *   That is cart-dependent by nature, and it is why the games
                 *   that run out of the banked window (tetris) were the ones
                 *   that died on a save.
                 *
                 * Both are bounded by the transfer watchdog above, so a
                 * machine that never goes quiet still answers its host.
                 */
                /* THE WAIT FOR QUIET IS BOUNDED (2026-10-25). `blit_busy` and
                 * `bus_busy` are the machine's own in-flight work, and the
                 * engine's `sleep` stops the CPUs that would ordinarily retire
                 * it. `blit_ce` keeps a copy running, but a cartridge fetch is
                 * retired by the cart's own logic only if it was already
                 * accepted; a CPU stopped mid-handshake can leave `bus_busy`
                 * up for as long as it stays stopped -- and the menu, which is
                 * where a save is taken from, stops it. That is an unbounded
                 * wait inside a transfer the host is timing, so it is capped
                 * here (1,024 clocks = 36 us, more than ten PSRAM beats):
                 * snapshot after it regardless, which is what the sibling
                 * Pocket core (C:/Code/Minicube64, mc64_savestates) does -- it
                 * never waits on machine activity at all, only on its CPU
                 * having stopped. */
                /* A LOAD WAITS FOR THE MACHINE TO BE QUIET TOO (2026-10-28).
                 *
                 * The save path has always waited (`FREEZE` below) because it
                 * has to read a machine that is not moving. The load path
                 * writes the machine's own bank registers -- `$2005` selects
                 * the system-RAM bank, and its bit 3 selects the VRAM page the
                 * BLITTER is drawing into -- and it used to start the moment the
                 * command arrived. An APF load is commanded from the core menu,
                 * which pauses the CPUs but NOT the copy already in flight
                 * (`blit_ce`, rtl/gametank.sv), so a load could move the VRAM
                 * page out from under a blitter mid-copy: half of one page, half
                 * of the other. That is a corrupted picture that only shows up
                 * on a cart that blits -- and it is exactly the kind of "load
                 * worked, but the screen is wrong" this path cannot otherwise
                 * see.
                 *
                 * The wait is the same shape and the same bound as FREEZE's: at
                 * most 1,024 clocks (36 us), because a cartridge fetch a stopped
                 * CPU left outstanding may never retire on its own. */
                LWAIT: begin
                    drive <= 1'b0;
                    if (freeze_cnt >= 20'd3 &&
                        ((!blit_busy && !bus_busy) || freeze_cnt >= 20'd1024)) begin
                        st <= WSTART;
                    end
                    else begin
                        freeze_cnt <= freeze_cnt + 20'd1;
                    end
                end

                FREEZE: begin
                    drive <= 1'b0;
                    if (freeze_cnt >= 20'd3 &&
                        ((!blit_busy && !bus_busy) || freeze_cnt >= 20'd1024)) begin
                        cpu_q_l <= cpu_q;
                        mc_l    <= mc_in;
                        bank_m  <= banking_q;
                        dma_m   <= dma_ctl_q;
                        st      <= WSTART;
                    end
                    else begin
                        freeze_cnt <= freeze_cnt + 20'd1;
                    end
                end

                WSTART: begin
                    drive <= 1'b0;
                    if (wid == WORDS) begin
                        st <= REST;
                    end
                    else if (is_load) begin
                        if (!load_empty) begin
                            // The FIFO's head is this word; `load_rd` pops it
                            // on this same edge.
                            word <= load_data;
                            lane <= 3'd0;
                            if (wid == 32'd0) begin
                                if (load_data[63:32] != TAG) begin
                                    err_q <= 1'b1;
                                    st    <= REST;
                                end
                                else begin
                                    st <= CFG;
                                end
                            end
                            else begin
                                st <= CFG;
                            end
                        end
                    end
                    else if (!WALK) begin
                        // The bisect: a word of the state that is not taken from
                        // the machine. Everything else about the transfer -- the
                        // word count, the rate through the store, `ok`, the
                        // read-out the host does -- is unchanged.
                        lane <= 3'd0;
                        word <= 64'h0;
                        st   <= EMIT;
                    end
                    else begin
                        lane <= 3'd0;
                        word <= 64'h0;
                        st   <= CFG;
                    end
                end

                // Point the machine's windows at this word's region. At most
                // two register writes, and only when a boundary was crossed.
                CFG: begin
                    drive <= 1'b0;
                    if (word_is_reg) begin
                        if (!is_load) word <= special_word;   // header/regs
                        st <= is_load ? ADVW : EMIT;
                    end
                    else if (wid >= VIA_BASE) begin
                        // the 6522: no bus at all, straight out of the snapshot
                        if (!is_load) word <= via_l[(wid - VIA_BASE) * 64 +: 64];
                        st <= is_load ? ADVW : EMIT;
                    end
                    else if (want_dma != cfg_dma) begin
                        drive      <= 1'b1;
                        drive_we   <= 1'b1;
                        drive_addr <= 16'h2007;
                        drive_do   <= want_dma;
                        cfg_dma    <= want_dma;
                    end
                    else if (want_bank != cfg_bank) begin
                        drive      <= 1'b1;
                        drive_we   <= 1'b1;
                        drive_addr <= 16'h2005;
                        drive_do   <= want_bank;
                        cfg_bank   <= want_bank;
                    end
                    else begin
                        st <= BRD;
                    end
                end

                // A memory byte: read it (three clocks) or write it.
                // The drive register is what puts the address on the bus, so
                // it is visible during the NEXT cycle -- one clock to present,
                // one to let the console's latches and RAM output register
                // settle, and the byte is sampled at the end of that second
                // clock. A write commits on the second clock's edge the same
                // way, which is why both directions take the two states.
                BRD: begin
                    drive      <= 1'b1;
                    drive_we   <= is_load;
                    drive_addr <= byte_addr;
                    drive_do   <= word[lane*8 +: 8];
                    st         <= BWAIT;
                end

                BWAIT: begin
                    // The address (and, on a write, the data) has been on the
                    // bus for this whole clock: the console latches it at the
                    // END of this clock, and its RAM output register loads on
                    // that same edge. So a write has committed by the time we
                    // leave, and a read's byte is waiting one clock later.
                    st <= is_load ? ADVW : BREAD;
                end

                BREAD: begin
                    // Hold the address one more clock. System RAM answers one
                    // clock after the address latches; the framebuffer's port
                    // answers two (its address register feeds the array's own
                    // output register), so the sample is in BREAD2 and it is
                    // exact for both.
                    st <= BREAD2;
                end

                BREAD2: begin
                    word[lane*8 +: 8] <= bus_di;
                    drive             <= 1'b0;
                    st                <= ADVW;
                end

                ADVW: begin
                    drive <= 1'b0;
                    if (lane == 3'd7) begin
                        lane <= 3'd0;
                        if (is_load) begin
                            wid <= wid + 32'd1;
                            st  <= WSTART;
                        end
                        else begin
                            st <= EMIT;
                        end
                    end
                    else begin
                        lane <= lane + 3'd1;
                        st   <= CFG;
                    end
                end

                // Hand the finished word to the APF end, waiting for room.
                EMIT: begin
                    drive <= 1'b0;
                    if (!save_full) begin
                        wid  <= wid + 32'd1;
                        lane <= 3'd0;
                        st   <= WSTART;
                    end
                end

                // Put the machine back exactly as it was: the window registers
                // first, then (for a load) the CPU's registers and microcode.
                REST: begin
                    drive <= 1'b0;
                    if (cfg_dma != tgt_dma) begin
                        drive      <= 1'b1;
                        drive_we   <= 1'b1;
                        drive_addr <= 16'h2007;
                        drive_do   <= tgt_dma;
                        cfg_dma    <= tgt_dma;
                    end
                    else if (cfg_bank != tgt_bank) begin
                        drive      <= 1'b1;
                        drive_we   <= 1'b1;
                        drive_addr <= 16'h2005;
                        drive_do   <= tgt_bank;
                        cfg_bank   <= tgt_bank;
                    end
                    else if (is_load && !err_q) begin
                        st <= RESR;
                    end
                    else begin
                        st      <= BUSR;
                        busr_cnt <= 3'd0;
                    end
                end

                RESR: begin
                    // One cycle with the CPU stopped: its register file and the
                    // microcode go back, and the next cycle lets it run. The
                    // 6522 is loaded on the same edge -- it has to be, or the
                    // CPU's first timer read after a load sees the old chip.
                    drive       <= 1'b0;
                    restore_r   <= 1'b1;
                    via_load    <= via_w;
                    via_load_we <= 1'b1;
                    st          <= BUSR;
                    busr_cnt    <= 3'd0;
                end

                /* THE LAST THING ON THE BUS IS THE CPU'S OWN ADDRESS
                 * (2026-10-24). The machine's read path is registered and
                 * SHARED: `rd_sel`, the system-RAM output latch and the audio
                 * RAM latch all hold whatever the last access left in them, and
                 * the CPU samples its pending read on the first strobe after
                 * RDY rises. Released straight from the walk, that strobe read
                 * the walk's LAST byte -- audio RAM at $3FFF -- no matter what
                 * address the CPU had asked for. The high byte of a 16-bit
                 * fetch is where it shows: the CPU executed a wrong opcode and
                 * jumped into the picture, which from the outside is a game
                 * that crashes the instant the OS saves.
                 *
                 * Measured in sim/gt/tb_cart_ss.cpp before this existed:
                 * tetris's PC pages over the 200 K clocks after a save were
                 * 73xx/74xx/75xx/76xx/77xx (a straight walk through the
                 * framebuffer) against ABxx/ACxx with no save at all.
                 *
                 * So the bus is held on `cpu_addr` -- the address the stopped
                 * CPU is still pointing at -- for six clocks, read-only, which
                 * reloads every shared register with the byte the CPU is about
                 * to sample. Six is more than the three the slowest registered
                 * path needs (the cartridge lookup: tag check, then `bank_q`),
                 * and a miss is safe anyway because the stall that comes with it
                 * keeps the CPU's strobe off until the fetch lands. */
                /* ONE STROBE, THEN LISTEN (2026-10-25).
                 *
                 * This used to hold the engine's bus for six clocks with
                 * `drive` up, and the engine's `bus_ce` (rtl/mainbus.sv) is a
                 * level, not the CPU's 1-in-8 pulse -- so the cartridge got SIX
                 * read strobes for one pending fetch. Its cache answers the
                 * first, but every later pulse re-issues the lookup, and a
                 * pulse that lands while a miss is still filling compares a tag
                 * against a data word that has already moved: `bank_q` is
                 * written from a stale line and the CPU samples the wrong byte.
                 *
                 * That is a wrong opcode on the very first fetch after a save,
                 * and it is cart-dependent -- only a game executing out of the
                 * $8000 banked window (tetris) has a cartridge byte pending.
                 * Measured here: three saves a few frames apart put the PC in
                 * $73xx-$74xx (the framebuffer window, which is not executable)
                 * and $82xx of the wrong bank.
                 *
                 * So BUSR drives the address for exactly one cycle, the way the
                 * CPU does, and BUSS then lets the bus go quiet while the
                 * registered paths settle -- the console's own windows are
                 * latched off that one strobe, and the CPU's first strobe finds
                 * them already loaded. */
                BUSR: begin
                    drive       <= 1'b1;
                    drive_we    <= 1'b0;
                    drive_addr  <= cpu_addr;
                    via_load_we <= 1'b0;   // one clock is all the chip needs
                    st          <= BUSS;
                end

                BUSS: begin
                    drive <= 1'b0;   // the address stays selected; no strobes
                    if (busr_cnt == 3'd5) st <= DONE;
                    else busr_cnt <= busr_cnt + 3'd1;
                end

                DONE: begin
                    drive     <= 1'b0;
                    // ... and a transfer that was cut short is not a state that
                    // was restored, however much of it landed.
                    done_q    <= is_load && !aborted;
                    busy_q    <= 1'b0;
                    loading_q <= 1'b0;
                    st        <= IDLE;
                end

                default: st <= IDLE;
            endcase

            // ---- the load's captured words ----------------------------------
            // Words 0..3 are registers, not memory: they arrive through the
            // FIFO, are latched as they go past, and CFG skips the bus for
            // them (their bytes are already complete). `restore_r` puts them
            // back into the machine at the end.
            if (ld_take && wid == 32'd1) cpu_q_w <= load_data;
            if (ld_take && wid == 32'd2) begin
                dma_w  <= load_data[15:8];
                bank_w <= load_data[7:0];
                cart_w <= load_data[23:16];
                cart_v <= load_data[31];
            end
            if (ld_take && wid == 32'd3) mc_w    <= load_data;
            if (ld_take && wid == 32'd4) acp_q_w <= load_data;
            if (ld_take && wid == 32'd5) acp_mc_w <= load_data;
            if (ld_take && wid == 32'd6) acp_rate_w <= load_data[7:0];
            if (ld_take && wid >= VIA_BASE)
                via_w[(wid - VIA_BASE) * 64 +: 64] <= load_data;

            // the snapshot the save direction reads out of the machine
            if (st == FREEZE && freeze_cnt >= 20'd3 &&
                ((!blit_busy && !bus_busy) || freeze_cnt >= 20'd1024)) begin
                acp_q_l    <= acp_q;
                acp_mc_l   <= acp_mc_in;
                acp_rate_l <= acp_rate;
                via_l      <= via_state;
            end
        end
    end

    wire ld_take = (st == WSTART) && is_load && !load_empty;

endmodule

`default_nettype wire
