// msort_v2_top.sv
// Full v2 engine = the complete mem_sort_dedup_patch in one module:
//   LOAD -> re-sort -> windowed dedup -> compact -> score-sort -> identical-removal -> OUT
//
// Records are carried through two ping-pong RAM banks (no index gather). The merge
// sort (ported verbatim from the verified msort_merge_sorter, payload widened to a
// full record, key chosen by `second_sort`) runs twice: by `re` (pass 1) and by the
// score composite (pass 2). The dedup is the verified msort_dedup windowed loop. A
// load-time-style adjacent-`re` check during the dedup raises `fallback` (the host
// then redoes that array in software, bit-exact). Branch B (SW merge) is omitted —
// never fires on short reads (docs/merge_sorter_v2_design.md).
//
// All blocks are individually verified (tb_msort, tb_msort_dedup); this composes
// them and is checked end-to-end (tb_msort_v2) against real bwa-mem2 output.

`include "msort_v2_pkg.sv"

module msort_v2_top
    import msort_v2_pkg::*;
(
    input  logic clk,
    input  logic rst_n,

    input  logic in_valid,
    input  rec_t in_rec,
    input  logic in_last,
    output logic in_ready,

    output logic out_valid,
    output rec_t out_rec,
    output logic out_last,
    input  logic out_ready,

    output logic fallback,    // array had an equal-re tie (or n>N_MAX) -> redo in SW
    output logic busy,
    output logic done
);
    // ---- two ping-pong record banks (registered read + write) ----
    rec_t bankA [0:N_MAX-1];
    rec_t bankB [0:N_MAX-1];
    logic [IDX_W-1:0] rd_addr, wr_addr;
    logic             rd_bank, wr_bank, wr_en;
    rec_t             wr_data, rdA_q, rdB_q;
    always_ff @(posedge clk) begin
        rdA_q <= bankA[rd_addr];
        rdB_q <= bankB[rd_addr];
        if (wr_en) begin
            if (wr_bank) bankB[wr_addr] <= wr_data;
            else         bankA[wr_addr] <= wr_data;
        end
    end
    rec_t rd_q;
    assign rd_q = rd_bank ? rdB_q : rdA_q;

    // ---- comparator: is a before-or-equal b? sel=0 re asc; sel=1 alnreg_slt ----
    function automatic logic rec_le(input rec_t a, input rec_t b, input logic sel);
        if (!sel) rec_le = (a.re <= b.re);
        else if (a.score != b.score) rec_le = (a.score > b.score);
        else if (a.rb    != b.rb)    rec_le = (a.rb    < b.rb);
        else                         rec_le = (a.qb   <= b.qb);
    endfunction

    // ---- states ----
    typedef enum logic [4:0] {
        T_IDLE, T_LOAD,
        T_PASS_CHECK, T_PAIR_INIT, T_PRIME_L, T_PRIME_R, T_MERGE_STEP, T_MERGE_LATCH,
        T_DD_RDP, T_DD_LATP, T_DD_PREV, T_DD_JRD, T_DD_JLAT,
        T_CMP_RD, T_CMP_LAT,
        T_OUT_RD, T_OUT_LAT, T_OUT_BEAT,
        T_DONE
    } st_t;
    st_t state;

    cnt_t n, wptr;
    logic data_in_b, cur_b, second_sort;
    // merge-sort regs
    logic [CNT_W:0] width;
    cnt_t lo, mid, hi, k, lfetch, rfetch;
    rec_t hL, hR;
    logic lvalid, rvalid, pend, pend_left;
    // dedup regs
    cnt_t i, j;
    rec_t p;
    // compact / output regs
    cnt_t ck, cw, ok;
    rec_t out_reg, prevk;
    logic prev_valid;

    // boundary math for merge sort
    localparam int WW = CNT_W + 2;
    logic [WW-1:0] lo_ext, w_ext, lo2;
    cnt_t mid_c, hi_c;
    always_comb begin
        lo_ext = {{(WW-CNT_W){1'b0}}, lo};
        w_ext  = {{(WW-(CNT_W+1)){1'b0}}, width};
        lo2    = lo_ext + (w_ext << 1);
        mid_c  = (lo_ext + w_ext < {{(WW-CNT_W){1'b0}}, n}) ? (lo_ext + w_ext) : n;
        hi_c   = (lo2          < {{(WW-CNT_W){1'b0}}, n}) ? lo2[CNT_W-1:0]      : n;
    end

    // merge decision
    logic take_left;
    rec_t emit;
    assign take_left = lvalid && (!rvalid || rec_le(hL, hR, second_sort));
    assign emit      = take_left ? hL : hR;

    // dedup decision (valid in T_DD_JLAT; p and rd_q=q)
    logic signed [63:0] or_, oq, mr, mq;
    logic cont, q_excl, redundant, excl_p, excl_q;
    always_comb begin
        or_ = rd_q.re - p.rb;
        oq  = (rd_q.qb < p.qb) ? (64'(rd_q.qe) - 64'(p.qb)) : (64'(p.qe) - 64'(rd_q.qb));
        mr  = ((rd_q.re - rd_q.rb) < (p.re - p.rb)) ? (rd_q.re - rd_q.rb) : (p.re - p.rb);
        mq  = ((rd_q.qe - rd_q.qb) < (p.qe - p.qb)) ? (64'(rd_q.qe) - 64'(rd_q.qb)) : (64'(p.qe) - 64'(p.qb));
        cont      = (p.rid == rd_q.rid) && (p.rb < (rd_q.re + GAP));
        q_excl    = (rd_q.qe == rd_q.qb);
        redundant = (RED_NUM*or_ > RED_DEN*mr) && (RED_NUM*oq > RED_DEN*mq);
        excl_p    = cont && !q_excl && redundant && (p.score <  rd_q.score);
        excl_q    = cont && !q_excl && redundant && (p.score >= rd_q.score);
    end

    // ---- combinational read address (per state at issue time) ----
    always_comb begin
        unique case (state)
            T_PAIR_INIT:  rd_addr = lo[IDX_W-1:0];
            T_PRIME_L:    rd_addr = mid[IDX_W-1:0];
            T_MERGE_STEP: rd_addr = take_left ? lfetch[IDX_W-1:0] : rfetch[IDX_W-1:0];
            T_DD_RDP:     rd_addr = i[IDX_W-1:0];
            T_DD_LATP:    rd_addr = (i - 1'b1);
            T_DD_JRD:     rd_addr = j[IDX_W-1:0];
            T_CMP_RD:     rd_addr = ck[IDX_W-1:0];
            T_OUT_RD:     rd_addr = ok[IDX_W-1:0];
            default:      rd_addr = '0;
        endcase
    end
    // Read-bank select is per-PHASE (stable across the read's issue and the next-
    // cycle consume), NOT per-state: sort phase reads the live `data_in_b` bank;
    // dedup/compact/output read `cur_b`. (data_in_b/cur_b only change at phase
    // boundaries, after the relevant reads are consumed.)
    logic in_sort_phase;
    assign in_sort_phase = (state == T_PASS_CHECK) || (state == T_PAIR_INIT) ||
                           (state == T_PRIME_L)    || (state == T_PRIME_R)   ||
                           (state == T_MERGE_STEP) || (state == T_MERGE_LATCH);
    assign rd_bank = in_sort_phase ? data_in_b : cur_b;

    // ---- combinational write port ----
    always_comb begin
        wr_en = 1'b0; wr_addr = '0; wr_bank = 1'b0; wr_data = in_rec;
        if ((state == T_IDLE || state == T_LOAD) && in_valid) begin
            wr_en = 1'b1; wr_addr = wptr[IDX_W-1:0]; wr_bank = 1'b0; wr_data = in_rec;   // load->A
        end else if (state == T_MERGE_STEP) begin
            wr_en = 1'b1; wr_addr = k[IDX_W-1:0]; wr_bank = ~data_in_b; wr_data = emit;  // sort dst
        end else if (state == T_DD_JLAT && excl_p) begin
            wr_en = 1'b1; wr_addr = i[IDX_W-1:0]; wr_bank = cur_b; wr_data = p;    wr_data.qe = p.qb;
        end else if (state == T_DD_JLAT && excl_q) begin
            wr_en = 1'b1; wr_addr = j[IDX_W-1:0]; wr_bank = cur_b; wr_data = rd_q; wr_data.qe = rd_q.qb;
        end else if (state == T_CMP_LAT && (rd_q.qe > rd_q.qb)) begin
            wr_en = 1'b1; wr_addr = cw[IDX_W-1:0]; wr_bank = ~cur_b; wr_data = rd_q;     // survivor->other
        end
    end

    assign in_ready  = (state == T_IDLE) || (state == T_LOAD);
    assign busy      = (state != T_IDLE);
    assign out_valid = (state == T_OUT_BEAT);
    assign out_rec   = out_reg;
    assign out_last  = (state == T_OUT_BEAT) && (ok == n - 1'b1);

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state <= T_IDLE; wptr <= '0; n <= '0; data_in_b <= 1'b0; cur_b <= 1'b0;
            second_sort <= 1'b0; fallback <= 1'b0; done <= 1'b0; prev_valid <= 1'b0;
        end else begin
            done <= 1'b0;
            case (state)
                // ===== load (into bank A) =====
                T_IDLE: begin
                    fallback <= 1'b0; wptr <= '0; data_in_b <= 1'b0; cur_b <= 1'b0;
                    second_sort <= 1'b0; prev_valid <= 1'b0;
                    if (in_valid) begin
                        wptr <= 'd1;
                        if (in_last) begin n <= 'd1; width <= 'd1; state <= T_PASS_CHECK; end
                        else state <= T_LOAD;
                    end
                end
                T_LOAD: begin
                    if (in_valid) begin
                        wptr <= wptr + 1'b1;
                        if (in_last) begin n <= wptr + 1'b1; width <= 'd1; state <= T_PASS_CHECK; end
                    end
                end

                // ===== merge sort (shared; second_sort picks key & next phase) =====
                T_PASS_CHECK: begin
                    if (width < n && n > 1) begin
                        lo <= '0; k <= '0; state <= T_PAIR_INIT;
                    end else begin
                        // sort complete: result lives in data_in_b bank
                        cur_b <= data_in_b;
                        if (n == 0) state <= T_DONE;                  // no survivors
                        else if (!second_sort) begin
                            i <= 'd1; state <= T_DD_RDP;              // -> dedup (n>=2)
                        end else begin
                            ok <= '0; prev_valid <= 1'b0; state <= T_OUT_RD;  // -> output
                        end
                    end
                end
                T_PAIR_INIT: begin
                    mid <= mid_c; hi <= hi_c; lfetch <= lo + 1'b1; rfetch <= mid_c + 1'b1;
                    lvalid <= 1'b0; rvalid <= 1'b0; pend <= 1'b0; state <= T_PRIME_L;
                end
                T_PRIME_L: begin
                    hL <= rd_q; lvalid <= 1'b1;
                    if (mid < hi) state <= T_PRIME_R;
                    else begin rvalid <= 1'b0; state <= T_MERGE_STEP; end
                end
                T_PRIME_R: begin hR <= rd_q; rvalid <= 1'b1; state <= T_MERGE_STEP; end
                T_MERGE_STEP: begin
                    k <= k + 1'b1;                       // write via wr port (dst)
                    if (take_left) begin
                        if (lfetch < mid) begin lfetch <= lfetch + 1'b1; pend <= 1'b1; pend_left <= 1'b1; end
                        else             begin lvalid <= 1'b0; pend <= 1'b0; end
                    end else begin
                        if (rfetch < hi)  begin rfetch <= rfetch + 1'b1; pend <= 1'b1; pend_left <= 1'b0; end
                        else             begin rvalid <= 1'b0; pend <= 1'b0; end
                    end
                    state <= T_MERGE_LATCH;
                end
                T_MERGE_LATCH: begin
                    if (pend) begin
                        if (pend_left) hL <= rd_q; else hR <= rd_q;
                        pend <= 1'b0; state <= T_MERGE_STEP;
                    end else if (!lvalid && !rvalid) begin
                        if (lo2 >= {{(WW-CNT_W){1'b0}}, n}) begin
                            data_in_b <= ~data_in_b; width <= width << 1; state <= T_PASS_CHECK;
                        end else begin
                            lo <= lo2[CNT_W-1:0]; state <= T_PAIR_INIT;
                        end
                    end else state <= T_MERGE_STEP;
                end

                // ===== windowed dedup (records physically re-sorted in cur_b) =====
                T_DD_RDP:  state <= T_DD_LATP;
                T_DD_LATP: begin p <= rd_q; state <= T_DD_PREV; end
                T_DD_PREV: begin
                    if (p.re == rd_q.re) fallback <= 1'b1;            // adjacent equal re -> SW fallback
                    if (p.rid != rd_q.rid || p.rb >= (rd_q.re + GAP)) begin
                        if (i + 1'b1 >= n) begin ck <= '0; cw <= '0; state <= T_CMP_RD; end
                        else begin i <= i + 1'b1; state <= T_DD_RDP; end
                    end else begin
                        j <= i - 1'b1; state <= T_DD_JRD;
                    end
                end
                T_DD_JRD:  state <= T_DD_JLAT;
                T_DD_JLAT: begin
                    if (!cont || excl_p) begin
                        if (i + 1'b1 >= n) begin ck <= '0; cw <= '0; state <= T_CMP_RD; end
                        else begin i <= i + 1'b1; state <= T_DD_RDP; end
                    end else begin
                        if (j == 0) begin
                            if (i + 1'b1 >= n) begin ck <= '0; cw <= '0; state <= T_CMP_RD; end
                            else begin i <= i + 1'b1; state <= T_DD_RDP; end
                        end else begin j <= j - 1'b1; state <= T_DD_JRD; end
                    end
                end

                // ===== compact survivors (cur_b -> ~cur_b), then score-sort =====
                T_CMP_RD:  state <= T_CMP_LAT;
                T_CMP_LAT: begin
                    if (rd_q.qe > rd_q.qb) cw <= cw + 1'b1;           // survivor written via wr port
                    if (ck + 1'b1 >= n) begin
                        // compaction done: survivors in ~cur_b, count = cw(+maybe this one)
                        cur_b <= ~cur_b;
                        n <= (rd_q.qe > rd_q.qb) ? (cw + 1'b1) : cw;
                        data_in_b <= ~cur_b;                          // score-sort src = survivor bank
                        second_sort <= 1'b1; width <= 'd1; state <= T_PASS_CHECK;
                    end else begin
                        ck <= ck + 1'b1; state <= T_CMP_RD;
                    end
                end

                // ===== output with identical-(score,rb,qb) removal =====
                T_OUT_RD:  state <= T_OUT_LAT;
                T_OUT_LAT: begin
                    if (prev_valid && rd_q.score==prevk.score && rd_q.rb==prevk.rb && rd_q.qb==prevk.qb) begin
                        if (ok + 1'b1 >= n) state <= T_DONE;
                        else begin ok <= ok + 1'b1; state <= T_OUT_RD; end
                    end else begin
                        out_reg <= rd_q; state <= T_OUT_BEAT;
                    end
                end
                T_OUT_BEAT: begin
                    if (out_ready) begin
                        prevk <= out_reg; prev_valid <= 1'b1;
                        if (ok + 1'b1 >= n) state <= T_DONE;
                        else begin ok <= ok + 1'b1; state <= T_OUT_RD; end
                    end
                end

                T_DONE: begin done <= 1'b1; state <= T_IDLE; end
                default: state <= T_IDLE;
            endcase
        end
    end
endmodule
