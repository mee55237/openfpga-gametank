//============================================================================
//  gt_save_slot -- the Pocket save slot's read side.
//
//  WHAT A GAMETANK SAVE IS. A flash GameTank cartridge has no save RAM: a game
//  stores its save in the cartridge's own flash, and the emulator (the
//  compatibility floor) persists a diff of the cart image next to the ROM. So
//  on that cart the save file IS the cartridge image, and the OS reads it back
//  out of the 0x0200_0000 window at shutdown ([0080]) and writes it back in at
//  boot ([0082]). (A Flash2M_RAM32K cart saves to its 32 KB SRAM instead; that
//  is rtl/gt_nvram.sv, and rtl/core_top.v routes the same window there.)
//
//  THE WINDOW IS ADDRESSED, NOT SEQUENCED (2026-11-02). This is the one design
//  rule the file exists to state, because the previous version broke it and the
//  card shows exactly what that costs.
//
//  The image lives in PSRAM and has to be streamed ahead: a PSRAM beat is ~80
//  clk_core and the bridge wants a word every ~88 clk_74a, so the bytes are
//  fetched in 16-beat bursts into an 8 KB buffer (eight bursts) and a bridge
//  read is answered from it -- and `[0080]` is not acknowledged until that
//  buffer is FULL (see the ack, below), so a save-out of the whole image never
//  depends on the stream keeping up with the host. The buffer is INDEXED BY
//  THE IMAGE WORD NUMBER -- image word W lives at `imgbuf[W % WIN]` for as
//  long as it is resident -- so the answer to
//  a read is a function of its ADDRESS and nothing else. A word that is late,
//  a word that is repeated, a read that arrives before the stream has started,
//  a read that arrives while the window is being re-armed: all of them answer
//  zero or the right word, and none of them can move the file.
//
//  That is the bug this replaced. The old window was an ordered FIFO with a
//  `head_idx` that advanced on a read pulse, so "which word is this" was decided
//  by how many reads had happened rather than by the address. One read the core
//  did not expect consumed a word, every answer after it came from the word
//  before, and the file that reached the card was the cartridge SHIFTED BY FOUR
//  BYTES -- 100.00% of `Minicraft.sav` equals `image[i+4]`, measured). It then
//  got restored over the cartridge at the next boot and saved again, so the
//  shift compounded: +4, then +8. "The save loads but it is partly corrupted"
//  and "I have to load the cart twice" are the same four bytes.
//
//  THE ACK IS WHAT MAKES THE READ RATE IRRELEVANT (2026-11-06). `[0080]` blocks
//  the OS until this module answers, and the OS starts reading the moment it is
//  answered -- so the ack waits until the WINDOW IS FULL, not until word 0 is
//  there. That is not politeness, it is the property the .sav needs: an 8 KB
//  image is 1,024 words and the window is 1,024 words, so by the time the host
//  reads byte 0 the entire save is resident and how fast PSRAM produces the
//  next word no longer matters. It does matter for a window that is acked at
//  sixteen words: `Cubicle Knight.sav` from the 2026-11-05 build was 25%
//  correct -- one burst of sixteen good words, three bursts of zero, repeating
//  -- because the host consumed faster than a 2 KB window could be refilled
//  between bursts. Every run in sim was green anyway, because
//  tmp/gfx/sim/gt/psram_model.h answers with no wait states.
//
//  The wait is capped so a dead PSRAM answers instead of hanging the menu; the
//  cap is a stopped-stream escape, well past a legitimate fill, and
//  rtl/core_bridge_cmd.v's command watchdog is the outer bound on it.
//
//  FLUSH. A new request restarts the image at word 0. The toggle crosses three
//  flops and the read side ignores the window for 48 clocks afterwards, so a
//  read that lands while the two pointers are still being reset cannot see the
//  previous session's words.
//============================================================================

