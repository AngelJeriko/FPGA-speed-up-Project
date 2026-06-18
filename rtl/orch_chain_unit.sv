// orch_chain_unit.sv
// Per-chain extension sequencer for the extend-orchestrator. Given one chain
// (its seeds + reference window, with the read's query already loaded), it
// reproduces mem_chain2aln_across_reads_V2's per-chain work and streams out the
// chain's pre-purge alnregs in append order:
//
//   1. sort the chain's seeds by ksw key (score<<32 | i) DESCENDING
//      (ties -> higher seed index first), matching ks_introsort_64 + the
//      k = n-1..0 reverse walk in bwamem.cpp.
//   2. for each seed in that order: run bsw_seed_unit (left+right SW + assemble)
//      -> the alnreg coords/score; then stream ALL chain seeds through
//      orch_seedcov with those final coords -> seedcov (a sum, order-independent).
//   3. emit {rb,re,qb,qe,score,truesc,w,seedcov,seedlen0,rid} (the full type-2
//      record) with out_last on the final seed.
//
// Memories: the read's query and the chain's reference window are written into
// the inner bsw_seed_unit via the ld_* passthrough BEFORE `start` (query once per
// read, ref once per chain). The chain's seeds are written into the local seed
// buffer via sld_* before `start`. Verified vs extend_only() per-chain (HW model).

