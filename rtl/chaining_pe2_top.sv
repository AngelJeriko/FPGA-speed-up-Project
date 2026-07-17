// chaining_pe2_top.sv
// THE JOIN: chaining -> extension -> sort -> mate-rescue as ONE block, single direction.
//
// This is accel_pe2_top with `chaining_extend_top` substituted for `accel_top`, i.e. the two
// previously separate integration trees fused:
//   Tree A (front): chaining_top + chain2aln_setup + accel_top   (chaining_extend_top)
//   Tree B (back):  accel_top + matesw_pe_sel_top                (accel_pe2_top)
// Both sat on accel_top but neither contained the other, so the full chaining->extend->sort->
// rescue path had never run as one block. It does now.
//
//   Run 1 (run_is_cand=1): RAW SEEDS for read i  -> chaining -> extension -> sort
//     -> score-sorted a[i] beats -> [capture FSM] -> candidate SOURCE buffer.
//   Run 2 (run_is_cand=0): RAW SEEDS for read !i -> chaining -> extension -> sort
//     -> a[!i] beats -> [capture FSM] -> rescue ma regfile.
//   Then: host loads the mate seq (read !i) + drives each candidate's windows on cand_req,
//     pulses sel_start -> the selector picks the good prefix (score >= top - pen_unpaired,
//     capped at max_matesw) and threads each rescue into ma. Final a[!i] read via rd_idx.
//
// The substitution is mostly interface work because chaining_extend_top and accel_top share an
// IDENTICAL output contract (same m_axis_tvalid/tdata/tlast/tready carrying rec_t). What changes:
//   (1) INPUT SIDE: raw seeds + query + start/n_in (chaining derives the chains itself) replace
//       accel_top's pre-chained per-chain drive (ch_go / s_ld / rmax).
//   (2) REF FETCH: chaining_extend_top computes rmax on chip, so the per-chain reference window
//       is no longer host-known up front -- the deferred-fetch handshake (ref_req/ref_in_*) is
//       plumbed UP to the host. Replacing it with an on-chip genome fetch later touches only
//       these ports (docs/chaining_extension_wiring_options.md Decision B2).
//   (3) RUN RESET: the run is latched at `start` (was accel's read_start). chain_store zeroes
//       nch/pool_n/fallback on its own start pulse and chaining_top clears fallback/n_out, so
//       run 2 cannot inherit run 1's chain state; the raw-seed buffer is bounded by n_in, so a
//       shorter run 2 never reads run 1's stale tail.
//
// FALLBACK IS STAGE-SPECIFIC (fb_chain / fb_sort / tie / overflow are separate bits, never
// OR'd together) so the host redoes ONLY the failed stage rather than the whole read. That
// matters most for rescue: it is 12.5% of runtime, so redoing just it caps the damage at ~0.05x
// versus ~0.15x for a whole-read redo. fb_chain/fb_sort are per-run and sampled at ce_done
// (the host knows which run it drove via run_is_cand); tie/overflow belong to the rescue stage
// and are sampled at sel_done.
//
// rec_t carries {rb,re,qb,qe,rid,score} only; seedcov/is_alt are NOT produced by the sorter and
// enter as 0 (the pre-existing accel/merge-sorter Stage-1 simplification -- mr_dedup keys on
// rb/re/qb/qe/score, the rest merely ride along).

`include "bsw_pkg.sv"
`include "msort_v2_pkg.sv"

module chaining_pe2_top
    import bsw_pkg::*;
    import msort_v2_pkg::*;
