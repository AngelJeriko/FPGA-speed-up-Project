// bns_clamp_top.sv — Decision C2 of docs/genome_fetch_options.md: the CONTIG CLAMP, on chip.
//
// Bit-exact to host/extend_orchestrator/bns_clamp.h (== bwa-mem2 bns_fetch_seq_v2 + bns_pos2rid +
// bns_depos). Sits after chain2aln_setup (which emits rmax0/rmax1/s0_rbeg = beg/end/mid) and before
// the reference fetch. Clamps [beg,end) to the contig that seeds[0].rbeg lands in (flipping into
// reverse-strand space when is_rev) and derives rid.
//
// SCALABLE / BRAM VERSION (full hg38): the contig table is a REGISTERED-READ memory (off_mem/len_mem)
// — no combinational array read, so it infers block RAM (M20K), not a giant address mux. NCTG scales
// to ~4096 (chr1-5 uses 5; full hg38 ~3,366 with alts/decoys). Two consequences vs a register file:
//   1. Reads have 1-cycle latency (present rd_addr, data on off_q/len_q next cycle). The FSM issues an
//      address in one state and consumes it in the next.
//   2. bns_pos2rid is done as a SINGLE-READ binary search ("rightmost offset <= pos_f"), which needs
//      off_mem[mid] only (not off_mem[mid+1]). Because contig offsets strictly increase, this yields
//      the IDENTICAL rid as bwa's bracket search — verified bit-exact vs bns_clamp.h. Search cost is
//      ~2*ceil(log2(n_seqs)) cycles (~24 for full hg38) + one clamp read.
module bns_clamp_top #(
    parameter int NCTG = 4096          // max contigs (5=chr1-5, ~3,366 full hg38 w/ alts)
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
    // ---- contig table: registered-read memory (infers BRAM) ----
    logic signed [63:0] off_mem [NCTG];
    logic signed [63:0] len_mem [NCTG];
    logic [15:0]        rd_addr;
    logic signed [63:0] off_q, len_q;          // 1-cycle-latency read outputs
    always_ff @(posedge clk) begin
        if (tbl_we) begin off_mem[tbl_idx] <= tbl_offset; len_mem[tbl_idx] <= tbl_len; end
        off_q <= off_mem[rd_addr];
        len_q <= len_mem[rd_addr];
    end

    // S_*WAIT states give the registered-read memory its 1-cycle latency before the data is consumed.
    typedef enum logic [2:0] { S_IDLE, S_SWAIT, S_SCMP, S_CWAIT, S_CCONS, S_DONE } st_t;
    st_t state;

    logic signed [63:0] beg_s, end_s, midf, l2, lpac_r;
    logic [15:0]        lo, hi, mid_r, rid_i;
    logic               isrev_r;

    // next [lo,hi) from the current probe off_q vs midf ("rightmost offset <= pos_f")
    logic [15:0] n_lo, n_hi;
    always_comb begin
        if (off_q <= midf) begin n_lo = mid_r + 16'd1; n_hi = hi;    end   // go right
        else               begin n_lo = lo;            n_hi = mid_r; end   // go left
    end

    // combinational clamp math for the resolved rid (valid in S_CCONS when off_q/len_q = off/len[rid])
    logic signed [63:0] fb, fe, cb, ce, cln;
    always_comb begin
        if (isrev_r) begin fb = l2 - (off_q + len_q); fe = l2 - off_q; end   // flip into RC space
        else         begin fb = off_q;                fe = off_q + len_q; end
        cb = (beg_s > fb) ? beg_s : fb;
        ce = (end_s < fe) ? end_s : fe;
        if (ce > l2)     ce = l2;
        if (cb < 64'sd0) cb = 64'sd0;
        cln = (cb >= lpac_r || ce <= lpac_r) ? (ce - cb) : 64'sd0;   // 0 == bridging fwd/rev boundary
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE; done <= 1'b0; rd_addr <= 16'd0;
        end else begin
            done <= 1'b0;
            case (state)
            S_IDLE: if (start) begin
                if (end_in < beg_in) begin beg_s <= end_in; end_s <= beg_in; end   // swap
                else                 begin beg_s <= beg_in; end_s <= end_in; end
                lpac_r  <= l_pac;
                l2      <= l_pac <<< 1;
                isrev_r <= (midpos >= l_pac);                                       // bns_depos
                midf    <= (midpos >= l_pac) ? ((l_pac <<< 1) - 64'sd1 - midpos) : midpos;
                lo      <= 16'd0;
                hi      <= n_seqs;
                mid_r   <= n_seqs >> 1;
                rd_addr <= n_seqs >> 1;                                             // issue first probe
                state   <= S_SWAIT;
            end
            S_SWAIT: state <= S_SCMP;             // wait for off_q = off_mem[mid_r]
            S_SCMP: begin                         // off_q = off_mem[mid_r] valid now
                if (n_lo < n_hi) begin            // keep searching
                    lo <= n_lo; hi <= n_hi;
                    mid_r   <= (n_lo + n_hi) >> 1;
                    rd_addr <= (n_lo + n_hi) >> 1;
                    state   <= S_SWAIT;
                end else begin                    // resolved: rid = n_lo - 1
                    rid_i   <= n_lo - 16'd1;
                    rd_addr <= n_lo - 16'd1;       // issue the clamp read of off/len[rid]
                    state   <= S_CWAIT;
                end
            end
            S_CWAIT: state <= S_CCONS;            // wait for off_q/len_q = off/len[rid_i]
            S_CCONS: begin                        // off_q/len_q = off/len[rid_i] valid now
                beg_out <= cb;
                end_out <= ce;
                out_len <= cln;
                rid     <= {16'd0, rid_i};
                is_rev  <= isrev_r;
                done    <= 1'b1;
                state   <= S_DONE;
            end
            S_DONE: state <= S_IDLE;
            default: state <= S_IDLE;
            endcase
        end
    end
endmodule
