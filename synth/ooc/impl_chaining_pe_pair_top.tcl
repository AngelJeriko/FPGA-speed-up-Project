# impl_chaining_pe_pair_top.tcl — REAL place-and-route of the FULL accelerator.
#   Vivado GUI -> Tools -> Run Tcl Script... -> pick this file.
#
# WHY: the full design's OOC *synthesis* estimate is ~102 MHz, but its worst path is the
# same routing-dominated bsw_top max_tracker reduction that phys_opt recovered ~5 MHz on
# for bsw_top alone (119 -> 124 placed). So the synth estimate is almost certainly
# pessimistic. This runs the aggressive impl flow (Explore + phys_opt_design) so we get
# the TRUE placed+routed Fmax + the REAL worst path to drive the next timing fix.
#
# ⚠️ RUNTIME/MEMORY: this is the ~305K-LUT top. Full opt+place+route+phys_opt can take
#    MANY hours and a lot of RAM. It's also OOC (no floorplan/IO), so the number is a
#    rough-but-real signal, not the last word. Run it when you can leave the box busy.

set here [file dirname [file normalize [info script]]]
set root [file normalize $here/../..]
set rtl  $root/rtl
set out  $here/reports
file mkdir $out

# 8.0 ns = the real 125 MHz target, so the router optimises toward the actual goal and
# WNS reads directly as margin-to-125. Fmax = 1000/(period - WNS).
set period 8.0

set candidates {
  xcku5p-ffvb676-2-e xczu7ev-ffvc1156-2-e
  xc7v2000tfhg1761-2 xc7k410tffg900-2 xc7k325tffg900-2 xc7k160tfbg484-2
  xc7a200tfbg484-2 xc7a100tcsg324-2
}
if {[info exists ::PART] && $::PART ne ""} { set part $::PART } else {
  set part ""; foreach p $candidates { if {[llength [get_parts -quiet $p]] > 0} { set part $p; break } }
}
if {$part eq "" || [llength [get_parts -quiet $part]] == 0} {
  puts "ERROR: no usable part found. set PART <one> and re-run."; return
}
puts "### impl chaining_pe_pair_top on $part (period ${period} ns) ###"

set files {bsw_pkg.sv bsw_score_matrix.sv bsw_pe.sv bsw_systolic_array.sv bsw_max_tracker.sv \
  bsw_ctrl_fsm.sv bsw_top.sv bsw_shared.sv bsw_axis_adapter.sv orch_window.sv orch_assemble.sv \
  orch_seedcov.sv bsw_seed_unit.sv orch_chain_unit.sv orch_purge.sv orch_read_top.sv \
  msort_v2_pkg.sv msort_v2_top.sv accel_top.sv chain_store.sv chain_weight.sv chain_introsort.sv \
  chain_flt.sv chain_flt_top.sv chaining_top.sv chain2aln_setup.sv bns_clamp_top.sv \
  chaining_extend_top.sv matesw_top.sv matesw_orient_unit.sv matesw_dedup.sv matesw_orch_top.sv \
  matesw_pe_top.sv matesw_pe_sel_top.sv chaining_pe2_top.sv chaining_pe_pair_top.sv}

if {[catch {
    catch { close_project }
    create_project -in_memory -part $part -force
    foreach f $files { read_verilog -sv $rtl/$f }
    synth_design -top chaining_pe_pair_top -part $part -mode out_of_context
    create_clock -name clk -period $period [get_ports clk]

    opt_design
    place_design -directive Explore
    phys_opt_design
    route_design -directive Explore
    catch { phys_opt_design }

    report_timing_summary -delay_type max -max_paths 30 -file $out/chaining_impl_timing.rpt
    report_utilization -file $out/chaining_impl_util.rpt

    set wns 0.0
    set tp [get_timing_paths -max_paths 1 -nworst 1 -setup -quiet]
    if {[llength $tp] > 0} { set wns [get_property SLACK $tp] }
    set fmax "n/a"; catch { set fmax [format "%.1f" [expr {1000.0/($period - $wns)}]] }
    puts "======== SUMMARY: chaining_pe_pair_top PLACED+ROUTED ========"
    puts "WNS     : $wns ns   (period $period ns => margin to 125 MHz)"
    puts "FMAX    : $fmax MHz"
    puts "125 MHz?: [expr {$wns >= 0 ? {YES - closes 125} : {NO - short by [format %.3f [expr -$wns]] ns}}]"
    puts "============================================================="
} errmsg]} {
    puts "!!! chaining impl FAILED: $errmsg"
}
catch { close_project }
puts "\n### done. Copy the SUMMARY + top worst-path from chaining_impl_timing.rpt. ###"
