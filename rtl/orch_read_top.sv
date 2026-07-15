// orch_read_top.sv
// Read-level integration of the extend-orchestrator: drives all of a read's
// chains through orch_chain_unit, collects their alnregs (append order) into a
// read-level buffer, then runs orch_purge over the whole read. The result is the
// post-purge alnreg array — exactly orchestrate() in orch.h.
//
// Host protocol (Stage-1, host-fed reference), one read:
//   1. pulse read_start (latches cfg, resets counters)
//   2. load the query once          (q_ld_*)                while ch_ready
//   3. for each chain, while ch_ready:
//        load the chain ref window   (r_ld_*)
//        load the chain seeds        (s_ld_*, local idx 0..n-1)
//        pulse ch_go with {ch_n, ch_rid, ch_rmax0, ch_rmax1}
//        wait for ch_ready to rise again (chain collected)
//   4. pulse read_finish -> runs the purge; read_done pulses when complete
//   5. read the post-purge alnregs via rd_idx -> o_* (qb/qe come from the purge)
//
// The chain's seeds are forwarded to BOTH orch_chain_unit (local index, for the
// extension) and orch_purge (global index sbase+local, for the purge). The
// collected alnregs are written to BOTH the local full-record buffer and the
// purge's 6-field av buffer. abase==sbase==cumulative count (one alnreg/seed).

