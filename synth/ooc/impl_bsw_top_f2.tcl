# impl_bsw_top_f2.tcl - REAL place-and-route of bsw_top at the F2 clock target (250 MHz),
# on the actual VU47P if available, otherwise on a same-generation UltraScale+ proxy.
#
#   Vivado -> Tools -> Run Tcl Script...   (or: source <path>/synth/ooc/impl_bsw_top_f2.tcl)
#
# WHY THIS SCRIPT EXISTS - it decides the shape of the whole F2 port.
# On F1 we targeted clk_main_a0 = 125 MHz (clock recipe A0). On F2 clk_main_a0 is FIXED
# at 250 MHz - no recipe changes it - and every Shell<->CL interface is synchronous to
# it (aws-fpga f2: hdk/docs/Clock_Recipes_User_Guide.md, AWS_Shell_Interface_Specification.md).
# So the F2 port is one of two designs:
#
#   (A) bsw_top closes 250 MHz on VU47P  -> single clock domain, the port is done.
#   (B) it does not                      -> keep bsw_axil_regs on clk_main_a0 and move
#                                           u_bsw to AWS_CLK_GEN clk_extra_a1 (125 MHz,
#                                           recipe A1), with a req/ack CDC.
#
# Our only hard datum is 124.4 MHz on a Virtex-7 -2 PROXY (docs/synth_ooc_results.md).
# UltraScale+ is a much faster fabric, so that number does not settle (A) vs (B). This
# script measures the real part, and takes minutes - run it BEFORE the multi-hour DCP
# build and long before paying for an AFI bake and an f2.6xlarge.
#
# NOTE ON TOOLING: xcvu47p is a large Virtex UltraScale+ HBM device and is not in every
# Vivado install's device set. If it is missing, this script FALLS BACK to the closest
# available UltraScale+ part at the SAME -2 speed grade and says so loudly.
#
# That fallback is worth much more than it sounds. Our only prior datum, 124.4 MHz, came
# from xc7v2000t-2 - a Virtex-7, i.e. a whole fabric generation older. A KU5P or ZU7EV
# at -2 is the SAME UltraScale+ fabric and the SAME speed grade as VU47P, so per-path
# logic delay is directly comparable and the Fmax it reports actually predicts the F2
# result. What it cannot reproduce is VU47P's size and floorplan: a much larger die
# routes differently, and this is out-of-context anyway. Treat a proxy number as a
# confident answer when it lands clearly above or clearly below 250 MHz, and as
# "assume the CDC" when it lands within ~15% of the line.
#
# bsw_top is small enough for these proxies: 71,320 LUT / 27,370 FF / 140 DSP / 0 BRAM
# measured on the Virtex-7 run, against roughly 216K LUT on KU5P and 230K on ZU7EV.
#
# If a proxy part is missing too, add the family through the Vivado installer
# ("Add Design Tools or Devices") - this is usually a device-family install choice, not
# a licensing one.

# Make the script re-runnable in one Vivado session. Without this, a second `source`
# adds its sources to the design left in memory by the first and fails in a way that
# looks like an RTL problem (duplicate modules) rather than an operator one.
catch {close_design}
catch {close_project}

set here [file dirname [file normalize [info script]]]
set root [file normalize $here/../..]
set rtl  $root/rtl
set out  $here/reports
file mkdir $out

# The exact F2 device, taken from the HDK's own build_all.tcl (DEVICE_TYPE), followed by
# same-generation / same-speed-grade fallbacks. Override with `set PART <part>` first.
set exact "xcvu47p-fsvh2892-2-e"
set proxies {xcku5p-ffvb676-2-e xczu7ev-ffvc1156-2-e xcvu9p-flgb2104-2-i}

set part ""
set is_exact 0
if {[info exists ::PART] && $::PART ne ""} {
  set part $::PART
  if {$part eq $exact} { set is_exact 1 }
} elseif {[llength [get_parts -quiet $exact]] > 0} {
  set part $exact
  set is_exact 1
} else {
  foreach p $proxies {
    if {[llength [get_parts -quiet $p]] > 0} { set part $p; break }
  }
}

