// matesw_top.sv
// Mate-rescue Smith-Waterman engine = ksw_align2 (two-pass full local SW) built on
// the reused BSW systolic core in restart mode. Given the unmapped mate (query) and
// a reference window (target) pre-loaded into local memories, it returns the
// kswr-style result {score, te, qe, tb, qb} that mem_matesw consumes.
//
//   pass 1 (forward) : bsw_top(restart=1, h0=0) over query[0..qlen-1] x
//                      target[0..tlen-1] -> score, te = tle-1, qe = qle-1.
//   XSUBO early-out  : if score < subo, return with tb=qb=-1 (no start pass).
//   pass 2 (reverse) : run the same core over the REVERSED prefixes
//                      query[qe..0] x target[te..0] -> rte, rqe; then
//                      tb = te - rte, qb = qe - rqe (if scores match).
//
// XSTOP is not needed: the tracker's rmax updates only on a strictly-greater row
// max, so a full reverse pass freezes te/qe at the FIRST row reaching the score —
// identical to ksw's early stop. Verified bit-exact vs host/mate_rescue/hw.h
// (== upstream ksw_align2) by tb_matesw_top.

`include "bsw_pkg.sv"

module matesw_top
    import bsw_pkg::*;
(
    input  logic               clk,
    input  logic               rst_n,

    // ---- load query + reference window (before start) ----
    input  logic               ld_en,
    input  logic               ld_sel,        // 0 = query, 1 = target (ref window)
    input  logic [15:0]        ld_addr,
    input  base_t              ld_data,

    // ---- request ----
    input  logic               start,
    input  logic signed [31:0] qlen,
    input  logic signed [31:0] tlen,
    input  logic signed [31:0] o_del, e_del, o_ins, e_ins,
    input  logic signed [31:0] subo,           // XSUBO threshold (min_seed_len*a)
    input  logic               xstart,         // KSW_XSTART present
    input  logic               xsubo,          // KSW_XSUBO present

    // ---- result (kswr fields consumed by mem_matesw) ----
    output logic               busy,
    output logic               done,
    output logic signed [31:0] o_score,
    output logic signed [31:0] o_te,
    output logic signed [31:0] o_qe,
    output logic signed [31:0] o_tb,
    output logic signed [31:0] o_qb
);
    // ---- local memories (host-loaded) ----
    base_t query_mem [MAX_QLEN];
    base_t ref_mem   [MAX_TLEN];
    always_ff @(posedge clk) if (ld_en) begin
        if (ld_sel) ref_mem[ld_addr]   <= ld_data;
        else        query_mem[ld_addr] <= ld_data;
    end

    // ---- reversed-prefix buffers (pass 2) ----
    base_t [MAX_QLEN-1:0] rq_buf;
    base_t [MAX_TLEN-1:0] rt_buf;
    // forward buffers (packed views of the memories)
    base_t [MAX_QLEN-1:0] fq_buf;
    base_t [MAX_TLEN-1:0] ft_buf;
    integer kk;
    always_comb begin
        for (kk = 0; kk < MAX_QLEN; kk++) fq_buf[kk] = query_mem[kk];
        for (kk = 0; kk < MAX_TLEN; kk++) ft_buf[kk] = ref_mem[kk];
    end

    // ---- latched request ----
    logic signed [31:0] qlen_r, tlen_r, od_r, ed_r, oi_r, ei_r, subo_r;
    logic               xstart_r, xsubo_r;
    logic signed [31:0] te_r, qe_r, score_r;     // forward results

    // ---- bsw_top (restart mode = local SW) ----
    logic                 bsw_req, bsw_rdy, bsw_vld, phase_rev;
    bsw_config_t          bsw_cfg;
    bsw_result_t          bsw_res;
    base_t [MAX_QLEN-1:0] bsw_q;
    base_t [MAX_TLEN-1:0] bsw_t;

    assign bsw_q = phase_rev ? rq_buf : fq_buf;
    assign bsw_t = phase_rev ? rt_buf : ft_buf;
    always_comb begin
        bsw_cfg            = '0;
        bsw_cfg.h0         = '0;                 // local SW: no seed carry-in
        bsw_cfg.o_del      = score_t'(od_r);
        bsw_cfg.e_del      = score_t'(ed_r);
        bsw_cfg.o_ins      = score_t'(oi_r);
        bsw_cfg.e_ins      = score_t'(ei_r);
        bsw_cfg.zdrop      = '0;                 // no z-drop in local SW
        bsw_cfg.end_bonus  = '0;
        bsw_cfg.w          = len_t'(MAX_QLEN);
        bsw_cfg.qlen       = phase_rev ? len_t'(qe_r + 1) : len_t'(qlen_r);
        bsw_cfg.tlen       = phase_rev ? len_t'(te_r + 1) : len_t'(tlen_r);
    end

    bsw_top u_bsw (
        .clk(clk), .rst_n(rst_n), .restart_mode(1'b1),
        .req_valid_i(bsw_req), .req_ready_o(bsw_rdy),
        .query_i(bsw_q), .target_i(bsw_t), .cfg_i(bsw_cfg),
        .result_valid_o(bsw_vld), .result_ready_i(1'b1), .result_o(bsw_res)
    );

    // bsw result -> te/qe (ksw: te = tle-1, qe = qle-1; -1 when no alignment)
    wire signed [31:0] s_score = $signed(bsw_res.score);
    wire signed [31:0] s_te    = $signed({16'b0, bsw_res.tle}) - 32'sd1;
    wire signed [31:0] s_qe    = $signed({16'b0, bsw_res.qle}) - 32'sd1;

    // ---- pack reverse prefixes ----
    logic [15:0] pk;          // pack cursor
    logic [15:0] pk_max;

    typedef enum logic [3:0] {
        M_IDLE, M_FWD, M_FWDW, M_SUBO, M_PACK, M_REV, M_REVW, M_COMB, M_DONE
    } st_t;
    st_t state;
    assign busy = (state != M_IDLE);

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state <= M_IDLE; done <= 1'b0; bsw_req <= 1'b0; phase_rev <= 1'b0;
        end else begin
            done <= 1'b0; bsw_req <= 1'b0;
            case (state)
                M_IDLE: if (start) begin
                    qlen_r<=qlen; tlen_r<=tlen; od_r<=o_del; ed_r<=e_del; oi_r<=o_ins; ei_r<=e_ins;
                    subo_r<=subo; xstart_r<=xstart; xsubo_r<=xsubo;
                    phase_rev <= 1'b0;
                    state <= M_FWD;
                end
                M_FWD: begin phase_rev <= 1'b0; bsw_req <= 1'b1; state <= M_FWDW; end
                M_FWDW: if (bsw_vld) begin
                    score_r <= s_score; te_r <= s_te;
                    // ksw_u8 reports qe=0 when no positive alignment exists (the
                    // qe scan over the all-zero Hmax column returns index 0); the
                    // tracker leaves rmax_j=-1, so override qe to 0 when score==0.
                    qe_r <= (s_score == 32'sd0) ? 32'sd0 : s_qe;
                    state <= M_SUBO;
                end
                M_SUBO: begin
                    // no start pass if not requested, or score below subo, or no
                    // forward alignment (te/qe < 0). Matches mem_matesw's needs.
                    if (!xstart_r || (xsubo_r && score_r < subo_r) || te_r < 0 || qe_r < 0) begin
                        o_tb <= -32'sd1; o_qb <= -32'sd1;
                        state <= M_DONE;
                    end else begin
                        pk <= 16'd0;
                        pk_max <= (qe_r > te_r) ? qe_r[15:0] : te_r[15:0];
                        state <= M_PACK;
                    end
                end
                M_PACK: begin
                    if (pk <= qe_r[15:0]) rq_buf[pk] <= query_mem[qe_r[15:0] - pk];
                    if (pk <= te_r[15:0]) rt_buf[pk] <= ref_mem[te_r[15:0] - pk];
                    if (pk == pk_max) state <= M_REV;
                    else pk <= pk + 16'd1;
                end
                M_REV: begin phase_rev <= 1'b1; bsw_req <= 1'b1; state <= M_REVW; end
                M_REVW: if (bsw_vld) begin
                    // rscore = s_score, rte = s_te, rqe = s_qe (reverse pass)
                    if (s_score == score_r) begin
                        o_tb <= te_r - s_te;
                        o_qb <= qe_r - s_qe;
                    end else begin
                        o_tb <= -32'sd1; o_qb <= -32'sd1;
                    end
                    state <= M_COMB;
                end
                M_COMB: state <= M_DONE;
                M_DONE: begin
                    o_score <= score_r; o_te <= te_r; o_qe <= qe_r;
                    done <= 1'b1; state <= M_IDLE;
                end
                default: state <= M_IDLE;
            endcase
        end
    end
endmodule
