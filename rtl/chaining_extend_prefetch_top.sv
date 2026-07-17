// chaining_extend_prefetch_top.sv — Decision D2 (cross-chain prefetch), the remaining latency overlap
// named in docs/genome_fetch_options.md. Drop-in variant of chaining_extend_top with IDENTICAL ports
// and IDENTICAL output (verified bit-exact vs the same golden), but the per-chain work is split into a
// PRODUCER and a CONSUMER around a 2-slot ping-pong window buffer:
//
//   PRODUCER: for each chain, walk seeds -> rmax (chain2aln_setup) -> clamp (bns_clamp_top) ->
//             fetch the window (ref_req/ref_in_*) INTO a free slot. Runs AHEAD of the consumer.
//   CONSUMER: for each chain in order, load the ready slot's window + seeds into accel and ch_go,
//             wait ch_ready, free the slot.
//
// So the HBM fetch of chain k+1 overlaps the Smith-Waterman of chain k: the fetch latency (already
// amortised per-window by the D2-pipelined ref_fetch_top) is lifted off the critical path. The
// production pipeline (chaining_extend_top) is UNCHANGED; this variant is proven in isolation and can
// be swapped in once synthesis/real-HW numbers justify it.
//
// Correctness note: the byte stream and the accel drive are exactly the sequential module's, just
// re-timed and sourced from the slot buffer — so the output is bit-exact. rid stays from the chain
// (== the clamp's rid on faithful data). Fallback stays stage-specific (fb_chain / fb_sort).
`include "bsw_pkg.sv"
`include "msort_v2_pkg.sv"

module chaining_extend_prefetch_top
    import bsw_pkg::*;
    import msort_v2_pkg::*;