`include "bsw_pkg.sv"

module orch_read_top
    import bsw_pkg::*;
#(
    parameter int NAV = 1024,
    parameter int NSD = 1024,
    parameter int NCH = 1024
)(
    input  logic               clk,
    input  logic               rst_n,

    // ---- read-level cfg + control ----
    input  logic               read_start,
    input  logic signed [31:0] l_query, a, o_del, e_del, o_ins, e_ins, zdrop, wcfg, pen5, pen3,

    // ---- query load (once per read) ----
    input  logic               q_ld_en,
    input  logic [15:0]        q_ld_addr,
    input  base_t              q_ld_data,
    // ---- per-chain ref load ----
    input  logic               r_ld_en,
    input  logic [15:0]        r_ld_addr,
    input  base_t              r_ld_data,
    // ---- per-chain seed load (local index) ----
    input  logic               s_ld_en,
    input  logic [7:0]         s_ld_idx,
    input  logic signed [63:0] s_ld_rbeg,
    input  logic signed [31:0] s_ld_qbeg,
    input  logic signed [31:0] s_ld_len,
    input  logic signed [31:0] s_ld_score,

    // ---- chain go / done ----
    input  logic               ch_go,
    input  logic [7:0]         ch_n,
    input  logic signed [31:0] ch_rid,
    input  logic signed [63:0] ch_rmax0,
    input  logic signed [63:0] ch_rmax1,
    output logic               ch_ready,

    // ---- finish + status ----
    input  logic               read_finish,
    output logic               read_done,
    output logic               busy,
    output logic [15:0]        o_nav,        // # collected alnregs (valid after read_done)
    output logic               overflow,     // alnregs exceeded NAV (or chains NCH) -> SW redo

    // ---- post-purge readback (full alnreg) ----
    input  logic [15:0]        rd_idx,
    output logic signed [63:0] o_rb,
    output logic signed [63:0] o_re,
    output logic signed [31:0] o_qb,
    output logic signed [31:0] o_qe,
    output logic signed [31:0] o_score,
    output logic signed [31:0] o_truesc,
    output logic signed [31:0] o_w,
    output logic signed [31:0] o_seedcov,
    output logic signed [31:0] o_seedlen0,
    output logic signed [31:0] o_rid
);
    // ---- read-level full-record av buffer ----
    logic signed [63:0] av_rb [NAV], av_re [NAV];
    logic signed [31:0] av_score [NAV], av_truesc [NAV], av_w [NAV],
                        av_seedcov [NAV], av_seedlen0 [NAV], av_rid [NAV];

    // ---- latched read cfg ----
    logic signed [31:0] lq_r,a_r,od_r,ed_r,oi_r,ei_r,zd_r,w_r,p5_r,p3_r;

    // ---- counters ----
    logic [15:0] av_wptr;   // running collected-alnreg count (== cumulative seeds)
    logic [15:0] base_cur;  // av_wptr captured at ch_go (this chain's base)
    logic [15:0] cj;        // chain index
    logic [7:0]  ch_n_r;
    logic signed [31:0] rid_r; logic signed [63:0] rmax0_r, rmax1_r;

    // ---- orch_chain_unit ----
    logic        cu_start, cu_busy, cu_ovalid, cu_olast, cu_done;
    logic signed [63:0] cu_rb, cu_re; logic signed [31:0] cu_qb,cu_qe,cu_score,cu_truesc,cu_w,cu_scov,cu_sl0,cu_rid;
    logic        cu_ld_en, cu_ld_sel; logic [15:0] cu_ld_addr; base_t cu_ld_data;
    // ld passthrough: query (sel=0) or ref (sel=1)
    assign cu_ld_en   = q_ld_en | r_ld_en;
    assign cu_ld_sel  = r_ld_en;
    assign cu_ld_addr = r_ld_en ? r_ld_addr : q_ld_addr;
    assign cu_ld_data = r_ld_en ? r_ld_data : q_ld_data;

    orch_chain_unit u_chain (
        .clk(clk), .rst_n(rst_n),
        .ld_en(cu_ld_en), .ld_sel(cu_ld_sel), .ld_addr(cu_ld_addr), .ld_data(cu_ld_data),
        .sld_en(s_ld_en), .sld_idx(s_ld_idx), .sld_rbeg(s_ld_rbeg), .sld_qbeg(s_ld_qbeg),
        .sld_len(s_ld_len), .sld_score(s_ld_score),
        .start(cu_start), .l_query(lq_r), .a(a_r), .o_del(od_r), .e_del(ed_r),
        .o_ins(oi_r), .e_ins(ei_r), .zdrop(zd_r), .wcfg(w_r), .pen5(p5_r), .pen3(p3_r),
        .n_seeds(ch_n_r), .rid(rid_r), .rmax0(rmax0_r), .rmax1(rmax1_r),
        .busy(cu_busy), .out_valid(cu_ovalid), .out_last(cu_olast), .done(cu_done),
        .o_rb(cu_rb), .o_re(cu_re), .o_qb(cu_qb), .o_qe(cu_qe), .o_score(cu_score),
        .o_truesc(cu_truesc), .o_w(cu_w), .o_seedcov(cu_scov), .o_seedlen0(cu_sl0), .o_rid(cu_rid)
    );

    // ---- orch_purge ----
    logic        pg_start, pg_busy, pg_done;
    logic        pg_ch_ld; logic [15:0] pg_ch_idx, pg_ch_sbase, pg_ch_n, pg_ch_abase;
    logic signed [31:0] pg_rd_qb, pg_rd_qe;
    // collected-alnreg write into the purge av buffer: same cycle/index as the
    // local full-record write below (combinational so cu_* data and av_wptr align)
    logic        pg_av_ld; logic [15:0] pg_av_idx;

    orch_purge u_purge (
        .clk(clk), .rst_n(rst_n),
        // av load (collected alnregs, 6 purge-relevant fields)
        .av_ld_en(pg_av_ld), .av_ld_idx(pg_av_idx),
        .av_ld_rb(cu_rb), .av_ld_re(cu_re), .av_ld_qb(cu_qb), .av_ld_qe(cu_qe),
        .av_ld_w(cu_w), .av_ld_sl0(cu_sl0),
        // seed load (global index), mirrors the chain seed load
        .sd_ld_en(s_ld_en), .sd_ld_idx(av_wptr + {8'd0, s_ld_idx}),
        .sd_ld_rbeg(s_ld_rbeg), .sd_ld_qbeg(s_ld_qbeg), .sd_ld_len(s_ld_len), .sd_ld_score(s_ld_score),
        // chain table
        .ch_ld_en(pg_ch_ld), .ch_ld_idx(pg_ch_idx), .ch_ld_sbase(pg_ch_sbase),
        .ch_ld_n(pg_ch_n), .ch_ld_abase(pg_ch_abase),
        // run
        .start(pg_start), .nav(av_wptr), .nchain(cj),
        .a(a_r), .o_del(od_r), .e_del(ed_r), .o_ins(oi_r), .e_ins(ei_r), .wcfg(w_r), .l_query(lq_r),
        .busy(pg_busy), .done(pg_done),
        .rd_idx(rd_idx), .rd_qb(pg_rd_qb), .rd_qe(pg_rd_qe)
    );

    // readback: qb/qe from the purge (post-purge), the rest from the local buffer
    assign o_rb       = av_rb[rd_idx];
    assign o_re       = av_re[rd_idx];
    assign o_qb       = pg_rd_qb;
    assign o_qe       = pg_rd_qe;
    assign o_score    = av_score[rd_idx];
    assign o_truesc   = av_truesc[rd_idx];
    assign o_w        = av_w[rd_idx];
    assign o_seedcov  = av_seedcov[rd_idx];
    assign o_seedlen0 = av_seedlen0[rd_idx];
    assign o_rid      = av_rid[rd_idx];

    // ---- FSM ----
    typedef enum logic [2:0] { S_IDLE, S_RDY, S_CH_RUN, S_CH_WAIT, S_PURGE, S_PWAIT, S_DONE } st_t;
    st_t state;
    assign busy     = (state != S_IDLE);
    assign ch_ready = (state == S_RDY);
    assign o_nav    = av_wptr;

    // purge av-buffer write: mirror the local buffer write (same cycle + index).
    // Gated on capacity so the purge buffer never aliases either.
    assign pg_av_ld  = (state == S_CH_WAIT) && cu_ovalid && (av_wptr < NAV[15:0]);
    assign pg_av_idx = av_wptr;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state <= S_IDLE; read_done <= 1'b0; overflow <= 1'b0;
            cu_start <= 1'b0; pg_start <= 1'b0; pg_ch_ld <= 1'b0;
        end else begin
            read_done <= 1'b0; cu_start <= 1'b0; pg_start <= 1'b0;
            pg_ch_ld <= 1'b0;
            case (state)
                S_IDLE: if (read_start) begin
                    lq_r<=l_query; a_r<=a; od_r<=o_del; ed_r<=e_del; oi_r<=o_ins; ei_r<=e_ins;
                    zd_r<=zdrop; w_r<=wcfg; p5_r<=pen5; p3_r<=pen3;
                    av_wptr<=16'd0; cj<=16'd0; overflow<=1'b0;
                    state <= S_RDY;
                end
                S_RDY: begin
                    if (read_finish) state <= S_PURGE;
                    else if (ch_go) begin
                        base_cur <= av_wptr;
                        ch_n_r   <= ch_n;
                        rid_r    <= ch_rid; rmax0_r <= ch_rmax0; rmax1_r <= ch_rmax1;
                        state    <= S_CH_RUN;
                    end
                end
                S_CH_RUN: begin cu_start <= 1'b1; state <= S_CH_WAIT; end
                S_CH_WAIT: begin
                    // This is the EARLIEST overflow point in the accel: av_wptr is 16-bit
                    // and the av_* arrays are NAV deep, so without this gate an oversize
                    // read aliases on write here -- before the sorter ever counts it.
                    // Real data reaches n=1060 vs NAV=1024. On overflow: stop writing,
                    // hold av_wptr at NAV so o_nav stays truthful, raise `overflow`; the
                    // read still runs to completion and the host redoes it in SW.
                    if (cu_ovalid) begin
                        if (av_wptr >= NAV[15:0]) overflow <= 1'b1;
                        else begin
                            // write the full record locally; the purge av buffer is
                            // written combinationally this same cycle (pg_av_ld above)
                            av_rb[av_wptr]<=cu_rb; av_re[av_wptr]<=cu_re;
                            av_score[av_wptr]<=cu_score; av_truesc[av_wptr]<=cu_truesc;
                            av_w[av_wptr]<=cu_w; av_seedcov[av_wptr]<=cu_scov;
                            av_seedlen0[av_wptr]<=cu_sl0; av_rid[av_wptr]<=cu_rid;
                            av_wptr  <= av_wptr + 16'd1;
                        end
                    end
                    if (cu_done) begin
                        // record this chain in the purge chain table (NCH deep)
                        if (cj >= NCH[15:0]) overflow <= 1'b1;
                        else begin
                            pg_ch_ld <= 1'b1; pg_ch_idx <= cj;
                            pg_ch_sbase <= base_cur; pg_ch_abase <= base_cur;
                            pg_ch_n <= {8'd0, ch_n_r};
                            cj <= cj + 16'd1;
                        end
                        state <= S_RDY;
                    end
                end
                S_PURGE: begin pg_start <= 1'b1; state <= S_PWAIT; end
                S_PWAIT: if (pg_done) begin read_done <= 1'b1; state <= S_DONE; end
                S_DONE:  state <= S_IDLE;   // av buffers persist for readback
                default: state <= S_IDLE;
            endcase
        end
    end
endmodule
