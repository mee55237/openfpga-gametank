//
// bridge host/target command handler
// 2022 Analogue
//

// mapped to 0xF8xxxxxx on bridge
// the spec is loose enough to allow implementation with either
// block rams and a soft CPU, or simply hard logic with some case statements.
//
// the implementation spec is documented, and depending on your application you
// may want to completely replace this module. this is only one of many
// possible ways to accomplish the host/target command system and data table.
//
// this module should always be clocked by a direct clock input and never a PLL,
// because it should report PLL lock status
//

module core_bridge_cmd (

input   wire            clk,
output  reg             reset_n,

input   wire            bridge_endian_little,
input   wire    [31:0]  bridge_addr,
input   wire            bridge_rd,
output  reg     [31:0]  bridge_rd_data,
input   wire            bridge_wr,
input   wire    [31:0]  bridge_wr_data,

// all these signals should be synchronous to clk
// add synchronizers if these need to be used in other clock domains
input   wire            status_boot_done,           // assert when PLLs lock and logic is ready
input   wire            status_setup_done,          // assert when core is happy with what's been loaded into it
input   wire            status_running,             // assert when pocket's taken core out of reset and is running

output  reg             dataslot_requestread,
output  reg     [15:0]  dataslot_requestread_id,
input   wire            dataslot_requestread_ack,
input   wire            dataslot_requestread_ok,
/* THERE IS NO "NOTHING TO SAVE" ANSWER, AND RESULT 1 IS NOT ONE
 * (2026-11-09, from the panel). `[0080]` was briefly answered with result 1,
 * "not allowed ever" (Host/Target Commands: 0 ready, 1 not allowed ever,
 * 2 check later), for a session that had written nothing since its save was
 * loaded -- the idea being that the OS would then leave the `.sav` alone and
 * the quit would cost nothing. It does leave the file alone, and it also
 * reports `error in framework: slot 2 denied` on the way out: 1 is the
 * protocol's "this slot can never be read", not "nothing changed". A slot
 * that answers it is a broken slot to the OS, so this core never does. The
 * read-out always runs; its cost is the size table's, and that is why a
 * flash cartridge that saved nothing declares ZERO bytes -- "size of the data
 * slot. Zero if the slot is not used" -- and a session that did save declares
 * only the head plus the tail below its lowest written byte. */

output  reg             dataslot_requestwrite,
output  reg     [15:0]  dataslot_requestwrite_id,
output  reg     [31:0]  dataslot_requestwrite_size,
input   wire            dataslot_requestwrite_ack,
input   wire            dataslot_requestwrite_ok,

output  reg             dataslot_update,
output  reg     [15:0]  dataslot_update_id,
output  reg     [31:0]  dataslot_update_size,

output  reg             dataslot_allcomplete,

output  reg     [31:0]  rtc_epoch_seconds,
output  reg     [31:0]  rtc_date_bcd,
output  reg     [31:0]  rtc_time_bcd,
output  reg             rtc_valid,

input   wire            savestate_supported,
input   wire    [31:0]  savestate_addr,
input   wire    [31:0]  savestate_size,
input   wire    [31:0]  savestate_maxloadsize,

output  reg             osnotify_inmenu,
// OS Notify (0x00B0) bit 1. NOT IN THE SPECIFICATION: Analogue's Host/Target
// Commands page defines bit 0 only ("the user is in the OS menus and the core
// has lost focus") and says a core may ignore it. The framework's stock file
// exposes only bit 0 as well; this tree decoded bit 1 because the sibling core
// on the panel does (`osnotify_pause_req <= host_20[1];`). NOTHING READS IT
// (2026-10-17): as a pause it was a latch with no release, and its bit 0
// sibling froze the panel after every state load (spec 21.11). It is kept
// exported so a documented use can be added without touching this file.
output  reg             osnotify_pause_req,

output  reg             savestate_start,        // core should detect rising edge on this,
input   wire            savestate_start_ack,    // and then assert ack for at least 1 cycle
input   wire            savestate_start_busy,   // assert constantly while in progress after ack
input   wire            savestate_start_ok,     // assert continuously when done, and clear when new process is started
input   wire            savestate_start_err,    // assert continuously on error, and clear when new process is started

output  reg             savestate_load,
input   wire            savestate_load_ack,
input   wire            savestate_load_busy,
input   wire            savestate_load_ok,
input   wire            savestate_load_err,

input   wire            target_dataslot_read,       // rising edge triggered
input   wire            target_dataslot_write,
input   wire            target_dataslot_getfile,
input   wire            target_dataslot_openfile,
// 0x0188 Data slot flush. NOT USED BY THE FRAMEWORK'S OWN WRITEBACK PATH:
// a file the core wrote with 0x0184 is only guaranteed to be on the card
// after this, because the host buffers it (see rtl/gt_save_file.sv).
input   wire            target_dataslot_flush,

output  reg             target_dataslot_ack,        // asserted upon command start until completion
output  reg             target_dataslot_done,       // asserted upon command finish until next command is issued
output  reg     [2:0]   target_dataslot_err,        // contains result of command execution. zero is OK

// 0x0188 record. `seen` says the host answered the last flush; when it is 0
// the flush was sent and nothing came back, which is a fact about the
// firmware and not about the file (see TARG_ST_WAITRESULT_DSO).
output  reg             target_dataslot_flush_seen,
output  reg     [2:0]   target_dataslot_flush_result,

input   wire    [15:0]  target_dataslot_id,         // parameters for each of the read/reload/write commands
input   wire    [31:0]  target_dataslot_slotoffset,
input   wire    [31:0]  target_dataslot_bridgeaddr,
input   wire    [31:0]  target_dataslot_length,

input   wire    [31:0]  target_buffer_param_struct, // bus address of the memory region APF will fetch additional parameter struct from
input   wire    [31:0]  target_buffer_resp_struct,  // bus address of the memory region APF will write its response struct to
                                                    // this should be mapped by the developer, the buffer is not implemented in this file

input   wire    [9:0]   datatable_addr,
input   wire            datatable_wren,
input   wire    [31:0]  datatable_data,
output  wire    [31:0]  datatable_q

);

