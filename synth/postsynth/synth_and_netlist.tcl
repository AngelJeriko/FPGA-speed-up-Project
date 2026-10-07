# synth_and_netlist.tcl -- STEP 0 + the netlist for STEP 2, in one run.
#
#   vivado -mode batch -source synth/postsynth/synth_and_netlist.tcl
#
# Run it from the REPO ROOT (it locates everything relative to its own path, but
# vivado.log lands in the cwd and the message histogram reads it from there).
#
# WHY THIS SCRIPT EXISTS
# ---------------------------------------------------------------------------
# Every correctness claim we have about bsw_top rests on Verilator, which compiles
# SystemVerilog to C++. It therefore CANNOT see the class of bug the user is asking
# about: code that simulates fine but that a synthesizer either rejects, or -- far
# worse -- silently builds into different hardware (inferred latches, multi-driven
# nets, X-insensitive comparisons, reliance on simulator zero-init). We have been
# bitten by exactly this before: a real synthesis run once threw ~147k
# multi-driven-net warnings on RTL Verilator passed clean.
#
# Synthesis is the AUTHORITY on what is buildable. So this script does three jobs:
#
#   1. Reports the environment (version, licence, which parts are actually installed)
#      so we stop guessing about it.
#   2. Synthesizes bsw_top out-of-context and histograms every warning by message ID.
#      A clean run here answers most of the "Verilator accepted something the board
#      can't run" worry BEFORE any simulation.
#   3. Writes a funcsim netlist -- the gate/LUT/flop-level Verilog that synthesis
#      actually produced -- which is what STEP 2 simulates in XSIM against the same
#      E. coli vectors. That is the closest functional proxy for the FPGA that can
#      be reached without a board.
#
# It does NOT place and route. No timing claims come out of this; impl_bsw_top_f2.tcl
# already owns that question. Expect a few minutes, not tens of minutes.

catch {close_design}
catch {close_project}

set here [file dirname [file normalize [info script]]]
set root [file normalize $here/../..]
set rtl  $root/rtl
set out  $here/out
file mkdir $out

puts ""
puts "#############################################################"
puts "### STEP 0: synthesize bsw_top + emit funcsim netlist"
puts "#############################################################"
puts ""
puts "--- environment ---"
puts "  vivado version : [version -short]"
puts "  repo root      : $root"
puts "  output dir     : $out"

# Licence: a BASIC/no-licence install still synthesizes free parts, but it is worth
# recording, because it is the usual reason a large device is missing.
if {[catch {
    set feats {}
    foreach f [get_license_features -quiet] { lappend feats $f }
    if {[llength $feats] == 0} { puts "  licence feats  : (none reported)" } \
    else { puts "  licence feats  : [join [lrange $feats 0 9] {, }]" }
} msg]} { puts "  licence feats  : (query failed: $msg)" }

# ---------------------------------------------------------------------------
# Part selection. The exact F2 device first; then same-generation / same-speed-grade
# UltraScale+ proxies; then older families as a last resort.
#
# For THIS script's purpose a proxy is nearly as good as the real device. Whether a
# construct is synthesizable, and whether the netlist behaves like the RTL, are
# language-and-inference questions, not device questions. Only resource MAPPING
# (DSP vs LUT, BRAM shapes) and timing are device-specific, and we are claiming
# neither here.
# ---------------------------------------------------------------------------
set exact   "xcvu47p-fsvh2892-2-e"
set proxies {xcku5p-ffvb676-2-e xczu7ev-ffvc1156-2-e xcvu9p-flgb2104-2-i
             xcku040-ffva1156-2-e xc7v2000tfhg1761-2 xc7k410tffg900-2
             xc7k325tffg900-2 xc7a200tfbg484-2}

puts ""
puts "--- part inventory (what this install can actually target) ---"
foreach p [concat [list $exact] $proxies] {
    set n [llength [get_parts -quiet $p]]
    puts [format "  %-26s %s" $p [expr {$n > 0 ? "AVAILABLE" : "missing"}]]
}
# Also report family breadth, which tells us what is installable without guessing.
foreach fam {xcvu47p xcvu9p xcku5p xcku0 xczu7 xc7v xc7k xc7a} {
    set n [llength [get_parts -quiet ${fam}*]]
    puts [format "  family %-12s %d parts" $fam $n]
}

