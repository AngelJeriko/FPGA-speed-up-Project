// matesw_orch_top.sv
// Mate-rescue ORCHESTRATION top = one mem_matesw call in hardware. Wires the two
// verified blocks (matesw_orient_unit = SW + kswr->alnreg transform; matesw_dedup =
// mem_sort_dedup_patch) with the skip[4] decision and the score insertion, exactly
// as host/mate_rescue/orch.h::matesw_orchestrate (== mem_matesw_batch_post, !MATE_SORT):
//
//   skip[r]  = pes[r].failed, OR a consistent pair already exists in orientation r
//              (mem_infer_dir over the entry ma list).  all-skip -> ma unchanged.
//   per non-skipped r:
//     pre-SW gate = win.used && a.rid==win.rid && (win.re-win.rb) >= min_seed_len
//       if gate: load oriented query (reverse-complement when is_rev) + the host-fed
//                ref window into matesw_orient_unit, run it; if it yields a rescue,
//                insertion-sort the alnreg into ma by score (desc); n_acc++.
//     if n_acc>0: run matesw_dedup over ma (the per-orientation dedup; it runs even
//                 when this orientation's own gate failed, matching the source).
//
// Stage-1 host-fed reference: the 4 candidate windows (used/rb/re/rid + ref bytes)
// are provided by the host (the FPGA does not call bns_fetch_seq). MA_MAX bounds the
// ma list; n_ma_in > MA_MAX raises `overflow` (host SW fallback).
//
// Result: the survivor ma list is left in the internal register file, read back via
// rd_idx (n_out entries). is_rev[r] = (r==1)||(r==2).

`include "bsw_pkg.sv"

module matesw_orch_top
    import bsw_pkg::*;
#(
    parameter int MA_MAX = 256
)(
    input  logic               clk,
    input  logic               rst_n,

    // ---- load: mate sequence (ms) ----
    input  logic               ld_ms_en,
    input  logic [15:0]        ld_ms_addr,
    input  base_t              ld_ms_data,
    // ---- load: the 4 host-fed reference windows ----
    input  logic               ld_ref_en,
    input  logic [1:0]         ld_ref_win,
    input  logic [15:0]        ld_ref_addr,
    input  base_t              ld_ref_data,
    // ---- load: entry ma list ----
    input  logic               ld_ma_en,
    input  logic [15:0]        ld_ma_idx,
    input  logic signed [63:0] ld_ma_rb,
    input  logic signed [63:0] ld_ma_re,
    input  logic signed [31:0] ld_ma_qb,
    input  logic signed [31:0] ld_ma_qe,
    input  logic signed [31:0] ld_ma_rid,
    input  logic signed [31:0] ld_ma_score,
    input  logic signed [31:0] ld_ma_cov,

    // ---- request (latched on start) ----
    input  logic               start,
    input  logic signed [31:0] l_ms,
    input  logic signed [31:0] min_seed_len,
    input  logic signed [31:0] a,
    input  logic signed [31:0] o_del, e_del, o_ins, e_ins,
    input  logic signed [63:0] a_rb,
    input  logic signed [63:0] l_pac,
    input  logic signed [31:0] a_rid,
    input  logic signed [31:0] a_is_alt,
    input  logic [15:0]        n_ma_in,
    input  logic [3:0]         win_used,
    input  logic signed [63:0] win_rb  [4],
    input  logic signed [63:0] win_re  [4],
    input  logic signed [31:0] win_rid [4],
    input  logic signed [63:0] pes_low [4],
    input  logic signed [63:0] pes_high[4],
    input  logic [3:0]         pes_failed,

    // ---- status / result ----
    output logic               busy,
    output logic               done,
    output logic               overflow,
    output logic               tie,        // any per-orientation dedup tie -> SW fallback
    output logic [15:0]        n_out,
    input  logic [15:0]        rd_idx,
    output logic signed [63:0] o_rb,
    output logic signed [63:0] o_re,
    output logic signed [31:0] o_qb,
    output logic signed [31:0] o_qe,
    output logic signed [31:0] o_rid,
    output logic signed [31:0] o_score,
    output logic signed [31:0] o_cov
);
    // ---- memories ----
    base_t ms_mem  [MAX_QLEN];
    base_t ref_mem [4][MAX_TLEN];
    always_ff @(posedge clk) begin
        if (ld_ms_en)  ms_mem[ld_ms_addr]              <= ld_ms_data;
        if (ld_ref_en) ref_mem[ld_ref_win][ld_ref_addr] <= ld_ref_data;
    end

    // ---- ma register file ----
    logic signed [63:0] m_rb [MA_MAX];
    logic signed [63:0] m_re [MA_MAX];
    logic signed [31:0] m_qb [MA_MAX];
    logic signed [31:0] m_qe [MA_MAX];
    logic signed [31:0] m_rid[MA_MAX];
    logic signed [31:0] m_sc [MA_MAX];
    logic signed [31:0] m_cov[MA_MAX];

    assign o_rb=m_rb[rd_idx]; assign o_re=m_re[rd_idx]; assign o_qb=m_qb[rd_idx];
    assign o_qe=m_qe[rd_idx]; assign o_rid=m_rid[rd_idx]; assign o_score=m_sc[rd_idx];
    assign o_cov=m_cov[rd_idx];

    // ---- latched request ----
    logic signed [31:0] lms_r, msl_r, a_r, od_r, ed_r, oi_r, ei_r, arid_r, aalt_r;
    logic signed [63:0] arb_r, lpac_r;
    integer n;                       // current ma count
    logic [3:0] skip;
    integer r_cur, k, ip, ii;
    logic any_gate;

    // is_rev per orientation
    function automatic logic is_rev(input integer r); return (r==1)||(r==2); endfunction

    // ---- skip scan: mem_infer_dir(l_pac, a_rb, m_rb[ii]) ----
    logic        r1, r2;
    logic signed [63:0] p2, idist;
    logic [1:0]  dir;
    always_comb begin
        r1   = (arb_r       >= lpac_r);
        r2   = (m_rb[ii]    >= lpac_r);
        p2   = (r1==r2) ? m_rb[ii] : ((lpac_r <<< 1) - 64'sd1 - m_rb[ii]);
        idist = (p2 > arb_r) ? (p2 - arb_r) : (arb_r - p2);
        dir  = (((r1==r2)?2'd0:2'd1) ^ ((p2 > arb_r)?2'd0:2'd3));
    end

    // ---- matesw_orient_unit ----
    logic               ou_ld_en, ou_ld_sel; logic [15:0] ou_ld_addr; base_t ou_ld_data;
    logic               ou_start, ou_busy, ou_done, ou_rescue;
    logic signed [31:0] ou_tlen;
    logic signed [63:0] ou_b_rb, ou_b_re; logic signed [31:0] ou_b_qb, ou_b_qe, ou_b_sc, ou_b_cov, ou_b_rid, ou_b_alt;
    logic               ou_isrev;
    logic signed [63:0] ou_rb;

    matesw_orient_unit u_ou (
        .clk(clk), .rst_n(rst_n),
        .ld_en(ou_ld_en), .ld_sel(ou_ld_sel), .ld_addr(ou_ld_addr), .ld_data(ou_ld_data),
        .start(ou_start), .l_ms(lms_r), .tlen(ou_tlen),
        .o_del(od_r), .e_del(ed_r), .o_ins(oi_r), .e_ins(ei_r),
        .a(a_r), .min_seed_len(msl_r), .is_rev(ou_isrev),
        .rb(ou_rb), .l_pac(lpac_r), .a_rid(arid_r), .a_is_alt(aalt_r),
        .busy(ou_busy), .done_o(ou_done), .rescue(ou_rescue),
        .b_rb(ou_b_rb), .b_re(ou_b_re), .b_qb(ou_b_qb), .b_qe(ou_b_qe),
        .b_score(ou_b_sc), .b_seedcov(ou_b_cov), .b_rid(ou_b_rid), .b_is_alt(ou_b_alt)
    );
    assign ou_tlen  = win_re[r_cur][31:0] - win_rb[r_cur][31:0];
    assign ou_isrev = is_rev(r_cur);
    assign ou_rb    = win_rb[r_cur];

    // ---- matesw_dedup ----
    logic               dd_ld_en; logic [15:0] dd_ld_idx;
    logic signed [63:0] dd_ld_rb, dd_ld_re; logic signed [31:0] dd_ld_qb,dd_ld_qe,dd_ld_rid,dd_ld_sc,dd_ld_cov;
    logic               dd_start, dd_busy, dd_done, dd_ovf, dd_tie; logic [15:0] dd_n_in, dd_n_out;
    logic [15:0]        dd_rd_idx;
    logic signed [63:0] dd_o_rb, dd_o_re; logic signed [31:0] dd_o_qb,dd_o_qe,dd_o_rid,dd_o_sc,dd_o_cov;

    matesw_dedup #(.MA_MAX(MA_MAX)) u_dd (
        .clk(clk), .rst_n(rst_n),
        .ld_en(dd_ld_en), .ld_idx(dd_ld_idx),
        .ld_rb(dd_ld_rb), .ld_re(dd_ld_re), .ld_qb(dd_ld_qb), .ld_qe(dd_ld_qe),
        .ld_rid(dd_ld_rid), .ld_score(dd_ld_sc), .ld_cov(dd_ld_cov),
        .start(dd_start), .n_in(dd_n_in), .busy(dd_busy), .done(dd_done),
        .overflow(dd_ovf), .tie(dd_tie), .n_out(dd_n_out),
        .rd_idx(dd_rd_idx), .o_rb(dd_o_rb), .o_re(dd_o_re), .o_qb(dd_o_qb), .o_qe(dd_o_qe),
        .o_rid(dd_o_rid), .o_score(dd_o_sc), .o_cov(dd_o_cov)
    );
    assign dd_ld_rb=m_rb[k]; assign dd_ld_re=m_re[k]; assign dd_ld_qb=m_qb[k];
    assign dd_ld_qe=m_qe[k]; assign dd_ld_rid=m_rid[k]; assign dd_ld_sc=m_sc[k]; assign dd_ld_cov=m_cov[k];
    // load enable/index are combinational so they track the combinational data above
    // (registering only the index would lag the data by one cycle as k advances).
    assign dd_ld_en  = (state == T_DD_LD);
    assign dd_ld_idx = k[15:0];

    // ---- ma load ----
    always_ff @(posedge clk) if (ld_ma_en && ld_ma_idx < MA_MAX[15:0]) begin
        m_rb[ld_ma_idx]<=ld_ma_rb; m_re[ld_ma_idx]<=ld_ma_re; m_qb[ld_ma_idx]<=ld_ma_qb;
        m_qe[ld_ma_idx]<=ld_ma_qe; m_rid[ld_ma_idx]<=ld_ma_rid; m_sc[ld_ma_idx]<=ld_ma_score;
        m_cov[ld_ma_idx]<=ld_ma_cov;
    end

    typedef enum logic [4:0] {
        T_IDLE, T_SKIP, T_SKIPCHK, T_ORI, T_LDQ, T_LDR, T_RUN, T_RWAIT,
        T_INS_FIND, T_INS_SH, T_DD_LD, T_DD_RUN, T_DD_WAIT, T_DD_RD0, T_DD_RD1,
        T_NEXTR, T_DONE
    } st_t;
    st_t state;
    assign busy = (state != T_IDLE);

    task automatic copy_ma(input integer dst, input integer src);
        m_rb[dst]<=m_rb[src]; m_re[dst]<=m_re[src]; m_qb[dst]<=m_qb[src]; m_qe[dst]<=m_qe[src];
        m_rid[dst]<=m_rid[src]; m_sc[dst]<=m_sc[src]; m_cov[dst]<=m_cov[src];
    endtask

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state<=T_IDLE; done<=1'b0; overflow<=1'b0; tie<=1'b0; n_out<='0;
            ou_start<=1'b0; ou_ld_en<=1'b0; dd_start<=1'b0;
        end else begin
            done<=1'b0; ou_start<=1'b0; dd_start<=1'b0; ou_ld_en<=1'b0;
            case (state)
                T_IDLE: if (start) begin
                    lms_r<=l_ms; msl_r<=min_seed_len; a_r<=a;
                    od_r<=o_del; ed_r<=e_del; oi_r<=o_ins; ei_r<=e_ins;
                    arb_r<=a_rb; lpac_r<=l_pac; arid_r<=a_rid; aalt_r<=a_is_alt;
                    // reserve headroom: up to 4 rescue inserts can grow n before dedup
                    n<=n_ma_in; overflow<=(n_ma_in > MA_MAX[15:0]-16'd4); tie<=1'b0;
                    skip<=pes_failed; any_gate<=1'b0;
                    if (n_ma_in > MA_MAX[15:0]-16'd4) begin n_out<=n_ma_in; state<=T_DONE; end
                    else begin ii<=0; state<=T_SKIP; end
                end

                // ---- skip scan over entry ma ----
                T_SKIP: begin
                    if (ii >= n) state<=T_SKIPCHK;
                    else begin
                        if (idist >= pes_low[dir] && idist <= pes_high[dir]) skip[dir]<=1'b1;
                        ii<=ii+1;
                    end
                end
                T_SKIPCHK: begin
                    if (&skip) begin n_out<=n[15:0]; state<=T_DONE; end   // all-skip: ma unchanged
                    else begin r_cur<=0; state<=T_ORI; end
                end

                // ---- per-orientation ----
                T_ORI: begin
                    if (r_cur >= 4) begin n_out<=n[15:0]; state<=T_DONE; end
                    else if (skip[r_cur]) begin r_cur<=r_cur+1; state<=T_ORI; end
                    else begin
                        // pre-SW gate
                        if (win_used[r_cur] && (arid_r==win_rid[r_cur]) &&
                            ((win_re[r_cur]-win_rb[r_cur]) >= {{32{msl_r[31]}},msl_r})) begin
                            k<=0; state<=T_LDQ;
                        end else begin
                            // no SW; dedup still runs if a prior orientation fired
                            if (any_gate) begin k<=0; state<=T_DD_LD; end
                            else begin r_cur<=r_cur+1; state<=T_ORI; end
                        end
                    end
                end
                // load oriented query into orient_unit (reverse-complement when is_rev)
                T_LDQ: begin
                    ou_ld_en<=1'b1; ou_ld_sel<=1'b0; ou_ld_addr<=k[15:0];
                    if (is_rev(r_cur)) begin
                        ou_ld_data <= (ms_mem[lms_r-1-k] < base_t'(4)) ?
                                      base_t'(base_t'(3) - ms_mem[lms_r-1-k]) : base_t'(4);
                    end else ou_ld_data <= ms_mem[k];
                    if (k+1 >= lms_r) begin k<=0; state<=T_LDR; end
                    else k<=k+1;
                end
                // load the host-fed ref window into orient_unit
                T_LDR: begin
                    ou_ld_en<=1'b1; ou_ld_sel<=1'b1; ou_ld_addr<=k[15:0];
                    ou_ld_data <= ref_mem[r_cur][k];
                    if (k+1 >= ou_tlen) state<=T_RUN;
                    else k<=k+1;
                end
                T_RUN: begin ou_start<=1'b1; state<=T_RWAIT; end
                T_RWAIT: if (ou_done) begin
`ifdef MOT_TRACE
                    $display("[T] r=%0d rescue=%0d b_rb=%0d b_re=%0d b_qb=%0d b_qe=%0d b_sc=%0d n=%0d",
                             r_cur, ou_rescue, ou_b_rb, ou_b_re, ou_b_qb, ou_b_qe, ou_b_sc, n);
