// accel_pe_top.sv
// Folds mate-rescue into the back-half accelerator: the alnreg list a[!i] produced
// by accel_top (extension -> sort/dedup) is consumed ON-CHIP as the mate-rescue ma
// list, with no host round-trip in between. One direction of the paired-end rescue:
//
//   host drives accel_top for the mate read (read !i) -> sorted alnreg AXI stream
//     -> [capture FSM] streamed straight into matesw_pe_top's ma register file
//     -> host drives the rescue candidates b[i] (a_rb/rid + host-fed windows) and
//        the mate sequence -> matesw_pe_top threads the rescues into ma
//     -> final a[!i] read back via rd_idx.
//
// The full pair = two runs (swap which read feeds accel vs supplies candidates).
//
// rec_t carries {rb,re,qb,qe,rid,score} only; seedcov/is_alt are NOT produced by the
// sorter and enter the rescue as 0. This is structurally exact for mate-rescue
// (mr_dedup keys on rb/re/qb/qe/score only; seedcov/is_alt merely ride along) — the
// seedcov/is_alt VALUE loss is the pre-existing accel_top/merge-sorter Stage-1
// simplification, not introduced here.

`include "bsw_pkg.sv"
`include "msort_v2_pkg.sv"

module accel_pe_top
    import bsw_pkg::*;
    import msort_v2_pkg::*;
#(
    parameter int MA_MAX = 64
)(
    input  logic               clk,
    input  logic               rst_n,

    // ======== accel_top (mate read back-half) — host-driven, passed through ========
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
    output logic               accel_fallback,   // mate read needs SW redo (no rescue on-chip)
    output logic               accel_busy,
    output logic               ma_ready,          // pulse: a[!i] captured into the rescue ma

    // ======== matesw rescue (host-driven candidates + windows) ========
    input  logic               ld_ms_en,  input logic [15:0] ld_ms_addr, input base_t ld_ms_data,
    input  logic               ld_ref_en, input logic [1:0]  ld_ref_win, input logic [15:0] ld_ref_addr, input base_t ld_ref_data,
    input  logic               cand_start,
    input  logic signed [31:0] l_ms, min_seed_len, a_sc, mo_del, me_del, mo_ins, me_ins,
    input  logic signed [63:0] a_rb, l_pac,
    input  logic signed [31:0] a_rid, a_is_alt,
    input  logic [3:0]         win_used,
    input  logic signed [63:0] win_rb  [4],
    input  logic signed [63:0] win_re  [4],
    input  logic signed [31:0] win_rid [4],
    input  logic signed [63:0] pes_low [4],
    input  logic signed [63:0] pes_high[4],
    input  logic [3:0]         pes_failed,

    // ======== rescue status / result ========
    output logic               rescue_busy,
    output logic               cand_done,
    output logic               tie,        // rescue dedup tie -> SW fallback
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
    // ---- accel_top ----
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
    assign accel_fallback = ac_fb;
    assign accel_busy     = ac_busy;

    // ---- capture: accel output beats -> matesw_pe_top ma register file ----
    logic [15:0] cap_cnt;           // number of alnregs captured (a[!i] length)
    logic        pe_init;           // pulse pe_top init after capture
    logic        ac_done_q;
    always_ff @(posedge clk) begin
        if (!rst_n) begin cap_cnt <= 16'd0; pe_init <= 1'b0; ac_done_q <= 1'b0; ma_ready <= 1'b0; end
        else begin
            pe_init <= 1'b0; ma_ready <= 1'b0;
            if (read_start) cap_cnt <= 16'd0;        // new mate read: reset capture
            if (ac_tvalid)  cap_cnt <= cap_cnt + 16'd1;
            ac_done_q <= ac_done;
            if (ac_done && !ac_done_q) begin pe_init <= 1'b1; ma_ready <= 1'b1; end  // capture complete
        end
    end

    // pe_top ma load driven by the capture (en/idx/data all combinational on the beat)
    logic               pe_ldma_en; logic [15:0] pe_ldma_idx;
    logic signed [63:0] pe_ldma_rb, pe_ldma_re; logic signed [31:0] pe_ldma_qb,pe_ldma_qe,pe_ldma_rid,pe_ldma_sc,pe_ldma_cov;
    assign pe_ldma_en  = ac_tvalid;
    assign pe_ldma_idx = cap_cnt;
    assign pe_ldma_rb  = ac_tdata.rb;
    assign pe_ldma_re  = ac_tdata.re;
    assign pe_ldma_qb  = ac_tdata.qb;
    assign pe_ldma_qe  = ac_tdata.qe;
    assign pe_ldma_rid = ac_tdata.rid;
    assign pe_ldma_sc  = ac_tdata.score;
    assign pe_ldma_cov = 32'sd0;                     // seedcov not carried by the sorter

    // ---- matesw_pe_top ----
    matesw_pe_top #(.MA_MAX(MA_MAX)) u_pe (
        .clk(clk), .rst_n(rst_n),
        .ld_ms_en(ld_ms_en), .ld_ms_addr(ld_ms_addr), .ld_ms_data(ld_ms_data),
        .ld_ref_en(ld_ref_en), .ld_ref_win(ld_ref_win), .ld_ref_addr(ld_ref_addr), .ld_ref_data(ld_ref_data),
        .ld_ma_en(pe_ldma_en), .ld_ma_idx(pe_ldma_idx),
        .ld_ma_rb(pe_ldma_rb), .ld_ma_re(pe_ldma_re), .ld_ma_qb(pe_ldma_qb), .ld_ma_qe(pe_ldma_qe),
        .ld_ma_rid(pe_ldma_rid), .ld_ma_score(pe_ldma_sc), .ld_ma_cov(pe_ldma_cov),
        .init(pe_init), .n_ma_init(cap_cnt),
        .cand_start(cand_start), .l_ms(l_ms), .min_seed_len(min_seed_len), .a(a_sc),
        .o_del(mo_del), .e_del(me_del), .o_ins(mo_ins), .e_ins(me_ins),
        .a_rb(a_rb), .l_pac(l_pac), .a_rid(a_rid), .a_is_alt(a_is_alt),
        .win_used(win_used), .win_rb(win_rb), .win_re(win_re), .win_rid(win_rid),
        .pes_low(pes_low), .pes_high(pes_high), .pes_failed(pes_failed),
        .busy(rescue_busy), .cand_done(cand_done), .tie(tie), .n_ma(n_ma),
        .rd_idx(rd_idx), .o_rb(o_rb), .o_re(o_re), .o_qb(o_qb), .o_qe(o_qe),
        .o_rid(o_rid), .o_score(o_score), .o_cov(o_cov)
    );
endmodule
