// matesw_dedup.sv
// mem_sort_dedup_patch (bwamem.cpp) for the mate-rescue ma list — the per-orientation
// sort/dedup the orchestration runs after each rescue insertion. Modeled on
// host/mate_rescue/orch.h::mr_dedup (the SW-merge branch is omitted — it needs the
// reference and was measured to fire 0x). Arrays here are tiny (bounded MA_MAX), so
// every pass is a simple in-place O(n^2) over a small register file:
//   1. STABLE insertion-sort by re ascending          (ks_introsort mem_ars2)
//   2. integer redundancy de-overlap (nested i/j loop) ; mask_level_redun=0.95 via
//      the proven integer surrogate 20*ov > 19*minlen
//   3. compact (drop qe==qb)
//   4. score-sort: score desc, rb asc, qb asc          (ks_introsort mem_ars; total order)
//   5. mark identical (score,rb,qb) then compact (keep index 0)
// Fields carried: rb/re/qb/qe/rid/score + seedcov (rides along; not a key). sub/csub/
// n_comp are not modeled (only touched by the never-firing merge branch).
//
// Load the n_in records via ld_* (idx 0..n_in-1), pulse start; when done, read the
// n_out survivors via rd_idx. Sets `overflow` if n_in > MA_MAX (host SW fallback).

