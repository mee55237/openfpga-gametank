//============================================================================
//  GRAM, PSRAM-backed (512 KB at PSRAM byte 0).
//
//  Ported from the MiSTer core's rtl/gram_ddr.sv: the row buffer, the
//  prefetcher and the eight-word CPU read cache are unchanged, because they
//  are the part that makes a slow memory look like the console's SRAM. The
//  transport underneath is now rtl/mem_bus.sv (four halfword PSRAM accesses
//  per 64-bit beat) instead of a DDR3 burst client, so the only edits here are
//  the port names, the byte-address arithmetic, and the dropped DDR base.
//
//  Guarantees preserved (docs/gametank-hardware.md, upstream REQUIREMENTS):
//   - Blitter IRQ timing is untouched (exact WxH duration counter in
//     blitter.sv, independent of the pixel datapath).
//   - Pixel writes may slip under memory latency; software cannot observe it
//     ($4000 reads open bus while COPY_ENABLE=1).
//   - CPU window accesses stretch the CPU clock-enable (cpu_stall) only on
//     unavoidable misses; reads use a tiny cache so scans pay one miss per
//     active 8-byte stream.
//
//  Prefetch: a blit's whole GRAM access set is deterministic at TRIGGER
//  (params + mode bits). The prefetcher replicates the engine's per-row GY
//  sequence and streams each row's two gx-quadrant halves into a double row
//  buffer, staying one row ahead of consumption.
//
//  GRAM address layout (HARDWARE.md section Blitter):
//    addr = {bank[2:0], gy'[7], gx'[7], gy'[6:0], gx'[6:0]}   (19 bits)
//  Row identity excludes the gx bits: {bank, gy'[7], gy'[6:0]} (11 bits).
//  PSRAM placement: byte address == addr.
//============================================================================

module gram
(
    input  logic        clk_sys,
    input  logic        reset,
    input  logic        cpu_ce,

    // parameter-write snoop (same bus the blitter sees)
    input  logic        param_we,
    input  logic [2:0]  param_addr,
    input  logic [7:0]  param_data,
    input  logic [7:0]  dma_ctl,
    input  logic [7:0]  banking,

    // blitter port: comb candidate address/want, ready gates the engine
    // step; the served byte appears on blit_q two clocks after the address
    // registers, which is inside the blitter's window phase 3 (four clocks
    // after the step).
    input  logic [18:0] blit_paddr,
    input  logic        blit_want,
    output logic        blit_ready,
    input  logic [18:0] blit_addr,    // registered by the blitter at the step
    output logic [7:0]  blit_q,

    // CPU window channel (strobe-latched pulses from mainbus)
    input  logic [18:0] cpu_addr,
    input  logic        cpu_we,
    input  logic [7:0]  cpu_wdata,
    input  logic        cpu_rd,       // pulses when a window read latched
    output logic [7:0]  cpu_q,
    output logic        cpu_stall,    // freeze the console clock-enables

    // memory port (rtl/mem_bus.sv)
    output logic        mem_rd,
    output logic        mem_we,
    output logic [21:0] mem_addr,     // PSRAM byte address
    output logic [63:0] mem_din,
    output logic [7:0]  mem_be,
    output logic [7:0]  mem_burstcnt,
    input  logic [63:0] mem_dout,
    input  logic        mem_dout_ready,
    input  logic        mem_busy
);

// Low paddr bits select within a served beat; blit_addr's row bits are
// implied by the slot latched at the step; other bits are engine-side.
wire _unused = &{1'b0, dma_ctl[7:5], dma_ctl[2:0], banking[7:3],
                 blit_paddr[2:0], blit_addr[18:15], blit_addr[13:7]};

function automatic logic [7:0] gcarry(input logic [7:0] v);
    return dma_ctl[4] ? v + 8'd1 : {v[7:4], v[3:0] + 4'd1};
endfunction

// ---------------------------------------------------------------------------
// Param snoop (the prefetcher's own copies)
// ---------------------------------------------------------------------------
logic [7:0] pGY, pH;
logic       trig_pulse;

always_ff @(posedge clk_sys) begin
    trig_pulse <= 1'b0;
    if (param_we) begin
        case (param_addr)
            3'd3: pGY <= param_data;
            3'd5: pH  <= param_data;
            3'd6: if (param_data[0]) trig_pulse <= 1'b1;
            default: ;
        endcase
    end
end