set part ""
set is_exact 0
# Accept a part either as `-tclargs <part>` or by `set PART <part>` beforehand.
if {![info exists ::PART] && [info exists ::argv] && [llength $::argv] > 0} {
    set ::PART [lindex $::argv 0]
}
if {[info exists ::PART] && $::PART ne ""} {
    set part $::PART
} elseif {[llength [get_parts -quiet $exact]] > 0} {
    set part $exact ; set is_exact 1
} else {
    foreach p $proxies { if {[llength [get_parts -quiet $p]] > 0} { set part $p ; break } }
}
if {$part eq "" || [llength [get_parts -quiet $part]] == 0} {
    puts ""
    puts "ERROR: no usable part installed. Add a device family via the Vivado"
    puts "       installer (Add Design Tools or Devices), or re-run with:"
    puts "         vivado -mode batch -source <this script> -tclargs <part>"
    return
}
puts ""
puts "### synthesizing on: $part   (exact F2 device: [expr {$is_exact ? {YES} : {NO -- proxy}}]) ###"

# Same file list, same order, as scripts/run_sim.sh uses for tb_bsw_ext. bsw_pkg.sv
# is a package and must be first. bsw_axis_adapter.sv is deliberately absent: it is
# not in bsw_top's hierarchy, it wraps it.
set files {bsw_pkg.sv bsw_score_matrix.sv bsw_pe.sv bsw_systolic_array.sv
           bsw_max_tracker.sv bsw_ctrl_fsm.sv bsw_top.sv}

if {[catch {
    create_project -in_memory -part $part -force
    foreach f $files { read_verilog -sv $rtl/$f }
    # OOC: no I/O buffers inserted, so the netlist's ports stay plain wires and the
    # testbench can drive them directly.
    synth_design -top bsw_top -part $part -mode out_of_context
    # A clock is needed only so report_timing_summary has something to say; this is
    # NOT a timing measurement and the period is not a target.
    create_clock -name clk -period 4.0 [get_ports clk]

    report_utilization -hierarchical -file $out/bsw_top_util.rpt
    report_timing_summary -max_paths 3 -file $out/bsw_top_timing_rough.rpt

    # ---- the artifact STEP 2 needs ----
    write_verilog -mode funcsim -force $out/bsw_top_funcsim.v
} msg]} {
    puts ""
    puts "##### SYNTHESIS FAILED #####"
    puts $msg
    puts "##### paste everything above back #####"
    return
}

# ---------------------------------------------------------------------------
# Inferred latches and multi-driven nets are the two findings that would directly
# vindicate the user's concern, so surface them explicitly rather than leaving them
# buried in the warning histogram.
# ---------------------------------------------------------------------------
puts ""
puts "--- red flags (these are the Verilator-invisible failure modes) ---"
set nlatch 0
catch { set nlatch [llength [get_cells -quiet -hier -filter {PRIMITIVE_TYPE =~ REGISTER.latch.*}]] }
puts [format "  inferred latches        : %d %s" $nlatch [expr {$nlatch == 0 ? "(good)" : "<<< INVESTIGATE"}]]
set ndsp   [llength [get_cells -quiet -hier -filter {REF_NAME =~ DSP*}]]
set nbram  [llength [get_cells -quiet -hier -filter {REF_NAME =~ RAMB*}]]
set nuram  [llength [get_cells -quiet -hier -filter {REF_NAME =~ URAM*}]]
set nff    [llength [get_cells -quiet -hier -filter {PRIMITIVE_TYPE =~ REGISTER.*}]]
set nlut   [llength [get_cells -quiet -hier -filter {PRIMITIVE_TYPE =~ LUT.*}]]
puts [format "  LUT / FF / DSP / BRAM / URAM : %d / %d / %d / %d / %d" $nlut $nff $ndsp $nbram $nuram]

# The netlist's module header settles whether the packed structs and packed arrays on
# bsw_top's ports (bsw_config_t cfg_i, base_t [1023:0] target_i, bsw_result_t result_o)
# flattened to plain vectors, and at what widths. The STEP 2 testbench wiring depends
# entirely on this, so print it.
puts ""
puts "--- funcsim netlist module header (decides the STEP 2 wiring) ---"
set nl $out/bsw_top_funcsim.v
if {[file exists $nl]} {
    puts "  file: $nl  ([file size $nl] bytes)"
    set fh [open $nl r]
    set n 0 ; set inmod 0
    while {[gets $fh line] >= 0} {
        if {[string match "*module bsw_top*" $line]} { set inmod 1 }
        if {$inmod} {
            puts "  | $line"
            incr n
            if {[string match "*);*" $line] || $n > 60} { break }
        }
    }
    close $fh
} else {
    puts "  ERROR: netlist was not written."
}

# Histogram the warnings: thousands of lines collapse into a handful of causes
# (160 PEs means one sloppy line becomes 160 warnings).
catch {
    set ::LOG [file normalize vivado.log]
    if {[file exists $::LOG]} { source $root/synth/ooc/summarize_msgs.tcl }
}

puts ""
puts "#############################################################"
puts "### DONE. Paste back: the part inventory, the red flags, the"
puts "### netlist module header, and the message summary."
puts "### Keep $out/bsw_top_funcsim.v on this machine -- STEP 2 uses it."
puts "#############################################################"
