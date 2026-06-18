// bsw_seed_unit.sv
// Per-seed extension + assembly unit for the extend-orchestrator. Given ONE seed
// (with its chain geometry) and the read's query bases + the chain's reference
// window pre-loaded into local memories, it produces the assembled alnreg fields
// (rb/re/qb/qe/score/truesc/w/rid) — exactly the pre-purge alnreg that the C++
// model's extend_only() emits for that seed. seedcov is NOT computed here (it
// needs the whole chain seed list and is a separate streaming stage).
//
// Pipeline, mirroring mem_chain2aln_across_reads_V2 per seed:
//   1. orch_window streams the source indices of the 4 extension windows
//      (Lq,Lr reversed; Rq,Rr forward) -> demux into left/right query/target bufs
//   2. run the (single, reused) bsw_top SW core on the LEFT window  -> ExtRes_L
//      (h0 = len*a, end_bonus = pen_clip5)
//   3. run bsw_top on the RIGHT window (h0 = post-left score, end_bonus=pen_clip3)
//      -> ExtRes_R
//   4. orch_assemble(ExtRes_L, ExtRes_R, seed/cfg) -> alnreg
//
// Band-doubling is a proven no-op for 150bp reads (worst maxoff < 75), so the SW
// core runs ONCE per side and the stored band w is always cfg.w (=100); see
// host/extend_orchestrator/check_band.cpp. A window with target length 0 (seed
// flush against the ref-window edge) is handled WITHOUT running the core (which
// would hang on tlen==0): ksw returns {score=h0, qle=0, tle=0, gscore=-1, gtle=0}.
//
// Memories are written by the host/TB via the ld_* port before `start`; query is
// per-read (l_query bytes), ref is per-chain (rmax1-rmax0 bytes). The per-read
// accumulator will load them once and fire many seeds; for unit verification the
// TB reloads per seed.

