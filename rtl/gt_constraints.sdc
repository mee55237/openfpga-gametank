# ---------------------------------------------------------------------------
# GameTank core constraints.
#
# rtl/apf_constraints.sdc is Analogue's and says not to edit it. It already
# declares clk_74a, clk_74b and bridge_spiclk and calls derive_pll_clocks, so
# every PLL output is a clock object before this file is read. That is why
# nothing here re-declares a clock: a second create_clock on the same pin is a
# duplicate-clock error in TimeQuest, not a stricter constraint.
#
# The design has four clock domains:
#
#   clk_74a / clk_74b / bridge_spiclk   74.25 MHz    the Pocket's APF fabric
#   clk_core                            28.636 MHz   the console (pll_console 0)
#   clk_audio                           12.27 MHz    APU, when it is used
#                                                    (pll_console 1 -- not
#                                                    instantiated on this build)
#   clk_pix / clk_pix_90                2.250 MHz    the picture link (pll_video)
#
# NO CROSSING BETWEEN THESE IS A SYNCHRONOUS TRANSFER. Every one is a toggle or
# a level through two flops, or a dual-clock RAM whose pointers cross as gray
# codes:
#
#   * clk_74a -> clk_core: the cartridge loader's words and addresses are
#     written on the fabric clock and published by a gray-coded pointer that
#     clk_core reads only through two flops; the controller vector is latched
#     the same way; run_core is a level through two flops; pll_locked_raw is
#     sampled through two flops in clk_74a before anything reads it.
#   * clk_core -> clk_74a: the loader's idle/level flags and the save-state
#     buffer's write pointer come back the same way. The state buffer is a
#     true-dual-port RAM whose ports sit on the two clocks; its gray pointers
#     are the crossing.
#   * clk_core -> clk_pix: gt_video's frame_tog, wr_page and rd_page are
#     toggles sampled through two flops (tog_s1, wr_s1, ...) and v[] is
#     registered on the video side. The framebuffer is a dual-clock RAM, so
#     there is no register path between the domains.
#   * clk_pix -> clk_core: nothing. The picture never steers the machine.
#
# So the domains are asynchronous to each other, and only paths INSIDE a domain
# are timed. The previous grouping got this wrong: it put clk_74a and every PLL
# output except the audio mclk in ONE group, so TimeQuest timed the
# console -> video synchronisers as if they had to make a single-cycle transfer.
# The nearest edge pair of 28.636 and 2.250 MHz is 3.840 ns apart and the path
# into gt_video|tog_s1 takes 27.75 ns, which is where the fit's video-clock
# -25.876 ns came from -- a two-flop crossing that has a whole 444 ns video
# period to settle, reported as a failing single-cycle path.
#
# clk_pix and clk_pix_90 stay in the SAME group on purpose: the video link is
# DDR, launched on one edge and captured on the other, so those two are a
# genuinely synchronous pair and their skew is what has to be right.
# ---------------------------------------------------------------------------

# --- which clock is where ---------------------------------------------------
#
# THE GROUPS BELOW WERE NOT BEING APPLIED AT ALL (2026-10-24). The previous
# spelling built the command in a variable and handed it to `eval`, and it
# tested each group with `llength`. Neither works on a TimeQuest collection:
# `llength` of a collection is not its size (the same trap the Minicube64 fit
# notes record -- the command is `get_collection_size`), and `eval` re-parses
# the argument string, where a generated clock's own name (`...|vcoph[0]`)
# reads as a command substitution. The result was a fit whose report says the
# opposite of what this file says: `ap_core.sta.summary` listed 222,908 timed
# transfers from clk_74a into the console clock and a -9.3 ns setup slack on a
# 34.9 ns clock, i.e. every two-flop synchroniser in the core was constrained
# to make a single-cycle transfer between two unrelated clocks.
#
# So the groups are written out literally, each one a `get_clocks` call in the
# `-group` position: no variables, no `eval`, nothing that re-parses a clock
# name. The only test is `get_collection_size`, and it guards the whole command
# so a build that does not instantiate one of the PLLs skips the grouping
# instead of failing the SDC.

# `get_collection_size` is the command that counts a TimeQuest collection, but
# it is asked through `catch` so an older TimeQuest that only has `llength`
# still reads this file instead of aborting the whole SDC.
proc gt_group_size {pattern} {
    set c [get_clocks -nowarn $pattern]
    if {[catch {get_collection_size $c} n]} {
        set n [llength $c]
    }
    return $n
}

if {[gt_group_size {clk_74a}] > 0 &&
    [gt_group_size {clk_74b}] > 0 &&
    [gt_group_size {bridge_spiclk}] > 0 &&
    [gt_group_size {*pll_console*}] > 0 &&
    [gt_group_size {*pll_video*}] > 0} {
    set_clock_groups -asynchronous \
        -group [get_clocks -nowarn {clk_74a}] \
        -group [get_clocks -nowarn {clk_74b}] \
        -group [get_clocks -nowarn {bridge_spiclk}] \
        -group [get_clocks -nowarn {*pll_console*}] \
        -group [get_clocks -nowarn {*pll_video*}]
}

derive_clock_uncertainty
