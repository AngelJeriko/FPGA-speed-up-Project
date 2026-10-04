# Source list for tb_bsw_ext under XSIM (AMD Vivado's simulator).
#
# ORDER MATTERS: bsw_pkg.sv is a SystemVerilog package and must compile first;
# everything else references types from it. This list mirrors exactly the
# RTL_FILES array that scripts/run_sim.sh uses for tb_bsw_ext (see the `else`
# branch around line 322) -- if that list changes, change this one too.
#
# Used as:  xvlog -sv -f sim/xsim/bsw_ext_sources.f
--include ../../rtl
../../rtl/bsw_pkg.sv
../../rtl/bsw_score_matrix.sv
../../rtl/bsw_pe.sv
../../rtl/bsw_systolic_array.sv
../../rtl/bsw_max_tracker.sv
../../rtl/bsw_ctrl_fsm.sv
../../rtl/bsw_top.sv
../../rtl/bsw_axis_adapter.sv
../../tb/tb_bsw_ext.sv
