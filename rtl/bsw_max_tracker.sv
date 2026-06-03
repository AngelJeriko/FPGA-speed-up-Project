// bsw_max_tracker.sv
// Tracks per-row maxima, global max, gscore, max_off, and zdrop early-exit.
// Reference: bandedSWA.cpp lines 158-222 (post-DP-inner-loop bookkeeping).
//
// Approach
// --------
// The systolic array emits cells along anti-diagonals: at cycle t, PE_j taps
// the cell (i,j) with i = (t - 1) - j (one cycle of register latency after
// active_i was high). To recover per-row statistics from that schedule we use
// a row_max pipeline of N_PE stages that flows in lockstep with the wavefront:
//
//   stage 0 sees PE_0's cell    (column 0 of some row, fresh start)
//   stage k sees PE_k's cell    (column k of the same row, k cycles later)
//
// At each cycle, stage k holds the running (max, argmax_j) for the row whose
// cells are currently being produced by PE_k. When the wave reaches stage
// qlen-1 the row is complete and its (m, mj) is final.
//
// Per cell we *also* update the global running max (score, max_i, max_j,
// max_off) directly from every active PE tap. That's cheap and removes any
// dependency on the row pipeline for the global score.
//
// Limitations (V1)
// ----------------
//   * Assumes qlen <= N_PE (no swath processing).
//   * Banding (dynamic beg/end shrink) not implemented; full-column processing.
//     Score and qle/tle/gtle/gscore/max_off are still correct for the unbanded
//     reference - banding is a CPU-side optimization that doesn't change the
//     final answer in the no-zdrop case.

