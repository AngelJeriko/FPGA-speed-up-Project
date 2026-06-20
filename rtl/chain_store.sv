// chain_store.sv
// mem_chain (bwamem.cpp) for one read = the kbtree-of-chains replaced by a sorted-by-pos
// array of chain METADATA + an append-only seed POOL (linked list per chain). Models
// host/chaining/chain.h::c_mem_chain bit-exact:
//   for each seed (in stream order):
//     lo = predecessor (kb_intervalp): exact pos -> leftmost equal, else rightmost pos<key
//     if lo>=0 && test_and_merge(chain[lo], seed): absorb (contained) or append (colinear)
//     else: insert a NEW chain at lo+1 (kb_putp position); dup-pos -> `fallback`
//
// HW structure: chain metadata array (c_pos sorted asc) shifts on insert; the seed pool is
// append-only (seeds never move), each chain a singly-linked list (head/tail/next). So an
// insert shifts only metadata, and an append is O(1). test_and_merge needs only the chain's
// FIRST seed (pos/first_qbeg) and LAST seed (last_qbeg/rbeg/len) + rid -> kept in metadata.
//
// Output: n_chains; per chain {pos,rid,is_alt,n_seeds,head}; walk seeds via the pool's `next`.
// `fallback` (dup-pos) marks reads the flat array can't reproduce the kbtree's multi-node
// ordering on -> host SW redo (chain.h's `fb`; ~3-4% of reads). NCHAIN/NSEED bound the read;
// exceeding either capacity (chains or pooled seeds) also raises `fallback` -> host SW redo.

