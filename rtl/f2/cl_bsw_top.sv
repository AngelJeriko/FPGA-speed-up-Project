// cl_bsw_top.sv — AWS **F2** Custom Logic (CL) wrapper for the BSW kernel.
//
// F2 port of rtl/f1/cl_bsw_top.sv. Same idea: expose bsw_axil_regs on the Shell's
// OCL AXI4-Lite BAR (AppPF BAR0) and tie off every other Shell interface. Host talks
// to the kernel entirely via 32-bit peek/poke over OCL — no DDR4, no HBM, no DMA.
//
// ====================== WHAT CHANGED vs THE F1 WRAPPER ======================
// Verified against aws/aws-fpga branch `f2` (hdk/common/shell_stable/design/interfaces
// and hdk/cl/examples/cl_demo/cl_axil_reg_access + CL_TEMPLATE):
//
//   1. OCL SIGNAL NAMES FLIPPED.  F1 used sh_ocl_*/ocl_sh_*; F2 uses ocl_cl_*/cl_ocl_*.
//      F2 also adds ocl_cl_awuser[54:0] / ocl_cl_aruser[54:0], which we ignore.
//   2. TIE-OFF FILE SET CHANGED.  unused_ddr_a_b_d_template.inc + unused_ddr_c_template.inc
//      collapsed into ONE unused_ddr_template.inc; unused_sh_bar1_template.inc is GONE
//      (no BAR1 on F2). A new unused_sh_ocl_template.inc exists — we must NOT include it,
//      it would fight our OCL slave for cl_ocl_*.
//   3. unused_ddr_template.inc REFERENCES `rst_main_n_sync` and does not declare it.
//      The CL must declare and drive it, so our reset synchroniser output is named
//      exactly that. (The AWS cl_axil_reg_access example leaks this as an implicit
//      1-bit wire, which silently holds its sh_ddr stub in reset. We drive it properly.)
//   4. NO cl_common_defines.vh on F2 — CL_NAME lives in our own cl_bsw_defines.vh.
//   5. NEW UNDRIVEN CL OUTPUTS that no tie-off covers: cl_sh_status0/1/2,
//      cl_sh_status_vled, the pcim ax*-qualifier group, cl_sh_dma_pcis_ruser,
//      hbm_apb_*_0/1 (both HBM monitor ports) and PCIE_EP/RP_*. We drive them all to 0,
//      following CL_TEMPLATE. Leaving them floating is legal but noisy.
//   6. CLOCK.  F1 built at 125 MHz via clock recipe A0. On F2 `clk_main_a0` is FIXED at
//      250 MHz — no recipe changes it — and every Shell<->CL interface is synchronous
//      to it. See the CLOCKING note below; this is the one real engineering risk in the
//      port, and it is deliberately isolated to one seam in this file.
//
// ============================== CLOCKING ==============================
// As written, bsw_axil_regs AND bsw_top both run on clk_main_a0 = 250 MHz. That is the
// right shape IF bsw_top closes 250 MHz on the VU47P. Our only hard timing datum is
// 124.4 MHz on a Virtex-7 -2 proxy (docs/synth_ooc_results.md) — a much slower fabric —
// so the real VU47P number is unknown and MUST be measured before an AFI is baked
// (scripts/f2/ooc_vu47p.tcl, minutes, on the cheap build host).
//
// If it does NOT close 250: that fallback is BUILT AND VERIFIED, not just planned.
// Define BSW_KERNEL_CDC (stage with --clk-gen) and bsw_axil_regs keeps its AXI-Lite
// front end on clk_main_a0 while bsw_top moves to AWS_CLK_GEN's clk_extra_a1 (125 MHz,
// clock recipe A1) behind rtl/bsw_kernel_cdc.sv — a two-phase toggle handshake with a
// quasi-static payload. Proven by tb_bsw_axil_cdc (23/23 against a same-clock reference,
// two non-harmonic clocks, reset skew). Constraints: scripts/f2/cl_timing_user_cdc.xdc.
// Note the F2 build script HARD-ERRORS if a --clock_recipe_* is passed without
// --aws_clk_gen; the staging script adds both together.
//
// ============================== HOW TO BUILD ==============================
//   scripts/f2/stage_cl_project.sh --build        (see docs/f2_build_runbook.md)
// The CL directory basename, the -c argument and this module's name must all be
// IDENTICAL ("cl_bsw_top") — aws_build_dcp_from_cl.py derives the CL name from the
// $CL_DIR basename and synth runs with `-top ${CL}`.
//
// ============================== WHAT IS VERIFIED ==============================
// The OCL -> bsw_axil_regs bridge is the same AXI4-Lite slave port set exercised by
// tb/tb_bsw_axil.sv (13/13, ACGT/ACGT -> score=5, mutation-checked) and by
// tb/tb_cl_bsw_ocl.sv. What only the HDK can check — the Shell port list and the
// tie-offs — is covered here by scripts/f2/lint_cl_bsw.sh, which elaborates THIS file
// against the REAL cl_ports.vh and the REAL tie-off .inc files from a checkout of the
// aws-fpga f2 branch, using AWS's own sh_ddr.stub.sv. That catches renamed ports,
// missing drivers and include-order faults on this box, before any paid build.

