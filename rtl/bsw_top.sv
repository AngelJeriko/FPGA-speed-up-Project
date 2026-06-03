// bsw_top.sv
// Top-level banded Smith-Waterman accelerator.
// Glues the control FSM, systolic array, and max tracker behind a simple
// req/result handshake.

`include "bsw_pkg.sv"

module bsw_top
    import bsw_pkg::*;
#(
    parameter int N_PE = BAND_WIDTH
)(
    input  logic                       clk,
    input  logic                       rst_n,

    // Request handshake
    input  logic                       req_valid_i,
    output logic                       req_ready_o,
    input  base_t [MAX_QLEN-1:0]       query_i,
    input  base_t [MAX_TLEN-1:0]       target_i,
    input  bsw_config_t                cfg_i,

    // Result handshake
    output logic                       result_valid_o,
    input  logic                       result_ready_i,
    output bsw_result_t                result_o
);

    // ---- FSM <-> array ----
    logic                       sa_clear, sa_load_q, sa_active;
    base_t  [N_PE-1:0]          sa_query_bases;
    score_t [N_PE-1:0]          sa_init_h_curr;
    base_t                      sa_target;
    score_t                     sa_h_diag, sa_f;
    score_t                     sa_o_del, sa_e_del, sa_o_ins, sa_e_ins;

    // ---- FSM <-> tracker ----
    logic                       tr_clear, tr_start, tr_done;
    len_t                       tr_qlen, tr_tlen;
    score_t                     tr_h0, tr_zdrop, tr_e_del, tr_e_ins;
    logic                       zdrop_break, dead_row;

    // ---- Array -> tracker ----
    logic   [N_PE-1:0]          cell_valid;
    score_t [N_PE-1:0]          h_cells;
    score_t [N_PE-1:0]          e_cells;

    // ---- Result wire ----
    bsw_result_t                tracker_result;

    // ---- FSM ----
    bsw_ctrl_fsm #(.N_PE(N_PE)) u_fsm (
        .clk             (clk),
        .rst_n           (rst_n),
        .req_valid_i     (req_valid_i),
        .req_ready_o     (req_ready_o),
        .query_i         (query_i),
        .target_i        (target_i),
        .cfg_i           (cfg_i),
        .sa_clear_o      (sa_clear),
        .sa_load_q_o     (sa_load_q),
        .sa_query_bases_o(sa_query_bases),
        .sa_init_h_curr_o(sa_init_h_curr),
        .sa_active_o     (sa_active),
        .sa_target_o     (sa_target),
        .sa_h_diag_o     (sa_h_diag),
        .sa_f_o          (sa_f),
        .sa_o_del_o      (sa_o_del),
        .sa_e_del_o      (sa_e_del),
        .sa_o_ins_o      (sa_o_ins),
        .sa_e_ins_o      (sa_e_ins),
        .tr_clear_o      (tr_clear),
        .tr_start_o      (tr_start),
        .tr_done_o       (tr_done),
        .tr_qlen_o       (tr_qlen),
        .tr_tlen_o       (tr_tlen),
        .tr_h0_o         (tr_h0),
        .tr_zdrop_o      (tr_zdrop),
        .tr_e_del_o      (tr_e_del),
        .tr_e_ins_o      (tr_e_ins),
        .zdrop_break_i   (zdrop_break),
        .dead_row_i      (dead_row),
        .result_i        (tracker_result),
        .result_valid_o  (result_valid_o),
        .result_ready_i  (result_ready_i),
        .result_o        (result_o)
    );

    // Drain wires from array (unused at top level but kept for future hookup)
    logic   sa_last_active;
    base_t  sa_last_target;
    score_t sa_last_h_diag, sa_last_h_left, sa_last_f;

    // ---- Systolic array ----
    bsw_systolic_array #(.N_PE(N_PE)) u_array (
        .clk             (clk),
        .rst_n           (rst_n),
        .clear_i         (sa_clear),
        .load_q_i        (sa_load_q),
        .query_bases_i   (sa_query_bases),
        .init_h_curr_i   (sa_init_h_curr),
        .o_del_i         (sa_o_del),
        .e_del_i         (sa_e_del),
        .o_ins_i         (sa_o_ins),
        .e_ins_i         (sa_e_ins),
        .active_in       (sa_active),
        .target_in       (sa_target),
        .h_diag_in       (sa_h_diag),
        .f_in            (sa_f),
        .cell_valid_o    (cell_valid),
        .h_cells_o       (h_cells),
        .e_cells_o       (e_cells),
        .last_active_o   (sa_last_active),
        .last_target_o   (sa_last_target),
        .last_h_diag_o   (sa_last_h_diag),
        .last_h_left_o   (sa_last_h_left),
        .last_f_o        (sa_last_f)
    );

    // ---- Max tracker ----
    bsw_max_tracker #(.N_PE(N_PE)) u_tracker (
        .clk             (clk),
        .rst_n           (rst_n),
        .clear_i         (tr_clear),
        .start_i         (tr_start),
        .done_i          (tr_done),
        .qlen_i          (tr_qlen),
        .tlen_i          (tr_tlen),
        .h0_i            (tr_h0),
        .zdrop_i         (tr_zdrop),
        .e_del_i         (tr_e_del),
        .e_ins_i         (tr_e_ins),
        .cell_valid_i    (cell_valid),
        .h_cells_i       (h_cells),
        .result_o        (tracker_result),
        .zdrop_break_o   (zdrop_break),
        .dead_row_o      (dead_row)
    );

endmodule
