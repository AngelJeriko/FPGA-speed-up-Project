// bsw_shared.sv
// Time-shared banded Smith-Waterman core. Holds ONE bsw_top and arbitrates it
// between two request channels that never run concurrently:
//   A = extend      (bsw_seed_unit,  restart_mode=0, banded)
//   B = mate-rescue (matesw_top,     restart_mode=1, local SW)
//
// The paired-end host runs BOTH extend passes to completion (ce_done) before it
// pulses sel_start (see chaining_pe2_top), so A and B are temporally disjoint. The
// arbiter latches an owner when a request is granted and releases it when the
// result handshake completes; whichever channel is not the owner sees req_ready=0
// and result_valid=0, so it simply waits.
//
// Because bsw_ctrl_fsm latches query/target/cfg the cycle it accepts a request
// (accept_req), the wide channel mux feeding the core is a LOAD-TIME path, not the
// array's runtime critical path. If that one-cycle path is ever tight, a single
// register stage on core_req here costs 1 cycle of request latency (nothing versus
// the hundreds of cycles per SW run).
//
// This module is instantiated ONLY in the integrated top (chaining_pe2_top, with
// SHARED_CORE=1 threaded down to the two leaves). Standalone module testbenches
// keep SHARED_CORE=0, so each leaf still owns a private bsw_top and every existing
// tb is unchanged.

`include "bsw_pkg.sv"

module bsw_shared
    import bsw_pkg::*;
#(
    parameter int N_PE = BAND_WIDTH
)(
    input  logic       clk,
    input  logic       rst_n,
    // Channel A: extend (bsw_seed_unit)
    input  bsw_creq_t  a_req_i,
    output bsw_cresp_t a_resp_o,
    // Channel B: mate-rescue (matesw_top)
    input  bsw_creq_t  b_req_i,
    output bsw_cresp_t b_resp_o
);
    localparam logic [1:0] OWN_NONE = 2'd0, OWN_A = 2'd1, OWN_B = 2'd2;
    logic [1:0] own;

    // Selection: hold the latched owner for the whole transaction; when idle, grant
    // to whoever is asking (A priority is arbitrary — the two never collide).
    logic [1:0] sel;
    always_comb begin
        if      (own != OWN_NONE)   sel = own;
        else if (a_req_i.req_valid)  sel = OWN_A;
        else if (b_req_i.req_valid)  sel = OWN_B;
        else                         sel = OWN_NONE;
    end

    // ---- core input mux ----
    bsw_creq_t core_req;
    always_comb begin
        unique case (sel)
            OWN_A:   core_req = a_req_i;
            OWN_B:   core_req = b_req_i;
            default: core_req = '0;
        endcase
    end

    logic        core_req_ready, core_result_valid;
    bsw_result_t core_result;

    bsw_top #(.N_PE(N_PE)) u_bsw (
        .clk(clk), .rst_n(rst_n),
        .restart_mode  (core_req.restart_mode),
        .req_valid_i   (core_req.req_valid),
        .req_ready_o   (core_req_ready),
        .query_i       (core_req.query),
        .target_i      (core_req.target),
        .cfg_i         (core_req.cfg),
        .result_valid_o(core_result_valid),
        .result_ready_i(core_req.result_ready),
        .result_o      (core_result)
    );

    // ---- response demux: result data fans out (harmless — gated by valid at the
    // consumer); req_ready/result_valid are asserted only to the current owner ----
    always_comb begin
        a_resp_o = '0;
        b_resp_o = '0;
        a_resp_o.result = core_result;
        b_resp_o.result = core_result;
        if (sel == OWN_A) begin
            a_resp_o.req_ready    = core_req_ready;
            a_resp_o.result_valid = core_result_valid;
        end else if (sel == OWN_B) begin
            b_resp_o.req_ready    = core_req_ready;
            b_resp_o.result_valid = core_result_valid;
        end
    end

    // ---- owner FSM: latch at grant, release when the result is taken ----
    wire core_finish = core_result_valid && core_req.result_ready;
    always_ff @(posedge clk) begin
        if (!rst_n) own <= OWN_NONE;
        else begin
            if (own == OWN_NONE) begin
                if      (a_req_i.req_valid) own <= OWN_A;
                else if (b_req_i.req_valid) own <= OWN_B;
            end else if (core_finish) begin
                own <= OWN_NONE;
            end
        end
    end
endmodule
