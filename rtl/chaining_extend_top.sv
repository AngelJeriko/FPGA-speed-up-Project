// chaining_extend_top.sv — wires the COMPLETE chaining stage into the full extend pipeline:
//   raw seed stream --chaining_top--> surviving chains
//                   --chain2aln_setup--> per-chain reference-window bounds (rmax0/rmax1)
//                   --accel_top--> extension + compaction + merge-sort --> AXI-Stream alnregs.
//
// The per-chain reference BYTES are supplied externally (deferred genome fetch, per the design
// doc): when a chain's rmax is ready the top raises `ref_req` with {ref_rbeg, ref_len}; the host
// streams the window back on ref_in_* and pulses ref_in_done; the top forwards those bytes to
// accel_top's r_ld. Both chaining and the sorter can raise `fallback` -> whole-read SW redo.
//
// Per surviving chain k (weight-sorted order from chaining_top): read its chain_store index,
// walk its seed pool (head->next) into a local buffer, compute rmax (chain2aln_setup), fetch the
// ref window, then drive accel_top (r_ld ref, s_ld seeds, ch_go {n,rid,rmax0,rmax1}).
`include "bsw_pkg.sv"
`include "msort_v2_pkg.sv"

module chaining_extend_top
    import bsw_pkg::*;
    import msort_v2_pkg::*;