// ---------------------------------------------------------------------------
// Double row-buffer: 2 slots × 256 B (both gx-quadrant halves of one row)
//
// ONE M10K, ONE BYTE WIDE (2026-11-01). The buffer used to be flat registers:
// a fill wrote the eight bytes of a PSRAM beat in one clock, which is eight
// write ports, so Quartus built 4,096 flops and their read muxes -- 2,317 ALMs
// and a third of the whole core for 512 bytes. Bytes now go in one per clock.
// A beat arrives every ~80 clocks (mem_bus.sv), so eight clocks to store it is
// invisible to the engine, and `beatv` is only set once the last byte of the
// beat has been written, so a beat still being filled is never a hit.
//
// The read is registered as well, and `blit_q` sits one register after it: the
// byte for a step is on `gram_q` two clocks after its address registers. The
// blitter reads it in window phase 3, four clocks after the step, which is the
// same margin the MiSTer row buffer (a real BRAM) had.
// ---------------------------------------------------------------------------
(* ramstyle = "M10K, no_rw_check" *) logic [7:0] rowbuf [0:511];
logic [10:0] tag   [0:1];    // {bank, gy'[7], gy'[6:0]}
logic [31:0] beatv [0:1];    // per-8-byte-beat valid bits
logic        lru;            // slot to refill next

wire [10:0] want_row = {blit_paddr[18:15], blit_paddr[13:7]};
wire [4:0]  want_beat = {blit_paddr[14], blit_paddr[6:3]};

wire hit0 = (tag[0] == want_row) && beatv[0][want_beat];
wire hit1 = (tag[1] == want_row) && beatv[1][want_beat];
assign blit_ready = !blit_want || dma_ctl[3] || hit0 || hit1;  // colorfill needs no data

// The serving slot is LATCHED at the granted step: a refill may retag the
// other slot's entry between the step and the engine's win_ph==3 sample,
// so a live tag compare would redirect an in-flight serve to the wrong
// slot (caught by the blit_scene lockstep run).
logic srv_slot;

// ---- the row buffer's two ports -----------------------------------------
// Write: the fill sequence, one byte per clock (BURST_STORE below).
// Read: the serving slot, registered output; blit_q is the second register
// stage that puts the byte back on the clock the engine samples it.
logic        rb_we;
logic [8:0]  rb_waddr;
logic [7:0]  rb_wdata;
logic [8:0]  rb_raddr;
logic [7:0]  rb_q;

assign rb_raddr = {srv_slot, blit_addr[14], blit_addr[6:0]};

always_ff @(posedge clk_sys) begin
    if (rb_we)
        rowbuf[rb_waddr] <= rb_wdata;
    rb_q <= rowbuf[rb_raddr];
end

always_ff @(posedge clk_sys) begin
    if (cpu_ce && blit_want && blit_ready)
        srv_slot <= hit1;
    blit_q <= rb_q;
end

`ifdef GRAM_DDR_DEBUG
always_ff @(posedge clk_sys) begin
    if (st == BURST_CMD)
        $display("[%0t] FILL slot=%0d half=%0d row=%03x", $time, fill_slot, fill_half, fill_row);
    if (blit_want)
        $display("[%0t] WANT addr=%05x ready=%0d tag0=%03x tag1=%03x srvslot=%0d q=%02x",
                 $time, blit_paddr, blit_ready, tag[0], tag[1], srv_slot, blit_q);
end
`endif

// ---------------------------------------------------------------------------
// Prefetch sequencing + PSRAM FSM
// ---------------------------------------------------------------------------
typedef enum logic [2:0] { IDLE, BURST_CMD, BURST_DATA, BURST_STORE, CPUW, CPUR, CPUR_WAIT } st_e;
st_e st;

logic [7:0]  next_gy;        // raw engine gy of the next row to prefetch
logic [7:0]  rows_left;
logic        fill_slot;      // slot being filled
logic        fill_half;      // which 128B half (gx'[7])
logic [3:0]  beat_cnt;
logic [63:0] fill_word;      // the beat being unpacked into the row buffer
logic [2:0]  store_b;        // which of its bytes is going in this clock
logic [10:0] fill_row;
logic        ydir_l;

// Demand gating: beyond the two initial fills, fetch row k+1 only after the
// engine has demonstrably reached row k (the most recently fetched row) —
// the momentary blit_want has gaps (trigger latency, between-pixel windows)
// and must not be trusted for "engine no longer needs this slot".
logic [1:0]  init_fills;
logic [10:0] last_fetch_tag;
logic [10:0] last_req;
logic        last_req_v;

