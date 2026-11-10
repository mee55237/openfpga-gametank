//============================================================================
//  gt_nvram -- the 32 KB save RAM on a Flash2M_RAM32K cartridge.
//
//  THE HARDWARE. A RAM32K cart is a 2 MB flash part plus a 32 KB
//  battery-backed SRAM (gte.cpp: MemoryRead_Flash2M / MemoryWrite). The 6502
//  sees the SRAM in two 16 KB halves at $8000-$BFFF when the 74HC595's bit 7
//  is clear; bit 6 picks the half:
//
//      offset = (address & $3FFF) | ((bank_mask & $40) << 8)
//
//  $C000-$FFFF stays the flash fixed bank whether bit 7 is set or not. The
//  console side of that is rtl/cart.sv; this file is only the storage.
//
//  TWO BUSES, TWO CLOCKS. The Pocket's Save data slot reads and writes the
//  same 32 KB at launch and shutdown (clk_74a), while the 6502 reads a byte at
//  a time (clk_core). It is the same slot (0x0200_0000) that holds the 2 MB
//  cartridge image on a flash cart: the core routes it here only when the
//  cartridge is a RAM32K, and the Dataslot ID/Size Table reports 32 KB for it
//  so the OS writes a 32 KB `.sav`. The array is therefore a true dual-port
//  RAM: 8,192 words of 32 bits, with a byte lane on the 6502 side.
//
//  WHY 32 BITS AND NOT 8. The bridge transfers whole 32-bit words; the 6502
//  transfers bytes. A 32-bit array lets the APF side move four bytes per
//  clock and the console side write one byte by selecting its lane, so
//  neither side needs a width converter or a multi-cycle shim. Both read
//  ports are registered and read continuously; consumers sample a few
//  clocks after the address settles anyway (the bridge waits four cycles in
//  ST_READ_0, and the 6502 has an eight-clock bus window), so no read
//  handshake is needed.
//
//  WHY AN EXPLICIT altsyncram (2026-11-04). The first version described the
//  array with two always blocks, one per clock. That is not legal Verilog --
//  the same variable may not be driven by two processes -- and Quartus says so
//  on the first real compile:
//
//      Error (10028): Can't resolve multiple constant drivers for net
//      "mem[0][31]" at gt_nvram.sv(102)
//
//  The simulator had accepted it (and the clear did run), but the hardware
//  build never did. M10K is physically a true dual-port RAM, so the two write
//  ports are real; the honest way to get them is to instantiate the dual-port
//  primitive instead of hoping inference bridges two clocks. Both ports keep
//  one cycle of read latency, exactly as the inferred version was written
//  (unregistered address, registered output), so no consumer changes.
//
//  POWER-UP IS ZERO in the array itself -- Quartus initialises M10K to zero,
//  like the emulator's BSS (`cartridge_state.save_ram` starts zeroed). The
//  `.sav` slot is declared with bit 5 (data.json parameters 0x24), so APF
//  initialises a slot that has no file yet to 0xFF up to size_maximum -- and
//  that is 2 MB, which rtl/core_top.v's `nv_size_ok` refuses whole on a RAM32K
//  cart (a real SRAM save is exactly 32 KB). The array therefore keeps these
//  zeros; a game must treat them as "nothing saved yet", exactly as it treats
//  a battery-backed part's undefined first bytes on hardware.
//
//  A NEW CARTRIDGE ZEROES IT TOO (2026-11-04). Power-up is not the only way a
//  cartridge arrives: loading another one from the core menu streams slot 1
//  into the same core, and the array is not part of that download. Without a
//  clear, the new game reads the PREVIOUS game's save wherever its own `.sav`
//  does not cover the array -- and on a RAM32K game whose save is missing, or
//  is an old 2 MB image save (refused whole), that is all 32 KB of it. The
//  clear starts on the first word of a slot-1 stream and takes 8,192 clk_74a
//  (~110 us at 74.25 MHz). It finishes long before the Save slot can move:
//  the OS has to read the .sav off the card after the cartridge transfer, and
//  the console is held by `dl_wait` for the cartridge itself anyway. The clear
//  therefore owns port A for that window; a save write cannot arrive in it.
//============================================================================

