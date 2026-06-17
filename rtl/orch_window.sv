// orch_window.sv
// Window-builder (address generator) for the extend-orchestrator. Given a seed and
// the chain geometry, it streams the source indices for the four extension windows
// in the order bsw_top consumes them (one index/cycle), so an external query/ref
// block-RAM read (RAM[addr] -> bsw array[pos]) fills the SW inputs:
//
//   win 0 Lq: query[qbeg-1 .. 0]          reversed, len qbeg        (if qbeg>0)
//   win 1 Lr: ref[tmp-1 .. 0]             reversed, len tmp=rbeg-rmax0
//   win 2 Rq: query[qe0 .. l_query-1]     forward,  len l_query-qe0 (if qe0!=l_query)
//   win 3 Rr: ref[re0 .. rmax1-rmax0-1]   forward,  len (rmax1-rmax0)-re0
//
// `out_addr` indexes the query RAM for win 0/2 and the chain-ref RAM for win 1/3.
// Mirrors the window setup in mem_chain2aln_across_reads_V2.
//
// Verified vs the C++ model via tb_orch_window + vectors/window_vectors.txt.

module orch_window (
    input  logic               clk,
    input  logic               rst_n,
    input  logic               start,          // pulse: latch params, begin
    input  logic signed [63:0] rbeg,
    input  logic signed [31:0] qbeg,
    input  logic signed [31:0] len,
    input  logic signed [63:0] rmax0,
    input  logic signed [63:0] rmax1,
    input  logic signed [31:0] l_query,

    output logic               out_valid,
    output logic        [1:0]  out_win,        // 0=Lq 1=Lr 2=Rq 3=Rr
    output logic signed [31:0] out_addr,       // source index (query or ref RAM)
    output logic               out_wlast,      // last element of the current window
    output logic               need_left,
    output logic               need_right,
    output logic               done
);
    typedef enum logic [1:0] { S_IDLE, S_EMIT, S_DONE } st_t;
    st_t state;

    // latched geometry (lengths are small: <= ref-window size ~811)
    logic signed [31:0] qbeg_r, len_r, lq_r;
    logic signed [31:0] tmp_r, qe0_r, re0_r, len2_r, len1_r;
    logic               nl_r, nr_r;
    logic [2:0]         w;       // 0..3, 4 = finished
    logic signed [31:0] cnt;

    // current window length / source index (combinational from latched geometry)
    logic signed [31:0] curlen, cursrc;
    always_comb begin
        unique case (w)
            3'd0: curlen = nl_r ? qbeg_r : 32'sd0;   // Lq
            3'd1: curlen = nl_r ? tmp_r  : 32'sd0;   // Lr
            3'd2: curlen = nr_r ? len2_r : 32'sd0;   // Rq
            3'd3: curlen = nr_r ? len1_r : 32'sd0;   // Rr
            default: curlen = 32'sd0;
        endcase
        unique case (w)
            3'd0: cursrc = (qbeg_r - 1) - cnt;       // reversed
            3'd1: cursrc = (tmp_r  - 1) - cnt;       // reversed
            3'd2: cursrc = qe0_r + cnt;              // forward
            3'd3: cursrc = re0_r + cnt;              // forward
            default: cursrc = 32'sd0;
        endcase
    end

    assign out_valid  = (state == S_EMIT) && (w < 3'd4) && (cnt < curlen);
    assign out_win    = w[1:0];
    assign out_addr   = cursrc;
    assign out_wlast  = out_valid && (cnt == curlen - 1);
    assign need_left  = nl_r;
    assign need_right = nr_r;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state <= S_IDLE; done <= 1'b0;
        end else begin
            done <= 1'b0;
            case (state)
                S_IDLE: if (start) begin
                    qbeg_r <= qbeg; len_r <= len; lq_r <= l_query;
                    tmp_r  <= 32'(rbeg - rmax0);
                    qe0_r  <= qbeg + len;
                    re0_r  <= 32'(rbeg + 64'(len) - rmax0);
                    len2_r <= l_query - (qbeg + len);
                    len1_r <= 32'((rmax1 - rmax0) - (rbeg + 64'(len) - rmax0));
                    nl_r   <= (qbeg != 0);
                    nr_r   <= ((qbeg + len) != l_query);
                    w <= 3'd0; cnt <= 32'sd0; state <= S_EMIT;
                end
                S_EMIT: begin
                    if (w >= 3'd4) begin
                        state <= S_DONE;
                    end else if (cnt >= curlen) begin
                        w <= w + 3'd1; cnt <= 32'sd0;     // empty / finished window
                    end else begin
                        if (cnt == curlen - 1) begin w <= w + 3'd1; cnt <= 32'sd0; end
                        else cnt <= cnt + 32'sd1;
                    end
                end
                S_DONE: begin done <= 1'b1; state <= S_IDLE; end
                default: state <= S_IDLE;
            endcase
        end
    end
endmodule
