# synth_cl_bsw_f2.tcl — run REAL Vivado synthesis on the whole F2 CL wrapper, on any
# machine with Vivado. No AWS account, no licence beyond what you already have, no F2.
#
#   Vivado -> Tools -> Run Tcl Script...
#   (or Tcl Console:  set KIT C:/path/to/aws-fpga-f2 ; source .../synth_cl_bsw_f2.tcl )
#
# ============================== WHY THIS MATTERS ==============================
# scripts/f2/lint_cl_bsw.sh proved that cl_bsw_top ELABORATES against the real Shell
# port list and tie-offs. What it explicitly cannot prove is the one fault class that
# would otherwise surface only hours into a paid AWS build: a MULTIPLY-DRIVEN NET.
# We demonstrated that gap rather than assuming it — a mutant that drives cl_ocl_* from
# both our OCL slave and a tie-off lints 100% clean under Verilator even with -Wall.
# That is the same blind spot recorded in docs ("Verilator misses synthesis bugs": real
# synthesis once caught 147k multi-driven-net warnings that Verilator passed).
#
# Vivado sees it. So synthesising the wrapper here closes the gap BEFORE the DCP build,
# and costs minutes on hardware you already have.
#
# It also reports real UltraScale+ utilisation for the whole CL, which is the other
# thing we cannot get from Verilator — useful as an early "will this fit alongside the
# Shell" sanity check.
#
# ============================== WHAT IT IS NOT ==============================
# This is OUT-OF-CONTEXT synthesis of the CL alone, with stubs where AWS ships IP
# (axi_register_slice_light) or encrypted logic (sh_ddr, via the HDK's own
# sh_ddr.stub.sv). It is NOT the AWS build: no Shell, no real IP, no place-and-route
# against the F2 floorplan, and the timing numbers here mean nothing — use
# synth/ooc/impl_bsw_top_f2.tcl for timing. The question this answers is narrow and
# worth answering: "does the CL synthesise cleanly, and is anything multiply driven?"
#
# ============================== SETUP ==============================
# You need a checkout of the aws-fpga **f2** branch (a plain git clone, nothing else):
#   git clone --filter=blob:none --no-checkout --depth 1 -b f2 \
#       https://github.com/aws/aws-fpga.git aws-fpga-f2
#   cd aws-fpga-f2 && git sparse-checkout init --cone && git sparse-checkout set \
#       hdk/common/shell_stable/design/interfaces hdk/common/shell_stable/design/sh_ddr
# Then point KIT at it (or set AWS_FPGA_F2_DIR / HDK_DIR in the environment).
#
# Optional:  set CDC 1     -> synthesise the two-clock build instead (BSW_KERNEL_CDC)
#            set PART <p>  -> force a device
# ==============================================================================

# Make the script re-runnable in one Vivado session. Without this, a second `source`
# adds its sources to the design left in memory by the first and fails in a way that
# looks like an RTL problem (duplicate modules) rather than an operator one.
catch {close_design}
catch {close_project}

set here [file dirname [file normalize [info script]]]
set root [file normalize $here/../..]
set out  $here/reports
file mkdir $out

# ---- locate the HDK ----------------------------------------------------------
if {![info exists ::KIT]} {
  if {[info exists ::env(AWS_FPGA_F2_DIR)]} {
    set ::KIT $::env(AWS_FPGA_F2_DIR)
  } elseif {[info exists ::env(HDK_DIR)]} {
    set ::KIT [file normalize $::env(HDK_DIR)/..]
  } else {
    puts "ERROR: set KIT to your aws-fpga f2 checkout first, e.g."
    puts "       set KIT C:/work/aws-fpga-f2"
    puts "       (see the SETUP block at the top of this script)"
    return
  }
}
set ifdir  $::KIT/hdk/common/shell_stable/design/interfaces
set ddrdir $::KIT/hdk/common/shell_stable/design/sh_ddr

if {![file exists $ifdir/cl_ports.vh]} {
  puts "ERROR: no cl_ports.vh under $ifdir — is KIT pointing at an aws-fpga checkout?"
  return
}
# Same guard the shell scripts use: an F1 (master-branch) HDK would elaborate into
# something subtly wrong rather than failing outright.
set fh [open $ifdir/cl_ports.vh r]
set cl_ports_txt [read $fh]
close $fh
if {[lsearch -regexp [split $cl_ports_txt "\n"] {ocl_cl_awaddr}] < 0} {
  puts "ERROR: $ifdir/cl_ports.vh has no ocl_cl_* signals."
  puts "       That is an F1 (master-branch) HDK, not the f2 branch."
  return
}
if {![file exists $ddrdir/sh_ddr.stub.sv]} {
  puts "ERROR: sh_ddr.stub.sv not found under $ddrdir"
  puts "       Add it to your sparse-checkout (see SETUP)."
  return
}

