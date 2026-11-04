//============================================================================
//  gt_save_slot -- the Pocket save slot's read side.
//
//  WHAT A GAMETANK SAVE IS. The console has no save RAM: a game stores its save
//  in the cartridge's own flash, and the emulator (the compatibility floor)
//  persists a diff of the cart image next to the ROM. So the save file IS the
//  cartridge image, and the OS reads it back out of the 0x0200_0000 window at
//  shutdown ([0080]) and writes it back in at boot ([0082]).
//
//  THE WINDOW IS ADDRESSED, NOT SEQUENCED (2026-11-02). This is the one design
//  rule the file exists to state, because the previous version broke it and the
//  card shows exactly what that costs.
//
//  The image lives in PSRAM and has to be streamed ahead: a PSRAM beat is ~80
//  clk_core and the bridge wants a word every ~88 clk_74a, so the bytes are
//  fetched in 16-beat bursts into a 2 KB buffer and a bridge read is answered
//  from it. The buffer is INDEXED BY THE IMAGE WORD NUMBER -- image word W
//  lives at `imgbuf[W % 256]` for as long as it is resident -- so the answer to
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
//  THE ACK IS HONEST. `[0080]` blocks the OS until this module says word 0 is
//  resident, and it must, because the OS starts reading the moment it is
//  answered. It used to be granted immediately, which cost the first three words
//  of every save (the stream needs ~200 clk_74a to produce the first burst). The
//  ack now waits for the word, capped at 65,535 clk_74a (0.88 ms, sixteen times
//  the fill) so a dead PSRAM still answers instead of hanging the menu.
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
    output logic        ack,            // ... accepted, and word 0 is available

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

    // ---- diagnostics ------------------------------------------------------
    output logic        underrun        // a read the stream had not produced
);

    localparam int WIN        = 256;                 // 64-bit entries (2 KB)
    localparam int BURST_LEN  = 16;                  // 8-byte beats per request
    localparam int HIGH_WATER = WIN - BURST_LEN;     // 240: last safe start
    localparam int IMG_WORDS  = IMG_BYTES / 8;       // 262,144

    // THE ACK PROMISES A HEAD START, NOT A WORD (2026-11-02). `[0080]` is a
    // command the OS blocks on, and the moment it is answered the OS reads the
    // window as fast as its bridge allows. One resident word is enough to
    // answer the first access and nothing else: the host then outruns the fill
    // and the file gets a hole a few words in. Two bursts' worth is 256 bytes,
    // ~200 us of PSRAM the OS does not feel, and it is what makes "the ack came
    // back" mean "reading from here is safe" rather than "good luck".
    localparam int ACK_WORDS  = BURST_LEN;

    // ======================================================================
    //  The image window. Written in clk_core, read in clk_74a, addressed by
    //  the image word number's low bits on both sides -- that shared mapping
    //  is what makes the window an array of the image rather than a queue.
    // ======================================================================
    (* ramstyle = "M10K, no_rw_check" *) logic [63:0] imgbuf [0:WIN-1];

    // The registered read is what lets this infer as block RAM; the address is
    // stable for the whole ~88-clk_74a bridge access, so one clock of latency
    // is invisible to the host (it collects the word four clocks after the
    // address is latched).
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

    // The pulse in each domain. `flush_74a` is also a probe: sim/gt/tb_slot.cpp
    // counts how many times the window was re-armed during a read-out.
    wire flush_74a = flush_s74[2] ^ flush_s74[1];

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
    logic [15:0] ack_wd     = 16'd0;     // the ack's escape hatch
    logic        req_q      = 1'b0;
    logic        arm_q      = 1'b0;      // pre_arm's edge, so the flush is one shot



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

    /* ... AND A REQUEST THAT ARRIVES AFTER THE PRE-ARM IS ANSWERED, NOT RESTARTED.
     * `already_armed` is "the stream is already sitting at image word 0 with
     * something in the window", which is exactly what `pre_ev` leaves behind. */
    wire         already_armed = active && (rbin == 22'd0) && (wbin_s != 22'd0);
    wire         rearm_now     = req_ev && !start_pend &&
                                 !(pre_arm && already_armed);

    wire [21:0] rd_word = bridge_addr[24:3];     // image word the address names
    wire        rd_high = bridge_addr[2];
    wire        addr2   = (bridge_addr[31:24] == 8'h02);

    /* RESIDENT IS A RANGE, AND THAT IS ALL IT IS. `[rbin, wbin)` is what the
     * stream has produced: every one of those words is at `imgbuf[W % WIN]`,
     * because both sides count the image from zero and never reorder it.
     * `arm_hold` keeps the range meaningless for the 48 clocks it takes the
     * two pointers to reset across the crossing. */
    wire resident = (rd_word >= rbin) && (rd_word < wbin_s);
    wire rd_hit   = addr2 && active && resident && (arm_hold == 6'd0);

    wire [21:0] resident_words = wbin_s - rbin;

    // Reads answer from the window one clock after their address, and the
    // qualifiers ride with them so a word and its `hit` always belong together.
    always_ff @(posedge clk_74a) begin
        win_q  <= imgbuf[rd_word[7:0]];
        q_high <= rd_high;
        q_hit  <= rd_hit;
    end

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
    wire advance = rd_hit && (rd_word >= rbin + 22'd8);

    always_ff @(posedge clk_74a) begin
        if (reset_74a) begin
            active     <= 1'b0;
            start_pend <= 1'b0;
            stream_74a <= 1'b0;
            arm_hold   <= 6'd0;
            ack        <= 1'b0;
            ack_wd     <= 16'd0;
            req_q      <= 1'b0;
            arm_q      <= 1'b0;
            rbin       <= 22'd0;
            underrun   <= 1'b0;
        end else begin
            ack    <= 1'b0;
            req_q  <= req;
            arm_q  <= pre_arm;

            if (ack_wd != 16'd0)   ack_wd   <= ack_wd - 16'd1;
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
            if (rearm_now || pre_ev) begin
                flush_tog  <= ~flush_tog;
                active     <= 1'b1;
                rbin       <= 22'd0;
                stream_74a <= 1'b0;
                arm_hold   <= 6'd48;
                underrun   <= 1'b0;

                /* AND ONLY THE OS'S REQUEST HAS AN ACK TO ANSWER. A dump that
                 * arrives while one is outstanding must not take the deadline
                 * away with it: `ack_wd` zeroed under a pending `[0080]` is a
                 * command the framework waits on forever. */
                if (rearm_now) begin
                    start_pend <= 1'b1;
                    ack_wd     <= 16'd65535;
                end
            end else begin
                /* THE PRE-ARMED REQUEST: no flush, only the ack it is owed. */
                if (req_ev && !start_pend) begin
                    start_pend <= 1'b1;
                    ack_wd     <= 16'd65535;
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
                end
            end

            if (advance)
                rbin <= rd_word - 22'd7;

            /* READY MEANS WORD 0 IS IN THE WINDOW. The OS stops waiting on this
             * and starts reading, so an empty window here is a zero header and
             * two more zero words before the stream catches up. The cap is the
             * escape hatch for a PSRAM that is not answering. */
            if (start_pend && (arm_hold == 6'd0) &&
                ((resident_words >= 22'(ACK_WORDS)) || (ack_wd == 16'd1))) begin
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
            if (bridge_rd && addr2 && !rd_hit && active && (arm_hold == 6'd0) &&
                (resident_words != 22'd0) && (rd_word > rbin) &&
                (rd_word < rbin + 22'(WIN)))
                underrun <= 1'b1;
        end
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
            rgray_s1 <= 22'd0;
            rgray_s2 <= 22'd0;
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

    // IMG_BASE is a byte address and the word index is the count of 8-byte
    // entries, so the stream's own address is base + word * 8.
    wire [21:0] saddr = IMG_BASE + 22'(wbin << 3);

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
            wbin <= 22'd0;
            beat <= 4'd0;
        end else case (sst)
            S_IDLE: begin
                if (stream_core && room && (wbin < 22'(IMG_WORDS)))
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
            imgbuf[wbin[7:0]] <= mem_dout;
    end

    /* ------------------------------------------------------------------ *
     * PROBES the harnesses read (sim/gt/gt_slot_top.sv). They are the facts
     * about the window, not leftovers: "is there anything to answer with",
     * "how much", and "the word that was last presented".
     * ------------------------------------------------------------------ */
    wire        fifo_empty  = (resident_words == 22'd0);
    wire [8:0]  fifo_wcount = resident_words[8:0];
    wire [63:0] fifo_q      = win_q;
    wire [21:0] head_idx    = rbin;
    wire [63:0] hold        = 64'd0;
    wire        have_word   = 1'b0;

endmodule

`default_nettype wire
