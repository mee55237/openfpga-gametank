//============================================================================
//  gt_state_buffer -- one 64-bit state buffer for both directions.
//
//  THE DEVICE HAS 308 M10K BLOCKS AND THE TWO BUFFERS NEEDED 135 OF THEM.
//  A save drains 8,257 words out of the machine into a store the host reads at
//  its own pace; a load stages up to 8,769 words the host writes at bridge
//  speed so the machine can take them at its own. As two arrays that was 64
//  blocks for the store, 71 for the stage, and the whole core came to 351
//  blocks -- it did not fit, by 43.
//
//  They are never in flight at the same time: the host saves, or it restores.
//  So this is one array, and only the DIRECTION of its two ports changes with
//  the command:
//
//     port A (clk_74a)   save: the host's read    load: the host's write
//     port B (clk_core)  save: the engine's write  load: the engine's read
//
//  Each port keeps its own clock and simply turns around, which is what makes
//  one M10K instance cover both; a simple dual port would have had to swap its
//  write and read clocks and could not be inferred. The separate store and the load
//  stage it replaced are gone (see save_state_controller.sv).
//
//  The M10K read is registered, so each side keeps the word it presented one
//  clock earlier and reports `empty` until that word has arrived -- the same
//  head register the FIFO uses, for the same reason.
//============================================================================