`include "bsw_pkg.sv"

module bsw_max_tracker
    import bsw_pkg::*;
#(
    parameter int N_PE = BAND_WIDTH
)(
    input  logic                    clk,
    input  logic                    rst_n,

    // Per-alignment control
    input  logic                    clear_i,     // pulse before each alignment
    input  logic                    start_i,     // pulse at cycle the wavefront leaves PE_0 with row 0
    input  logic                    done_i,      // pulse from FSM when last row's tail has graduated

    // Runtime parameters
    input  len_t                    qlen_i,
    input  len_t                    tlen_i,
    input  score_t                  h0_i,
    input  score_t                  zdrop_i,
    input  score_t                  e_del_i,
    input  score_t                  e_ins_i,

    // Per-PE taps from the systolic array
    input  logic   [N_PE-1:0]       cell_valid_i,
    input  score_t [N_PE-1:0]       h_cells_i,

    // Outputs
    output bsw_result_t             result_o,
    output logic                    zdrop_break_o,  // assert to FSM to terminate early
    output logic                    dead_row_o      // assert when a full row's max was 0 -> abort
);

    // ------------------------------------------------------------
    // Cycle counter -- counts since start_i.
    // The cell at PE_j observed during clock cycle T was produced for
    // row R = (T - 1) - j (PE has 1 register of latency from active_i).
    // Equivalently: with our counter `cyc` that increments AT each posedge
    // starting from start_i, the cell at PE_j this cycle is for row (cyc - 1 - j).
    // ------------------------------------------------------------
    len_t cyc;

    always_ff @(posedge clk) begin
        if (!rst_n || clear_i) begin
            cyc <= '0;
        end else if (start_i) begin
            cyc <= len_t'(1);
        end else if (cyc != '0) begin
            cyc <= cyc + len_t'(1);
        end
    end

    // ------------------------------------------------------------
    // Per-PE row index: for PE k this cycle, the row being produced.
    // Derived as cyc-1-k. Guarded by cell_valid_i[k] (which the systolic
    // active chain provides).
    // ------------------------------------------------------------
    len_t [N_PE-1:0] row_of_pe;
    always_comb begin
        for (int k = 0; k < N_PE; k++) begin
            row_of_pe[k] = cyc - len_t'(1) - len_t'(k);
        end
    end

    // ------------------------------------------------------------
    // Global running-max scoreboard.
    // Updated every cycle from all N_PE active cells in parallel via a
    // reduction tree. We pick the strict-greatest cell; ties keep the
    // earlier row (matches the C++ "m > h ? m : h" semantics).
    // ------------------------------------------------------------
    score_t glob_max;
    len_t   glob_max_i;
    len_t   glob_max_j;
    len_t   glob_max_off;

    // Reduction: scan PE taps from low to high index, keeping the new cell
    // when strictly greater.
    score_t reduced_h;
    len_t   reduced_i;
    len_t   reduced_j;
    logic   any_valid;

    always_comb begin
        reduced_h = glob_max;
        reduced_i = glob_max_i;
        reduced_j = glob_max_j;
        any_valid = 1'b0;
        for (int k = 0; k < N_PE; k++) begin
            if (cell_valid_i[k] && (h_cells_i[k] > reduced_h)) begin
                reduced_h = h_cells_i[k];
                reduced_i = row_of_pe[k];
                reduced_j = len_t'(k);
            end
            if (cell_valid_i[k]) any_valid = 1'b1;
        end
    end

    // |i - j| for max_off update
    function automatic len_t abs_diff(input len_t a, input len_t b);
        if (a >= b) return a - b;
        else        return b - a;
    endfunction

    always_ff @(posedge clk) begin
        if (!rst_n || clear_i) begin
            glob_max     <= h0_i;       // initialised to h0 like C++ line 159
            glob_max_i   <= '1;         // -1 sentinel (all ones in unsigned)
            glob_max_j   <= '1;
            glob_max_off <= '0;
        end else begin
            // On start, latch h0 once
            if (start_i) glob_max <= h0_i;

            if (reduced_h > glob_max) begin
                glob_max     <= reduced_h;
                glob_max_i   <= reduced_i;
                glob_max_j   <= reduced_j;
                if (abs_diff(reduced_j, reduced_i) > glob_max_off)
                    glob_max_off <= abs_diff(reduced_j, reduced_i);
            end
        end
    end

    // ------------------------------------------------------------
    // Row-max pipeline.
    // Stage k holds the (m, mj) for the row whose cells are currently
    // being emitted by PE_k. Stage 0 starts fresh from PE_0's cell;
    // each subsequent stage merges PE_k's cell with the upstream value.
    //
    // When stage (qlen-1) is reached, the row is complete and we apply
    // the post-row update (gscore / global max / zdrop).
    // ------------------------------------------------------------
    score_t row_m_pipe   [N_PE];
    len_t   row_mj_pipe  [N_PE];
    len_t   row_idx_pipe [N_PE];  // which row index each stage represents
    logic   row_vld_pipe [N_PE];

    always_ff @(posedge clk) begin
        if (!rst_n || clear_i) begin
            for (int k = 0; k < N_PE; k++) begin
                row_m_pipe[k]   <= '0;
                row_mj_pipe[k]  <= '0;
                row_idx_pipe[k] <= '0;
                row_vld_pipe[k] <= 1'b0;
            end
        end else begin
            // Stage 0: fresh row anchored at PE_0
            if (cell_valid_i[0]) begin
                row_m_pipe[0]   <= h_cells_i[0];
                row_mj_pipe[0]  <= '0;
                row_idx_pipe[0] <= row_of_pe[0];
                row_vld_pipe[0] <= 1'b1;
            end else begin
                row_m_pipe[0]   <= '0;
                row_mj_pipe[0]  <= '0;
                row_idx_pipe[0] <= '0;
                row_vld_pipe[0] <= 1'b0;
            end

            // Stages 1..N_PE-1: merge upstream with PE_k's cell
            for (int k = 1; k < N_PE; k++) begin
                if (row_vld_pipe[k-1]) begin
                    row_idx_pipe[k] <= row_idx_pipe[k-1];
                    row_vld_pipe[k] <= 1'b1;
                    if (cell_valid_i[k] && (h_cells_i[k] > row_m_pipe[k-1])) begin
                        row_m_pipe[k]  <= h_cells_i[k];
                        row_mj_pipe[k] <= len_t'(k);
                    end else begin
                        row_m_pipe[k]  <= row_m_pipe[k-1];
                        row_mj_pipe[k] <= row_mj_pipe[k-1];
                    end
                end else begin
                    row_vld_pipe[k] <= 1'b0;
                end
            end
        end
    end

    // ------------------------------------------------------------
    // Row-tail detection: when the row pipeline reaches stage (qlen-1)
    // a row has just been finalised. Use that stage's (m, mj, row_idx).
    // ------------------------------------------------------------
    logic   row_tail_valid;
    score_t row_tail_m;
    len_t   row_tail_mj;
    len_t   row_tail_idx;
    score_t row_tail_h_last;     // H(row, qlen-1), needed for gscore

    // qlen-1 is the index of the last query column
    wire [PE_IDX_WIDTH:0] tail_idx = qlen_i[PE_IDX_WIDTH:0] - 'd1;

    // ------------------------------------------------------------
    // H_last alignment: by the cycle when stage qlen-1 carries row R's data,
    // PE_{qlen-1}'s h_cells output has already advanced to row R+1's cell. So
    // we keep a 1-cycle-delayed copy of h_cells_i[tail_idx]. At the cycle when
    // row_tail_idx == R, h_last_delayed holds H(R, qlen-1). This mirrors the
    // C++ semantics where gscore is updated from h1 (= H(i, qlen-1)) for that
    // row specifically — not the row's max across all columns.
    // ------------------------------------------------------------
    score_t h_last_delayed;
    always_ff @(posedge clk) begin
        if (!rst_n || clear_i) h_last_delayed <= '0;
        else                   h_last_delayed <= h_cells_i[tail_idx];
    end

    always_comb begin
        // Default
        row_tail_valid = 1'b0;
        row_tail_m     = '0;
        row_tail_mj    = '0;
        row_tail_idx   = '0;
        row_tail_h_last= '0;
        for (int k = 0; k < N_PE; k++) begin
            if ((k == tail_idx) && row_vld_pipe[k]) begin
                row_tail_valid = 1'b1;
                row_tail_m     = row_m_pipe[k];
                row_tail_mj    = row_mj_pipe[k];
                row_tail_idx   = row_idx_pipe[k];
                row_tail_h_last= h_last_delayed;
            end
        end
    end

    // ------------------------------------------------------------
    // gscore + gtle: best H reaching the end of the query (j = qlen-1).
    // Updated each time a row tail graduates.
    // ------------------------------------------------------------
    score_t gscore_r;
    len_t   gtle_r;
    len_t   max_ie_r;

    always_ff @(posedge clk) begin
        if (!rst_n || clear_i) begin
            gscore_r <= '1;     // -1 sentinel (C++ initialises gscore=-1)
            gtle_r   <= '0;
            max_ie_r <= '1;
        end else if (row_tail_valid) begin
            if ($signed(row_tail_h_last) > $signed(gscore_r)) begin
                gscore_r <= row_tail_h_last;
                gtle_r   <= row_tail_idx + len_t'(1);   // +1 like C++ "tle = max_i + 1"
                max_ie_r <= row_tail_idx;
            end
        end
    end

    // ------------------------------------------------------------
    // zdrop early-exit. Mirrors C++ lines 207-215:
    //   if (m > max) ... update ...
    //   else if (zdrop > 0) {
    //     if (i - max_i > mj - max_j)
    //       if (max - m - ((i-max_i) - (mj-max_j)) * e_del > zdrop) break;
    //     else
    //       if (max - m - ((mj-max_j) - (i-max_i)) * e_ins > zdrop) break;
    //   }
    // We apply this when a row tail graduates and the row's m did not
    // improve on the global max.
    // ------------------------------------------------------------
    logic zdrop_break_q;
    logic dead_row_q;

    // Combinational zdrop math. All terms widened to 32-bit signed to avoid
    // unsigned wraparound on the index/score subtractions.
    logic signed [31:0] z_di, z_dj, z_gap, z_drift, z_thr;
    logic               z_should_break;

    always_comb begin
        z_di    = $signed({16'b0, row_tail_idx}) - $signed({16'b0, glob_max_i});
        z_dj    = $signed({16'b0, row_tail_mj})  - $signed({16'b0, glob_max_j});
        z_gap   = $signed({16'b0, glob_max})     - $signed({16'b0, row_tail_m});
        if (z_di > z_dj)
            z_drift = (z_di - z_dj) * $signed({16'b0, e_del_i});
        else
            z_drift = (z_dj - z_di) * $signed({16'b0, e_ins_i});
        z_thr   = z_gap - z_drift;
        z_should_break = (z_thr > $signed({16'b0, zdrop_i}))
                      && ($signed(zdrop_i) > 0)
                      && ($signed(row_tail_m) <= $signed(glob_max));
    end

    always_ff @(posedge clk) begin
        if (!rst_n || clear_i) begin
            zdrop_break_q <= 1'b0;
            dead_row_q    <= 1'b0;
        end else if (row_tail_valid) begin
            if (row_tail_m == '0)  dead_row_q    <= 1'b1;
            if (z_should_break)    zdrop_break_q <= 1'b1;
        end
    end

    assign zdrop_break_o = zdrop_break_q;
    assign dead_row_o    = dead_row_q;

    // ------------------------------------------------------------
    // Final result. Latched on done_i (FSM signals end of alignment).
    // qle = max_j + 1, tle = max_i + 1, gtle = max_ie + 1 (matches C++).
    // ------------------------------------------------------------
    bsw_result_t result_q;

    always_ff @(posedge clk) begin
        if (!rst_n || clear_i) begin
            result_q <= '0;
        end else if (done_i) begin
            result_q.score   <= glob_max;
            result_q.qle     <= glob_max_j + len_t'(1);
            result_q.tle     <= glob_max_i + len_t'(1);
            result_q.gscore  <= gscore_r;
            result_q.gtle    <= max_ie_r + len_t'(1);
            result_q.max_off <= glob_max_off;
        end
    end

    assign result_o = result_q;

endmodule
