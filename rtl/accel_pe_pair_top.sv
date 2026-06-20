// accel_pe_pair_top.sv
// Both-directions paired-end mate-rescue SEQUENCER. A full pair rescues BOTH mates
// (mem_sam_pe runs the candidate loop for i=0 and i=1):
//   Direction 0: candidates = a[0], rescue mate read 1 -> a[1]'   (cand-run=read0, ma-run=read1)
//   Direction 1: candidates = a[1], rescue mate read 0 -> a[0]'   (cand-run=read1, ma-run=read0)
// bwa semantics: BOTH candidate sources are the ORIGINAL a[0]/a[1] (b[i] is snapshotted
// before any rescue). Re-running accel per direction re-derives the original source
// deterministically, so direction 1's source is the original a[1] — NOT a[1]'.
//
// This wraps ONE accel_pe2_top (each direction = its own two accel runs + rescue, driven
// by the host) and adds a RESULT-A snapshot buffer: after direction 0's rescue the host
// pulses snap_a_start and the sequencer copies a[1]' into an internal buffer (via the inner
// rd_idx/o_* readback). Direction 1 then reuses the inner regfile to produce a[0]'. At the
// end BOTH results coexist: res_from_a=1 reads a[1]' (buffer), res_from_a=0 reads a[0]'
// (inner live). All accel data / windows / control are relayed from the host unchanged.

`include "bsw_pkg.sv"
`include "msort_v2_pkg.sv"

module accel_pe_pair_top
    import bsw_pkg::*;
    import msort_v2_pkg::*;
