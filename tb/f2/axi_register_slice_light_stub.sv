// axi_register_slice_light_stub.sv — LINT/SIM-ONLY stand-in for the AWS/Xilinx
// `axi_register_slice_light` IP that cl_bsw_top instantiates on the OCL path.
//
// The real IP ships with the HDK/Vivado as generated IP, not as readable source, so it
// cannot be elaborated off-AWS. This stub has the SAME module name and the SAME port
// set, and passes every channel straight through combinationally, so that
// scripts/f2/lint_cl_bsw.sh can elaborate the REAL cl_bsw_top build path (real
// cl_ports.vh, real tie-offs) on this box.
//
// NOT synthesizable input to the AWS build — the build sees the real IP. This stub
// exists only so that a missing/renamed port on our side fails HERE instead of after a
// multi-hour DCP build. It is a pass-through, so it deliberately does NOT model the
// IP's pipeline latency; timing behaviour is not what this lint is checking.
module axi_register_slice_light (
   input  logic        aclk,
   input  logic        aresetn,

   input  logic [31:0] s_axi_awaddr,
   input  logic  [2:0] s_axi_awprot,
   input  logic        s_axi_awvalid,
   output logic        s_axi_awready,
   input  logic [31:0] s_axi_wdata,
   input  logic  [3:0] s_axi_wstrb,
   input  logic        s_axi_wvalid,
   output logic        s_axi_wready,
   output logic  [1:0] s_axi_bresp,
   output logic        s_axi_bvalid,
   input  logic        s_axi_bready,
   input  logic [31:0] s_axi_araddr,
   input  logic  [2:0] s_axi_arprot,
   input  logic        s_axi_arvalid,
   output logic        s_axi_arready,
   output logic [31:0] s_axi_rdata,
   output logic  [1:0] s_axi_rresp,
   output logic        s_axi_rvalid,
   input  logic        s_axi_rready,

   output logic [31:0] m_axi_awaddr,
   output logic  [2:0] m_axi_awprot,
   output logic        m_axi_awvalid,
   input  logic        m_axi_awready,
   output logic [31:0] m_axi_wdata,
   output logic  [3:0] m_axi_wstrb,
   output logic        m_axi_wvalid,
   input  logic        m_axi_wready,
   input  logic  [1:0] m_axi_bresp,
   input  logic        m_axi_bvalid,
   output logic        m_axi_bready,
   output logic [31:0] m_axi_araddr,
   output logic        m_axi_arvalid,
   input  logic        m_axi_arready,
   input  logic [31:0] m_axi_rdata,
   input  logic  [1:0] m_axi_rresp,
   input  logic        m_axi_rvalid,
   output logic        m_axi_rready
);
   always_comb begin
      m_axi_awaddr  = s_axi_awaddr;   m_axi_awprot  = s_axi_awprot;
      m_axi_awvalid = s_axi_awvalid;  s_axi_awready = m_axi_awready;
      m_axi_wdata   = s_axi_wdata;    m_axi_wstrb   = s_axi_wstrb;
      m_axi_wvalid  = s_axi_wvalid;   s_axi_wready  = m_axi_wready;
      s_axi_bresp   = m_axi_bresp;    s_axi_bvalid  = m_axi_bvalid;
      m_axi_bready  = s_axi_bready;
      m_axi_araddr  = s_axi_araddr;
      m_axi_arvalid = s_axi_arvalid;  s_axi_arready = m_axi_arready;
      s_axi_rdata   = m_axi_rdata;    s_axi_rresp   = m_axi_rresp;
      s_axi_rvalid  = m_axi_rvalid;   m_axi_rready  = s_axi_rready;
   end
endmodule