# ---- pick a part -------------------------------------------------------------
# Any part will do for a multi-driver check, but an UltraScale+ one also gives
# utilisation numbers in the right technology. bsw_top alone is ~71K LUT, so prefer
# something that can actually hold it.
set candidates {xcvu47p-fsvh2892-2-e xcvu9p-flgb2104-2-i xcku5p-ffvb676-2-e \
                xczu7ev-ffvc1156-2-e xc7v2000tfhg1761-2}
if {[info exists ::PART] && $::PART ne ""} {
  set part $::PART
} else {
  set part ""
  foreach p $candidates { if {[llength [get_parts -quiet $p]] > 0} { set part $p; break } }
}
if {$part eq "" || [llength [get_parts -quiet $part]] == 0} {
  puts "ERROR: none of these parts is installed: $candidates"
  puts "       Add a device family via the Vivado installer, or: set PART <part>"
  return
}

set cdc 0
if {[info exists ::CDC] && $::CDC} { set cdc 1 }

puts ""
puts "### synth cl_bsw_top   part=$part   mode=[expr {$cdc ? {two-clock (BSW_KERNEL_CDC)} : {single-clock}}]"
puts "### HDK interfaces: $ifdir"
puts ""

# ---- sources, in dependency order (mirrors scripts/cl_bsw_files_f2.f) --------
set srcs [list \
  $root/rtl/bsw_pkg.sv \
  $root/rtl/bsw_score_matrix.sv \
  $root/rtl/bsw_pe.sv \
  $root/rtl/bsw_systolic_array.sv \
  $root/rtl/bsw_max_tracker.sv \
  $root/rtl/bsw_ctrl_fsm.sv \
  $root/rtl/bsw_top.sv ]
if {$cdc} { lappend srcs $root/rtl/bsw_kernel_cdc.sv }
lappend srcs \
  $root/rtl/bsw_axil_regs.sv \
  $root/rtl/f2/cl_bsw_top.sv \
  $root/tb/f2/axi_register_slice_light_stub.sv \
  $ddrdir/sh_ddr.stub.sv
if {$cdc} { lappend srcs $root/tb/f2/aws_clk_gen_stub.sv }

foreach f $srcs { read_verilog -sv $f }

set defines {}
if {$cdc} { set defines {BSW_KERNEL_CDC} }

# ---- THE ACTUAL CHECK ---------------------------------------------------------
# Vivado reports a multiply-driven net as WARNING [Synth 8-3352] and keeps going: the
# run "succeeds" while producing a broken netlist, which is exactly how such a fault
# reaches an AFI. Escalate it to an ERROR so synth_design STOPS instead. This is the
# whole point of the script, so make it impossible to miss rather than something you
# have to spot while scrolling a log.
set_msg_config -id {Synth 8-3352} -new_severity ERROR

# A net with no driver at all is usually benign here (unused Shell inputs), so it is
# promoted only as far as CRITICAL WARNING - visible in the summary, not fatal.
set_msg_config -id {Synth 8-3848} -new_severity {CRITICAL WARNING}

# -include_dirs gives `include "cl_ports.vh"` and the unused_*_template.inc files a
# search path; rtl/ and rtl/f2/ resolve bsw_pkg.sv and cl_bsw_defines.vh.
if {[llength $defines]} {
  synth_design -top cl_bsw_top -part $part -mode out_of_context \
    -include_dirs [list $root/rtl $root/rtl/f2 $ifdir] -verilog_define $defines
} else {
  synth_design -top cl_bsw_top -part $part -mode out_of_context \
    -include_dirs [list $root/rtl $root/rtl/f2 $ifdir]
}

set tag [expr {$cdc ? "cdc" : "single"}]
report_utilization -file $out/cl_bsw_top_${tag}_util.rpt

# ---- verdict -----------------------------------------------------------------
# Getting here at all means synth_design did not error, i.e. [Synth 8-3352] never fired.
# (The earlier version of this script walked every hierarchical net calling get_pins per
# net. On a ~71K-LUT design that is hundreds of thousands of Tcl round-trips and can run
# for hours - the message-severity approach asks the tool the same question in zero time.)
set crit [get_msg_config -count -severity {CRITICAL WARNING}]
set warn [get_msg_config -count -severity {WARNING}]

puts ""
puts "#############################################################"
puts "### cl_bsw_top synthesised on $part  (mode: $tag)"
puts "### >>> PASS - no multiply-driven nets."
puts "###     Synth 8-3352 was escalated to ERROR before synthesis, so reaching"
puts "###     this line IS the result. That is the fault class Verilator cannot see."
puts "###"
puts "### Critical warnings: $crit      Warnings: $warn"
puts "### Worth a look in the log even on a pass:"
puts "###     Synth 8-3848   net has no driver          (promoted to CRITICAL WARNING)"
puts "###     Synth 8-6014   unused sequential element  (a whole block optimised away)"
puts "###     Synth 8-3331   design has unconnected port"
puts "### Utilisation: $out/cl_bsw_top_${tag}_util.rpt"
puts "###"
puts "### NOTE: this is out-of-context with stubs for AWS IP - the TIMING numbers from"
puts "### this run are meaningless. Use synth/ooc/impl_bsw_top_f2.tcl for timing."
puts "#############################################################"
