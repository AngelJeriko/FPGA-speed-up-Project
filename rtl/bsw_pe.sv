// bsw_pe.sv
// One Processing Element of the banded Smith-Waterman systolic array.
//
// Timing model (anti-diagonal wavefront):
//   At cycle t, PE_j processes cell (i, j) where i = t - j.
//   Each PE registers all outputs to the right neighbor.
//
//   Dependencies for cell (i, j):
//     - H(i-1, j-1)   : diagonal      — comes from PE_{j-1} two cycles ago
//     - F(i, j-1)     : left (gap-x)  — comes from PE_{j-1} one cycle ago
//     - E(i, j)       : own column    — held in this PE's E register
//     - S(query[j], target[i])        : substitution score
//
//   Recurrence (from bandedSWA.cpp lines 178-198):
//     M           = (H_diag != 0) ? H_diag + S : 0
//     H_new       = max(M, E_reg, F_in, 0)
//     E_new       = max(H_new - (o_del+e_del), E_reg - e_del,   0)
//     F_new       = max(H_new - (o_ins+e_ins), F_in   - e_ins,  0)
//
// Output H is exposed in two registered taps:
//     H_left_o = H_curr_reg = H computed last cycle (= H(i-1, j) when PE_{j+1} reads it)
//     H_diag_o = H_prev_reg = H computed two cycles ago (= H(i-1, j-1) for PE_{j+1})
//
// active_i is a pipelined valid bit travelling with the wavefront.
// load_q_i pulses once at start of an alignment to capture query_base_i.
// clear_i resets per-PE accumulators (E/F/H) between alignments.

`include "bsw_pkg.sv"

module bsw_pe
    import bsw_pkg::*;
(
    input  logic        clk,
    input  logic        rst_n,         // sync, active-low

    // Per-alignment control
    input  logic        clear_i,       // clear E/F/H/valid at start of new alignment
    input  logic        load_q_i,      // capture query_base_i + init_h_curr_i
    input  base_t       query_base_i,
    input  score_t      init_h_curr_i, // initial H state ( = eh[j] from C++ first-row init)

    // Penalties (broadcast from config; positive magnitudes)
    input  score_t      o_del_i,
    input  score_t      e_del_i,
    input  score_t      o_ins_i,
    input  score_t      e_ins_i,

    // Wavefront inputs (from PE_{j-1})
    input  logic        active_i,
    input  base_t       target_i,
    input  score_t      h_diag_i,      // H(i-1, j-1)
    input  score_t      f_i,           // F(i, j-1)

    // Wavefront outputs (to PE_{j+1}, all registered)
    output logic        active_o,
    output base_t       target_o,
    output score_t      h_diag_o,      // = H_prev_reg (2-cycle-delayed H)
    output score_t      h_left_o,      // = H_curr_reg (1-cycle-delayed H), exposed for tap/debug
    output score_t      f_o,

    // Local taps for the max tracker / FSM
    output logic        cell_valid_o,  // pulses when this PE produced a valid cell
    output score_t      h_cell_o,      // H(i, j) just registered into H_curr_reg
    output score_t      e_cell_o       // E_reg after update
);

    // ---- Stored config ----
    base_t  query_base_reg;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            query_base_reg <= '0;
        end else if (load_q_i) begin
            query_base_reg <= query_base_i;
        end
    end

    // ---- Substitution score (combinational LUT) ----
    score_t s_match;
    bsw_score_matrix u_score (
        .q (query_base_reg),
        .t (target_i),
        .s (s_match)
    );

    // ---- DP recurrence (combinational) ----
    score_t E_reg, F_out_reg;
    score_t H_curr_reg, H_prev_reg;

    score_t M_term, H_max_ME, H_max_MEF, H_new;
    score_t oe_del, E_open, E_ext, E_pick, E_new;
    score_t oe_ins, F_open, F_ext, F_pick, F_new;
    logic   diag_nz;

    // Signed zero used for clamps. Unsized '0 is treated as unsigned in
    // comparison context and silently breaks the negative-value clamps.
    localparam score_t SZERO = score_t'(0);

    always_comb begin
        // M = (H_diag != 0) ? H_diag + S : 0
        // The "!= 0" check disallows starting an alignment from a zero cell mid-way,
        // mirroring the C++ "M? M + q[j] : 0" idiom.
        diag_nz   = (h_diag_i != SZERO);
        M_term    = diag_nz ? (h_diag_i + s_match) : SZERO;

        // H_new = max(M, E, F, 0)
        H_max_ME  = (M_term   > E_reg) ? M_term   : E_reg;
        H_max_MEF = (H_max_ME > f_i)   ? H_max_ME : f_i;
        H_new     = (H_max_MEF > SZERO) ? H_max_MEF : SZERO;

        // E_new = max(H_new - (o_del+e_del), E - e_del, 0)
        oe_del = o_del_i + e_del_i;
        E_open = H_new - oe_del;
        E_ext  = E_reg - e_del_i;
        E_pick = (E_open > E_ext)  ? E_open : E_ext;
        E_new  = (E_pick > SZERO)  ? E_pick : SZERO;

        // F_new = max(H_new - (o_ins+e_ins), F_in - e_ins, 0)
        oe_ins = o_ins_i + e_ins_i;
        F_open = H_new - oe_ins;
        F_ext  = f_i   - e_ins_i;
        F_pick = (F_open > F_ext)  ? F_open : F_ext;
        F_new  = (F_pick > SZERO)  ? F_pick : SZERO;
    end

    // ---- State update ----
    logic active_q;
    base_t target_q;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            E_reg      <= '0;
            F_out_reg  <= '0;
            H_curr_reg <= '0;
            H_prev_reg <= '0;
            active_q   <= 1'b0;
            target_q   <= '0;
        end else if (clear_i) begin
            // Clear at start of alignment. If load_q_i is asserted at the same
            // time (FSM does both during S_LOAD), pre-load H_curr_reg with the
            // first-row boundary value eh[j]; otherwise just clear.
            E_reg      <= '0;
            F_out_reg  <= '0;
            H_curr_reg <= load_q_i ? init_h_curr_i : '0;
            H_prev_reg <= '0;
            active_q   <= 1'b0;
            target_q   <= '0;
        end else begin
            // Pipeline shift always happens so the wavefront propagates.
            active_q   <= active_i;
            target_q   <= target_i;
            H_prev_reg <= H_curr_reg;

            if (active_i) begin
                H_curr_reg <= H_new;
                E_reg      <= E_new;
                F_out_reg  <= F_new;
            end else begin
                // Hold H_curr_reg's roll into H_prev_reg above, but freeze the live state
                H_curr_reg <= H_curr_reg;
                E_reg      <= E_reg;
                F_out_reg  <= F_out_reg;
            end
        end
    end

    // ---- Outputs ----
    assign active_o     = active_q;
    assign target_o     = target_q;
    assign h_left_o     = H_curr_reg;
    assign h_diag_o     = H_prev_reg;
    assign f_o          = F_out_reg;

    assign cell_valid_o = active_q;     // H_curr_reg is the cell PE just produced
    assign h_cell_o     = H_curr_reg;
    assign e_cell_o     = E_reg;

endmodule
