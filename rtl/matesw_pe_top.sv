// matesw_pe_top.sv
// Paired-end mate-rescue wrapper = the b[i] candidate loop of mem_sam_pe_batch_post
// (!MATE_SORT, bwamem_pair.cpp:778-789) for ONE direction. The mate (read !i) is
// rescued against EACH "good" candidate of read i; every mem_matesw call mutates the
// SAME ma list (a[!i]), which therefore must be threaded across candidates:
//
//   for j in 0 .. n_cand-1:   ma = matesw_orchestrate(cand[j], mate_seq, ma)
//
// This wrapper owns the shared ma register file and drives the verified
// matesw_orch_top (= one mem_matesw call) once per candidate: stream ma in, run,
// read the updated ma back. The mate sequence (ms) and each candidate's host-fed
// reference windows are loaded through the pass-through ld ports before the
// candidate's cand_start. The full pair = two independent runs (one per direction).
//
// Sequence per candidate (after init loads the entry ma + ms):
//   host loads cand[j]'s 4 ref windows (ld_ref) + drives its scalars/window-meta;
//   pulses cand_start; wrapper: load ma -> orch_top, start, wait, read ma back;
//   raises cand_done. Final ma is read via rd_idx (n_ma entries).

`include "bsw_pkg.sv"

module matesw_pe_top
    import bsw_pkg::*;
#(
    parameter int MA_MAX = 64
)(
    input  logic               clk,
    input  logic               rst_n,

    // ---- pass-through loads to the inner orch_top (mate seq + ref windows) ----
    input  logic               ld_ms_en,
    input  logic [15:0]        ld_ms_addr,
    input  base_t              ld_ms_data,
    input  logic               ld_ref_en,
    input  logic [1:0]         ld_ref_win,
    input  logic [15:0]        ld_ref_addr,
    input  base_t              ld_ref_data,

    // ---- entry ma load (into the wrapper's shared register file) ----
    input  logic               ld_ma_en,
    input  logic [15:0]        ld_ma_idx,
    input  logic signed [63:0] ld_ma_rb,
    input  logic signed [63:0] ld_ma_re,
    input  logic signed [31:0] ld_ma_qb,
    input  logic signed [31:0] ld_ma_qe,
    input  logic signed [31:0] ld_ma_rid,
    input  logic signed [31:0] ld_ma_score,
    input  logic signed [31:0] ld_ma_cov,
    input  logic               init,            // pulse: latch n_ma_init as the live count
    input  logic [15:0]        n_ma_init,

    // ---- per-candidate request ----
    input  logic               cand_start,
    input  logic signed [31:0] l_ms,
    input  logic signed [31:0] min_seed_len,
    input  logic signed [31:0] a,
    input  logic signed [31:0] o_del, e_del, o_ins, e_ins,
    input  logic signed [63:0] a_rb,
    input  logic signed [63:0] l_pac,
    input  logic signed [31:0] a_rid,
    input  logic signed [31:0] a_is_alt,
    input  logic [3:0]         win_used,
    input  logic signed [63:0] win_rb  [4],
    input  logic signed [63:0] win_re  [4],
    input  logic signed [31:0] win_rid [4],
    input  logic signed [63:0] pes_low [4],
    input  logic signed [63:0] pes_high[4],
    input  logic [3:0]         pes_failed,

    // ---- status / result ----
    output logic               busy,
    output logic               cand_done,
    output logic               tie,        // any candidate's dedup tie -> SW fallback
    output logic [15:0]        n_ma,
    input  logic [15:0]        rd_idx,
    output logic signed [63:0] o_rb,
    output logic signed [63:0] o_re,
    output logic signed [31:0] o_qb,
    output logic signed [31:0] o_qe,
    output logic signed [31:0] o_rid,
    output logic signed [31:0] o_score,
    output logic signed [31:0] o_cov
);
    // ---- shared ma register file ----
    logic signed [63:0] w_rb [MA_MAX];
    logic signed [63:0] w_re [MA_MAX];
    logic signed [31:0] w_qb [MA_MAX];
    logic signed [31:0] w_qe [MA_MAX];
    logic signed [31:0] w_rid[MA_MAX];
    logic signed [31:0] w_sc [MA_MAX];
    logic signed [31:0] w_cov[MA_MAX];

    assign o_rb=w_rb[rd_idx]; assign o_re=w_re[rd_idx]; assign o_qb=w_qb[rd_idx];
    assign o_qe=w_qe[rd_idx]; assign o_rid=w_rid[rd_idx]; assign o_score=w_sc[rd_idx];
    assign o_cov=w_cov[rd_idx];
    assign n_ma = n_r;

    logic [15:0] n_r;            // live ma count
    integer k;

    typedef enum logic [2:0] { P_IDLE, P_LDMA, P_RUN, P_WAIT, P_RD0, P_RD1, P_DONE } st_t;
    st_t state;

    // ---- latched candidate request ----
    logic signed [31:0] lms_r, msl_r, a_r, od_r, ed_r, oi_r, ei_r, arid_r, aalt_r;
    logic signed [63:0] arb_r, lpac_r;
    logic [3:0] wu_r, pf_r;
    logic signed [63:0] wrb_r[4], wre_r[4], plo_r[4], phi_r[4];
    logic signed [31:0] wrid_r[4];

    // ---- inner orch_top ----
    logic               ot_ldma_en; logic [15:0] ot_ldma_idx;
    logic signed [63:0] ot_ldma_rb, ot_ldma_re; logic signed [31:0] ot_ldma_qb,ot_ldma_qe,ot_ldma_rid,ot_ldma_sc,ot_ldma_cov;
    logic               ot_start, ot_busy, ot_done, ot_ovf, ot_tie; logic [15:0] ot_nin, ot_nout;
    logic [15:0]        ot_rd_idx;
    logic signed [63:0] ot_o_rb, ot_o_re; logic signed [31:0] ot_o_qb,ot_o_qe,ot_o_rid,ot_o_sc,ot_o_cov;

    matesw_orch_top #(.MA_MAX(MA_MAX)) u_ot (
        .clk(clk), .rst_n(rst_n),
        // ms/ref pass straight through from the wrapper ports
        .ld_ms_en(ld_ms_en), .ld_ms_addr(ld_ms_addr), .ld_ms_data(ld_ms_data),
        .ld_ref_en(ld_ref_en), .ld_ref_win(ld_ref_win), .ld_ref_addr(ld_ref_addr), .ld_ref_data(ld_ref_data),
        // ma driven by the wrapper
        .ld_ma_en(ot_ldma_en), .ld_ma_idx(ot_ldma_idx),
        .ld_ma_rb(ot_ldma_rb), .ld_ma_re(ot_ldma_re), .ld_ma_qb(ot_ldma_qb), .ld_ma_qe(ot_ldma_qe),
        .ld_ma_rid(ot_ldma_rid), .ld_ma_score(ot_ldma_sc), .ld_ma_cov(ot_ldma_cov),
        .start(ot_start), .l_ms(lms_r), .min_seed_len(msl_r), .a(a_r),
        .o_del(od_r), .e_del(ed_r), .o_ins(oi_r), .e_ins(ei_r),
        .a_rb(arb_r), .l_pac(lpac_r), .a_rid(arid_r), .a_is_alt(aalt_r),
        .n_ma_in(n_r), .win_used(wu_r), .win_rb(wrb_r), .win_re(wre_r), .win_rid(wrid_r),
        .pes_low(plo_r), .pes_high(phi_r), .pes_failed(pf_r),
        .busy(ot_busy), .done(ot_done), .overflow(ot_ovf), .tie(ot_tie), .n_out(ot_nout),
        .rd_idx(ot_rd_idx), .o_rb(ot_o_rb), .o_re(ot_o_re), .o_qb(ot_o_qb), .o_qe(ot_o_qe),
        .o_rid(ot_o_rid), .o_score(ot_o_sc), .o_cov(ot_o_cov)
    );
    // ma stream into orch_top: en/idx/data all combinational on k (avoid the
    // registered-idx vs combinational-data skew bug).
    assign ot_ldma_en  = (state == P_LDMA);
    assign ot_ldma_idx = k[15:0];
    assign ot_ldma_rb=w_rb[k]; assign ot_ldma_re=w_re[k]; assign ot_ldma_qb=w_qb[k];
    assign ot_ldma_qe=w_qe[k]; assign ot_ldma_rid=w_rid[k]; assign ot_ldma_sc=w_sc[k]; assign ot_ldma_cov=w_cov[k];
    assign ot_rd_idx = k[15:0];

    assign busy = (state != P_IDLE);

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state<=P_IDLE; cand_done<=1'b0; ot_start<=1'b0; n_r<='0; tie<=1'b0;
        end else begin
            cand_done<=1'b0; ot_start<=1'b0;

            // ma writes: host init-load OR readback from orch_top (P_RD1)
            if (ld_ma_en && ld_ma_idx < MA_MAX[15:0]) begin
                w_rb[ld_ma_idx]<=ld_ma_rb; w_re[ld_ma_idx]<=ld_ma_re; w_qb[ld_ma_idx]<=ld_ma_qb;
                w_qe[ld_ma_idx]<=ld_ma_qe; w_rid[ld_ma_idx]<=ld_ma_rid; w_sc[ld_ma_idx]<=ld_ma_score;
                w_cov[ld_ma_idx]<=ld_ma_cov;
            end
            if (init) begin n_r <= n_ma_init; tie <= 1'b0; end   // new direction: reset tie

            case (state)
                P_IDLE: if (cand_start) begin
                    lms_r<=l_ms; msl_r<=min_seed_len; a_r<=a;
                    od_r<=o_del; ed_r<=e_del; oi_r<=o_ins; ei_r<=e_ins;
                    arb_r<=a_rb; lpac_r<=l_pac; arid_r<=a_rid; aalt_r<=a_is_alt;
                    wu_r<=win_used; pf_r<=pes_failed;
                    for (int r=0;r<4;r++) begin
                        wrb_r[r]<=win_rb[r]; wre_r[r]<=win_re[r]; wrid_r[r]<=win_rid[r];
                        plo_r[r]<=pes_low[r]; phi_r[r]<=pes_high[r];
                    end
                    k<=0; state<=P_LDMA;
                end
                P_LDMA: begin                       // stream w_* -> orch_top.ld_ma
                    if (k+1 >= n_r || n_r==0) state<=P_RUN;
                    else k<=k+1;
                end
                P_RUN: begin ot_start<=1'b1; state<=P_WAIT; end
                P_WAIT: if (ot_done) begin
                    n_r <= ot_nout; k<=0; tie <= tie | ot_tie;
                    if (ot_nout==0) state<=P_DONE; else state<=P_RD0;
                end
                P_RD0: state<=P_RD1;                // ot_rd_idx=k registered into orch_top read
                P_RD1: begin
                    w_rb[k]<=ot_o_rb; w_re[k]<=ot_o_re; w_qb[k]<=ot_o_qb; w_qe[k]<=ot_o_qe;
                    w_rid[k]<=ot_o_rid; w_sc[k]<=ot_o_sc; w_cov[k]<=ot_o_cov;
                    if (k+1 >= n_r) state<=P_DONE;
                    else begin k<=k+1; state<=P_RD0; end
                end
                P_DONE: begin cand_done<=1'b1; state<=P_IDLE; end
                default: state<=P_IDLE;
            endcase
        end
    end
endmodule
