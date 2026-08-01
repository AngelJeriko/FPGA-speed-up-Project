# impl_bsw_top.tcl — REAL place-and-route of bsw_top (not just synth-estimate).
#   Vivado GUI -> Tools -> Run Tcl Script... -> pick this file.
#   (or Tcl Console:  source <path>/synth/ooc/impl_bsw_top.tcl )
#
# WHY: the OOC *synthesis* WNS is a pre-placement estimate. bsw_top's worst path is
# ~74% ROUTING on an "unplaced" estimate (the 160-PE -> max_tracker gather). Pre-P&R
# routing on that shape is unreliable. This runs opt_design + place_design +
# route_design so the reported number is REAL placed+routed timing on the proxy part.
# Expect ~10-40 min. Copy the SUMMARY + the top worst-path back.

set here [file dirname [file normalize [info script]]]
set root [file normalize $here/../..]
set rtl  $root/rtl
set out  $here/reports
file mkdir $out

# 5.0 ns (200 MHz) target: tight enough that the router keeps optimizing so WNS
# reflects the true achievable delay; Fmax = 1000/(period - WNS) is what matters,
# and "does it clear 125 MHz?" == "is the achieved data-path delay <= 8.0 ns?".
set period 5.0

# same proxy auto-pick as ooc_console.tcl (override with `set PART <part>` first)
set candidates {
  xcku5p-ffvb676-2-e xczu7ev-ffvc1156-2-e
  xc7v2000tfhg1761-2 xc7k410tffg900-2 xc7k325tffg900-2 xc7k160tfbg484-2
  xc7a200tfbg484-2 xc7a100tcsg324-2
}
if {[info exists ::PART] && $::PART ne ""} {
  set part $::PART
} else {
  set part ""
  foreach p $candidates { if {[llength [get_parts -quiet $p]] > 0} { set part $p; break } }
}
if {$part eq "" || [llength [get_parts -quiet $part]] == 0} {
  puts "ERROR: no usable part found (tried: $candidates). set PART <one-of-them> and re-run."
  return
}
puts "### impl bsw_top on proxy part: $part  (period ${period} ns) ###"

set files {bsw_pkg.sv bsw_score_matrix.sv bsw_pe.sv bsw_systolic_array.sv \
           bsw_max_tracker.sv bsw_ctrl_fsm.sv bsw_top.sv}

if {[catch {
    catch { close_project }
    create_project -in_memory -part $part -force
    foreach f $files { read_verilog -sv $rtl/$f }
    synth_design -top bsw_top -part $part -mode out_of_context
    create_clock -name clk -period $period [get_ports clk]

    # ---- REAL implementation ----
    opt_design
    place_design
    route_design

    report_timing_summary -delay_type max -max_paths 20 -file $out/bsw_top_impl_timing.rpt
    report_utilization -file $out/bsw_top_impl_util.rpt

    set wns 0.0
    set tp [get_timing_paths -max_paths 1 -nworst 1 -setup -quiet]
    if {[llength $tp] > 0} { set wns [get_property SLACK $tp] }
    set fmax "n/a"
    catch { set fmax [format "%.1f" [expr {1000.0/($period - $wns)}]] }
    set dpd [format "%.3f" [expr {$period - $wns}]]

    puts "======== SUMMARY: bsw_top (PLACED + ROUTED) ========"
    puts "PART        : $part"
    puts "PERIOD      : $period ns"
    puts "WNS         : $wns ns"
    puts "DATA DELAY  : $dpd ns   (<= 8.000 ns  => clears 125 MHz)"
    puts "FMAX        : $fmax MHz"
    puts "125 MHz?    : [expr {$dpd <= 8.0 ? {YES - closes 125} : {NO - short of 125}}]"
    puts "===================================================="
} errmsg]} {
    puts "!!! bsw_top impl FAILED: $errmsg"
}
catch { close_project }
puts "\n### done. Copy the SUMMARY + the top worst-path from bsw_top_impl_timing.rpt. ###"