#(
    parameter int MA_MAX = 256,
    parameter int NSRC   = 64,
    parameter int NCHAIN = 64,
    parameter int NSEED  = 64,
    parameter int NQ     = 512,
    parameter int NS     = 64
)(
    input  logic               clk,
    input  logic               rst_n,

    // ======== chaining+extend (host-driven; reused for BOTH runs) ========
    input  logic               run_is_cand,   // latched at start: 1=source run, 0=ma run
    input  logic               start,
    input  logic [15:0]        n_in,          // # raw seeds for this run
    // config: wcfg/min_seed_len/l_pac are the SAME opt fields the rescue uses (bwa opt->w,
    // opt->min_seed_len, bns->l_pac), so they are shared ports rather than duplicated.
    input  logic signed [31:0] wcfg, max_chain_gap, max_chain_extend,
    input  logic signed [31:0] l_query, a, o_del, e_del, o_ins, e_ins, zdrop, pen5, pen3,
    // raw seed stream -> chaining
    input  logic               ld_en,
    input  logic [15:0]        ld_idx,
    input  logic signed [63:0] ld_rbeg,
    input  logic signed [31:0] ld_qbeg, ld_len, ld_score, ld_rid, ld_isalt,
    // query load (buffered, replayed to the extension)
    input  logic               q_ld_en,  input logic [15:0] q_ld_addr, input base_t q_ld_data,
    // deferred per-chain reference-window fetch (plumbed up from chaining_extend_top)
    output logic               ref_req,
    output logic signed [63:0] ref_rbeg,
    output logic [15:0]        ref_len,
    input  logic               ref_in_en,
    input  logic [15:0]        ref_in_addr,
    input  base_t              ref_in_data,
    input  logic               ref_in_done,
    // status
    output logic               ce_busy,
    output logic               ce_done,           // pulse at end of each run's capture
    output logic               fb_chain,          // this run's chaining stage needs SW redo
    output logic               fb_sort,           // this run's extension/sort stage needs SW redo
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
    output logic               tie,        // rescue dedup tie -> SW redo of the rescue stage
    output logic               overflow,   // rescue ma list outgrew MA_MAX -> SW redo of the rescue stage
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
    // ---- chaining_extend_top (reused for both runs) ----
    logic        ce_tvalid, ce_tlast, ce_done_i, ce_fb_chain, ce_fb_sort, ce_busy_i;
    logic        unused_ce_fb;   // the OR'd bit: deliberately unused, we report per stage
    rec_t        ce_tdata;

    chaining_extend_top #(.NCHAIN(NCHAIN), .NSEED(NSEED), .NQ(NQ), .NS(NS)) u_ce (
        .clk(clk), .rst_n(rst_n),
        .w(wcfg), .max_chain_gap(max_chain_gap), .min_seed_len(min_seed_len),
        .max_chain_extend(max_chain_extend),
        .a(a), .o_del(o_del), .e_del(e_del), .o_ins(o_ins), .e_ins(e_ins),
        .zdrop(zdrop), .pen5(pen5), .pen3(pen3), .l_query(l_query), .l_pac(l_pac),
        .ld_en(ld_en), .ld_idx(ld_idx), .ld_rbeg(ld_rbeg), .ld_qbeg(ld_qbeg),
        .ld_len(ld_len), .ld_score(ld_score), .ld_rid(ld_rid), .ld_isalt(ld_isalt),
        .q_ld_en(q_ld_en), .q_ld_addr(q_ld_addr), .q_ld_data(q_ld_data),
        .start(start), .n_in(n_in), .busy(ce_busy_i), .done(ce_done_i),
        .fallback(unused_ce_fb), .fb_chain(ce_fb_chain), .fb_sort(ce_fb_sort),
        .ref_req(ref_req), .ref_rbeg(ref_rbeg), .ref_len(ref_len),
        .ref_in_en(ref_in_en), .ref_in_addr(ref_in_addr), .ref_in_data(ref_in_data),
        .ref_in_done(ref_in_done),
        .m_axis_tvalid(ce_tvalid), .m_axis_tdata(ce_tdata), .m_axis_tlast(ce_tlast),
        .m_axis_tready(1'b1)                        // always accept; captured immediately
    );
    assign ce_busy = ce_busy_i;

    // ---- capture FSM: route the beats by the run latched at `start` ----
    logic [15:0] cap_cnt;
    logic        run_cand_r;       // 1 = current run feeds the source; 0 = feeds ma
    logic        ce_done_q;
    logic [15:0] n_src_r, n_ma_r;
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            cap_cnt <= 16'd0; run_cand_r <= 1'b0; ce_done_q <= 1'b0;
            ce_done <= 1'b0; fb_chain <= 1'b0; fb_sort <= 1'b0; n_src_r <= 16'd0; n_ma_r <= 16'd0;
        end else begin
            ce_done <= 1'b0;
            if (start) begin cap_cnt <= 16'd0; run_cand_r <= run_is_cand; end
            if (ce_tvalid)  cap_cnt <= cap_cnt + 16'd1;
            ce_done_q <= ce_done_i;
            if (ce_done_i && !ce_done_q) begin         // this run's output is fully captured
                ce_done  <= 1'b1;
                fb_chain <= ce_fb_chain;               // per-run, per-stage; host samples at ce_done
                fb_sort  <= ce_fb_sort;
                if (run_cand_r) n_src_r <= cap_cnt; else n_ma_r <= cap_cnt;
            end
        end
    end
    assign n_src_o     = n_src_r;
    assign n_ma_init_o = n_ma_r;

    // run 1 beats -> candidate source ; run 2 beats -> rescue ma regfile
    logic               s_src_en;  logic [15:0] s_src_idx;
    logic signed [63:0] s_src_rb;  logic signed [31:0] s_src_rid, s_src_alt, s_src_sc;
    assign s_src_en  = ce_tvalid && run_cand_r;
    assign s_src_idx = cap_cnt;
    assign s_src_rb  = ce_tdata.rb;
    assign s_src_rid = ce_tdata.rid;
    assign s_src_alt = 32'sd0;                          // is_alt not carried by the sorter
    assign s_src_sc  = ce_tdata.score;

    logic               s_ma_en;   logic [15:0] s_ma_idx;
    logic signed [63:0] s_ma_rb, s_ma_re; logic signed [31:0] s_ma_qb,s_ma_qe,s_ma_rid,s_ma_sc;
    assign s_ma_en  = ce_tvalid && !run_cand_r;
    assign s_ma_idx = cap_cnt;
    assign s_ma_rb  = ce_tdata.rb;
    assign s_ma_re  = ce_tdata.re;
    assign s_ma_qb  = ce_tdata.qb;
    assign s_ma_qe  = ce_tdata.qe;
    assign s_ma_rid = ce_tdata.rid;
    assign s_ma_sc  = ce_tdata.score;

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
        .busy(rescue_busy), .done(sel_done), .tie(tie), .overflow(overflow), .n_ma(n_ma),
        .rd_idx(rd_idx), .o_rb(o_rb), .o_re(o_re), .o_qb(o_qb), .o_qe(o_qe),
        .o_rid(o_rid), .o_score(o_score), .o_cov(o_cov)
    );
endmodule
