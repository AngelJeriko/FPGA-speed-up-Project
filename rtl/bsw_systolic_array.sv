// bsw_systolic_array.sv
// Linear chain of N_PE bsw_pe instances forming the SW wavefront.
//
// Query is held stationary: PE_j stores query[j] for the alignment.
// Target streams in from PE_0 and shifts right one PE per cycle.
// The first PE sees H_diag=0, F=0 on its left boundary.
//
// All per-PE taps (cell_valid, h_cell, e_cell) are exposed as packed arrays
// so the max-tracker module can scan every cell as it is produced.
//
// Limitation (first version): qlen must be <= N_PE. Wider queries require
// swath processing with state save/restore at the band boundary — TODO.

`include "bsw_pkg.sv"

module bsw_systolic_array
    import bsw_pkg::*;
#(
    parameter int N_PE = BAND_WIDTH
)(
    input  logic                    clk,
    input  logic                    rst_n,

    // Per-alignment control
    input  logic                    clear_i,
    input  logic                    load_q_i,
    input  logic                    restart_mode,    // 0=extension, 1=local SW (mate-rescue)
    input  base_t  [N_PE-1:0]       query_bases_i,
    input  score_t [N_PE-1:0]       init_h_curr_i,   // eh[j] per-PE init for first row

    // Penalties (broadcast)
    input  score_t                  o_del_i,
    input  score_t                  e_del_i,
    input  score_t                  o_ins_i,
    input  score_t                  e_ins_i,

    // Wavefront injection at PE_0
    input  logic                    active_in,
    input  base_t                   target_in,
    input  score_t                  h_diag_in,   // typically 0
    input  score_t                  f_in,        // typically 0

    // Per-PE taps for the max tracker
    output logic   [N_PE-1:0]       cell_valid_o,
    output score_t [N_PE-1:0]       h_cells_o,
    output score_t [N_PE-1:0]       e_cells_o,

    // Drain from PE_{N-1}
    output logic                    last_active_o,
    output base_t                   last_target_o,
    output score_t                  last_h_diag_o,
    output score_t                  last_h_left_o,
    output score_t                  last_f_o
);

    // Inter-PE wires. Use index [j] = wire from PE_{j-1} to PE_j.
    // Index [0] is the array boundary inputs.
    logic   [N_PE:0]            chain_active;
    base_t  [N_PE:0]            chain_target;
    score_t [N_PE:0]            chain_h_diag;
    score_t [N_PE:0]            chain_h_left;  // exposed for debug only
    score_t [N_PE:0]            chain_f;

    assign chain_active[0] = active_in;
    assign chain_target[0] = target_in;
    assign chain_h_diag[0] = h_diag_in;
    assign chain_h_left[0] = '0;
    assign chain_f[0]      = f_in;

    genvar j;
    generate
        for (j = 0; j < N_PE; j++) begin : g_pe
            bsw_pe u_pe (
                .clk          (clk),
                .rst_n        (rst_n),
                .clear_i      (clear_i),
                .load_q_i     (load_q_i),
                .restart_mode (restart_mode),
                .query_base_i (query_bases_i[j]),
                .init_h_curr_i(init_h_curr_i[j]),
                .o_del_i      (o_del_i),
                .e_del_i      (e_del_i),
                .o_ins_i      (o_ins_i),
                .e_ins_i      (e_ins_i),
                .active_i     (chain_active[j]),
                .target_i     (chain_target[j]),
                .h_diag_i     (chain_h_diag[j]),
                .f_i          (chain_f[j]),
                .active_o     (chain_active[j+1]),
                .target_o     (chain_target[j+1]),
                .h_diag_o     (chain_h_diag[j+1]),
                .h_left_o     (chain_h_left[j+1]),
                .f_o          (chain_f[j+1]),
                .cell_valid_o (cell_valid_o[j]),
                .h_cell_o     (h_cells_o[j]),
                .e_cell_o     (e_cells_o[j])
            );
        end
    endgenerate

    assign last_active_o  = chain_active[N_PE];
    assign last_target_o  = chain_target[N_PE];
    assign last_h_diag_o  = chain_h_diag[N_PE];
    assign last_h_left_o  = chain_h_left[N_PE];
    assign last_f_o       = chain_f[N_PE];

endmodule