`include "bsw_pkg.sv"

module bsw_seed_unit
    import bsw_pkg::*;
(
    input  logic               clk,
    input  logic               rst_n,

    // ---- memory load (host/TB) : write query_mem[addr]/ref_mem[addr] ----
    input  logic               ld_en,
    input  logic               ld_sel,        // 0 = query_mem, 1 = ref_mem
    input  logic [15:0]        ld_addr,
    input  base_t              ld_data,

    // ---- request : one seed ----
    input  logic               start,         // pulse (when !busy)
    input  logic signed [31:0] l_query,
    input  logic signed [31:0] a,
    input  logic signed [31:0] o_del,
    input  logic signed [31:0] e_del,
    input  logic signed [31:0] o_ins,
    input  logic signed [31:0] e_ins,
    input  logic signed [31:0] zdrop,
    input  logic signed [31:0] wcfg,           // opt->w (=100)
    input  logic signed [31:0] pen5,
    input  logic signed [31:0] pen3,
    input  logic signed [63:0] rbeg,
    input  logic signed [31:0] qbeg,
    input  logic signed [31:0] len,
    input  logic signed [31:0] rid,
    input  logic signed [63:0] rmax0,
    input  logic signed [63:0] rmax1,

    // ---- result ----
    output logic               busy,
    output logic               done_o,        // 1-cycle pulse when alnreg valid
    output logic signed [63:0] rb,
    output logic signed [63:0] re,
    output logic signed [31:0] qb,
    output logic signed [31:0] qe,
    output logic signed [31:0] score,
    output logic signed [31:0] truesc,
    output logic signed [31:0] w_out,
    output logic signed [31:0] rid_out
);
    // ---- local memories (flop arrays for v1; map to M20K in synthesis) ----
    base_t query_mem [MAX_QLEN];
    base_t ref_mem   [MAX_TLEN];
    always_ff @(posedge clk) begin
        if (ld_en) begin
            if (ld_sel) ref_mem[ld_addr]   <= ld_data;
            else        query_mem[ld_addr] <= ld_data;
        end
    end

    // ---- latched request ----
    logic signed [31:0] lq_r, a_r, od_r, ed_r, oi_r, ei_r, zd_r, w_r, p5_r, p3_r;
    logic signed [31:0] qbeg_r, len_r, rid_r;
    logic signed [63:0] rbeg_r, rmax0_r, rmax1_r;
    logic               need_left, need_right;
    logic signed [31:0] h0L, h0R;

    // ---- window buffers (packed so they drive bsw_top ports directly) ----
    base_t [MAX_QLEN-1:0] lq_buf, rq_buf;
    base_t [MAX_TLEN-1:0] lt_buf, rt_buf;
    logic [15:0] cnt_lq, cnt_lt, cnt_rq, cnt_rt;   // = window lengths after build

    // ---- orch_window ----
    logic        win_start, w_ovalid, w_owlast, w_nl, w_nr, w_done;
    logic [1:0]  w_owin;
    logic signed [31:0] w_oaddr;
    orch_window u_win (
        .clk(clk), .rst_n(rst_n), .start(win_start),
        .rbeg(rbeg_r), .rmax0(rmax0_r), .rmax1(rmax1_r),
        .qbeg(qbeg_r), .len(len_r), .l_query(lq_r),
        .out_valid(w_ovalid), .out_win(w_owin), .out_addr(w_oaddr),
        .out_wlast(w_owlast), .need_left(w_nl), .need_right(w_nr), .done(w_done)
    );

    // ---- bsw_top (single core, reused for left then right) ----
    logic                 bsw_req, bsw_req_rdy, bsw_res_vld;
    base_t [MAX_QLEN-1:0] bsw_q;
    base_t [MAX_TLEN-1:0] bsw_t;
    bsw_config_t          bsw_cfg;
    bsw_result_t          bsw_res;

    bsw_top u_bsw (
        .clk(clk), .rst_n(rst_n),
        .restart_mode(1'b0),                 // extension: banded SW, no fresh restart
        .req_valid_i(bsw_req), .req_ready_o(bsw_req_rdy),
        .query_i(bsw_q), .target_i(bsw_t), .cfg_i(bsw_cfg),
        .result_valid_o(bsw_res_vld), .result_ready_i(1'b1), .result_o(bsw_res)
    );

    // phase: 0 = left run, 1 = right run -> selects which buffers/cfg drive bsw
    logic phase_right;
    assign bsw_q = phase_right ? rq_buf : lq_buf;
    assign bsw_t = phase_right ? rt_buf : lt_buf;
    always_comb begin
        bsw_cfg            = '0;
        bsw_cfg.h0         = phase_right ? score_t'(h0R)  : score_t'(h0L);
        bsw_cfg.o_del      = score_t'(od_r);
        bsw_cfg.e_del      = score_t'(ed_r);
        bsw_cfg.o_ins      = score_t'(oi_r);
        bsw_cfg.e_ins      = score_t'(ei_r);
        bsw_cfg.zdrop      = score_t'(zd_r);
        bsw_cfg.end_bonus  = phase_right ? score_t'(p3_r) : score_t'(p5_r);
        bsw_cfg.w          = len_t'(w_r);
        bsw_cfg.qlen       = phase_right ? len_t'(cnt_rq) : len_t'(cnt_lq);
        bsw_cfg.tlen       = phase_right ? len_t'(cnt_rt) : len_t'(cnt_lt);
    end

    // ---- captured SW results (32-bit signed for orch_assemble) ----
    logic signed [31:0] lS, lqle, ltle, lgs, lgtle;
    logic signed [31:0] rS, rqle, rtle, rgs, rgtle;

    // ---- orch_assemble (combinational) ----
    logic signed [63:0] asm_rb, asm_re;
    logic signed [31:0] asm_qb, asm_qe, asm_score, asm_truesc, asm_w, asm_rid;
    orch_assemble u_asm (
        .need_left(need_left), .need_right(need_right),
        .l_query(lq_r), .a(a_r), .w(w_r), .pen5(p5_r), .pen3(p3_r),
        .rbeg(rbeg_r), .qbeg(qbeg_r), .len(len_r), .rid(rid_r),
        .l_score(lS), .l_qle(lqle), .l_tle(ltle), .l_gscore(lgs), .l_gtle(lgtle), .l_w(w_r),
        .r_score(rS), .r_qle(rqle), .r_tle(rtle), .r_gscore(rgs), .r_gtle(rgtle), .r_w(w_r),
        .rb(asm_rb), .re(asm_re), .qb(asm_qb), .qe(asm_qe),
        .score(asm_score), .truesc(asm_truesc), .w_out(asm_w), .rid_out(asm_rid)
    );

    // ---- FSM ----
    typedef enum logic [3:0] {
        S_IDLE, S_WSTART, S_BUILD, S_LEFT, S_LWAIT, S_RPREP, S_RIGHT, S_RWAIT, S_ASM, S_DONE
    } st_t;
    st_t state;

    // ksw result for an empty (tlen==0) target window
    task automatic set_empty_left();
        lS <= h0L; lqle <= 0; ltle <= 0; lgs <= -32'sd1; lgtle <= 0;
    endtask
    task automatic set_empty_right();
        rS <= h0R; rqle <= 0; rtle <= 0; rgs <= -32'sd1; rgtle <= 0;
    endtask

    assign busy = (state != S_IDLE);

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state <= S_IDLE; done_o <= 1'b0; win_start <= 1'b0; bsw_req <= 1'b0;
            phase_right <= 1'b0;
        end else begin
            done_o <= 1'b0; win_start <= 1'b0; bsw_req <= 1'b0;
            case (state)
                S_IDLE: if (start) begin
                    lq_r<=l_query; a_r<=a; od_r<=o_del; ed_r<=e_del; oi_r<=o_ins; ei_r<=e_ins;
                    zd_r<=zdrop; w_r<=wcfg; p5_r<=pen5; p3_r<=pen3;
                    qbeg_r<=qbeg; len_r<=len; rid_r<=rid;
                    rbeg_r<=rbeg; rmax0_r<=rmax0; rmax1_r<=rmax1;
                    need_left  <= (qbeg != 0);
                    need_right <= ((qbeg + len) != l_query);
                    h0L <= len * a;
                    cnt_lq<=0; cnt_lt<=0; cnt_rq<=0; cnt_rt<=0;
                    phase_right <= 1'b0;
                    state <= S_WSTART;
                end
                S_WSTART: begin win_start <= 1'b1; state <= S_BUILD; end
                S_BUILD: begin
                    if (w_ovalid) begin
                        unique case (w_owin)
                            2'd0: begin lq_buf[cnt_lq] <= query_mem[w_oaddr]; cnt_lq <= cnt_lq + 16'd1; end
                            2'd1: begin lt_buf[cnt_lt] <= ref_mem[w_oaddr];   cnt_lt <= cnt_lt + 16'd1; end
                            2'd2: begin rq_buf[cnt_rq] <= query_mem[w_oaddr]; cnt_rq <= cnt_rq + 16'd1; end
                            2'd3: begin rt_buf[cnt_rt] <= ref_mem[w_oaddr];   cnt_rt <= cnt_rt + 16'd1; end
                        endcase
                    end
                    if (w_done) state <= S_LEFT;
                end
                S_LEFT: begin
                    phase_right <= 1'b0;
                    if (!need_left) state <= S_RPREP;
                    else if (cnt_lt == 16'd0) begin   // tlen==0: ksw shortcut
                        set_empty_left();
                        state <= S_RPREP;
                    end else begin
                        bsw_req <= 1'b1;              // bsw is idle/ready here
                        state <= S_LWAIT;
                    end
                end
                S_LWAIT: if (bsw_res_vld) begin
                    lS    <= $signed(bsw_res.score);
                    lqle  <= $signed({16'b0, bsw_res.qle});
                    ltle  <= $signed({16'b0, bsw_res.tle});
                    lgs   <= $signed(bsw_res.gscore);
                    lgtle <= $signed({16'b0, bsw_res.gtle});
                    state <= S_RPREP;
                end
                S_RPREP: begin
                    h0R <= need_left ? lS : (len_r * a_r);
                    state <= S_RIGHT;
                end
                S_RIGHT: begin
                    phase_right <= 1'b1;
                    if (!need_right) state <= S_ASM;
                    else if (cnt_rt == 16'd0) begin
                        set_empty_right();
                        state <= S_ASM;
                    end else begin
                        bsw_req <= 1'b1;
                        state <= S_RWAIT;
                    end
                end
                S_RWAIT: if (bsw_res_vld) begin
                    rS    <= $signed(bsw_res.score);
                    rqle  <= $signed({16'b0, bsw_res.qle});
                    rtle  <= $signed({16'b0, bsw_res.tle});
                    rgs   <= $signed(bsw_res.gscore);
                    rgtle <= $signed({16'b0, bsw_res.gtle});
                    state <= S_ASM;
                end
                S_ASM: begin
                    rb<=asm_rb; re<=asm_re; qb<=asm_qb; qe<=asm_qe;
                    score<=asm_score; truesc<=asm_truesc; w_out<=asm_w; rid_out<=asm_rid;
                    state <= S_DONE;
                end
                S_DONE: begin done_o <= 1'b1; state <= S_IDLE; end
                default: state <= S_IDLE;
            endcase
        end
    end
endmodule