// CPU channel latches
logic        cpuw_pend, cpur_pend;
logic [18:0] cpu_addr_l;
logic [7:0]  cpu_wdata_l;
logic [2:0]  cpu_lane;
logic [7:0]  cpu_cache_v;
logic [15:0] cpu_cache_word [0:7];
logic [63:0] cpu_cache_data [0:7];
logic [2:0]  cpu_cache_hit_idx;
logic [2:0]  cpu_cache_alloc;
logic [2:0]  cpu_cache_rr;
logic        cpu_cache_hit /*verilator public_flat_rd*/;

assign cpu_stall = cpur_pend || cpuw_pend;
wire cpuw_fast = cpu_we && st == IDLE && !mem_busy && !cpuw_pend && !cpur_pend;

wire [7:0] row_eff = ydir_l ? ~next_gy : next_gy;

always_comb begin
    cpu_cache_hit = 1'b0;
    cpu_cache_hit_idx = 3'd0;
    for (int i = 0; i < 8; i++) begin
        if (cpu_cache_v[i] && cpu_cache_word[i] == cpu_addr[18:3]) begin
            cpu_cache_hit = 1'b1;
            cpu_cache_hit_idx = 3'(i);
        end
    end

    cpu_cache_alloc = cpu_cache_rr;
    for (int i = 0; i < 8; i++) begin
        if (!cpu_cache_v[i])
            cpu_cache_alloc = 3'(i);
    end
end

// Miss redirect: engine waiting on a row neither slot holds nor is filling
wire miss_redirect = blit_want && !dma_ctl[3] && !hit0 && !hit1 &&
                     !((st == BURST_CMD || st == BURST_DATA) && fill_row == want_row);

// The row buffer's write port: one byte per clock while a beat is unpacked.
// The address is the same {slot, half, beat, byte} the read port uses, so a
// half-written beat simply is not marked valid yet.
assign rb_we    = (st == BURST_STORE);
assign rb_waddr = {fill_slot, fill_half, beat_cnt, store_b};
assign rb_wdata = fill_word[7:0];

