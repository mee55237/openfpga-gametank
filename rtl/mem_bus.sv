//============================================================================
//  The console's memory port, backed by Pocket PSRAM.
//
//  GameTank keeps two things outside the FPGA: 512 KB of GRAM (the blitter's
//  source bitmaps) and the cartridge image (up to 2 MB). On the MiSTer core
//  both sat in HPS DDR3 behind a 64-bit burst client. Pocket has no HPS, so
//  both live in cram0 -- GRAM at byte 0, the cartridge at 0x100000 -- and this
//  module is the only thing that talks to the chip.
//
//  The client protocol is the one the machine's memory users already speak
//  (rtl/gram.sv's row prefetcher, rtl/cart.sv's bank cache, and the flash-save
//  streamer): hold rd/we with the address until busy falls; that clock is the
//  acceptance. A read then delivers `burstcnt` 64-bit beats, one per beat, on
//  dout_ready; a write takes its 64-bit word in one go. What changed is the
//  transport: PSRAM is a 16-bit AD-MUX part, so each beat is four halfword
//  accesses through rtl/psram.sv and costs roughly eighty clocks.
//
//  That cost is why the caches above this port exist. A blitter row is 256
//  bytes (32 beats, ~2,560 clocks) and the blitter consumes a row in 128 CPU
//  cycles (~3,580 clocks), so rtl/gram.sv's row buffer still stays ahead of the
//  engine; a cartridge bank is cached whole, so the CPU only pays this latency
//  on the first pass over new code or data. The numbers are in
//  docs/gametank-port.md -- they are why this file is not a plain 64-bit mux.
//
//  No reset: the cartridge download runs while the console is held in reset,
//  and the power-up state below is its own initializer.
//============================================================================

module mem_bus
(
    input  logic        clk_sys,

    // ---- client 0: GRAM row prefetcher (rtl/gram.sv) --------------------
    input  logic        c0_rd,
    input  logic        c0_we,
    input  logic [21:0] c0_addr,      // byte address in image space
    input  logic [63:0] c0_din,
    input  logic [7:0]  c0_be,
    input  logic [7:0]  c0_burstcnt,
    output logic        c0_dout_ready,
    output logic        c0_busy,

    // ---- client 1: cartridge (rtl/cart.sv) ------------------------------
    input  logic        c1_rd,
    input  logic        c1_we,
    input  logic [21:0] c1_addr,
    input  logic [63:0] c1_din,
    input  logic [7:0]  c1_be,
    input  logic [7:0]  c1_burstcnt,
    output logic        c1_dout_ready,
    output logic        c1_busy,

    // ---- client 2: flash-save streamer (read only) ----------------------
    input  logic        c2_rd,
    input  logic [21:0] c2_addr,
    input  logic [7:0]  c2_burstcnt,
    output logic        c2_dout_ready,
    output logic        c2_busy,

    // ---- client 3: the Pocket save slot's image read (read only) --------
    // The data slot the OS saves out is the cartridge image itself. It is
    // 2 MB and the OS reads it 4 bytes at a time at ~2.4 us, so the request
    // is a BURST (16 beats = 128 bytes) fed to a read-ahead FIFO in
    // rtl/gt_save_slot.sv; a one-beat client would not keep ahead of the
    // bridge's own rate.
    input  logic        c3_rd,
    input  logic [21:0] c3_addr,
    input  logic [7:0]  c3_burstcnt,
    output logic        c3_dout_ready,
    output logic        c3_busy,

    // the beat just read, fanned out to every client (dout_ready qualifies)
    output logic [63:0] dout,

    // ---- PSRAM chip 0 ---------------------------------------------------
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
    output logic         cram_lb_n
);

// The PSRAM timing model runs on the console clock for now: at 28.636 MHz an
// async halfword read takes ~23 clocks, which the row buffer and the bank
// cache absorb (see the header). Moving this port to the Pocket's 74.25 MHz
// clock is the throughput milestone in docs/gametank-port.md.
localparam real CLOCK_SPEED = 28.636;

typedef enum logic [1:0] { IDLE, CMD, BEAT } state_t;
typedef enum logic [1:0] { HS_ISSUE, HS_BUSY, HS_DONE } half_t;

state_t     st         = IDLE;
logic [1:0] owner      = 2'd0;
logic [1:0] last_owner = 2'd2;
logic [7:0] beats_left = '0;

logic [21:0] beat_addr;
logic [63:0] beat_din;
logic [7:0]  beat_be;

half_t       hs     = HS_ISSUE;
logic [1:0]  hw     = 2'd0;
logic [63:0] beat   = '0;
logic        wr_run = 1'b0;

