// matesw_orient_unit.sv
// Per-orientation mate-rescue unit for the paired-end top. Wires the verified
// matesw_top SW engine to the kswr->alnreg transform that mem_matesw applies for
// ONE rescue orientation. Given the oriented query (the mate seq, already reverse-
// complemented by the caller when is_rev) and the host-fed reference window pre-
// loaded into matesw_top's memories, it runs ksw_align2 and emits the candidate
// alnreg `b` (rb/re/qb/qe/score/seedcov/rid/is_alt) plus `rescue` (= the gate
// aln.score>=min_seed_len && aln.qb>=0).  This is the inner block the orchestration
// FSM (matesw_orch_top, next) invokes per non-skipped orientation.
//
// Transform == mem_matesw_batch_post (bwamem_pair.cpp:1180-1189), modeled in
// host/mate_rescue/orch.h::matesw_orchestrate:
//   b.qb = is_rev ? l_ms-(qe+1) : qb;   b.qe = is_rev ? l_ms-qb : qe+1;
//   b.rb = is_rev ? 2*l_pac-(rb+te+1) : rb+tb;
//   b.re = is_rev ? 2*l_pac-(rb+tb)   : rb+te+1;
//   b.seedcov = min(b.re-b.rb, b.qe-b.qb) >> 1;
// (csub = aln.score2 is NOT produced — not a sort/dedup key; see orch.h.)
//
// is_rev only affects the transform, NOT the SW: the caller loads the oriented
// query, so matesw_top runs the same forward/reverse local SW regardless. xstart
// and xsubo are always set (mem_matesw passes both); subo = min_seed_len*a.