`default_nettype none

module gt_state_buffer #(
    // The declared maximum a host may send: `savestate_maxloadsize` is this
    // many 64-bit words. It has to be the WHOLE file, not a rate buffer: the OS
    // fills the window and only then commands the load (see
    // save_state_controller's STAGE_WORDS). A save is smaller and drains into
    // the same space, so one array sized for the larger covers both.
    parameter int WORDS = 8769
) (
    input  logic        clk_74a,
    input  logic        clk_core,
    input  logic        reset_74a,
    input  logic        reset_core,

    // ---- which way the ports point ---------------------------------------
    // Driven from clk_74a: set by the host's first word of a load stream,
    // cleared when a save begins. It never changes while a transfer is
    // running, and the core side sees a synchronised copy.
    input  logic        mode_load,
    input  logic        load_start,       // clk_74a: the host's word 0
    input  logic        save_flush_74a,   // clk_74a: a save begins here
    input  logic        save_flush_core,  // clk_core: ... the same event

    // ---- save: the engine writes (core), the host reads (74a) ------------
    input  logic        save_wr,
    input  logic [63:0] save_wdata,
    output logic        save_full,
    input  logic        save_rd,
    output logic [63:0] save_rdata,
    output logic        save_empty,

    // ---- load: the host writes (74a), the engine reads (core) ------------
    input  logic        load_wr,
    input  logic [63:0] load_wdata,
    output logic        load_full,
    input  logic        load_rd,
    output logic [63:0] load_rdata,
    output logic        load_empty
);

    localparam int AW = $clog2(WORDS);       // 14 for 8,769

    // One array, two clocks: the altsyncram true-dual-port template.
    (* ramstyle = "M10K, no_rw_check" *) logic [63:0] mem [0:WORDS-1];

    // Pointers are occupancy counts (word 0 is the first), one per side.
    logic [AW:0] swptr = '0, srptr = '0;     // save: engine wrote, host consumed
    logic [AW:0] lwptr = '0, lrptr = '0;     // load: host wrote, engine consumed

    // The core's copy of the mode. It only has to be right by the time a
    // transfer starts, and a transfer cannot start in the two clocks after the
    // host's first word, so two flops are enough.
    logic [1:0] mode_s = 2'b0;

    always_ff @(posedge clk_core)
        mode_s <= {mode_s[0], mode_load};

    wire core_load = mode_s[1];

    // ---- port A, clk_74a --------------------------------------------------
    wire [AW-1:0] a_addr  = mode_load ? lwptr[AW-1:0] : srptr[AW-1:0];
    wire          a_we    = mode_load & load_wr;
    wire [63:0]   a_wdata = load_wdata;

    logic [63:0] a_q;

    always_ff @(posedge clk_74a) begin
        if (a_we)
            mem[a_addr] <= a_wdata;
        a_q <= mem[a_addr];
    end

    // ---- port B, clk_core -------------------------------------------------
    wire [AW-1:0] b_addr  = core_load ? lrptr[AW-1:0] : swptr[AW-1:0];
    wire          b_we    = ~core_load & save_wr;
    wire [63:0]   b_wdata = save_wdata;

    logic [63:0] b_q;

    always_ff @(posedge clk_core) begin
        if (b_we)
            mem[b_addr] <= b_wdata;
        b_q <= mem[b_addr];
    end

    /* ================================================================== *
     * The crossings. Each pointer is a gray code on two flops, as in
     * any gray-pointer FIFO, and each side clears the other's synchroniser on its
     * own reset: a flush clears both pointers, and a side that reset first
     * must not read the other side's pre-reset value as data.
     * ================================================================== */
    logic [AW:0] swgray = '0, srgray = '0, lwgray = '0, lrgray = '0;
    logic [AW:0] swg1 = '0, swg2 = '0;      // save write -> 74a
    logic [AW:0] srg1 = '0, srg2 = '0;      // save read  -> core
    logic [AW:0] lwg1 = '0, lwg2 = '0;      // load write -> core
    logic [AW:0] lrg1 = '0, lrg2 = '0;      // load read  -> 74a

    always_comb begin
        swgray = (swptr >> 1) ^ swptr;
        srgray  = (srptr >> 1) ^ srptr;
        lwgray = (lwptr >> 1) ^ lwptr;
        lrgray = (lrptr >> 1) ^ lrptr;
    end

    always_ff @(posedge clk_74a) begin
        if (reset_74a | save_flush_74a) begin
            swg1 <= '0;
            swg2 <= '0;
            lrg1 <= '0;
            lrg2 <= '0;
        end else begin
            swg1 <= swgray;
            swg2 <= swg1;
            lrg1 <= lrgray;
            lrg2 <= lrg1;
        end
    end

    always_ff @(posedge clk_core) begin
        if (reset_core | save_flush_core) begin
            srg1 <= '0;
            srg2 <= '0;
            lwg1 <= '0;
            lwg2 <= '0;
        end else begin
            srg1 <= srgray;
            srg2 <= srg1;
            lwg1 <= lwgray;
            lwg2 <= lwg1;
        end
    end

    // Gray back to binary: one running XOR from the top down.
    function automatic [AW:0] gray2bin(input logic [AW:0] g);
        gray2bin[AW] = g[AW];
        for (int i = AW - 1; i >= 0; i--)
            gray2bin[i] = gray2bin[i+1] ^ g[i];
    endfunction

    wire [AW:0] swptr_74 = gray2bin(swg2);   // words the engine has written
    wire [AW:0] srptr_c  = gray2bin(srg2);   // words the host has read
    wire [AW:0] lwptr_c  = gray2bin(lwg2);   // words the host has written
    wire [AW:0] lrptr_74 = gray2bin(lrg2);   // words the engine has read

    /* ================================================================== *
     * Save side: the engine writes, the host reads.
     * ================================================================== */
    always_ff @(posedge clk_core) begin
        if (reset_core | save_flush_core)
            swptr <= '0;
        else if (b_we)
            swptr <= swptr + 1'b1;
    end

    // The engine stops rather than wrapping over words the host has not read.
    // A save is 8,257 words and the buffer 8,769, so this can only fire if a
    // future state grows past the array -- it is a guard, not a throttle.
    assign save_full = (swptr - srptr_c) >= (AW + 1)'(WORDS);

    logic s_head_v = 1'b0;

    /* THE DRAIN WAITS FOR THE FLUSH TO SETTLE -- the 31-cycle window
     * inherited from the previous core. The engine's write
     * pointer is reset in clk_core by a toggle that reaches it through the
     * same synchroniser chain as the request that starts it, so in the few
     * clk_74a cycles after a flush the host's view of the count can still be
     * the previous stream's -- and a head taken then is a word of the LAST
     * save, presented as this one's first. 31 cycles is far more than the
     * flops need and far less than the ~2 us before the engine's first word. */
    logic [4:0] flush_cnt = 5'd0;

    always_ff @(posedge clk_74a) begin
        if (save_flush_74a)
            flush_cnt <= 5'd31;
        else if (flush_cnt != 5'd0)
            flush_cnt <= flush_cnt - 5'd1;
    end

    always_ff @(posedge clk_74a) begin
        if (reset_74a | save_flush_74a) begin
            srptr    <= '0;
            s_head_v <= 1'b0;
        end else if (save_rd && s_head_v) begin
            srptr    <= srptr + 1'b1;
            s_head_v <= 1'b0;
        end else if (!s_head_v && !mode_load && (flush_cnt == 5'd0) &&
                     (srptr < swptr_74)) begin
            s_head_v <= 1'b1;
        end
    end

    assign save_rdata = a_q;
    assign save_empty = ~s_head_v;

    /* ================================================================== *
     * Load side: the host writes, the engine reads.
     * ================================================================== */
    // A new stream starts at word 0: the host's write pointer jumps back to
    // zero, and the engine notices by finding itself ahead of it.
    always_ff @(posedge clk_74a) begin
        if (reset_74a | save_flush_74a | load_start)
            lwptr <= '0;
        else if (a_we)
            lwptr <= lwptr + 1'b1;
    end

    /* A NEW STREAM'S POINTER IS BEHIND THE OLD READER'S, AND THAT IS NOT "FULL"
     * (2026-10-31). `load_start` puts the host's write pointer back to zero at
     * word 0, but the engine's read pointer arrives here through two flops and
     * is still the PREVIOUS stream's for a few clocks. The subtraction below is
     * unsigned, so that window reads as 0 - 8,711: the buffer looked full, every
     * word of the new stream was dropped, and the engine was never armed because
     * the host's count never reached the state's own length.
     *
     * The reader can never legitimately be ahead of the writer (a head is only
     * offered while lrptr < lwptr), so "the far pointer is higher" IS the restart
     * window. Treating it as zero occupancy is the same statement the load side's
     * own pointer reset makes. */
    assign load_full = (lwptr >= lrptr_74) &&
                       ((lwptr - lrptr_74) >= (AW + 1)'(WORDS));

    // Four clocks after a new stream is spotted before a head is offered: the
    // host's zeroed pointer takes two flops to arrive, and until it does the
    // count here still reads as the previous stream's -- a head taken then is
    // a word of the LAST save, presented as this one's header.
    logic [2:0] load_settle = 3'd7;
    logic       l_head_v    = 1'b0;

    always_ff @(posedge clk_core) begin
        if (reset_core | save_flush_core) begin
            lrptr       <= '0;
            l_head_v    <= 1'b0;
            load_settle <= 3'd7;
        end else begin
            if (load_settle != 3'd0)
                load_settle <= load_settle - 3'd1;

            if (lrptr > lwptr_c) begin
                // The host's pointer went backwards: its stream restarted.
                lrptr       <= '0;
                l_head_v    <= 1'b0;
                load_settle <= 3'd7;
            end else if (load_rd && l_head_v) begin
                lrptr    <= lrptr + 1'b1;
                l_head_v <= 1'b0;
            end else if (!l_head_v && core_load && (load_settle == 3'd0) &&
                         (lrptr < lwptr_c)) begin
                l_head_v <= 1'b1;
            end
        end
    end

    assign load_rdata = b_q;
    assign load_empty = ~l_head_v;

endmodule

`default_nettype wire
