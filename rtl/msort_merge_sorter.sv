// msort_merge_sorter.sv
// Folded (iterative bottom-up) merge sorter for alignment-register score keys.
//
// Reproduces the post-dedup `alnreg_slt` sort: ascending unsigned compare of the
// 96-bit composite key (msort_pkg :: pack layout) == score desc, rb asc, qb asc.
// Verified bit-exact against ks_introsort by the C++ model (host/merge_sorter/).
//
// "Folded": ONE merge datapath is swept across the data once per pass; run width
// doubles 1->2->4->... for ceil(log2 n) passes. Two on-chip RAM banks ping-pong
// (read source, write destination, swap each pass). One element is emitted per
// merge cycle, so a pass costs ~n cycles and a full sort ~n*ceil(log2 n) cycles
// (e.g. ~10k cycles at n=1024 -> ~50 us @200 MHz; far above throughput need —
// the sorter is not the pipeline bottleneck, so this trades area for cycles).
//
// Phases: LOAD (stream n keys in, indices assigned 0..n-1) -> SORT -> UNLOAD
// (stream sorted (idx,key) out). Host must not enqueue n > N_MAX (1024); those
// rare cases (n in 1025..1060, 0.03% of cost) take the software fallback.
//
// NOTE: memories use combinational reads here (functional v1 — infers MLAB/
// distributed RAM). Registered-read block-RAM mapping is a synthesis refinement.

