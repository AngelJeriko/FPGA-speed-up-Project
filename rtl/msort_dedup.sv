// msort_dedup.sv
// Windowed redundancy de-overlap (branch A of mem_sort_dedup_patch), the new v2
// datapath. Input: records ALREADY re-sorted by `re` ascending (the sort reuses
// v1's msort_merge_sorter). Performs the O(n*window) nested dedup loop:
//
//   for i in 1..n-1:
//     p = a[i]; skip if rid!=a[i-1].rid or rb >= a[i-1].re + GAP
//     for j = i-1 down while rid== and rb < a[j].re + GAP:
//       q = a[j]; skip if q excluded (qe==qb)
//       if redundant(p,q):  drop the lower-scoring one (set its qe=qb)
//                           (drop p -> break inner)
//   output survivors (qe>qb) in array (re-sorted) order.
//
// redundant = (RED_NUM*or_ > RED_DEN*mr) && (RED_NUM*oq > RED_DEN*mq)  -- the
// integer-exact form of the float `or_ > 0.95f*mr` test (see msort_v2_pkg).
// branch B (mem_patch_reg SW merge) is omitted: it never fires on short reads
// (measured 0/20.09M); arrays needing it / with re-ties / n>1024 fall back to SW.
//
// Memory: one simple-dual-port block RAM (registered read + write); the engine is
// fully sequential (dedup is a small fraction of the hotspot, so optimize area).