module matesw_dedup #(parameter int MA_MAX = 256) (
    input  logic               clk,
    input  logic               rst_n,

    // ---- load (host/TB) ----
    input  logic               ld_en,
    input  logic [15:0]        ld_idx,
    input  logic signed [63:0] ld_rb,
    input  logic signed [63:0] ld_re,
    input  logic signed [31:0] ld_qb,
    input  logic signed [31:0] ld_qe,
    input  logic signed [31:0] ld_rid,
    input  logic signed [31:0] ld_score,
    input  logic signed [31:0] ld_cov,

    // ---- request ----
    input  logic               start,
    input  logic [15:0]        n_in,

    // ---- status / result ----
    output logic               busy,
    output logic               done,
    output logic               overflow,
    output logic               tie,        // dedup sort-key TIE (equal re, or equal score,rb,qb)
                                           // -> introsort/stable diverge -> host SW fallback
                                           // (mirrors orch.h::mr_dedup's fb flag)
    output logic [15:0]        n_out,

    // ---- result read port ----
    input  logic [15:0]        rd_idx,
    output logic signed [63:0] o_rb,
    output logic signed [63:0] o_re,
    output logic signed [31:0] o_qb,
    output logic signed [31:0] o_qe,
    output logic signed [31:0] o_rid,
    output logic signed [31:0] o_score,
    output logic signed [31:0] o_cov
);
    localparam logic signed [63:0] GAP = 64'sd10000;   // opt->max_chain_gap

    // ---- register file ----
    logic signed [63:0] rb [MA_MAX];
    logic signed [63:0] re [MA_MAX];
    logic signed [31:0] qb [MA_MAX];
    logic signed [31:0] qe [MA_MAX];
    logic signed [31:0] rid[MA_MAX];
    logic signed [31:0] sc [MA_MAX];
    logic signed [31:0] cov[MA_MAX];

    always_ff @(posedge clk) if (ld_en && ld_idx < MA_MAX[15:0]) begin
        rb[ld_idx]  <= ld_rb;  re[ld_idx]  <= ld_re;
        qb[ld_idx]  <= ld_qb;  qe[ld_idx]  <= ld_qe;
        rid[ld_idx] <= ld_rid; sc[ld_idx]  <= ld_score; cov[ld_idx] <= ld_cov;
    end

    assign o_rb=rb[rd_idx]; assign o_re=re[rd_idx]; assign o_qb=qb[rd_idx];
    assign o_qe=qe[rd_idx]; assign o_rid=rid[rd_idx]; assign o_score=sc[rd_idx];
    assign o_cov=cov[rd_idx];

    // ---- key registers (for the element being inserted) ----
    logic signed [63:0] k_rb, k_re; logic signed [31:0] k_qb, k_qe, k_rid, k_sc, k_cov;
    integer n, m, i, j;

    typedef enum logic [4:0] {
        S_IDLE, S_R_OUT, S_R_IN, S_R_PLACE,
        S_RED_OUT, S_RED_IN,
        S_C1,
        S_S_OUT, S_S_IN, S_S_PLACE,
        S_ID, S_C2, S_DONE
    } st_t;
    st_t state;
    assign busy = (state != S_IDLE);

    // helper: copy element src -> dst (combinational selection, registered write)
    task automatic copy_elem(input integer dst, input integer src);
        rb[dst]<=rb[src]; re[dst]<=re[src]; qb[dst]<=qb[src]; qe[dst]<=qe[src];
        rid[dst]<=rid[src]; sc[dst]<=sc[src]; cov[dst]<=cov[src];
    endtask
    task automatic put_key(input integer dst);
        rb[dst]<=k_rb; re[dst]<=k_re; qb[dst]<=k_qb; qe[dst]<=k_qe;
        rid[dst]<=k_rid; sc[dst]<=k_sc; cov[dst]<=k_cov;
    endtask

    // redundancy surrogate quantities for (p=i, q=j)
    logic signed [63:0] or_, mr_, mr_a, mr_b;
    logic signed [63:0] oq_, mq_, mq_a, mq_b;
    logic               redun, q_excluded, in_window;
    always_comb begin
        or_   = re[j] - rb[i];
        mr_a  = re[j] - rb[j]; mr_b = re[i] - rb[i];
        mr_   = (mr_a < mr_b) ? mr_a : mr_b;
        oq_   = (qb[j] < qb[i]) ? (qe[j] - qb[i]) : (qe[i] - qb[j]);
        mq_a  = qe[j] - qb[j]; mq_b = qe[i] - qb[i];
        mq_   = (mq_a < mq_b) ? mq_a : mq_b;
        redun = (64'sd20*or_ > 64'sd19*mr_) && (64'sd20*oq_ > 64'sd19*mq_);
        q_excluded = (qe[j] == qb[j]);
        in_window  = (j >= 0) && (rid[i] == rid[j]) && (rb[i] < re[j] + GAP);
    end

    // score comparator: does key come strictly before a[j]? (score desc, rb asc, qb asc)
    logic key_before_j;
    always_comb begin
        if (k_sc != sc[j])      key_before_j = (k_sc > sc[j]);
        else if (k_rb != rb[j]) key_before_j = (k_rb < rb[j]);
        else                    key_before_j = (k_qb < qb[j]);
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state <= S_IDLE; done <= 1'b0; overflow <= 1'b0; tie <= 1'b0; n_out <= '0;
        end else begin
            done <= 1'b0;
            case (state)
                S_IDLE: if (start) begin
                    n <= n_in; overflow <= (n_in > MA_MAX[15:0]); tie <= 1'b0;
                    if (n_in <= 16'd1) begin n_out <= n_in; state <= S_DONE; end
                    else if (n_in > MA_MAX[15:0]) begin n_out <= n_in; state <= S_DONE; end
                    else begin i <= 1; state <= S_R_OUT; end
                end

                // ---- 1. stable insertion sort by re ascending ----
                S_R_OUT: begin
                    k_rb<=rb[i]; k_re<=re[i]; k_qb<=qb[i]; k_qe<=qe[i];
                    k_rid<=rid[i]; k_sc<=sc[i]; k_cov<=cov[i];
                    j <= i - 1; state <= S_R_IN;
                end
                S_R_IN: begin
                    if (j >= 0 && re[j] > k_re) begin    // strict '>' keeps stability
                        copy_elem(j+1, j); j <= j - 1;
                    end else state <= S_R_PLACE;
                end
                S_R_PLACE: begin
                    put_key(j+1);
                    if (i + 1 >= n) begin i <= 1; state <= S_RED_OUT; end
                    else begin i <= i + 1; state <= S_R_OUT; end
                end

                // ---- 2. integer redundancy de-overlap ----
                S_RED_OUT: begin
                    if (i >= n) begin m <= 0; i <= 0; state <= S_C1; end
                    else begin
                        if (re[i] == re[i-1]) tie <= 1'b1;   // equal-re in the re-sorted array
                        if (rid[i] != rid[i-1] || rb[i] >= re[i-1] + GAP) i <= i + 1;
                        else begin j <= i - 1; state <= S_RED_IN; end
                    end
                end
                S_RED_IN: begin
                    if (!in_window) begin i <= i + 1; state <= S_RED_OUT; end
                    else if (q_excluded) j <= j - 1;
                    else if (redun) begin
                        if (sc[i] < sc[j]) begin
                            qe[i] <= qb[i];              // p excluded; break
                            i <= i + 1; state <= S_RED_OUT;
                        end else begin
                            qe[j] <= qb[j]; j <= j - 1;  // q excluded; continue
                        end
                    end else j <= j - 1;
                end

                // ---- 3. compact (drop qe==qb) ----
                S_C1: begin
                    if (i >= n) begin n <= m; if (m > 0) begin i <= 1; state <= S_S_OUT; end
                                              else begin n_out <= 0; state <= S_DONE; end end
                    else begin
                        if (qe[i] > qb[i]) begin
                            if (m != i) copy_elem(m, i);
                            m <= m + 1;
                        end
                        i <= i + 1;
                    end
                end

                // ---- 4. score-sort (total order) ----
                S_S_OUT: begin
                    if (i >= n) begin i <= 1; state <= S_ID; end
                    else begin
                        k_rb<=rb[i]; k_re<=re[i]; k_qb<=qb[i]; k_qe<=qe[i];
                        k_rid<=rid[i]; k_sc<=sc[i]; k_cov<=cov[i];
                        j <= i - 1; state <= S_S_IN;
                    end
                end
                S_S_IN: begin
                    if (j >= 0 && key_before_j) begin copy_elem(j+1, j); j <= j - 1; end
                    else state <= S_S_PLACE;
                end
                S_S_PLACE: begin put_key(j+1); i <= i + 1; state <= S_S_OUT; end

                // ---- 5. mark identical (score,rb,qb), then compact keeping index 0 ----
                S_ID: begin
                    if (i >= n) begin m <= 1; i <= 1; state <= S_C2; end
                    else begin
                        if (sc[i]==sc[i-1] && rb[i]==rb[i-1] && qb[i]==qb[i-1]) begin qe[i] <= qb[i]; tie <= 1'b1; end
                        i <= i + 1;
                    end
                end
                S_C2: begin
                    if (i >= n) begin n_out <= m[15:0]; state <= S_DONE; end
                    else begin
                        if (qe[i] > qb[i]) begin
                            if (m != i) copy_elem(m, i);
                            m <= m + 1;
                        end
                        i <= i + 1;
                    end
                end

                S_DONE: begin done <= 1'b1; state <= S_IDLE; end
                default: state <= S_IDLE;
            endcase
        end
    end
endmodule
