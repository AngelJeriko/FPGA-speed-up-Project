// msort_merge_sorter.sv
// Folded (iterative bottom-up) merge sorter for alignment-register score keys.
//
// Reproduces the post-dedup `alnreg_slt` sort: ascending unsigned compare of the
// 96-bit composite key (msort_pkg :: pack layout) == score desc, rb asc, qb asc.
// Verified bit-exact against ks_introsort by the C++ model (host/merge_sorter/).
//
// "Folded": ONE merge datapath is swept across the data once per pass; run width
// doubles 1->2->4->... for ceil(log2 n) passes. Two on-chip RAM banks ping-pong
// (read source, write destination, swap each pass).
//
// MEMORY: synchronous (registered) reads + writes -> maps to FPGA block RAM
// (M20K), each bank a simple-dual-port RAM (1 read port + 1 write port). A
// registered read returns data the cycle AFTER the address is presented, so the
// merge unit keeps the head of each run in a register (hL/hR) and prefetches the
// refill for whichever side it consumes. This v1.1 uses a 2-cycle-per-element
// merge (STEP issues the refill read, LATCH captures it) — simple and provably
// correct; throughput is far above need (the sorter is not the pipeline
// bottleneck), so cycles are traded for clean block-RAM timing.
//
// Phases: LOAD (stream n keys in, indices assigned 0..n-1) -> SORT -> UNLOAD
// (stream sorted (idx,key) out). Host must not enqueue n > N_MAX (1024); those
// rare cases (n in 1025..1060, 0.03% of cost) take the software fallback.