`include "msort_v2_pkg.sv"

module msort_dedup
    import msort_v2_pkg::*;
(
    input  logic  clk,
    input  logic  rst_n,

    // load (records pre-sorted by re)
    input  logic  in_valid,
    input  rec_t  in_rec,
    input  logic  in_last,
    output logic  in_ready,

    // survivors out (re-sorted order, excluded dropped)
    output logic  out_valid,
    output rec_t  out_rec,
    input  logic  out_ready,

    output logic  tie_detected,   // adjacent equal re seen during load (-> SW fallback)
    output logic  busy,
    output logic  done
);
    // ---- record RAM (simple dual port, registered read/write) ----
    rec_t mem [0:N_MAX-1];
    logic [IDX_W-1:0] rd_addr, wr_addr;
    rec_t             wr_data, rd_q;
    logic             wr_en;
    always_ff @(posedge clk) begin
        rd_q <= mem[rd_addr];
        if (wr_en) mem[wr_addr] <= wr_data;
    end

    // ---- state ----
    typedef enum logic [3:0] {
        S_IDLE, S_LOAD, S_I_RDP, S_I_LATP, S_I_PREV, S_J_RD, S_J_LAT,
        S_CMP_RD, S_CMP_LAT, S_CMP_OUT, S_DONE
    } st_t;
    st_t  state;

    cnt_t n, wptr, i, j, k;
    rec_t p;                     // a[i] held across the inner loop
    rec_t out_reg;               // latched survivor for the output beat
    logic signed [63:0] last_re; // for load-time tie detect

    // ---- combinational dedup decision (valid in S_J_LAT, uses p and rd_q=q) ----
    logic signed [63:0] or_, oq, mr, mq;
    logic cont, q_excl, redundant, excl_p, excl_q;
    always_comb begin
        or_ = rd_q.re - p.rb;
        oq  = (rd_q.qb < p.qb) ? (64'(rd_q.qe) - 64'(p.qb)) : (64'(p.qe) - 64'(rd_q.qb));
        mr  = ((rd_q.re - rd_q.rb) < (p.re - p.rb)) ? (rd_q.re - rd_q.rb) : (p.re - p.rb);
        mq  = ((rd_q.qe - rd_q.qb) < (p.qe - p.qb)) ? (64'(rd_q.qe) - 64'(rd_q.qb)) : (64'(p.qe) - 64'(p.qb));
        cont      = (p.rid == rd_q.rid) && (p.rb < (rd_q.re + GAP));
        q_excl    = (rd_q.qe == rd_q.qb);
        redundant = (RED_NUM*or_ > RED_DEN*mr) && (RED_NUM*oq > RED_DEN*mq);
        excl_p    = cont && !q_excl && redundant && (p.score <  rd_q.score);
        excl_q    = cont && !q_excl && redundant && (p.score >= rd_q.score);
    end

    // ---- combinational memory address / write ports ----
    always_comb begin
        // read address per state
        unique case (state)
            S_I_RDP:  rd_addr = i[IDX_W-1:0];
            S_I_LATP: rd_addr = (i - 1'b1);
            S_J_RD:   rd_addr = j[IDX_W-1:0];
            S_CMP_RD: rd_addr = k[IDX_W-1:0];
            default:  rd_addr = '0;
        endcase
        // write port
        wr_en   = 1'b0;
        wr_addr = wptr[IDX_W-1:0];
        wr_data = in_rec;
        if ((state == S_IDLE || state == S_LOAD) && in_valid) begin
            wr_en = 1'b1; wr_addr = wptr[IDX_W-1:0]; wr_data = in_rec;     // load
        end else if (state == S_J_LAT && excl_p) begin
            wr_en = 1'b1; wr_addr = i[IDX_W-1:0]; wr_data = p;  wr_data.qe = p.qb;     // drop p
        end else if (state == S_J_LAT && excl_q) begin
            wr_en = 1'b1; wr_addr = j[IDX_W-1:0]; wr_data = rd_q; wr_data.qe = rd_q.qb; // drop q
        end
    end

    assign in_ready  = (state == S_IDLE) || (state == S_LOAD);
    assign busy      = (state != S_IDLE);
    assign out_valid = (state == S_CMP_OUT);
    assign out_rec   = out_reg;

    // helper: at end of an inner loop or after exclude-p, advance i (or finish)
    // (implemented inline below)

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state <= S_IDLE; wptr <= '0; n <= '0; tie_detected <= 1'b0; done <= 1'b0;
        end else begin
            done <= 1'b0;
            case (state)
                // ---------------------------------------------------------
                S_IDLE: begin
                    tie_detected <= 1'b0;
                    wptr <= '0;
                    if (in_valid) begin
                        last_re <= in_rec.re;
                        wptr <= 'd1;
                        state <= S_LOAD;
                        if (in_last) begin n <= 'd1; state <= S_CMP_RD; k <= '0; end
                    end
                end
                // ---------------------------------------------------------
                S_LOAD: begin
                    if (in_valid) begin
                        if (in_rec.re == last_re) tie_detected <= 1'b1;
                        last_re <= in_rec.re;
                        wptr <= wptr + 1'b1;
                        if (in_last) begin
                            n <= wptr + 1'b1;
                            if (wptr + 1'b1 >= 'd2) begin i <= 'd1; state <= S_I_RDP; end
                            else begin k <= '0; state <= S_CMP_RD; end
                        end
                    end
                end
                // ---------------------------------------------------------
                S_I_RDP:  state <= S_I_LATP;                 // issued read a[i]
                S_I_LATP: begin p <= rd_q; state <= S_I_PREV; end  // latch p; issued read a[i-1]
                S_I_PREV: begin
                    // rd_q = a[i-1]; outer skip test
                    if (p.rid != rd_q.rid || p.rb >= (rd_q.re + GAP)) begin
                        // skip this i
                        if (i + 1'b1 >= n) begin k <= '0; state <= S_CMP_RD; end
                        else begin i <= i + 1'b1; state <= S_I_RDP; end
                    end else begin
                        j <= i - 1'b1; state <= S_J_RD;
                    end
                end
                // ---------------------------------------------------------
                S_J_RD:  state <= S_J_LAT;                   // issued read a[j]
                S_J_LAT: begin
                    // rd_q = a[j] = q. Decision via comb signals.
                    if (!cont || excl_p) begin
                        // window closed, or p dropped -> inner done, next i
                        if (i + 1'b1 >= n) begin k <= '0; state <= S_CMP_RD; end
                        else begin i <= i + 1'b1; state <= S_I_RDP; end
                    end else begin
                        // q_excl (skip), excl_q (dropped via comb write), or no-op:
                        // all continue to j-1, or finish inner if j==0
                        if (j == 0) begin
                            if (i + 1'b1 >= n) begin k <= '0; state <= S_CMP_RD; end
                            else begin i <= i + 1'b1; state <= S_I_RDP; end
                        end else begin
                            j <= j - 1'b1; state <= S_J_RD;
                        end
                    end
                end
                // ---------------------------------------------------------
                S_CMP_RD:  state <= S_CMP_LAT;               // issued read a[k]
                S_CMP_LAT: begin
                    if (rd_q.qe > rd_q.qb) begin
                        out_reg <= rd_q; state <= S_CMP_OUT;  // survivor -> present
                    end else if (k + 1'b1 >= n) begin
                        state <= S_DONE;
                    end else begin
                        k <= k + 1'b1; state <= S_CMP_RD;
                    end
                end
                S_CMP_OUT: begin
                    if (out_ready) begin
                        if (k + 1'b1 >= n) state <= S_DONE;
                        else begin k <= k + 1'b1; state <= S_CMP_RD; end
                    end
                end
                // ---------------------------------------------------------
                S_DONE: begin done <= 1'b1; state <= S_IDLE; end
                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
