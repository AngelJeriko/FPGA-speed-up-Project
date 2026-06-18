// orch_purge.sv
// Cross-chain redundancy purge for the extend-orchestrator. Mirrors the
// "discard redundant seeds" loop at the end of mem_chain2aln_across_reads_V2
// (orch.h purge(), with the proven integer-only surrogates — see ksw.h
// cal_max_gap_int and the *10 / *100/*95 seed-length gates).
//
// One read at a time. The host/TB pre-loads, via the *_ld_* ports:
//   - av[]  : the pre-purge alnregs (rb,re,qb,qe,w,seedlen0), append order
//   - sd[]  : all the read's seeds (rbeg,qbeg,len,score), grouped by chain
//   - ch[]  : per-chain table {sbase (seed-buffer base), n (seed count),
//             abase (av base = index of this chain's first alnreg)}
// Then `start` runs the purge; purged alnregs get qb=qe=-1 in place. The TB reads
// them back via rd_idx -> rd_qb/rd_qe.
//
// Key identities (see memory/extend-orchestrator):
//   - seeds/read == alnregs/read (one alnreg per seed) <= 886, so NAV/NSD = 1024.
//   - the av index of chain cj's seed at descending position k is abase+(n-1-k)
//     (extend_only appends k=n-1..0), so no seed_aln table is needed.
//   - srt2 = per-chain seeds sorted ASCENDING by (score<<32|i); processed k=n-1..0.

