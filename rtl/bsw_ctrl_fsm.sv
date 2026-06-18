// bsw_ctrl_fsm.sv
// Top-level control FSM. Orchestrates one alignment from the request handshake
// through array warmup, target streaming, drain, and result presentation.
//
// State sequence
// --------------
//   S_IDLE   : assert req_ready_o, wait for req_valid_i
//   S_LOAD   : pulse clear and load_q, broadcast query bases to the array,
//              broadcast penalties, latch target and config
//   S_RUN    : drive active_o=1, stream target[t_idx] -> PE_0 for tlen cycles
//              (or until zdrop_break / dead_row)
//   S_DRAIN  : active_o=0; let the wavefront propagate to the right edge and
//              the row pipeline finalise the last row (qlen + small margin)
//   S_DONE   : pulse tracker_done_o, present result_o with result_valid_o,
//              wait for result_ready_i
//
// Storage
// -------
// Query (MAX_QLEN) and target (MAX_TLEN) are latched into local memories on
// S_LOAD entry. For V1 these are flop-based; production would map them to
// M20K / BRAM.

`include "bsw_pkg.sv"

module bsw_ctrl_fsm
    import bsw_pkg::*;
#(
    parameter int N_PE = BAND_WIDTH
)(
    input  logic                       clk,
    input  logic                       rst_n,

    // ---- Request from host ----
    input  logic                       req_valid_i,
    output logic                       req_ready_o,
    input  base_t [MAX_QLEN-1:0]       query_i,
    input  base_t [MAX_TLEN-1:0]       target_i,
    input  bsw_config_t                cfg_i,

    // ---- To systolic array ----
    output logic                       sa_clear_o,
    output logic                       sa_load_q_o,
    output base_t [N_PE-1:0]           sa_query_bases_o,
    output score_t [N_PE-1:0]          sa_init_h_curr_o, // eh[j] per-PE
    output logic                       sa_active_o,
    output base_t                      sa_target_o,
    output score_t                     sa_h_diag_o,
    output score_t                     sa_f_o,
    output score_t                     sa_o_del_o,
    output score_t                     sa_e_del_o,
    output score_t                     sa_o_ins_o,
    output score_t                     sa_e_ins_o,

    // ---- To max tracker ----
    output logic                       tr_clear_o,
    output logic                       tr_start_o,
    output logic                       tr_done_o,
    output len_t                       tr_qlen_o,
    output len_t                       tr_tlen_o,
    output score_t                     tr_h0_o,
    output score_t                     tr_zdrop_o,
    output score_t                     tr_e_del_o,
    output score_t                     tr_e_ins_o,

    // ---- Tracker -> FSM (early-exit) ----
    input  logic                       zdrop_break_i,
    input  logic                       dead_row_i,

    // ---- Result handshake to host ----
    input  bsw_result_t                result_i,
    output logic                       result_valid_o,
    input  logic                       result_ready_i,
    output bsw_result_t                result_o
);

    // ---- State ----
    typedef enum logic [2:0] {
        S_IDLE   = 3'd0,
        S_LOAD   = 3'd1,
        S_RUN    = 3'd2,
        S_DRAIN  = 3'd3,
        S_DONE   = 3'd4,
        S_REJECT = 3'd5   // qlen > N_PE: skip to S_DONE with error=1
    } state_e;

    state_e state, state_n;

    // Latched oversize flag: set at request capture when qlen > N_PE so the
    // result-emit path returns an error rather than stale tracker data.
    logic oversize_q;

    // ---- Latched config + sequences ----
    bsw_config_t                cfg_q;
    base_t [MAX_QLEN-1:0]       query_q;
    base_t [MAX_TLEN-1:0]       target_q;

    // Direct DONE -> LOAD handoff: the host can submit the next request while
    // the previous result is being collected. accept_req is the cycle in which
    // the FSM consumes (cfg_i, query_i, target_i) -- either we're idle, or we're
    // in DONE and the host is taking the result this cycle. See
    // docs/speedup_plan.md (B).
    wire accept_req = req_valid_i &&
                      ((state == S_IDLE) ||
                       (state == S_DONE && result_ready_i));

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            cfg_q      <= '0;
            query_q    <= '0;
            target_q   <= '0;
            oversize_q <= 1'b0;
        end else if (accept_req) begin
            cfg_q      <= cfg_i;
            query_q    <= query_i;
            target_q   <= target_i;
            oversize_q <= (cfg_i.qlen > len_t'(N_PE));
        end
    end

    // ---- Counters ----
    len_t t_idx;        // target stream index 0..tlen-1
    len_t drain_cnt;    // remaining drain cycles

    // Margin: 1 cycle of PE input register + N_PE stages of row pipeline + 1.
    // We don't strictly need N_PE; we need qlen-1 stages of the row pipeline to
    // graduate. Use cfg_q.qlen + 4 as a safe margin (covers PE latency and 1
    // tracker register).
    wire len_t drain_total = cfg_q.qlen + len_t'(4);

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            t_idx     <= '0;
            drain_cnt <= '0;
        end else begin
            unique case (state)
                S_LOAD: begin
                    t_idx <= '0;
                end
                S_RUN: begin
                    if (t_idx < cfg_q.tlen) t_idx <= t_idx + len_t'(1);
                    if (state_n == S_DRAIN) drain_cnt <= drain_total;
                end
                S_DRAIN: begin
                    if (drain_cnt != '0) drain_cnt <= drain_cnt - len_t'(1);
                end
                default: ;
            endcase
        end
    end

    // ---- Next-state ----
    always_comb begin
        state_n = state;
        unique case (state)
            S_IDLE  : if (req_valid_i)
                          state_n = (cfg_i.qlen > len_t'(N_PE)) ? S_REJECT : S_LOAD;
            S_LOAD  :                                         state_n = S_RUN;
            S_REJECT:                                         state_n = S_DONE;
            // S_DONE -> S_LOAD/S_REJECT directly when the host has the next
            // request queued (req_valid_i high), saving the IDLE cycle. If the
            // host is just consuming the result, fall back to S_IDLE.
            S_DONE  : if (result_ready_i) begin
                          if (req_valid_i)
                              state_n = (cfg_i.qlen > len_t'(N_PE)) ? S_REJECT : S_LOAD;
                          else
                              state_n = S_IDLE;
                      end
            S_RUN   : if ((t_idx == cfg_q.tlen - len_t'(1))
                          || zdrop_break_i || dead_row_i)     state_n = S_DRAIN;
            // S_DRAIN intentionally ignores zdrop_break_i / dead_row_i: those
            // signals are sticky in the tracker (cleared only by the next
            // alignment's clear pulse), so re-checking them here would skip
            // the drain entirely the moment we entered DRAIN via z-drop. The
            // drain MUST run for drain_total cycles so that cells already in
            // flight in the systolic array can graduate into glob_max — that's
            // what preserves accuracy in the presence of an early z-drop exit.
            S_DRAIN : if (drain_cnt == len_t'(1))             state_n = S_DONE;
        endcase
    end

    always_ff @(posedge clk) begin
        if (!rst_n) state <= S_IDLE;
        else        state <= state_n;
    end

    // One-cycle-delayed view of state, used to detect first cycle of S_RUN.
    state_e state_q;
    always_ff @(posedge clk) begin
        if (!rst_n) state_q <= S_IDLE;
        else        state_q <= state;
    end

    // ---- Query packing into PE array (parallel load) ----
    // PEs 0..qlen-1 get query[0..qlen-1]. PEs qlen..N_PE-1 get sentinel (N=4).
    always_comb begin
        for (int k = 0; k < N_PE; k++) begin
            if (k < int'(cfg_q.qlen)) begin
                sa_query_bases_o[k] = query_q[k[$clog2(MAX_QLEN)-1:0]];
            end else begin
                sa_query_bases_o[k] = base_t'(4);   // N
            end
        end
    end

    // ---- First-row eh[] init (combinational saturating-subtract ladder) ----
    // Mirrors C++ scalarBandedSWA:
    //   eh[0] = h0
    //   eh[1] = max(h0 - (o_ins + e_ins), 0)
    //   eh[j] = max(eh[j-1] - e_ins, 0)   for j >= 2  (while > e_ins; else 0)
    // We feed this to each PE_j as its initial H_curr_reg value so that the
    // wavefront chain delivers the correct H_diag for each PE's first cell.
    score_t eh_init [N_PE];
    score_t oe_ins_w;
    assign oe_ins_w = cfg_q.o_ins + cfg_q.e_ins;

    score_t eh_sub  [N_PE];
    score_t eh_diff [N_PE];
    always_comb begin
        eh_init[0] = cfg_q.h0;
        eh_sub[0]  = '0;
        eh_diff[0] = '0;
        for (int j = 1; j < N_PE; j++) begin
            eh_sub[j]  = (j == 1) ? oe_ins_w : cfg_q.e_ins;
            eh_diff[j] = eh_init[j-1] - eh_sub[j];
            eh_init[j] = (eh_diff[j] > score_t'(0)) ? eh_diff[j] : score_t'(0);
        end
    end

    always_comb begin
        // Off-by-one fix: PE_k's preloaded H_curr_reg only matters as the value
        // that rolls into H_prev_reg and is delivered as the ROW-0 diagonal to
        // PE_{k+1}. ksw uses M(0,j) = eh_init[j], so PE_{k+1}'s (0,k+1) diagonal
        // must be eh_init[k+1] -> PE_k must preload eh_init[k+1] (NOT eh_init[k]).
        // PE_0's own (0,0) diagonal comes from bound_reg (= h0 = eh_init[0]), and
        // row>=1 diagonals come from real computed cells, so only this row-0
        // boundary mapping is affected. The last PE feeds no one (drive 0).
        for (int k = 0; k < N_PE; k++) begin
            sa_init_h_curr_o[k] = (k + 1 < N_PE) ? eh_init[k+1] : score_t'(0);
        end
    end

    // ---- PE_0 column boundary (h_diag) — decaying register ----
    // Mirrors C++ "h1 = h0 - (o_del + e_del*(i+1))" clamped to 0 for the
    // first column of each row. We stream this into PE_0 as h_diag for cell
    // (i, 0). Decays by oe_del once (between row 0 and row 1) then by e_del
    // each subsequent row, saturated at 0.
    score_t bound_reg;
    logic   bound_first;   // 1 until we've applied the first (oe_del) decay
    score_t oe_del_w;
    score_t bound_dec_amt;
    score_t bound_diff;
    assign oe_del_w      = cfg_q.o_del + cfg_q.e_del;
    assign bound_dec_amt = bound_first ? oe_del_w : cfg_q.e_del;
    assign bound_diff    = bound_reg - bound_dec_amt;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            bound_reg   <= '0;
            bound_first <= 1'b0;
        end else if (state == S_LOAD && state_n == S_RUN) begin
            // Entering S_RUN: PE_0 will see h_diag = h0 on its first active cycle.
            bound_reg   <= cfg_q.h0;
            bound_first <= 1'b1;
        end else if (state == S_RUN && sa_active_o) begin
            bound_reg   <= (bound_diff > score_t'(0)) ? bound_diff : score_t'(0);
            bound_first <= 1'b0;
        end
    end

    // ---- Outputs ----
    // Accept new requests either in IDLE or in DONE while the host is taking
    // the current result. This is the visible half of the direct DONE -> LOAD
    // handoff (B); together with accept_req it forms a valid/ready pair the
    // host can drive every cycle.
    assign req_ready_o = (state == S_IDLE) ||
                         (state == S_DONE && result_ready_i);

    // Pulses
    assign sa_clear_o     = (state == S_LOAD);
    assign sa_load_q_o    = (state == S_LOAD);
    assign tr_clear_o     = (state == S_LOAD);
    // Fire tr_start_o on the FIRST cycle of S_RUN (not on the S_LOAD->S_RUN
    // transition). This guarantees tr_clear_o is low when tr_start_o is high,
    // so the tracker's cyc counter actually advances.
    assign tr_start_o     = (state == S_RUN) && (state_q != S_RUN);
    assign tr_done_o      = (state == S_DRAIN) && (state_n == S_DONE);

    // Streaming
    assign sa_active_o    = (state == S_RUN) && (t_idx < cfg_q.tlen);
    assign sa_target_o    = (state == S_RUN) ? target_q[t_idx[$clog2(MAX_TLEN)-1:0]]
                                              : base_t'(0);
    assign sa_h_diag_o    = bound_reg;   // first-column boundary for PE_0
    assign sa_f_o         = '0;          // F(i, -1) = 0

    // Penalty broadcast (constant during alignment)
    assign sa_o_del_o     = cfg_q.o_del;
    assign sa_e_del_o     = cfg_q.e_del;
    assign sa_o_ins_o     = cfg_q.o_ins;
    assign sa_e_ins_o     = cfg_q.e_ins;

    // Tracker config broadcast
    assign tr_qlen_o      = cfg_q.qlen;
    assign tr_tlen_o      = cfg_q.tlen;
    assign tr_h0_o        = cfg_q.h0;
    assign tr_zdrop_o     = cfg_q.zdrop;
    assign tr_e_del_o     = cfg_q.e_del;
    assign tr_e_ins_o     = cfg_q.e_ins;

    // Result presentation. When oversize_q is set the request bypassed the
    // tracker, so result_i is stale (whatever was latched on the last good
    // alignment). Override with all-zeros + error=1 so the host can detect the
    // rejection unambiguously.
    assign result_valid_o = (state == S_DONE);
    always_comb begin
        if (oversize_q) begin
            result_o       = '0;
            result_o.error = 1'b1;
        end else begin
            result_o       = result_i;
            result_o.error = 1'b0;
        end
    end

endmodule
