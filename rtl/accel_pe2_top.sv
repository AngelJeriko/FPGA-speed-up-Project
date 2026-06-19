// accel_pe2_top.sv
// FULLY on-chip (Stage-1) single-direction paired-end mate-rescue: BOTH the candidate
// source and the rescue ma list come from accel runs, with the candidate SELECTION on
// chip. Extends accel_pe_top (which folded only the ma list) by adding a second accel
// run for the candidates and the matesw_pe_sel_top selection layer.
//
//   Run 1 (run_is_cand=1): host drives accel_top for read i  -> score-sorted a[i] beats
//     -> [capture FSM] streamed into matesw_pe_sel_top's candidate SOURCE buffer.
//   Run 2 (run_is_cand=0): host drives accel_top for read !i -> a[!i] beats
//     -> [capture FSM] streamed into the rescue ma regfile (ld_ma -> matesw_pe_top).
//   Then: host loads the mate seq (read !i) + drives each candidate's windows on cand_req,
//     pulses sel_start -> the selector picks the good prefix (score >= top - pen_unpaired,
//     capped at max_matesw) and threads each rescue into ma. Final a[!i] read via rd_idx.
//
// The full pair = two invocations (swap which read is cand vs ma). One accel_top instance
// is reused for both runs (sequential). The accel output is already score-sorted DESC by
// the merge-sorter, so the source ordering the prefix gate needs is free.
//
// rec_t carries {rb,re,qb,qe,rid,score} only; seedcov/is_alt are NOT produced by the
// sorter and enter as 0 (the pre-existing accel/merge-sorter Stage-1 simplification —
// mr_dedup keys on rb/re/qb/qe/score, the rest merely ride along). Either run raising
// accel `fallback` (equal-re tie / n>1024) propagates out -> host redoes that read in SW.

`include "bsw_pkg.sv"
`include "msort_v2_pkg.sv"

module accel_pe2_top
    import bsw_pkg::*;
    import msort_v2_pkg::*;
