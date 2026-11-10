//============================================================================
//  gt_save_file -- the core writes the Save slot's `.sav` WHILE THE GAME RUNS,
//  so a save is on the card before the player can quit.
//
//  THE OS ALSO WRITES IT AT QUIT, AND THAT IS THE PRICE OF THE FILE
//  (2026-11-09). `pocket/data.json` marks slot 2 `"nonvolatile": true`, because
//  that flag is the only way a `.sav` under /Saves exists at all: Analogue's
//  data.json reference defines it as "loaded and unloaded on core exit", and a
//  slot without it is neither loaded at launch nor written back. The framework's
//  own bridge answers `[0080]` with one `_ok` bit -- there is no "skip this
//  write-back" result a core can return -- so a clean quit still costs one
//  read-out of the slot. Its SIZE is this core's: the file is head + tail (see
//  rtl/core_top.v), ~196 KB on a 2 MB cartridge instead of 2 MB, which is 61 ms
//  of bridge at the APF's measured 3.23 MB/s. What this module adds is the save
//  the player does not lose if the console is switched off before quitting: the
//  file is written while the game runs.
//
//  THE FRAMEWORK STILL LOADS IT, and `"deferload"` is false so that it does.
//  It was true for one build, and that build is the one the panel answered with
//  "error in framework: core not ready to run": with nothing to load, this core
//  asked for a file before the framework had finished the cartridge, and the
//  boot was spent in data-slot commands instead of running. The restore below
//  is therefore a FALLBACK -- see rtl/core_top.v's arming, which only sends it
//  when the framework put nothing in the slot -- and in the ordinary case the
//  `.sav` reaches the image the same way it always has: the framework loads it,
//  right after the cartridge and before `[008F]`.
//
//  NONVOLATILE IS NOT THE FILE CHANNEL, and the 2026-11-07 note that said it
//  was is not evidence about it: the two builds with the flag clear were also
//  missing the writer fixes this one carries (the restart storm, the
//  created-file arm). What the flag controls is the launch load and the
//  shutdown read-out; `[0192]`/`[0184]` are the data-slot file commands and are
//  not gated on it. The card settled the rest: with the flag clear there was no
//  `.sav` anywhere on it, and the core's own `[0192]` create was refused -- see
//  the 2026-11-09 (later) entry in tmp/gfx/docs/gametank-port.md. A clean quit's
//  read-out is the price of the file existing, and it is bounded by the size
//  above, not by the cartridge.
//
//  THE NAME IS STILL THE `.sav` THE OS USED TO RESOLVE. A deferload slot names
//  no file, so [0190] for slot 2 is normally empty and the path is built from
//  the CARTRIDGE's own ([0190] slot 1) -- which is exactly how the OS named the
//  save when it owned it:
//
//    /Assets/gametank/common/Cubicle Knight.gtr
//    /Saves/gametank/common/Cubicle Knight.sav
//
//  and `<rom>save.gtr` beside the cartridge is the last resort, when even the
//  mirror cannot be built or the Saves path will not open.
//
//  WHY THIS STILL EXISTS. GameTank's save IS the whole cartridge image: a game
//  rewrites its own file in flash, so the image on the card is the save. A save
//  must reach the card at the moment the game makes it (this module), and the
//  platform's shutdown read-out is not a save mechanism any more -- it produced
//  zero-filled files on this core, because the host walks the window faster
//  than PSRAM feeds it. The file is correct because this module wrote it, or
//  because the launch restore read it back; nothing else touches it.
//
//  HOW. Four target commands, core-to-host (docs/APF-NOTES.md in
//  kroy-the-rabbit/openfpga-carttools is the reference for all of them):
//
//    [0190] get filename of data slot  -- slot 1 is the cartridge, slot 2 the
//                                          save slot; the host answers with the
//                                          FULL path it resolved for the slot
//    [0192] open new file into slot     -- create/resize it, so a first save on
//                                          a cartridge with no save file works
//    [0184] data slot write             -- host copies `length` bytes OUT of
//                                          this core into the file at an offset
//    [0188] data slot flush             -- host pushes its buffer to the card
//
//  The name is the ROM's own path with its extension replaced: the host hands
//  back `/Assets/gametank/common/Minicraft.gtr`, and this module rewrites the
//  bytes from the last '.' as `save.gtr`, giving
//  `/Assets/gametank/common/Minicraftsave.gtr`. A path with no '.' just gets
//  `save.gtr` appended. Nothing about the name is fixed in this file -- it is
//  built from whatever the OS says the ROM is, so it follows the card's folder
//  layout rather than assuming one.
//
//  AND THE FILE IS STILL THE `.sav`. Every open in this file names the path the
//  OS used to resolve for the slot -- `/Saves/<platform>/<core>/<name>.sav` --
//  so the card keeps the saves it already has. Only the writer changed.
//
//  WHY THE FILE GOES OUT IN CHUNKS, AND WHY THAT IS NOT AN OPTIMISATION.
//  [0184] has the host read the image out of the slot's window (0x02000000,
//  rtl/gt_save_slot.sv), exactly as the OS does at shutdown. But the host reads
//  that window at about 5 MB/s and the stream behind it is fed by PSRAM at about
//  2.5 MB/s. ONE command covering the whole image therefore drains the slot's
//  2 KB read-ahead in the first few hundred microseconds and every word after it
//  is a zero. The command boundary is the pacing: each [0184] asks for at most
//  one FIFO's worth (1920 bytes), the slot reports when that much is resident,
//  and no command is issued until it is. A 32 KB cartridge is 17 commands; a
//  2 MB one is 1,024, and takes a couple of seconds.
//
//  A FLASH CARTRIDGE'S FILE IS USUALLY NOT THE IMAGE ANY MORE (2026-11-09).
//  It is [the cartridge's first 128 bytes][the image from the lowest byte the
//  game changed], and `img_bytes` is that FILE's length -- see rtl/core_top.v's
//  `sv_tail` and rtl/gt_save_slot.sv's `tail_en`. This module needs to know
//  nothing about the shape: every byte it asks for is a file byte, and the
//  slot's window serves file bytes (word 0 is the image's word 0, and the word
//  after the head is image word `sv_lo / 8`). So a save that used to be 1,024
//  commands over 2 MB is now the few sectors the game actually rewrote, and the
//  quit read-out is the same size, because the size table declares it.
//
//  SO THERE IS NO SECOND COPY OF THE IMAGE. No extra PSRAM port, no extra M10K:
//  the only storage in this module is the two 264-byte struct windows (the path
//  the OS gave for the save slot, and the one this module builds for the file).
//============================================================================