logic [63:0] dout_r   = '0;
logic        dready_r = 1'b0;
// Which client the beat that is on `dout_r` belongs to. Captured with the
// beat: by the time it is presented the arbiter may already be back in IDLE
// (and re-granting), so `owner` is not a reliable qualifier then.
logic [1:0]  rsp_owner = 2'd0;

// ---- PSRAM request side --------------------------------------------------
logic [21:0] ps_addr;
logic        ps_rd, ps_wr, ps_ub, ps_lb;
logic [15:0] ps_din;
logic        ps_busy, ps_avail;
logic [15:0] ps_dout;

wire beat_active = (st == BEAT);
wire hw_start    = beat_active && (hs == HS_ISSUE) && !ps_busy;

assign ps_addr = beat_addr + {19'd0, hw, 1'b0};
assign ps_rd   = hw_start && !wr_run;
assign ps_wr   = hw_start &&  wr_run && (beat_be[hw * 2] | beat_be[hw * 2 + 1]);
assign ps_din  = beat_din[hw * 16 +: 16];
// psram.sv's write_high_byte/write_low_byte are enables (it drives the UB#/
// LB# pins itself), so these follow the byte-enable bits directly.
assign ps_ub   = beat_be[hw * 2 + 1];
assign ps_lb   = beat_be[hw * 2];