#(
    parameter int NCHAIN = 64,
    parameter int NSEED  = 64,
    parameter int NQ     = 512,
    parameter int NS     = 64,
    parameter int NCTG   = 8,
    parameter int NREF   = 1024    // max reference-window bytes per slot (measured max 811)
)(
    input  logic               clk,
    input  logic               rst_n,
    input  logic signed [31:0] w, max_chain_gap, min_seed_len, max_chain_extend,
    input  logic signed [31:0] a, o_del, e_del, o_ins, e_ins, zdrop, pen5, pen3, l_query,
    input  logic signed [63:0] l_pac,
    input  logic               ld_en,
    input  logic [15:0]        ld_idx,
    input  logic signed [63:0] ld_rbeg,
    input  logic signed [31:0] ld_qbeg, ld_len, ld_score, ld_rid, ld_isalt,
    input  logic               q_ld_en,
    input  logic [15:0]        q_ld_addr,
    input  base_t              q_ld_data,
    input  logic               start,
    input  logic [15:0]        n_in,
    output logic               busy,
    output logic               done,
    output logic               fallback,
    output logic               fb_chain,
    output logic               fb_sort,
    output logic               ref_req,
    output logic signed [63:0] ref_rbeg,
    output logic [15:0]        ref_len,
    input  logic               ref_in_en,
    input  logic [15:0]        ref_in_addr,
    input  base_t              ref_in_data,
    input  logic               ref_in_done,
    input  logic               ctab_we,
    input  logic [15:0]        ctab_idx,
    input  logic signed [63:0] ctab_offset,
    input  logic signed [63:0] ctab_len,
    input  logic [15:0]        ctab_n,
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

    // ================= chain2aln_setup (rmax) — producer =================
    logic c2_ld_en; logic [15:0] c2_ld_idx; logic signed [63:0] c2_ld_rbeg; logic signed [31:0] c2_ld_qbeg, c2_ld_len;
    logic c2_start; logic [15:0] c2_nin; logic c2_busy, c2_done; logic signed [63:0] c2_rmax0, c2_rmax1;
    chain2aln_setup #(.NSEED(NS)) u_c2 (.clk,.rst_n,
        .a,.o_del,.e_del,.o_ins,.e_ins,.wband(w),.l_query,.l_pac,
        .ld_en(c2_ld_en),.ld_idx(c2_ld_idx),.ld_rbeg(c2_ld_rbeg),.ld_qbeg(c2_ld_qbeg),.ld_len(c2_ld_len),
        .start(c2_start),.n_in(c2_nin),.busy(c2_busy),.done(c2_done),.rmax0(c2_rmax0),.rmax1(c2_rmax1));

    // ================= producer / consumer state =================
    // per-chain seed buffer (2 slots), window buffer (2 slots), and per-slot metadata
    logic signed [63:0] sb_rbeg [2][NS];
    logic signed [31:0] sb_qbeg [2][NS], sb_len [2][NS], sb_score [2][NS];
    base_t              win_buf [2][NREF];
    logic [15:0]        slot_n   [2], slot_rid [2], slot_wlen [2];
    logic signed [63:0] slot_r0  [2], slot_r1  [2];
    logic               slot_full[2];

    // producer regs
    logic [15:0] kp, cidx_p, sidx_p, scnt_p, nsd_p, rid_p;
    logic signed [63:0] r0_p, r1_p;
    // consumer regs
    logic [15:0] kc, sload_i, rload_i, qi;
    // read-level regs
    logic [15:0] nsurv;

    // ================= bns_clamp_top (contig clamp) — producer =================
    logic               clp_start, clp_done, clp_isrev;
    logic signed [63:0] clp_beg, clp_end, clp_ol;
    logic [31:0]        clp_rid;
    bns_clamp_top #(.NCTG(NCTG)) u_clp (.clk, .rst_n,
        .tbl_we(ctab_we), .tbl_idx(ctab_idx), .tbl_offset(ctab_offset), .tbl_len(ctab_len),
        .n_seqs(ctab_n), .l_pac(l_pac),
        .start(clp_start), .beg_in(r0_p), .midpos(sb_rbeg[kp[0]][0]), .end_in(r1_p),
        .done(clp_done), .beg_out(clp_beg), .end_out(clp_end),
        .rid(clp_rid), .is_rev(clp_isrev), .out_len(clp_ol));
    logic _unused_clp; assign _unused_clp = ^{clp_rid, clp_isrev, clp_ol};

    // ================= accel_top (extension + sort) — consumer =================
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

    // ================= FSMs =================
    // top-level phase; producer (pst) and consumer (cst) run concurrently during PH_LOOP
    typedef enum logic [3:0] { PH_IDLE, PH_CH_RUN, PH_CH_WAIT, PH_RSTART, PH_RDY0, PH_QREP,
                               PH_LOOP, PH_FINISH, PH_AXI, PH_DONE, PH_DONE_FB } ph_t;
    typedef enum logic [3:0] { P_IDLE, P_META, P_WALK, P_RMAXRUN, P_RMAXWAIT,
                               P_CLAMPRUN, P_CLAMPWAIT, P_REFREQ, P_COMMIT, P_DONE } pst_t;
    typedef enum logic [2:0] { C_IDLE, C_RLOAD, C_SLOAD, C_GO, C_GOWAIT, C_FREE, C_DONE } cst_t;
    ph_t  phase;
    pst_t pst;
    cst_t cst;

    assign busy     = (phase != PH_IDLE);
    assign fallback = fb_chain | fb_sort;
    assign ref_rbeg = r0_p;
    assign ref_len  = (r1_p - r0_p);
    assign ref_req  = (phase == PH_LOOP && pst == P_REFREQ);

    assign ct_rd_idx  = kp;
    assign ct_rd_cidx = cidx_p;
    assign ct_rd_sidx = sidx_p;

    // producer feeds chain2aln during its walk
    always_comb begin
        c2_ld_en=1'b0; c2_ld_idx=16'd0; c2_ld_rbeg=64'sd0; c2_ld_qbeg=32'sd0; c2_ld_len=32'sd0;
        c2_nin=nsd_p; c2_start=(phase==PH_LOOP && pst==P_RMAXRUN);
        if (phase==PH_LOOP && pst==P_WALK) begin
            c2_ld_en=1'b1; c2_ld_idx=scnt_p; c2_ld_rbeg=ct_s_rbeg; c2_ld_qbeg=ct_s_qbeg; c2_ld_len=ct_s_len;
        end
    end
    assign clp_start = (phase==PH_LOOP && pst==P_CLAMPRUN);

    // consumer drives accel
    always_comb begin
        ac_read_start = (phase==PH_RSTART);
        ac_read_finish= (phase==PH_FINISH);
        ac_q_ld_en=1'b0; ac_q_ld_addr=16'd0; ac_q_ld_data='0;
        ac_r_ld_en=1'b0; ac_r_ld_addr=16'd0; ac_r_ld_data='0;
        ac_s_ld_en=1'b0; ac_s_ld_idx=8'd0; ac_s_ld_rbeg=64'sd0; ac_s_ld_qbeg=32'sd0; ac_s_ld_len=32'sd0; ac_s_ld_score=32'sd0;
        ac_ch_go=(phase==PH_LOOP && cst==C_GO);
        ac_ch_n=slot_n[kc[0]][7:0]; ac_ch_rid={{16{1'b0}},slot_rid[kc[0]]}; ac_ch_rmax0=slot_r0[kc[0]]; ac_ch_rmax1=slot_r1[kc[0]];
        if (phase==PH_QREP) begin ac_q_ld_en=1'b1; ac_q_ld_addr=qi; ac_q_ld_data=q_buf[qi]; end
        if (phase==PH_LOOP && cst==C_RLOAD) begin
            ac_r_ld_en=1'b1; ac_r_ld_addr=rload_i; ac_r_ld_data=win_buf[kc[0]][rload_i];
        end
        if (phase==PH_LOOP && cst==C_SLOAD) begin
            ac_s_ld_en=1'b1; ac_s_ld_idx=sload_i[7:0];
            ac_s_ld_rbeg=sb_rbeg[kc[0]][sload_i]; ac_s_ld_qbeg=sb_qbeg[kc[0]][sload_i];
            ac_s_ld_len=sb_len[kc[0]][sload_i]; ac_s_ld_score=sb_score[kc[0]][sload_i];
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            phase<=PH_IDLE; pst<=P_IDLE; cst<=C_IDLE; done<=1'b0; fb_chain<=1'b0; fb_sort<=1'b0; ct_start<=1'b0;
            slot_full[0]<=1'b0; slot_full[1]<=1'b0;
        end else begin
            done<=1'b0; ct_start<=1'b0;

            // ---------- top-level phase ----------
            case (phase)
                PH_IDLE: if (start) begin fb_chain<=1'b0; fb_sort<=1'b0; ct_start<=1'b1; phase<=PH_CH_RUN; end
                PH_CH_RUN: phase<=PH_CH_WAIT;
                PH_CH_WAIT: if (ct_done) begin
                    if (ct_fallback) begin fb_chain<=1'b1; phase<=PH_DONE_FB; end
                    else begin nsurv<=ct_nout; phase<=PH_RSTART; end
                end
                PH_RSTART: phase<=PH_RDY0;
                PH_RDY0: if (ac_ch_ready) begin qi<=16'd0; phase<=PH_QREP; end
                PH_QREP: if (qi + 16'd1 >= l_query[15:0]) begin
                            kp<=16'd0; kc<=16'd0; pst<=P_IDLE; cst<=C_IDLE;
                            slot_full[0]<=1'b0; slot_full[1]<=1'b0; phase<=PH_LOOP;
                         end else qi<=qi+16'd1;
                PH_LOOP: if (cst==C_DONE) phase<=PH_FINISH;    // consumer drained every chain
                PH_FINISH: phase<=PH_AXI;
                PH_AXI: if (ac_done) begin if (ac_fallback) fb_sort<=1'b1; phase<=PH_DONE; end
                PH_DONE:    begin done<=1'b1; phase<=PH_IDLE; end
                PH_DONE_FB: begin done<=1'b1; phase<=PH_IDLE; end
                default: phase<=PH_IDLE;
            endcase

            // ---------- producer (prepare + fetch chain kp into slot kp[0]) ----------
            if (phase==PH_LOOP) begin
                case (pst)
                    P_IDLE: if (kp >= nsurv) pst<=P_DONE;
                            else if (!slot_full[kp[0]]) begin
                                cidx_p<=ct_o_cidx; pst<=P_META;   // ct_rd_idx=kp -> o_cidx valid
                            end
                    P_META: begin rid_p<=ct_o_rid[15:0]; nsd_p<=ct_o_nseeds; sidx_p<=ct_o_head; scnt_p<=16'd0; pst<=P_WALK; end
                    P_WALK: begin
                        sb_rbeg[kp[0]][scnt_p]<=ct_s_rbeg; sb_qbeg[kp[0]][scnt_p]<=ct_s_qbeg;
                        sb_len[kp[0]][scnt_p]<=ct_s_len; sb_score[kp[0]][scnt_p]<=ct_s_score;
                        sidx_p<=ct_s_next;
                        if (scnt_p + 16'd1 >= nsd_p) pst<=P_RMAXRUN; else scnt_p<=scnt_p+16'd1;
                    end
                    P_RMAXRUN: pst<=P_RMAXWAIT;
                    P_RMAXWAIT: if (c2_done) begin r0_p<=c2_rmax0; r1_p<=c2_rmax1; pst<=P_CLAMPRUN; end
                    P_CLAMPRUN: pst<=P_CLAMPWAIT;
                    P_CLAMPWAIT: if (clp_done) begin r0_p<=clp_beg; r1_p<=clp_end; pst<=P_REFREQ; end
                    P_REFREQ: begin
                        if (ref_in_en) win_buf[kp[0]][ref_in_addr]<=ref_in_data;
                        if (ref_in_done) pst<=P_COMMIT;
                    end
                    P_COMMIT: begin
                        slot_n[kp[0]]<=nsd_p; slot_rid[kp[0]]<=rid_p;
                        slot_r0[kp[0]]<=r0_p; slot_r1[kp[0]]<=r1_p; slot_wlen[kp[0]]<=(r1_p-r0_p);
                        slot_full[kp[0]]<=1'b1;
                        kp<=kp+16'd1; pst<=P_IDLE;
                    end
                    P_DONE: ;    // idle until the read finishes
                    default: pst<=P_IDLE;
                endcase
            end

            // ---------- consumer (drain slot kc[0] into accel) ----------
            if (phase==PH_LOOP) begin
                case (cst)
                    C_IDLE: if (kc >= nsurv) cst<=C_DONE;
                            else if (slot_full[kc[0]]) begin
                                rload_i<=16'd0; sload_i<=16'd0;
                                cst<=(slot_wlen[kc[0]]==16'd0) ? C_SLOAD : C_RLOAD;  // empty window -> skip r_ld
                            end
                    C_RLOAD: if (rload_i + 16'd1 >= slot_wlen[kc[0]]) cst<=C_SLOAD; else rload_i<=rload_i+16'd1;
                    C_SLOAD: if (sload_i + 16'd1 >= slot_n[kc[0]]) cst<=C_GO; else sload_i<=sload_i+16'd1;
                    C_GO: cst<=C_GOWAIT;
                    C_GOWAIT: if (ac_ch_ready) cst<=C_FREE;
                    C_FREE: begin slot_full[kc[0]]<=1'b0; kc<=kc+16'd1; cst<=C_IDLE; end
                    C_DONE: ;    // handled by the phase FSM (-> PH_FINISH)
                    default: cst<=C_IDLE;
                endcase
            end
        end
    end
endmodule
