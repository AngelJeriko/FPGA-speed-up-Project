// cl_bsw_top.sv — AWS F1 Custom Logic (CL) wrapper for the BSW kernel.
//
// Minimal bring-up: exposes bsw_axil_regs on the Shell's OCL AXI4-Lite BAR and ties
// off every other Shell interface (DDR A/B/C/D, PCIM, DMA-PCIS, SDA, BAR1, FLR, IRQ).
// Host talks to the kernel entirely via 32-bit peek/poke over OCL — no DDR4, no DMA.
//
// STRUCTURE follows the canonical `cl_hello_world` minimal CL: the Shell port list and
// the unused-interface tie-offs come from the HDK's own include files, so this wrapper
// tracks whatever aws-fpga HDK version you build against instead of hand-copying ~300
// Shell ports (which drift between HDK releases).
//
// ============================ HOW TO BUILD (on AWS) ============================
//   1. Clone aws-fpga, `source hdk_setup.sh`.
//   2. Copy this repo's rtl/ into $CL_DIR/design/ (or add to the .f/synth file list),
//      make cl_bsw_top the CL_NAME.
//   3. The `include`s below resolve from $HDK_SHELL_DESIGN_DIR/interfaces and
//      $CL_DIR/design (cl_ports.vh, cl_id_defines.vh, cl_common_defines.vh, and the
//      unused_*_template.inc tie-offs are all provided by the HDK — same set
//      cl_hello_world uses).
//   4. Set CL_SH_ID0/1 in cl_id_defines.vh (vendor/device id) for your AFI.
//   5. `cd $CL_DIR/build/scripts && aws_build_dcp_from_cl.sh -clock_recipe_a A1` (A1=125MHz).
//
// ============================ WHAT IS VERIFIED ============================
// The OCL->bsw_axil_regs bridge here is a 1:1 signal rename of the exact AXI4-Lite
// slave port set exercised by tb/tb_bsw_axil.sv (13/13 pass, ACGT/ACGT->score=5,
// mutation-checked). The parts that can ONLY be checked by the HDK build are the Shell
// port list and the tie-offs (no Shell model exists here). Lint the glue standalone with
// `+define+CL_BSW_LINT` (self-contained port list, no HDK includes) — see bottom.

`ifndef CL_BSW_LINT
// ===================== REAL HDK BUILD PATH =====================
module cl_bsw_top
(
   `include "cl_ports.vh"    // Shell<->CL port list (from the HDK; identical to cl_hello_world)
);

`include "cl_common_defines.vh"   // CL_NAME etc.
`include "cl_id_defines.vh"       // CL_SH_ID0 / CL_SH_ID1

// ---- tie off every Shell interface we do not use (HDK-provided templates) ----
`include "unused_flr_template.inc"
`include "unused_ddr_a_b_d_template.inc"
`include "unused_ddr_c_template.inc"
`include "unused_pcim_template.inc"
`include "unused_dma_pcis_template.inc"
`include "unused_cl_sda_template.inc"
`include "unused_sh_bar1_template.inc"
`include "unused_apppf_irq_template.inc"

// ---- FPGA / AFI id ----
assign cl_sh_id0 = `CL_SH_ID0;
assign cl_sh_id1 = `CL_SH_ID1;

// ---- reset synchroniser (Shell rst_main_n -> CL) ----
logic pre_sync_rst_n, sync_rst_n;
always_ff @(posedge clk_main_a0)
   if (!rst_main_n) {sync_rst_n, pre_sync_rst_n} <= 2'b00;
   else             {sync_rst_n, pre_sync_rst_n} <= {pre_sync_rst_n, 1'b1};

// ---- the kernel: bsw_axil_regs on the OCL AXI4-Lite BAR ----
// OCL is 32-bit addr/data. bsw_axil_regs uses a 16-bit (64 KiB) window; wire low addr bits.
bsw_axil_regs #(.ADDR_W(16), .DATA_W(32)) u_regs (
   .clk       (clk_main_a0),
   .rst_n     (sync_rst_n),
   // write address
   .s_awaddr  (sh_ocl_awaddr[15:0]),
   .s_awvalid (sh_ocl_awvalid),
   .s_awready (ocl_sh_awready),
   // write data
   .s_wdata   (sh_ocl_wdata),
   .s_wstrb   (sh_ocl_wstrb),
   .s_wvalid  (sh_ocl_wvalid),
   .s_wready  (ocl_sh_wready),
   // write resp
   .s_bresp   (ocl_sh_bresp),
   .s_bvalid  (ocl_sh_bvalid),
   .s_bready  (sh_ocl_bready),
   // read address
   .s_araddr  (sh_ocl_araddr[15:0]),
   .s_arvalid (sh_ocl_arvalid),
   .s_arready (ocl_sh_arready),
   // read data
   .s_rdata   (ocl_sh_rdata),
   .s_rresp   (ocl_sh_rresp),
   .s_rvalid  (ocl_sh_rvalid),
   .s_rready  (sh_ocl_rready)
);

endmodule // cl_bsw_top

`else
// ===================== STANDALONE LINT PATH (no HDK) =====================
// Same body, but a self-contained port list (only clk/rst + OCL) so the OCL glue can be
// elaborated/linted here without the Shell. NOT for synthesis — build path is above.
module cl_bsw_top (
   input  logic        clk_main_a0,
   input  logic        rst_main_n,
   input  logic [31:0] sh_ocl_awaddr,  input  logic sh_ocl_awvalid,  output logic ocl_sh_awready,
   input  logic [31:0] sh_ocl_wdata,   input  logic [3:0] sh_ocl_wstrb,
   input  logic        sh_ocl_wvalid,  output logic ocl_sh_wready,
   output logic [1:0]  ocl_sh_bresp,   output logic ocl_sh_bvalid,   input  logic sh_ocl_bready,
   input  logic [31:0] sh_ocl_araddr,  input  logic sh_ocl_arvalid,  output logic ocl_sh_arready,
   output logic [31:0] ocl_sh_rdata,   output logic [1:0] ocl_sh_rresp,
   output logic        ocl_sh_rvalid,  input  logic sh_ocl_rready
);
logic pre_sync_rst_n, sync_rst_n;
always_ff @(posedge clk_main_a0)
   if (!rst_main_n) {sync_rst_n, pre_sync_rst_n} <= 2'b00;
   else             {sync_rst_n, pre_sync_rst_n} <= {pre_sync_rst_n, 1'b1};

bsw_axil_regs #(.ADDR_W(16), .DATA_W(32)) u_regs (
   .clk(clk_main_a0), .rst_n(sync_rst_n),
   .s_awaddr(sh_ocl_awaddr[15:0]), .s_awvalid(sh_ocl_awvalid), .s_awready(ocl_sh_awready),
   .s_wdata(sh_ocl_wdata), .s_wstrb(sh_ocl_wstrb), .s_wvalid(sh_ocl_wvalid), .s_wready(ocl_sh_wready),
   .s_bresp(ocl_sh_bresp), .s_bvalid(ocl_sh_bvalid), .s_bready(sh_ocl_bready),
   .s_araddr(sh_ocl_araddr[15:0]), .s_arvalid(sh_ocl_arvalid), .s_arready(ocl_sh_arready),
   .s_rdata(ocl_sh_rdata), .s_rresp(ocl_sh_rresp), .s_rvalid(ocl_sh_rvalid), .s_rready(sh_ocl_rready)
);
endmodule
`endif
