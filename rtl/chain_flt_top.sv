// chain_flt_top.sv — the FULL mem_chain_flt pipeline = weight + sort + filter, wiring the three
// verified units (chain_weight x N, chain_introsort, chain_flt) into one engine. Models
// host/chaining/chain.h::c_mem_chain_flt end-to-end: chains-with-seeds -> the surviving chains'
// original indices, in weight-sorted order.
//
// Flow:
//   1. WEIGH  : for each chain, stream its seeds through chain_weight -> w[ci]; also grab
//               cbeg = first seed qbeg, cend = last seed qbeg+len (the filter's query span).
//   2. SORT   : chain_introsort sorts the (w, original-index) pairs by w DESC (unstable tie
//               order). perm[p] = original index of the p-th chain. If introsort hits the depth
//               limit (combsort), it raises fallback -> this top raises `fallback` (host SW redo);
//               that is the ONLY fallback source in weight+sort+filter.
//   3. FILTER : chain_flt applies the greedy overlap/shadow filter on the sorted metadata ->
//               kept[p] per sorted position.
//   4. COMPACT: emit perm[p] for every kept[p] != 0, in sorted order.
//
// Assumes min_chain_weight == 0 (the only value bwa-mem2 uses here) so the pre-sort weight-drop
// never removes a chain (chain weight is always >= 1). Input chains carry their seeds in a flat
// pool addressed per chain by (offset, count); NCHAIN/NSEED bound the read.
module chain_flt_top #(parameter int NCHAIN = 64, parameter int NSEED = 256, parameter int CWSEED = 64) (
    input  logic               clk,
    input  logic               rst_n,

    // ---- config ----
    input  logic signed [31:0] max_chain_gap,
    input  logic signed [31:0] min_seed_len,
    input  logic signed [31:0] max_chain_extend,

    // ---- seed pool load (flat; chains index into it) ----
    input  logic               ld_seed_en,
    input  logic [15:0]        ld_seed_idx,
    input  logic signed [63:0] ld_seed_rbeg,
    input  logic signed [31:0] ld_seed_qbeg,
    input  logic signed [31:0] ld_seed_len,

    // ---- chain load: (seed offset, seed count, is_alt) per chain ----
    input  logic               ld_chain_en,
    input  logic [15:0]        ld_chain_idx,
    input  logic [15:0]        ld_chain_off,
    input  logic [15:0]        ld_chain_ns,
    input  logic               ld_chain_isalt,

    // ---- run ----
    input  logic               start,
    input  logic [15:0]        n_in,
    output logic               busy,
    output logic               done,
    output logic               fallback,
    output logic [15:0]        n_out,

    // ---- output: surviving original chain indices, sorted order ----
    input  logic [15:0]        rd_idx,
    output logic [15:0]        o_id
);
    // ================= input storage =================
    logic signed [63:0] sd_rbeg[NSEED];
    logic signed [31:0] sd_qbeg[NSEED], sd_len[NSEED];
    logic [15:0]        c_off[NCHAIN], c_ns[NCHAIN];
    logic               c_alt[NCHAIN];
    always_ff @(posedge clk) begin
        if (ld_seed_en  && ld_seed_idx  < NSEED[15:0]) begin
            sd_rbeg[ld_seed_idx]<=ld_seed_rbeg; sd_qbeg[ld_seed_idx]<=ld_seed_qbeg; sd_len[ld_seed_idx]<=ld_seed_len;
        end
        if (ld_chain_en && ld_chain_idx < NCHAIN[15:0]) begin
            c_off[ld_chain_idx]<=ld_chain_off; c_ns[ld_chain_idx]<=ld_chain_ns; c_alt[ld_chain_idx]<=ld_chain_isalt;
        end
    end

    // ================= computed per-chain =================
    logic signed [31:0] w[NCHAIN], cbeg[NCHAIN], cend[NCHAIN];
    logic [15:0]        perm[NCHAIN], out_id[NCHAIN];
    logic [15:0]        n, ci, si, p, out_cnt;
    assign o_id  = out_id[rd_idx];

    // ================= sub-units =================
    // chain_weight
    logic cw_lden; logic [15:0] cw_ldidx; logic signed [31:0] cw_ldqbeg, cw_ldlen; logic signed [63:0] cw_ldrbeg;
    logic cw_start; logic [15:0] cw_nin; logic cw_busy, cw_done; logic signed [31:0] cw_w;
    chain_weight #(.NSEED(CWSEED)) u_w (.clk,.rst_n,
        .ld_en(cw_lden),.ld_idx(cw_ldidx),.ld_qbeg(cw_ldqbeg),.ld_rbeg(cw_ldrbeg),.ld_len(cw_ldlen),
        .start(cw_start),.n_in(cw_nin),.busy(cw_busy),.done(cw_done),.w(cw_w));

    // chain_introsort
    logic is_lden; logic [15:0] is_ldidx; logic signed [31:0] is_ldw; logic [15:0] is_ldid;
    logic is_start; logic [15:0] is_nin; logic is_busy, is_done, is_fb; logic [15:0] is_nout;
    logic [15:0] is_rdidx; logic signed [31:0] is_ow; logic [15:0] is_oid;
    chain_introsort #(.NMAX(NCHAIN), .STACKD(48)) u_s (.clk,.rst_n,
        .ld_en(is_lden),.ld_idx(is_ldidx),.ld_w(is_ldw),.ld_id(is_ldid),
        .start(is_start),.n_in(is_nin),.busy(is_busy),.done(is_done),.fallback(is_fb),.n_out(is_nout),
        .rd_idx(is_rdidx),.o_w(is_ow),.o_id(is_oid));

    // chain_flt
    logic fl_lden; logic [15:0] fl_ldidx; logic signed [31:0] fl_ldw, fl_ldcbeg, fl_ldcend; logic fl_ldisalt;
    logic fl_start; logic [15:0] fl_nin; logic fl_busy, fl_done; logic [15:0] fl_nout;
    logic [15:0] fl_rdidx; logic [1:0] fl_okept;
    chain_flt #(.NMAX(NCHAIN)) u_f (.clk,.rst_n,
        .max_chain_gap,.min_seed_len,.max_chain_extend,
        .ld_en(fl_lden),.ld_idx(fl_ldidx),.ld_w(fl_ldw),.ld_cbeg(fl_ldcbeg),.ld_cend(fl_ldcend),.ld_isalt(fl_ldisalt),
        .start(fl_start),.n_in(fl_nin),.busy(fl_busy),.done(fl_done),.n_out(fl_nout),
        .rd_idx(fl_rdidx),.o_kept(fl_okept));

    typedef enum logic [3:0] {
        T_IDLE, T_WL, T_WRUN, T_WWAIT, T_SL, T_SRUN, T_SWAIT, T_GATH, T_FRUN, T_FWAIT, T_COMP, T_DONE
    } st_t;
    st_t state;
    assign busy = (state != T_IDLE);

    // base seed address of chain ci's seed si
    logic [15:0] sa;
    assign sa = c_off[ci] + si;

    // ---- combinational drive of all sub-unit inputs ----
    always_comb begin
        cw_lden=1'b0; cw_ldidx=16'd0; cw_ldqbeg=32'sd0; cw_ldrbeg=64'sd0; cw_ldlen=32'sd0;
        cw_start=1'b0; cw_nin=c_ns[ci];
        is_lden=1'b0; is_ldidx=16'd0; is_ldw=32'sd0; is_ldid=16'd0; is_start=1'b0; is_nin=n; is_rdidx=p;
        fl_lden=1'b0; fl_ldidx=16'd0; fl_ldw=32'sd0; fl_ldcbeg=32'sd0; fl_ldcend=32'sd0; fl_ldisalt=1'b0;
        fl_start=1'b0; fl_nin=n; fl_rdidx=p;
        case (state)
            T_WL:   begin cw_lden=1'b1; cw_ldidx=si; cw_ldqbeg=sd_qbeg[sa]; cw_ldrbeg=sd_rbeg[sa]; cw_ldlen=sd_len[sa]; end
            T_WRUN: cw_start=1'b1;
            T_SL:   begin is_lden=1'b1; is_ldidx=ci; is_ldw=w[ci]; is_ldid=ci; end
            T_SRUN: is_start=1'b1;
            T_GATH: begin fl_lden=1'b1; fl_ldidx=p; fl_ldw=w[is_oid]; fl_ldcbeg=cbeg[is_oid]; fl_ldcend=cend[is_oid]; fl_ldisalt=c_alt[is_oid]; end
            T_FRUN: fl_start=1'b1;
            default:;
        endcase
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state<=T_IDLE; done<=1'b0; fallback<=1'b0;
        end else begin
            done<=1'b0;
            case (state)
                T_IDLE: if (start) begin
                    n<=n_in; ci<=16'd0; si<=16'd0; out_cnt<=16'd0; fallback<=1'b0;
                    state <= (n_in==16'd0) ? T_DONE : T_WL;
                end

                // stream chain ci's seeds into chain_weight; capture span ends
                T_WL: begin
                    if (si == 16'd0)              cbeg[ci] <= sd_qbeg[sa];
                    if (si + 16'd1 >= c_ns[ci]) begin
                        cend[ci] <= sd_qbeg[sa] + sd_len[sa];
                        state<=T_WRUN;
                    end else si<=si+16'd1;
                end
                T_WRUN: state<=T_WWAIT;
                T_WWAIT: if (cw_done) begin
                    w[ci] <= cw_w;
                    if (ci + 16'd1 >= n) begin ci<=16'd0; state<=T_SL; end
                    else begin ci<=ci+16'd1; si<=16'd0; state<=T_WL; end
                end

                // load (w,id) pairs into chain_introsort, run
                T_SL: if (ci + 16'd1 >= n) state<=T_SRUN; else ci<=ci+16'd1;
                T_SRUN: state<=T_SWAIT;
                T_SWAIT: if (is_done) begin
                    if (is_fb) begin fallback<=1'b1; state<=T_DONE; end
                    else begin p<=16'd0; state<=T_GATH; end
                end

                // gather sorted metadata into chain_flt (perm[p] = is_oid)
                T_GATH: begin
                    perm[p] <= is_oid;
                    if (p + 16'd1 >= n) state<=T_FRUN; else p<=p+16'd1;
                end
                T_FRUN: state<=T_FWAIT;
                T_FWAIT: if (fl_done) begin p<=16'd0; out_cnt<=16'd0; state<=T_COMP; end

                // compact: emit perm[p] for kept[p] != 0
                T_COMP: begin
                    if (fl_okept != 2'd0) begin out_id[out_cnt]<=perm[p]; out_cnt<=out_cnt+16'd1; end
                    if (p + 16'd1 >= n) state<=T_DONE; else p<=p+16'd1;
                end

                T_DONE: begin done<=1'b1; n_out<=out_cnt; state<=T_IDLE; end
                default: state<=T_IDLE;
            endcase
        end
    end
endmodule