// handle endianness
    reg     [31:0]  bridge_wr_data_in;
    reg     [31:0]  bridge_rd_data_out;

    wire endian_little_s;
synch_3 s01(bridge_endian_little, endian_little_s, clk);

always @(*) begin
    bridge_rd_data <= endian_little_s ? {
        bridge_rd_data_out[7:0],
        bridge_rd_data_out[15:8],
        bridge_rd_data_out[23:16],
        bridge_rd_data_out[31:24]
    } : bridge_rd_data_out;

    bridge_wr_data_in <= endian_little_s ? {
        bridge_wr_data[7:0],
        bridge_wr_data[15:8],
        bridge_wr_data[23:16],
        bridge_wr_data[31:24]
    } : bridge_wr_data;
end


// minimalistic approach here -
// keep the commonly used registers in logic, but data table in BRAM.
// implementation could be changed quite a bit for a more advanced use case

// host

    reg     [31:0]  host_0;
    reg     [31:0]  host_4 = 'h20; // host cmd parameter data at 0x20
    reg     [31:0]  host_8 = 'h40; // host cmd response data at 0x40

    reg     [31:0]  host_20; // parameter data
    reg     [31:0]  host_24;
    reg     [31:0]  host_28;
    // 0x2C is not decoded: the host may write it, nothing in this core reads
    // it, and a register nothing reads is 32 flops of nothing (2026-11-09).

    reg     [31:0]  host_40; // response data
    reg     [31:0]  host_44;
    reg     [31:0]  host_48;
    // 0x4C has no producer: there is no third response word. The read below
    // answers 0 for it explicitly, which is what an undriven register gave
    // (2026-11-09).

    reg             host_cmd_start;
    reg     [15:0]  host_cmd_startval;
    reg     [15:0]  host_cmd;
    reg     [15:0]  host_resultcode;

localparam  [3:0]   ST_IDLE         = 'd0;
localparam  [3:0]   ST_PARSE        = 'd1;
localparam  [3:0]   ST_WORK         = 'd2;
localparam  [3:0]   ST_DONE_OK      = 'd13;
localparam  [3:0]   ST_DONE_CODE    = 'd14;
localparam  [3:0]   ST_DONE_ERR     = 'd15;
    reg     [3:0]   hstate;

/* NO HOST COMMAND MAY GO UNANSWERED (2026-11-02).
 *
 * Every branch of `ST_PARSE` below can wait for something the CORE has to
 * produce: `[0080]`/`[0082]` for the slot handshake, `[00A0]`/`[00A4]` for a
 * savestate engine. The OS, meanwhile, is parked in the middle of one bridge
 * transaction until the reply word lands, and it does not time it out.
 *
 * A quit is exactly this sequence: `[0010 Reset Enter]`, then `[0080]` for the
 * nonvolatile slot, then `[008F]`, then the menu. So one reply that never comes
 * is a Pocket that sits on a black screen until it is power-cycled -- which is
 * the panel's own description of this core's quit, and the reason the `.sav` is
 * never written: the OS never gets as far as the write-back.
 *
 * The deadline is 2^22 clk_74a, 57 ms. The slowest thing a command waits on is
 * a savestate capture; the data-slot handshake has its own 0.88 ms cap. 57 ms is
 * far longer than any of them and far shorter than a person notices, so a real
 * answer always wins and the timeout only fires for an answer that was never
 * coming. On expiry the command is answered as if it had succeeded: a shutdown
 * that reads out a stale window still writes a file, and a file beats a hang. */
/* LONG ENOUGH FOR A REAL `[0080]` (`1 in 4 words`, 2026-11-06). The save
 * slot answers `[0080]` only once a whole 8 KB window of the image is
 * resident (rtl/gt_save_slot.sv), which is ~1.3 ms in sim and several times
 * that on the part, because the model there has no wait states. The old
 * 56 ms bound is close enough to that to turn a slow fill into a command
 * error, and a command error is what the OS acts on. 113 ms is still a
 * watchdog: nothing this core does legitimately takes longer. */
localparam  [22:0]  HOST_WD_MAX     = 23'h7F_FFFF;
    reg     [22:0]  hstate_wd;

// target

    reg     [31:0]  target_0;
    reg     [31:0]  target_4 = 'h20; // target cmd parameter data at 0x20 
    reg     [31:0]  target_8 = 'h40; // target cmd response data at 0x40 

    reg     [31:0]  target_20; // parameter data
    reg     [31:0]  target_24;
    reg     [31:0]  target_28;
    reg     [31:0]  target_2C;

    // 0x40-0x4C hold the TARGET's response words, which the host writes and a
    // core reads when it has target commands that return data. This one has
    // none (its [0184/0188/0190/0192 answers go back through host_40/44), so
    // the four registers were write-only and are gone (2026-11-09).

