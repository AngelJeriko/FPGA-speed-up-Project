// cl_bsw_defines.vh — CL-level defines for the F2 BSW bring-up.
// F2 has no cl_common_defines.vh (F1 did), so CL_NAME lives here, alongside the
// two AXI literals AWS's cl_axil_reg_access example keeps in its own defines file.
`ifndef CL_BSW_DEFINES
`define CL_BSW_DEFINES

// MUST match the $CL_DIR basename, the -c argument to aws_build_dcp_from_cl.py,
// and the module name in cl_bsw_top.sv. Synth runs with `-top ${CL}`.
`define CL_NAME cl_bsw_top

`define AXI_PROT_DEFAULT  3'h0
`define AXI_RESP_OKAY     2'b00

`endif // CL_BSW_DEFINES
