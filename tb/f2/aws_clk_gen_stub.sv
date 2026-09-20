// aws_clk_gen_stub.sv - LINT-ONLY stand-in for the HDK's aws_clk_gen (hdk/common/lib).
//
// The real module builds MMCMs out of Xilinx primitives, so Verilator cannot elaborate
// it off-AWS. This stub carries the SAME module name and the SAME 40-port list,
// generated mechanically from the real file so that a port rename in a future HDK shows
// up here as a lint error instead of as a surprise mid-build. Every clock output is
// driven from i_clk_main_a0 and every reset output from i_rst_main_n.
//
// It exists ONLY so scripts/f2/lint_cl_bsw.sh --cdc can elaborate the REAL two-clock
// build path of cl_bsw_top. It deliberately does NOT model frequency, phase, or the
// AXI-Lite control interface: this lint checks STRUCTURE, never timing. The functional
// proof of the crossing is tb_bsw_axil_cdc, which drives two genuinely unrelated clocks.
//
// Because every output here is the same clock, a design that only "works" when the two
// domains are identical would still pass this lint -- which is precisely why the
// crossing is proven by the testbench and not by this file.
//
// NOT synthesizable input to the AWS build - that build reads the real module.
module aws_clk_gen
  #(
    parameter CLK_GRP_A_EN = 1,
    parameter CLK_GRP_B_EN = 1,
    parameter CLK_GRP_C_EN = 1,
    parameter CLK_HBM_EN   = 1
    )
   (
    input  logic            i_clk_main_a0,
    input  logic            i_rst_main_n,
    input  logic            i_clk_hbm_ref,
    input  logic [31:0]     s_axil_ctrl_awaddr,
    input  logic            s_axil_ctrl_awvalid,
    output logic            s_axil_ctrl_awready,
    input  logic [31:0]     s_axil_ctrl_wdata,
    input  logic [3:0]      s_axil_ctrl_wstrb,
    input  logic            s_axil_ctrl_wvalid,
    output logic            s_axil_ctrl_wready,
    output logic [1:0]      s_axil_ctrl_bresp,
    output logic            s_axil_ctrl_bvalid,
    input  logic            s_axil_ctrl_bready,
    input  logic [31:0]     s_axil_ctrl_araddr,
    input  logic            s_axil_ctrl_arvalid,
    output logic            s_axil_ctrl_arready,
    output logic [31:0]     s_axil_ctrl_rdata,
    output logic [1:0]      s_axil_ctrl_rresp,
    output logic            s_axil_ctrl_rvalid,
    input  logic            s_axil_ctrl_rready,
    output logic            o_clk_hbm_ref,
    output logic            o_clk_main_a0,
    output logic            o_clk_extra_a1,
    output logic            o_clk_extra_a2,
    output logic            o_clk_extra_a3,
    output logic            o_clk_extra_b0,
    output logic            o_clk_extra_b1,
    output logic            o_clk_extra_c0,
    output logic            o_clk_extra_c1,
    output logic            o_clk_hbm_axi,
    output logic            o_cl_rst_hbm_axi_n,
    output logic            o_cl_rst_hbm_ref_n,
    output logic            o_cl_rst_c1_n,
    output logic            o_cl_rst_c0_n,
    output logic            o_cl_rst_b1_n,
    output logic            o_cl_rst_b0_n,
    output logic            o_cl_rst_a3_n,
    output logic            o_cl_rst_a2_n,
    output logic            o_cl_rst_a1_n,
    output logic            o_cl_rst_main_n
    );

   assign s_axil_ctrl_awready    = '0;
   assign s_axil_ctrl_wready     = '0;
   assign s_axil_ctrl_bresp      = '0;
   assign s_axil_ctrl_bvalid     = '0;
   assign s_axil_ctrl_arready    = '0;
   assign s_axil_ctrl_rdata      = '0;
   assign s_axil_ctrl_rresp      = '0;
   assign s_axil_ctrl_rvalid     = '0;
   assign o_clk_hbm_ref          = i_clk_main_a0;
   assign o_clk_main_a0          = i_clk_main_a0;
   assign o_clk_extra_a1         = i_clk_main_a0;
   assign o_clk_extra_a2         = i_clk_main_a0;
   assign o_clk_extra_a3         = i_clk_main_a0;
   assign o_clk_extra_b0         = i_clk_main_a0;
   assign o_clk_extra_b1         = i_clk_main_a0;
   assign o_clk_extra_c0         = i_clk_main_a0;
   assign o_clk_extra_c1         = i_clk_main_a0;
   assign o_clk_hbm_axi          = i_clk_main_a0;
   assign o_cl_rst_hbm_axi_n     = i_rst_main_n;
   assign o_cl_rst_hbm_ref_n     = i_rst_main_n;
   assign o_cl_rst_c1_n          = i_rst_main_n;
   assign o_cl_rst_c0_n          = i_rst_main_n;
   assign o_cl_rst_b1_n          = i_rst_main_n;
   assign o_cl_rst_b0_n          = i_rst_main_n;
   assign o_cl_rst_a3_n          = i_rst_main_n;
   assign o_cl_rst_a2_n          = i_rst_main_n;
   assign o_cl_rst_a1_n          = i_rst_main_n;
   assign o_cl_rst_main_n        = i_rst_main_n;

endmodule