localparam  [3:0]   TARG_ST_IDLE        = 'd0;
localparam  [3:0]   TARG_ST_READYTORUN  = 'd1;
localparam  [3:0]   TARG_ST_DATASLOTOP  = 'd2;
localparam  [3:0]   TARG_ST_WAITRESULT_RTR  = 'd14;
localparam  [3:0]   TARG_ST_WAITRESULT_DSO  = 'd15;
    reg     [3:0]   tstate;

/* A TARGET COMMAND THE HOST NEVER ANSWERS MUST NOT WEDGE THE CHANNEL
 * (2026-11-02).
 *
 * `TARG_ST_WAITRESULT_DSO` has no exit but the host writing "ok" into
 * `target_0`. Every core derived from this template gets away with it because
 * none of them issues target commands; this one does (rtl/gt_save_file.sv), and
 * the host does not answer them while it is busy elsewhere -- in particular
 * while its own menu is up, which is the moment a quit begins. A command that
 * goes unanswered there leaves the framework in that state for the rest of the
 * session: `target_0` keeps the "cm" marker of a command the host never ran, no
 * later command is ever issued, and the core spends the shutdown looking like
 * it is in the middle of a transfer. That is a core the OS cannot close
 * cleanly.
 *
 * 2^26 clk_74a is 0.90 s. The longest command this core issues reads 1,920
 * bytes across the bridge, about 0.4 ms, so this is two thousand times the work
 * it is protecting -- and it is short enough that a quit is never held up by
 * more than the timeout. On expiry the command is dropped exactly as a failed
 * one is: `target_dataslot_done` with error 5, so the module that asked for it
 * gives up instead of waiting for a `done` that is not coming. */
localparam  [26:0]  TARG_WD_MAX      = 27'h400_0000;

/* 0x0188 IS NOT WAITED ON LIKE THE OTHERS (2026-11-01).
 *
 * The documented reply to a flush is `ok` with "all bytes written ok", and on
 * a real card a flush is also where the host updates the file's length on SD,
 * so it can legitimately take seconds. Both the reference dumper and this core
 * have only ever seen it go unanswered, and a command that is still
 * outstanding blocks every target command after it -- including the one that
 * hands the data slot back, which must happen or the shutdown writeback lands
 * on the file that was just written.
 *
 * So a flush is fired into a fixed 0.23 s window and nothing waits on it: a
 * reply that arrives inside the window is recorded, and one that does not is
 * forgotten. The window is also a settle period -- `target_0` is cleared on the
 * way out, so a reply arriving late cannot be read as the result of whatever
 * command comes next. */
localparam  [26:0]  FLUSH_WD         = 27'h100_0000;
    reg     [26:0]  targ_wd;
    reg             flushing = 1'b0;

/* THE HOST SAYS GOODBYE TWICE BEFORE `reset_n` EVER DROPS (2026-11-02).
 *
 * The block below abandons an in-flight target command when the host resets
 * us, and on the panel that was still one command too late. "Exiting the core
 * goes black and I have to power cycle" is the framework closing while a `cm`
 * marker is standing in target_0: the OS has already stopped running target
 * commands, the marker never clears, and the core it is trying to unload looks
 * like it is mid-transfer forever.
 *
 * `reset_n` is not the first goodbye. Before it the host does two things this
 * core can see, and each means the same thing -- "I am not servicing you now":
 *
 *   * the menu opens (`osnotify_inmenu`, [00B0]). Quit is chosen from that
 *     menu, so this is the last moment before a shutdown. It is also the state
 *     the reference dumper's 1.8 s settle exists for;
 *   * the data-slot phase ends (`dataslot_allcomplete`, [008F]). The OS sends
 *     it when it has finished with every slot, which at a shutdown is right
 *     after it has read the Save slot out.
 *
 * Both are taken on the RISING EDGE, not the level. `allcomplete` stays high
 * for the rest of the session after an ordinary load, and treating that as an
 * abort would kill the next command the save writer issues. A rising edge is
 * the event; the level is just the state afterwards.
 *
 * The result is the same as the reset path: the marker is cleared, the issuer
 * is told nobody answered (error 7), and the block returns to idle. Nothing is
 * left for the framework to wait on. */
    reg             dso_q    = 1'b0;
    reg             inmenu_q = 1'b0;

    /* THE ABORT IS ONLY EVER THIS CORE'S OWN COMMANDS (2026-11-02).
     *
     * It was every state, and that is a launch that cannot start. The two
     * commands above are ours -- `[0180`/`[0184`/`[0190`/`[0192`, issued by
     * rtl/gt_save_file.sv. The other two are the FRAMEWORK's:
     * `TARG_ST_READYTORUN`/`TARG_ST_WAITRESULT_RTR` are the `cm 0140` that tells
     * Analogue OS this core is ready to run.
     *
     * `dataslot_allcomplete` is `[008F`, and the OS sends it when it has finished
     * with every data slot -- at a LAUNCH that is after the cartridge and the
     * save have both landed, which is after `status_setup_done` has already put
     * the ready-to-run marker into `target_0`. So on every launch the abort fired
     * on the marker, cleared `target_0`, and the framework had nothing left to
     * run: "error in framework: core not ready to run", and the core never
     * starts. That is the panel's report, word for word, and it is new with this
     * abort.
     *
     * The note at TARG_WD_MAX above records the same failure from the watchdog's
     * side a day earlier -- the ready-to-run marker is the one thing in this file
     * that must never be withdrawn, by any mechanism. So the abort is gated to
     * the states where the command really is ours and really can be abandoned. */
    wire            targ_cmd_mine = (tstate == TARG_ST_DATASLOTOP) ||
                                    (tstate == TARG_ST_WAITRESULT_DSO);
    wire            targ_abort = targ_cmd_mine &&
                                 ((dataslot_allcomplete & ~dso_q) |
                                  (osnotify_inmenu     & ~inmenu_q));

    reg             status_setup_done_1, status_setup_done_queue;
    reg             target_dataslot_read_1, target_dataslot_read_queue;
    reg             target_dataslot_write_1, target_dataslot_write_queue;
    reg             target_dataslot_getfile_1, target_dataslot_getfile_queue;
    reg             target_dataslot_openfile_1, target_dataslot_openfile_queue;
    reg             target_dataslot_flush_1, target_dataslot_flush_queue;