`include "msort_pkg.sv"

module msort_merge_sorter
    import msort_pkg::*;
(
    input  logic        clk,
    input  logic        rst_n,        // sync, active-low

    // ---- Load interface (stream keys in) ----
    input  logic        in_valid,
    input  key_t        in_key,
    input  logic        in_last,      // asserted with the final key of the array
    output logic        in_ready,     // accepts a key this cycle

    input  logic        start,        // unused (in_last auto-starts the sort)

    // ---- Unload interface (stream sorted pairs out) ----
    output logic        out_valid,
    output idx_t        out_idx,      // original load index, in sorted order
    output key_t        out_key,      // its composite key
    output logic        out_last,
    input  logic        out_ready,

    // ---- Status ----
    output logic        busy,
    output logic        done          // 1-cycle pulse when a sort completes
);

    // ---- Ping-pong storage: two simple-dual-port block RAMs -----------------
    pair_t bankA [0:N_MAX-1];
    pair_t bankB [0:N_MAX-1];
    logic  data_in_b;                 // 0: live data in A, 1: in B

    // Memory ports (synchronous). One combinational read address per cycle; the
    // data lands in rd_q* on the next clock. Writes are synchronous.
    logic [IDX_W-1:0] rd_addr;        // combinational, set per state
    logic [IDX_W-1:0] wr_addr;        // combinational
    pair_t            wr_data;        // combinational
    logic             wr_en_a, wr_en_b;
    pair_t            rdA_q, rdB_q;

    always_ff @(posedge clk) begin
        rdA_q <= bankA[rd_addr];
        rdB_q <= bankB[rd_addr];
        if (wr_en_a) bankA[wr_addr] <= wr_data;
        if (wr_en_b) bankB[wr_addr] <= wr_data;
    end

    // ---- FSM ----
    typedef enum logic [3:0] {
        ST_IDLE, ST_LOAD, ST_PASS_CHECK, ST_PAIR_INIT, ST_PRIME_L, ST_PRIME_R,
        ST_MERGE_STEP, ST_MERGE_LATCH, ST_UNLOAD_PRIME, ST_UNLOAD, ST_DONE
    } state_t;
    state_t state;

    cnt_t  n;                         // element count
    cnt_t  wptr;                      // load write pointer
    logic [PASS_W:0] width;           // current run width (1,2,4,...)
    cnt_t  lo, mid, hi;               // current run-pair boundaries (mid=lend, hi=rend)
    cnt_t  k;                         // dest write pointer (continuous within a pass)
    cnt_t  lfetch, rfetch;            // next addr to read for left / right run
    pair_t hL, hR;                    // current heads of the two runs
    logic  lvalid, rvalid;           // head validity
    logic  pend;                      // a refill read is in flight
    logic  pend_left;                 // which head the in-flight refill targets
    cnt_t  cur;                       // unload index

    // ---- boundary math (wide temporaries to avoid overflow before clamp) ----
    localparam int WW = PASS_W + 2;
    logic [WW-1:0] lo_ext, w_ext, two_w, lo2;
    cnt_t mid_c, hi_c;
    always_comb begin
        lo_ext = {{(WW-CNT_W){1'b0}}, lo};
        w_ext  = {{(WW-(PASS_W+1)){1'b0}}, width};
        two_w  = w_ext << 1;
        lo2    = lo_ext + two_w;                                   // lo + 2*width
        mid_c  = (lo_ext + w_ext  < {{(WW-CNT_W){1'b0}}, n}) ? (lo_ext + w_ext)  : n;  // min(lo+w , n)
        hi_c   = (lo2          < {{(WW-CNT_W){1'b0}}, n}) ? lo2[CNT_W-1:0]       : n;  // min(lo+2w, n)
    end

    // ---- src read mux (which bank holds live data this pass) ----------------
    pair_t rd_data;
    assign rd_data = data_in_b ? rdB_q : rdA_q;

    // ---- merge decision (combinational, from current heads) -----------------
    logic  take_left;
    pair_t emit;
    assign take_left = lvalid && (!rvalid || (hL.key <= hR.key));
    assign emit      = take_left ? hL : hR;

    // ---- combinational read address per state -------------------------------
    always_comb begin
        unique case (state)
            ST_PAIR_INIT:  rd_addr = lo[IDX_W-1:0];                 // left head
            ST_PRIME_L:    rd_addr = mid[IDX_W-1:0];                // right head
            ST_MERGE_STEP: rd_addr = take_left ? lfetch[IDX_W-1:0]  // refill consumed side
                                               : rfetch[IDX_W-1:0];
            ST_UNLOAD_PRIME: rd_addr = '0;
            ST_UNLOAD:     rd_addr = out_ready ? (cur + 1'b1) : cur; // prefetch next / hold
            default:       rd_addr = '0;
        endcase
    end

    // ---- combinational write port -------------------------------------------
    always_comb begin
        wr_en_a = 1'b0; wr_en_b = 1'b0;
        wr_addr = k[IDX_W-1:0];
        wr_data = emit;
        if (state == ST_IDLE && in_valid) begin
            wr_addr = wptr[IDX_W-1:0]; wr_data = '{key:in_key, idx:wptr[IDX_W-1:0]}; wr_en_a = 1'b1;
        end else if (state == ST_LOAD && in_valid) begin
            wr_addr = wptr[IDX_W-1:0]; wr_data = '{key:in_key, idx:wptr[IDX_W-1:0]}; wr_en_a = 1'b1;
        end else if (state == ST_MERGE_STEP) begin
            wr_addr = k[IDX_W-1:0]; wr_data = emit;
            if (data_in_b) wr_en_a = 1'b1;   // dst = A when live data in B
            else           wr_en_b = 1'b1;   // dst = B when live data in A
        end
    end

    // ---- status outputs -----------------------------------------------------
    assign in_ready  = (state == ST_IDLE) || (state == ST_LOAD);
    assign busy      = (state != ST_IDLE);
    assign out_valid = (state == ST_UNLOAD);
    assign out_idx   = rd_data.idx;
    assign out_key   = rd_data.key;
    assign out_last  = (state == ST_UNLOAD) && (cur == n - 1'b1);

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state <= ST_IDLE; wptr <= '0; n <= '0; data_in_b <= 1'b0; done <= 1'b0;
        end else begin
            done <= 1'b0;
            case (state)
                // -----------------------------------------------------------
                ST_IDLE: begin
                    data_in_b <= 1'b0;
                    wptr      <= '0;
                    if (in_valid) begin                 // first key (written by wr port)
                        wptr  <= wptr + 1'b1;
                        state <= ST_LOAD;
                        if (in_last) begin
                            n <= wptr + 1'b1; width <= 'd1; state <= ST_PASS_CHECK;
                        end
                    end
                end
                // -----------------------------------------------------------
                ST_LOAD: begin
                    if (in_valid) begin
                        wptr <= wptr + 1'b1;
                        if (in_last) begin
                            n <= wptr + 1'b1; width <= 'd1; state <= ST_PASS_CHECK;
                        end
                    end
                end
                // -----------------------------------------------------------
                ST_PASS_CHECK: begin
                    if (n <= 1) begin
                        cur <= '0; state <= (n == 0) ? ST_DONE : ST_UNLOAD_PRIME;
                    end else if (width < n) begin
                        lo <= '0; k <= '0; state <= ST_PAIR_INIT;
                    end else begin
                        cur <= '0; state <= ST_UNLOAD_PRIME;
                    end
                end
                // -----------------------------------------------------------
                // compute pair boundaries, issue left-head read (rd_addr=lo)
                ST_PAIR_INIT: begin
                    mid    <= mid_c;
                    hi     <= hi_c;
                    lfetch <= lo + 1'b1;
                    rfetch <= mid_c + 1'b1;
                    lvalid <= 1'b0; rvalid <= 1'b0; pend <= 1'b0;
                    state  <= ST_PRIME_L;
                end
                // -----------------------------------------------------------
                // left head arrived; capture it, issue right-head read (rd_addr=mid)
                ST_PRIME_L: begin
                    hL <= rd_data; lvalid <= 1'b1;
                    if (mid < hi) begin
                        state <= ST_PRIME_R;            // right run exists
                    end else begin
                        rvalid <= 1'b0; state <= ST_MERGE_STEP;  // lone run
                    end
                end
                // -----------------------------------------------------------
                ST_PRIME_R: begin
                    hR <= rd_data; rvalid <= 1'b1;
                    state <= ST_MERGE_STEP;
                end
                // -----------------------------------------------------------
                // emit one element; issue the refill read for the consumed side
                ST_MERGE_STEP: begin
                    k <= k + 1'b1;                       // write happens via wr port
                    if (take_left) begin
                        if (lfetch < mid) begin
                            lfetch <= lfetch + 1'b1; pend <= 1'b1; pend_left <= 1'b1;
                        end else begin
                            lvalid <= 1'b0; pend <= 1'b0;
                        end
                    end else begin
                        if (rfetch < hi) begin
                            rfetch <= rfetch + 1'b1; pend <= 1'b1; pend_left <= 1'b0;
                        end else begin
                            rvalid <= 1'b0; pend <= 1'b0;
                        end
                    end
                    state <= ST_MERGE_LATCH;
                end
                // -----------------------------------------------------------
                // capture an in-flight refill; decide pair completion
                ST_MERGE_LATCH: begin
                    if (pend) begin
                        if (pend_left) hL <= rd_data;   // refill arrived
                        else           hR <= rd_data;
                        pend  <= 1'b0;
                        state <= ST_MERGE_STEP;          // heads valid -> keep merging
                    end else begin
                        // a side just went invalid (no refill in flight)
                        if (!lvalid && !rvalid) begin
                            // pair complete
                            if (lo2 >= {{(WW-CNT_W){1'b0}}, n}) begin
                                data_in_b <= ~data_in_b; width <= width << 1;
                                state <= ST_PASS_CHECK;
                            end else begin
                                lo <= lo2[CNT_W-1:0]; state <= ST_PAIR_INIT;
                            end
                        end else begin
                            state <= ST_MERGE_STEP;      // drain remaining side
                        end
                    end
                end
                // -----------------------------------------------------------
                // unload: prime read of element 0, then stream in order
                ST_UNLOAD_PRIME: begin
                    state <= ST_UNLOAD;                  // rd_data = result[0] next cycle
                end
                ST_UNLOAD: begin
                    if (out_ready) begin
                        if (cur == n - 1'b1) state <= ST_DONE;
                        cur <= cur + 1'b1;
                    end
                end
                // -----------------------------------------------------------
                ST_DONE: begin
                    done <= 1'b1; state <= ST_IDLE;
                end
                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule
