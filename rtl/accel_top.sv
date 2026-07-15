// accel_top.sv
// Combined extend-orchestrator + merge-sorter accelerator (Stage-1, host-fed
// reference). One read in -> one consolidated, sorted/deduped alnreg list out,
// behind a single AXI-Stream output bus.
//
//   host loads (query/ref/seeds) -> orch_read_top (extension + seedcov + purge)
//     -> compaction (keep qe>qb, mirroring bwamem.cpp before mem_sort_dedup_patch)
//     -> msort_v2_top (re-sort + de-overlap + score-sort + identical removal)
//     -> m_axis_t* (rec = {rb,re,qb,qe,rid,score})
//
// The merge-sorter raises `fallback` for arrays with an equal-re tie or n>1024;
// the host then redoes that read in software (bit-exact), exactly as the
// standalone sorter contract specifies.
//
// Both sub-engines are independently verified; this composes them with the
// compaction streamer and is checked end-to-end (tb_accel_top) against
// orchestrate()->compact->v2_dedup().

`include "bsw_pkg.sv"
`include "msort_v2_pkg.sv"

module accel_top
    import bsw_pkg::*;
    import msort_v2_pkg::*;
(
    input  logic               clk,
    input  logic               rst_n,

    // ---- read-level cfg + control (-> orch_read_top) ----
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

    // ---- AXI-Stream result ----
    output logic               m_axis_tvalid,
    output rec_t               m_axis_tdata,
    output logic               m_axis_tlast,
    input  logic               m_axis_tready,

    // ---- status ----
    output logic               fallback,    // read needs SW redo (sorter tie / oversize)
    output logic               busy,
    output logic               done         // pulse: this read fully processed
);
    // ---- orch_read_top ----
    logic        rt_read_done, rt_busy;
    logic [15:0] rt_nav, rt_rd_idx;
    logic        rt_ovf;                 // orchestrator buffers overflowed (earliest point)
    logic signed [63:0] rt_rb, rt_re; logic signed [31:0] rt_qb,rt_qe,rt_score,rt_truesc,rt_w,rt_scov,rt_sl0,rt_rid;

    orch_read_top u_rt (
        .clk(clk), .rst_n(rst_n),
        .read_start(read_start),
        .l_query(l_query), .a(a), .o_del(o_del), .e_del(e_del), .o_ins(o_ins),
        .e_ins(e_ins), .zdrop(zdrop), .wcfg(wcfg), .pen5(pen5), .pen3(pen3),
        .q_ld_en(q_ld_en), .q_ld_addr(q_ld_addr), .q_ld_data(q_ld_data),
        .r_ld_en(r_ld_en), .r_ld_addr(r_ld_addr), .r_ld_data(r_ld_data),
        .s_ld_en(s_ld_en), .s_ld_idx(s_ld_idx), .s_ld_rbeg(s_ld_rbeg),
        .s_ld_qbeg(s_ld_qbeg), .s_ld_len(s_ld_len), .s_ld_score(s_ld_score),
        .ch_go(ch_go), .ch_n(ch_n), .ch_rid(ch_rid), .ch_rmax0(ch_rmax0), .ch_rmax1(ch_rmax1),
        .ch_ready(ch_ready), .read_finish(read_finish),
        .read_done(rt_read_done), .busy(rt_busy), .o_nav(rt_nav), .overflow(rt_ovf),
        .rd_idx(rt_rd_idx),
        .o_rb(rt_rb), .o_re(rt_re), .o_qb(rt_qb), .o_qe(rt_qe), .o_score(rt_score),
        .o_truesc(rt_truesc), .o_w(rt_w), .o_seedcov(rt_scov), .o_seedlen0(rt_sl0), .o_rid(rt_rid)
    );

    // ---- msort_v2_top ----
    logic        ms_in_valid, ms_in_last, ms_in_ready, ms_busy, ms_done, ms_fallback;
    rec_t        ms_in_rec;
    logic        ms_out_valid, ms_out_last;
    rec_t        ms_out_rec;

    msort_v2_top u_ms (
        .clk(clk), .rst_n(rst_n),
        .in_valid(ms_in_valid), .in_rec(ms_in_rec), .in_last(ms_in_last), .in_ready(ms_in_ready),
        .out_valid(ms_out_valid), .out_rec(ms_out_rec), .out_last(ms_out_last), .out_ready(m_axis_tready),
        .fallback(ms_fallback), .busy(ms_busy), .done(ms_done)
    );

    // output mux: direct single-survivor emit (C_EMIT1) vs the sorter stream
    rec_t cur_rec;
    assign m_axis_tvalid = (cstate == C_EMIT1) ? 1'b1     : ms_out_valid;
    assign m_axis_tdata  = (cstate == C_EMIT1) ? cur_rec  : ms_out_rec;
    assign m_axis_tlast  = (cstate == C_EMIT1) ? 1'b1     : ms_out_last;

    // ---- compaction streamer: post-purge survivors (qe>qb) -> sorter ----
    // bwa-mem2 short-circuits n<=1 in mem_sort_dedup_patch (no sort), and the
    // standalone merge-sorter is only defined for n>=2, so accel_top emits 0/1
    // survivors directly and only streams n>=2 through msort_v2_top.
    typedef enum logic [3:0] {
        C_IDLE, C_FIND_SET, C_FIND_EVAL, C_DECIDE, C_EMIT1,
        C_STREAM_SET, C_STREAM_EVAL, C_PRESENT, C_SORT, C_DONE
    } cst_t;
    cst_t cstate;
    logic [15:0] scan_idx, last_surv, surv_cnt;
    logic        fb_latch;

    // current readback record (combinational in rt_rd_idx)
    assign rt_rd_idx = scan_idx;
    wire   is_surv   = (rt_qe > rt_qb);
    always_comb begin
        cur_rec = '0;
        cur_rec.rb=rt_rb; cur_rec.re=rt_re; cur_rec.qb=rt_qb; cur_rec.qe=rt_qe;
        cur_rec.rid=rt_rid; cur_rec.score=rt_score;
    end

    assign busy     = (cstate != C_IDLE) || rt_busy;
    assign fallback = fb_latch;

    // sorter input handshake driven combinationally (valid held in C_PRESENT until
    // in_ready, so no beat is dropped by a registered-valid delay)
    assign ms_in_valid = (cstate == C_PRESENT);
    assign ms_in_rec   = cur_rec;
    assign ms_in_last  = (scan_idx == last_surv);

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            cstate <= C_IDLE; done <= 1'b0; fb_latch <= 1'b0;
        end else begin
            done <= 1'b0;
            case (cstate)
                C_IDLE: if (rt_read_done) begin
                    scan_idx <= 16'd0; last_surv <= 16'd0; surv_cnt <= 16'd0;
                    fb_latch <= 1'b0;
                    cstate <= (rt_nav == 16'd0) ? C_DONE : C_FIND_SET;
                end
                // ---- pass A: count survivors (qe>qb), remember the last one ----
                C_FIND_SET: cstate <= C_FIND_EVAL;   // rt_rd_idx=scan_idx settles
                C_FIND_EVAL: begin
                    if (is_surv) begin last_surv <= scan_idx; surv_cnt <= surv_cnt + 16'd1; end
                    if (scan_idx + 16'd1 == rt_nav) cstate <= C_DECIDE;
                    else begin scan_idx <= scan_idx + 16'd1; cstate <= C_FIND_SET; end
                end
                // ---- decide path by survivor count (surv_cnt now final) ----
                C_DECIDE: begin
                    // surv_cnt is already computed by pass A, so bounding it against the
                    // sorter's capacity is free. Combined with rt_ovf (the orchestrator's
                    // own buffers), an oversize read now ends cleanly in fallback and never
                    // streams -- instead of silently aliasing. See merge_sorter_v2_design.md.
                    if (rt_ovf || surv_cnt > 16'(N_MAX)) begin
                        fb_latch <= 1'b1; cstate <= C_DONE;
                    end
                    else if (surv_cnt == 16'd0) cstate <= C_DONE;            // nothing
                    else if (surv_cnt == 16'd1) begin scan_idx <= last_surv; cstate <= C_EMIT1; end
                    else    begin scan_idx <= 16'd0; cstate <= C_STREAM_SET; end
                end
                // ---- n==1: emit the single survivor directly (bwa short-circuit) ----
                C_EMIT1: if (m_axis_tready) cstate <= C_DONE;
                // ---- n>=2: stream survivors into the sorter ----
                C_STREAM_SET: cstate <= C_STREAM_EVAL;
                C_STREAM_EVAL: begin
                    if (is_surv) cstate <= C_PRESENT;
                    else if (scan_idx + 16'd1 == rt_nav) cstate <= C_SORT;
                    else begin scan_idx <= scan_idx + 16'd1; cstate <= C_STREAM_SET; end
                end
                C_PRESENT: begin
                    // ms_in_valid/rec/last are combinational (above); advance on accept
                    if (ms_in_ready) begin
                        if (scan_idx == last_surv) cstate <= C_SORT;
                        else begin scan_idx <= scan_idx + 16'd1; cstate <= C_STREAM_SET; end
                    end
                end
                C_SORT: if (ms_done) begin fb_latch <= ms_fallback; cstate <= C_DONE; end
                C_DONE: begin done <= 1'b1; cstate <= C_IDLE; end
                default: cstate <= C_IDLE;
            endcase
        end
    end
endmodule