#(
    parameter int NCHAIN = 64,
    parameter int NSEED  = 64,     // chain_store pool / raw seeds
    parameter int NQ     = 512,    // query length bound
    parameter int NS     = 64      // per-chain seed buffer
)(
    input  logic               clk,
    input  logic               rst_n,

    // ---- config ----
    input  logic signed [31:0] w, max_chain_gap, min_seed_len, max_chain_extend,
    input  logic signed [31:0] a, o_del, e_del, o_ins, e_ins, zdrop, pen5, pen3, l_query,
    input  logic signed [63:0] l_pac,

    // ---- raw seed stream load (-> chaining_top / chain_store) ----
    input  logic               ld_en,
    input  logic [15:0]        ld_idx,
    input  logic signed [63:0] ld_rbeg,
    input  logic signed [31:0] ld_qbeg, ld_len, ld_score, ld_rid, ld_isalt,

    // ---- query load (buffered, replayed to accel_top) ----
    input  logic               q_ld_en,
    input  logic [15:0]        q_ld_addr,
    input  base_t              q_ld_data,

    // ---- run ----
    input  logic               start,
    input  logic [15:0]        n_in,        // # raw seeds
    output logic               busy,
    output logic               done,
    output logic               fallback,

    // ---- deferred reference-window fetch ----
    output logic               ref_req,     // high: need ref bytes for [ref_rbeg, ref_rbeg+ref_len)
    output logic signed [63:0] ref_rbeg,
    output logic [15:0]        ref_len,
    input  logic               ref_in_en,
    input  logic [15:0]        ref_in_addr,
    input  base_t              ref_in_data,
    input  logic               ref_in_done,

    // ---- AXI-Stream result (passthrough from accel_top) ----
    output logic               m_axis_tvalid,
    output rec_t               m_axis_tdata,
    output logic               m_axis_tlast,
    input  logic               m_axis_tready
);
    // ================= query buffer =================
    base_t q_buf [NQ];
    always_ff @(posedge clk) if (q_ld_en && q_ld_addr < NQ[15:0]) q_buf[q_ld_addr] <= q_ld_data;

    // ================= chaining_top =================
    logic ct_start, ct_busy, ct_done, ct_fallback; logic [15:0] ct_nout;
    logic [15:0] ct_rd_idx, ct_o_cidx;
    logic [15:0] ct_rd_cidx; logic signed [63:0] ct_o_pos; logic signed [31:0] ct_o_rid, ct_o_isalt; logic [15:0] ct_o_nseeds, ct_o_head;
    logic [15:0] ct_rd_sidx; logic signed [63:0] ct_s_rbeg; logic signed [31:0] ct_s_qbeg, ct_s_len, ct_s_score; logic [15:0] ct_s_next;
    chaining_top #(.NCHAIN(NCHAIN), .NSEED(NSEED), .CWSEED(NS)) u_ct (.clk,.rst_n,
        .w,.max_chain_gap,.l_pac,.min_seed_len,.max_chain_extend,
        .ld_en,.ld_idx,.ld_rbeg,.ld_qbeg,.ld_len,.ld_score,.ld_rid,.ld_isalt,
        .start(ct_start),.n_in(n_in),.busy(ct_busy),.done(ct_done),.fallback(ct_fallback),.n_out(ct_nout),
        .rd_idx(ct_rd_idx),.o_cidx(ct_o_cidx),
        .rd_cidx(ct_rd_cidx),.o_pos(ct_o_pos),.o_rid(ct_o_rid),.o_isalt(ct_o_isalt),.o_nseeds(ct_o_nseeds),.o_head(ct_o_head),
        .rd_sidx(ct_rd_sidx),.s_rbeg(ct_s_rbeg),.s_qbeg(ct_s_qbeg),.s_len(ct_s_len),.s_score(ct_s_score),.s_next(ct_s_next));

    // ================= chain2aln_setup (rmax) =================
    logic c2_ld_en; logic [15:0] c2_ld_idx; logic signed [63:0] c2_ld_rbeg; logic signed [31:0] c2_ld_qbeg, c2_ld_len;
    logic c2_start; logic [15:0] c2_nin; logic c2_busy, c2_done; logic signed [63:0] c2_rmax0, c2_rmax1;
    chain2aln_setup #(.NSEED(NS)) u_c2 (.clk,.rst_n,
        .a,.o_del,.e_del,.o_ins,.e_ins,.wband(w),.l_query,.l_pac,
        .ld_en(c2_ld_en),.ld_idx(c2_ld_idx),.ld_rbeg(c2_ld_rbeg),.ld_qbeg(c2_ld_qbeg),.ld_len(c2_ld_len),
        .start(c2_start),.n_in(c2_nin),.busy(c2_busy),.done(c2_done),.rmax0(c2_rmax0),.rmax1(c2_rmax1));

    // ================= accel_top (extension + compaction + sort) =================
    logic ac_read_start, ac_read_finish, ac_ch_go, ac_ch_ready, ac_fallback, ac_busy, ac_done;
    logic ac_q_ld_en; logic [15:0] ac_q_ld_addr; base_t ac_q_ld_data;
    logic ac_r_ld_en; logic [15:0] ac_r_ld_addr; base_t ac_r_ld_data;
    logic ac_s_ld_en; logic [7:0] ac_s_ld_idx; logic signed [63:0] ac_s_ld_rbeg; logic signed [31:0] ac_s_ld_qbeg, ac_s_ld_len, ac_s_ld_score;
    logic [7:0] ac_ch_n; logic signed [31:0] ac_ch_rid; logic signed [63:0] ac_ch_rmax0, ac_ch_rmax1;
    accel_top u_ac (.clk,.rst_n,
        .read_start(ac_read_start),
        .l_query(l_query),.a(a),.o_del(o_del),.e_del(e_del),.o_ins(o_ins),.e_ins(e_ins),
        .zdrop(zdrop),.wcfg(w),.pen5(pen5),.pen3(pen3),
        .q_ld_en(ac_q_ld_en),.q_ld_addr(ac_q_ld_addr),.q_ld_data(ac_q_ld_data),
        .r_ld_en(ac_r_ld_en),.r_ld_addr(ac_r_ld_addr),.r_ld_data(ac_r_ld_data),
        .s_ld_en(ac_s_ld_en),.s_ld_idx(ac_s_ld_idx),.s_ld_rbeg(ac_s_ld_rbeg),.s_ld_qbeg(ac_s_ld_qbeg),.s_ld_len(ac_s_ld_len),.s_ld_score(ac_s_ld_score),
        .ch_go(ac_ch_go),.ch_n(ac_ch_n),.ch_rid(ac_ch_rid),.ch_rmax0(ac_ch_rmax0),.ch_rmax1(ac_ch_rmax1),.ch_ready(ac_ch_ready),
        .read_finish(ac_read_finish),
        .m_axis_tvalid(m_axis_tvalid),.m_axis_tdata(m_axis_tdata),.m_axis_tlast(m_axis_tlast),.m_axis_tready(m_axis_tready),
        .fallback(ac_fallback),.busy(ac_busy),.done(ac_done));

    // ================= local per-chain seed buffer =================
    logic signed [63:0] sb_rbeg [NS];
    logic signed [31:0] sb_qbeg [NS], sb_len [NS], sb_score [NS];

    // ================= orchestration =================
    logic [15:0] nsurv, k, cidx, sidx, scnt, nsd, qi, rid_k;
    logic signed [63:0] rmax0_k, rmax1_k;
    typedef enum logic [4:0] {
        E_IDLE, E_CH_RUN, E_CH_WAIT, E_RSTART, E_RDY0, E_QREP,
        E_K_CIDX, E_K_META, E_K_WALK, E_K_RMAXRUN, E_K_RMAXWAIT,
        E_K_REFREQ, E_K_SLOAD, E_K_GO, E_K_GOWAIT, E_K_NEXT,
        E_FINISH, E_AXI, E_DONE, E_DONE_FB
    } st_t;
    st_t state;
    assign busy = (state != E_IDLE);
    assign ref_rbeg = rmax0_k;
    assign ref_len  = (rmax1_k - rmax0_k);
    assign ref_req  = (state == E_K_REFREQ);

    // ---- chaining_top read ports (driven by the walk) ----
    always_comb begin
        ct_rd_idx  = k;
        ct_rd_cidx = cidx;
        ct_rd_sidx = sidx;
    end

    // ---- chain2aln_setup loads (driven during the walk) ----
    always_comb begin
        c2_ld_en=1'b0; c2_ld_idx=16'd0; c2_ld_rbeg=64'sd0; c2_ld_qbeg=32'sd0; c2_ld_len=32'sd0;
        c2_nin=nsd; c2_start=(state==E_K_RMAXRUN);
        if (state==E_K_WALK) begin
            c2_ld_en=1'b1; c2_ld_idx=scnt; c2_ld_rbeg=ct_s_rbeg; c2_ld_qbeg=ct_s_qbeg; c2_ld_len=ct_s_len;
        end
    end

    // ---- accel_top loads / control ----
    logic [15:0] sload_i;     // index for replaying seeds into accel
    always_comb begin
        ac_read_start = (state==E_RSTART);
        ac_read_finish= (state==E_FINISH);
        ac_q_ld_en=1'b0; ac_q_ld_addr=16'd0; ac_q_ld_data='0;
        ac_r_ld_en=1'b0; ac_r_ld_addr=16'd0; ac_r_ld_data='0;
        ac_s_ld_en=1'b0; ac_s_ld_idx=8'd0; ac_s_ld_rbeg=64'sd0; ac_s_ld_qbeg=32'sd0; ac_s_ld_len=32'sd0; ac_s_ld_score=32'sd0;
        ac_ch_go=(state==E_K_GO);
        ac_ch_n=nsd[7:0]; ac_ch_rid=rid_k; ac_ch_rmax0=rmax0_k; ac_ch_rmax1=rmax1_k;
        if (state==E_QREP) begin ac_q_ld_en=1'b1; ac_q_ld_addr=qi; ac_q_ld_data=q_buf[qi]; end
        if (state==E_K_REFREQ) begin                 // forward host ref bytes to accel
            ac_r_ld_en=ref_in_en; ac_r_ld_addr=ref_in_addr; ac_r_ld_data=ref_in_data;
        end
        if (state==E_K_SLOAD) begin
            ac_s_ld_en=1'b1; ac_s_ld_idx=sload_i[7:0];
            ac_s_ld_rbeg=sb_rbeg[sload_i]; ac_s_ld_qbeg=sb_qbeg[sload_i]; ac_s_ld_len=sb_len[sload_i]; ac_s_ld_score=sb_score[sload_i];
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state<=E_IDLE; done<=1'b0; fallback<=1'b0; ct_start<=1'b0;
        end else begin
            done<=1'b0; ct_start<=1'b0;
            case (state)
                E_IDLE: if (start) begin fallback<=1'b0; ct_start<=1'b1; state<=E_CH_RUN; end

                E_CH_RUN: state<=E_CH_WAIT;
                E_CH_WAIT: if (ct_done) begin
                    if (ct_fallback) begin fallback<=1'b1; state<=E_DONE_FB; end
                    else begin nsurv<=ct_nout; state<=E_RSTART; end
                end

                E_RSTART: state<=E_RDY0;                 // read_start pulsed via comb
                E_RDY0: if (ac_ch_ready) begin qi<=16'd0; state<=E_QREP; end
                E_QREP: if (qi + 16'd1 >= l_query[15:0]) begin k<=16'd0; state<=E_K_CIDX; end
                        else qi<=qi+16'd1;

                // ----- per surviving chain k -----
                E_K_CIDX: begin                          // cidx = surviving chain index
                    if (k >= nsurv) state<=E_FINISH;
                    else begin cidx<=ct_o_cidx; state<=E_K_META; end
                end
                E_K_META: begin                          // latch rid/nseeds/head (rd_cidx=cidx)
                    rid_k<=ct_o_rid[15:0]; nsd<=ct_o_nseeds; sidx<=ct_o_head; scnt<=16'd0;
                    state<=E_K_WALK;
                end
                E_K_WALK: begin                          // buffer seed scnt; feed chain2aln (comb)
                    sb_rbeg[scnt]<=ct_s_rbeg; sb_qbeg[scnt]<=ct_s_qbeg; sb_len[scnt]<=ct_s_len; sb_score[scnt]<=ct_s_score;
                    sidx<=ct_s_next;
                    if (scnt + 16'd1 >= nsd) state<=E_K_RMAXRUN;
                    else scnt<=scnt+16'd1;
                end
                E_K_RMAXRUN: state<=E_K_RMAXWAIT;        // c2 start pulsed via comb
                E_K_RMAXWAIT: if (c2_done) begin rmax0_k<=c2_rmax0; rmax1_k<=c2_rmax1; state<=E_K_REFREQ; end

                E_K_REFREQ: if (ref_in_done) begin sload_i<=16'd0; state<=E_K_SLOAD; end

                E_K_SLOAD: if (sload_i + 16'd1 >= nsd) state<=E_K_GO;
                           else sload_i<=sload_i+16'd1;

                E_K_GO: state<=E_K_GOWAIT;               // ch_go pulsed via comb
                E_K_GOWAIT: if (ac_ch_ready) state<=E_K_NEXT;
                E_K_NEXT: begin k<=k+16'd1; state<=E_K_CIDX; end

                E_FINISH: state<=E_AXI;                  // read_finish pulsed via comb
                E_AXI: if (ac_done) begin
                    if (ac_fallback) fallback<=1'b1;
                    state<=E_DONE;
                end

                E_DONE:    begin done<=1'b1; state<=E_IDLE; end
                E_DONE_FB: begin done<=1'b1; state<=E_IDLE; end
                default: state<=E_IDLE;
            endcase
        end
    end
endmodule
