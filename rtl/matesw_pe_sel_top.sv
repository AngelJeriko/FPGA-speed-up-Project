// matesw_pe_sel_top.sv
// On-chip CANDIDATE SELECTION + rescue loop = the b[i] selection of mem_sam_pe_batch
// folded onto the verified matesw_pe_top. Models host/mate_rescue/pe.h::matesw_pe_select:
//
//   given read i's alnregs (the candidate SOURCE, score-sorted DESC by the dedup) and
//   read !i's entry ma list, select the "good" candidates and rescue the mate against
//   each, threading the SAME ma list across candidates.
//
//   top = src[0].score                       (src[0] = highest, sorted desc)
//   K   = # leading j with src[j].score >= top - pen_unpaired,  capped at max_matesw
//   for j in 0..K-1:  matesw_orchestrate(src[j], mate_seq, ma)
//
// Because the source is score-sorted descending, the "good" set is a contiguous
// PREFIX (a clean break), so selection reduces to COUNTING K and replaying src[0..K-1]
// — no scatter/gather. This wrapper owns the source buffer + the K driver and drives
// the verified matesw_pe_top (which owns the ma regfile and does one mem_matesw per
// cand_start). a_rb/a_rid/a_is_alt are pulled from the source; the candidate's
// per-orientation reference WINDOWS stay host-fed (Stage-1: no on-chip bns_fetch_seq),
// requested on demand via the cand_req/cur_cand -> cand_wins_ready handshake.
//
// Stage-1 note: the source carries no is_alt through the merge-sorter (rec_t is 6
// fields), so candidates enter with src_alt=0 — same simplification as accel_pe_top.

