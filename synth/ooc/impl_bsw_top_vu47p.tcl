# impl_bsw_top_vu47p.tcl — REAL place-and-route of bsw_top on the ACTUAL F2 device.
#
#   Vivado -> Tools -> Run Tcl Script...   (or: source <path>/synth/ooc/impl_bsw_top_vu47p.tcl)
#
# WHY THIS SCRIPT EXISTS — it decides the shape of the whole F2 port.
# On F1 we targeted clk_main_a0 = 125 MHz (clock recipe A0). On F2 clk_main_a0 is FIXED
# at 250 MHz — no recipe changes it — and every Shell<->CL interface is synchronous to
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
# script measures the real part, and takes minutes — run it BEFORE the multi-hour DCP
# build and long before paying for an AFI bake and an f2.6xlarge.
#
# NOTE ON TOOLING: xcvu47p is a large Virtex UltraScale+ HBM device. It is not in the
# free Vivado ML Standard device set — run this on the FPGA Developer AMI (Vivado
# 2024.1/2024.2/2025.1/2025.2 per aws-fpga f2 supported_vivado_versions.txt), which is
# the same cheap non-F2 build host that runs the DCP build.

set here [file dirname [file normalize [info script]]]
set root [file normalize $here/../..]
set rtl  $root/rtl
set out  $here/reports
file mkdir $out

# The exact F2 device, taken from the HDK's own build_all.tcl (DEVICE_TYPE).
set part "xcvu47p-fsvh2892-2-e"
if {[llength [get_parts -quiet $part]] == 0} {
  puts "ERROR: part $part not available in this Vivado install."
  puts "       VU47P needs the FPGA Developer AMI / a full Vivado ML Enterprise device set."
  puts "       (Vivado ML Standard does not include large UltraScale+ HBM parts.)"
  return
}

# 4.0 ns = 250 MHz, the real F2 clk_main_a0 period. Fmax = 1000/(4.0 - WNS).
set period 4.0

puts "### impl bsw_top on the REAL F2 part: $part  (period ${period} ns = 250 MHz) ###"

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

report_timing_summary -delay_type max -max_paths 20 -file $out/bsw_top_vu47p_timing.rpt
report_utilization -file $out/bsw_top_vu47p_util.rpt

set wns [get_property SLACK [get_timing_paths -delay_type max]]
set fmax [expr {1000.0 / ($period - $wns)}]
puts ""
puts "#############################################################"
puts "### bsw_top on $part"
puts [format "### WNS  = %.3f ns  (target %.1f ns / %.0f MHz)" $wns $period [expr {1000.0/$period}]]
puts [format "### Fmax = %.1f MHz" $fmax]
if {$wns >= 0} {
  puts "### => CLOSES 250 MHz. Take path (A): single clock domain, no CDC, no AWS_CLK_GEN,"
  puts "###    and build with NO --clock_recipe_* flags at all."
} else {
  puts "### => DOES NOT close 250 MHz. Take path (B): CDC + AWS_CLK_GEN clk_extra_a1"
  puts "###    (recipe A1 = 125 MHz); see the CLOCKING note in rtl/f2/cl_bsw_top.sv."
}
puts "### Reports: $out"
puts "#############################################################"