`default_nettype none

module gt_save_slot #(
    // The cartridge image: 2 MB at PSRAM byte 0x100000 (rtl/cart.sv's
    // CART_BASE). The save file is this region, whole.
    parameter logic [21:0] IMG_BASE  = 22'h100000,
    parameter int          IMG_BYTES = 2097152
) (
    // ---- the APF side, in clk_74a ----------------------------------------
    input  logic        clk_74a,
    input  logic        reset_74a,

    input  logic        req,            // a read request for this slot (pulse)
    input  logic        allcomplete,    // the OS is done with the slot
    /* THE SHUTDOWN STARTS THE STREAM BEFORE ANYONE ASKS FOR IT (2026-11-03).
     *
     * `[0010 Reset Enter]` is the OS's first goodbye, and the save read-out
     * (`[0080]`) comes after it. Until now the image only started moving when
     * `[0080]` arrived, so the ack below had to wait for its sixteen-word head
     * start with the OS blocked in the command -- the one place this core can
     * make the Pocket's shutdown wait on it, and the only difference between
     * this core's `[0080]` and every other core's (they tie the ack to 1).
     *
     * So the stream is armed here instead, at the moment the host says it is
     * going down: by the time `[0080]` is asked, word 0 and the 2 KB behind it
     * are already resident, the request is answered on its first poll, and the
     * content is the same stream in the same order. A request that arrives with
     * this high and the window already positioned at zero is the SAME read-out
     * and does not re-arm (see the arm condition below) -- re-arming there would
     * throw the head start away and hand the OS an empty window. */
    input  logic        pre_arm,        // the host has begun to shut us down

    /* THE CORE'S OWN WRITER ARMS THE SAME STREAM (2026-11-07).
     *
     * rtl/gt_save_file.sv writes the image out with the host's [0184, which
     * makes the HOST read this window -- so it needs exactly what `pre_arm`
     * does (flush, start again at image word 0) and exactly what `pre_arm`
     * cannot give it: a second arm while `pre_arm` is already high, which is a
     * save that lands during the shutdown window. Sharing one input would
     * swallow that rising edge, and the writer would then read a window that
     * was never reset -- a wrong .sav rather than a failed one. */
    input  logic        file_arm,       // the core's writer: arm, no ack
    /* WHERE THE WRITER'S DATA STARTS (2026-11-08).
     *
     * A save only rewrites what the game changed, and what it changed is a span
     * somewhere in the image -- on a 2 MB cartridge the last sectors. The stream
     * used to be nailed to image word 0 (`file_arm` is a restart at zero), so
     * asking for bytes at 0x1D0000 meant streaming 1.8 MB the host never reads.
     * The write itself would still have been the same size, and the wait for it
     * is the save time. So the arm takes the word to start at, and the fill
     * begins there: `[rbin, wbin)` is the span the writer needs, nothing before
     * it is ever fetched.
     *
     * It is a quasi-static word in the writer's own clock, sampled on the arm
     * edge (the same edge that toggles the flush): the value is set a state
     * before the toggle and does not move until the next save. Word 0 is the
     * OS's read-out, and `pre_arm`/`req` keep it -- only `file_arm` uses this. */
    input  logic [21:0] file_start,     // image word the writer's span begins at

    /* A SAVE FILE THAT IS NOT THE WHOLE IMAGE (2026-11-09).
     *
     * A flash cartridge's save only ever differs from the .gtr from some low
     * byte upwards, so the file is [the cartridge's own first 128 bytes][the
     * image from `tail_word` to its end]. The head is there because the host
     * validates a restore against the cartridge's first eight words before it
     * lets a single byte through (rtl/core_top.v's SV_HEAD); without it a
     * shorter file would be refused as "not this cartridge's save".
     *
     * So the window is not the image, it is the file: word 0 is the image's own
     * word 0, the first HEAD_W words are the cartridge's head, and the word
     * after them is image word `tail_word`. `tail_en` low is the shape every
     * build before this one had -- the window is the image, word for word.
     *
     * THE HEAD IS ONE WHOLE BURST (2026-11-09). A burst is sixteen 8-byte
     * entries fetched CONSECUTIVELY from the image, so a boundary that fell
     * inside one would leave the rest of that burst holding the image where the
     * file wanted the tail: with a four-entry head the first 96 bytes of every
     * tail file were the cartridge's own bytes 32.. instead of the save. The
     * fix is not a shorter burst, it is a head the same size as one -- 128
     * bytes -- so the first burst is exactly the head and the second begins at
     * the tail. sim/gt/tb_slot.cpp's 4e is that check.
     *
     * The window is still ADDRESSED, not sequenced (see the header): the file
     * position the host names maps to an image word, and the answer is a
     * function of that address alone.
     */
    input  logic        tail_en,        // the file is [head][tail], not the image
    input  logic [21:0] tail_word,      // ... the tail's first image word

    /* NOTHING TO READ OUT IS A LEGAL ANSWER, AND IT IS ZERO WORDS (2026-11-09).
     *
     * The framework's Dataslot ID/Size Table says how big the file is, and
     * Analogue's reference defines the value: "Size of the data slot. Zero if
     * the slot is not used." A flash cartridge that has not written since it
     * was loaded is exactly that -- the file on the card already describes the
     * cartridge -- so the core declares 0 rather than the 128-byte head it
     * used to, and the OS has nothing to write.
     *
     * That makes the stream zero words long, and it must not wait for a window
     * that will never fill: with `empty` the span below is 0 in both clocks, so
     * no burst is issued, the ack fires as soon as the arm settles (48 clocks,)
     * and `hold_console` never takes the CPU. The host asks `[0080]`, is told
     * "ready", reads nothing, and sends `[008F]`. */
    input  logic        empty,          // this slot holds no file at all
    output logic        ack,            // ... accepted, and word 0 is available

    /* THE READ-OUT, AS A LEVEL THE MACHINE CAN BE HELD BY (2026-11-06).
     *
     * `ack` is a pulse and `stream_74a` runs before anyone asks, so neither
     * says "the host is reading the image right now". This does: it rises on the
     * request and falls when the host says `allcomplete`, which is exactly the
     * window in which rtl/core_top.v holds the CPU. Without it the machine kept
     * executing through the transfer and competed for the PSRAM port -- see the
     * note at `save_stream` in rtl/core_top.v for the card measurement. */
    output logic        readout,        // the host is reading the image out

    /* THE CPU ONLY HAS TO BE OFF PSRAM WHILE THE WINDOW IS THIN (2026-11-07).
     *
     * This is an OUTPUT and not the readout itself because the two are not the
     * same question. The readout lasts until the OS has written the file, card
     * flush included; the hold is only needed while the stream has beats to
     * fetch. Measured in sim/gt/tb_core_ss.cpp at the APF's own pace, a 2 MB
     * `.sav` is 649.6 ms of read-out and the console was held for every
     * millisecond of it -- plus every card write the OS does between chunks. A
     * picture that has not moved for a second is what a crash looks like, and
     * none of that hold buys anything once the window is full: the stream is
     * parked (`room` low), issues nothing, and PSRAM is idle.
     *
     * So the hold follows the WINDOW, with hysteresis: taken back below
     * HOLD_AT words resident, released at RUN_AT. Between the two the console
     * runs and the host keeps draining, and the stream refills what that cost
     * before the window is anywhere near empty. The margins are not close --
     * HOLD_AT is 12 KB of a 16 KB window, i.e. 3.7 ms of the host's own reading
     * at the measured 3.23 MB/s, while the 3 KB between the thresholds refills
     * at a 6 MB/s port against a 3.2 MB/s drain. */
    output logic        hold_console,   // keep the machine off the memory port

    // THE WRITER'S ARM IS GONE (2026-11-03). There used to be three ports here
    // -- `dump_arm`/`dump_thresh`/`dump_full` -- for rtl/gt_save_file.sv, which
    // pushed the image out through target command 0x0184 and needed the window
    // positioned at word 0 with nobody waiting on an ack. That module is removed
    // (see rtl/core_top.v): the only reader of this window is the OS's own
    // nonvolatile writeback, and `pre_arm` covers the one case that needed a
    // silent arm.

    input  logic [31:0] bridge_addr,    // 0x0200_0000 + byte offset
    input  logic        bridge_rd,
    output logic [31:0] rd_data,        // held for the whole gap between reads

    // ---- the memory side, in clk_core ------------------------------------
    input  logic        clk_core,
    input  logic        reset_core,

    output logic        mem_rd,
    output logic [21:0] mem_addr,
    output logic [7:0]  mem_burstcnt,
    input  logic [63:0] mem_dout,
    input  logic        mem_dout_ready,
    input  logic        mem_busy,

    /* THE WINDOW'S OCCUPANCY, FOR THE CORE'S OWN FILE WRITER (2026-11-07).
     *
     * rtl/gt_save_file.sv writes the image out itself with the host's [0184,
     * which makes the HOST read this window -- so it has to be asked for a chunk
     * only once that chunk is resident, or it reads zeros. This is the count it
     * paces against; the threshold lives in the writer because only it knows how
     * big the next command is. */
    output logic [21:0] win_words,

    // ---- diagnostics ------------------------------------------------------
    output logic        underrun        // a read the stream had not produced
);

    /* THE WINDOW IS THE IMAGE, WHEN THE IMAGE FITS (2026-11-06).
     *
     * It was 256 entries (2 KB) and it did not work on the card: the file came
     * out one image word in four, byte-identically from two different fits, so
     * it was not my control logic moving -- it was the host emptying a 2 KB
     * window faster than PSRAM could refill it, and the window being the only
     * buffer there is. The ratio is fixed by the host's own pace, so no amount
     * of ack lead fixes it: 2 KB of lead is spent in the first 64 bytes of a
     * 2 MB dump.
     *
     * 2,048 entries is 16 KB, which is THIRTEEN M10K blocks -- six more than
     * the 8 KB window used, out of the nineteen the fit had spare. It is not a
     * round number by accident: of the 40 cartridges on the card, ONE is 8 KB
     * and twenty-three are 16 KB, so an 8 KB window left the common case
     * streamed live past its first half -- which is the only place a hole can
     * still come from. At 16 KB the whole save of every 16 KB cartridge (24 of
     * 40) is resident before the host reads byte 0, and the read rate stops
     * mattering for all of them. The ack waits for the full window (below), so
     * for any image that fits, the host reads a buffer that was complete
     * before it started -- independent of the fill rate, the host's pace, and
     * whether the machine is held. Images larger than the window get 16 KB of
     * lead, which is all a window can do for them. */
    localparam int WIN        = 2048;                // 64-bit entries (16 KB)
    localparam int BURST_LEN  = 16;                  // 8-byte beats per request
    localparam int HIGH_WATER = WIN - BURST_LEN;     // 2032: last safe start
    localparam int IMG_WORDS  = IMG_BYTES / 8;       // 262,144

    /* THE ACK IS "THE WINDOW IS FULL", NOT "ONE BURST IS IN" (2026-11-05).
     *
     * It was BURST_LEN -- sixteen words, 128 bytes -- so the OS was released
     * with 128 bytes of lead and then had to be fed at its own pace for the
     * rest of the image. Measured, the fill runs at 24.3 clk_core per 8-byte
     * beat (9.4 MB/s, sim/gt/tb_slot.cpp's `fill` line), and the host takes a
     * 4-byte word every ~80 clk_74a (3.7 MB/s), so the margin once the console
     * is held is 2.5x -- but a margin is only a margin if it is ALLOWED to
     * accumulate. Starting with 128 bytes spent it immediately. Starting with
     * the whole 1,920-byte window, the stream has already banked five times the
     * host's per-word jitter before the first read lands, and `room` keeps it
     * there for the rest of the dump.
     *
     * The wait is 120 beats ~= 1.1 ms, inside the 65,535-clock cap below and
     * inside the OS's patience for `[0080]` (every other core answers it at
     * once because they have nothing to wait for). */
    /* ... AND THE WATCHDOG IS LONGER THAN THE FILL (2026-11-06). The deadline
     * was 65,535 clk_74a -- 0.88 ms -- which was fine for 240 words and is not
     * for 1,008: the card's own file says the ack gave up at about 60 words, so
     * the fill there is nearer a megabyte a second than the ten the model
     * predicts, and 8 KB takes several milliseconds. This is the escape hatch
     * for a PSRAM that is not answering at all, not a race against it. */
    localparam int ACK_WORDS  = HIGH_WATER;
    /* THE DEADLINE IS A DEAD-PSRAM ESCAPE, NOT A PACE (`1 in 4 words` on the
     * card, 2026-11-06). At ~13 ms it was 2.6x the SIMULATED fill of one
     * window -- and the simulation is the fast case, because
     * tmp/gfx/sim/gt/psram_model.h answers with no wait states while the part
     * inserts them. A deadline that fires in the middle of a legitimate fill
     * is worse than no deadline at all: it acks a half-full window, the host
     * reads past it, and the .sav comes out with holes -- exactly the file the
     * card had. Four seconds-worth of clocks is only reached by a stream that
     * has stopped, and rtl/core_bridge_cmd.v's own command watchdog is the
     * outer bound on that. */
    localparam logic [23:0] ACK_DEADLINE = 24'd4_000_000;   // ~54 ms at 74.25 MHz

    // ======================================================================
    //  The image window. Written in clk_core, read in clk_74a, addressed by
    //  the image word number's low bits on both sides -- that shared mapping
    //  is what makes the window an array of the image rather than a queue.
    // ======================================================================
    (* ramstyle = "M10K, no_rw_check" *) logic [63:0] imgbuf [0:WIN-1];

    // The registered read is what lets this infer as block RAM; its address is
    // the SERVED word (`srv_word`, below), which is fixed from the strobe that
    // latched it until the next one, so the one clock of latency is invisible
    // to the host -- it collects the word four clocks after the address is
    // latched (see the timing note at `srv_word`).
    logic [63:0] win_q;
    logic        q_high = 1'b0;
    logic        q_hit  = 1'b0;

    // ======================================================================
    //  The flush: one toggle, a pulse in each domain
    // ======================================================================
    logic        flush_tog = 1'b0;
    logic [2:0]  flush_s74 = 3'd0;
    logic [2:0]  flush_s   = 3'd0;

    always_ff @(posedge clk_74a)
        flush_s74 <= {flush_s74[1:0], flush_tog};

`ifdef GT_SIM
    // The pulse in each domain. `flush_74a` is also a probe: sim/gt/tb_slot.cpp
    // counts how many times the window was re-armed during a read-out.
    wire flush_74a = flush_s74[2] ^ flush_s74[1];