`include "bsw_pkg.sv"

module matesw_orient_unit
    import bsw_pkg::*;
(
    input  logic               clk,
    input  logic               rst_n,

    // ---- memory load (host/TB) -> forwarded to matesw_top ----
    input  logic               ld_en,
    input  logic               ld_sel,        // 0 = query (oriented mate), 1 = ref window
    input  logic [15:0]        ld_addr,
    input  base_t              ld_data,

    // ---- request : one orientation ----
    input  logic               start,         // pulse when !busy
    input  logic signed [31:0] l_ms,           // mate length = SW qlen
    input  logic signed [31:0] tlen,           // window length = re - rb
    input  logic signed [31:0] o_del, e_del, o_ins, e_ins,
    input  logic signed [31:0] a,              // match score
    input  logic signed [31:0] min_seed_len,   // gate threshold; subo = min_seed_len*a
    input  logic               is_rev,         // reverse-complement orientation
    input  logic signed [63:0] rb,             // window start (post-bns_fetch_seq)
    input  logic signed [63:0] l_pac,
    input  logic signed [31:0] a_rid,          // mapped mate rid / is_alt carried onto b
    input  logic signed [31:0] a_is_alt,

    // ---- result ----
    output logic               busy,
    output logic               done_o,         // 1-cycle pulse when result valid
    output logic               rescue,          // 1 = alnreg produced (gate passed)
    output logic signed [63:0] b_rb,
    output logic signed [63:0] b_re,
    output logic signed [31:0] b_qb,
    output logic signed [31:0] b_qe,
    output logic signed [31:0] b_score,
    output logic signed [31:0] b_seedcov,
    output logic signed [31:0] b_rid,
    output logic signed [31:0] b_is_alt
);
    // ---- latched request ----
    logic signed [31:0] lms_r, msl_r, a_r;
    logic signed [31:0] tlen_r, od_r, ed_r, oi_r, ei_r;
    logic               isrev_r;
    logic signed [63:0] rb_r, lpac_r;
    logic signed [31:0] arid_r, aalt_r;

    // ---- matesw_top instance (ld ports pass straight through) ----
    logic               mt_start, mt_busy, mt_done, mt_xstart, mt_xsubo;
    logic signed [31:0] mt_qlen, mt_tlen, mt_od, mt_ed, mt_oi, mt_ei, mt_subo;
    logic signed [31:0] mt_score, mt_te, mt_qe, mt_tb, mt_qb;

    matesw_top u_mt (
        .clk(clk), .rst_n(rst_n),
        .ld_en(ld_en), .ld_sel(ld_sel), .ld_addr(ld_addr), .ld_data(ld_data),
        .start(mt_start), .qlen(mt_qlen), .tlen(mt_tlen),
        .o_del(mt_od), .e_del(mt_ed), .o_ins(mt_oi), .e_ins(mt_ei),
        .subo(mt_subo), .xstart(mt_xstart), .xsubo(mt_xsubo),
        .busy(mt_busy), .done(mt_done),
        .o_score(mt_score), .o_te(mt_te), .o_qe(mt_qe), .o_tb(mt_tb), .o_qb(mt_qb)
    );

    // matesw request is constant during the run (latched values feed it)
    assign mt_qlen   = lms_r;
    assign mt_tlen   = tlen_r;
    assign mt_od     = od_r;
    assign mt_ed     = ed_r;
    assign mt_oi     = oi_r;
    assign mt_ei     = ei_r;
    assign mt_subo   = msl_r * a_r;            // subo = min_seed_len * a
    assign mt_xstart = 1'b1;
    assign mt_xsubo  = 1'b1;

    // ---- kswr -> alnreg transform (combinational, from the captured matesw result) ----
    logic signed [63:0] two_lpac, te64, tb64, t_rb, t_re, span_r, span_q, span_min;
    logic signed [31:0] t_qb, t_qe, t_cov;
    logic               t_rescue;
    always_comb begin
        two_lpac = lpac_r <<< 1;
        te64     = $signed({{32{mt_te[31]}}, mt_te});
        tb64     = $signed({{32{mt_tb[31]}}, mt_tb});
        t_rb     = isrev_r ? (two_lpac - (rb_r + te64 + 64'sd1)) : (rb_r + tb64);
        t_re     = isrev_r ? (two_lpac - (rb_r + tb64))         : (rb_r + te64 + 64'sd1);
        t_qb     = isrev_r ? (lms_r - (mt_qe + 32'sd1)) : mt_qb;
        t_qe     = isrev_r ? (lms_r - mt_qb)            : (mt_qe + 32'sd1);
        span_r   = t_re - t_rb;
        span_q   = {{32{t_qe[31]}}, (t_qe - t_qb)};
        span_min = (span_r < span_q) ? span_r : span_q;
        t_cov    = span_min[32:1];                    // (min span) >> 1
        t_rescue = (mt_score >= msl_r) && (mt_qb >= 32'sd0);
    end

    typedef enum logic [1:0] { U_IDLE, U_RUN, U_WAIT, U_DONE } st_t;
    st_t state;
    assign busy = (state != U_IDLE);

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state <= U_IDLE; done_o <= 1'b0; mt_start <= 1'b0;
        end else begin
            done_o <= 1'b0; mt_start <= 1'b0;
            case (state)
                U_IDLE: if (start) begin
                    lms_r<=l_ms; tlen_r<=tlen; od_r<=o_del; ed_r<=e_del; oi_r<=o_ins; ei_r<=e_ins;
                    a_r<=a; msl_r<=min_seed_len; isrev_r<=is_rev;
                    rb_r<=rb; lpac_r<=l_pac; arid_r<=a_rid; aalt_r<=a_is_alt;
                    state <= U_RUN;
                end
                U_RUN: begin mt_start <= 1'b1; state <= U_WAIT; end
                U_WAIT: if (mt_done) begin
                    rescue    <= t_rescue;
                    b_rb      <= t_rb;     b_re <= t_re;
                    b_qb      <= t_qb;     b_qe <= t_qe;
                    b_score   <= mt_score;
                    b_seedcov <= t_cov;
                    b_rid     <= arid_r;   b_is_alt <= aalt_r;
                    state <= U_DONE;
                end
                U_DONE: begin done_o <= 1'b1; state <= U_IDLE; end
                default: state <= U_IDLE;
            endcase
        end
    end
endmodule