if {$part eq "" || [llength [get_parts -quiet $part]] == 0} {
  puts "ERROR: neither $exact nor any UltraScale+ proxy is available here."
  puts "       Tried: $proxies"
  puts "       Add the UltraScale+ device families via the Vivado installer"
  puts "       (Add Design Tools or Devices), or run on the FPGA Developer AMI."
  puts "       Running this on a Virtex-7 part would NOT answer the 250 MHz question:"
  puts "       that is a generation older and systematically pessimistic."
  return
}

if {!$is_exact} {
  puts ""
  puts "##########################################################################"
  puts "### PROXY PART: $part  (the real F2 device $exact is not installed)"
  puts "### Same UltraScale+ generation and same -2 speed grade, so the Fmax below"
  puts "### is directly comparable. It does NOT model VU47P's die size or floorplan."
  puts "### Read it as: clearly >250 -> path (A); clearly <250 -> path (B);"
  puts "### within ~15% of 250 -> treat as inconclusive and take path (B)."
  puts "##########################################################################"
  puts ""
}

# 4.0 ns = 250 MHz, the real F2 clk_main_a0 period. Fmax = 1000/(4.0 - WNS).
set period 4.0

if {$is_exact} {
  puts "### impl bsw_top on the REAL F2 part: $part  (period ${period} ns = 250 MHz) ###"
} else {
  puts "### impl bsw_top on UltraScale+ PROXY: $part  (period ${period} ns = 250 MHz) ###"
}

set files {bsw_pkg.sv bsw_score_matrix.sv bsw_pe.sv bsw_systolic_array.sv \
           bsw_max_tracker.sv bsw_ctrl_fsm.sv bsw_top.sv}

foreach f $files { read_verilog -sv [file join $rtl $f] }

synth_design -top bsw_top -part $part -mode out_of_context
create_clock -period $period -name clk [get_ports clk]

# Same aggressive timing flow the proxy runs use, so the numbers are comparable.
opt_design -directive Explore
place_design -directive Explore
phys_opt_design -directive Explore
route_design -directive Explore
phys_opt_design -directive Explore

# Name the reports after the part that ACTUALLY ran, so a proxy result can never be
# mistaken for a real VU47P one later (e.g. bsw_top_f2_xcku5p_timing.rpt).
set ptag [lindex [split $part -] 0]
set rpt_t $out/bsw_top_f2_${ptag}_timing.rpt
set rpt_u $out/bsw_top_f2_${ptag}_util.rpt
report_timing_summary -delay_type max -max_paths 20 -file $rpt_t
report_utilization -file $rpt_u

set wns [get_property SLACK [get_timing_paths -delay_type max]]
set fmax [expr {1000.0 / ($period - $wns)}]
puts ""
puts "#############################################################"
puts "### bsw_top on $part"
puts [format "### WNS  = %.3f ns  (target %.1f ns / %.0f MHz)" $wns $period [expr {1000.0/$period}]]
puts [format "### Fmax = %.1f MHz" $fmax]
if {$is_exact} {
  if {$wns >= 0} {
    puts "### => CLOSES 250 MHz. Take path (A): single clock domain, no CDC, no"
    puts "###    AWS_CLK_GEN, and NO --clock_recipe_* flags at all."
  } else {
    puts "### => DOES NOT close 250 MHz. Take path (B): stage with --clk-gen; the CDC"
    puts "###    is already built and verified (rtl/bsw_kernel_cdc.sv)."
  }
} else {
  if {$fmax >= 287.5} {
    puts "### => Comfortably above 250 MHz on a same-generation proxy (>15% margin)."
    puts "###    Plan on path (A); confirm on the real part during the DCP build."
  } elseif {$fmax <= 212.5} {
    puts "### => Clearly below 250 MHz on a same-generation proxy (>15% short)."
    puts "###    Take path (B): stage with --clk-gen. The CDC is built and verified."
  } else {
    puts "### => INCONCLUSIVE: within ~15% of 250 MHz on a proxy part. A real VU47P"
    puts "###    could land either side. Take path (B) - it costs one extra source"
    puts "###    file and a clock recipe, and it cannot fail timing the way (A) can."
  }
}
puts "### Reports: $rpt_t"
puts "###          $rpt_u"
puts "#############################################################"
