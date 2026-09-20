// cl_id_defines.vh — PCI vendor/device IDs reported by the CL to the Shell.
// These are the AWS example IDs (hdk/cl/examples/.../cl_id_defines.vh). They are fine
// for bring-up; change them if you register your own device ID for a published AFI.
//   CL_SH_ID0: [15:0] PCI Vendor ID, [31:16] PCI Device ID
//   CL_SH_ID1: [15:0] PCI Subsystem Vendor ID, [31:16] PCI Subsystem ID
`ifndef CL_ID_DEFINES
`define CL_ID_DEFINES

`define CL_SH_ID0       32'hF006_1D0F
`define CL_SH_ID1       32'h1D51_FEDC

`endif // CL_ID_DEFINES
