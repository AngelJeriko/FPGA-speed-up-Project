// cl_bsw_files.f — source list for the AWS F1 CL build of cl_bsw_top.
// -----------------------------------------------------------------------------
// This is the EXACT, ordered set of RTL the aws_build_dcp_from_cl.sh synth stage
// needs to elaborate cl_bsw_top. Feed it to whatever your HDK CL project uses to
// enumerate sources (encrypt.tcl `set` list / read_verilog in the synth .tcl /
// $CL_DIR .f list). Getting this wrong is the #1 way to lose a multi-hour build
// to a "module not found" at elaboration.
//
//   top module : cl_bsw_top          (rtl/f1/cl_bsw_top.sv)
//   package    : bsw_pkg             (rtl/bsw_pkg.sv — MUST be read first / on +incdir)
//   +incdir    : rtl  rtl/f1         (the `include "bsw_pkg.sv"` in each file resolves here)
//
// NOTE: bsw_axis_adapter.sv is intentionally ABSENT — the OCL/AXI-Lite bring-up
// reaches bsw_top through bsw_axil_regs, not the AXIS adapter. Do NOT add the old
// scripts/file_list.f here: it targets plain bsw_top, omits both rtl/f1/*.sv, and
// pulls in the unused axis adapter.
//
// Paths are relative to repo root; adjust the prefix when you drop rtl/ into
// $CL_DIR/design (e.g. prepend design/).

// ---- package (first) ----
rtl/bsw_pkg.sv

// ---- bsw compute core (dependency order) ----
rtl/bsw_score_matrix.sv
rtl/bsw_pe.sv
rtl/bsw_systolic_array.sv
rtl/bsw_max_tracker.sv
rtl/bsw_ctrl_fsm.sv
rtl/bsw_top.sv

// ---- F1 CL wrapper (bsw_axil_regs before the top that instantiates it) ----
rtl/f1/bsw_axil_regs.sv
rtl/f1/cl_bsw_top.sv
