# dryrun_tcl.tcl - exercise a Vivado Tcl script's CONTROL FLOW without Vivado.
#
# Vivado scripts in this repo are written here and run on someone else's machine, so a
# syntax slip or a bad branch costs a round trip. This harness stubs the Vivado command
# set with no-ops and sources the script under plain tclsh, which catches:
#   * syntax errors and unbalanced braces/brackets
#   * accidental command substitution - `[Synth 8-3352]` inside a double-quoted puts is
#     a COMMAND CALL in Tcl, not literal text (this one really happened)
#   * bad part-selection / fallback logic, guards that never fire, wrong source order
#
# It does NOT check that the Vivado commands themselves are correct - the stubs accept
# anything. It checks that the script gets as far as calling them, with the arguments
# you meant.
#
# Usage:
#   tclsh synth/ooc/dryrun_tcl.tcl <kit-path> <script.tcl> [CDC]
# e.g.
#   tclsh synth/ooc/dryrun_tcl.tcl ~/aws-fpga-f2 synth/ooc/synth_cl_bsw_f2.tcl
#   tclsh synth/ooc/dryrun_tcl.tcl ~/aws-fpga-f2 synth/ooc/synth_cl_bsw_f2.tcl 1
#
# Override the simulated environment before sourcing if you want a different case:
#   PARTS  - glob patterns of "installed" parts (default: only xcku5p*, i.e. the
#            interesting case where xcvu47p is ABSENT and the fallback must work)
#   WNS    - slack that get_property reports, to exercise the verdict branches

if {![info exists ::PARTS]} { set ::PARTS {xcku5p*} }
if {![info exists ::WNS]}   { set ::WNS -0.42 }

set ::READS {}
set ::CALLS {}

proc close_design {args}  {}
proc close_project {args} {}
proc get_parts {args} {
    set p [lindex $args end]
    foreach pat $::PARTS { if {[string match $pat $p]} { return $p } }
    return {}
}
proc read_verilog {args} { lappend ::READS [lindex $args end] }
proc synth_design {args}          { lappend ::CALLS "synth_design $args";   puts ">> synth_design $args" }
proc set_msg_config {args}        { puts ">> set_msg_config $args" }
proc get_msg_config {args}        { return 0 }
proc report_utilization {args}    { puts ">> report_utilization $args" }
proc report_timing_summary {args} { puts ">> report_timing_summary $args" }
proc create_clock {args}     {}
proc opt_design {args}       {}
proc place_design {args}     {}
proc phys_opt_design {args}  {}
proc route_design {args}     {}
proc get_ports {args}        { return clk }
proc get_timing_paths {args} { return path0 }
proc get_property {args}     { return $::WNS }
proc get_cells {args}        { return {} }
proc get_clocks {args}       { return {} }
proc get_nets {args}         { return {} }
proc get_pins {args}         { return {} }

set ::KIT [lindex $argv 0]
set script [lindex $argv 1]
if {[llength $argv] > 2 && [lindex $argv 2] ne ""} { set ::CDC [lindex $argv 2] }

source $script

puts ">> sources read: [llength $::READS]"
foreach f $::READS { puts ">>    [file tail $f]" }
