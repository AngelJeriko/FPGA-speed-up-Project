# ooc_console.tcl — run from the Vivado GUI, no terminal needed.
#   Vivado GUI -> Tools -> Run Tcl Script... -> pick this file.
#   (or in the Tcl Console:  source <path>/synth/ooc/ooc_console.tcl )
#
# It synthesizes each priority module out-of-context on a free UltraScale+ proxy part,
# then prints Fmax + LUT/FF/BRAM/DSP to the Tcl Console. Copy that console text back.

# --- locate the repo relative to THIS script (works no matter the current dir) ---
set here [file dirname [file normalize [info script]]]
set root [file normalize $here/../..]
set rtl  $root/rtl
set out  $here/reports
file mkdir $out
set period 3.0   ;# ns; target 333 MHz. Fmax = 1000/(period - WNS)

# --- auto-pick a free UltraScale+ part that is actually installed ---
set candidates {
  xcku5p-ffvb676-2-e xcku3p-ffva676-2-e
  xczu7ev-ffvc1156-2-e xczu3eg-sbva484-2-e xczu2cg-sbva484-1-e
  xcau25p-ffvb676-2-e
}
set part ""
foreach p $candidates { if {[llength [get_parts -quiet $p]] > 0} { set part $p; break } }
if {$part eq ""} {
  puts "############################################################"
  puts "ERROR: none of my candidate proxy parts are installed."
  puts "Type   get_parts -filter {FAMILY =~ *UltraScale+*}   to see yours,"
  puts "pick one ending in -2-e or -2-i, and tell Claude."
  puts "############################################################"
  return
}
puts "### using proxy part: $part ###"

# --- module -> source files (repo-relative to rtl/) ---
set targets {
  chain_store      {chain_store.sv}
  bsw_max_tracker  {bsw_pkg.sv bsw_max_tracker.sv}
  matesw_dedup     {matesw_dedup.sv}
}

proc ncells {pat} { return [llength [get_cells -hier -quiet -filter "REF_NAME =~ $pat"]] }

foreach {top files} $targets {
  puts "\n############ synthesizing $top ############"
  if {[catch {
      catch { close_project }
      create_project -in_memory -part $part -force
      foreach f $files { read_verilog -sv $rtl/$f }
      synth_design -top $top -part $part -mode out_of_context

      if {[llength [get_ports -quiet clk]] > 0} {
        create_clock -name clk -period $period [get_ports clk]
      }
      report_utilization    -file $out/${top}_util.rpt
      report_timing_summary -delay_type max -max_paths 20 -file $out/${top}_timing.rpt

      set wns 0.0
      set tp [get_timing_paths -max_paths 1 -nworst 1 -setup -quiet]
      if {[llength $tp] > 0} { set wns [get_property SLACK $tp] }
      set fmax "n/a"
      catch { set fmax [format "%.1f" [expr {1000.0/($period - $wns)}]] }

      puts "======== SUMMARY: $top ========"
      puts "PART   : $part"
      puts "WNS    : $wns ns   (period ${period} ns)"
      puts "FMAX   : $fmax MHz"
      puts "LUT    : [ncells LUT*]"
      puts "FF     : [ncells FD*]"
      puts "RAMB36 : [ncells RAMB36*]"
      puts "RAMB18 : [ncells RAMB18*]"
      puts "URAM   : [ncells URAM*]"
      puts "DSP    : [ncells DSP*]"
      puts "================================"
  } errmsg]} {
      puts "!!! $top FAILED: $errmsg"
  }
}
catch { close_project }
puts "\n### done. Copy the SUMMARY blocks above and send them to Claude. ###"
puts "### (full reports also saved in: $out ) ###"
