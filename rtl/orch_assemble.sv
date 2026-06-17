// orch_assemble.sv
// Alnreg assembly datapath for the extend-orchestrator: given a seed + cfg and
// the left/right banded-SW results (from bsw_top), produce the assembled alnreg
// fields rb/re/qb/qe/score/truesc/w (seedcov is computed in a separate stage —
// it needs the chain seed list). Pure combinational; mirrors the assembly in
// mem_chain2aln_across_reads_V2 (left then right, pen_clip global/local choice).
//
// Verified bit-exact vs the C++ model (host/extend_orchestrator) via
// tb_orch_assemble + vectors/asm_vectors.txt (565,446 alnregs).

module orch_assemble (
    // seed / cfg
    input  logic               need_left,
    input  logic               need_right,
    input  logic signed [31:0] l_query,
    input  logic signed [31:0] a,
    input  logic signed [31:0] w,        // cfg band (opt->w) = a->w init
    input  logic signed [31:0] pen5,
    input  logic signed [31:0] pen3,
    input  logic signed [63:0] rbeg,
    input  logic signed [31:0] qbeg,
    input  logic signed [31:0] len,
    input  logic signed [31:0] rid,
    // left SW result
    input  logic signed [31:0] l_score,
    input  logic signed [31:0] l_qle,
    input  logic signed [31:0] l_tle,
    input  logic signed [31:0] l_gscore,
    input  logic signed [31:0] l_gtle,
    input  logic signed [31:0] l_w,
    // right SW result
    input  logic signed [31:0] r_score,
    input  logic signed [31:0] r_qle,
    input  logic signed [31:0] r_tle,
    input  logic signed [31:0] r_gscore,
    input  logic signed [31:0] r_gtle,
    input  logic signed [31:0] r_w,
    // assembled alnreg (no seedcov)
    output logic signed [63:0] rb,
    output logic signed [63:0] re,
    output logic signed [31:0] qb,
    output logic signed [31:0] qe,
    output logic signed [31:0] score,
    output logic signed [31:0] truesc,
    output logic signed [31:0] w_out,
    output logic signed [31:0] rid_out
);
    // ---- left stage ----
    logic signed [63:0] rb_l;
    logic signed [31:0] qb_l, score_l, truesc_l, w_l;
    always_comb begin
        if (need_left) begin
            score_l = l_score;
            if (l_gscore <= 0 || l_gscore <= score_l - pen5) begin
                qb_l = qbeg - l_qle;  rb_l = rbeg - 64'(l_tle);  truesc_l = score_l;
            end else begin
                qb_l = 32'sd0;        rb_l = rbeg - 64'(l_gtle); truesc_l = l_gscore;
            end
            w_l = (w > l_w) ? w : l_w;
        end else begin
            score_l = len * a; qb_l = 32'sd0; rb_l = rbeg; truesc_l = len * a; w_l = w;
        end
    end

    // ---- right stage (h0R = post-left score = score_l) ----
    always_comb begin
        qb      = qb_l;
        rb      = rb_l;
        rid_out = rid;
        if (need_right) begin
            score = r_score;
            if (r_gscore <= 0 || r_gscore <= score - pen3) begin
                qe = (qbeg + len) + r_qle;
                re = (rbeg + 64'(len)) + 64'(r_tle);
                truesc = truesc_l + (score - score_l);
            end else begin
                qe = l_query;
                re = (rbeg + 64'(len)) + 64'(r_gtle);
                truesc = truesc_l + (r_gscore - score_l);
            end
            w_out = (w_l > r_w) ? w_l : r_w;
        end else begin
            score  = score_l;
            qe     = l_query;
            re     = rbeg + 64'(len);
            truesc = truesc_l;
            w_out  = w_l;
        end
    end
endmodule