#(
    parameter int MA_MAX = 64,
    parameter int NSRC   = 64
)(
    input  logic               clk,
    input  logic               rst_n,

    // ======== accel_top (host-driven; reused for BOTH runs) ========
    input  logic               run_is_cand,   // latched at read_start: 1=source run, 0=ma run
    input  logic               read_start,
    input  logic signed [31:0] l_query, a, o_del, e_del, o_ins, e_ins, zdrop, wcfg, pen5, pen3,
    input  logic               q_ld_en,  input logic [15:0] q_ld_addr, input base_t q_ld_data,
    input  logic               r_ld_en,  input logic [15:0] r_ld_addr, input base_t r_ld_data,
    input  logic               s_ld_en,  input logic [7:0]  s_ld_idx,
    input  logic signed [63:0] s_ld_rbeg, input logic signed [31:0] s_ld_qbeg, s_ld_len, s_ld_score,
    input  logic               ch_go,    input logic [7:0]  ch_n,
    input  logic signed [31:0] ch_rid,   input logic signed [63:0] ch_rmax0, ch_rmax1,
    output logic               ch_ready,
    input  logic               read_finish,
    output logic               accel_busy,
    output logic               accel_done,        // pulse at end of each run's capture
    output logic               accel_fallback,    // this run needs SW redo (sampled at accel_done)
    output logic [15:0]        n_src_o,           // captured candidate-source count (after run 1)
    output logic [15:0]        n_ma_init_o,       // captured entry-ma count (after run 2)

    // ======== rescue (host-driven: mate seq, ref windows, selection params) ========
    input  logic               ld_ms_en,  input logic [15:0] ld_ms_addr, input base_t ld_ms_data,
    input  logic               ld_ref_en, input logic [1:0]  ld_ref_win, input logic [15:0] ld_ref_addr, input base_t ld_ref_data,
    input  logic               sel_start,
    input  logic signed [31:0] l_ms, min_seed_len, a_sc, mo_del, me_del, mo_ins, me_ins,
    input  logic signed [63:0] l_pac,
    input  logic signed [31:0] pen_unpaired, max_matesw,
    input  logic [3:0]         win_used,
    input  logic signed [63:0] win_rb  [4],
    input  logic signed [63:0] win_re  [4],
    input  logic signed [31:0] win_rid [4],
    input  logic signed [63:0] pes_low [4],
    input  logic signed [63:0] pes_high[4],
    input  logic [3:0]         pes_failed,
    output logic               cand_req,
    output logic [15:0]        cur_cand,
    input  logic               cand_wins_ready,

    // ======== debug: candidate-source readback (verification only) ========
    input  logic [15:0]        src_rd_idx,
    output logic signed [63:0] src_o_rb,
    output logic signed [31:0] src_o_rid,
    output logic signed [31:0] src_o_alt,
    output logic signed [31:0] src_o_sc,

    // ======== rescue status / result ========
    output logic               rescue_busy,
    output logic               sel_done,
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
    // ---- accel_top (reused for both runs) ----
    logic        ac_tvalid, ac_tlast, ac_done, ac_fb, ac_busy;
    rec_t        ac_tdata;

    accel_top u_ac (
        .clk(clk), .rst_n(rst_n),
        .read_start(read_start), .l_query(l_query), .a(a), .o_del(o_del), .e_del(e_del),
        .o_ins(o_ins), .e_ins(e_ins), .zdrop(zdrop), .wcfg(wcfg), .pen5(pen5), .pen3(pen3),
        .q_ld_en(q_ld_en), .q_ld_addr(q_ld_addr), .q_ld_data(q_ld_data),
        .r_ld_en(r_ld_en), .r_ld_addr(r_ld_addr), .r_ld_data(r_ld_data),
        .s_ld_en(s_ld_en), .s_ld_idx(s_ld_idx), .s_ld_rbeg(s_ld_rbeg),
        .s_ld_qbeg(s_ld_qbeg), .s_ld_len(s_ld_len), .s_ld_score(s_ld_score),
        .ch_go(ch_go), .ch_n(ch_n), .ch_rid(ch_rid), .ch_rmax0(ch_rmax0), .ch_rmax1(ch_rmax1),
        .ch_ready(ch_ready), .read_finish(read_finish),
        .m_axis_tvalid(ac_tvalid), .m_axis_tdata(ac_tdata), .m_axis_tlast(ac_tlast),
        .m_axis_tready(1'b1),                       // always accept; captured immediately
        .fallback(ac_fb), .busy(ac_busy), .done(ac_done)
    );
    assign accel_busy = ac_busy;

    // ---- capture FSM: route accel beats by the run latched at read_start ----
    logic [15:0] cap_cnt;
    logic        run_cand_r;       // 1 = current run feeds the source; 0 = feeds ma
    logic        ac_done_q;
    logic [15:0] n_src_r, n_ma_r;
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            cap_cnt <= 16'd0; run_cand_r <= 1'b0; ac_done_q <= 1'b0;
            accel_done <= 1'b0; accel_fallback <= 1'b0; n_src_r <= 16'd0; n_ma_r <= 16'd0;
        end else begin
            accel_done <= 1'b0;
            if (read_start) begin cap_cnt <= 16'd0; run_cand_r <= run_is_cand; end
            if (ac_tvalid)  cap_cnt <= cap_cnt + 16'd1;
            ac_done_q <= ac_done;
            if (ac_done && !ac_done_q) begin           // this run's output is fully captured
                accel_done     <= 1'b1;
                accel_fallback <= ac_fb;               // per-run; host samples at accel_done
                if (run_cand_r) n_src_r <= cap_cnt; else n_ma_r <= cap_cnt;
            end
        end
    end
    assign n_src_o     = n_src_r;
    assign n_ma_init_o = n_ma_r;

    // run 1 beats -> candidate source ; run 2 beats -> rescue ma regfile
    logic               s_src_en;  logic [15:0] s_src_idx;
    logic signed [63:0] s_src_rb;  logic signed [31:0] s_src_rid, s_src_alt, s_src_sc;
    assign s_src_en  = ac_tvalid && run_cand_r;
    assign s_src_idx = cap_cnt;
    assign s_src_rb  = ac_tdata.rb;
    assign s_src_rid = ac_tdata.rid;
    assign s_src_alt = 32'sd0;                          // is_alt not carried by the sorter
    assign s_src_sc  = ac_tdata.score;

    logic               s_ma_en;   logic [15:0] s_ma_idx;
    logic signed [63:0] s_ma_rb, s_ma_re; logic signed [31:0] s_ma_qb,s_ma_qe,s_ma_rid,s_ma_sc;
    assign s_ma_en  = ac_tvalid && !run_cand_r;
    assign s_ma_idx = cap_cnt;
    assign s_ma_rb  = ac_tdata.rb;
    assign s_ma_re  = ac_tdata.re;
    assign s_ma_qb  = ac_tdata.qb;
    assign s_ma_qe  = ac_tdata.qe;
    assign s_ma_rid = ac_tdata.rid;
    assign s_ma_sc  = ac_tdata.score;

    // ---- matesw_pe_sel_top ----
    matesw_pe_sel_top #(.MA_MAX(MA_MAX), .NSRC(NSRC)) u_sel (
        .clk(clk), .rst_n(rst_n),
        // candidate source <- run 1 capture
        .src_ld_en(s_src_en), .src_ld_idx(s_src_idx),
        .src_ld_rb(s_src_rb), .src_ld_rid(s_src_rid), .src_ld_alt(s_src_alt), .src_ld_score(s_src_sc),
        .n_src(n_src_r), .pen_unpaired(pen_unpaired), .max_matesw(max_matesw),
        // mate seq + ref windows: host-driven passthrough
        .ld_ms_en(ld_ms_en), .ld_ms_addr(ld_ms_addr), .ld_ms_data(ld_ms_data),
        .ld_ref_en(ld_ref_en), .ld_ref_win(ld_ref_win), .ld_ref_addr(ld_ref_addr), .ld_ref_data(ld_ref_data),
        // entry ma <- run 2 capture
        .ld_ma_en(s_ma_en), .ld_ma_idx(s_ma_idx),
        .ld_ma_rb(s_ma_rb), .ld_ma_re(s_ma_re), .ld_ma_qb(s_ma_qb), .ld_ma_qe(s_ma_qe),
        .ld_ma_rid(s_ma_rid), .ld_ma_score(s_ma_sc), .ld_ma_cov(32'sd0),
        .n_ma_init(n_ma_r),
        .sel_start(sel_start), .l_ms(l_ms), .min_seed_len(min_seed_len), .a(a_sc),
        .o_del(mo_del), .e_del(me_del), .o_ins(mo_ins), .e_ins(me_ins), .l_pac(l_pac),
        .win_used(win_used), .win_rb(win_rb), .win_re(win_re), .win_rid(win_rid),
        .pes_low(pes_low), .pes_high(pes_high), .pes_failed(pes_failed),
        .cand_req(cand_req), .cur_cand(cur_cand), .cand_wins_ready(cand_wins_ready),
        .src_rd_idx(src_rd_idx), .src_o_rb(src_o_rb), .src_o_rid(src_o_rid),
        .src_o_alt(src_o_alt), .src_o_sc(src_o_sc),
        .busy(rescue_busy), .done(sel_done), .n_ma(n_ma),
        .rd_idx(rd_idx), .o_rb(o_rb), .o_re(o_re), .o_qb(o_qb), .o_qe(o_qe),
        .o_rid(o_rid), .o_score(o_score), .o_cov(o_cov)
    );
endmodule