`ifndef CL_BSW_LINT
// ========================= REAL HDK BUILD PATH =========================
`include "cl_bsw_defines.vh"     // CL_NAME, AXI_PROT_DEFAULT, AXI_RESP_OKAY

module cl_bsw_top
(
   `include "cl_ports.vh"        // F2 Shell<->CL port list (from the HDK)
);

`include "cl_id_defines.vh"      // CL_SH_ID0 / CL_SH_ID1

// ---- reset synchroniser (Shell rst_main_n -> CL) -------------------------------
// MUST be declared and driven BEFORE unused_ddr_template.inc, which consumes
// rst_main_n_sync by name.
logic pre_sync_rst_n;
logic rst_main_n_sync;
always_ff @(posedge clk_main_a0)
   if (!rst_main_n) {rst_main_n_sync, pre_sync_rst_n} <= 2'b00;
   else             {rst_main_n_sync, pre_sync_rst_n} <= {pre_sync_rst_n, 1'b1};

// ---- tie off every Shell interface we do not use (HDK-provided templates) ------
// NOTE: unused_sh_ocl_template.inc is deliberately absent — OCL is the one interface
// we drive. Adding it would multiply-drive cl_ocl_* and corrupt the build.
`include "unused_flr_template.inc"        // cl_sh_flr_done
`include "unused_ddr_template.inc"        // sh_ddr #(.DDR_PRESENT(0)) + ddr stat bus
`include "unused_apppf_irq_template.inc"  // cl_sh_apppf_irq_req
`include "unused_dma_pcis_template.inc"   // cl_sh_dma_pcis_*, cl_sh_dma_{wr,rd}_full
`include "unused_pcim_template.inc"       // cl_sh_pcim_* (data/addr group)
`ifndef BSW_KERNEL_CDC
`include "unused_cl_sda_template.inc"     // cl_sda_* (the CDC build drives these instead)
`endif

// ---- kernel clock domain --------------------------------------------------------
// Defining BSW_KERNEL_CDC switches to the two-clock build: bsw_top moves off the
// Shell's fixed 250 MHz clk_main_a0 and onto AWS_CLK_GEN's clk_extra_a1 (125 MHz on
// clock recipe A1), behind bsw_kernel_cdc. Use it only if bsw_top does not close
// 250 MHz on VU47P — measure with synth/ooc/impl_bsw_top_f2.tcl first, and stage
// with `scripts/f2/stage_cl_project.sh --clk-gen`, which defines this, installs
// cl_timing_user_cdc.xdc and adds --aws_clk_gen --clock_recipe_a A1 to the build.
`ifdef BSW_KERNEL_CDC
localparam bit KCDC = 1'b1;

logic kernel_clk, kernel_rst_n;
logic gen_clk_main_a0, gen_rst_main_n, gen_clk_hbm_ref;
logic gen_clk_extra_a2, gen_clk_extra_a3, gen_clk_extra_b0, gen_clk_extra_b1;
logic gen_clk_extra_c0, gen_clk_extra_c1, gen_clk_hbm_axi;
logic gen_rst_hbm_axi_n, gen_rst_hbm_ref_n, gen_rst_c1_n, gen_rst_c0_n;
logic gen_rst_b1_n, gen_rst_b0_n, gen_rst_a3_n, gen_rst_a2_n;

// Group A only: we need clk_extra_a1 and nothing else. Disabling B/C/HBM keeps the
// MMCM/BUFG count (and the power) down.
// The AXI-Lite control port is wired to the Shell's SDA interface (MgmtPF BAR4), which
// is exactly what AWS's own cl_mem_perf example does — it leaves our OCL BAR entirely
// to bsw_axil_regs, and it is what makes fpga-load-clkgen-dynamic work at runtime.
aws_clk_gen #(
   .CLK_GRP_A_EN (1),
   .CLK_GRP_B_EN (0),
   .CLK_GRP_C_EN (0),
   .CLK_HBM_EN   (0)
) AWS_CLK_GEN (
   .i_clk_main_a0       (clk_main_a0),
   .i_rst_main_n        (rst_main_n_sync),
   .i_clk_hbm_ref       (clk_hbm_ref),

   .s_axil_ctrl_awaddr  (sda_cl_awaddr),  .s_axil_ctrl_awvalid (sda_cl_awvalid),
   .s_axil_ctrl_awready (cl_sda_awready),
   .s_axil_ctrl_wdata   (sda_cl_wdata),   .s_axil_ctrl_wstrb   (sda_cl_wstrb),
   .s_axil_ctrl_wvalid  (sda_cl_wvalid),  .s_axil_ctrl_wready  (cl_sda_wready),
   .s_axil_ctrl_bresp   (cl_sda_bresp),   .s_axil_ctrl_bvalid  (cl_sda_bvalid),
   .s_axil_ctrl_bready  (sda_cl_bready),
   .s_axil_ctrl_araddr  (sda_cl_araddr),  .s_axil_ctrl_arvalid (sda_cl_arvalid),
   .s_axil_ctrl_arready (cl_sda_arready),
   .s_axil_ctrl_rdata   (cl_sda_rdata),   .s_axil_ctrl_rresp   (cl_sda_rresp),
   .s_axil_ctrl_rvalid  (cl_sda_rvalid),  .s_axil_ctrl_rready  (sda_cl_rready),

   .o_clk_hbm_ref       (gen_clk_hbm_ref),
   .o_clk_main_a0       (gen_clk_main_a0),
   .o_clk_extra_a1      (kernel_clk),        // <- 125 MHz on clock recipe A1
   .o_clk_extra_a2      (gen_clk_extra_a2),
   .o_clk_extra_a3      (gen_clk_extra_a3),
   .o_clk_extra_b0      (gen_clk_extra_b0),
   .o_clk_extra_b1      (gen_clk_extra_b1),
   .o_clk_extra_c0      (gen_clk_extra_c0),
   .o_clk_extra_c1      (gen_clk_extra_c1),
   .o_clk_hbm_axi       (gen_clk_hbm_axi),
   .o_cl_rst_hbm_axi_n  (gen_rst_hbm_axi_n),
   .o_cl_rst_hbm_ref_n  (gen_rst_hbm_ref_n),
   .o_cl_rst_c1_n       (gen_rst_c1_n),
   .o_cl_rst_c0_n       (gen_rst_c0_n),
   .o_cl_rst_b1_n       (gen_rst_b1_n),
   .o_cl_rst_b0_n       (gen_rst_b0_n),
   .o_cl_rst_a3_n       (gen_rst_a3_n),
   .o_cl_rst_a2_n       (gen_rst_a2_n),
   .o_cl_rst_a1_n       (kernel_rst_n),      // reset already sync'd to clk_extra_a1
   .o_cl_rst_main_n     (gen_rst_main_n)
);
`else
// Single-clock build (the default, and the one we hope the VU47P measurement allows):
// the kernel ports below are tied to the main domain and bsw_axil_regs ignores them.
localparam bit KCDC = 1'b0;
logic kernel_clk, kernel_rst_n;
assign kernel_clk   = clk_main_a0;
assign kernel_rst_n = rst_main_n_sync;
`endif

// ---- CL outputs no tie-off covers (mirrors CL_TEMPLATE) ------------------------
always_comb begin
   cl_sh_id0          = `CL_SH_ID0;
   cl_sh_id1          = `CL_SH_ID1;
   cl_sh_status0      = 'b0;
   cl_sh_status1      = 'b0;
   cl_sh_status2      = 'b0;
   cl_sh_status_vled  = 'b0;
end

// pcim qualifier signals (the unused_pcim template drives addr/data/valid, not these)
always_comb begin
   cl_sh_pcim_awburst = 'b0;
   cl_sh_pcim_awcache = 'b0;
   cl_sh_pcim_awlock  = 'b0;
   cl_sh_pcim_awprot  = 'b0;
   cl_sh_pcim_awqos   = 'b0;
   cl_sh_pcim_wid     = 'b0;
   cl_sh_pcim_wuser   = 'b0;
   cl_sh_pcim_arburst = 'b0;
   cl_sh_pcim_arcache = 'b0;
   cl_sh_pcim_arlock  = 'b0;
   cl_sh_pcim_arprot  = 'b0;
   cl_sh_pcim_arqos   = 'b0;
   cl_sh_dma_pcis_ruser = 'b0;
end

// HBM monitor APB — unused on this bring-up (no HBM in the BSW datapath yet)
always_comb begin
   hbm_apb_paddr_0   = 'b0;  hbm_apb_paddr_1   = 'b0;
   hbm_apb_pprot_0   = 'b0;  hbm_apb_pprot_1   = 'b0;
   hbm_apb_psel_0    = 'b0;  hbm_apb_psel_1    = 'b0;
   hbm_apb_penable_0 = 'b0;  hbm_apb_penable_1 = 'b0;
   hbm_apb_pwrite_0  = 'b0;  hbm_apb_pwrite_1  = 'b0;
   hbm_apb_pwdata_0  = 'b0;  hbm_apb_pwdata_1  = 'b0;
   hbm_apb_pstrb_0   = 'b0;  hbm_apb_pstrb_1   = 'b0;
   hbm_apb_pready_0  = 'b0;  hbm_apb_pready_1  = 'b0;
   hbm_apb_prdata_0  = 'b0;  hbm_apb_prdata_1  = 'b0;
   hbm_apb_pslverr_0 = 'b0;  hbm_apb_pslverr_1 = 'b0;
end

// CL-side PCIe endpoint/root-port pins — unused
always_comb begin
   PCIE_EP_TXP    = 'b0;
   PCIE_EP_TXN    = 'b0;
   PCIE_RP_PERSTN = 'b0;
   PCIE_RP_TXP    = 'b0;
   PCIE_RP_TXN    = 'b0;
end

// ---- OCL AXI4-Lite: Shell -> register slice -> bsw_axil_regs -------------------
// The register slice is what AWS's own cl_axil_reg_access example does; it buys a
// pipeline stage on the Shell boundary, which matters more at 250 MHz than it did
// at F1's 125 MHz. scripts/f2/lint_cl_bsw.sh supplies a behavioural stub for it.
logic        ocl_q_awvalid, ocl_q_awready;
logic [31:0] ocl_q_awaddr;
logic        ocl_q_wvalid,  ocl_q_wready;
logic [31:0] ocl_q_wdata;
logic  [3:0] ocl_q_wstrb;
logic        ocl_q_bvalid,  ocl_q_bready;
logic  [1:0] ocl_q_bresp;
logic        ocl_q_arvalid, ocl_q_arready;
logic [31:0] ocl_q_araddr;
logic        ocl_q_rvalid,  ocl_q_rready;
logic [31:0] ocl_q_rdata;
logic  [1:0] ocl_q_rresp;

axi_register_slice_light AXIL_OCL_REG_SLC (
   .aclk          (clk_main_a0),
   .aresetn       (rst_main_n_sync),
   .s_axi_awaddr  (ocl_cl_awaddr),   .s_axi_awprot  (`AXI_PROT_DEFAULT),
   .s_axi_awvalid (ocl_cl_awvalid),  .s_axi_awready (cl_ocl_awready),
   .s_axi_wdata   (ocl_cl_wdata),    .s_axi_wstrb   (ocl_cl_wstrb),
   .s_axi_wvalid  (ocl_cl_wvalid),   .s_axi_wready  (cl_ocl_wready),
   .s_axi_bresp   (cl_ocl_bresp),    .s_axi_bvalid  (cl_ocl_bvalid),
   .s_axi_bready  (ocl_cl_bready),
   .s_axi_araddr  (ocl_cl_araddr),   .s_axi_arprot  (`AXI_PROT_DEFAULT),
   .s_axi_arvalid (ocl_cl_arvalid),  .s_axi_arready (cl_ocl_arready),
   .s_axi_rdata   (cl_ocl_rdata),    .s_axi_rresp   (cl_ocl_rresp),
   .s_axi_rvalid  (cl_ocl_rvalid),   .s_axi_rready  (ocl_cl_rready),
   .m_axi_awaddr  (ocl_q_awaddr),    .m_axi_awprot  (),
   .m_axi_awvalid (ocl_q_awvalid),   .m_axi_awready (ocl_q_awready),
   .m_axi_wdata   (ocl_q_wdata),     .m_axi_wstrb   (ocl_q_wstrb),
   .m_axi_wvalid  (ocl_q_wvalid),    .m_axi_wready  (ocl_q_wready),
   .m_axi_bresp   (ocl_q_bresp),     .m_axi_bvalid  (ocl_q_bvalid),
   .m_axi_bready  (ocl_q_bready),
   .m_axi_araddr  (ocl_q_araddr),    .m_axi_arvalid (ocl_q_arvalid),
   .m_axi_arready (ocl_q_arready),
   .m_axi_rdata   (ocl_q_rdata),     .m_axi_rresp   (ocl_q_rresp),
   .m_axi_rvalid  (ocl_q_rvalid),    .m_axi_rready  (ocl_q_rready)
);

// ---- the kernel: bsw_axil_regs (16-bit / 64 KiB window off the 32-bit OCL BAR) --
bsw_axil_regs #(.ADDR_W(16), .DATA_W(32), .KERNEL_CDC(KCDC)) u_regs (
   .clk       (clk_main_a0),
   .rst_n     (rst_main_n_sync),
   .clk_k     (kernel_clk),
   .rst_k_n   (kernel_rst_n),
   .s_awaddr  (ocl_q_awaddr[15:0]), .s_awvalid (ocl_q_awvalid), .s_awready (ocl_q_awready),
   .s_wdata   (ocl_q_wdata),        .s_wstrb   (ocl_q_wstrb),
   .s_wvalid  (ocl_q_wvalid),       .s_wready  (ocl_q_wready),
   .s_bresp   (ocl_q_bresp),        .s_bvalid  (ocl_q_bvalid),  .s_bready  (ocl_q_bready),
   .s_araddr  (ocl_q_araddr[15:0]), .s_arvalid (ocl_q_arvalid), .s_arready (ocl_q_arready),
   .s_rdata   (ocl_q_rdata),        .s_rresp   (ocl_q_rresp),
   .s_rvalid  (ocl_q_rvalid),       .s_rready  (ocl_q_rready)
);

endmodule // cl_bsw_top

`else
// ===================== STANDALONE LINT PATH (no HDK) =====================
// Self-contained port list (clk/rst + OCL only) so the OCL glue elaborates without the
// Shell — same role as the F1 wrapper's lint path, with F2 signal names. NOT for
// synthesis. The REAL path above is covered by scripts/f2/lint_cl_bsw.sh.
module cl_bsw_top (
   input  logic        clk_main_a0,
   input  logic        rst_main_n,
   input  logic [31:0] ocl_cl_awaddr,  input  logic [54:0] ocl_cl_awuser,
   input  logic        ocl_cl_awvalid, output logic        cl_ocl_awready,
   input  logic [31:0] ocl_cl_wdata,   input  logic  [3:0] ocl_cl_wstrb,
   input  logic        ocl_cl_wvalid,  output logic        cl_ocl_wready,
   output logic  [1:0] cl_ocl_bresp,   output logic        cl_ocl_bvalid,
   input  logic        ocl_cl_bready,
   input  logic [31:0] ocl_cl_araddr,  input  logic [54:0] ocl_cl_aruser,
   input  logic        ocl_cl_arvalid, output logic        cl_ocl_arready,
   output logic [31:0] cl_ocl_rdata,   output logic  [1:0] cl_ocl_rresp,
   output logic        cl_ocl_rvalid,  input  logic        ocl_cl_rready
);
logic pre_sync_rst_n, rst_main_n_sync;
always_ff @(posedge clk_main_a0)
   if (!rst_main_n) {rst_main_n_sync, pre_sync_rst_n} <= 2'b00;
   else             {rst_main_n_sync, pre_sync_rst_n} <= {pre_sync_rst_n, 1'b1};

// Lint path drives the slave directly (no register slice IP available off-HDK).
bsw_axil_regs #(.ADDR_W(16), .DATA_W(32)) u_regs (
   .clk(clk_main_a0), .rst_n(rst_main_n_sync),
   .s_awaddr(ocl_cl_awaddr[15:0]), .s_awvalid(ocl_cl_awvalid), .s_awready(cl_ocl_awready),
   .s_wdata(ocl_cl_wdata), .s_wstrb(ocl_cl_wstrb), .s_wvalid(ocl_cl_wvalid), .s_wready(cl_ocl_wready),
   .s_bresp(cl_ocl_bresp), .s_bvalid(cl_ocl_bvalid), .s_bready(ocl_cl_bready),
   .s_araddr(ocl_cl_araddr[15:0]), .s_arvalid(ocl_cl_arvalid), .s_arready(cl_ocl_arready),
   .s_rdata(cl_ocl_rdata), .s_rresp(cl_ocl_rresp), .s_rvalid(cl_ocl_rvalid), .s_rready(ocl_cl_rready)
);
endmodule
`endif