`default_nettype none

module gt_save_file #(
    // The struct window: bytes 0x000..0x0FF are the file path (written by the
    // host on [0190], handed straight back on [0192]), 0x100 is the open flags
    // and 0x104 the desired size. TWO of them, 264 bytes apart: the OS's own
    // path at STRUCT_BASE, the path this module builds at STRUCT_BASE + 0x108.
    parameter logic [31:0] STRUCT_BASE = 32'h0300_0000,
    // The save slot's read window (data.json: address 0x02000000).
    parameter logic [31:0] IMG_WINDOW  = 32'h0200_0000,
    parameter int          IMG_MAX     = 2097152,
    // One command's worth: the slot's FIFO holds 256 64-bit entries and its
    // fill stops at 240, so a chunk must never ask for more than that.
    parameter int          CHUNK_BYTES = 1920,
    /* 66 words per struct (64 of path + flags + size), two of them -- but only
     * the first 128 are stored. The last four words of the pair are the second
     * window's flags and size, which are answered from registers, and 128 words
     * is what banks into 32-word slices. See the note at the array. */
    parameter int          WORDS       = 128
) (
    input  logic        clk,            // clk_74a
    input  logic        reset,

    // ---- when -------------------------------------------------------------
    input  logic        trig,           // clk_74a pulse: the game saved ($90)
    input  logic        inmenu,         // level: the OS menu is open
    input  logic        have_img,       // a cartridge image is loaded
    input  logic [31:0] img_bytes,      // ... and this is how big it is

    /* THE FILE ON THE CARD ALREADY HOLDS THIS IMAGE (2026-11-08).
     *
     * The OS writes a nonvolatile slot's file back INTO the core at launch, so
     * for the whole session the image in PSRAM and the `.sav` on the card agree
     * except for the bytes the game has reprogrammed since. This is that fact:
     * core_top raises it when the launch load told it the `.sav` is exactly the
     * cartridge's size and the image probe accepted it. `synced` below covers
     * the rest -- the first full write this module makes. Together they are the
     * licence to write a span instead of the whole image. */
    input  logic        file_ok,

    /* ... AND WHETHER THIS CARTRIDGE HAS A SPAN AT ALL (2026-11-08).
     *
     * A Flash2M cart saves IN ITS FLASH, so rtl/cart.sv sees every byte the
     * game rewrites and the span is the whole story. A RAM32K cart saves in its
     * 32 KB of SRAM, which is not the flash model at all -- nothing is counted,
     * and a span save would write nothing while the SRAM changed. On that cart
     * the writer always writes the window (32 KB, instantly), which is what it
     * did before spans existed. */
    input  logic        span_ok,

    /* ---- the span of the image the game has changed -----------------------
     *
     * rtl/cart.sv counts every flash program and erase it executes and holds the
     * lowest and highest image byte touched since the last capture. This module
     * captures that span when it starts a save (a two-phase handshake, because
     * the two ends are in different clocks) and writes only those bytes.
     *
     * A 2 MB cartridge used to be written 2 MB at a time on every save -- the
     * host reads the window at ~3 MB/s and writes the card behind it, so a save
     * that changed one 64 KB sector cost a minute of card traffic for 33 times
     * the data. A Minicraft save touches 0x1D0000..0x1F9FFF; the rest of the
     * image is identical on both sides, and every byte of it was being re-read
     * and re-written. */
    output logic        span_req,       // capture and clear the span (held)
    input  logic        span_ack,       // ... captured: lo/hi/any are stable
    input  logic [20:0] span_lo,
    input  logic [20:0] span_hi,
    input  logic        span_any,

    // ---- the image stream (rtl/gt_save_slot.sv) ---------------------------
    output logic        slot_arm,       // pulse: stream the image from `slot_start`
    output logic [21:0] slot_start,     // ... this image word
    output logic [8:0]  slot_thresh,    // entries this chunk needs
    input  logic        slot_full,      // ... the FIFO holds them

    // ---- the struct windows, through the bridge ---------------------------
    input  logic [31:0] bridge_addr,
    input  logic        bridge_rd,
    output logic [31:0] rd_data,
    input  logic        bridge_wr,
    input  logic [31:0] bridge_wr_data,

    // ---- target commands (rtl/core_bridge_cmd.v) --------------------------
    output logic        t_write,
    output logic        t_read,
    output logic        t_getfile,
    output logic        t_openfile,
    output logic        t_flush,
    output logic [15:0] t_id,
    output logic [31:0] t_slotoffset,
    output logic [31:0] t_bridgeaddr,
    output logic [31:0] t_length,
    output logic [31:0] t_param_struct,
    output logic [31:0] t_resp_struct,
    input  logic        t_done,
    input  logic [2:0]  t_err,

    // ---- the launch restore -----------------------------------------------
    input  logic        load_req,       // clk_74a pulse: read the file back in
    output logic        load_busy,      // level: keep the console in reset
    output logic        load_done,      // pulse: the image has been restored

    // ---- status -----------------------------------------------------------
    output logic        busy,
    output logic        done,           // pulse: the file is written and flushed
    output logic        failed          // level: the last attempt gave up
);

    // data.json: slot 1 is "Cartridge" (the .gtr), slot 2 is "Save".
    localparam logic [15:0] SAVE_SLOT_ID = 16'd2;
    localparam logic [15:0] ROM_SLOT_ID  = 16'd1;

    // Word offsets of the two struct windows inside `sram`, and of the two
    // words appended to each path (flags at +0x100, size at +0x104).
    localparam int A_WORD = 0;      // the OS's own path for slot 2
    localparam int B_WORD = 66;     // the path this module builds
    localparam logic [31:0] B_BASE = STRUCT_BASE + 32'h108;

    // The bytes written over the ROM's extension. `save.gtr` -- the name the
    // card's own tooling uses for a persisted cartridge, and the one that keeps
    // the file loadable as a cartridge in its own right.
    localparam int SUFFIX_LEN = 9;  // 8 characters + the NUL

    /* 150 ms of QUIET, not 3.5 ms (2026-11-08).
     *
     * This timer is what decides that a save has finished happening. It was
     * 2^18 clk_74a (3.5 ms), which is long enough for the `$90` prefix's own
     * writes and nothing else -- and `trig` is not just `$90`:
     * rtl/gametank.sv's `save_trig` is `save_trigger | flash_done`, so EVERY
     * program and EVERY erase the game executes asks for a save. A real save is
     * thousands of those. As long as each one lands within the window the save
     * keeps being deferred and the burst costs one write, which is the intent --
     * but a game whose flash loop pauses for longer than 3.5 ms -- one empty
     * frame between two sectors is 16.7 ms -- got a save mid-burst, and then
     * another after the next pause, and another, each one re-reading the span as
     * it grew. 172 KB of Minicraft save data became dozens of writes.
     *
     * 150 ms is four frames: a burst that pauses for a frame still coalesces,
     * and a save the player is waiting on lands a tenth of a second later than
     * it used to. A game that writes flash continuously without stopping never
     * gets a save from this timer at all -- opening the menu (the last moment
     * before a quit) still writes it, which is the case that matters. */
    localparam logic [23:0] SETTLE = 24'd11_137_500;    // 150 ms at 74.25 MHz

    function automatic logic [7:0] suffix_byte(input logic [3:0] k);
        case (k)
            4'd0: suffix_byte = "s";
            4'd1: suffix_byte = "a";
            4'd2: suffix_byte = "v";
            4'd3: suffix_byte = "e";
            4'd4: suffix_byte = ".";
            4'd5: suffix_byte = "g";
            4'd6: suffix_byte = "t";
            4'd7: suffix_byte = "r";
            default: suffix_byte = 8'h00;
        endcase
    endfunction

    // `sav`, written over the cartridge's own extension. Three characters for
    // three (`gtr`), so the name keeps its length and no byte after it moves.
    function automatic logic [7:0] sav_byte(input logic [3:0] k);
        case (k)
            4'd0: sav_byte = "s";
            4'd1: sav_byte = "a";
            4'd2: sav_byte = "v";
            default: sav_byte = 8'h00;
        endcase
    endfunction

    // `/Saves/` -- the Saves tree's own prefix, which replaces `/Assets/`.
    function automatic logic [7:0] pref_byte(input logic [3:0] k);
        case (k)
            4'd0: pref_byte = "/";
            4'd1: pref_byte = "S";
            4'd2: pref_byte = "a";
            4'd3: pref_byte = "v";
            4'd4: pref_byte = "e";
            4'd5: pref_byte = "s";
            4'd6: pref_byte = "/";
            default: pref_byte = 8'h00;
        endcase
    endfunction

    // ======================================================================
    //  The struct window
    // ======================================================================
    /* A MEMORY, NOT 3,316 FLIP-FLOPS (2026-10-31).
     *
     * The first version was a plain array with a combinational read, and
     * Quartus built it out of registers: the fit report for it says 2,256 ALMs,
     * 3,316 dedicated registers and **zero M10Ks**, which is 22% of the whole
     * device for 528 bytes of path. Compare rtl/mc64_state_buffer.sv, 8,967 bits
     * in M10K for 219 ALMs.
     *
     * The shape this needs is LUTRAM: one write port, an asynchronous read, and
     * the read has to answer in the address's own cycle because that is when
     * the bridge samples it. M10K cannot do that read; an MLAB can.
     *
     * The open flags and the size are NOT in here any more. They are two
     * constants for this core (`3` and the image size), so `rd_data` answers
     * them from registers at the two documented offsets, which removes the last
     * two multi-element writes.
     *
     * THE INDEX IS NINE BITS, NOT SEVEN. `wi` used to be `bridge_addr[8:2]`,
     * one bit short of the second struct's last word (0x0300_020C, word 131):
     * every write past word 127 wrapped to a low word, and `wi < WORDS`
     * truncated WORDS to 4 on top of it, so only the first four words of a path
     * were ever stored. The harness caught it as a writer that asked for two
     * paths and then retried for ever. */
    /* ONE M10K, REGISTERED READ (2026-11-01). Two fits measured the shapes
     * before this one. Flat 132 x 32: 4,399 ALMs, 4,237 combinational ALUTs and
     * 3,316 registers, with `scan_i` on a 645 ps path -- 41% of the device for
     * 528 bytes of path, because Quartus ignored `ramstyle` (a request, not an
     * order) and built flops with a 132-way read mux. Banked into 32-word
     * MLABs: the muxes are the cost and they stay in fabric either way. This is
     * one M10K, 128 x 32, simple dual port -- one write port, one registered
     * read -- and no fabric at all.
     *
     * THE REGISTERED READ IS ALLOWED. The bridge contract is "the core may not
     * immediately provide the read data and has up until the next read strobe to
     * drive bridge_rd_data", and `bridge_rd` is a level held for BOTH cycles of
     * an access (docs/gametank-port.md -- the read counter had to stop counting
     * it per cycle for exactly that reason). So the port carries the bridge's
     * address while it is accessing, the second cycle hands back the right word,
     * and the controller latches on both cycles with the last one standing.
     *
     * The sequence pays one cycle per word: a reading state presents its address
     * with `q_v` clear and consumes the word with `q_v` set. A cycle the bridge
     * takes the port, the sequence drops `q_v` and re-presents -- its address has
     * not moved, so nothing is skipped. 128 words at two cycles is 3.4 us.
     *
     * Words 128..131 of the pair (the second window's flags and size) are not
     * stored: they are answered from registers, and a bridge read of them gets
     * zero from `wi < WORDS`, which nothing consults. */
    (* ramstyle = "M10K, no_rw_check" *) logic [31:0] sram [0:WORDS-1];

    logic        sram_we    = 1'b0;
    logic [7:0]  sram_waddr = 8'h00;
    logic [31:0] sram_wdata = 32'h00;

    /* Which word the sequence is looking at, one per state that reads: the scan
     * over window A, the length/extension scan over window B, and the
     * read-modify-write as `save.gtr` replaces the extension. */
    logic [9:0]  fsm_addr;

    logic        q_v = 1'b0;            // the word at `fsm_addr` is in `rdata`

    /* THE BRIDGE'S WORD IS LATCHED AT ITS STROBE (2026-11-07).
     *
     * `bridge_rd` is `pmp_rd` (rtl/apf_top.v:333), and
     * rtl/io_bridge_peripheral.v raises it in ST_READ_1 -- one clock AFTER the
     * host sampled `pmp_rd_data` in ST_READ_0. So the host takes the word named
     * by the PREVIOUS strobe: it reads one address ahead and throws the first
     * read of every stream away. That is the same contract
     * rtl/gt_save_slot.sv implements, and the only reason any `.sav` on the
     * card has ever come out unshifted.
     *
     * This port used to be gated on `bridge_rd` itself, so during the address
     * phase -- the four clocks the host actually samples in -- it answered for
     * the SEQUENCE's address instead. The OS read `/Saves/...` shifted by four
     * bytes, and its flags and size words as each other: [0192] answered
     * "malformed path", no file was ever opened, and every save on the card
     * was really the OS's 2 MB shutdown writeback. That is the slow quit, and
     * the reason the park file never appeared. */
    logic [7:0]  brd_w   = 8'h00;       // the word the last strobe named
    logic [7:0]  brd_w_q = 8'h00;       // ... and the one `rdata` is holding
    logic        brd_q   = 1'b0;
    wire         brd_stb = bridge_rd & ~brd_q;
    // (latched in the sequence's own block, below: one always_ff owns it)

    /* The sequence owns the port while it walks a window; the bridge owns it at
     * every other moment, from its own latched address. */
    wire         fsm_use = (fst == F_SCANA) || (fst == F_LEN)   ||
                           (fst == F_DOT)   || (fst == F_PREF)  ||
                           (fst == F_SHIFT) || (fst == F_NAME)  ||
                           (fst == F_XT);
    wire  [9:0]  raddr = fsm_use ? fsm_addr : {2'b00, brd_w};
    logic [31:0] rdata;

    always_ff @(posedge clk) begin
        if (sram_we)
            sram[sram_waddr[6:0]] <= sram_wdata;
        rdata <= sram[raddr];
    end

    wire [31:0] br_word = rdata;
    wire [31:0] fs_word = rdata;

    wire  [9:0]  wi         = bridge_addr[9:2];
    logic        wr_q       = 1'b0;
    logic [9:0]  wr_addr_q  = 10'h3FF;

    // The bridge is a 32-bit word interface and the host writes the whole word,
    // so a write replaces the word and the byte lane is not consulted. The
    // address key is what makes a two-cycle `bridge_wr` one write (the same
    // shape rtl/gt_save_slot.sv keys its reads with).
    /* ... and only words the array actually holds. Without the `wi < WORDS`
     * guard a host write to the second window's flags (word 130) would land on
     * word 2 through the low seven bits -- the same truncation this file was
     * already bitten by once. */
    wire   sf_wr = bridge_wr && (bridge_addr[31:24] == 8'h03) &&
                   (wi < WORDS) &&
                   (!wr_q || (bridge_addr[9:0] != wr_addr_q));

    /* The two documented words after each path, answered from registers -- and
     * INDEXED BY THE LATCHED WORD, not by `bridge_addr`: the host samples word
     * 64 (flags) while presenting word 65, so the answer has to follow the
     * same one-behind rule as the array itself. Word 64/65 are window A's
     * flags/size, 130/131 window B's (out past the array, hence registers). */
    localparam logic [7:0] A_FLAGS_W = 8'(64);
    localparam logic [7:0] A_SIZE_W  = 8'(65);
    localparam logic [7:0] B_FLAGS_W = 8'(130);
    localparam logic [7:0] B_SIZE_W  = 8'(131);

    // ======================================================================
    //  When a save is owed
    // ======================================================================
    logic        trig_q   = 1'b0;
    logic        inmenu_q = 1'b0;
    logic        dirty    = 1'b0;       // a save happened, not yet on the card
    logic [23:0] wait_cnt = 24'd0;

    /* WHAT THE LAST ATTEMPT OWED, IF IT DID NOT FINISH (2026-11-08).
     *
     * A failed save used to raise `resync`, which says "the file is not the
     * image" and makes the NEXT save write all 2 MB. That is right for a failed
     * FULL write, and wrong -- and expensive -- for a failed span write: a span
     * that did not finish leaves bytes outside it untouched, so the only bytes in
     * doubt are the span's own, and those are exactly the bytes to write again.
     *
     * Without this, one failure under a flash burst (where triggers arrive every
     * few microseconds) turned every following trigger into a 2 MB rewrite: the
     * card was hammered for minutes and the save never converged. Now a failure
     * remembers its range and the retry re-covers it (merged with whatever the
     * game changed since), whatever its size. */
    logic [21:0] pend_lo  = 22'd0;
    logic [21:0] pend_hi  = 22'd0;      // exclusive
    logic        pend_any = 1'b0;
    logic        full_att = 1'b0;       // the attempt in flight writes the image
    wire         trig_ev  = trig  & ~trig_q;
    wire         menu_ev  = inmenu & ~inmenu_q;

    // ======================================================================
    //  The sequence
    // ======================================================================
    typedef enum logic [5:0] {
        F_IDLE,
        F_CLR, F_CLR2,
        F_GETA, F_GETALOW, F_GETAHIGH, F_SCANA,
        F_GETB, F_GETBLOW, F_GETBHIGH, F_LEN, F_DOT, F_NAME,
        // the mirrored Saves path: the /Assets/ prefix check, the extension
        // swapped to `sav`, and the byte copy that drops the prefix's 't'
        F_PREF, F_XT, F_SHIFT,
        F_SPAN,
        F_OPEN, F_OPENLOW, F_OPENHIGH,
        F_CHUNK, F_WAITFULL, F_WR, F_WRLOW, F_WRHIGH,
        F_FLUSH, F_FLUSHLOW, F_FLUSHIGH,
        // the restore: the same name, opened read-only, read back in chunks
        F_LOPEN, F_LOPENLOW, F_LOPENHIGH,
        F_LCHUNK, F_LRDLOW, F_LRDHIGH,
        F_LGOOD, F_LDONE,
        F_BAD, F_GOOD
    } fst_t;

    fst_t        fst     = F_IDLE;
    fst_t        fst_q   = F_IDLE;
    logic [31:0] len_q   = 32'd0;       // the whole file
    logic [31:0] sent    = 32'd0;       // bytes already in the file
    logic [31:0] chunk   = 32'd0;       // bytes in this command
    /* WHICH BYTES THIS SAVE WRITES (2026-11-08). `base` is the first image
     * byte, 8-aligned because the stream and the window are counted in 64-bit
     * entries; `dlen` is how many bytes follow it. A full save is base 0 and
     * dlen == len_q, which is what every save used to be. */
    logic [21:0] base    = 22'd0;
    logic [21:0] dlen    = 22'd0;
    /* The file is known to be the image: set by the launch load (`file_ok`) or
     * by a full write this module completed. Only then may a save write just
     * the span -- writing a span into a file that is NOT the image would leave
     * every byte outside the span as whatever the file held before (zeros, on a
     * file this session created). */
    logic        synced  = 1'b0;
    /* A save that FAILED may have left the file half-written, so the next one
     * may not assume the bytes outside its span are still the image. Set by
     * F_BAD, cleared by a full write that reaches the flush. */
    logic        resync  = 1'b0;
    logic [31:0] img_q   = 32'd0;      // a different cartridge is a different file
    logic [8:0]  clr_i   = 9'd0;
    logic [8:0]  scan_i  = 9'd0;        // byte index into our path
    logic [8:0]  len_b   = 9'd0;        // its length, NUL not included
    logic [8:0]  dot_q   = 9'd0;        // the '.' the suffix replaces
    logic [8:0]  nam_i   = 9'd0;        // which suffix byte is being written
    logic        path_ok = 1'b0;        // the ROM's path came back non-empty

    /* THIS PASS IS A LOAD, NOT A SAVE (2026-11-07).
     *
     * It is the FALLBACK, not the usual path (2026-11-09): the slot is
     * nonvolatile again, so the framework streams the .sav into the core at
     * launch and this pass is armed only when it did not -- `!slot2_seen &&
     * !slot2_hit` in rtl/core_top.v -- and never on a cartridge whose save may
     * have a tail (`sf_tail_cart`). Then the file has to be read and put back
     * before the console boots. The pass is the same walk -- slot 1's path, the
     * suffix, the struct window -- and the same slot-2 channel; only the
     * direction of the data command changes ([0180 in, [0184 out) and the file
     * is opened without create/resize.
     *
     * `lmode` is what the shared states test: F_NAME opens for reading instead
     * of writing, and the struct window answers flags 0 and size 0 (open the
     * file as it is) rather than 3 and the image size. */
    logic        lmode     = 1'b0;
    logic        load_want = 1'b0;      // a restore has been asked for
    /* WHICH WINDOW HOLDS THE FILE (2026-11-07).
     *
     * The file is the Save slot's own `.sav` -- the path [0190] answers for
     * slot 2 -- so the OS's slot and this core's file are the same file, and
     * the card keeps the saves it already has. `use_b` is the fallback: a host
     * that answers no path for slot 2 gets `<rom>save.gtr` beside the cartridge
     * from the name built out of the ROM's own path. It is set by F_GETB, which
     * is only reached when slot 2's window came back empty. */
    logic        use_b     = 1'b0;
    /* Whether window A holds the path THIS MODULE built from the ROM's (rather
     * than one the host answered). It is what decides whether a failed [0192
     * can fall back to the file beside the cartridge: window B still holds the
     * ROM's untouched path in that case, and nothing at all when the host
     * supplied window A. */
    logic        derived   = 1'b0;
    logic [1:0]  pf_i      = 2'd0;      // which prefix word is under the check
    logic [8:0]  sh_i      = 9'd0;      // destination byte index of the copy
    logic [31:0] sh_acc    = 32'd0;     // the destination word being assembled

    // The bridge's view of the window: paths out of the array, the two words
    // after each path out of registers (they are constants here).
    always @(*) begin
        if (bridge_addr[31:24] != 8'h03)
            rd_data = 32'h0;
        else if (brd_w_q == A_FLAGS_W || brd_w_q == B_FLAGS_W)
            // create | resize -- or, for the restore, neither: open the file
            // exactly as it is and leave its length alone. Both windows answer
            // the same way, because either one can be the file now.
            rd_data = lmode ? 32'd0 : 32'd3;
        else if (brd_w_q == A_SIZE_W || brd_w_q == B_SIZE_W)
            // The restore opens the file as it is, so its size field is not
            // used; a save resizes it to the image.
            rd_data = lmode ? 32'd0 : len_q;
        else if (brd_w_q < 8'(WORDS))
            rd_data = br_word;
        else
            rd_data = 32'h0;
    end
    /* A FLUSH HAS TO LAND BEFORE THE FIRST CHUNK (2026-10-31).
     *
     * `slot_arm` re-arms the stream by toggling a flush across to the memory
     * clock, and the write side's pointer clears a few clocks AFTER the read
     * side's (two clk_core of synchroniser, against a read side that sees its
     * own flush at once). Until it does, the FIFO's count still reads the
     * previous fill and `slot_full` is still high -- so a writer that fires its
     * first chunk straight after the arm asks the host to read 1,920 bytes of a
     * stream that has not restarted, and the FIFO serves whatever the old fill
     * left at the addresses the reset pointers now name. Measured in
     * sim/gt/tb_save_file.cpp: the first chunk of a re-armed stream came back as
     * image byte 2048 (the entry that had overwritten the FIFO's word 0), with
     * an underrun, and the file was wrong from its first byte.
     *
     * So an arm is followed by a wait for the count to fall to zero before any
     * chunk is asked for. That is the FIFO's own definition of "the reset has
     * landed", not a delay guessed here. */
    logic        need_low = 1'b1;      // the FIFO must read empty after an arm

    /* Every wait is bounded. A host that never answers a target command leaves
     * `t_done` low forever, and a core stuck on it would stop saving silently
     * and for ever -- the failure mode this whole file exists to avoid.
     *
     * IT WAS 3.6 s AND THE SAVE PAID IT (2026-11-08). 2^28 clk_74a is longer
     * than a whole 2 MB write, so a command the host does not answer -- the
     * best-effort park, most of all, whose file is not the player's and which a
     * card is free to refuse -- silently added three and a half seconds to every
     * save. The bound only has to be longer than a real command: a 1,920-byte
     * [0184 whose data has to reach the card is a few milliseconds, and 226 ms
     * is two orders of magnitude of headroom on that. A host that is slower than
     * that has stopped, and giving up costs the write, not the save.
     *
     * IT IS 0.9 s NOW (2026-11-08), because giving up no longer costs only that
     * command: a failed save is retried (`pend_*` above), so a timeout on a card
     * that is merely busy aborts a save that would have finished. 0.9 s is still
     * three orders of magnitude past a 1,920-byte write and far short of the 3.6 s
     * this used to leave on the table. */
    logic [27:0] to = 28'd0;
    wire         to_exp = (to == 28'h3FF_FFFF);       // ~0.9 s at 74.25 MHz

    // The image's length, clamped to what the slot can hold.
    wire [31:0] img_len = (img_bytes > 32'(IMG_MAX)) ? 32'(IMG_MAX) : img_bytes;

    /* MAY A SAVE TRUST THAT THE FILE IS THIS IMAGE? Only when the launch load
     * proved it (`file_ok`), or this module wrote the whole thing (`synced`);
     * only on a cartridge whose changes this core can see (`span_ok`); and only
     * until a save fails (`resync`), because a half-written file is not the
     * image however it started out. */
    wire        known = span_ok & (file_ok | synced) & ~resync;

    // The next chunk, worked out from what is left rather than from registers
    // this block is assigning in the same cycle.
    // ... measured from the span, not from the file: `dlen` is the whole image
    // for a full save and the changed run for a span save.
    wire [31:0] rem_n   = {10'd0, dlen} - sent;
    wire [31:0] chunk_n = (rem_n > 32'(CHUNK_BYTES)) ? 32'(CHUNK_BYTES) : rem_n;

    // The span, rounded out to the window's own 64-bit entries and clamped to
    // the image. `span_hi` is inclusive; a span ending at the last byte of a
    // 2 MB image rounds to 0x200000, which is why this is 22 bits.
    wire [21:0] sp_lo8 = {span_lo[20:3], 3'b000};
    wire [21:0] sp_hi8 = {1'b0, (span_hi | 21'd7)} + 22'd1;
    wire [21:0] sp_end = (sp_hi8 > len_q[21:0]) ? len_q[21:0] : sp_hi8;
    /* THE RANGE THIS SAVE MUST COVER: what the game changed since the last
     * capture, UNION what the previous attempt still owed. An empty span
     * carries no range at all, so it must not widen the union -- hence the
     * sentinel rather than the (meaningless) lo/hi the accumulator holds when
     * `span_any` is low. */
    wire [21:0] new_lo  = span_any ? sp_lo8 : 22'h20_0000;
    wire [21:0] new_hi  = span_any ? sp_end : 22'd0;
    wire [21:0] cov_lo  = (pend_any && (pend_lo < new_lo)) ? pend_lo : new_lo;
    wire [21:0] cov_hi  = (pend_any && (pend_hi > new_hi)) ? pend_hi : new_hi;
    wire [21:0] cov_len = (cov_hi > cov_lo) ? (cov_hi - cov_lo) : 22'd0;
    // The FIFO holds 64-bit entries, so a chunk is rounded up to a whole entry --
    // AND ONE MORE (2026-11-08). The host reads four bytes at a time, one word
    // behind: it gets the bytes at `X+4` by reading `X+8`. So the last four
    // bytes of every chunk are fetched from the entry AFTER it, and a chunk of
    // one entry (an 8-byte span, which is what a game that rewrote one word
    // produces) had no entry after it -- the stream was still three words in
    // and the host read the window empty. The spare entry is the lead the host
    // needs to finish a chunk, and for a full 1,920-byte chunk the cap is what
    // it always was. 240 is the fill's own ceiling (see gt_save_slot.sv).
    wire [31:0] ent_n   = ((chunk_n + 32'd7) >> 3) + 32'd1;
    wire [8:0]  thr_n   = (ent_n > 32'd240) ? 9'd240 : ent_n[8:0];

    // The byte of our path currently under the scanner, and the two fields the
    // name writer needs. All 9-bit arithmetic: a path is 256 bytes.
    wire [7:0]  scw     = 8'(B_WORD) + scan_i[7:2];
    wire [31:0] scword  = fs_word;
    wire [7:0]  scbyte  = scword[{scan_i[1:0], 3'b000} +: 8];

    wire [8:0]  nw_i    = dot_q + nam_i;
    wire [7:0]  nw_word = 8'(B_WORD) + nw_i[8:2];
    wire [1:0]  nw_lane = nw_i[1:0];

    // The extension swap: `sav` goes over the three bytes after the dot, so
    // the destination word is the SOURCE's own word and the byte lane is the
    // only thing that moves.
    wire [8:0]  xt_i    = dot_q + 9'd1 + nam_i;
    wire [7:0]  xt_word = 8'(B_WORD) + xt_i[8:2];
    wire [1:0]  xt_lane = xt_i[1:0];

    // The copy: destination byte `sh_i` comes from source byte `sh_i + 1` (the
    // prefix's 't' is the one byte the mirror drops), except for the seven
    // bytes of the new prefix itself.
    wire [8:0]  sh_src  = sh_i + 9'd1;
    wire [7:0]  sh_swb  = 8'(fs_word >> {sh_src[1:0], 3'b000});
    wire [7:0]  sh_byte = (sh_i < 9'd7) ? pref_byte(sh_i[3:0]) : sh_swb;
    wire        sh_rdy  = (fst == F_SHIFT) &&
                          ((sh_i < 9'd7) || (q_v && !bridge_rd));
    wire [31:0] sh_word = sh_acc | (32'(sh_byte) << {sh_i[1:0], 3'b000});
    wire        sh_last = (sh_i == (len_b - 9'd1));
    wire        sh_we   = sh_rdy && (sh_last || (sh_i[1:0] == 2'd3));

    // The sequence's read port, one address per state that reads the window.
    assign fsm_addr = (fst == F_NAME)  ? 10'(nw_word)
                    : (fst == F_XT)    ? 10'(xt_word)
                    : (fst == F_PREF)  ? (10'(B_WORD) + 10'(pf_i))
                    : (fst == F_SHIFT) ? (10'(B_WORD) + 10'(sh_src[8:2]))
                    : (fst == F_SCANA) ? 10'(scan_i)
                    :                    10'(scw);

    assign busy           = (fst != F_IDLE);

    // The console is held for the whole restore -- including the name walk,
    // which is four commands and 128 words of path before the first byte comes
    // back -- and from the cycle the request is seen, so there is no clock in
    // which the game can start against an image that is about to change. Only a
    // load holds it: a save runs while the game plays.
    assign load_busy      = lmode | load_want;

    // ======================================================================
    //  The array's one write port
    // ======================================================================
    // Exactly one writer per cycle: the host filling a path, the clear that
    // precedes it, or the name being rewritten over the extension. The host has
    // priority because its writes arrive asynchronously to the sequence; the
    // three never overlap in practice, and this ordering makes that explicit
    // rather than hopeful.
    always_comb begin
        sram_we    = 1'b0;
        sram_waddr = 8'h00;
        sram_wdata = 32'h00;

        if (sf_wr) begin
            sram_we    = 1'b1;
            sram_waddr = wi[6:0];
            sram_wdata = bridge_wr_data;
        end
        else if (fst == F_CLR) begin
            sram_we    = 1'b1;
            sram_waddr = clr_i[7:0];
            sram_wdata = 32'h0;
        end
        else if ((fst == F_NAME) && q_v && !bridge_rd) begin
            // Read-modify-write of one byte: `save.gtr` goes over the ROM's own
            // extension, and the bytes either side of it stay where they were.
            sram_we    = 1'b1;
            sram_waddr = nw_word;
            sram_wdata = (fs_word & ~(32'h0000_00FF << {nw_lane, 3'b000}))
                       | (32'(suffix_byte(nam_i[3:0])) << {nw_lane, 3'b000});
        end
        else if ((fst == F_XT) && q_v && !bridge_rd) begin
            // ... and `sav` over the same extension, in place: one byte per
            // cycle, read-modify-written, so the base name and its directory
            // are exactly what the cartridge has.
            sram_we    = 1'b1;
            sram_waddr = xt_word;
            sram_wdata = (fs_word & ~(32'h0000_00FF << {xt_lane, 3'b000}))
                       | (32'(sav_byte(nam_i[3:0])) << {xt_lane, 3'b000});
        end
        else if (sh_we) begin
            // The mirrored path, one destination word at a time. Every byte of
            // the word is known by the time it is written (the accumulator is
            // cleared after each), so no read-modify-write is needed -- and the
            // last word's spare bytes are zero, which is the path's NUL.
            sram_we    = 1'b1;
            sram_waddr = sh_i[7:2];
            sram_wdata = sh_word;
        end
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            fst        <= F_IDLE;
            fst_q      <= F_IDLE;
            trig_q     <= 1'b0;
            inmenu_q   <= 1'b0;
            dirty      <= 1'b0;
            wait_cnt   <= 24'd0;
            pend_lo    <= 22'd0;
            pend_hi    <= 22'd0;
            pend_any   <= 1'b0;
            full_att   <= 1'b0;
            len_q      <= 32'd0;
            sent       <= 32'd0;
            chunk      <= 32'd0;
            base       <= 22'd0;
            dlen       <= 22'd0;
            synced     <= 1'b0;
            resync     <= 1'b0;
            img_q      <= 32'd0;
            span_req   <= 1'b0;
            slot_start <= 22'd0;
            clr_i      <= 9'd0;
            scan_i     <= 9'd0;
            len_b      <= 9'd0;
            dot_q      <= 9'd0;
            nam_i      <= 9'd0;
            path_ok    <= 1'b0;
            use_b      <= 1'b0;
            derived    <= 1'b0;
            pf_i       <= 2'd0;
            sh_i       <= 9'd0;
            sh_acc     <= 32'd0;
            lmode      <= 1'b0;
            load_want  <= 1'b0;
            load_done  <= 1'b0;
            need_low   <= 1'b1;
            to         <= 28'd0;
            wr_q       <= 1'b0;
            wr_addr_q  <= 10'h3FF;
            brd_w      <= 8'h00;
            brd_w_q    <= 8'h00;
            brd_q      <= 1'b0;
            slot_arm   <= 1'b0;
            slot_thresh<= 9'd0;
            t_write    <= 1'b0;
            t_getfile  <= 1'b0;
            t_openfile <= 1'b0;
            t_flush    <= 1'b0;
            t_id       <= SAVE_SLOT_ID;
            t_slotoffset <= 32'd0;
            t_bridgeaddr <= IMG_WINDOW;
            t_length     <= 32'd0;
            t_param_struct <= STRUCT_BASE;
            t_resp_struct  <= STRUCT_BASE;
            done         <= 1'b0;
            failed       <= 1'b0;
        end
        else begin
            // One-cycle strobes; a state that issues a command raises its own
            // strobe for exactly the cycle it is in.
            slot_arm   <= 1'b0;
            t_write    <= 1'b0;
            t_read     <= 1'b0;
            t_getfile  <= 1'b0;
            t_openfile <= 1'b0;
            t_flush    <= 1'b0;
            done       <= 1'b0;
            load_done  <= 1'b0;

            trig_q   <= trig;
            inmenu_q <= inmenu;

            // A different cartridge is a different .sav: whatever this module
            // wrote for the last one says nothing about this one.
            if (img_bytes != img_q) begin
                img_q  <= img_bytes;
                synced <= 1'b0;
            end

            // Latched: the loader's end-of-stream is a pulse, and the FSM may
            // still be walking the last state of a save when it lands.
            if (load_req) load_want <= 1'b1;

            wr_q <= bridge_wr;
            if (bridge_wr) wr_addr_q <= bridge_addr[9:0];

            /* THE BRIDGE'S WORD, LATCHED WHERE ITS STROBE SAID (2026-11-07).
             * Before the state case, so a command start's `brd_w <= 0` below
             * wins on that cycle: every exchange begins with the priming read
             * the host throws away returning word 0. */
            brd_q <= bridge_rd;
            if (brd_stb && (bridge_addr[31:24] == 8'h03))
                brd_w <= bridge_addr[9:2];
            // `rdata` is a registered read, so it is always one word behind
            // `brd_w`: the flags/size registers have to be selected from that
            // same word, or the host is handed each as the other.
            brd_w_q <= brd_w;

            // The struct, written from three places in this one block: the host
            // (a path, on [0190]), and this module (the built name, then the
            // flags and size before each [0192]).



            if (fst != fst_q) to <= 28'd0;
            else if (!to_exp) to <= to + 28'd1;
            fst_q <= fst;

            // A state starts with no window word in hand; the states that read
            // present their address on this first cycle (see `q_v`).
            if (fst != fst_q) q_v <= 1'b0;

            // ---- trigger bookkeeping -------------------------------------
            /* A FAILED SAVE WAITS FOR THE NEXT ONE (2026-11-02).
             *
             * F_BAD puts `dirty` back so the state is not lost, and F_IDLE
             * starts again the moment the settle timer is out -- which is 3.5 ms.
             * A save that cannot succeed (a slot the host will not bind, a file
             * it will not create, a chunk it keeps refusing) therefore re-walks
             * the whole 2 MB image every few milliseconds for the rest of the
             * session: the console's PSRAM bus is saturated, the game turns to
             * treacle, and the card gets rewritten forever. That is a failure
             * the player sees as "it crashed after a while", and it is not one
             * this core can win by trying harder.
             *
             * So `failed` holds the retry until something actually asks again:
             * the game's next `$90`, or the menu being opened (the last moment
             * before a quit, where a save is worth one more try). A transient
             * failure still recovers on the next save; a permanent one costs the
             * console nothing. */
            if (trig_ev) begin
                dirty    <= 1'b1;
                failed   <= 1'b0;
                wait_cnt <= SETTLE;
            end
            else if (menu_ev && dirty) begin
                // Opening the menu is the last moment before a quit, and a quit
                // on this core is not survivable: stop waiting out the settle
                // timer and write now.
                failed   <= 1'b0;
                wait_cnt <= 24'd0;
            end
            else if (wait_cnt != 24'd0) begin
                wait_cnt <= wait_cnt - 24'd1;
            end

            unique case (fst)
            // ---------------------------------------------------------------
            F_IDLE: begin
                /* THE RESTORE COMES FIRST, AND ONLY ONCE (2026-11-07).
                 *
                 * `load_req` is a pulse from the loader's own end-of-stream, so
                 * it arrives while nothing else is competing for the channel.
                 * It is latched (`load_want`) because the arm below is a state
                 * the FSM may still be walking when the pulse lands. */
                if (load_want) begin
                    load_want <= 1'b0;
                    lmode     <= 1'b1;
                    use_b     <= 1'b0;
                    derived   <= 1'b0;
                    failed    <= 1'b0;
                    sent      <= 32'd0;
                    len_q     <= img_len;
                    // The restore reads from byte 0 of the file, exactly as the
                    // OS's own read-out does; `dlen` is the same as the file
                    // here, and F_LCHUNK paces its chunks off it.
                    base      <= 22'd0;
                    dlen      <= img_len[21:0];
                    path_ok   <= 1'b0;
                    clr_i     <= 9'd0;
                    fst       <= F_CLR;
                end
                else if (dirty && !failed && (wait_cnt == 24'd0) && have_img &&
                    (img_bytes != 32'd0)) begin
                    dirty <= 1'b0;
                    failed<= 1'b0;
                    sent  <= 32'd0;
                    len_q <= img_len;
                    use_b   <= 1'b0;
                    derived <= 1'b0;
                    path_ok <= 1'b0;
                    clr_i <= 9'd0;
                    // Nothing is in flight yet: a failure before F_SPAN has
                    // chosen a range wrote nothing and must not be read as a
                    // broken full write (see `full_att`).
                    full_att <= 1'b0;
                    // Ask what the game changed before deciding how much to
                    // write: the answer is the whole file for a cart that has
                    // never saved, and a few sectors for one that has.
                    span_req <= 1'b1;
                    fst   <= F_SPAN;
                end
            end

            // ---- how much of the image this save has to write --------------
            /* A SAVE WRITES WHAT CHANGED (2026-11-08). See the ports: cart.sv
             * holds the lowest and highest image byte the game has programmed
             * or erased since the last capture, and this is the capture. A full
             * image stays the answer whenever the file is not already known to
             * be the image -- no launch load, a load of the wrong size, a fresh
             * file, or a span that never arrives. */
            F_SPAN: begin
                if (span_ack) begin
                    span_req <= 1'b0;
                    if (known) begin
                        full_att <= 1'b0;
                        if (!span_any && !pend_any) begin
                            // The card already holds this image, byte for byte,
                            // and nothing changed since it was written.
                            fst <= F_GOOD;
                        end
                        else begin
                            // The changed run, or the range a failed attempt
                            // still owes, or the two merged -- see `pend_*`.
                            base     <= cov_lo;
                            dlen     <= cov_len;
                            pend_lo  <= cov_lo;
                            pend_hi  <= cov_hi;
                            pend_any <= 1'b1;
                            fst      <= F_CLR;
                        end
                    end
                    else begin
                        // Nothing vouches for the file, so the window is the
                        // only safe thing to write.
                        base     <= 22'd0;
                        dlen     <= len_q[21:0];
                        pend_any <= 1'b0;
                        full_att <= 1'b1;
                        fst      <= F_CLR;
                    end
                end
                else if (to_exp) begin
                    // No answer is not a licence to write a window: write the
                    // image, which is correct whatever the file held -- unless
                    // there is a range already owed, which is both correct and
                    // the only thing that can be missing.
                    span_req <= 1'b0;
                    full_att <= ~(known & pend_any);
                    base <= (known && pend_any) ? pend_lo : 22'd0;
                    dlen <= (known && pend_any) ? (pend_hi - pend_lo)
                                                : len_q[21:0];
                    fst  <= F_CLR;
                end
            end

            // ---- the same name, opened for reading -------------------------
            F_LOPEN: begin
                // flags 0: neither create nor resize, so a cartridge that has
                // never saved fails this open instead of creating an empty
                // file beside the ROM.
                // The host reads the struct one word behind from a priming
                // read; start that read at word 0 so the first path word it
                // wants is the one it gets.
                brd_w          <= 8'h00;
                t_param_struct <= use_b ? B_BASE : STRUCT_BASE;
                t_id           <= SAVE_SLOT_ID;
                t_openfile     <= 1'b1;
                fst            <= F_LOPENLOW;
            end

            F_LOPENLOW: begin
                if (!t_done)     fst <= F_LOPENHIGH;
                else if (to_exp) fst <= F_LDONE;
            end

            F_LOPENHIGH: begin
                if (t_done) begin
                    sent  <= 32'd0;
                    if (t_err <= 3'd1) begin
                        fst <= F_LCHUNK;
                    end
                    // A file the host will not open is either a path that does
                    // not exist yet -- a cartridge that has never saved -- or
                    // the mirrored name being wrong. Only a name this module
                    // built is worth a second attempt: the fallback's own
                    // refusal means booting on the image as it came in.
                    else if (derived) begin
                        use_b   <= 1'b1;
                        derived <= 1'b0;
                        scan_i  <= len_b;
                        fst     <= F_DOT;
                    end
                    else
                        fst <= F_LGOOD;
                end
                else if (to_exp) fst <= F_LGOOD;
            end

            // ---- read `chunk` bytes of the image back into the window -------
            F_LCHUNK: begin
                if (sent >= len_q) begin
                    // Every byte of the image came back from the card, so the
                    // file IS this image and the next save may write only what
                    // the game changes (see `known`). A short file leaves by
                    // F_LRDHIGH's error path and never sets this.
                    synced <= 1'b1;
                    fst    <= F_LGOOD;
                end
                else begin
                    chunk        <= chunk_n;
                    t_read       <= 1'b1;
                    t_id         <= SAVE_SLOT_ID;
                    t_slotoffset <= sent;
                    t_bridgeaddr <= IMG_WINDOW + sent;
                    t_length     <= chunk_n;
                    fst          <= F_LRDLOW;
                end
            end

            F_LRDLOW: begin
                if (!t_done)     fst <= F_LRDHIGH;
                else if (to_exp) fst <= F_LGOOD;
            end

            F_LRDHIGH: begin
                if (t_done) begin
                    if (t_err == 3'd0) begin
                        sent <= sent + chunk;
                        fst  <= F_LCHUNK;
                    end
                    else
                        // A file shorter than the image: what was there has
                        // been put back, and the rest is a cartridge that has
                        // never saved those bytes.
                        fst <= F_LGOOD;
                end
                else if (to_exp) fst <= F_LGOOD;
            end

            // ---- let the console out of reset ------------------------------
            F_LGOOD: begin
                // Nothing to hand back: with "nonvolatile": false the OS never
                // writes this slot's file, and the slot is only ever pointed at
                // the file this module is about to use.
                fst <= F_LDONE;
            end

            F_LDONE: begin
                lmode     <= 1'b0;
                load_done <= 1'b1;
                fst       <= F_IDLE;
            end

            // ---- blank both windows ----------------------------------------
            F_CLR: begin
                if (clr_i == 9'(WORDS - 1)) begin
                    clr_i <= 9'd0;
                    // The scan over slot 2's window presents its own address.
                    q_v   <= 1'b0;
                    fst   <= F_GETA;
                end
                else
                    clr_i <= clr_i + 9'd1;
            end

            // ---- the path the OS has for the save slot ---------------------
            F_GETA: begin
                brd_w          <= 8'h00;
                t_getfile      <= 1'b1;
                t_id           <= SAVE_SLOT_ID;
                t_resp_struct  <= STRUCT_BASE;
                fst            <= F_GETALOW;
            end

            F_GETALOW: begin
                if (!t_done)     fst <= F_GETAHIGH;
                else if (to_exp) fst <= F_GETB;      // no path, no hand-back
            end

            F_GETAHIGH: begin
                if (t_done) begin
                    scan_i <= 9'd0;
                    fst    <= (t_err == 3'd0) ? F_SCANA : F_GETB;
                end
                else if (to_exp) fst <= F_GETB;
            end

            F_SCANA: begin
                // Non-zero anywhere in the 256 bytes means the OS resolved a
                // path; a window cleared by F_CLR says it did not. Two cycles
                // a word: entry presents the address, the next consumes it
                // (`q_v`), and `scan_i` does not move between them. The final
                // iteration is word 63 -- the last of the path window.
                if (q_v && !bridge_rd) begin
                    if (fs_word != 32'h0)
                        path_ok <= 1'b1;
                    if (scan_i == 9'd63) begin
                        scan_i <= 9'd0;
                        // The slot's own path IS the file: open it, do not go
                        // build a second one. Only an empty slot-2 window
                        // falls through to the cartridge's path.
                        fst    <= (path_ok || (fs_word != 32'h0))
                                  ? (lmode ? F_LOPEN : F_OPEN) : F_GETB;
                    end
                    else begin
                        scan_i <= scan_i + 9'd1;
                        q_v    <= 1'b0;
                    end
                end
                else
                    q_v <= !bridge_rd;      // (re)present the address
            end

            // ---- the cartridge's own path ----------------------------------
            F_GETB: begin
                brd_w         <= 8'h00;
                // This is always answered -- it is the file the user launched --
                // and the Saves path is mirrored from it.
                t_getfile     <= 1'b1;
                t_id          <= ROM_SLOT_ID;
                t_resp_struct <= B_BASE;
                // The scan that follows starts at byte 0 of window B, and `q_v`
                // may still be high from the slot-2 scan: a state that consumes
                // a word on its first cycle would read the port's last word
                // (window A's) instead, and the path would be measured from a
                // byte that is not its first.
                q_v           <= 1'b0;
                fst           <= F_GETBLOW;
            end

            F_GETBLOW: begin
                if (!t_done)     fst <= F_GETBHIGH;
                else if (to_exp) fst <= F_BAD;
            end

            F_GETBHIGH: begin
                if (t_done) begin
                    scan_i <= 9'd0;
                    fst    <= (t_err == 3'd0) ? F_LEN : F_BAD;
                end
                else if (to_exp) fst <= F_BAD;
            end

            // ---- how long it is --------------------------------------------
            F_LEN: begin
                if (q_v && !bridge_rd) begin
                    // The first zero byte ends the string. The host terminates
                    // it, so an unterminated path is a malformed one rather
                    // than a long one -- F_NAME's bounds check rejects it.
                    if (scbyte == 8'h00) begin
                        len_b <= scan_i;
                        q_v   <= 1'b0;      // F_PREF presents its own address
                        fst   <= (scan_i == 9'd0) ? F_BAD : F_PREF;
                    end
                    // 247 is the last byte of window B the array holds.
                    else if (scan_i == 9'd247) begin
                        len_b <= 9'd247;
                        fst   <= F_BAD;
                    end
                    else begin
                        scan_i <= scan_i + 9'd1;
                        q_v    <= 1'b0;
                    end
                end
                else
                    q_v <= !bridge_rd;
            end

            // ---- where the extension starts --------------------------------
            F_DOT: begin
                if (q_v && !bridge_rd) begin
                    // The last '.' before the end of the string, so a
                    // directory with a dot in it cannot be mistaken for the
                    // extension. None at all means the suffix is appended.
                    if (scbyte == 8'h2E) begin          // '.'
                        dot_q <= scan_i;
                        nam_i <= 9'd0;
                        // F_XT writes the word AFTER the dot when the dot is a
                        // word's last byte, so it must present its own address
                        // rather than consume the one this scan just read.
                        q_v   <= 1'b0;
                        // Nine bytes for `save.gtr`, three for `sav`: either
                        // has to stay inside the 248 bytes window B holds, or
                        // the write would wrap onto window A's first word.
                        fst   <= use_b
                                 ? ((scan_i + 9'(SUFFIX_LEN) <= 9'd247) ? F_NAME : F_BAD)
                                 : ((scan_i + 9'd3 <= 9'd247) ? F_XT : F_BAD);
                    end
                    else if (scan_i == 9'd0) begin
                        dot_q <= len_b;
                        nam_i <= 9'd0;
                        q_v   <= 1'b0;
                        // No extension to swap, so the name cannot be mirrored:
                        // the file goes beside the cartridge after all.
                        use_b <= 1'b1;
                        fst   <= (len_b + 9'(SUFFIX_LEN) <= 9'd247) ? F_NAME : F_BAD;
                    end
                    else begin
                        scan_i <= scan_i - 9'd1;
                        q_v    <= 1'b0;
                    end
                end
                else
                    q_v <= !bridge_rd;
            end

            // ---- is the path under /Assets/ -------------------------------
            F_PREF: begin
                // The Saves tree mirrors the Assets tree -- "the directory
                // structure in the Assets and Saves folders should mirror each
                // other" (Directories and SD Folder Structure) -- so the two
                // words that hold `/Ass` and `ets/` decide whether a mirror can
                // be built at all. That is the same rule the OS uses to name a
                // nonvolatile save from slot 0.
                if (q_v && !bridge_rd) begin
                    if ((pf_i == 2'd0 && fs_word != 32'h7373_412F) ||
                        (pf_i == 2'd1 && fs_word != 32'h2F73_7465)) begin
                        // Not /Assets/...: `<rom>save.gtr` beside the cartridge.
                        use_b  <= 1'b1;
                        scan_i <= len_b;
                        pf_i   <= 2'd0;
                        q_v    <= 1'b0;
                        fst    <= F_DOT;
                    end
                    else if (pf_i == 2'd1) begin
                        pf_i <= 2'd0;
                        q_v  <= 1'b0;
                        fst  <= F_DOT;
                    end
                    else begin
                        pf_i <= pf_i + 2'd1;
                        q_v  <= 1'b0;
                    end
                end
                else
                    q_v <= !bridge_rd;
            end

            // ---- write `save.gtr` over the extension ----------------------
            F_NAME: begin
                // The write itself is in the array block, gated on `q_v`: it
                // needs the word this state has just presented.
                if (q_v && !bridge_rd) begin
                    if (nam_i == 9'(SUFFIX_LEN - 1)) begin
                        nam_i <= 9'd0;
                        fst   <= lmode ? F_LOPEN : F_OPEN;
                    end
                    else begin
                        nam_i <= nam_i + 9'd1;
                        q_v   <= 1'b0;
                    end
                end
                else
                    q_v <= !bridge_rd;
            end

            // ---- the mirrored path, into window A ---------------------------
            F_XT: begin
                // `sav` over the cartridge's extension, by the array block
                // above: three bytes for three, so the name keeps its length
                // and its directory.
                if (q_v && !bridge_rd) begin
                    if (nam_i == 9'd2) begin
                        nam_i   <= 9'd0;
                        sh_i    <= 9'd0;
                        sh_acc  <= 32'd0;
                        derived <= 1'b1;
                        // The copy reads its own source bytes from `sh_i == 7`
                        // on, so it must not inherit this state's last word: a
                        // dot in a word's last byte would hand it the wrong
                        // one.
                        q_v     <= 1'b0;
                        fst     <= F_SHIFT;
                    end
                    else begin
                        nam_i <= nam_i + 9'd1;
                        q_v   <= 1'b0;
                    end
                end
                else
                    q_v <= !bridge_rd;
            end

            F_SHIFT: begin
                // Destination byte `sh_i` is `/Saves/` for the first seven and
                // the source's own byte `sh_i + 1` after that: dropping the
                // prefix's 't' is the whole shift. A destination word is
                // written as soon as its fourth byte is known, and the last
                // one -- the NUL -- always is, so no tail is left behind.
                if (sh_rdy) begin
                    if (sh_last) begin
                        sh_acc <= 32'd0;
                        sh_i   <= 9'd0;
                        q_v    <= 1'b0;
                        fst    <= lmode ? F_LOPEN : F_OPEN;
                    end
                    else begin
                        sh_acc <= (sh_i[1:0] == 2'd3) ? 32'd0 : sh_word;
                        sh_i   <= sh_i + 9'd1;
                        q_v    <= 1'b0;
                    end
                end
                else
                    q_v <= !bridge_rd;
            end

            // ---- open (create/resize) the file beside the ROM --------------
            F_OPEN: begin
                // open_dataslot_file_t: path at +0x000 (already here), flags at
                // +0x100, desired size at +0x104. Bit 0 creates the file if it
                // does not exist, bit 1 resizes it -- both are required, and a
                // read-only slot would refuse (it is not: data.json's Save slot
                // carries no read-only bit).
                brd_w          <= 8'h00;
                t_param_struct <= use_b ? B_BASE : STRUCT_BASE;
                t_id           <= SAVE_SLOT_ID;
                t_openfile     <= 1'b1;
                fst            <= F_OPENLOW;
            end

            F_OPENLOW: begin
                if (!t_done)     fst <= F_OPENHIGH;
                else if (to_exp) fst <= F_BAD;
            end

            F_OPENHIGH: begin
                if (t_done) begin
                    // 0 = opened, 1 = created and opened (documented as success)
                    if (t_err <= 3'd1) begin
                        /* ... and a file this call CREATED holds nothing that is
                         * not about to be written. Anything less than the whole
                         * image over it leaves zeros where the cartridge has
                         * code, so a created file always gets a full write.
                         *
                         * THE STREAM HAS TO BE ARMED AT ZERO WITH IT
                         * (2026-11-08). `base` is a register: the arm below used
                         * its OLD value -- the span's offset -- while `dlen`
                         * became the whole image, so the file would have received
                         * the image's bytes from `base` onwards written at offset
                         * 0: the whole thing shifted, and a cartridge's code left
                         * as zeros. It only ever bit a save that CREATED its file
                         * (a first save on a cartridge whose .sav was gone), and
                         * that path had never run on the panel.
                         *
                         * A created file also means the file is not the image, so
                         * the attempt is a full one for `full_att`/`resync`, and
                         * whatever range was owed is moot. */
                        if (t_err == 3'd1) begin
                            base      <= 22'd0;
                            dlen      <= len_q[21:0];
                            full_att  <= 1'b1;
                            pend_any  <= 1'b0;
                            slot_start <= 22'd0;
                        end
                        else
                            // The slot counts 64-bit ENTRIES, this module counts
                            // bytes: hand it the span's first word, not its offset.
                            slot_start <= {3'b000, base[21:3]};
                        slot_arm   <= 1'b1;
                        need_low <= 1'b1;
                        sent     <= 32'd0;
                        fst      <= F_CHUNK;
                    end
                    else if (derived) begin
                        // The mirrored Saves path would not open (no such
                        // folder, a card that refuses the write): the file goes
                        // beside the cartridge instead. Window B still holds
                        // the untouched ROM path, so the name is built again.
                        use_b   <= 1'b1;
                        derived <= 1'b0;
                        scan_i  <= len_b;
                        fst     <= F_DOT;
                    end
                    else
                        fst <= F_BAD;
                end
                else if (to_exp) begin
                    if (derived) begin
                        use_b   <= 1'b1;
                        derived <= 1'b0;
                        scan_i  <= len_b;
                        fst     <= F_DOT;
                    end
                    else
                        fst <= F_BAD;
                end
            end

            // ---- the chunks -------------------------------------------------
            F_CHUNK: begin
                if (sent >= {10'd0, dlen}) begin
                    fst <= F_FLUSH;
                end
                else begin
                    chunk       <= chunk_n;
                    slot_thresh <= thr_n;
                    fst         <= F_WAITFULL;
                end
            end

            F_WAITFULL: begin
                // The flush that re-armed the stream has to have reached the
                // write side before its count means anything (see `need_low`).
                if (need_low) begin
                    if (!slot_full)  need_low <= 1'b0;
                    else if (to_exp) fst <= F_BAD;
                end
                // `slot_thresh` is a static level for the whole wait and the
                // FIFO only ever fills towards it -- there is nothing to race.
                else if (slot_full)   fst <= F_WR;
                else if (to_exp)      fst <= F_BAD;
            end

            F_WR: begin
                t_write      <= 1'b1;
                t_id         <= SAVE_SLOT_ID;
                t_slotoffset <= {10'd0, base} + sent;
                t_bridgeaddr <= IMG_WINDOW + {10'd0, base} + sent;
                t_length     <= chunk;
                fst          <= F_WRLOW;
            end

            // `done` is a LEVEL that stays up until the next command starts, so
            // a wait has to see it fall before it can believe it rose again.
            F_WRLOW: begin
                if (!t_done)     fst <= F_WRHIGH;
                else if (to_exp) fst <= F_BAD;
            end

            F_WRHIGH: begin
                if (t_done) begin
                    if (t_err == 3'd0) begin
                        sent <= sent + chunk;
                        fst  <= F_CHUNK;
                    end
                    else
                        fst <= F_BAD;          // the file is open; nothing to retry
                end
                else if (to_exp) fst <= F_BAD;
            end

            // ---- done ------------------------------------------------------
            F_FLUSH: begin
                // A save that covered the image has made the file the image.
                if ((base == 22'd0) && (dlen == len_q[21:0])) begin
                    synced <= 1'b1;
                    resync <= 1'b0;         // every byte written: trustworthy
                end
                // Every byte this attempt set out to write is on the card.
                pend_any <= 1'b0;
                t_flush <= 1'b1;
                t_id    <= SAVE_SLOT_ID;
                fst     <= F_FLUSHLOW;
            end

            F_FLUSHLOW: begin
                if (!t_done)     fst <= F_FLUSHIGH;
                else if (to_exp) fst <= F_GOOD;
            end

            F_FLUSHIGH: begin
                // The flush result is not acted on: the bytes are already in
                // the host's file layer, and a flush whose result this core
                // cannot see is not a reason to rewrite the whole image.
                // Nothing follows it: the slot is not nonvolatile, so the OS
                // has no read-out to redirect at quit (see the header).
                if (t_done || to_exp) fst <= F_GOOD;
            end

            F_GOOD: begin
                if (lmode)
                    fst <= F_LDONE;     // the restore is done, release the console
                else begin
                    done <= 1'b1;
                    fst  <= F_IDLE;
                end
            end

            F_BAD: begin
                // A failure in the restore is not a save that is owed: the
                // console boots on the image it was given, and the next $90
                // still writes the file.
                if (lmode) begin
                    lmode <= 1'b0;
                    fst   <= F_IDLE;
                end
                else begin
                    // Keep `dirty` set so the next trigger (or the menu) tries
                    // again: a failed save must never look like a finished one.
                    //
                    // ONLY A FAILED FULL WRITE POISONS THE FILE (2026-11-08).
                    // `resync` makes the next save write all 2 MB, which is the
                    // correct recovery when an attempt that was writing the
                    // whole image broke -- and the wrong, ruinously expensive
                    // one when a span broke, because a span leaves every byte
                    // outside it exactly as it was. A broken span retries its
                    // own range (`pend_*`), whatever its size, so a hiccup costs
                    // the bytes that did not make it, not the whole image.
                    dirty  <= 1'b1;
                    failed <= 1'b1;
                    if (full_att)
                        resync <= 1'b1;
                    fst    <= F_IDLE;
                end
            end

            default: fst <= F_IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