`endif

    always_ff @(posedge clk_core)
        flush_s <= {flush_s[1:0], flush_s74[2]};

    wire flush_core = flush_s[2] ^ flush_s[1];

    // ======================================================================
    //  The read side, in clk_74a
    // ======================================================================
    logic        active     = 1'b0;
    logic        start_pend = 1'b0;      // a request the ack still has to answer
    logic        stream_74a = 1'b0;      // ... and the command to go and fetch
    logic [5:0]  arm_hold   = 6'd0;      // window settling after a flush
    logic [23:0] ack_wd     = 24'd0;     // the ack's escape hatch
    logic        req_q      = 1'b0;
    logic        arm_q      = 1'b0;      // pre_arm's edge, so the flush is one shot
    logic        farm_q     = 1'b0;      // ... and the writer's, on its own input



    /* `wbin` is the write side's pointer, owned by clk_core and declared up
     * here only so the read side's view of it can be written beside its own.
     *
     * IT CROSSES AS GRAY (2026-11-02). A 22-bit binary counter does not change
     * one bit at a time (255 -> 256 flips nine), so a two-flop synchroniser can
     * catch a value that never existed -- and on this side that value decides
     * `resident`, i.e. whether the host is told the word it asked for is here.
     * Measured: a torn sample made one host read look like an underrun with the
     * data still correct, which is exactly the shape of "sometimes it works".
     * Gray gives the reader the old value or the new one, never a third. */
    logic [21:0] wbin       = 22'd0;     // next image word to fetch
    logic [21:0] wgray      = 22'd0;     // ... gray-coded, for the read side
    logic [21:0] rbin       = 22'd0;     // oldest resident image word

    always_ff @(posedge clk_core)
        wgray <= (wbin >> 1) ^ wbin;

    logic [21:0] wgray_s1   = 22'd0;
    logic [21:0] wgray_s2   = 22'd0;

    always_ff @(posedge clk_74a)
        wgray_s1 <= wgray;

    always_ff @(posedge clk_74a)
        wgray_s2 <= wgray_s1;

    // Gray back to binary: a running XOR from the top bit down. Inside a
    // function the accumulator is a private variable, which is what keeps this
    // out of the "always_comb reads what it drives" lint warning the same
    // expression trips when it is written inline.
    function automatic logic [21:0] gray2bin(input logic [21:0] g);
        logic [21:0] b;
        b[21] = g[21];
        for (int i = 20; i >= 0; i--)
            b[i] = b[i+1] ^ g[i];
        return b;
    endfunction

    logic [21:0] wbin_s = 22'd0;

    always_comb
        wbin_s = gray2bin(wgray_s2);

    wire         req_ev  = req & ~req_q;
    wire         pre_ev  = pre_arm & ~arm_q;
    wire         file_ev = file_arm & ~farm_q;

    /* ... AND A REQUEST THAT ARRIVES AFTER THE PRE-ARM IS ANSWERED, NOT RESTARTED.
     * `already_armed` is "the stream is already sitting at image word 0 with
     * something in the window", which is exactly what `pre_ev` leaves behind. */
    wire         already_armed = active && (rbin == 22'd0) && (wbin_s != 22'd0);
    wire         rearm_now     = req_ev && !start_pend &&
                                 !(pre_arm && already_armed);

    /* THE WORD THE HOST TAKES IS THE ONE ITS PREVIOUS TRANSACTION NAMED
     * (2026-11-06 -- and it is what the card has been saying all along).
     *
     * rtl/io_bridge_peripheral.v latches `pmp_addr` in ST_ADDR_0, counts four
     * clocks in ST_READ_0 and takes `pmp_rd_data_e` there; `pmp_rd` rises one
     * clock LATER, in ST_READ_1. So the strobe means "I have this word, advance
     * to the next", and the framework's own reference reader uses it that way:
     * refs/agg23-pocket-utils/ip/data_unloader.sv learns the address on
     * `bridge_rd`'s rising edge -- one clock after the word was taken -- and
     * fetches that word for the NEXT transaction. A reader built that way can
     * only ever present the PREVIOUS address's data. That is the contract, and
     * the host primes the pipe with one read it throws away.
     *
     * Answering from the live `bridge_addr` was therefore one word AHEAD. The
     * .sav says so twice over: ALL 8,188 comparable bytes of `Cubicle Knight.sav`
     * are the cartridge at +4 (not most -- every one), and its LAST word is
     * 0x55555555, where the cartridge has 0x0000E1FC: that is the answer to
     * 0x02002000, PSRAM past the end of an 8 KB cartridge. A host that only read
     * the 2,048 words it wants could produce neither; one that reads the address
     * after the last word it wants produces both, because that read is the one
     * that lands past the image. (An earlier note here argued the address was stable at
     * the sample and live addressing was right. It is stable -- that was never
     * the question. The question is which address the host WANTS, and it is the
     * previous one, because `data_unloader` cannot be off by one.)
     *
     * `srv_word`/`srv_high` are that address: latched at the strobe and served
     * to the next transaction, cleared when a session is armed so the host's
     * priming read is image word 0.
     *
     * `rd_stb` is the rising edge of the read pulse, and it is what the
     * RETENTION pointer below must follow -- see `advance`. */
    logic        rd_stb_q = 1'b0;
    wire         rd_stb   = bridge_rd & ~rd_stb_q;

    always_ff @(posedge clk_74a)
        rd_stb_q <= bridge_rd;

    wire [21:0] rd_word = bridge_addr[24:3];     // the word the NEXT access names
    wire        rd_high = bridge_addr[2];
    wire        addr2   = (bridge_addr[31:24] == 8'h02);

    logic [21:0] srv_word = 22'd0;               // ... and the one this access takes
    logic        srv_high = 1'b0;

    /* RESIDENT IS A RANGE, AND THAT IS ALL IT IS. `[rbin, wbin)` is what the
     * stream has produced: every one of those words is at `imgbuf[W % WIN]`,
     * because both sides count the image from zero and never reorder it.
     * `arm_hold` keeps the range meaningless for the 48 clocks it takes the
     * two pointers to reset across the crossing. */
    wire resident = (rd_word >= rbin) && (rd_word < wbin_s);
    wire rd_hit   = addr2 && active && resident && (arm_hold == 6'd0);

    /* A BASE THAT IS NOT ZERO MAKES THE DIFFERENCE ABLE TO WRAP (2026-11-08).
     * The stream now starts at the span's first word, so for the couple of
     * clocks the gray-coded `wbin` takes to arrive, `wbin_s` is still BEHIND
     * `rbin` -- and a subtraction there is 4 M words, not zero. That number is
     * what the writer paces against (`win_words`), so it would fire the first
     * chunk before a byte was fetched and the host would read zeros. Clamped,
     * the same window is simply empty, which is what it is. */
    wire [21:0] resident_words = (wbin_s >= rbin) ? (wbin_s - rbin) : 22'd0;

    assign win_words = resident_words;

    wire srv_res = (srv_word >= rbin) && (srv_word < wbin_s);
    wire srv_hit = addr2 && active && srv_res && (arm_hold == 6'd0);

    // Reads answer from the SERVED word one clock after its address, and the
    // qualifiers ride with them so a word and its `hit` always belong together.
    // It lives in the main FSM's `else` branch below, not in a block of its own:
    // `srv_word` is also cleared by the reset and by the arm, and two always
    // blocks driving one variable is a Quartus error (10028) even though the
    // simulator accepts it.

    assign rd_data = q_hit ? (q_high ? win_q[63:32] : win_q[31:0]) : 32'h0;

    /* RETAINING THE WINDOW. `rbin` only moves forward, and only to keep eight
     * words behind the host -- so the stream has almost the whole window
     * (248 entries) to fill ahead of it.
     *
     * IT WAS 191 BEHIND, AND THAT WAS THE WHOLE BUFFER (2026-11-02). Keeping
     * 192 entries behind the host leaves only 64 for the fill, and the fill is
     * the slow side: a chunk of a save is 1,920 bytes read at the bridge's
     * pace while PSRAM produces ~2.5 MB/s, so 64 entries is thirty words of
     * margin instead of two hundred. Measured in sim/gt/tb_save_file.cpp: the
     * window ran dry 40 words into the second chunk. Eight is enough that the
     * word just taken is still there (a repeat read answers from it) and small
     * enough that it costs nothing.
     *
     * A read that jumps backwards past that, or forwards out of range, answers
     * zero; the OS reads 2 MB from word 0 to the end and never does either. */
    wire advance = rd_stb && rd_hit && (rd_word >= rbin + 22'd8);

    /* Where this session's file ends, in the host's own clock: the head's words
     * plus the tail. `tail_en`/`tail_word` are arm-time values, so this is too. */
    localparam int HEAD_W = 16;         // 128 bytes: the cartridge's first burst
    wire [21:0] span_words_74 = empty ? 22'd0
                              : tail_en
                              ? (22'(HEAD_W) + 22'(IMG_WORDS) - tail_word)
                              : 22'(IMG_WORDS);

    always_ff @(posedge clk_74a) begin
        if (reset_74a) begin
            active     <= 1'b0;
            start_pend <= 1'b0;
            stream_74a <= 1'b0;
            arm_hold   <= 6'd0;
            ack        <= 1'b0;
            ack_wd     <= 24'd0;
            req_q      <= 1'b0;
            arm_q      <= 1'b0;
            rbin       <= 22'd0;
            srv_word   <= 22'd0;
            srv_high   <= 1'b0;
            underrun   <= 1'b0;
            readout    <= 1'b0;
        end else begin
            ack    <= 1'b0;
            req_q  <= req;
            arm_q  <= pre_arm;
            farm_q <= file_arm;

            /* THE READOUT, in the arm's own block so one always_ff owns
             * `srv_word`: the strobe latches the address the host sent, and the
             * RAM port answers from it for the rest of the transaction (the
             * arm below overrides both on the same clock, which is what makes
             * the host's priming read image word 0). */
            if (rd_stb) begin
                srv_word <= rd_word;
                srv_high <= rd_high;
            end
            win_q  <= imgbuf[srv_word[10:0]];
            q_high <= srv_high;
            q_hit  <= srv_hit;

            if (req_ev) readout <= 1'b1;

            if (ack_wd != 24'd0)   ack_wd   <= ack_wd - 24'd1;
            if (arm_hold != 6'd0)  arm_hold <= arm_hold - 6'd1;

            /* A SECOND REQUEST WHILE THE FIRST IS UNANSWERED IS THE SAME
             * REQUEST, NOT A NEW ONE (2026-11-02). `[0080]` blocks in the OS,
             * but the request level is re-raised whenever a host command starts
             * and it is cleared between commands, so a framework that asks
             * twice is asking twice about ONE read-out. Re-arming on the second
             * restarts the fill from word 0 -- and a host that asks faster than
             * a burst lands re-arms forever and is never answered at all.
             * Measured in sim/gt/tb_core_ss.cpp: 2,000 retries, no ack. */
            /* NOTHING DISARMS THIS STREAM ON SILENCE (2026-11-02, MEASURED).
             *
             * A `2^20`-clock "the host has stopped reading" timer was tried
             * twice and is wrong both times. The APF does not stream 2 MB: it
             * reads a chunk, writes it to the card, and comes back -- and a card
             * write is LONGER than 14 ms. So the timer fires in the middle of
             * a flush, the stream parks, and every read after it answers zero.
             * The card says exactly that: a 2 MB `.sav` with the cartridge's
             * first ~1 KB repeated two thousand times, once per chunk.
             * sim/gt/tb_slot.cpp reproduces it by pausing 2^20 clocks at byte
             * 0x800 and is green only while the timer is absent.
             *
             * The stream is bounded without a timer anyway: `wbin` stops at
             * IMG_WORDS, so it ends at the last word of the image by itself, and
             * a new `[0080]` re-arms it from word 0 because the arm is the
             * request. */
            if (rearm_now || pre_ev || file_ev) begin
                flush_tog  <= ~flush_tog;
                active     <= 1'b1;
                // The OS's read-out always starts at word 0; the core's writer
                // starts wherever the bytes it has to write begin.
                rbin       <= file_ev ? file_start : 22'd0;
                srv_word   <= file_ev ? file_start : 22'd0;
                srv_high   <= 1'b0;
                stream_74a <= 1'b0;
                arm_hold   <= 6'd48;
                underrun   <= 1'b0;

                /* AND ONLY THE OS'S REQUEST HAS AN ACK TO ANSWER. A dump that
                 * arrives while one is outstanding must not take the deadline
                 * away with it: `ack_wd` zeroed under a pending `[0080]` is a
                 * command the framework waits on forever. */
                if (rearm_now) begin
                    start_pend <= 1'b1;
                    ack_wd     <= ACK_DEADLINE;
                end
            end else begin
                /* THE PRE-ARMED REQUEST: no flush, only the ack it is owed. */
                if (req_ev && !start_pend) begin
                    start_pend <= 1'b1;
                    ack_wd     <= ACK_DEADLINE;
                end

                if (arm_hold == 6'd1)
                    stream_74a <= 1'b1;         // the flush has settled: go
                /* `[008F]` ENDS THE STREAM, NOT A PENDING HANDSHAKE (2026-11-02).
                 * It was clearing `start_pend`, and the launch sequence sends
                 * `[008F]` immediately after its slot loads -- so a host that
                 * asks for the save once and blocks in `[0080]` could have its
                 * answer thrown away by the previous transfer's ending, and
                 * then ask again, and be thrown away again. Measured in
                 * sim/gt/tb_core_ss.cpp: `[0080]` stuck at `resp 42550080` for
                 * two thousand retries. The ack is the answer to a command the
                 * OS is waiting on; nothing but that command's own completion
                 * may drop it. */
                if (allcomplete) begin
                    active     <= 1'b0;
                    stream_74a <= 1'b0;
                    readout    <= 1'b0;
                end
            end

            if (advance)
                rbin <= rd_word - 22'd7;

            /* READY MEANS WORD 0 IS IN THE WINDOW. The OS stops waiting on this
             * and starts reading, so an empty window here is a zero header and
             * two more zero words before the stream catches up. The cap is the
             * escape hatch for a PSRAM that is not answering. */
            /* ... AND A CART SMALLER THAN THE WINDOW IS ANSWERED WHEN IT ENDS
             * (2026-11-06). `ACK_WORDS` is "a full window of lead", which an
             * 8 KB image reaches before its last word. A 4 KB image never
             * does: its whole content is 512 words, the stream stops at
             * IMG_WORDS, and the only thing left to fire the ack would be the
             * deadline -- 13 ms of the OS waiting on every single save-out.
             * `wbin` ending AT the image is the same statement the window
             * count makes, for an image that fits. */
            /* `empty` IS ITS OWN ANSWER (2026-11-09). The ack and the hold are
             * both keyed on the window reaching `span_words_74`, and the window
             * starts at `file_start` -- the core writer's span base, which is
             * NOT reset by a cartridge reload. A slot that holds nothing has no
             * window to wait for at all, so it short-circuits both: nothing to
             * fetch, nothing to hold the console for, one clock to answer. */
            if (start_pend && (arm_hold == 6'd0) &&
                (empty ||
                 (resident_words >= 22'(ACK_WORDS)) ||
                 (wbin_s == span_words_74) ||
                 (ack_wd == 24'd1))) begin
                ack        <= 1'b1;
                start_pend <= 1'b0;
            end

            /* AN UNDERRUN IS THE STREAM BEHIND THE HOST, not a read of an
             * address this window does not hold. Both are answered zero; only
             * the first means the fill is too slow, and only the first is worth
             * failing a harness over.
             *
             * IT IS A READ, NOT AN ADDRESS (`bridge_rd`). `bridge_addr` stands
             * where the last access left it, so a test without the strobe calls
             * every idle clock an underrun the moment the window becomes live --
             * measured: the flag rose at byte 0 of a sweep that had not started
             * yet. */
            if (bridge_rd && addr2 && !srv_hit && active && (arm_hold == 6'd0) &&
                (resident_words != 22'd0) && (srv_word > rbin) &&
                (srv_word < rbin + 22'(WIN)))
                underrun <= 1'b1;
        end
    end

    /* ---- the console's hold, decided in the host's own clock -------------
     *
     * `resident_words` is the 74.25 MHz side's view of the window, which is the
     * side that knows what the host has taken. Held by default (`active` low or
     * a flush still settling), released only when there is nothing left to
     * fetch or the window is nearly full again -- never on a level that could
     * oscillate every clock, which is what the two thresholds are for. */
    localparam int HOLD_AT = 1536;      // words resident: take the CPU back
    localparam int RUN_AT  = 1920;      // words resident: let it run

    always_ff @(posedge clk_74a) begin
        if (reset_74a || !active)
            hold_console <= 1'b1;
        else if (arm_hold != 6'd0)
            hold_console <= 1'b1;       // the window is still settling
        else if (empty || (wbin_s == span_words_74))
            hold_console <= 1'b0;       // nothing to fetch, or all of it is here
        else if (resident_words <= 22'(HOLD_AT))
            hold_console <= 1'b1;
        else if (resident_words >= 22'(RUN_AT))
            hold_console <= 1'b0;
    end

    /* A SESSION SURVIVES THE HOST'S SILENCE (`[0080]` ends it, and a new arm
     * replaces it). A stream nobody is reading costs nothing: `room` below parks
     * it once the window is full, so it is idle, not busy. */

    // ======================================================================
    //  The stream: 16-beat bursts out of the image
    // ======================================================================
    logic [21:0] rbin_s = 22'd0;         // the read base, synchronised

    // The base crosses as gray for the same reason as `wbin`, in the other
    // direction. `rbin` only ever grows, so a stale sample is the SMALLER one --
    // the stream then believes it has less room than it does, which costs a
    // wait. The dangerous direction is a sample that looks bigger than the
    // truth: `room` would then start a burst with no space behind it and the
    // buffer would drop beats, which is an eight-byte hole in the image.
    logic [21:0] rgray   = 22'd0;

    always_ff @(posedge clk_74a)
        rgray <= (rbin >> 1) ^ rbin;

    logic [21:0] rgray_s1 = 22'd0;
    logic [21:0] rgray_s2 = 22'd0;

    always_ff @(posedge clk_core) begin
        if (flush_core) begin
            // Seed the read base with the span's start, not zero: `room` is
            // `wbin - rbin_s`, so a zeroed base against a `wbin` that begins at
            // 0x3A000 would look like 232 KB of used window and the fill would
            // never issue a burst.
            rgray_s1 <= (file_start >> 1) ^ file_start;
            rgray_s2 <= (file_start >> 1) ^ file_start;
        end else begin
            rgray_s1 <= rgray;
            rgray_s2 <= rgray_s1;
        end
    end

    // The window is full when the write pointer has caught up with the base.
    // `rbin_s` lags, so the test is conservative -- which is the direction
    // that matters: an extra wait is invisible, an overrun drops a beat and
    // leaves an eight-byte hole in the image.
    always_comb
        rbin_s = gray2bin(rgray_s2);

    wire [21:0] used = wbin - rbin_s;
    wire        room = (used <= 22'(HIGH_WATER));

    typedef enum logic [1:0] { S_IDLE, S_ISSUE, S_BEATS } st_t;
    st_t         sst  = S_IDLE;
    logic [3:0]  beat = 4'd0;

    /* The file position -> the image word it is holding (2026-11-09). Four
     * words of head, then the tail from `tail_word`. The two are quasi-static
     * together (they change with the arm, not inside a transfer), so they cross
     * with two flops apiece like every other arm-time value here. */
    logic        tail_en_s1 = 1'b0, tail_en_s2 = 1'b0;
    logic [21:0] tail_w_s1  = 22'd0, tail_w_s2  = 22'd0;

    always_ff @(posedge clk_core) begin
        tail_en_s1 <= tail_en;
        tail_en_s2 <= tail_en_s1;
        tail_w_s1  <= tail_word;
        tail_w_s2  <= tail_w_s1;
    end

    logic        empty_s1 = 1'b0, empty_s2 = 1'b0;

    always_ff @(posedge clk_core) begin
        empty_s1 <= empty;
        empty_s2 <= empty_s1;
    end

    wire [21:0] tail_w_c = tail_w_s2;
    wire [21:0] span_words_c = empty_s2 ? 22'd0
                             : tail_en_s2
                             ? (22'(HEAD_W) + 22'(IMG_WORDS) - tail_w_c)
                             : 22'(IMG_WORDS);

    wire [21:0] img_w = !tail_en_s2            ? wbin
                      : (wbin < 22'(HEAD_W)) ? wbin
                      : (tail_w_c + (wbin - 22'(HEAD_W)));

    /* ... and the file word `tail_word` names is the head's first word, so the
     * head can never overlap the tail: a tail base below 128 bytes would make
     * the file longer than the image it describes. */

    // IMG_BASE is a byte address and the word index is the count of 8-byte
    // entries, so the stream's own address is base + word * 8.
    wire [21:0] saddr = IMG_BASE + 22'(img_w << 3);

    logic [1:0] stream_s = 2'b0;
    always_ff @(posedge clk_core)
        stream_s <= {stream_s[0], stream_74a};

    wire stream_core = stream_s[1];

    assign mem_rd       = (sst == S_ISSUE) && stream_core;
    assign mem_addr     = saddr;
    // THE CLIENT'S COUNT IS THE NUMBER OF BEATS, not beats-1 (rtl/cart.sv asks
    // for 16 with 8'd16, and rtl/mem_bus.sv ends the burst at one).
    assign mem_burstcnt = 8'(BURST_LEN);

    always_ff @(posedge clk_core) begin
        if (reset_core) begin
            sst  <= S_IDLE;
            wbin <= 22'd0;
            beat <= 4'd0;
        end else if (flush_core) begin
            sst  <= S_IDLE;
            wbin <= file_start;
            beat <= 4'd0;
        end else case (sst)
            S_IDLE: begin
                if (stream_core && room && (wbin < span_words_c))
                    sst <= S_ISSUE;
            end
            S_ISSUE: begin
                // The request is accepted on the clock `mem_busy` falls; that
                // is also when the strobe has to drop.
                if (!stream_core)          sst <= S_IDLE;
                else if (!mem_busy)        sst <= S_BEATS;
            end
            S_BEATS: begin
                if (mem_dout_ready) begin
                    beat <= beat + 4'd1;
                    wbin <= wbin + 22'd1;
                    if (beat == 4'(BURST_LEN - 1))
                        sst <= S_IDLE;
                end
            end
            default: sst <= S_IDLE;
        endcase
    end

    // Every beat goes into the window at the word number it was fetched for.
    always_ff @(posedge clk_core) begin
        if ((sst == S_BEATS) && mem_dout_ready)
            imgbuf[wbin[10:0]] <= mem_dout;
    end

`ifdef GT_SIM
    /* ------------------------------------------------------------------ *
     * PROBES the harnesses read (sim/gt/gt_slot_top.sv). They are the facts
     * about the window, not leftovers: "is there anything to answer with",
     * "how much", and "the word that was last presented".
     * ------------------------------------------------------------------ */
    wire        fifo_empty  = (resident_words == 22'd0);
    wire [10:0] fifo_wcount = resident_words[10:0];
    wire [63:0] fifo_q      = win_q;
    wire [21:0] head_idx    = rbin;
    wire [63:0] hold        = 64'd0;
    wire        have_word   = 1'b0;
`endif

endmodule

`default_nettype wire