`include "msort_pkg.sv"

module msort_merge_sorter
    import msort_pkg::*;
(
    input  logic        clk,
    input  logic        rst_n,        // sync, active-low

    // ---- Load interface (stream keys in) ----
    input  logic        in_valid,
    input  key_t        in_key,
    input  logic        in_last,      // asserted with the final key of the array
    output logic        in_ready,     // accepts a key this cycle

    input  logic        start,        // pulse after last key to begin sorting
                                       // (optional: in_last auto-starts the sort)

    // ---- Unload interface (stream sorted pairs out) ----
    output logic        out_valid,
    output idx_t        out_idx,      // original load index, in sorted order
    output key_t        out_key,      // its composite key
    output logic        out_last,
    input  logic        out_ready,

    // ---- Status ----
    output logic        busy,
    output logic        done          // 1-cycle pulse when a sort completes
);

    // ---- Ping-pong storage ----
    pair_t bankA [0:N_MAX-1];
    pair_t bankB [0:N_MAX-1];
    logic  data_in_b;                 // 0: live data in A, 1: in B

    // ---- FSM ----
    typedef enum logic [2:0] {
        ST_IDLE, ST_LOAD, ST_PASS_CHECK, ST_PASS_INIT, ST_MERGE, ST_UNLOAD, ST_DONE
    } state_t;
    state_t state;

    cnt_t  n;                         // element count
    cnt_t  wptr;                      // load write pointer
    logic [PASS_W:0] width;           // current run width (1,2,4,...)
    cnt_t  lo, mid, hi;               // current run-pair boundaries
    cnt_t  i, j, k;                   // left ptr, right ptr, dest ptr
    cnt_t  rptr;                      // unload read pointer

    // wide temporaries for boundary math (avoid overflow before clamp)
    logic [PASS_W+1:0] lo_w, w_w;
    function automatic cnt_t min_cnt(input logic [PASS_W+1:0] a, input cnt_t b);
        min_cnt = (a < {{(PASS_W+2-CNT_W){1'b0}}, b}) ? a[CNT_W-1:0] : b;
    endfunction

    // ---- Combinational source reads (truncate addr; usage is gated) ----
    pair_t sL, sR;
    always_comb begin
        sL = data_in_b ? bankB[i[IDX_W-1:0]] : bankA[i[IDX_W-1:0]];
        sR = data_in_b ? bankB[j[IDX_W-1:0]] : bankA[j[IDX_W-1:0]];
    end

    logic left_avail, right_avail, take_left;
    pair_t emit;
    cnt_t  ni, nj;
    always_comb begin
        left_avail  = (i < mid);
        right_avail = (j < hi);
        // left wins on equal keys (stable); keys are unique in practice
        take_left   = left_avail && (!right_avail || (sL.key <= sR.key));
        emit        = take_left ? sL : sR;
        ni          = take_left ? (i + 1'b1) : i;
        nj          = take_left ? j : (j + 1'b1);
    end

    // ---- Unload combinational read of the result bank ----
    pair_t out_pair;
    always_comb begin
        out_pair = data_in_b ? bankB[rptr[IDX_W-1:0]] : bankA[rptr[IDX_W-1:0]];
    end

    assign in_ready  = (state == ST_IDLE) || (state == ST_LOAD);
    assign busy      = (state != ST_IDLE);
    assign out_valid = (state == ST_UNLOAD);
    assign out_idx   = out_pair.idx;
    assign out_key   = out_pair.key;
    assign out_last  = (state == ST_UNLOAD) && (rptr == n - 1'b1);

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state     <= ST_IDLE;
            wptr      <= '0;
            n         <= '0;
            data_in_b <= 1'b0;
            done      <= 1'b0;
        end else begin
            done <= 1'b0;
            case (state)
                // -----------------------------------------------------------
                ST_IDLE: begin
                    data_in_b <= 1'b0;
                    wptr      <= '0;
                    if (in_valid) begin               // first key starts a load
                        bankA[wptr[IDX_W-1:0]] <= '{key:in_key, idx:wptr[IDX_W-1:0]};
                        wptr  <= wptr + 1'b1;
                        state <= ST_LOAD;
                        if (in_last) begin
                            n <= wptr + 1'b1;          // single-element array
                            state <= ST_PASS_CHECK;
                        end
                    end
                end
                // -----------------------------------------------------------
                ST_LOAD: begin
                    if (in_valid) begin
                        bankA[wptr[IDX_W-1:0]] <= '{key:in_key, idx:wptr[IDX_W-1:0]};
                        wptr <= wptr + 1'b1;
                        if (in_last) begin
                            n     <= wptr + 1'b1;
                            width <= 'd1;
                            state <= ST_PASS_CHECK;
                        end
                    end
                end
                // -----------------------------------------------------------
                // decide whether another merge pass is needed
                ST_PASS_CHECK: begin
                    if (n <= 1) begin
                        rptr  <= '0;
                        state <= (n == 0) ? ST_DONE : ST_UNLOAD;
                    end else if (width < n) begin
                        state <= ST_PASS_INIT;
                    end else begin
                        rptr  <= '0;
                        state <= ST_UNLOAD;
                    end
                end
                // -----------------------------------------------------------
                // set up the first run-pair of a pass (lo=0)
                ST_PASS_INIT: begin
                    w_w   = {{(PASS_W+2-(PASS_W+1)){1'b0}}, width};
                    lo    <= '0;
                    i     <= '0;
                    k     <= '0;
                    mid   <= min_cnt(w_w, n);                 // min(width, n)
                    j     <= min_cnt(w_w, n);
                    hi    <= min_cnt(w_w + w_w, n);           // min(2*width, n)
                    state <= ST_MERGE;
                end
                // -----------------------------------------------------------
                // one merged element per cycle
                ST_MERGE: begin
                    // write the chosen element to the destination bank
                    if (data_in_b) bankA[k[IDX_W-1:0]] <= emit;
                    else           bankB[k[IDX_W-1:0]] <= emit;
                    k <= k + 1'b1;
                    i <= ni;
                    j <= nj;

                    // pair complete when both runs are drained
                    if (ni >= mid && nj >= hi) begin
                        lo_w = {{(PASS_W+2-CNT_W){1'b0}}, lo} + {1'b0, width, 1'b0}; // lo + 2*width
                        if (lo_w >= {{(PASS_W+2-CNT_W){1'b0}}, n}) begin
                            // pass complete -> swap banks, double width
                            data_in_b <= ~data_in_b;
                            width     <= width << 1;
                            state     <= ST_PASS_CHECK;
                        end else begin
                            // advance to next run-pair (k stays continuous)
                            w_w  = {{(PASS_W+2-(PASS_W+1)){1'b0}}, width};
                            lo   <= lo_w[CNT_W-1:0];
                            i    <= lo_w[CNT_W-1:0];
                            mid  <= min_cnt(lo_w + w_w, n);
                            j    <= min_cnt(lo_w + w_w, n);
                            hi   <= min_cnt(lo_w + w_w + w_w, n);
                        end
                    end
                end
                // -----------------------------------------------------------
                ST_UNLOAD: begin
                    if (out_ready) begin
                        if (rptr == n - 1'b1) begin
                            state <= ST_DONE;
                        end
                        rptr <= rptr + 1'b1;
                    end
                end
                // -----------------------------------------------------------
                ST_DONE: begin
                    done  <= 1'b1;
                    state <= ST_IDLE;
                end
                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule
