// bns_clamp_top.sv — Decision C2 of docs/genome_fetch_options.md: the CONTIG CLAMP, on chip.
//
// Bit-exact to host/extend_orchestrator/bns_clamp.h, which is line-for-line faithful to unmodified
// bwa-mem2: bns_fetch_seq_v2 (bwamem.cpp:1890) + bns_pos2rid (bntseq.cpp:378) + bns_depos
// (bntseq.h:87). It sits immediately AFTER chain2aln_setup (which already emits rmax0/rmax1/s0_rbeg
// = beg/end/mid) and BEFORE the reference fetch. Today the host performs this clamp; pulling it on
// chip is required because "ask the host to clamp" is exactly the round trip the genome-fetch work
// removes. Host still supplies the ref BYTES until the A1 fetch datapath lands.
//
// Operation (per request): swap beg/end if reversed; depos(mid) -> is_rev + forward coord midf;
// bns_pos2rid(midf) via an iterative binary search over the ascending contig offset table
// (~ceil(log2(n_seqs)) cycles); clamp [beg,end) to the contig's [offset, offset+len), flipped into
// reverse-strand space when is_rev; final get_seq clamps + len (0 iff bridging, unreachable here).
//
// The contig table (offset,len per contig) lives in registers loaded via tbl_we; 5 entries for
// chr1-5, up to ~3,366 for full hg38 (tens of KB) -> then move to on-chip SRAM by raising NCTG and
// converting off_r/len_r to a RAM. n_seqs and l_pac are held stable during a request.
module bns_clamp_top #(
    parameter int NCTG = 8              // max contigs (5=chr1-5, 3=synthetic, up to ~4096 full hg38)
)(
    input  logic                clk,
    input  logic                rst_n,
    // ---- contig table load: one entry per tbl_we pulse ----
    input  logic                tbl_we,
    input  logic [15:0]         tbl_idx,
    input  logic signed [63:0]  tbl_offset,
    input  logic signed [63:0]  tbl_len,       // bwa's int32 len, zero-extended
    input  logic [15:0]         n_seqs,        // number of contigs (held stable)
    input  logic signed [63:0]  l_pac,         // forward-strand length (held stable)
    // ---- request ----
    input  logic                start,
    input  logic signed [63:0]  beg_in,        // rmax0
    input  logic signed [63:0]  midpos,        // seeds[0].rbeg
    input  logic signed [63:0]  end_in,        // rmax1
    // ---- result (valid the cycle done=1) ----
    output logic                done,
    output logic signed [63:0]  beg_out,       // clamped beg
    output logic signed [63:0]  end_out,       // clamped end
    output logic [31:0]         rid,           // derived contig id
    output logic                is_rev,        // strand of the fetch
    output logic signed [63:0]  out_len        // end_out-beg_out (0 iff bridging)
);
    // ---- contig table (registers; raise NCTG + convert to SRAM for full hg38) ----
    logic signed [63:0] off_r [NCTG];
    logic signed [63:0] len_r [NCTG];
    always_ff @(posedge clk) if (tbl_we) begin
        off_r[tbl_idx] <= tbl_offset;
        len_r[tbl_idx] <= tbl_len;
    end

    typedef enum logic [1:0] { S_IDLE, S_SEARCH, S_CLAMP, S_DONE } state_t;
    state_t state;

    // request-scoped registers
    logic signed [63:0] beg_s, end_s, midf, l2, lpac_r;
    logic [15:0]        nseq_r, left, right, bmid, rid_i;
    logic               isrev_r;

    assign rid = {16'd0, rid_i};

    // --- combinational binary-search probe over the current [left,right) ---
    logic [15:0]        bm;
    logic signed [63:0] off_bm, off_bm1;
    always_comb begin
        bm      = (left + right) >> 1;
        off_bm  = off_r[bm];
        off_bm1 = off_r[(bm == nseq_r - 16'd1) ? bm : (bm + 16'd1)];   // guard the top-edge read
    end

    // --- combinational clamp math for the resolved rid_i (valid once rid_i is set) ---
    logic signed [63:0] fb_raw, fe_raw, fb, fe, cb, ce, cln;
    always_comb begin
        fb_raw = off_r[rid_i];
        fe_raw = off_r[rid_i] + len_r[rid_i];
        if (isrev_r) begin fb = l2 - fe_raw; fe = l2 - fb_raw; end   // flip into reverse-strand space
        else         begin fb = fb_raw;      fe = fe_raw;      end
        cb = (beg_s > fb) ? beg_s : fb;        // clamp up to contig start
        ce = (end_s < fe) ? end_s : fe;        // clamp down to contig end
        if (ce > l2)      ce = l2;             // bns_get_seq_v2 final clamps (no-ops post contig clamp)
        if (cb < 64'sd0)  cb = 64'sd0;
        cln = (cb >= lpac_r || ce <= lpac_r) ? (ce - cb) : 64'sd0;   // 0 == bridging fwd/rev boundary
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE;
            done  <= 1'b0;
        end else begin
            done <= 1'b0;
            case (state)
            S_IDLE: if (start) begin
                if (end_in < beg_in) begin beg_s <= end_in; end_s <= beg_in; end   // swap
                else                 begin beg_s <= beg_in; end_s <= end_in; end
                lpac_r  <= l_pac;
                nseq_r  <= n_seqs;
                l2      <= l_pac <<< 1;
                isrev_r <= (midpos >= l_pac);                                       // bns_depos
                midf    <= (midpos >= l_pac) ? ((l_pac <<< 1) - 64'sd1 - midpos) : midpos;
                left    <= 16'd0;
                right   <= n_seqs;
                bmid    <= 16'd0;
                state   <= S_SEARCH;
            end
            S_SEARCH: begin
                if (left < right) begin
                    bmid <= bm;                                                     // remember last mid
                    if (midf >= off_bm) begin
                        if (bm == nseq_r - 16'd1 || midf < off_bm1) begin
                            rid_i <= bm; state <= S_CLAMP;                          // bracketed -> found
                        end else left <= bm + 16'd1;
                    end else right <= bm;
                end else begin
                    rid_i <= bmid; state <= S_CLAMP;                               // loop exit: last mid
                end
            end
            S_CLAMP: begin
                beg_out <= cb;
                end_out <= ce;
                out_len <= cln;
                is_rev  <= isrev_r;
                done    <= 1'b1;
                state   <= S_DONE;
            end
            S_DONE: state <= S_IDLE;
            endcase
        end
    end
endmodule