`default_nettype none

module gt_nvram (
    // ---- console side (clk_core) -----------------------------------------
    input  logic        clk_core,
    input  logic [14:0] cpu_addr,     // byte address, 0..32767
    output wire  [7:0]  cpu_q,        // byte at cpu_addr
    input  logic        cpu_we,       // one-cycle pulse
    input  logic [7:0]  cpu_wdata,

    // ---- Pocket data-slot side (clk_74a) ---------------------------------
    input  logic        clk_74a,
    input  logic [12:0] ap_addr,      // 32-bit word address, 0..8191
    output wire  [31:0] ap_q,
    input  logic        ap_we,        // one-cycle pulse
    input  logic [31:0] ap_wdata,
    input  logic        clr          // one-cycle pulse: a new cartridge
);

// ---------------------------------------------------------------------------
// The clear walks the array once, one 32-bit word per clk_74a. It borrows
// port A's write port rather than driving the array from a second process.
// ---------------------------------------------------------------------------
logic [12:0] clr_idx = 13'd0;
logic        clr_run = 1'b0;

always_ff @(posedge clk_74a) begin
    if (clr) begin
        clr_run <= 1'b1;
        clr_idx <= 13'd0;
    end else if (clr_run) begin
        clr_idx <= clr_idx + 13'd1;
        if (clr_idx == 13'd8191)
            clr_run <= 1'b0;
    end
end

// During the clear the write port carries zeros; otherwise it carries the
// bridge's word. Port A is registered internally by the RAM, not here.
wire [12:0] ram_a_addr = (clr | clr_run) ? clr_idx : ap_addr;
wire [31:0] ram_a_data = (clr | clr_run) ? 32'd0    : ap_wdata;
wire        ram_a_we   =  clr | clr_run | ap_we;

// The 6502 writes one byte: the lane selects it, the replicated data fills it.
wire [12:0] ram_b_addr = cpu_addr[14:2];
wire [31:0] ram_b_data = {4{cpu_wdata}};
wire        ram_b_we   = cpu_we;
wire [3:0]  ram_b_be   = 4'b0001 << cpu_addr[1:0];

// The lane is registered beside the RAM's own read register so it describes
// the same byte the read produced, even if the CPU address changes while a
// read is in flight.
logic [1:0] cpu_lane;

always_ff @(posedge clk_core)
    cpu_lane <= cpu_addr[1:0];

wire [31:0] ram_q_a;
wire [31:0] ram_q_b;

assign ap_q  = ram_q_a;
assign cpu_q = ram_q_b[cpu_lane*8 +: 8];

/* ONE CLOCK OF READ LATENCY ON BOTH PORTS, BY TWO DIFFERENT ROUTES.
 *
 * altsyncram's register parameters accept only CLOCK0 or CLOCK1 -- there is no
 * "UNREGISTERED" value, and the defaults are CLOCK1. So port B's address, data,
 * write enable and byte enables are registered (the defaults, left unnamed) and
 * its OUTPUT is not, which still puts the byte one clock after the address, as
 * rtl/cart.sv expects. The registered write enable means a 6502 byte write
 * lands on the clock after its strobe; the 6502 holds address and data for the
 * whole bus cycle, so the byte written is the byte intended.
 *
 * Port A has no input-register parameters at all; only OUTDATA_REG_A exists.
 * Its inputs are unregistered and its output is registered, so the bridge's
 * read is one clock too, and the clear writes on the clock it is presented.
 *
 * THIS COST THREE COMPILES (2026-11-04), EACH NAMING THE RULE.
 *  1. "UNREGISTERED" on the port B parameters is rejected outright: the legal
 *     values are CLOCK0|CLOCK1. They are left at their CLOCK1 default.
 *  2. OLD_DATA is rejected by the Cyclone V RAM block in bidir_dual_port mode
 *     (the megafunction lists it, the primitive does not): "uses an
 *     unsupported value for parameter port_a_read_during_write_mode".
 *     The value used below is NEW_DATA_NO_NBE_READ, which is the default of
 *     both the megafunction and the Cyclone V primitive (verified in
 *     altsyncram_info.xml and cyclonev_ram_block_info.xml), so no legal-value
 *     or combination rule can reject it. Neither port depends on what a
 *     collision returns: the clear runs with the console held and the Save
 *     slot not started, and a 6502 read never coincides with its own write,
 *     which lands a clock after the strobe. */
altsyncram #(
    .clock_enable_input_a      ("BYPASS"),
    .clock_enable_input_b      ("BYPASS"),
    .clock_enable_output_a     ("BYPASS"),
    .clock_enable_output_b     ("BYPASS"),
    .init_file                 ("UNUSED"),
    .intended_device_family    ("Cyclone V"),
    .lpm_type                  ("altsyncram"),
    .numwords_a                (8192),
    .numwords_b                (8192),
    .operation_mode            ("BIDIR_DUAL_PORT"),
    .outdata_aclr_a            ("NONE"),
    .outdata_aclr_b            ("NONE"),
    .outdata_reg_a             ("CLOCK0"),
    .outdata_reg_b             ("UNREGISTERED"),
    .power_up_uninitialized    ("FALSE"),
    .read_during_write_mode_port_a ("NEW_DATA_NO_NBE_READ"),
    .read_during_write_mode_port_b ("NEW_DATA_NO_NBE_READ"),
    .width_a                   (32),
    .width_b                   (32),
    .width_byteena_a           (4),
    .width_byteena_b           (4),
    .widthad_a                 (13),
    .widthad_b                 (13)
) ram (
    .clock0       (clk_74a),
    .clock1       (clk_core),
    .address_a    (ram_a_addr),
    .address_b    (ram_b_addr),
    .data_a       (ram_a_data),
    .data_b       (ram_b_data),
    .wren_a       (ram_a_we),
    .wren_b       (ram_b_we),
    .byteena_a    (4'hF),
    .byteena_b    (ram_b_be),
    .q_a          (ram_q_a),
    .q_b          (ram_q_b),
    .aclr0        (1'b0),
    .aclr1        (1'b0),
    .addressstall_a (1'b0),
    .addressstall_b (1'b0),
    .clocken0     (1'b1),
    .clocken1     (1'b1),
    .clocken2     (1'b1),
    .clocken3     (1'b1),
    .rden_a       (1'b1),
    .rden_b       (1'b1),
    .eccstatus    ()
);

endmodule

`default_nettype wire
