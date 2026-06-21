// chain2aln_setup.sv — the mem_chain2aln SETUP stage: per chain, compute the reference-window
// bounds rmax0/rmax1 from the chain's seeds + query length. Models extend_orchestrator/
// chain2aln.h::c_compute_rmax bit-exact (= bwamem.cpp:mem_chain2aln rmax loop). This is the glue
// between chaining (produces chains) and extension (orch_read_top, which takes rmax + ref bytes).
//
//   rmax0 = l_pac<<1, rmax1 = 0
//   for each seed: b = rbeg - (qbeg + cal_max_gap(qbeg))
//                  e = rbeg + len + (tail + cal_max_gap(tail)),  tail = l_query-qbeg-len
//                  rmax0 = min(rmax0,b); rmax1 = max(rmax1,e)
//   rmax0 = max(rmax0,0); rmax1 = min(rmax1,l_pac<<1)
//   if (rmax0<l_pac<rmax1) pick one strand (rmax1=l_pac if seed0 fwd, else rmax0=l_pac)
//
// cal_max_gap is the integer-exact form (ksw.h:cal_max_gap_int). NOTE: it uses two signed
// divisions by e_del/e_ins (runtime config) -> a real build needs a divider / reciprocal;
// fine for sim. NSEED bounds the chain length.
module chain2aln_setup #(parameter int NSEED = 256) (
    input  logic               clk,
    input  logic               rst_n,

    // ---- config (per read) ----
    input  logic signed [31:0] a,
    input  logic signed [31:0] o_del,
    input  logic signed [31:0] e_del,
    input  logic signed [31:0] o_ins,
    input  logic signed [31:0] e_ins,
    input  logic signed [31:0] wband,
    input  logic signed [31:0] l_query,
    input  logic signed [63:0] l_pac,

    // ---- chain seed load (rbeg,qbeg,len; score irrelevant to rmax) ----
    input  logic               ld_en,
    input  logic [15:0]        ld_idx,
    input  logic signed [63:0] ld_rbeg,
    input  logic signed [31:0] ld_qbeg,
    input  logic signed [31:0] ld_len,

    // ---- run ----
    input  logic               start,
    input  logic [15:0]        n_in,
    output logic               busy,
    output logic               done,
    output logic signed [63:0] rmax0,
    output logic signed [63:0] rmax1
);
    // ---- seed buffer ----
    logic signed [63:0] b_rbeg[NSEED];
    logic signed [31:0] b_qbeg[NSEED], b_len[NSEED];
    always_ff @(posedge clk) if (ld_en && ld_idx < NSEED[15:0]) begin
        b_rbeg[ld_idx]<=ld_rbeg; b_qbeg[ld_idx]<=ld_qbeg; b_len[ld_idx]<=ld_len;
    end

    // ---- latched config ----
    logic signed [31:0] a_r, od_r, ed_r, oi_r, ei_r, w_r, lq_r;
    logic signed [63:0] lpac_r, lpac2_r, s0_rbeg;

    // cal_max_gap (integer-exact): trunc((qlen*a - o + e)/e), max, clamp to 1 and w<<1
    function automatic logic signed [31:0] cmg(input logic signed [31:0] qlen);
        logic signed [31:0] ld, li, l, w2;
        ld = (qlen*a_r - od_r + ed_r) / ed_r;
        li = (qlen*a_r - oi_r + ei_r) / ei_r;
        l  = (ld > li) ? ld : li;
        l  = (l > 32'sd1) ? l : 32'sd1;
        w2 = w_r <<< 1;
        cmg = (l < w2) ? l : w2;
    endfunction

    // ---- per-seed b/e (combinational on seed j) ----
    logic [15:0] j, n;
    logic signed [63:0] b_val, e_val;
    logic signed [31:0] gqb, tailv, gtl, qb_j, ln_j;
    logic signed [63:0] rb_j;
    always_comb begin
        rb_j  = b_rbeg[j]; qb_j = b_qbeg[j]; ln_j = b_len[j];
        gqb   = cmg(qb_j);
        tailv = lq_r - qb_j - ln_j;
        gtl   = cmg(tailv);
        // b = rbeg - (qbeg + gqb)
        b_val = rb_j - ($signed({{32{qb_j[31]}},qb_j}) + $signed({{32{gqb[31]}},gqb}));
        // e = rbeg + len + (tail + gtl)
        e_val = rb_j + $signed({{32{ln_j[31]}},ln_j})
                     + ($signed({{32{tailv[31]}},tailv}) + $signed({{32{gtl[31]}},gtl}));
    end

    // ---- final clamps + fwd/rev boundary fix (combinational on accumulated rmax) ----
    logic signed [63:0] fc0, fc1;
    always_comb begin
        fc0 = (rmax0 < 64'sd0)  ? 64'sd0   : rmax0;
        fc1 = (rmax1 > lpac2_r) ? lpac2_r  : rmax1;
        if (fc0 < lpac_r && lpac_r < fc1) begin
            if (s0_rbeg < lpac_r) fc1 = lpac_r;
            else                  fc0 = lpac_r;
        end
    end

    typedef enum logic [1:0] { D_IDLE, D_LOOP, D_FIN, D_DONE } st_t;
    st_t state;
    assign busy = (state != D_IDLE);

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state<=D_IDLE; done<=1'b0;
        end else begin
            done<=1'b0;
            case (state)
                D_IDLE: if (start) begin
                    a_r<=a; od_r<=o_del; ed_r<=e_del; oi_r<=o_ins; ei_r<=e_ins; w_r<=wband;
                    lq_r<=l_query; lpac_r<=l_pac; lpac2_r<=l_pac<<<1; s0_rbeg<=b_rbeg[0];
                    rmax0<=l_pac<<<1; rmax1<=64'sd0; n<=n_in; j<=16'd0;
                    state <= (n_in==16'd0) ? D_DONE : D_LOOP;
                end
                D_LOOP: begin
                    if (b_val < rmax0) rmax0 <= b_val;
                    if (e_val > rmax1) rmax1 <= e_val;
                    if (j + 16'd1 >= n) state<=D_FIN;
                    else j <= j + 16'd1;
                end
                D_FIN: begin rmax0<=fc0; rmax1<=fc1; state<=D_DONE; end
                D_DONE: begin done<=1'b1; state<=D_IDLE; end
                default: state<=D_IDLE;
            endcase
        end
    end
endmodule
