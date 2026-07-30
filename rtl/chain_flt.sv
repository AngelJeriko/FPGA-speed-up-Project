// chain_flt.sv — mem_chain_flt POST-SORT stage = the greedy overlap/shadow filter, the
// max_chain_extend cap, and the kept annotation. Models host/chaining/chain.h::c_chain_flt_post
// bit-exact. Input chains are already WEIGHTED and SORTED by weight DESC (produced upstream by
// chain_weight + chain_introsort), each reduced to its filter-relevant metadata:
//   w     = chain weight
//   cbeg  = first seed qbeg   (query span start)
//   cend  = last seed qbeg+len (query span end)
//   isalt = on an ALT contig
// Output: per-chain `kept` (0 drop / 1 shadowed-resurrected / 2 overlapped-kept / 3 primary).
// A chain is in the final chain set iff kept != 0.
//
// The greedy loop keeps a `keptlist` of survivors (highest weight first). Each new chain i is
// compared against every survivor j: a SIGNIFICANT query overlap (>= half the smaller span,
// span < max_chain_gap, and j not-alt-unless-i-alt) records a shadow (j.first=i) and, if i is
// much weaker (2*w_i < w_j and gap >= 2*min_seed_len), DROPS i. Survivors that shadowed someone
// resurrect their first shadowed chain (kept=1). Integer surrogates: mask_level=drop_ratio=0.5.
//
// SYNTHESIZABILITY (2026-07-30, worklist #4): the metadata arrays cw/cb/ce/calt were read
// COMBINATIONALLY at TWO indices (i and jj=keptlist[kk]) every cycle -> two 512:1 LUT-mux trees
// per array feeding the compares (area bloat + long path). They are now a single REGISTERED-READ
// port (present rd_addr -> *_q valid next cycle) so they infer simple-dual-port BRAM (one write
// port = the host load, one read port). element[i] is CONSTANT across the whole inner loop, so it
// is read once and latched into *_i; the inner loop reads only the survivor jj. Bit-exact:
// identical algebra, just deferred by a cycle; extra internal states are transparent behind
// busy/done. See docs/synthesizability_worklist.md and docs/synth_ooc_results.md.
module chain_flt #(parameter int NMAX = 512) (
    input  logic               clk,
    input  logic               rst_n,

    // ---- config ----
    input  logic signed [31:0] max_chain_gap,
    input  logic signed [31:0] min_seed_len,
    input  logic signed [31:0] max_chain_extend,

    // ---- chain load (sorted by weight DESC, idx 0..n_in-1) ----
    input  logic               ld_en,
    input  logic [15:0]        ld_idx,
    input  logic signed [31:0] ld_w,
    input  logic signed [31:0] ld_cbeg,
    input  logic signed [31:0] ld_cend,
    input  logic               ld_isalt,

    // ---- run ----
    input  logic               start,
    input  logic [15:0]        n_in,
    output logic               busy,
    output logic               done,
    output logic [15:0]        n_out,

    // ---- readback ----
    input  logic [15:0]        rd_idx,
    output logic [1:0]         o_kept
);
    localparam int AW = $clog2(NMAX);

    // ---- per-chain metadata ----
    // cw/cb/ce/calt: written ONLY by the load port (single writer) and read via the
    // registered-read port below -> simple-dual-port BRAM. kept/first/keptlist remain
    // FSM-driven register files (single-index, out of this conversion's scope).
    logic signed [31:0] cw[NMAX], cb[NMAX], ce[NMAX];
    logic               calt[NMAX];
    logic [1:0]         kept[NMAX];
    logic signed [31:0] first[NMAX];           // index of first shadowed chain, or -1
    logic [15:0]        keptlist[NMAX], klen;

    always_ff @(posedge clk) if (ld_en && ld_idx < NMAX[15:0]) begin
        cw[ld_idx]<=ld_w; cb[ld_idx]<=ld_cbeg; ce[ld_idx]<=ld_cend; calt[ld_idx]<=ld_isalt;
    end
    logic [15:0] n;
    assign n_out  = n;
    assign o_kept = kept[rd_idx];

    // ---- working regs ----
    logic [15:0] i, kk, ci, ei;
    logic signed [31:0] cnt;
    logic        large_ovlp;
    logic signed [31:0] gap, msl, mce;
    logic [15:0] jj_r;                          // survivor index whose metadata is in *_q

    // ---- registered-read port over the metadata arrays ----
    // rd_addr presented one cycle; *_q valid the next. Index i is read once and
    // latched into *_i (constant across the inner loop); the inner loop reads jj.
    logic [AW-1:0]      rd_addr;
    logic signed [31:0] cw_q, cb_q, ce_q;
    logic               calt_q;
    always_ff @(posedge clk) begin
        cw_q   <= cw  [rd_addr];
        cb_q   <= cb  [rd_addr];
        ce_q   <= ce  [rd_addr];
        calt_q <= calt[rd_addr];
    end

    // latched metadata for the outer chain i
    logic signed [31:0] cw_i, cb_i, ce_i;
    logic               calt_i;

    typedef enum logic [3:0] {
        L_IDLE, L_CLR, L_OUTER, L_IPRES, L_ILAT, L_JPRES, L_JCON,
        L_ADD, L_NEXT, L_RES, L_EXT1, L_EXT2, L_DONE
    } st_t;
    st_t state;
    assign busy = (state != L_IDLE);

    // rd_addr: present i by default; present survivor keptlist[kk] during L_JPRES.
    always_comb begin
        rd_addr = i[AW-1:0];
        if (state == L_JPRES) rd_addr = keptlist[kk][AW-1:0];
    end

    // ---- inner-loop combinational compare of chain i (latched *_i) vs survivor
    //      jj (registered-read *_q). Identical algebra to the C++ model:
    //      cw_i/cb_i/ce_i/calt_i == c*[i]; cw_q/cb_q/ce_q/calt_q == c*[jj].
    logic signed [31:0] b_max, e_min, li, lj, min_l;
    logic ov, signif, brk;
    always_comb begin
        b_max  = (cb_q > cb_i) ? cb_q : cb_i;
        e_min  = (ce_q < ce_i) ? ce_q : ce_i;
        ov     = (e_min > b_max) && (!calt_q || calt_i);
        li     = ce_i - cb_i;
        lj     = ce_q - cb_q;
        min_l  = (li < lj) ? li : lj;
        signif = ov && (2*(e_min - b_max) >= min_l) && (min_l < gap);
        brk    = signif && (2*cw_i < cw_q) && ((cw_q - cw_i) >= (msl <<< 1));
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state<=L_IDLE; done<=1'b0;
        end else begin
            done<=1'b0;
            case (state)
                L_IDLE: if (start) begin
                    n<=n_in; gap<=max_chain_gap; msl<=min_seed_len; mce<=max_chain_extend;
                    ci<=16'd0; state<=L_CLR;
                end

                // clear kept/first; then seed keptlist with chain 0 (kept=3)
                L_CLR: begin
                    if (ci < n) begin
                        kept[ci]<=2'd0; first[ci]<=-32'sd1; ci<=ci+16'd1;
                    end else begin
                        if (n == 16'd0) state<=L_DONE;
                        else begin
                            kept[0]<=2'd3; keptlist[0]<=16'd0; klen<=16'd1;
                            i<=16'd1; state<=L_OUTER;
                        end
                    end
                end

                L_OUTER: begin
                    if (i >= n) begin kk<=16'd0; state<=L_RES; end
                    else begin large_ovlp<=1'b0; kk<=16'd0; state<=L_IPRES; end
                end

                // read element[i] (rd_addr=i via default) and latch it next cycle
                L_IPRES: state<=L_ILAT;
                L_ILAT: begin
                    cw_i<=cw_q; cb_i<=cb_q; ce_i<=ce_q; calt_i<=calt_q;
                    if (kk >= klen) state<=L_ADD;        // no survivors to test
                    else            state<=L_JPRES;
                end

                // present survivor keptlist[kk], remember its index, consume next cycle
                L_JPRES: begin jj_r<=keptlist[kk]; state<=L_JCON; end

                // compare chain i against survivor jj_r; drop (break) or advance
                L_JCON: begin
                    if (signif) begin
                        large_ovlp<=1'b1;
                        if (first[jj_r] < 0) first[jj_r]<=i;
                    end
                    if (brk) state<=L_NEXT;              // i dropped (kept stays 0)
                    else begin
                        kk<=kk+16'd1;
                        state<= ((kk+16'd1) >= klen) ? L_ADD : L_JPRES;
                    end
                end

                // i survived: append to keptlist, kept = overlap? 2 : 3
                L_ADD: begin
                    keptlist[klen]<=i; klen<=klen+16'd1;
                    kept[i]<= large_ovlp ? 2'd2 : 2'd3;
                    state<=L_NEXT;
                end

                L_NEXT: begin i<=i+16'd1; state<=L_OUTER; end

                // resurrect: each survivor that shadowed someone marks its first shadowed kept=1
                L_RES: begin
                    if (kk >= klen) begin ei<=16'd0; cnt<=32'sd0; state<=L_EXT1; end
                    else begin
                        if (first[keptlist[kk]] >= 0) kept[first[keptlist[kk]]]<=2'd1;
                        kk<=kk+16'd1;
                    end
                end

                // max_chain_extend: count kept in {1,2}; once count would reach mce, zero the rest
                L_EXT1: begin
                    if (ei >= n) state<=L_DONE;
                    else if (kept[ei]==2'd0 || kept[ei]==2'd3) ei<=ei+16'd1;
                    else if ((cnt + 32'sd1) >= mce) state<=L_EXT2;   // break here, start zeroing at ei
                    else begin cnt<=cnt+32'sd1; ei<=ei+16'd1; end
                end
                L_EXT2: begin
                    if (ei >= n) state<=L_DONE;
                    else begin if (kept[ei] < 2'd3) kept[ei]<=2'd0; ei<=ei+16'd1; end
                end

                L_DONE: begin done<=1'b1; state<=L_IDLE; end
                default: state<=L_IDLE;
            endcase
        end
    end
endmodule