#(
    parameter int MA_MAX = 64,
    parameter int NSRC   = 64
)(
    input  logic               clk,
    input  logic               rst_n,

    // ======== accel_top (host-driven; relayed) ========
    input  logic               run_is_cand,
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
    output logic               accel_done,
    output logic               accel_fallback,
    output logic [15:0]        n_src_o,
    output logic [15:0]        n_ma_init_o,

    // ======== rescue (host-driven; relayed) ========
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
    output logic               rescue_busy,
    output logic               sel_done,
    output logic               tie,        // current direction's rescue dedup tie -> SW fallback

    // ======== result-A snapshot (direction 0 = a[1]') ========
    input  logic               snap_a_start,    // pulse after dir-0 rescue: latch a[1]' to buffer
    output logic               snap_busy,
    output logic               snap_done,

    // ======== result readback: res_from_a=1 -> a[1]' (buffer), 0 -> a[0]' (inner live) ========
    input  logic               res_from_a,
    input  logic [15:0]        rd_idx,
    output logic [15:0]        n_ma,
    output logic signed [63:0] o_rb,
    output logic signed [63:0] o_re,
    output logic signed [31:0] o_qb,
    output logic signed [31:0] o_qe,
    output logic signed [31:0] o_rid,
    output logic signed [31:0] o_score,
    output logic signed [31:0] o_cov
);
    // ---- inner accel_pe2_top result + readback intercept ----
    logic [15:0]        in_n_ma;
    logic signed [63:0] in_o_rb, in_o_re; logic signed [31:0] in_o_qb,in_o_qe,in_o_rid,in_o_score,in_o_cov;
    logic [15:0]        in_rd_idx;

    // ---- snapshot FSM + buffer A ----
    logic signed [63:0] a_rb [MA_MAX], a_re [MA_MAX];
    logic signed [31:0] a_qb [MA_MAX], a_qe [MA_MAX], a_rid[MA_MAX], a_sc_[MA_MAX], a_cov[MA_MAX];
    logic [15:0]        n_a, snap_k, snap_n;
    typedef enum logic [1:0] { K_IDLE, K_RD, K_LAT, K_DONE } kst_t;
    kst_t kstate;
    assign snap_busy = (kstate != K_IDLE);

    // inner rd_idx: driven by the snapshot scan while active, else the host's rd_idx
    assign in_rd_idx = (kstate == K_RD || kstate == K_LAT) ? snap_k : rd_idx;

    always_ff @(posedge clk) begin
        if (!rst_n) begin kstate <= K_IDLE; snap_done <= 1'b0; n_a <= 16'd0; snap_k <= 16'd0; snap_n <= 16'd0; end
        else begin
            snap_done <= 1'b0;
            case (kstate)
                K_IDLE: if (snap_a_start) begin
                    snap_n <= in_n_ma; snap_k <= 16'd0;
                    kstate <= (in_n_ma == 16'd0) ? K_DONE : K_RD;
                end
                K_RD:  kstate <= K_LAT;               // in_rd_idx=snap_k settles (o_* combinational)
                K_LAT: begin
                    a_rb[snap_k]<=in_o_rb; a_re[snap_k]<=in_o_re; a_qb[snap_k]<=in_o_qb; a_qe[snap_k]<=in_o_qe;
                    a_rid[snap_k]<=in_o_rid; a_sc_[snap_k]<=in_o_score; a_cov[snap_k]<=in_o_cov;
                    if (snap_k + 16'd1 >= snap_n) begin n_a <= snap_n; kstate <= K_DONE; end
                    else begin snap_k <= snap_k + 16'd1; kstate <= K_RD; end
                end
                K_DONE: begin snap_done <= 1'b1; if (snap_n==16'd0) n_a <= 16'd0; kstate <= K_IDLE; end
                default: kstate <= K_IDLE;
            endcase
        end
    end

    // result mux
    assign n_ma     = res_from_a ? n_a          : in_n_ma;
    assign o_rb     = res_from_a ? a_rb [rd_idx] : in_o_rb;
    assign o_re     = res_from_a ? a_re [rd_idx] : in_o_re;
    assign o_qb     = res_from_a ? a_qb [rd_idx] : in_o_qb;
    assign o_qe     = res_from_a ? a_qe [rd_idx] : in_o_qe;
    assign o_rid    = res_from_a ? a_rid[rd_idx] : in_o_rid;
    assign o_score  = res_from_a ? a_sc_[rd_idx] : in_o_score;
    assign o_cov    = res_from_a ? a_cov[rd_idx] : in_o_cov;

    // ---- inner fold (one direction at a time) ----
    logic [15:0] unused_cur_cand; logic signed [63:0] unused_src_rb; logic signed [31:0] unused_src_rid, unused_src_alt, unused_src_sc;
    accel_pe2_top #(.MA_MAX(MA_MAX), .NSRC(NSRC)) u_pe2 (
        .clk(clk), .rst_n(rst_n),
        .run_is_cand(run_is_cand), .read_start(read_start),
        .l_query(l_query), .a(a), .o_del(o_del), .e_del(e_del), .o_ins(o_ins), .e_ins(e_ins),
        .zdrop(zdrop), .wcfg(wcfg), .pen5(pen5), .pen3(pen3),
        .q_ld_en(q_ld_en), .q_ld_addr(q_ld_addr), .q_ld_data(q_ld_data),
        .r_ld_en(r_ld_en), .r_ld_addr(r_ld_addr), .r_ld_data(r_ld_data),
        .s_ld_en(s_ld_en), .s_ld_idx(s_ld_idx), .s_ld_rbeg(s_ld_rbeg),
        .s_ld_qbeg(s_ld_qbeg), .s_ld_len(s_ld_len), .s_ld_score(s_ld_score),
        .ch_go(ch_go), .ch_n(ch_n), .ch_rid(ch_rid), .ch_rmax0(ch_rmax0), .ch_rmax1(ch_rmax1),
        .ch_ready(ch_ready), .read_finish(read_finish),
        .accel_busy(accel_busy), .accel_done(accel_done), .accel_fallback(accel_fallback),
        .n_src_o(n_src_o), .n_ma_init_o(n_ma_init_o),
        .ld_ms_en(ld_ms_en), .ld_ms_addr(ld_ms_addr), .ld_ms_data(ld_ms_data),
        .ld_ref_en(ld_ref_en), .ld_ref_win(ld_ref_win), .ld_ref_addr(ld_ref_addr), .ld_ref_data(ld_ref_data),
        .sel_start(sel_start), .l_ms(l_ms), .min_seed_len(min_seed_len), .a_sc(a_sc),
        .mo_del(mo_del), .me_del(me_del), .mo_ins(mo_ins), .me_ins(me_ins), .l_pac(l_pac),
        .pen_unpaired(pen_unpaired), .max_matesw(max_matesw),
        .win_used(win_used), .win_rb(win_rb), .win_re(win_re), .win_rid(win_rid),
        .pes_low(pes_low), .pes_high(pes_high), .pes_failed(pes_failed),
        .cand_req(cand_req), .cur_cand(cur_cand), .cand_wins_ready(cand_wins_ready),
        .src_rd_idx(16'd0), .src_o_rb(unused_src_rb), .src_o_rid(unused_src_rid),
        .src_o_alt(unused_src_alt), .src_o_sc(unused_src_sc),
        .rescue_busy(rescue_busy), .sel_done(sel_done), .tie(tie), .n_ma(in_n_ma),
        .rd_idx(in_rd_idx), .o_rb(in_o_rb), .o_re(in_o_re), .o_qb(in_o_qb), .o_qe(in_o_qe),
        .o_rid(in_o_rid), .o_score(in_o_score), .o_cov(in_o_cov)
    );
endmodule