`endif
                    any_gate<=1'b1;                       // gate passed -> ++n; dedup will run
                    if (ou_rescue) begin
                        // latch b, then insertion-sort by score (desc)
                        ip<=0; state<=T_INS_FIND;
                    end else begin k<=0; state<=T_DD_LD; end
                end
                // find insertion point: first i with m_sc[i] < b.score
                T_INS_FIND: begin
                    if (ip >= n || m_sc[ip] < ou_b_sc) begin
                        ii<=n; state<=T_INS_SH;           // shift from the tail
                    end else ip<=ip+1;
                end
                // shift [ip..n-1] up by one, then place b at ip
                T_INS_SH: begin
                    if (ii > ip) begin copy_ma(ii, ii-1); ii<=ii-1; end
                    else begin
                        m_rb[ip]<=ou_b_rb; m_re[ip]<=ou_b_re; m_qb[ip]<=ou_b_qb; m_qe[ip]<=ou_b_qe;
                        m_rid[ip]<=ou_b_rid; m_sc[ip]<=ou_b_sc; m_cov[ip]<=ou_b_cov;
                        n<=n+1; k<=0; state<=T_DD_LD;
                    end
                end
                // ---- per-orientation dedup: stream ma -> matesw_dedup -> read back ----
                T_DD_LD: begin
                    if (k+1 >= n) state<=T_DD_RUN;
                    else k<=k+1;
                end
                T_DD_RUN: begin dd_n_in<=n[15:0]; dd_start<=1'b1; state<=T_DD_WAIT; end
                T_DD_WAIT: if (dd_done) begin n<=dd_n_out; k<=0; tie<=tie|dd_tie;
`ifdef MOT_TRACE
                    $display("[D] r=%0d dedup n_in=%0d -> n_out=%0d", r_cur, dd_n_in, dd_n_out);
`endif
                    if (dd_n_out==0) state<=T_NEXTR; else state<=T_DD_RD0;
                end
                T_DD_RD0: begin dd_rd_idx<=k[15:0]; state<=T_DD_RD1; end
                T_DD_RD1: begin
                    m_rb[k]<=dd_o_rb; m_re[k]<=dd_o_re; m_qb[k]<=dd_o_qb; m_qe[k]<=dd_o_qe;
                    m_rid[k]<=dd_o_rid; m_sc[k]<=dd_o_sc; m_cov[k]<=dd_o_cov;
                    if (k+1 >= n) state<=T_NEXTR;
                    else begin k<=k+1; state<=T_DD_RD0; end
                end
                T_NEXTR: begin r_cur<=r_cur+1; state<=T_ORI; end

                T_DONE: begin done<=1'b1; state<=T_IDLE; end
                default: state<=T_IDLE;
            endcase
        end
    end
endmodule