module orch_purge #(
    parameter int NAV     = 1024,
    parameter int NSD     = 1024,
    parameter int NCH     = 1024,
    parameter int MAXSEED = 128
)(
    input  logic               clk,
    input  logic               rst_n,

    // ---- loads (before start) ----
    input  logic               av_ld_en,
    input  logic [15:0]        av_ld_idx,
    input  logic signed [63:0] av_ld_rb,
    input  logic signed [63:0] av_ld_re,
    input  logic signed [31:0] av_ld_qb,
    input  logic signed [31:0] av_ld_qe,
    input  logic signed [31:0] av_ld_w,
    input  logic signed [31:0] av_ld_sl0,

    input  logic               sd_ld_en,
    input  logic [15:0]        sd_ld_idx,
    input  logic signed [63:0] sd_ld_rbeg,
    input  logic signed [31:0] sd_ld_qbeg,
    input  logic signed [31:0] sd_ld_len,
    input  logic signed [31:0] sd_ld_score,

    input  logic               ch_ld_en,
    input  logic [15:0]        ch_ld_idx,
    input  logic [15:0]        ch_ld_sbase,
    input  logic [15:0]        ch_ld_n,
    input  logic [15:0]        ch_ld_abase,

    // ---- cfg + request ----
    input  logic               start,
    input  logic [15:0]        nav,
    input  logic [15:0]        nchain,
    input  logic signed [31:0] a, o_del, e_del, o_ins, e_ins, wcfg, l_query,

    // ---- status + readback ----
    output logic               busy,
    output logic               done,
    input  logic [15:0]        rd_idx,
    output logic signed [31:0] rd_qb,
    output logic signed [31:0] rd_qe
);
    // ---- storage ----
    logic signed [63:0] av_rb [NAV], av_re [NAV];
    logic signed [31:0] av_qb [NAV], av_qe [NAV], av_w [NAV], av_sl0 [NAV];
    logic signed [63:0] sd_rbeg [NSD];
    logic signed [31:0] sd_qbeg [NSD], sd_len [NSD], sd_score [NSD];
    logic [15:0]        ch_sbase [NCH], ch_n [NCH], ch_abase [NCH];

    always_ff @(posedge clk) begin
        if (av_ld_en) begin
            av_rb[av_ld_idx]<=av_ld_rb; av_re[av_ld_idx]<=av_ld_re;
            av_qb[av_ld_idx]<=av_ld_qb; av_qe[av_ld_idx]<=av_ld_qe;
            av_w[av_ld_idx]<=av_ld_w;   av_sl0[av_ld_idx]<=av_ld_sl0;
        end
        if (sd_ld_en) begin
            sd_rbeg[sd_ld_idx]<=sd_ld_rbeg; sd_qbeg[sd_ld_idx]<=sd_ld_qbeg;
            sd_len[sd_ld_idx]<=sd_ld_len;   sd_score[sd_ld_idx]<=sd_ld_score;
        end
        if (ch_ld_en) begin
            ch_sbase[ch_ld_idx]<=ch_ld_sbase; ch_n[ch_ld_idx]<=ch_ld_n;
            ch_abase[ch_ld_idx]<=ch_ld_abase;
        end
    end

    assign rd_qb = av_qb[rd_idx];
    assign rd_qe = av_qe[rd_idx];

    // ---- latched cfg ----
    logic signed [31:0] a_r,od_r,ed_r,oi_r,ei_r,w_r,lq_r;
    logic [15:0]        nav_r, nch_r;

    function automatic logic signed [31:0] cmg(input logic signed [31:0] qlen);
        logic signed [31:0] ld, li, l, w2;
        ld = (qlen*a_r - od_r + ed_r) / ed_r;   // == (int)((double)(qlen*a-o_del)/e_del + 1.)
        li = (qlen*a_r - oi_r + ei_r) / ei_r;
        l  = (ld > li) ? ld : li;
        l  = (l  > 1)  ? l  : 32'sd1;
        w2 = w_r <<< 1;
        cmg = (l < w2) ? l : w2;
    endfunction

    // ---- working state ----
    logic [15:0]        lim, cj;
    logic [15:0]        n_r, sbase_r, abase_r;
    logic [7:0]         srt2 [MAXSEED];
    logic [MAXSEED-1:0] srt_inv, used;
    logic [7:0]         slot, scan_i, best_i;
    logic signed [31:0] best_sc; logic best_set;
    logic signed [15:0] k;                 // seed pos, n-1..0 (signed for the -1 test)
    logic [7:0]         sidx;
    logic signed [63:0] s_rbeg; logic signed [31:0] s_qbeg, s_len;
    logic [15:0]        v, i;
    logic signed [15:0] vv; logic vv_broke;

    // ---- combinational view of av[i] vs current seed s (inner scan) ----
    logic signed [63:0] p_rb, p_re; logic signed [31:0] p_qb, p_qe, p_w, p_sl0;
    logic purged_i, contained_i, toolong_i, bandL_i, bandR_i;
    logic signed [63:0] qdL, rdL, qdR, rdR;
    logic signed [31:0] minL, minR, wL, wR;
    always_comb begin
        p_rb=av_rb[i]; p_re=av_re[i]; p_qb=av_qb[i]; p_qe=av_qe[i]; p_w=av_w[i]; p_sl0=av_sl0[i];
        purged_i   = (p_qb == -32'sd1) && (p_qe == -32'sd1);
        contained_i= (s_rbeg >= p_rb) && ((s_rbeg + 64'(s_len)) <= p_re) &&
                     (s_qbeg >= p_qb) && ((s_qbeg + s_len)      <= p_qe);
        toolong_i  = ((s_len - p_sl0) * 32'sd10) > lq_r;
        qdL = 64'(s_qbeg) - 64'(p_qb);
        rdL = s_rbeg - p_rb;
        minL = (qdL < rdL) ? qdL[31:0] : rdL[31:0];
        wL = (cmg(minL) < p_w) ? cmg(minL) : p_w;
        bandL_i = ((qdL - rdL) < 64'(wL)) && ((rdL - qdL) < 64'(wL));
        qdR = 64'(p_qe) - (64'(s_qbeg) + 64'(s_len));
        rdR = p_re - (s_rbeg + 64'(s_len));
        minR = (qdR < rdR) ? qdR[31:0] : rdR[31:0];
        wR = (cmg(minR) < p_w) ? cmg(minR) : p_w;
        bandR_i = ((qdR - rdR) < 64'(wR)) && ((rdR - qdR) < 64'(wR));
    end

    // ---- combinational view of seed t (vv conflict scan) ----
    logic signed [63:0] t_rbeg; logic signed [31:0] t_qbeg, t_len;
    logic vv_short, vv_c1, vv_c2;
    always_comb begin
        t_rbeg = sd_rbeg[sbase_r + srt2[vv[7:0]]];
        t_qbeg = sd_qbeg[sbase_r + srt2[vv[7:0]]];
        t_len  = sd_len [sbase_r + srt2[vv[7:0]]];
        vv_short = (t_len * 32'sd100) < (s_len * 32'sd95);
        vv_c1 = (s_qbeg <= t_qbeg) &&
                ((s_qbeg + s_len - t_qbeg) >= (s_len >>> 2)) &&
                ((64'(t_qbeg) - 64'(s_qbeg)) != (t_rbeg - s_rbeg));
        vv_c2 = (t_qbeg <= s_qbeg) &&
                ((t_qbeg + t_len - s_qbeg) >= (s_len >>> 2)) &&
                ((64'(s_qbeg) - 64'(t_qbeg)) != (s_rbeg - t_rbeg));
    end

    typedef enum logic [4:0] {
        S_IDLE, S_CH_START, S_SORT_SCAN, S_SORT_PLACE, S_K_INIT, S_K_SETUP,
        S_SCAN, S_AFTER, S_VV_INIT, S_VV, S_VV_DONE, S_K_DEC, S_CH_NEXT, S_DONE
    } st_t;
    st_t state;
    assign busy = (state != S_IDLE);

    wire [15:0] aidx = abase_r + (n_r - 16'd1 - k[15:0]);  // av index for seed at pos k

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state <= S_IDLE; done <= 1'b0;
        end else begin
            done <= 1'b0;
            case (state)
                S_IDLE: if (start) begin
                    a_r<=a; od_r<=o_del; ed_r<=e_del; oi_r<=o_ins; ei_r<=e_ins;
                    w_r<=wcfg; lq_r<=l_query; nav_r<=nav; nch_r<=nchain;
                    lim<=16'd0; cj<=16'd0;
                    state <= S_CH_START;
                end
                S_CH_START: begin
                    n_r     <= ch_n[cj];
                    sbase_r <= ch_sbase[cj];
                    abase_r <= ch_abase[cj];
                    used <= '0; srt_inv <= '0; slot<=8'd0; scan_i<=8'd0;
                    best_set<=1'b0; best_sc<=32'sd0; best_i<=8'd0;
                    state <= S_SORT_SCAN;
                end
                // ascending selection sort by (score, then index): min wins, ties->min idx
                S_SORT_SCAN: begin
                    if (scan_i == n_r[7:0]) state <= S_SORT_PLACE;
                    else begin
                        if (!used[scan_i] &&
                            (!best_set || $signed(sd_score[sbase_r+scan_i]) < best_sc)) begin
                            best_sc  <= $signed(sd_score[sbase_r+scan_i]);
                            best_i   <= scan_i;
                            best_set <= 1'b1;
                        end
                        scan_i <= scan_i + 8'd1;
                    end
                end
                S_SORT_PLACE: begin
                    srt2[slot] <= best_i;
                    used[best_i] <= 1'b1;
                    slot <= slot + 8'd1;
                    scan_i<=8'd0; best_set<=1'b0; best_sc<=32'sd0; best_i<=8'd0;
                    if (slot + 8'd1 == n_r[7:0]) state <= S_K_INIT;
                    else state <= S_SORT_SCAN;
                end
                S_K_INIT: begin k <= $signed(n_r) - 16'sd1; state <= S_K_SETUP; end
                S_K_SETUP: begin
                    sidx   <= srt2[k[7:0]];
                    s_rbeg <= sd_rbeg[sbase_r + srt2[k[7:0]]];
                    s_qbeg <= sd_qbeg[sbase_r + srt2[k[7:0]]];
                    s_len  <= sd_len [sbase_r + srt2[k[7:0]]];
                    v <= 16'd0; i <= 16'd0;
                    state <= S_SCAN;
                end
                S_SCAN: begin
                    if (i >= nav_r || v >= lim) state <= S_AFTER;
                    else if (purged_i)          i <= i + 16'd1;
                    else if (!contained_i)      begin v<=v+16'd1; i<=i+16'd1; end
                    else if (toolong_i)         begin v<=v+16'd1; i<=i+16'd1; end
                    else if (bandL_i)           state <= S_AFTER;        // break (redundant)
                    else if (bandR_i)           state <= S_AFTER;        // break
                    else                        begin v<=v+16'd1; i<=i+16'd1; end
                end
                S_AFTER: begin
                    if (v < lim) begin vv <= k + 16'sd1; vv_broke<=1'b0; state<=S_VV_INIT; end
                    else         begin lim <= lim + 16'd1; state <= S_K_DEC; end
                end
                S_VV_INIT: state <= S_VV;     // vv was latched in S_AFTER
                S_VV: begin
                    if (vv >= $signed(n_r))      state <= S_VV_DONE;     // vv==n, completed
                    else if (srt_inv[vv[7:0]])   vv <= vv + 16'sd1;      // continue (INVALID)
                    else if (vv_short)           vv <= vv + 16'sd1;      // continue
                    else if (vv_c1)              begin vv_broke<=1'b1; state<=S_VV_DONE; end
                    else if (vv_c2)              begin vv_broke<=1'b1; state<=S_VV_DONE; end
                    else                         vv <= vv + 16'sd1;
                end
                S_VV_DONE: begin
                    if (!vv_broke) begin                                 // vv==n -> purge
                        av_qb[aidx] <= -32'sd1;
                        av_qe[aidx] <= -32'sd1;
                        srt_inv[k[7:0]] <= 1'b1;
                    end else begin
                        lim <= lim + 16'd1;
                    end
                    state <= S_K_DEC;
                end
                S_K_DEC: begin
                    if (k == 16'sd0) state <= S_CH_NEXT;
                    else begin k <= k - 16'sd1; state <= S_K_SETUP; end
                end
                S_CH_NEXT: begin
                    if (cj + 16'd1 == nch_r) state <= S_DONE;
                    else begin cj <= cj + 16'd1; state <= S_CH_START; end
                end
                S_DONE: begin done <= 1'b1; state <= S_IDLE; end
                default: state <= S_IDLE;
            endcase
        end
    end
endmodule