always_ff @(posedge clk_sys) begin
    if (reset) begin
        st        <= IDLE;
        mem_rd    <= 1'b0;
        mem_we    <= 1'b0;
        beatv[0]  <= '0;
        beatv[1]  <= '0;
        tag[0]    <= '1;
        tag[1]    <= '1;
        lru       <= 1'b0;
        rows_left <= '0;
        cpuw_pend <= 1'b0;
        cpur_pend <= 1'b0;
        cpu_cache_v <= '0;
        cpu_cache_rr <= '0;
    end
    else begin
        // latch CPU channel requests (mutually exclusive with blitter use
        // of the window, but they may arrive while a prefetch burst runs)
        if (cpu_we) begin
            if (!cpuw_fast) begin
                cpuw_pend   <= 1'b1;
                cpu_addr_l  <= cpu_addr;
                cpu_wdata_l <= cpu_wdata;
            end
            if (cpu_cache_hit)
                cpu_cache_data[cpu_cache_hit_idx][cpu_addr[2:0]*8 +: 8] <=
                    cpu_wdata;
        end
        if (cpu_rd) begin
            if (cpu_cache_hit)
                cpu_q <= cpu_cache_data[cpu_cache_hit_idx][cpu_addr[2:0]*8 +: 8];
            else begin
                cpur_pend  <= 1'b1;
                cpu_addr_l <= cpu_addr;
            end
        end

        if (blit_want) begin
            last_req   <= want_row;
            last_req_v <= 1'b1;
        end

        // a new trigger restarts prefetch at the blit's first row
        // (colorfill blits read no GRAM — skip)
        if (trig_pulse) begin
            next_gy    <= pGY;
            rows_left  <= dma_ctl[3] ? 8'd0 :
                          (pH[6:0] == '0) ? 8'd128 : {1'b0, pH[6:0]};
            ydir_l     <= pH[7];
            beatv[0]   <= '0;
            beatv[1]   <= '0;
            lru        <= 1'b0;
            init_fills <= 2'd2;
            last_req_v <= 1'b0;
        end

        unique case (st)
            IDLE: begin
                if (cpuw_fast) begin
                    mem_we       <= 1'b1;
                    mem_addr     <= {3'd0, cpu_addr[18:3], 3'b000};
                    mem_din      <= {8{cpu_wdata}};
                    mem_be       <= 8'h01 << cpu_addr[2:0];
                    mem_burstcnt <= 8'd1;
                    st           <= CPUW;
                end
                else if (cpuw_pend) begin
                    mem_we       <= 1'b1;
                    mem_addr     <= {3'd0, cpu_addr_l[18:3], 3'b000};
                    mem_din      <= {8{cpu_wdata_l}};
                    mem_be       <= 8'h01 << cpu_addr_l[2:0];
                    mem_burstcnt <= 8'd1;
                    st           <= CPUW;
                end
                else if (cpur_pend) begin
                    mem_rd       <= 1'b1;
                    mem_addr     <= {3'd0, cpu_addr_l[18:3], 3'b000};
                    mem_be       <= 8'hFF;
                    mem_burstcnt <= 8'd1;
                    cpu_lane     <= cpu_addr_l[2:0];
                    st           <= CPUR;
                end
                else if (miss_redirect) begin
                    // self-heal: fetch the row the engine is actually asking for
                    fill_row  <= want_row;
                    fill_slot <= lru;
                    fill_half <= 1'b0;
                    tag[lru]  <= want_row;
                    beatv[lru] <= '0;
                    lru       <= ~lru;
                    last_fetch_tag <= want_row;
                    st        <= BURST_CMD;
                end
                else if (rows_left != 0 &&
                         (init_fills != 0 ||
                          (last_req_v && last_req == last_fetch_tag))) begin
                    // initial two rows fill freely; afterwards row k+1 only
                    // once the engine has reached row k (frees the lru slot)
                    fill_row  <= {banking[2:0], row_eff[7], row_eff[6:0]};
                    fill_slot <= lru;
                    fill_half <= 1'b0;
                    tag[lru]  <= {banking[2:0], row_eff[7], row_eff[6:0]};
                    beatv[lru] <= '0;
                    lru       <= ~lru;
                    last_fetch_tag <= {banking[2:0], row_eff[7], row_eff[6:0]};
                    if (init_fills != 0) init_fills <= init_fills - 2'd1;
                    next_gy   <= gcarry(next_gy);
                    rows_left <= rows_left - 8'd1;
                    st        <= BURST_CMD;
                end
            end

            BURST_CMD: begin
                mem_rd       <= 1'b1;
                // 128-byte half-row, as a PSRAM byte address:
                // {fill_row[10:7], fill_half, fill_row[6:0]} << 7
                mem_addr     <= {3'd0, fill_row[10:7], fill_half,
                                 fill_row[6:0], 7'b0};
                mem_be       <= 8'hFF;
                mem_burstcnt <= 8'd16;
                beat_cnt     <= '0;
                st           <= BURST_DATA;
            end

            BURST_DATA: begin
                if (!mem_busy) mem_rd <= 1'b0;
                if (mem_dout_ready) begin
                    fill_word <= mem_dout;
                    store_b   <= 3'd0;
                    st        <= BURST_STORE;
                end
            end

            BURST_STORE: begin
                // The beat is in hand and the burst (if any) is already
                // accepted, so the strobe has done its job. Dropping it here
                // also keeps a finished burst from being re-commanded by the
                // stale address while these eight clocks run.
                mem_rd    <= 1'b0;
                fill_word <= {8'h00, fill_word[63:8]};
                store_b   <= store_b + 3'd1;
                if (store_b == 3'd7) begin
                    beatv[fill_slot][{fill_half, beat_cnt}] <= 1'b1;
                    beat_cnt <= beat_cnt + 4'd1;
                    if (beat_cnt == 4'd15) begin
                        if (!fill_half) begin
                            fill_half <= 1'b1;
                            st <= BURST_CMD;
                        end
                        else st <= IDLE;
                    end
                    else st <= BURST_DATA;
                end
            end

            CPUW: begin
                if (!mem_busy) begin
                    mem_we    <= 1'b0;
                    if (!cpu_we)
                        cpuw_pend <= 1'b0;
                    st        <= IDLE;
                end
            end

            CPUR: begin
                if (!mem_busy) begin
                    mem_rd <= 1'b0;
                    st     <= CPUR_WAIT;
                end
            end

            CPUR_WAIT: begin
                if (mem_dout_ready) begin
                    cpu_q                         <= mem_dout[cpu_lane*8 +: 8];
                    cpu_cache_v[cpu_cache_alloc]  <= 1'b1;
                    cpu_cache_word[cpu_cache_alloc] <= cpu_addr_l[18:3];
                    cpu_cache_data[cpu_cache_alloc] <= mem_dout;
                    cpu_cache_rr                  <= cpu_cache_alloc + 3'd1;
                    cpur_pend                     <= 1'b0;
                    st                            <= IDLE;
                end
            end

            default: st <= IDLE;
        endcase
    end
end

endmodule