module chain_store #(parameter int NCHAIN = 512, parameter int NSEED = 2048) (
    input  logic               clk,
    input  logic               rst_n,

    // ---- config ----
    input  logic signed [31:0] w,            // opt->w (band)
    input  logic signed [31:0] max_chain_gap,
    input  logic signed [63:0] l_pac,

    // ---- seed stream load (idx 0..n_in-1, in order) ----
    input  logic               ld_en,
    input  logic [15:0]        ld_idx,
    input  logic signed [63:0] ld_rbeg,
    input  logic signed [31:0] ld_qbeg,
    input  logic signed [31:0] ld_len,
    input  logic signed [31:0] ld_score,
    input  logic signed [31:0] ld_rid,
    input  logic signed [31:0] ld_isalt,

    // ---- run ----
    input  logic               start,
    input  logic [15:0]        n_in,
    output logic               busy,
    output logic               done,
    output logic               fallback,     // dup-pos -> host SW redo
    output logic [15:0]        n_chains,

    // ---- chain metadata readback ----
    input  logic [15:0]        rd_cidx,
    output logic signed [63:0] o_pos,
    output logic signed [31:0] o_rid,
    output logic signed [31:0] o_isalt,
    output logic [15:0]        o_nseeds,
    output logic [15:0]        o_head,

    // ---- seed pool readback (walk a chain via head -> next ...) ----
    input  logic [15:0]        rd_sidx,
    output logic signed [63:0] s_rbeg,
    output logic signed [31:0] s_qbeg,
    output logic signed [31:0] s_len,
    output logic signed [31:0] s_score,
    output logic [15:0]        s_next
);
    // ---- seed input buffer (the stream) ----
    logic signed [63:0] in_rbeg[NSEED];
    logic signed [31:0] in_qbeg[NSEED], in_len[NSEED], in_score[NSEED], in_rid[NSEED], in_isalt[NSEED];
    always_ff @(posedge clk) if (ld_en && ld_idx < NSEED[15:0]) begin
        in_rbeg[ld_idx]<=ld_rbeg; in_qbeg[ld_idx]<=ld_qbeg; in_len[ld_idx]<=ld_len;
        in_score[ld_idx]<=ld_score; in_rid[ld_idx]<=ld_rid; in_isalt[ld_idx]<=ld_isalt;
    end

    // ---- seed pool (append-only linked list) ----
    logic signed [63:0] p_rbeg[NSEED];
    logic signed [31:0] p_qbeg[NSEED], p_len[NSEED], p_score[NSEED];
    logic [15:0]        p_next[NSEED];
    logic [15:0]        pool_n;

    // ---- chain metadata (sorted by c_pos ascending) ----
    logic signed [63:0] c_pos [NCHAIN];     // = first seed rbeg
    logic signed [31:0] c_rid [NCHAIN], c_isalt[NCHAIN];
    logic signed [31:0] c_fq  [NCHAIN];     // first seed qbeg
    logic signed [31:0] c_lq  [NCHAIN];     // last seed qbeg
    logic signed [63:0] c_lr  [NCHAIN];     // last seed rbeg
    logic signed [31:0] c_ll  [NCHAIN];     // last seed len
    logic [15:0]        c_head[NCHAIN], c_tail[NCHAIN], c_n[NCHAIN];
    logic [15:0]        nch;

    assign n_chains = nch;
    assign o_pos    = c_pos[rd_cidx];
    assign o_rid    = c_rid[rd_cidx];
    assign o_isalt  = c_isalt[rd_cidx];
    assign o_nseeds = c_n[rd_cidx];
    assign o_head   = c_head[rd_cidx];
    assign s_rbeg   = p_rbeg[rd_sidx];
    assign s_qbeg   = p_qbeg[rd_sidx];
    assign s_len    = p_len[rd_sidx];
    assign s_score  = p_score[rd_sidx];
    assign s_next   = p_next[rd_sidx];

    // ---- current seed being processed ----
    logic signed [63:0] s_rb; logic signed [31:0] s_qb, s_ln, s_sc, s_rd, s_al;
    logic [15:0] i;                 // input seed index
    logic [15:0] lo; logic signed [31:0] lo_s;   // predecessor (lo_s = -1 -> none)
    integer sh;                                  // shift index for insert

    // ---- predecessor (kb_intervalp) over the sorted pos array, for in_rbeg[i] ----
    logic [15:0] pred_beg, pred_lo; logic signed [31:0] pred_lo_s;
    always_comb begin
        pred_beg = 16'd0;
        for (int c=0;c<NCHAIN;c++)
            if (c < {16'd0,nch} && c_pos[c] < in_rbeg[i]) pred_beg = c[15:0] + 16'd1;
        if (pred_beg < nch && c_pos[pred_beg] == in_rbeg[i]) begin
            pred_lo = pred_beg;            pred_lo_s = {16'd0, pred_beg};
        end else begin
            pred_lo = pred_beg - 16'd1;    pred_lo_s = $signed({16'd0, pred_beg}) - 32'sd1;
        end
    end

    // ---- test_and_merge (combinational on chain[lo] vs current seed); valid if lo_s>=0 ----
    logic [15:0] loc;                       // clamped lo for safe array reads
    assign loc = (lo_s >= 0) ? lo : 16'd0;
    // all 64-bit SIGNED (a [31:0] part-select of a signed value is UNSIGNED in SV and
    // would poison the diffs -> sign-extend everything instead).
    logic signed [63:0] last_re, last_qe, sln64, cll64, xx, yy, w64, gap64;
    logic same_rid, contained, strand_block, colinear;
    always_comb begin
        sln64  = {{32{s_ln[31]}},        s_ln};
        cll64  = {{32{c_ll[loc][31]}},   c_ll[loc]};
        w64    = {{32{w[31]}},           w};
        gap64  = {{32{max_chain_gap[31]}}, max_chain_gap};
        last_qe = $signed({{32{c_lq[loc][31]}}, c_lq[loc]}) + cll64;  // last.qbeg + last.len
        last_re = c_lr[loc] + cll64;                            // last.rbeg + last.len
        same_rid = (s_rd == c_rid[loc]);
        contained = ($signed({{32{s_qb[31]}},s_qb}) >= $signed({{32{c_fq[loc][31]}},c_fq[loc]})) &&
                    (($signed({{32{s_qb[31]}},s_qb}) + sln64) <= last_qe) &&
                    (s_rb >= c_pos[loc]) && ((s_rb + sln64) <= last_re);
        strand_block = ((c_lr[loc] < l_pac) || (c_pos[loc] < l_pac)) && (s_rb >= l_pac);
        xx = {{32{s_qb[31]}},s_qb} - {{32{c_lq[loc][31]}},c_lq[loc]};   // x = p.qbeg - last.qbeg
        yy = s_rb - c_lr[loc];                                         // y = p.rbeg - last.rbeg
        colinear = (yy >= 0) && ((xx - yy) <= w64) && ((yy - xx) <= w64) &&
                   ((xx - cll64) < gap64) && ((yy - cll64) < gap64);
    end

    typedef enum logic [3:0] { C_IDLE, C_PRED, C_DECIDE, C_APPEND, C_INSERT, C_NEXT, C_DONE } st_t;
    st_t state;
    assign busy = (state != C_IDLE);

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state<=C_IDLE; done<=1'b0; fallback<=1'b0; nch<='0; pool_n<='0;
        end else begin
            done<=1'b0;
            case (state)
                C_IDLE: if (start) begin
                    nch<=16'd0; pool_n<=16'd0; fallback<=1'b0; i<=16'd0;
                    if (n_in==16'd0) state<=C_DONE; else state<=C_PRED;
                end

                // latch current seed + the combinational predecessor for in_rbeg[i]
                C_PRED: begin
                    s_rb<=in_rbeg[i]; s_qb<=in_qbeg[i]; s_ln<=in_len[i];
                    s_sc<=in_score[i]; s_rd<=in_rid[i]; s_al<=in_isalt[i];
                    lo<=pred_lo; lo_s<=pred_lo_s;
                    state<=C_DECIDE;
                end

                // decide: merge into chain[lo] (append/contained) or add a new chain
                C_DECIDE: begin
                    if (lo_s >= 0 && same_rid && contained) begin
                        state<=C_NEXT;                         // absorbed; seeds unchanged
                    end else if (lo_s >= 0 && same_rid && !strand_block && colinear) begin
                        // colinear append: needs one pool slot
                        if (pool_n >= NSEED[15:0]) begin fallback<=1'b1; state<=C_NEXT; end
                        else state<=C_APPEND;
                    end else begin
                        if (lo_s >= 0 && c_pos[lo] == s_rb) fallback<=1'b1;   // dup-pos
                        // new chain: needs one chain slot AND one pool slot; on overflow the
                        // flat arrays can't hold the read -> flag for host SW redo, skip write
                        if (nch >= NCHAIN[15:0] || pool_n >= NSEED[15:0]) begin
                            fallback<=1'b1; state<=C_NEXT;
                        end else begin
                            sh <= nch;                         // shift from the top down
                            state<=C_INSERT;
                        end
                    end
                end

                // append current seed to chain[lo]'s pool list; update its last_*
                C_APPEND: begin
                    p_rbeg[pool_n]<=s_rb; p_qbeg[pool_n]<=s_qb; p_len[pool_n]<=s_ln;
                    p_score[pool_n]<=s_sc; p_next[pool_n]<=16'hFFFF;
                    p_next[c_tail[lo]] <= pool_n;              // link old tail -> new
                    c_tail[lo] <= pool_n;
                    c_lq[lo]<=s_qb; c_lr[lo]<=s_rb; c_ll[lo]<=s_ln;
                    c_n[lo] <= c_n[lo] + 16'd1;
                    pool_n <= pool_n + 16'd1;
                    state<=C_NEXT;
                end

                // insert new chain at lo+1: shift metadata [lo+1..nch-1] up, place new
                C_INSERT: begin
                    if ($signed(sh) > (lo_s + 1)) begin
                        c_pos[sh]<=c_pos[sh-1]; c_rid[sh]<=c_rid[sh-1]; c_isalt[sh]<=c_isalt[sh-1];
                        c_fq[sh]<=c_fq[sh-1]; c_lq[sh]<=c_lq[sh-1]; c_lr[sh]<=c_lr[sh-1]; c_ll[sh]<=c_ll[sh-1];
                        c_head[sh]<=c_head[sh-1]; c_tail[sh]<=c_tail[sh-1]; c_n[sh]<=c_n[sh-1];
                        sh <= sh - 1;
                    end else begin
                        c_pos[lo_s+1]<=s_rb; c_rid[lo_s+1]<=s_rd; c_isalt[lo_s+1]<=s_al;
                        c_fq[lo_s+1]<=s_qb; c_lq[lo_s+1]<=s_qb; c_lr[lo_s+1]<=s_rb; c_ll[lo_s+1]<=s_ln;
                        c_head[lo_s+1]<=pool_n; c_tail[lo_s+1]<=pool_n; c_n[lo_s+1]<=16'd1;
                        p_rbeg[pool_n]<=s_rb; p_qbeg[pool_n]<=s_qb; p_len[pool_n]<=s_ln;
                        p_score[pool_n]<=s_sc; p_next[pool_n]<=16'hFFFF;
                        pool_n <= pool_n + 16'd1;
                        nch <= nch + 16'd1;
                        state<=C_NEXT;
                    end
                end

                C_NEXT: begin
                    if (i + 16'd1 >= n_in) state<=C_DONE;
                    else begin i<=i+16'd1; state<=C_PRED; end
                end

                C_DONE: begin done<=1'b1; state<=C_IDLE; end
                default: state<=C_IDLE;
            endcase
        end
    end
endmodule