psram #(.CLOCK_SPEED(CLOCK_SPEED)) u_psram
(
    .clk             (clk_sys),
    .bank_sel        (1'b0),
    .addr            (ps_addr),
    .write_en        (ps_wr),
    .data_in         (ps_din),
    .write_high_byte (ps_ub),
    .write_low_byte  (ps_lb),
    .read_en         (ps_rd),
    .read_avail      (ps_avail),
    .data_out        (ps_dout),
    .busy            (ps_busy),
    .cram_a          (cram_a),
    .dq_out          (cram_dq_out),
    .dq_oe           (cram_dq_oe),
    .dq_in           (cram_dq_in),
    .cram_wait       (cram_wait),
    .cram_clk        (cram_clk),
    .cram_adv_n      (cram_adv_n),
    .cram_cre        (cram_cre),
    .cram_ce0_n      (cram_ce0_n),
    .cram_ce1_n      (cram_ce1_n),
    .cram_oe_n       (cram_oe_n),
    .cram_we_n       (cram_we_n),
    .cram_ub_n       (cram_ub_n),
    .cram_lb_n       (cram_lb_n)
);

// ---- arbitration ---------------------------------------------------------
wire c0_req = c0_rd | c0_we;
wire c1_req = c1_rd | c1_we;
wire c2_req = c2_rd;
wire c3_req = c3_rd;

// A client may issue in the CMD window; every other clock its busy is high, so
// a command is held rather than lost.
// A command is accepted in the CMD window only. The owner must see busy fall
// on exactly that clock (its own FSM drops the strobe at that edge), and must
// see it rise again for the rest of the burst -- otherwise it would take its
// "port is free" branch mid-transfer and issue over the top of the burst.
assign c0_busy = !((st == CMD) && (owner == 2'd0));
assign c1_busy = !((st == CMD) && (owner == 2'd1));
assign c2_busy = !((st == CMD) && (owner == 2'd2));
assign c3_busy = !((st == CMD) && (owner == 2'd3));

assign c0_dout_ready = dready_r && (rsp_owner == 2'd0);
assign c1_dout_ready = dready_r && (rsp_owner == 2'd1);
assign c2_dout_ready = dready_r && (rsp_owner == 2'd2);
assign c3_dout_ready = dready_r && (rsp_owner == 2'd3);
assign dout          = dout_r;

// ---- one halfword of the current beat -----------------------------------
wire rd_done = (st == BEAT) && (hs == HS_DONE) && !wr_run && ps_avail;
wire wr_done = (st == BEAT) && (hs == HS_DONE) &&  wr_run && !ps_busy && !ps_avail;
wire skip_hw = (st == BEAT) && (hs == HS_ISSUE) && wr_run &&
               !(beat_be[hw * 2] | beat_be[hw * 2 + 1]);
wire hw_done = rd_done || wr_done || skip_hw;

// the beat with this halfword folded in; ps_dout is meaningful only when a
// read has just completed, which is the only time this is used
logic [63:0] beat_full;
always_comb begin
    beat_full = beat;
    beat_full[hw * 16 +: 16] = ps_dout;
end

/* FAIR TURNS ARE WRONG FOR THE SAVE SLOT (2026-11-03).
 *
 * The arbiter was round-robin: one 128-byte burst each, 0 -> 1 -> 2 -> 3. A
 * 16-beat burst is 128 bytes at four halfword reads a beat, and a halfword
 * read is ~23 clocks of this clock, so one burst is about 50 us of the PSRAM
 * port. The APF, meanwhile, reads the save slot every ~1.2 us -- 3.3 MB/s --
 * and the slot's window is 2 KB, i.e. half a millisecond of slack. Sharing
 * the port with the GRAM row prefetcher and the cartridge cache gives the
 * save stream a quarter of 2.5 MB/s, so the window is empty most of the time
 * and the host is answered zero.
 *
 * That is not a theory: `Minicraft.sav` on the card, written by the build of
 * 2026-11-03 14:39, contains 4% of the cartridge's nonzero bytes. The OS read
 * two megabytes, the core answered ~80 KB of image and zeros for the rest.
 *
 * So the slot's stream wins the port whenever it asks. It asks only while its
 * window is below the high-water mark, which is self-limiting: one 2 KB refill
 * then the video has the bus back. During a save-out or a restore the picture
 * may stutter for a few hundred milliseconds; the console is held or paused
 * for the transfer anyway, and a correct file is worth a frozen frame. */
logic [1:0] pick;
always_comb begin
    if (c3_req)
        pick = 2'd3;
    else begin
        pick = 2'd0;
        unique case (last_owner)
            2'd0:    pick = c1_req ? 2'd1 : c2_req ? 2'd2 : 2'd0;
            2'd1:    pick = c2_req ? 2'd2 : c0_req ? 2'd0 : 2'd1;
            2'd2:    pick = c0_req ? 2'd0 : c1_req ? 2'd1 : 2'd2;
            default: pick = c0_req ? 2'd0 : c1_req ? 2'd1 : c2_req ? 2'd2 : 2'd3;
        endcase
    end
end

`ifdef GT_DEBUG
always_ff @(posedge clk_sys) begin
    if (ps_rd) $display("[%0t] bus RD %06x hw=%0d", $time, ps_addr, hw);
    if (ps_wr) $display("[%0t] bus WR %06x hw=%0d data=%04x be=%02x",
                        $time, ps_addr, hw, ps_din, beat_be);
    if (hw_done) $display("[%0t]   hw done hw=%0d base=%06x", $time, hw, beat_addr);
end
`endif

always_ff @(posedge clk_sys) begin
    dready_r <= 1'b0;

    case (st)
        IDLE: begin
            if (c0_req || c1_req || c2_req || c3_req) begin
                owner <= pick;
                st    <= CMD;
            end
        end

        CMD: begin
            // The picked client's strobe is up: this clock accepts it. If it
            // withdrew between arbitration and here (a client may finish its
            // own request while waiting), just re-arbitrate.
            if (!((owner == 2'd0) ? c0_req
                  : (owner == 2'd1) ? c1_req
                  : (owner == 2'd2) ? c2_req : c3_req)) begin
                last_owner <= owner;
                st         <= IDLE;
            end
            else begin
            case (owner)
                2'd0: begin
                    beat_addr <= c0_addr; beat_din <= c0_din;
                    beat_be   <= c0_be;   beats_left <= c0_burstcnt;
                    wr_run    <= c0_we;
                end
                2'd1: begin
                    beat_addr <= c1_addr; beat_din <= c1_din;
                    beat_be   <= c1_be;   beats_left <= c1_burstcnt;
                    wr_run    <= c1_we;
                end
                2'd2: begin
                    beat_addr <= c2_addr; beat_din <= '0;
                    beat_be   <= 8'hFF;   beats_left <= c2_burstcnt;
                    wr_run    <= 1'b0;
                end
                default: begin
                    beat_addr <= c3_addr; beat_din <= '0;
                    beat_be   <= 8'hFF;   beats_left <= c3_burstcnt;
                    wr_run    <= 1'b0;
                end
            endcase
            hw  <= 2'd0;
            hs  <= HS_ISSUE;
            beat <= '0;
            st  <= BEAT;
            end
        end

        BEAT: begin
            if (rd_done) beat <= beat_full;
            // One halfword event, decided combinationally above.
            if (hw_done) begin
                if (hw == 2'd3) begin
                    if (!wr_run) begin
                        dout_r      <= beat_full;
                        rsp_owner   <= owner;
                        dready_r    <= 1'b1;
                    end
                    hw        <= 2'd0;
                    hs        <= HS_ISSUE;
                    beat_addr <= beat_addr + 22'd8;
                    beat      <= '0;
                    if (beats_left == 8'd1) begin
                        st         <= IDLE;
                        last_owner <= owner;
                    end
                    else
                        beats_left <= beats_left - 8'd1;
                end
                else begin
                    hw <= hw + 2'd1;
                    hs <= HS_ISSUE;
                end
            end
            else if (hs == HS_ISSUE) begin
                if (hw_start) hs <= HS_BUSY;
            end
            else if (hs == HS_BUSY) begin
                if (ps_busy || ps_avail) hs <= HS_DONE;
            end
        end

        default: st <= IDLE;
    endcase
end

endmodule
