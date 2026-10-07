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

# Licence: not queried here. `get_license_features` does not exist in 2026.1, and
# Vivado already prints the licence in its own startup banner, e.g.
#   INFO: [Common 17-3922] A valid Vivado Design Suite BASIC license has been detected.
# A BASIC licence synthesizes the free device families fine; it is simply the usual
# reason a large device such as xcvu47p is absent from the install.

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
if {![info exists ::TOPMOD] && [info exists ::argv] && [llength $::argv] > 1} {
    set ::TOPMOD [lindex $::argv 1]
}
# NPE shrinks the PE array via a Verilog define. XSIM's BASIC licence tier refuses a
# design with more than 50,000 instances and the full 160-PE netlist has 166,514, so
# a narrower array is the only route to gate-level simulation on that licence.
# Vectors must then be restricted to qlen <= NPE (see
# scripts/filter_vectors_by_qlen.py), because bsw_ctrl_fsm correctly REJECTS a longer
# query with error=1 rather than computing a wrong answer.
if {![info exists ::NPE] && [info exists ::argv] && [llength $::argv] > 2} {
    set ::NPE [lindex $::argv 2]
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

# WHICH TOP? Default is bsw_top_flat, NOT bsw_top.
#
# The first real 2026.1 run settled this. `write_verilog -mode funcsim` SCALARIZES
# aggregate ports: bsw_top's `base_t [159:0] query_i` came out as 160 separate
# ports named \query_i[159] and so on, and `target_i` as 1024 more. The netlist
# therefore has ~1200 ports where the RTL had three, and no port called `query_i`
# exists for a testbench to bind to.
#
# bsw_top_flat wraps bsw_top in plain 1-D vector ports, which the writer keeps
# intact. It is continuous assignments only -- no logic, no state -- and it is
# verified transparent under Verilator (tb_bsw_ext_flat, same vectors, identical
# results, and shown to go red when the mapping is deliberately corrupted).
#
# Set TOPMOD to bsw_top to synthesize the bare core instead -- useful for area and
# warning checks, useless for simulation.
if {![info exists ::TOPMOD] || $::TOPMOD eq ""} { set ::TOPMOD bsw_top_flat }
set top $::TOPMOD
if {$top eq "bsw_top_flat"} { lappend files ../synth/postsynth/bsw_top_flat.sv }
puts "### top module: $top ###"

if {[catch {
    create_project -in_memory -part $part -force
    # Give the fileset rtl/ as an include path. Not needed by the current file set
    # (a `include resolves relative to the including file, and rtl/*.sv sit beside
    # bsw_pkg.sv), but a wrapper living outside rtl/ cannot resolve one -- which is
    # how the first bsw_top_flat run failed. Harmless where unnecessary.
    catch { set_property include_dirs [list $rtl] [current_fileset] }
    foreach f $files { read_verilog -sv $rtl/$f }
    # OOC: no I/O buffers inserted, so the netlist's ports stay plain wires and the
    # testbench can drive them directly.
    set defs {}
    if {[info exists ::NPE] && $::NPE ne ""} {
        lappend defs "BSW_FLAT_NPE=$::NPE"
        puts "### N_PE overridden to $::NPE -- vectors MUST have qlen <= $::NPE ###"
    }
    if {[llength $defs] > 0} {
        synth_design -top $top -part $part -mode out_of_context -verilog_define $defs
    } else {
        synth_design -top $top -part $part -mode out_of_context
    }
    # A clock is needed only so report_timing_summary has something to say; this is
    # NOT a timing measurement and the period is not a target.
    create_clock -name clk -period 4.0 [get_ports clk]

    report_utilization -hierarchical -file $out/${top}_util.rpt
    report_timing_summary -max_paths 3 -file $out/${top}_timing_rough.rpt

    # ---- the artifact STEP 2 needs ----
    write_verilog -mode funcsim -force $out/${top}_funcsim.v
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
# Count by REF_NAME, not PRIMITIVE_TYPE. Two traps, both hit on the first real run:
# PRIMITIVE_TYPE "LUT.*" matches nothing (Vivado spells it LUT.values.LUT6), and
# Unisim transformation splits each DSP48E2 into 9 sub-cells, so a DSP48E2 filter
# over-counts 140 DSPs as 1260. The authoritative figures are synth_design's own
# "Report Cell Usage" table; these are a cross-check of it.
set nlut   0
foreach k {LUT1 LUT2 LUT3 LUT4 LUT5 LUT6} {
    incr nlut [llength [get_cells -quiet -hier -filter "REF_NAME == $k"]]
}
set nff    0
foreach k {FDRE FDSE FDCE FDPE} {
    incr nff [llength [get_cells -quiet -hier -filter "REF_NAME == $k"]]
}
set ndsp   [llength [get_cells -quiet -hier -filter {REF_NAME == DSP48E2}]]
set nbram  [llength [get_cells -quiet -hier -filter {REF_NAME =~ RAMB*}]]
set nuram  [llength [get_cells -quiet -hier -filter {REF_NAME =~ URAM*}]]
puts [format "  LUT / FF / DSP / BRAM / URAM : %d / %d / %d / %d / %d" $nlut $nff $ndsp $nbram $nuram]
# ROUTE_STATUS is an IMPLEMENTATION property -- post-synthesis it may not exist at
# all, and an unknown property inside a -filter expression throws even with -quiet.
# So guard it, and treat the synthesis log as the primary signal: a genuinely
# multiply-driven net always produces a Synth warning, which the histogram below
# catches regardless of whether this query works.
set nmdrv -1
catch { set nmdrv [llength [get_nets -quiet -hier -filter {ROUTE_STATUS == MULTIDRIVEN}]] }
if {$nmdrv < 0} {
    puts "  multi-driven nets       : (not queryable post-synth; see warning histogram)"
} else {
    puts [format "  multi-driven nets       : %d %s" $nmdrv [expr {$nmdrv == 0 ? "(good)" : "<<< INVESTIGATE"}]]
}
set nbbox -1
catch { set nbbox [llength [get_cells -quiet -hier -filter {IS_BLACKBOX == 1}]] }
if {$nbbox < 0} {
    puts "  black boxes             : (not queryable; see Report BlackBoxes in the log)"
} else {
    puts [format "  black boxes             : %d %s" $nbbox [expr {$nbbox == 0 ? "(good)" : "<<< INVESTIGATE"}]]
}

# The netlist's module header settles whether the packed structs and packed arrays on
# bsw_top's ports (bsw_config_t cfg_i, base_t [1023:0] target_i, bsw_result_t result_o)
# flattened to plain vectors, and at what widths. The STEP 2 testbench wiring depends
# entirely on this, so print it.
puts ""
puts "--- funcsim netlist module header (decides the STEP 2 wiring) ---"
set nl $out/${top}_funcsim.v
if {[file exists $nl]} {
    puts "  file: $nl  ([file size $nl] bytes)"
    set fh [open $nl r]
    set n 0 ; set inmod 0
    while {[gets $fh line] >= 0} {
        if {[string match "*module $top*" $line]} { set inmod 1 }
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

# ---------------------------------------------------------------------------
# Write a COMPACT summary to a file.
#
# WHY: the console output of this run is tens of thousands of lines -- the DSP
# inference tables alone are hundreds, and a 160-PE instance-area table is
# hundreds more. A terminal scrollback buffer will not hold it, and asking anyone
# to copy it out of a console is a waste of their time. Everything decisive about
# this run fits in well under a page, so write that page out.
#
# (The full log is never lost either: `vivado -mode batch` always writes the
# complete console output to vivado.log in the current directory.)
# ---------------------------------------------------------------------------
catch {
    set sf $out/step0_summary.txt
    set fh [open $sf w]
    puts $fh "bsw STEP 0 summary -- [clock format [clock seconds] -format {%Y-%m-%d %H:%M:%S}]"
    puts $fh "vivado        : [version -short]"
    puts $fh "part          : $part   (exact F2 device: [expr {$is_exact ? {YES} : {NO -- proxy}}])"
    puts $fh "top module    : $top"
    puts $fh "N_PE          : [expr {[info exists ::NPE] && $::NPE ne "" ? $::NPE : "160 (default)"}]"
    puts $fh ""
    puts $fh "parts available:"
    foreach pp [concat [list $exact] $proxies] {
        if {[llength [get_parts -quiet $pp]] > 0} { puts $fh "  $pp" }
    }
    puts $fh ""
    puts $fh "red flags:"
    puts $fh "  inferred latches  : $nlatch"
    puts $fh "  multi-driven nets : $nmdrv"
    puts $fh "  black boxes       : $nbbox"
    puts $fh ""
    puts $fh "resources:"
    puts $fh "  LUT  : $nlut"
    puts $fh "  FF   : $nff"
    puts $fh "  DSP48E2 : $ndsp"
    puts $fh "  BRAM : $nbram    URAM : $nuram"
    puts $fh "  total cells (leaf) : [llength [get_cells -quiet -hier -filter {IS_PRIMITIVE == 1}]]"
    puts $fh "  NOTE: XSIM BASIC licence refuses >50,000 INSTANCES. The 160-PE netlist"
    puts $fh "        reported 166,514 and was rejected. If xsim refuses this one, its"
    puts $fh "        error prints the exact count -- lower NPE and re-run."
    puts $fh ""

    # Error / warning tallies straight out of the log, plus one example per ID.
    set nerr 0 ; set ncrit 0
    array set wc {} ; array set wex {}
    if {[file exists $::LOG]} {
        set lh [open $::LOG r] ; set ltxt [read $lh] ; close $lh
        foreach line [split $ltxt "\n"] {
            if {[string match "ERROR:*" $line]} { incr nerr }
            if {[string match "CRITICAL WARNING:*" $line]} { incr ncrit }
            if {[string match "WARNING:*" $line]} {
                set id "(unlabelled)"
                regexp {\[([A-Za-z_]+ [0-9]+-[0-9]+)\]} $line -> id
                incr wc($id)
                if {![info exists wex($id)]} { set wex($id) [string trim $line] }
            }
        }
    }
    # Count multi-driven findings ONLY from real tool messages.
    #
    # The naive grep over the whole log reported 7 on a run whose netlist query said
    # 0, which is a false alarm: `vivado -mode batch` ECHOES the sourced script into
    # the log, so this file's own comments and puts strings containing the phrase get
    # counted as findings. Requiring a WARNING:/ERROR: prefix excludes echoed script
    # text, since a real finding is always a prefixed tool message.
    set nmd_log 0
    if {[info exists ltxt]} {
        foreach line [split $ltxt "\n"] {
            if {!([string match "WARNING:*" $line] ||
                  [string match "CRITICAL WARNING:*" $line] ||
                  [string match "ERROR:*" $line])} { continue }
            if {[string match -nocase "*multiply driven*" $line] ||
                [string match -nocase "*multi-driven*" $line]} { incr nmd_log }
        }
    }
    puts $fh "  multi-driven in tool messages : $nmd_log"
    puts $fh ""
    puts $fh "messages:"
    puts $fh "  errors            : $nerr"
    puts $fh "  critical warnings : $ncrit"
    set rows {}
    foreach id [array names wc] { lappend rows [list $wc($id) $id $wex($id)] }
    set rows [lsort -integer -decreasing -index 0 $rows]
    puts $fh "  warning causes    : [llength $rows] distinct"
    foreach r $rows {
        lassign $r n id ex
        if {[string length $ex] > 150} { set ex "[string range $ex 0 147]..." }
        puts $fh [format "    %6d x %-16s %s" $n $id $ex]
    }
    puts $fh ""

    # The netlist's port header, which decides whether a testbench can bind to it.
    puts $fh "netlist: [file tail $nl]  ([file size $nl] bytes)"
    if {[file exists $nl]} {
        set nh [open $nl r] ; set k 0 ; set inm 0
        while {[gets $nh line] >= 0} {
            if {[string match "*module $top*" $line]} { set inm 1 }
            if {$inm} {
                puts $fh "  | [string trim $line]"
                incr k
                if {[string match "*);*" $line] || $k > 24} { break }
            }
        }
        close $nh
        if {$k > 24} { puts $fh "  | ... (truncated; full header is in the netlist)" }
    }
    close $fh
    puts ""
    puts "#############################################################"
    puts "### COMPACT SUMMARY written to:"
    puts "###   $sf"
    puts "### Paste THAT file -- not the console. It is under a page."
    puts "#############################################################"
}

puts ""
puts "#############################################################"
puts "### DONE. Paste synth/postsynth/out/step0_summary.txt -- that one"
puts "### file has the part, the red flags, the warning causes and the"
puts "### netlist port header. No need to copy the console."
puts "### Keep $out/${top}_funcsim.v on this machine -- STEP 2 uses it."
puts "#############################################################"
