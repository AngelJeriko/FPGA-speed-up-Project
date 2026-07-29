// matesw_dedup.sv
// mem_sort_dedup_patch (bwamem.cpp) for the mate-rescue ma list — the per-orientation
// sort/dedup the orchestration runs after each rescue insertion. Modeled on
// host/mate_rescue/orch.h::mr_dedup (the SW-merge branch is omitted — it needs the
// reference and was measured to fire 0x). In-place O(n^2) over a small array:
//   1. STABLE insertion-sort by re ascending          (ks_introsort mem_ars2)
//   2. integer redundancy de-overlap (nested i/j loop) ; mask_level_redun=0.95 via
//      the proven integer surrogate 20*ov > 19*minlen
//   3. compact (drop qe==qb)
//   4. score-sort: score desc, rb asc, qb asc          (ks_introsort mem_ars; total order)
//   5. mark identical (score,rb,qb) then compact (keep index 0)
// Fields carried: rb/re/qb/qe/rid/score + seedcov (rides along; not a key).
//
// Load the n_in records via ld_* (idx 0..n_in-1), pulse start; when done, read the
// n_out survivors via rd_idx. Sets `overflow` if n_in > MA_MAX (host SW fallback).
//
// STORAGE: the 7 field arrays are a REGISTERED-READ memory with 1 write + 2 read ports
// (port A / port B) -> true-dual-port BRAM, NOT a 256:1 LUT-mux register file (which was
// ~573K LUTs). Every read is "present address in an _A state, consume the registered
// data (a_*/b_*) in the following _U state"; the redundancy inner loop reads only j after
// latching element[i] into p_*. Read latency adds ~1 cycle per access (median n=2 -> cheap;
// worst-case tail n<=256). The output port o_* is now a REGISTERED read of rd_idx (1-cycle
// latency) — readers (tb, matesw_orch_top) present rd_idx one cycle before sampling o_*.
// Bit-exact with the prior combinational version (same values, same order).

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
    output logic               tie,        // dedup sort-key TIE -> host SW fallback
    output logic [15:0]        n_out,

    // ---- result read port (REGISTERED: present rd_idx, sample o_* next cycle) ----
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

    // ---- registered-read memory: 1 write + 2 read ports (A,B) ----
    logic signed [63:0] rb [MA_MAX];
    logic signed [63:0] re [MA_MAX];
    logic signed [31:0] qb [MA_MAX];
    logic signed [31:0] qe [MA_MAX];
    logic signed [31:0] rid[MA_MAX];
    logic signed [31:0] sc [MA_MAX];
    logic signed [31:0] cov[MA_MAX];

    // write intent (combinational) — registered by the memory block below
    logic               we;
    logic [15:0]        wa;
    logic signed [63:0] w_rb, w_re;
    logic signed [31:0] w_qb, w_qe, w_rid, w_sc, w_cov;
    // read addresses (combinational)
    logic [15:0]        raddr, rbaddr;
    // registered read data — port A (a_*) and port B (b_*)
    logic signed [63:0] a_rb, a_re, b_rb, b_re;
    logic signed [31:0] a_qb, a_qe, a_rid, a_sc, a_cov;
    logic signed [31:0] b_qb, b_qe, b_rid, b_sc, b_cov;

    always_ff @(posedge clk) begin
        if (we) begin
            rb[wa]<=w_rb; re[wa]<=w_re; qb[wa]<=w_qb; qe[wa]<=w_qe;
            rid[wa]<=w_rid; sc[wa]<=w_sc; cov[wa]<=w_cov;
        end
        a_rb<=rb[raddr]; a_re<=re[raddr]; a_qb<=qb[raddr]; a_qe<=qe[raddr];
        a_rid<=rid[raddr]; a_sc<=sc[raddr]; a_cov<=cov[raddr];
        b_rb<=rb[rbaddr]; b_re<=re[rbaddr]; b_qb<=qb[rbaddr]; b_qe<=qe[rbaddr];
        b_rid<=rid[rbaddr]; b_sc<=sc[rbaddr]; b_cov<=cov[rbaddr];
    end

    // output = registered read of rd_idx (presented when idle)
    assign o_rb=a_rb; assign o_re=a_re; assign o_qb=a_qb;
    assign o_qe=a_qe; assign o_rid=a_rid; assign o_score=a_sc; assign o_cov=a_cov;

    // ---- key register (element being inserted) + p_* (latched element[i] for redundancy) ----
    logic signed [63:0] k_rb, k_re, p_rb, p_re;
    logic signed [31:0] k_qb, k_qe, k_rid, k_sc, k_cov;
    logic signed [31:0] p_qb, p_qe, p_rid, p_sc, p_cov;
    integer n, m, i, j;

    typedef enum logic [4:0] {
        S_IDLE,
        S_ROUT_A, S_ROUT_U, S_RIN_A, S_RIN_U, S_RPLACE,
        S_REDOUT_A, S_REDOUT_U, S_REDIN_A, S_REDIN_U,
        S_C1_A, S_C1_U,
        S_SOUT_A, S_SOUT_U, S_SIN_A, S_SIN_U, S_SPLACE,
        S_ID_A, S_ID_U,
        S_C2_A, S_C2_U,
        S_DONE
    } st_t;
    st_t state;
    assign busy = (state != S_IDLE);

    // ---- read-address decoder: present the address a following _U state will consume ----
    always_comb begin
        raddr  = 16'd0;
        rbaddr = 16'd0;
        case (state)
            S_IDLE:     raddr = rd_idx;                                  // serve output
            S_ROUT_A:   raddr = i[15:0];
            S_RIN_A:    raddr = (j >= 0) ? j[15:0] : 16'd0;
            S_REDOUT_A: begin raddr = i[15:0]; rbaddr = (i-1) >= 0 ? (i-1) : 16'd0; end
            S_REDIN_A:  raddr = (j >= 0) ? j[15:0] : 16'd0;
            S_C1_A:     raddr = i[15:0];
            S_SOUT_A:   raddr = i[15:0];
            S_SIN_A:    raddr = (j >= 0) ? j[15:0] : 16'd0;
            S_ID_A:     begin raddr = i[15:0]; rbaddr = (i-1) >= 0 ? (i-1) : 16'd0; end
            S_C2_A:     raddr = i[15:0];
            default: ;
        endcase
    end

    // ---- redundancy surrogate (p=element[i] latched, q=element[j] on port A) ----
    logic signed [63:0] or_, mr_, mr_a, mr_b, oq_, mq_, mq_a, mq_b;
    logic redun, q_excluded, in_window;
    always_comb begin
        or_   = a_re - p_rb;
        mr_a  = a_re - a_rb; mr_b = p_re - p_rb;
        mr_   = (mr_a < mr_b) ? mr_a : mr_b;
        oq_   = (a_qb < p_qb) ? (a_qe - p_qb) : (p_qe - a_qb);
        mq_a  = a_qe - a_qb; mq_b = p_qe - p_qb;
        mq_   = (mq_a < mq_b) ? mq_a : mq_b;
        redun = (64'sd20*or_ > 64'sd19*mr_) && (64'sd20*oq_ > 64'sd19*mq_);
        q_excluded = (a_qe == a_qb);
        in_window  = (j >= 0) && (p_rid == a_rid) && (p_rb < a_re + GAP);
    end

    // score comparator: does key come strictly before element[j] (a_*)? (score desc, rb asc, qb asc)
    logic key_before_j;
    always_comb begin
        if (k_sc != a_sc)      key_before_j = (k_sc > a_sc);
        else if (k_rb != a_rb) key_before_j = (k_rb < a_rb);
        else                   key_before_j = (k_qb < a_qb);
    end

    // ---- write decoder: one write/cycle. Full 7-field write; a qe-only update writes the
    //      element back (from the latched/read copy) with just qe changed. ----
    always_comb begin
        we = 1'b0; wa = 16'd0;
        w_rb=a_rb; w_re=a_re; w_qb=a_qb; w_qe=a_qe; w_rid=a_rid; w_sc=a_sc; w_cov=a_cov;
        if (state == S_IDLE) begin
            if (ld_en && ld_idx < MA_MAX[15:0]) begin
                we=1'b1; wa=ld_idx;
                w_rb=ld_rb; w_re=ld_re; w_qb=ld_qb; w_qe=ld_qe;
                w_rid=ld_rid; w_sc=ld_score; w_cov=ld_cov;
            end
        end else begin
            case (state)
                // insertion-sort by re: shift element[j] -> [j+1]
                S_RIN_U: if (j >= 0 && a_re > k_re) begin
                    we=1'b1; wa=16'(j+1);
                    w_rb=a_rb; w_re=a_re; w_qb=a_qb; w_qe=a_qe; w_rid=a_rid; w_sc=a_sc; w_cov=a_cov;
                end
                S_RPLACE: begin
                    we=1'b1; wa=16'(j+1);
                    w_rb=k_rb; w_re=k_re; w_qb=k_qb; w_qe=k_qe; w_rid=k_rid; w_sc=k_sc; w_cov=k_cov;
                end
                // redundancy: exclude p (qe[i]<=qb[i], element[i]=p_*) or q (qe[j]<=qb[j], element[j]=a_*)
                S_REDIN_U: if (in_window && !q_excluded && redun) begin
                    if (p_sc < a_sc) begin
                        we=1'b1; wa=i[15:0];
                        w_rb=p_rb; w_re=p_re; w_qb=p_qb; w_qe=p_qb; w_rid=p_rid; w_sc=p_sc; w_cov=p_cov;
                    end else begin
                        we=1'b1; wa=(j >= 0) ? j[15:0] : 16'd0;
                        w_rb=a_rb; w_re=a_re; w_qb=a_qb; w_qe=a_qb; w_rid=a_rid; w_sc=a_sc; w_cov=a_cov;
                    end
                end
                // compact: copy element[i] -> [m]
                S_C1_U: if (i < n && a_qe > a_qb && m != i) begin
                    we=1'b1; wa=m[15:0];
                    w_rb=a_rb; w_re=a_re; w_qb=a_qb; w_qe=a_qe; w_rid=a_rid; w_sc=a_sc; w_cov=a_cov;
                end
                // score-sort: shift element[j] -> [j+1]
                S_SIN_U: if (j >= 0 && key_before_j) begin
                    we=1'b1; wa=16'(j+1);
                    w_rb=a_rb; w_re=a_re; w_qb=a_qb; w_qe=a_qe; w_rid=a_rid; w_sc=a_sc; w_cov=a_cov;
                end
                S_SPLACE: begin
                    we=1'b1; wa=16'(j+1);
                    w_rb=k_rb; w_re=k_re; w_qb=k_qb; w_qe=k_qe; w_rid=k_rid; w_sc=k_sc; w_cov=k_cov;
                end
                // mark identical: qe[i]<=qb[i], element[i]=a_*
                S_ID_U: if (i < n && a_sc==b_sc && a_rb==b_rb && a_qb==b_qb) begin
                    we=1'b1; wa=i[15:0];
                    w_rb=a_rb; w_re=a_re; w_qb=a_qb; w_qe=a_qb; w_rid=a_rid; w_sc=a_sc; w_cov=a_cov;
                end
                S_C2_U: if (i < n && a_qe > a_qb && m != i) begin
                    we=1'b1; wa=m[15:0];
                    w_rb=a_rb; w_re=a_re; w_qb=a_qb; w_qe=a_qe; w_rid=a_rid; w_sc=a_sc; w_cov=a_cov;
                end
                default: ;
            endcase
        end
    end

    // ---- control FSM (state / indices / latches / status) ----
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state <= S_IDLE; done <= 1'b0; overflow <= 1'b0; tie <= 1'b0; n_out <= '0;
        end else begin
            done <= 1'b0;
            case (state)
                S_IDLE: if (start) begin
                    n <= n_in; overflow <= (n_in > MA_MAX[15:0]); tie <= 1'b0;
                    if (n_in <= 16'd1)             begin n_out <= n_in; state <= S_DONE; end
                    else if (n_in > MA_MAX[15:0])  begin n_out <= n_in; state <= S_DONE; end
                    else begin i <= 1; state <= S_ROUT_A; end
                end

                // ---- 1. stable insertion sort by re ascending ----
                S_ROUT_A: state <= S_ROUT_U;
                S_ROUT_U: begin
                    k_rb<=a_rb; k_re<=a_re; k_qb<=a_qb; k_qe<=a_qe; k_rid<=a_rid; k_sc<=a_sc; k_cov<=a_cov;
                    j <= i - 1; state <= S_RIN_A;
                end
                S_RIN_A: state <= S_RIN_U;
                S_RIN_U: if (j >= 0 && a_re > k_re) begin j <= j - 1; state <= S_RIN_A; end
                         else state <= S_RPLACE;
                S_RPLACE: if (i + 1 >= n) begin i <= 1; state <= S_REDOUT_A; end
                          else begin i <= i + 1; state <= S_ROUT_A; end

                // ---- 2. integer redundancy de-overlap ----
                S_REDOUT_A: state <= S_REDOUT_U;
                S_REDOUT_U: if (i >= n) begin m <= 0; i <= 0; state <= S_C1_A; end
                    else begin
                        if (a_re == b_re) tie <= 1'b1;                 // equal-re in the re-sorted array
                        if (a_rid != b_rid || a_rb >= b_re + GAP) begin i <= i + 1; state <= S_REDOUT_A; end
                        else begin
                            p_rb<=a_rb; p_re<=a_re; p_qb<=a_qb; p_qe<=a_qe; p_rid<=a_rid; p_sc<=a_sc; p_cov<=a_cov;
                            j <= i - 1; state <= S_REDIN_A;
                        end
                    end
                S_REDIN_A: state <= S_REDIN_U;
                S_REDIN_U: if (!in_window) begin i <= i + 1; state <= S_REDOUT_A; end
                    else if (q_excluded) begin j <= j - 1; state <= S_REDIN_A; end
                    else if (redun) begin
                        if (p_sc < a_sc) begin i <= i + 1; state <= S_REDOUT_A; end   // p excluded; break
                        else begin j <= j - 1; state <= S_REDIN_A; end                // q excluded; continue
                    end else begin j <= j - 1; state <= S_REDIN_A; end

                // ---- 3. compact (drop qe==qb) ----
                S_C1_A: state <= S_C1_U;
                S_C1_U: if (i >= n) begin
                            n <= m;
                            if (m > 0) begin i <= 1; state <= S_SOUT_A; end
                            else begin n_out <= 0; state <= S_DONE; end
                        end else begin
                            if (a_qe > a_qb) m <= m + 1;
                            i <= i + 1; state <= S_C1_A;
                        end

                // ---- 4. score-sort (total order) ----
                S_SOUT_A: state <= S_SOUT_U;
                S_SOUT_U: if (i >= n) begin i <= 1; state <= S_ID_A; end
                    else begin
                        k_rb<=a_rb; k_re<=a_re; k_qb<=a_qb; k_qe<=a_qe; k_rid<=a_rid; k_sc<=a_sc; k_cov<=a_cov;
                        j <= i - 1; state <= S_SIN_A;
                    end
                S_SIN_A: state <= S_SIN_U;
                S_SIN_U: if (j >= 0 && key_before_j) begin j <= j - 1; state <= S_SIN_A; end
                         else state <= S_SPLACE;
                S_SPLACE: begin i <= i + 1; state <= S_SOUT_A; end

                // ---- 5. mark identical (score,rb,qb), then compact keeping index 0 ----
                S_ID_A: state <= S_ID_U;
                S_ID_U: if (i >= n) begin m <= 1; i <= 1; state <= S_C2_A; end
                    else begin
                        if (a_sc==b_sc && a_rb==b_rb && a_qb==b_qb) tie <= 1'b1;
                        i <= i + 1; state <= S_ID_A;
                    end
                S_C2_A: state <= S_C2_U;
                S_C2_U: if (i >= n) begin n_out <= m[15:0]; state <= S_DONE; end
                        else begin
                            if (a_qe > a_qb) m <= m + 1;
                            i <= i + 1; state <= S_C2_A;
                        end

                S_DONE: begin done <= 1'b1; state <= S_IDLE; end
                default: state <= S_IDLE;
            endcase
        end
    end
endmodule
