// bsw_top_flat.sv -- flat-port wrapper around bsw_top, for post-synthesis simulation.
//
// WHY THIS EXISTS
// ---------------------------------------------------------------------------
// bsw_top's request ports are SystemVerilog aggregates:
//     base_t [MAX_QLEN-1:0] query_i      (160 elements x 3 bits)
//     base_t [MAX_TLEN-1:0] target_i     (1024 elements x 3 bits)
//     bsw_config_t          cfg_i        (packed struct, 160 bits)
//     bsw_result_t          result_o     (packed struct, 97 bits)
//
// Vivado's `write_verilog -mode funcsim` does NOT preserve those as single vector
// ports. It SCALARIZES a packed array of vectors into one port per element, with
// escaped bracket names. The real netlist header from the 2026.1 run reads:
//
//     module bsw_top
//        (clk, rst_n, restart_mode, req_valid_i, req_ready_o,
//         \query_i[159] , \query_i[158] , \query_i[157] , ...
//
// So the netlist exposes ~1184 separate ports where the RTL had three, and
// tb_bsw_ext's `.query_i(query)` cannot bind to any of them -- there is no port
// called `query_i` at all. That is not a bug in anything; it is just how the
// writer flattens aggregates.
//
// This wrapper gives synthesis a top whose ports are PLAIN 1-D VECTORS, which the
// writer keeps intact. One testbench (tb_bsw_ext_flat) then drives both the RTL
// and the netlist unchanged, which is the whole point: a difference in results is
// then attributable to synthesis, not to differently-wired harnesses.
//
// It is pure rewiring -- continuous assignments only, no logic, no state. A packed
// struct and a packed array are bit-stream equivalent to a vector of the same
// width, so these assignments are width-exact and lossless.
//
// NOT part of the F2 design. The real design wraps bsw_top in bsw_axil_regs /
// cl_bsw_top, which have flat ports already. This lives under synth/ rather than
// rtl/ so nobody mistakes it for shipping hardware.

// NO include directive for bsw_pkg.sv here -- deliberately.
//
// An include directive resolves relative to the INCLUDING file's own directory.
// rtl/*.sv can include bsw_pkg.sv because it sits beside them; this file cannot,
// because it lives in synth/postsynth/. Vivado 2026.1 failed exactly there:
//   ERROR: [Synth 8-9263] cannot open include file 'bsw_pkg.sv'
//          [synth/postsynth/bsw_top_flat.sv:37]
// This was masked under Verilator, because run_sim.sh passes -I rtl.
//
// None is needed: every flow that compiles this file also compiles
// rtl/bsw_pkg.sv ahead of it, so `import bsw_pkg::*` resolves from the compilation
// unit. synth_and_netlist.tcl reads bsw_pkg.sv first, and run_sim.sh lists it as
// RTL_FILES[0].

// N_PE is driven by a DEFINE rather than a parameter, so both tools can shrink the
// array from one switch:
//     with Verilator:  +define+BSW_FLAT_NPE=8
//     with Vivado:     synth_design -verilog_define BSW_FLAT_NPE=8
//
// WHY A DEFINE AND NOT A PARAMETER: overriding a parameter from the command line
// (`-G` in Verilator, `-generic` in Vivado) only reaches the TOP module. Here the top
// is the testbench, which instantiates this wrapper without passing N_PE, so neither
// switch can reach it. A define reaches any file in the compilation.
//
// WHY SHRINK AT ALL: XSIM's BASIC licence tier refuses a design with more than
// 50,000 instances, and the 160-PE gate-level netlist has 166,514. A reduced array
// is the only way to get gate-level evidence on that licence. Vectors must then be
// restricted to qlen <= N_PE, since bsw_ctrl_fsm correctly REJECTS a longer query
// (error=1) rather than computing a wrong answer.
`ifndef BSW_FLAT_NPE
  `define BSW_FLAT_NPE BAND_WIDTH
`endif

module bsw_top_flat
    import bsw_pkg::*;
#(
    parameter int N_PE = `BSW_FLAT_NPE
)(
    input  logic                           clk,
    input  logic                           rst_n,
    input  logic                           restart_mode,

    input  logic                           req_valid_i,
    output logic                           req_ready_o,

    // 160 * 3 = 480
    input  logic [MAX_QLEN*BASE_WIDTH-1:0] query_flat_i,
    // 1024 * 3 = 3072
    input  logic [MAX_TLEN*BASE_WIDTH-1:0] target_flat_i,
    // 7 score_t + 3 len_t = 10 * 16 = 160
    input  logic [$bits(bsw_config_t)-1:0] cfg_flat_i,

    output logic                           result_valid_o,
    input  logic                           result_ready_i,
    // 1 + 2*16 + 4*16 = 97
    output logic [$bits(bsw_result_t)-1:0] result_flat_o
);

    base_t [MAX_QLEN-1:0] query;
    base_t [MAX_TLEN-1:0] target;
    bsw_config_t          cfg;
    bsw_result_t          result;

    assign query  = query_flat_i;
    assign target = target_flat_i;
    assign cfg    = cfg_flat_i;

    bsw_top #(.N_PE(N_PE)) u_bsw (
        .clk            (clk),
        .rst_n          (rst_n),
        .restart_mode   (restart_mode),
        .req_valid_i    (req_valid_i),
        .req_ready_o    (req_ready_o),
        .query_i        (query),
        .target_i       (target),
        .cfg_i          (cfg),
        .result_valid_o (result_valid_o),
        .result_ready_i (result_ready_i),
        .result_o       (result)
    );

    assign result_flat_o = result;

endmodule
