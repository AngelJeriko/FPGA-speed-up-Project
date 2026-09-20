# cl_timing_user_cdc.xdc
# -----------------------------------------------------------------------------
# Timing constraints for the TWO-CLOCK (CDC) variant of cl_bsw_top, where bsw_top runs
# on AWS_CLK_GEN's clk_extra_a1 (125 MHz) instead of the Shell's fixed 250 MHz
# clk_main_a0. scripts/f2/stage_cl_project.sh installs this as
# $CL_DIR/build/constraints/cl_timing_user.xdc when staged with --clk-gen.
#
# Do NOT use it for the single-clock build: there is no second domain, and these
# constraints would match nothing (which is silent, not an error).
#
# WHAT NEEDS CONSTRAINING, and why the RTL alone is not enough:
#   * The two clocks are unrelated, so every path between them must be excluded from
#     normal setup/hold analysis, or the tools will try to close a crossing that has no
#     phase relationship and fail (or, worse, "succeed" by chance on one build).
#   * But excluding them outright leaves the wide payload buses completely unconstrained,
#     and the router is then free to give them arbitrary delay. bsw_kernel_cdc's safety
#     argument assumes the payload arrives within about one destination clock period of
#     being launched. set_max_delay -datapath_only re-imposes exactly that bound while
#     still ignoring the clock relationship.
#   * The toggle handshake flops carry ASYNC_REG in the RTL, which keeps each 2-flop
#     synchroniser placed tightly together. That is a placement property, not a timing
#     one, so it is expressed there rather than here.
#
# >>> VERIFY ON THE FIRST BUILD: the clock OBJECT names below. `clk_main_a0` is the
# >>> Shell's and is stable, but the generated clock out of AWS_CLK_GEN's MMCM may be
# >>> auto-named. Run `report_clocks` after synthesis and correct CLK_K_NAME if needed.
# >>> A constraint that matches nothing fails SILENTLY - it does not error - so check
# >>> the counts printed at the bottom of this file rather than assuming.
# -----------------------------------------------------------------------------

set CLK_A_NAME clk_main_a0
set CLK_K_NAME clk_extra_a1

set clk_a [get_clocks -quiet $CLK_A_NAME]
set clk_k [get_clocks -quiet $CLK_K_NAME]

if {[llength $clk_a] == 0 || [llength $clk_k] == 0} {
    puts "CRITICAL WARNING: cl_timing_user_cdc.xdc could not find both clocks"
    puts "  '$CLK_A_NAME' -> [llength $clk_a] match(es)"
    puts "  '$CLK_K_NAME' -> [llength $clk_k] match(es)"
    puts "  Run report_clocks and fix CLK_A_NAME / CLK_K_NAME. The CDC is UNCONSTRAINED."
} else {
    # 1. The domains are asynchronous. No phase relationship exists to time against.
    set_clock_groups -asynchronous -group $clk_a -group $clk_k

    # 2. Re-bound the quasi-static payload and result crossings. -datapath_only asks for
    #    pure net+logic delay and ignores clock skew, which is the right question for a
    #    crossing whose launch and capture edges are unrelated. The bound is one full
    #    destination period: the data is guaranteed stable for far longer than that.
    set per_k [get_property -quiet PERIOD $clk_k]
    set per_a [get_property -quiet PERIOD $clk_a]
    if {$per_k eq ""} { set per_k 8.000 }
    if {$per_a eq ""} { set per_a 4.000 }

    # A -> K: query_hold / target_hold / cfg_hold / restart_hold feed bsw_top directly.
    set a2k [get_cells -quiet -hier -filter \
        {NAME =~ *u_bsw/query_hold_reg* || NAME =~ *u_bsw/target_hold_reg* || \
         NAME =~ *u_bsw/cfg_hold_reg*   || NAME =~ *u_bsw/restart_hold_reg*}]
    # K -> A: result_k_q is sampled by the A-domain state machine.
    set k2a [get_cells -quiet -hier -filter {NAME =~ *u_bsw/result_k_q_reg*}]

    if {[llength $a2k] > 0} {
        set_max_delay -datapath_only -from $a2k -to $clk_k $per_k
    } else {
        puts "CRITICAL WARNING: cl_timing_user_cdc.xdc matched NO A->K payload registers."
    }
    if {[llength $k2a] > 0} {
        set_max_delay -datapath_only -from $k2a -to $clk_a $per_a
    } else {
        puts "CRITICAL WARNING: cl_timing_user_cdc.xdc matched NO K->A result registers."
    }

    puts "cl_timing_user_cdc.xdc: async clock groups set; \
A->K payload regs = [llength $a2k], K->A result regs = [llength $k2a]"
}