// Power-up value of reset_n: ONE.
//
// Two separate things depend on it, and they are worth keeping apart:
//
//   * STATUS. core_top drives `status_running` from this register, and the
//     framework's Request Status (host command 0x0000) reports `running` from
//     it. The sibling core that runs on this hardware (C:/Code/Wasm4/
//     VexiiRiscv) powers the same register up 1, so the OS sees the same
//     answer from both cores. Powering up 1 is what makes that match.
//
//   * RESET. This used to be how the machine was released, and that was the
//     bug: the OS only sends [0010 Reset Enter]/[0011 Reset Exit] around a
//     data-slot load when that slot's data.json `parameters` has bit6 set
//     (Analogue's Parameters Bitmap, "Reset core while loading"), and this
//     package's Cartridge slot is "0x01" -- bit0 "user-reloadable" only. So
//     0x0011 NEVER ARRIVES at launch, and a core that needs it to leave reset
//     produces no picture at all. core_top no longer gates the machine on this
//     register's level at all: it uses the FALLING EDGE (see `reset_core_edge`
//     there), so the machine boots whichever way this powers up and whatever
//     the OS does.
//
// Reset Enter still does what it says: the falling edge restarts the machine
// for a fixed window, with or without a following Reset Exit.
//
// The sim knob MC64_SIM_RESETN_LOW powers this up 0 and leaves it there --
// silicon's worst case if the power-up value were ever dropped. The boot
// harness runs in that mode too, so that class of failure cannot come back.
initial begin
`ifdef MC64_SIM_RESETN_LOW
    reset_n <= 1'b0;
`else
    reset_n <= 1'b1;
