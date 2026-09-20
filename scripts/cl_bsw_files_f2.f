// cl_bsw_files_f2.f — source list for the AWS **F2** CL build of cl_bsw_top.
// -----------------------------------------------------------------------------
// The EXACT, ordered set of RTL the F2 synth step must read to elaborate cl_bsw_top.
// scripts/f2/stage_cl_project.sh writes this ordering straight into the generated
// synth_cl_bsw_top.tcl as an explicit read_verilog list.
//
//   top module : cl_bsw_top          (rtl/f2/cl_bsw_top.sv)  — name MUST equal $CL_DIR
//                                     basename and the -c argument
//   package    : bsw_pkg             (rtl/bsw_pkg.sv — MUST be read FIRST)
//   defines    : cl_bsw_defines.vh, cl_id_defines.vh (rtl/f2/)
//   from HDK   : cl_ports.vh + 6 unused_*_template.inc (copied by encrypt.tcl)
//
// WHY AN EXPLICIT ORDERED LIST AND NOT AWS's `glob`:
// the stock synth tcl does `read_verilog -sv [glob ${src_post_enc_dir}/*.{s,}v]`, whose
// order is alphabetical. bsw_pkg.sv must compile before anything that imports it, and
// alphabetical order does not guarantee that. The staging script replaces the glob.
//
// ALSO: the staging script STRIPS the `include "bsw_pkg.sv"` line from each staged copy.
// Under Verilator those includes are harmless (one compilation unit, BSW_PKG_SV guard),
// but Vivado may compile each file as its own unit, in which case the guard does not
// carry across files and the package gets declared repeatedly. Compiling bsw_pkg.sv
// once, first, and letting `import bsw_pkg::*` resolve it is correct under both models.
//
// NOTE bsw_axis_adapter.sv is intentionally ABSENT — OCL/AXI-Lite bring-up reaches
// bsw_top through bsw_axil_regs, not the AXIS adapter.

// ---- package (MUST be first) ----
rtl/bsw_pkg.sv

// ---- bsw compute core (dependency order) ----
rtl/bsw_score_matrix.sv
rtl/bsw_pe.sv
rtl/bsw_systolic_array.sv
rtl/bsw_max_tracker.sv
rtl/bsw_ctrl_fsm.sv
rtl/bsw_top.sv

// ---- CL wrapper (bsw_axil_regs before the top that instantiates it) ----
// bsw_axil_regs is shared with the F1 flow and is shell-agnostic; only the top differs.
rtl/f1/bsw_axil_regs.sv
rtl/f2/cl_bsw_top.sv
