// chaining_top.sv — the COMPLETE bwa-mem2 chaining stage on chip = mem_chain (chain_store)
// feeding mem_chain_flt (chain_flt_top). Models host/chaining/chain.h end-to-end:
//   raw seed stream  --chain_store-->  chains (pos-sorted, seed pool)  --chain_flt_top-->
//   surviving chains (weight-sorted, overlap/shadow-filtered).
//
// chain_store emits seeds as an append-only linked-list POOL (per-chain head->next), while
// chain_flt_top consumes a FLAT pool addressed by (offset, count). The ADAPTER phase bridges
// them: for each chain it latches (n_seeds, is_alt, head), loads chain_flt_top's chain meta,
// then walks head->next copying each pooled seed into chain_flt_top's flat seed buffer. Both
// sub-blocks are reused UNMODIFIED (each already bit-exact vs its chain.h reference).
//
// Output: the surviving chains' chain_store indices (= pos-sorted order), in weight-sorted
// order (chain_flt_top's o_id). Read the actual chain data via the passthrough chain_store
// readback (rd_cidx -> meta, rd_sidx -> pool) at those indices. `fallback` = chain_store's
// dup-pos OR chain_flt_top's combsort -> host SW redo for the whole read.
module chaining_top #(parameter int NCHAIN = 64, parameter int NSEED = 64, parameter int CWSEED = 64) (
    input  logic               clk,
    input  logic               rst_n,

    // ---- config ----
    input  logic signed [31:0] w,
    input  logic signed [31:0] max_chain_gap,
    input  logic signed [63:0] l_pac,
    input  logic signed [31:0] min_seed_len,
    input  logic signed [31:0] max_chain_extend,

    // ---- raw seed stream load (-> chain_store) ----
    input  logic               ld_en,
    input  logic [15:0]        ld_idx,
    input  logic signed [63:0] ld_rbeg,
    input  logic signed [31:0] ld_qbeg,
    input  logic signed [31:0] ld_len,
    input  logic signed [31:0] ld_score,
    input  logic signed [31:0] ld_rid,
    input  logic signed [31:0] ld_isalt,

    // ---- run ----
    input  logic               start,
    input  logic [15:0]        n_in,           // number of raw seeds
    output logic               busy,
    output logic               done,
    output logic               fallback,
    output logic [15:0]        n_out,          // number of surviving chains

    // ---- surviving chain ids (chain_store index, weight-sorted order) ----
    input  logic [15:0]        rd_idx,
    output logic [15:0]        o_cidx,

    // ---- passthrough chain_store readback (fetch surviving chains' data) ----
    input  logic [15:0]        rd_cidx,
    output logic signed [63:0] o_pos,
    output logic signed [31:0] o_rid,
    output logic signed [31:0] o_isalt,
    output logic [15:0]        o_nseeds,
    output logic [15:0]        o_head,
    input  logic [15:0]        rd_sidx,
    output logic signed [63:0] s_rbeg,
    output logic signed [31:0] s_qbeg,
    output logic signed [31:0] s_len,
    output logic signed [31:0] s_score,
    output logic [15:0]        s_next
);
    // ===================== chain_store (mem_chain) =====================
    logic        cs_start; logic [15:0] cs_nchains; logic cs_busy, cs_done, cs_fallback;
    logic [15:0] cs_rd_cidx, cs_rd_sidx;
    logic signed [63:0] cs_o_pos; logic signed [31:0] cs_o_rid, cs_o_isalt; logic [15:0] cs_o_nseeds, cs_o_head;
    logic signed [63:0] cs_s_rbeg; logic signed [31:0] cs_s_qbeg, cs_s_len, cs_s_score; logic [15:0] cs_s_next;
    chain_store #(.NCHAIN(NCHAIN), .NSEED(NSEED)) u_cs (.clk,.rst_n,
        .w,.max_chain_gap,.l_pac,
        .ld_en,.ld_idx,.ld_rbeg,.ld_qbeg,.ld_len,.ld_score,.ld_rid,.ld_isalt,
        .start(cs_start),.n_in(n_in),.busy(cs_busy),.done(cs_done),.fallback(cs_fallback),.n_chains(cs_nchains),
        .rd_cidx(cs_rd_cidx),.o_pos(cs_o_pos),.o_rid(cs_o_rid),.o_isalt(cs_o_isalt),.o_nseeds(cs_o_nseeds),.o_head(cs_o_head),
        .rd_sidx(cs_rd_sidx),.s_rbeg(cs_s_rbeg),.s_qbeg(cs_s_qbeg),.s_len(cs_s_len),.s_score(cs_s_score),.s_next(cs_s_next));

    // passthrough chain_store readback to the host
    assign o_pos=cs_o_pos; assign o_rid=cs_o_rid; assign o_isalt=cs_o_isalt; assign o_nseeds=cs_o_nseeds; assign o_head=cs_o_head;
    assign s_rbeg=cs_s_rbeg; assign s_qbeg=cs_s_qbeg; assign s_len=cs_s_len; assign s_score=cs_s_score; assign s_next=cs_s_next;

    // ===================== chain_flt_top (mem_chain_flt) =====================
    logic        fl_ld_seed_en; logic [15:0] fl_ld_seed_idx; logic signed [63:0] fl_ld_seed_rbeg; logic signed [31:0] fl_ld_seed_qbeg, fl_ld_seed_len;
    logic        fl_ld_chain_en; logic [15:0] fl_ld_chain_idx, fl_ld_chain_off, fl_ld_chain_ns; logic fl_ld_chain_isalt;
    logic        fl_start; logic [15:0] fl_nin; logic fl_busy, fl_done, fl_fallback; logic [15:0] fl_nout;
    logic [15:0] fl_o_id;
    chain_flt_top #(.NCHAIN(NCHAIN), .NSEED(NSEED*4), .CWSEED(CWSEED)) u_fl (.clk,.rst_n,
        .max_chain_gap,.min_seed_len,.max_chain_extend,
        .ld_seed_en(fl_ld_seed_en),.ld_seed_idx(fl_ld_seed_idx),.ld_seed_rbeg(fl_ld_seed_rbeg),.ld_seed_qbeg(fl_ld_seed_qbeg),.ld_seed_len(fl_ld_seed_len),
        .ld_chain_en(fl_ld_chain_en),.ld_chain_idx(fl_ld_chain_idx),.ld_chain_off(fl_ld_chain_off),.ld_chain_ns(fl_ld_chain_ns),.ld_chain_isalt(fl_ld_chain_isalt),
        .start(fl_start),.n_in(fl_nin),.busy(fl_busy),.done(fl_done),.fallback(fl_fallback),.n_out(fl_nout),
        .rd_idx(rd_idx),.o_id(fl_o_id));
    assign o_cidx = fl_o_id;
    assign fl_nin = cs_nchains;

    // ===================== orchestration =====================
    logic [15:0] ci, sidx, s_cnt, cur_off, ns_cur;
    typedef enum logic [3:0] {
        G_IDLE, G_CS_RUN, G_CS_WAIT, G_AD_CMETA, G_AD_SEED, G_FLT_RUN, G_FLT_WAIT, G_DONE
    } st_t;
    st_t state;
    assign busy = (state != G_IDLE);

    // chain_store readback is shared: the adapter drives it during the walk, the host otherwise
    always_comb begin
        cs_rd_cidx = (state==G_AD_CMETA) ? ci   : rd_cidx;
        cs_rd_sidx = (state==G_AD_SEED)  ? sidx : rd_sidx;
        cs_start   = (state==G_CS_RUN);
        fl_start   = (state==G_FLT_RUN);
        // chain_flt_top loads, driven by the adapter
        fl_ld_chain_en=1'b0; fl_ld_chain_idx=16'd0; fl_ld_chain_off=16'd0; fl_ld_chain_ns=16'd0; fl_ld_chain_isalt=1'b0;
        fl_ld_seed_en=1'b0;  fl_ld_seed_idx=16'd0; fl_ld_seed_rbeg=64'sd0; fl_ld_seed_qbeg=32'sd0; fl_ld_seed_len=32'sd0;
        case (state)
            G_AD_CMETA: begin
                fl_ld_chain_en=1'b1; fl_ld_chain_idx=ci; fl_ld_chain_off=cur_off;
                fl_ld_chain_ns=cs_o_nseeds; fl_ld_chain_isalt=cs_o_isalt[0];
            end
            G_AD_SEED: begin
                fl_ld_seed_en=1'b1; fl_ld_seed_idx=cur_off + s_cnt;
                fl_ld_seed_rbeg=cs_s_rbeg; fl_ld_seed_qbeg=cs_s_qbeg; fl_ld_seed_len=cs_s_len;
            end
            default:;
        endcase
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state<=G_IDLE; done<=1'b0; fallback<=1'b0;
        end else begin
            done<=1'b0;
            case (state)
                G_IDLE: if (start) begin fallback<=1'b0; n_out<=16'd0; state<=G_CS_RUN; end

                G_CS_RUN: state<=G_CS_WAIT;              // cs_start pulsed via comb
                G_CS_WAIT: if (cs_done) begin
                    if (cs_fallback)            begin fallback<=1'b1; state<=G_DONE; end
                    else if (cs_nchains==16'd0) begin n_out<=16'd0; state<=G_DONE; end
                    else begin ci<=16'd0; cur_off<=16'd0; state<=G_AD_CMETA; end
                end

                // latch chain ci's (n_seeds, head); chain meta loaded into chain_flt_top via comb
                G_AD_CMETA: begin
                    ns_cur<=cs_o_nseeds; sidx<=cs_o_head; s_cnt<=16'd0;
                    state<=G_AD_SEED;
                end
                // copy pooled seed (cur_off+s_cnt) <- pool[sidx]; walk head->next
                G_AD_SEED: begin
                    sidx <= cs_s_next;
                    if (s_cnt + 16'd1 >= ns_cur) begin
                        cur_off <= cur_off + ns_cur;
                        if (ci + 16'd1 >= cs_nchains) state<=G_FLT_RUN;
                        else begin ci<=ci+16'd1; state<=G_AD_CMETA; end
                    end else s_cnt <= s_cnt + 16'd1;
                end

                G_FLT_RUN: state<=G_FLT_WAIT;            // fl_start pulsed via comb
                G_FLT_WAIT: if (fl_done) begin
                    if (fl_fallback) fallback<=1'b1;
                    n_out<=fl_nout; state<=G_DONE;
                end

                G_DONE: begin done<=1'b1; state<=G_IDLE; end
                default: state<=G_IDLE;
            endcase
        end
    end
endmodule