`endif
    dataslot_requestread <= 0;
    dataslot_requestwrite <= 0;
    dataslot_update <= 0;
    dataslot_allcomplete <= 0;
    rtc_valid <= 0;
    savestate_start <= 0;
    savestate_load <= 0;
    osnotify_inmenu <= 0;
    osnotify_pause_req <= 0;

    status_setup_done_queue <= 0;
    target_dataslot_read_queue <= 0;
    target_dataslot_write_queue <= 0;
    target_dataslot_getfile_queue <= 0;
    target_dataslot_openfile_queue <= 0;
    target_dataslot_flush_queue <= 0;
    target_dataslot_ack <= 0;
    target_dataslot_done <= 0;
    target_dataslot_err <= 0;
    targ_wd <= 0;
end

always @(posedge clk) begin

    // detect a rising edge on the input signal
    // and flag a queue that will be cleared later
    status_setup_done_1 <= status_setup_done;
    target_dataslot_read_1 <= target_dataslot_read;
    target_dataslot_write_1 <= target_dataslot_write;
    target_dataslot_getfile_1 <= target_dataslot_getfile;
    target_dataslot_openfile_1 <= target_dataslot_openfile;
    target_dataslot_flush_1 <= target_dataslot_flush;

    if(status_setup_done & ~status_setup_done_1) begin
        status_setup_done_queue <= 1;
    end
    if(target_dataslot_read & ~target_dataslot_read_1) begin
        target_dataslot_read_queue <= 1;
    end
    if(target_dataslot_write & ~target_dataslot_write_1) begin
        target_dataslot_write_queue <= 1;
    end
    if(target_dataslot_getfile & ~target_dataslot_getfile_1) begin
        target_dataslot_getfile_queue <= 1;
    end
    if(target_dataslot_openfile & ~target_dataslot_openfile_1) begin
        target_dataslot_openfile_queue <= 1;
    end
    if(target_dataslot_flush & ~target_dataslot_flush_1) begin
        target_dataslot_flush_queue <= 1;
    end

    b_datatable_wren <= 0;
    b_datatable_addr <= bridge_addr[11:2];   // (addr >> 2), low 10 bits

    if(bridge_wr) begin
        casex(bridge_addr)
        32'hF8xx00xx: begin
            case(bridge_addr[7:0])
            8'h0: begin
                host_0 <= bridge_wr_data_in; // command/status
                // check for command
                if(bridge_wr_data_in[31:16] == 16'h434D) begin
                    // host wants us to do a command
                    host_cmd_startval <= bridge_wr_data_in[15:0];
                    host_cmd_start <= 1;
                end
            end
            8'h20: host_20 <= bridge_wr_data_in; // parameter data regs
            8'h24: host_24 <= bridge_wr_data_in;
            8'h28: host_28 <= bridge_wr_data_in;
            endcase
        end
        32'hF8xx10xx: begin
            case(bridge_addr[7:0])
            8'h0: target_0 <= bridge_wr_data_in; // command/status
            8'h4: target_4 <= bridge_wr_data_in; // parameter data pointer
            8'h8: target_8 <= bridge_wr_data_in; // response data pointer
            endcase
        end
        32'hF8xx2xxx: begin
            b_datatable_wren <= 1;
        end
        endcase
    end
    if(bridge_rd) begin
        casex(bridge_addr)
        32'hF8xx00xx: begin
            case(bridge_addr[7:0])
            8'h0: bridge_rd_data_out <= host_0; // command/status
            8'h4: bridge_rd_data_out <= host_4; // parameter data pointer
            8'h8: bridge_rd_data_out <= host_8; // response data pointer
            8'h40: bridge_rd_data_out <= host_40; // response data regs
            8'h44: bridge_rd_data_out <= host_44;
            8'h48: bridge_rd_data_out <= host_48;
            8'h4C: bridge_rd_data_out <= 32'd0; // no third response word
            endcase
        end
        32'hF8xx10xx: begin
            case(bridge_addr[7:0])
            8'h0: bridge_rd_data_out <= target_0;
            8'h4: bridge_rd_data_out <= target_4;
            8'h8: bridge_rd_data_out <= target_8;
            8'h20: bridge_rd_data_out <= target_20; // parameter data regs
            8'h24: bridge_rd_data_out <= target_24;
            8'h28: bridge_rd_data_out <= target_28;
            8'h2C: bridge_rd_data_out <= target_2C;
            endcase
        end
        32'hF8xx2xxx: begin
            bridge_rd_data_out <= b_datatable_q;

        end
        endcase
    end





    // host > target command executer
    if (hstate == ST_PARSE) begin
        if (hstate_wd != HOST_WD_MAX) hstate_wd <= hstate_wd + 23'd1;
    end else
        hstate_wd <= 23'd0;

    case(hstate)
    ST_IDLE: begin

        dataslot_requestread <= 0;
        dataslot_requestwrite <= 0;
        dataslot_update <= 0;
        savestate_start <= 0;
        savestate_load <= 0;

        // there is no queueing. pocket will always make sure any outstanding host
        // commands are finished before starting another
        if(host_cmd_start) begin
            host_cmd_start <= 0;
            // save the command in case it gets clobbered later
            host_cmd <= host_cmd_startval;
            hstate <= ST_PARSE;
        end

    end
    ST_PARSE: begin
        // overwrite command semaphore with busy flag
        host_0 <= {16'h4255, host_cmd};

        if (hstate_wd == HOST_WD_MAX) begin
            /* THE DEADLINE PASSED. Answer, do not wait. (see HOST_WD_MAX) */
            host_resultcode <= 16'h0000;
            hstate          <= ST_DONE_CODE;
        end else case(host_cmd)
        16'h0000: begin
            // Request Status
            host_resultcode <= 1; // default: booting
            if(status_boot_done) begin
                host_resultcode <= 2; // setup
                if(status_setup_done) begin
                    host_resultcode <= 3; // idle
                end else if(status_running) begin
                    host_resultcode <= 4; // running
                end
            end
            hstate <= ST_DONE_CODE;
        end
        16'h0010: begin
            // Reset Enter
            reset_n <= 0;
            hstate <= ST_DONE_OK;
        end
        16'h0011: begin
            // Reset Exit
            reset_n <= 1;
            hstate <= ST_DONE_OK;
        end
        16'h0080: begin
            // Data slot request read
            dataslot_allcomplete <= 0;
            dataslot_requestread <= 1;
            dataslot_requestread_id <= host_20[15:0];
            // THE REQUEST MUST BE VISIBLE BEFORE ITS ACK IS BELIEVED
            // (2026-11-05). `dataslot_requestread` is registered, so on
            // the first cycle in this state it is still 0 -- and the ack
            // is a wire that is `save_req_read ? ps_ack : 1'b1` in
            // rtl/core_top.v, i.e. it collapses to 1 exactly while the
            // request is invisible. Sampled alone, it answered `[0080]`
            // on entry and the OS started reading a window the save slot
            // had not armed yet: the first words of the .sav came back
            // zero (sim/gt/tb_core_ss.cpp's `probe_reqread` check).
            // Waiting for the request to be one cycle old is what makes
            // the slot's own "word 0 is resident" ack the thing the OS
            // waits on.
            if(dataslot_requestread && dataslot_requestread_ack) begin
                host_resultcode <= 0;
                if(!dataslot_requestread_ok) host_resultcode <= 2;
                hstate <= ST_DONE_CODE;
            end
        end
        16'h0082: begin
            // Data slot request write
            dataslot_allcomplete <= 0;
            dataslot_requestwrite <= 1;
            dataslot_requestwrite_id <= host_20[15:0];
            dataslot_requestwrite_size <= host_24;
            if(dataslot_requestwrite_ack) begin
                host_resultcode <= 0;
                if(!dataslot_requestwrite_ok) host_resultcode <= 2;
                hstate <= ST_DONE_CODE;
            end
        end
        16'h008A: begin
            // Data slot update (sent on deferload marked slots only)
            dataslot_update <= 1;
            dataslot_update_id <= host_20[15:0];
            dataslot_update_size <= host_24;
            hstate <= ST_DONE_OK;
        end
        16'h008F: begin
            // Data slot access all complete
            dataslot_allcomplete <= 1;
            hstate <= ST_DONE_OK;
        end
        16'h0090: begin
            // Real-time Clock Data
            // user logic should detect rising edge, it is not continuously updated
            rtc_valid <= 1;
            rtc_epoch_seconds <= host_20;
            rtc_date_bcd <= host_24;
            rtc_time_bcd <= host_28;
            hstate <= ST_DONE_OK;
        end
        16'h00A0: begin
            // Savestate: Start/Query
            host_40 <= savestate_supported;
            host_44 <= savestate_addr;
            host_48 <= savestate_size;

            host_resultcode <= 0;
            if(savestate_start_busy) host_resultcode <= 1;
            if(savestate_start_ok) host_resultcode <= 2;
            if(savestate_start_err) host_resultcode <= 3;

            if(host_20[0]) begin
                // Request Start!
                savestate_start <= 1;
                // stay in this state until ack'd
                if(savestate_start_ack) begin
                    hstate <= ST_DONE_CODE;
                end
            end else begin
                hstate <= ST_DONE_CODE;
            end
        end
        16'h00A4: begin
            // Savestate: Load/Query
            host_40 <= savestate_supported;
            host_44 <= savestate_addr;
            host_48 <= savestate_maxloadsize;

            host_resultcode <= 0;
            if(savestate_load_busy) host_resultcode <= 1;
            if(savestate_load_ok) host_resultcode <= 2;
            if(savestate_load_err) host_resultcode <= 3;

            if(host_20[0]) begin
                // Request Load!
                savestate_load <= 1;
                // stay in this state until ack'd
                if(savestate_load_ack) begin
                    hstate <= ST_DONE_CODE;
                end
            end else begin
                hstate <= ST_DONE_CODE;
            end
        end
        16'h00B0: begin
            // OS Notify: Menu State
            osnotify_inmenu     <= host_20[0];
            osnotify_pause_req  <= host_20[1];
            hstate <= ST_DONE_OK;
        end
        16'h00B1: begin
            // OS Notify: Cartridge Adapter. The Pocket sends this on EVERY
            // boot -- "will always be sent", per the command reference -- and
            // this core has no adapter to switch to. Answering it is the
            // difference between a documented no-op and an unknown-command
            // error (0xFFFF) sitting in the OS's command log on every launch.
            hstate <= ST_DONE_OK;
        end
        16'h00B2: begin
            // OS Notify: Docked State. Same shape: nothing here changes, but
            // the OS is told the core took it.
            hstate <= ST_DONE_OK;
        end
        16'h00B8: begin
            // OS Notify: Display Mode. RESPONSE: ONE WORD, and 16'h444D is
            // what lets a grayscale-only (LCD) mode be used at all -- the OS
            // refuses the mode if it cannot read that back. This core's picture
            // is already 24-bit colour with no dithering, so it can honestly
            // affirm grayscale by passing the colour channels through: the
            // response says "yes", which is true.
            //
            // The word goes in the command block's response area, 0x40, which
            // is also where 0x00A0 puts its `can create` bit. That is safe in
            // both directions: 0x00A0 and 0x00A4 rewrite 0x40 unconditionally
            // on every query, and 0x444D has bit 0 set, so even a stale value
            // still reads as "save states are supported".
            host_40 <= host_20[0] ? 32'h0000_444D : 32'h0000_0000;
            hstate <= ST_DONE_OK;
        end
        default: begin
            hstate <= ST_DONE_ERR;
        end
        endcase
    end
    ST_WORK: begin
        hstate <= ST_IDLE;
    end
    ST_DONE_OK: begin
        host_0 <= 32'h4F4B0000; // result code 0
        hstate <= ST_IDLE;
    end
    ST_DONE_CODE: begin
        host_0 <= {16'h4F4B, host_resultcode};
        hstate <= ST_IDLE;
    end
    ST_DONE_ERR: begin
        host_0 <= 32'h4F4BFFFF; // result code FFFF = unknown command
        hstate <= ST_IDLE;
    end
    endcase


    /* THE WATCHDOG COVERS THE DATA-SLOT COMMANDS AND NOTHING ELSE
     * (2026-11-01).
     *
     * It was written for 0x0180/0x0184/0x0190/0x0192 -- the file commands this
     * core issues, which the host can ignore -- but it was counted for ANY
     * state that was not idle, and that includes `TARG_ST_WAITRESULT_RTR`: the
     * `cm 0140` that tells the framework the core is ready to run.
     *
     * That one must never be withdrawn. On the panel the OS answers it while it
     * is still bringing the core up (reading the card, mapping the data slots),
     * and a launch that took longer than 0.90 s had its ready-to-run marker
     * cleared out from under it -- after which the framework can only report
     * "core not ready to run" and the core never starts. It is the one target
     * command that has no failure mode worth timing out: if the framework never
     * answers, it is not going to run the core either way.
     *
     * So the counter runs ONLY in the two data-slot states (see TARG_WD_MAX),
     * and RTR waits exactly as the template's does. That last clause was a lie
     * in the code for a week: this condition still listed
     * `TARG_ST_WAITRESULT_RTR`, so a launch slow enough to cross 0.90 s had its
     * marker withdrawn and re-offered while the framework was deciding whether
     * the core was ready -- the same panel message, from the same file, one
     * state over. RTR is out of the count now, and the state has no exit but
     * the host's `ok` (see TARG_ST_WAITRESULT_RTR). */
    if(tstate == TARG_ST_DATASLOTOP || tstate == TARG_ST_WAITRESULT_DSO) begin
        if(targ_wd != TARG_WD_MAX) targ_wd <= targ_wd + 27'd1;
    end else
        targ_wd <= 0;

    /* NOTHING MAY BE IN FLIGHT WHEN THE HOST RESETS US (2026-11-02).
     *
     * Quit begins with `[0010 Reset Enter]`, which drops `reset_n`. A target
     * command that was outstanding at that moment leaves `cm` sitting in the
     * target->host command register: the framework has already passed the point
     * where it runs one, so it never clears, and the core spends the shutdown
     * looking like it is in the middle of a transfer. That is not a state a core
     * gets closed cleanly from -- the reference dumper waits 1.8 s after its
     * last command for exactly this reason, and every earlier attempt at this
     * core's quit went black at the moment the OS started taking it down.
     *
     * So the reset wins over whatever is in flight: the marker is cleared, the
     * issuer is told (error 7, "nobody answered", which is distinct from any
     * result code the host itself uses), and the block goes back to idle. This
     * is also what makes a `[0010`-triggered slot load safe -- nothing is left
     * pointing at a struct in a core that is about to be reconfigured. */
    dso_q    <= dataslot_allcomplete;
    inmenu_q <= osnotify_inmenu;

    if(!reset_n || targ_abort) begin
        target_0             <= 32'h0;
        target_dataslot_err  <= 3'd7;
        target_dataslot_done <= (tstate != TARG_ST_IDLE);
        flushing             <= 1'b0;
        tstate               <= TARG_ST_IDLE;
        /* AND SO IS EVERYTHING WAITING BEHIND IT (2026-11-02).
         *
         * Clearing `tstate` alone does not stop the next command, it starts it:
         * the queues below are what the idle state reads, and they were left
         * untouched. So the reset that ends a shutdown handed the framework a
         * fresh `[0184` to run -- a target command arriving at the exact moment
         * the OS has stopped running them. That is a `cm` standing in `target_0`
         * for a core that is being unloaded, which is the quit that goes black.
         *
         * A queued command is the core's own request (rtl/gt_save_file.sv), so
         * dropping it costs a save and never a console -- and the writer already
         * treats "nobody answered" as "stop, do not retry". */
        target_dataslot_read_queue     <= 0;
        target_dataslot_write_queue    <= 0;
        target_dataslot_getfile_queue  <= 0;
        target_dataslot_openfile_queue <= 0;
        target_dataslot_flush_queue    <= 0;
    end
    // target > host command executer
    else case(tstate)
    TARG_ST_IDLE: begin

        target_dataslot_ack <= 0;
        flushing            <= 0;

        /* THE READY-TO-RUN MARKER YIELDS TO A COMMAND THIS CORE OWNS
         * (2026-11-02).
         *
         * `cm 0140` is written into `target_0` the moment `status_setup_done`
         * rises, and it then OWNS `target_0` until the framework answers it.
         * Every other target command this core can issue waits behind it. That
         * is harmless in a core that never issues one; this core writes the
         * `.sav` (rtl/gt_save_file.sv), so a marker the framework did not pick
         * up held the save for the whole session and the `.sav` stayed empty.
         *
         * Deferring it here costs nothing: the queue bit stays set and this
         * branch runs again as soon as the queued command has been answered. */
        if(status_setup_done_queue &&
           !(target_dataslot_read_queue   | target_dataslot_write_queue |
             target_dataslot_getfile_queue | target_dataslot_openfile_queue |
             target_dataslot_flush_queue)) begin
            status_setup_done_queue <= 0;
            tstate <= TARG_ST_READYTORUN;

        end else if(target_dataslot_read_queue) begin
            target_dataslot_read_queue <= 0;
            target_0[15:0] <= 16'h0180;

            target_20 <= target_dataslot_id;
            target_24 <= target_dataslot_slotoffset;
            target_28 <= target_dataslot_bridgeaddr;
            target_2C <= target_dataslot_length;

            tstate <= TARG_ST_DATASLOTOP;

        end else if(target_dataslot_write_queue) begin
            target_dataslot_write_queue <= 0;
            target_0[15:0] <= 16'h0184;

            target_20 <= target_dataslot_id;
            target_24 <= target_dataslot_slotoffset;
            target_28 <= target_dataslot_bridgeaddr;
            target_2C <= target_dataslot_length;
            
            tstate <= TARG_ST_DATASLOTOP;
            
        end else if(target_dataslot_getfile_queue) begin
            target_dataslot_getfile_queue <= 0;
            target_0[15:0] <= 16'h0190;
            
            target_20 <= target_dataslot_id;
            target_24 <= target_buffer_resp_struct; // pointer to the bram that will hold the response struct
                                                    // which will contain the requested filename before command completion
            tstate <= TARG_ST_DATASLOTOP;
            
        end else if(target_dataslot_openfile_queue) begin
            target_dataslot_openfile_queue <= 0;
            target_0[15:0] <= 16'h0192;
            
            target_20 <= target_dataslot_id;
            target_24 <= target_buffer_param_struct; // pointer to the bram that will hold the parameter struct
                                                     // which must contain the desired filename and flag/size before command execution
            tstate <= TARG_ST_DATASLOTOP;

        end else if(target_dataslot_flush_queue) begin
            target_dataslot_flush_queue <= 0;
            target_0[15:0] <= 16'h0188;

            target_20 <= target_dataslot_id;
            target_24 <= 32'h0;
            target_28 <= 32'h0;
            target_2C <= 32'h0;

            // per-flush: 0 until this one is answered
            target_dataslot_flush_seen   <= 0;
            target_dataslot_flush_result <= 0;
            flushing                     <= 1;

            tstate <= TARG_ST_DATASLOTOP;
        end
    end
    TARG_ST_READYTORUN: begin
        target_0 <= 32'h636D_0140;
        tstate <= TARG_ST_WAITRESULT_RTR;
    end
    TARG_ST_DATASLOTOP: begin
        target_0[31:16] <= 16'h636D;

        target_dataslot_done <= 0;
        target_dataslot_err <= 0;
        tstate <= TARG_ST_WAITRESULT_DSO;
    end
    TARG_ST_WAITRESULT_DSO: begin
        if(flushing) begin
            if(target_0[31:16] == 16'h6F6B) begin
                target_dataslot_flush_seen   <= 1;
                target_dataslot_flush_result <= target_0[2:0];
                target_0                     <= 32'h0; // swallowed, not a verdict
            end
            if(targ_wd == FLUSH_WD) begin
                target_0             <= 32'h0;
                target_dataslot_err  <= 3'd0;   // not a failure of anything
                target_dataslot_done <= 1;
                tstate               <= TARG_ST_IDLE;
            end
        end else if(targ_wd == TARG_WD_MAX) begin
            /* NOBODY ANSWERED, AND THAT IS NOT ONE OF THE HOST'S CODES (2026-11-02).
             *
             * This used to report 5, which is also the host's own "general
             * error" for `[0192]`. rtl/gt_save_file.sv cannot tell them apart,
             * and it behaved accordingly: it read "nobody answered" as "this
             * byte order was refused" and walked all eight of them, so ONE save
             * the host was not servicing became ~14 s of a target command
             * permanently in flight -- and a quit inside that window is a quit
             * with a command outstanding. 7 is unused by every documented
             * result code (0..5), so the writer can stop on the first silence
             * instead of retrying a search that cannot succeed. */
            target_0             <= 32'h0;
            target_dataslot_err  <= 3'd7;
            target_dataslot_done <= 1;
            tstate <= TARG_ST_IDLE;
        end else begin
            if(target_0[31:16] == 16'h6275) begin
                target_dataslot_ack <= 1;
            end
            if(target_0[31:16] == 16'h6F6B) begin
                // done
                // save result code
                target_dataslot_err <= target_0[2:0];
                // assert done
                target_dataslot_done <= 1;
                tstate <= TARG_ST_IDLE;
            end
        end
    end
    TARG_ST_WAITRESULT_RTR: begin
        /* THE MARKER IS NOT RE-OFFERED (2026-11-09).
         *
         * This state once had a watchdog that WITHDREW `cm 0140` and put it
         * back in the queue. The note above it already called that a mistake:
         * withdrawing the marker is the one thing that produces "error in
         * framework: core not ready to run", and the template's own RTR state
         * has no timeout at all.
         *
         * It stayed in the code because every later fix was measured against a
         * launch that fails for other reasons. What it does on a slow launch is
         * clean, and fatal: the marker is raised a few milliseconds after
         * configuration, while the OS is still streaming the cartridge and the
         * save -- 2 MB of slot data is well over 0.90 s -- and at 0.90 s this
         * branch zeroes `target_0`. The framework then looks at its target
         * register and sees no ready-to-run, whatever it was about to answer.
         * The marker is re-offered from idle, so it is absent for as little as
         * two clocks, but the framework's poll is not synchronised to this
         * clock, and a data-slot command queued behind it keeps it absent for
         * the length of that command. A race with a 2-clock window, run once
         * per launch, is a panel that fails some launches and not others.
         *
         * So there is no timeout here, exactly as in the template: the marker
         * stands until the host answers it, however long the launch takes. If
         * the framework never answers, it was never going to run the core. */
        if(target_0[31:16] == 16'h6F6B)
            tstate <= TARG_ST_IDLE;
    end
    endcase


end

    wire    [31:0]  b_datatable_q;
    reg     [9:0]   b_datatable_addr;
    reg             b_datatable_wren;

mf_datatable idt (
    .address_a      ( datatable_addr ),
    .address_b      ( b_datatable_addr ),
    .clock_a        ( clk ),
    .clock_b        ( clk ),
    .data_a         ( datatable_data ),
    .data_b         ( bridge_wr_data_in ),
    .wren_a         ( datatable_wren ),
    .wren_b         ( b_datatable_wren ),
    .q_a            ( datatable_q ),
    .q_b            ( b_datatable_q )
);


endmodule