`include "bsw_pkg.sv"

module orch_chain_unit
    import bsw_pkg::*;
#(
    parameter int MAXSEED = 128
)(
    input  logic               clk,
    input  logic               rst_n,

    // ---- passthrough load of the inner bsw_seed_unit memories ----
    input  logic               ld_en,
    input  logic               ld_sel,        // 0=query, 1=ref
    input  logic [15:0]        ld_addr,
    input  base_t              ld_data,

    // ---- seed buffer load ----
    input  logic               sld_en,
    input  logic [7:0]         sld_idx,
    input  logic signed [63:0] sld_rbeg,
    input  logic signed [31:0] sld_qbeg,
    input  logic signed [31:0] sld_len,
    input  logic signed [31:0] sld_score,

    // ---- request : one chain ----
    input  logic               start,
    input  logic signed [31:0] l_query, a, o_del, e_del, o_ins, e_ins, zdrop, wcfg, pen5, pen3,
    input  logic [7:0]         n_seeds,
    input  logic signed [31:0] rid,
    input  logic signed [63:0] rmax0,
    input  logic signed [63:0] rmax1,

    // ---- output : alnreg stream (append order) ----
    output logic               busy,
    output logic               out_valid,
    output logic               out_last,
    output logic               done,
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
    // ---- seed buffer ----
    logic signed [63:0] sb_rbeg [MAXSEED];
    logic signed [31:0] sb_qbeg [MAXSEED];
    logic signed [31:0] sb_len  [MAXSEED];
    logic signed [31:0] sb_score[MAXSEED];
    always_ff @(posedge clk) begin
        if (sld_en) begin
            sb_rbeg[sld_idx]  <= sld_rbeg;
            sb_qbeg[sld_idx]  <= sld_qbeg;
            sb_len[sld_idx]   <= sld_len;
            sb_score[sld_idx] <= sld_score;
        end
    end

    // ---- latched request ----
    logic signed [31:0] lq_r,a_r,od_r,ed_r,oi_r,ei_r,zd_r,w_r,p5_r,p3_r,rid_r;
    logic signed [63:0] rmax0_r, rmax1_r;
    logic [7:0]         n_r;

    // ---- selection-sort order[] ----
    logic [7:0]         order [MAXSEED];
    logic [MAXSEED-1:0] used;
    logic [7:0]         sort_k;            // output position
    logic [7:0]         scan_i;            // scan cursor
    logic [7:0]         best_i;
    logic signed [31:0] best_sc;
    logic               best_set;

    // ---- inner bsw_seed_unit ----
    logic               u_start, u_busy, u_done;
    logic signed [31:0] u_qbeg, u_len;
    logic signed [63:0] u_rbeg;
    logic signed [63:0] u_rb, u_re;
    logic signed [31:0] u_qb, u_qe, u_score, u_truesc, u_w, u_rid;
    bsw_seed_unit u_seed (
        .clk(clk), .rst_n(rst_n),
        .ld_en(ld_en), .ld_sel(ld_sel), .ld_addr(ld_addr), .ld_data(ld_data),
        .start(u_start), .l_query(lq_r), .a(a_r), .o_del(od_r), .e_del(ed_r),
        .o_ins(oi_r), .e_ins(ei_r), .zdrop(zd_r), .wcfg(w_r), .pen5(p5_r), .pen3(p3_r),
        .rbeg(u_rbeg), .qbeg(u_qbeg), .len(u_len), .rid(rid_r), .rmax0(rmax0_r), .rmax1(rmax1_r),
        .busy(u_busy), .done_o(u_done),
        .rb(u_rb), .re(u_re), .qb(u_qb), .qe(u_qe),
        .score(u_score), .truesc(u_truesc), .w_out(u_w), .rid_out(u_rid)
    );

    // ---- inner orch_seedcov (control driven combinationally; see FSM/state) ----
    logic               sc_clear, sc_in_valid, sc_in_last, sc_done;
    logic signed [63:0] sc_rb, sc_re, sc_srbeg;
    logic signed [31:0] sc_qb, sc_qe, sc_sqbeg, sc_slen, sc_out;
    orch_seedcov u_sc (
        .clk(clk), .rst_n(rst_n), .clear(sc_clear),
        .qb(sc_qb), .qe(sc_qe), .rb(sc_rb), .re(sc_re),
        .in_valid(sc_in_valid), .s_rbeg(sc_srbeg), .s_qbeg(sc_sqbeg), .s_len(sc_slen),
        .in_last(sc_in_last), .seedcov(sc_out), .done(sc_done)
    );

    // ---- captured current alnreg (between SW done and emit) ----
    logic signed [63:0] cur_rb, cur_re;
    logic signed [31:0] cur_qb, cur_qe, cur_score, cur_truesc, cur_w, cur_rid, cur_seedlen0;
    logic [7:0]         cur_si;
    logic [7:0]         emit_k;            // which sorted seed we're processing
    logic [7:0]         stream_i;          // seedcov stream cursor

    typedef enum logic [3:0] {
        S_IDLE, S_SORT_SCAN, S_SORT_PLACE, S_NEXT, S_EXT, S_EXTW,
        S_SCCLR, S_SCSTREAM, S_SCW, S_EMIT, S_DONE
    } st_t;
    st_t state;

    // seedcov control + data driven combinationally so they align with the seed
    // buffer read (orch_seedcov samples them at the posedge of each stream cycle)
    assign sc_srbeg    = sb_rbeg[stream_i];
    assign sc_sqbeg    = sb_qbeg[stream_i];
    assign sc_slen     = sb_len[stream_i];
    assign sc_qb       = cur_qb;
    assign sc_qe       = cur_qe;
    assign sc_rb       = cur_rb;
    assign sc_re       = cur_re;
    assign sc_clear    = (state == S_SCCLR);
    assign sc_in_valid = (state == S_SCSTREAM);
    assign sc_in_last  = (state == S_SCSTREAM) && (stream_i == n_r - 8'd1);

    assign busy = (state != S_IDLE);

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state <= S_IDLE; done <= 1'b0; out_valid <= 1'b0; out_last <= 1'b0;
            u_start <= 1'b0;
        end else begin
            done <= 1'b0; out_valid <= 1'b0; out_last <= 1'b0;
            u_start <= 1'b0;
            case (state)
                S_IDLE: if (start) begin
                    lq_r<=l_query; a_r<=a; od_r<=o_del; ed_r<=e_del; oi_r<=o_ins; ei_r<=e_ins;
                    zd_r<=zdrop; w_r<=wcfg; p5_r<=pen5; p3_r<=pen3;
                    rid_r<=rid; rmax0_r<=rmax0; rmax1_r<=rmax1; n_r<=n_seeds;
                    used <= '0; sort_k <= 8'd0; scan_i <= 8'd0;
                    best_set <= 1'b0; best_sc <= 32'sh8000_0000; best_i <= 8'd0;
                    state <= S_SORT_SCAN;
                end
                // selection sort: pick max (score, then max index) among unused
                S_SORT_SCAN: begin
                    if (scan_i == n_r) begin
                        state <= S_SORT_PLACE;
                    end else begin
                        if (!used[scan_i] &&
                            (!best_set || $signed(sb_score[scan_i]) >= best_sc)) begin
                            best_sc  <= $signed(sb_score[scan_i]);
                            best_i   <= scan_i;
                            best_set <= 1'b1;
                        end
                        scan_i <= scan_i + 8'd1;
                    end
                end
                S_SORT_PLACE: begin
                    order[sort_k] <= best_i;
                    used[best_i]  <= 1'b1;
                    sort_k        <= sort_k + 8'd1;
                    // reset scan for next position
                    scan_i <= 8'd0; best_set <= 1'b0; best_sc <= 32'sh8000_0000; best_i <= 8'd0;
                    if (sort_k + 8'd1 == n_r) begin emit_k <= 8'd0; state <= S_NEXT; end
                    else state <= S_SORT_SCAN;
                end
                S_NEXT: begin
                    if (emit_k == n_r) state <= S_DONE;
                    else begin
                        cur_si <= order[emit_k];
                        state  <= S_EXT;
                    end
                end
                S_EXT: begin
                    // drive the seed and pulse the per-seed unit
                    u_rbeg <= sb_rbeg[cur_si];
                    u_qbeg <= sb_qbeg[cur_si];
                    u_len  <= sb_len[cur_si];
                    cur_seedlen0 <= sb_len[cur_si];
                    u_start <= 1'b1;
                    state   <= S_EXTW;
                end
                S_EXTW: if (u_done) begin
                    cur_rb<=u_rb; cur_re<=u_re; cur_qb<=u_qb; cur_qe<=u_qe;
                    cur_score<=u_score; cur_truesc<=u_truesc; cur_w<=u_w; cur_rid<=u_rid;
                    state <= S_SCCLR;
                end
                S_SCCLR: begin
                    stream_i <= 8'd0;     // sc_clear is comb (state==S_SCCLR)
                    state <= S_SCSTREAM;
                end
                S_SCSTREAM: begin
                    if (stream_i == n_r - 8'd1) state <= S_SCW;
                    else stream_i <= stream_i + 8'd1;
                end
                S_SCW: if (sc_done) state <= S_EMIT;
                S_EMIT: begin
                    out_valid  <= 1'b1;
                    out_last   <= (emit_k == n_r - 8'd1);
                    o_rb<=cur_rb; o_re<=cur_re; o_qb<=cur_qb; o_qe<=cur_qe;
                    o_score<=cur_score; o_truesc<=cur_truesc; o_w<=cur_w;
                    o_seedcov<=sc_out; o_seedlen0<=cur_seedlen0; o_rid<=cur_rid;
                    emit_k <= emit_k + 8'd1;
                    state  <= S_NEXT;
                end
                S_DONE: begin done <= 1'b1; state <= S_IDLE; end
                default: state <= S_IDLE;
            endcase
        end
    end
endmodule
