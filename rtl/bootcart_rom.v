//============================================================================
//  bootcart_rom -- the console's built-in cartridge, 32 KB at $8000-$FFFF.
//
//  A GameTank has no ROM of its own: with no cartridge in the slot, $8000-$FFFF
//  is whatever the wrapper puts on the cart bus, and the 65C02 fetches its
//  reset vector from $FFFC. rtl/gametank.sv takes that data on its cart_data
//  input, which rtl/core_top.v drives from this ROM until the OS hands over a
//  .gtr (rtl/cart.sv then takes the window once the image has filled PSRAM).
//
//  The image is the same one GameTank_MiSTer bakes into its wrapper
//  (refs/GameTank_MiSTer/GameTank.sv:176) and the same one tools/gt_sim.sh
//  boots: pads_demo.gtr, the manual pad check, which draws two rows of button
//  indicator blocks by writing the framebuffer directly. Regenerate with
//
//    hexdump -v -e '1/1 "%02X\n"' sim/testroms/pads_demo.gtr > rtl/bootcart.mem
//
//  Without it a Pocket with no cartridge open executes 0x00 (BRK) forever, the
//  framebuffer stays all zeroes, and the panel shows palette entry 0 -- #1A1A1A
//  -- over the whole 128x128 window: a picture that is dark grey and perfectly
//  in sync, which is exactly what it looked like on hardware.
//
//  One clock of read latency, matching the MiSTer wrapper's registered read:
//  the address is latched at one CPU strobe and the byte is read at the next,
//  eight clocks later.
//============================================================================

module bootcart_rom
(
    input  wire        clk,
    input  wire [14:0] addr,
    output reg  [7:0]  data
);

// Quartus resolves this relative to the project directory (rtl/), where the
// .qpf lives; Verilator does not need the file to lint.
reg [7:0] rom [0:32767];

initial $readmemh("bootcart.mem", rom);

always @(posedge clk)
    data <= rom[addr];

endmodule
