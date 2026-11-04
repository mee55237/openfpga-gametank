//============================================================================
//  Emulator-style framebuffer presentation.
//
//  GameTank software owns two 128x128 framebuffers and is allowed to recycle
//  a released page immediately. The desktop emulator samples VID_OUT_PAGE
//  once per host frame and presents an immutable image; directly scanning a
//  hardware page cannot reproduce that ownership model when a game flips and
//  starts drawing the old page during active video.
//
//  At the start of vertical blank, copy the currently requested 16 KiB page
//  through VRAM's read port into a dedicated display snapshot. The copy takes
//  16,386 CLK28 cycles including the synchronous-read pipeline, comfortably
//  inside the 29,056-cycle vertical blank. Active scanout only reads the
//  snapshot, so register transients and writes to either game-owned page can
//  never splice partial frames into the output.
//============================================================================

module frame_snapshot
(
    input  logic        clk,
    input  logic        reset,
    input  logic        vblank,
    input  logic        requested_page,

    output logic        source_page,
    output logic [13:0] source_addr,
    input  logic [7:0]  source_data,

    input  logic [13:0] scan_addr,
    output logic [7:0]  scan_data,

    /* High while the copy is running OR the snapshot is waiting for this
     * frame's page flip, so the scan port's other user (the picture's tail
     * fill, rtl/gametank.sv) knows when the read port is free. A snapshot read
     * during the copy could collide with the write at the same address, which
     * simple dual-port RAM does not define; and a tail read taken before the
     * new page is copied would fill the bottom rows from the previous page.
     */
    output logic        busy          // copy running, OR waiting for the vblank flip
);

/* HOW LONG TO WAIT FOR THE PAGE FLIP (2026-10-29).
 *
 * Sampling `requested_page` on the vblank edge copies the page the game is
 * about to recycle. A double-buffered game flips the page in its NMI handler
 * and then draws the next frame into the page it just released, so the copy
 * and those writes ran through the same 16 KB: the snapshot ended up part old
 * frame and part new one (Fishooter's right edge, 15 rows, was exactly the
 * boundary between the copy and the next frame's fill).
 *
 * The page that belongs in the snapshot is the one the game flips TO, and it
 * is already complete when the flip happens -- it was the back buffer for the
 * whole previous frame. So wait for that flip and copy it then; the game is
 * drawing the other page. A game that never flips (single framebuffer) still
 * gets its picture: the wait times out and copies the page it is displaying.
 */
localparam int HOLD_CLKS = 4096;   // 143 us; the whole vblank is 29,056 clocks

logic        waiting;
logic        copying;          // the 16 KB pass itself
logic [12:0] hold;

assign busy = waiting | copying;

logic [7:0] mem [0:16383];

logic        vblank_q;
logic        write_valid;
logic [13:0] write_addr;

always_ff @(posedge clk) begin
    // Same one-clock synchronous-read shape as VRAM's original video port.
    scan_data <= mem[scan_addr];

    if (write_valid)
        mem[write_addr] <= source_data;

    if (reset) begin
        vblank_q    <= 1'b0;
        copying     <= 1'b0;
        waiting     <= 1'b0;
        hold        <= '0;
        write_valid <= 1'b0;
        source_page <= 1'b0;
        source_addr <= '0;
        write_addr  <= '0;
    end
    else begin
        vblank_q <= vblank;

        // source_data is the byte requested one clock earlier from VRAM.
        write_valid <= copying;
        if (copying) begin
            write_addr <= source_addr;
            if (source_addr == 14'h3FFF)
                copying <= 1'b0;
            else
                source_addr <= source_addr + 14'd1;
        end

        // Start after the vblank edge has propagated to this module. The
        // first source byte is issued on the following clock, so no stale
        // pre-edge VRAM output is committed to the snapshot.
        if (vblank && !vblank_q) begin
            hold <= 13'(HOLD_CLKS);
            if (requested_page != source_page) begin
                // The game has already flipped; the new front page is the
                // one the frame just ended was drawn into.
                source_page <= requested_page;
                source_addr <= '0;
                copying     <= 1'b1;
                waiting     <= 1'b0;
                write_valid <= 1'b0;
            end
            else begin
                waiting     <= 1'b1;
                copying     <= 1'b0;
                write_valid <= 1'b0;
            end
        end
        else if (waiting) begin
            if (requested_page != source_page || hold == 13'd0) begin
                source_page <= requested_page;
                source_addr <= '0;
                copying     <= 1'b1;
                waiting     <= 1'b0;
                write_valid <= 1'b0;
            end
            else hold <= hold - 13'd1;
        end
    end
end

endmodule