`include "bsw_pkg.sv"

module matesw_pe_sel_top
    import bsw_pkg::*;
#(
    parameter int MA_MAX = 64,        // ma list bound (== matesw_pe_top)
    parameter int NSRC   = 64         // candidate-source bound
)(
    input  logic               clk,
    input  logic               rst_n,

    // ======== candidate source (read i's alnregs, score-sorted DESC) ========
    input  logic               src_ld_en,
    input  logic [15:0]        src_ld_idx,
    input  logic signed [63:0] src_ld_rb,
    input  logic signed [31:0] src_ld_rid,
    input  logic signed [31:0] src_ld_alt,
    input  logic signed [31:0] src_ld_score,
    input  logic [15:0]        n_src,           // # source candidates
    input  logic signed [31:0] pen_unpaired,    // gate: score >= top - pen_unpaired
    input  logic signed [31:0] max_matesw,      // cap on # rescued candidates

    // ======== pass-through loads to matesw_pe_top (mate seq + ref windows + entry ma) ========
    input  logic               ld_ms_en,
    input  logic [15:0]        ld_ms_addr,
    input  base_t              ld_ms_data,
    input  logic               ld_ref_en,
    input  logic [1:0]         ld_ref_win,
    input  logic [15:0]        ld_ref_addr,
    input  base_t              ld_ref_data,
    input  logic               ld_ma_en,
    input  logic [15:0]        ld_ma_idx,
    input  logic signed [63:0] ld_ma_rb,
    input  logic signed [63:0] ld_ma_re,
    input  logic signed [31:0] ld_ma_qb,
    input  logic signed [31:0] ld_ma_qe,
    input  logic signed [31:0] ld_ma_rid,
    input  logic signed [31:0] ld_ma_score,
    input  logic signed [31:0] ld_ma_cov,
    input  logic [15:0]        n_ma_init,       // entry ma count

    // ======== read-level scalars (constant across candidates) ========
    input  logic               sel_start,       // pulse: begin select + loop
    input  logic signed [31:0] l_ms, min_seed_len, a, o_del, e_del, o_ins, e_ins,
    input  logic signed [63:0] l_pac,

    // ======== per-candidate window inputs (host drives in response to cand_req) ========
    input  logic [3:0]         win_used,
    input  logic signed [63:0] win_rb  [4],
    input  logic signed [63:0] win_re  [4],
    input  logic signed [31:0] win_rid [4],
    input  logic signed [63:0] pes_low [4],
    input  logic signed [63:0] pes_high[4],
    input  logic [3:0]         pes_failed,

    // ======== window request handshake ========
    output logic               cand_req,        // level: wrapper wants windows for cur_cand
    output logic [15:0]        cur_cand,         // current source index being rescued
    input  logic               cand_wins_ready,  // host: windows for cur_cand are loaded

    // ======== debug: candidate-source readback (verification only; no logic effect) ========
    input  logic [15:0]        src_rd_idx,
    output logic signed [63:0] src_o_rb,
    output logic signed [31:0] src_o_rid,
    output logic signed [31:0] src_o_alt,
    output logic signed [31:0] src_o_sc,

    // ======== status / result (final ma) ========
    output logic               busy,
    output logic               done,
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
    // ---- candidate-source register file ----
    logic signed [63:0] s_rb [NSRC];
    logic signed [31:0] s_rid[NSRC];
    logic signed [31:0] s_alt[NSRC];
    logic signed [31:0] s_sc [NSRC];

    // ---- selection regs ----
    logic signed [31:0] thr;          // top - pen_unpaired
    logic [15:0]        j;            // current source index
    logic [15:0]        nsrc_r;
    logic signed [31:0] maxm_r, pen_r;

    // ---- inner matesw_pe_top control ----
    logic        pe_init, pe_cand_start, pe_busy, pe_cand_done;
    logic [15:0] pe_n_ma;

    matesw_pe_top #(.MA_MAX(MA_MAX)) u_pe (
        .clk(clk), .rst_n(rst_n),
        // mate seq + ref windows + entry ma load: straight through from wrapper ports
        .ld_ms_en(ld_ms_en), .ld_ms_addr(ld_ms_addr), .ld_ms_data(ld_ms_data),
        .ld_ref_en(ld_ref_en), .ld_ref_win(ld_ref_win), .ld_ref_addr(ld_ref_addr), .ld_ref_data(ld_ref_data),
        .ld_ma_en(ld_ma_en), .ld_ma_idx(ld_ma_idx),
        .ld_ma_rb(ld_ma_rb), .ld_ma_re(ld_ma_re), .ld_ma_qb(ld_ma_qb), .ld_ma_qe(ld_ma_qe),
        .ld_ma_rid(ld_ma_rid), .ld_ma_score(ld_ma_score), .ld_ma_cov(ld_ma_cov),
        .init(pe_init), .n_ma_init(n_ma_init),
        // candidate request: a_rb/a_rid/a_is_alt pulled from the source buffer
        .cand_start(pe_cand_start),
        .l_ms(l_ms), .min_seed_len(min_seed_len), .a(a),
        .o_del(o_del), .e_del(e_del), .o_ins(o_ins), .e_ins(e_ins),
        .a_rb(s_rb[j]), .l_pac(l_pac), .a_rid(s_rid[j]), .a_is_alt(s_alt[j]),
        .win_used(win_used), .win_rb(win_rb), .win_re(win_re), .win_rid(win_rid),
        .pes_low(pes_low), .pes_high(pes_high), .pes_failed(pes_failed),
        .busy(pe_busy), .cand_done(pe_cand_done), .n_ma(pe_n_ma),
        .rd_idx(rd_idx), .o_rb(o_rb), .o_re(o_re), .o_qb(o_qb), .o_qe(o_qe),
        .o_rid(o_rid), .o_score(o_score), .o_cov(o_cov)
    );
    assign n_ma     = pe_n_ma;
    assign cur_cand = j;

    // debug source-buffer readback (combinational; verification taps only)
    assign src_o_rb  = s_rb [src_rd_idx];
    assign src_o_rid = s_rid[src_rd_idx];
    assign src_o_alt = s_alt[src_rd_idx];
    assign src_o_sc  = s_sc [src_rd_idx];

    typedef enum logic [2:0] { S_IDLE, S_TOP, S_CHECK, S_REQ, S_START, S_RUN, S_DONE } st_t;
    st_t state;
    assign busy     = (state != S_IDLE);
    assign cand_req = (state == S_REQ);

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state <= S_IDLE; done <= 1'b0; pe_init <= 1'b0; pe_cand_start <= 1'b0;
            j <= '0; thr <= '0; nsrc_r <= '0; maxm_r <= '0; pen_r <= '0;
        end else begin
            done <= 1'b0; pe_init <= 1'b0; pe_cand_start <= 1'b0;

            // source buffer write (host load)
            if (src_ld_en && src_ld_idx < NSRC[15:0]) begin
                s_rb [src_ld_idx] <= src_ld_rb;
                s_rid[src_ld_idx] <= src_ld_rid;
                s_alt[src_ld_idx] <= src_ld_alt;
                s_sc [src_ld_idx] <= src_ld_score;
            end

            case (state)
                S_IDLE: if (sel_start) begin
                    pe_init <= 1'b1;             // latch entry ma count into pe_top.n_r
                    nsrc_r  <= n_src;
                    pen_r   <= pen_unpaired;
                    maxm_r  <= max_matesw;
                    j       <= '0;
                    state   <= (n_src == 16'd0) ? S_DONE : S_TOP;
                end
                // top = src[0].score (combinational reg read), thr = top - pen
                S_TOP: begin
                    thr   <= s_sc[0] - pen_r;
                    state <= S_CHECK;
                end
                // prefix gate: rescue src[j] iff j<n_src && j<max_matesw && score>=thr
                S_CHECK: begin
                    if (j < nsrc_r && $signed({16'd0, j}) < maxm_r && s_sc[j] >= thr)
                        state <= S_REQ;
                    else
                        state <= S_DONE;
                end
                // request this candidate's host-fed windows
                S_REQ: if (cand_wins_ready) state <= S_START;
                // pulse pe_top.cand_start (a_rb/a_rid/a_is_alt = s_*[j], win_* held by host)
                S_START: begin pe_cand_start <= 1'b1; state <= S_RUN; end
                // wait this candidate's mem_matesw to complete, then advance
                S_RUN: if (pe_cand_done) begin j <= j + 16'd1; state <= S_CHECK; end
                S_DONE: begin done <= 1'b1; state <= S_IDLE; end
                default: state <= S_IDLE;
            endcase
        end
    end
endmodule
