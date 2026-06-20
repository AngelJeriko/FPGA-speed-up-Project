// chain_weight.sv — mem_chain_weight (bwamem.cpp) for one chain. Models
// host/chaining/chain.h::c_chain_weight bit-exact:
//   pass 1 (query): walk seeds in chain order, end=0,w=0; for each seed
//     if qbeg>=end       w += len
//     elif qbeg+len>end  w += qbeg+len-end          (partial overlap)
//     end = max(end, qbeg+len)
//   pass 2 (ref): same over rbeg.  weight = min(pass1,pass2), capped at (1<<30)-1.
//
// Inherently sequential (a running `end` accumulator), so one seed/cycle/pass.
// All math is 64-bit signed (coords are non-negative, but keep it clean — cf. the
// chain_store signed-part-select gotcha). NSEED bounds the chain length.
module chain_weight #(parameter int NSEED = 64) (
    input  logic               clk,
    input  logic               rst_n,

    // ---- seed load (chain order, idx 0..n_in-1) ----
    input  logic               ld_en,
    input  logic [15:0]        ld_idx,
    input  logic signed [31:0] ld_qbeg,
    input  logic signed [63:0] ld_rbeg,
    input  logic signed [31:0] ld_len,

    // ---- run ----
    input  logic               start,
    input  logic [15:0]        n_in,
    output logic               busy,
    output logic               done,
    output logic signed [31:0] w
);
    // ---- seed buffer ----
    logic signed [31:0] b_qbeg[NSEED], b_len[NSEED];
    logic signed [63:0] b_rbeg[NSEED];
    always_ff @(posedge clk) if (ld_en && ld_idx < NSEED[15:0]) begin
        b_qbeg[ld_idx]<=ld_qbeg; b_rbeg[ld_idx]<=ld_rbeg; b_len[ld_idx]<=ld_len;
    end

    // ---- per-seed coordinates for the current index j (combinational) ----
    logic [15:0] j, n;
    logic signed [63:0] len64, qbase, qseg, rbase, rseg;
    always_comb begin
        len64 = $signed({{32{b_len [j][31]}}, b_len [j]});
        qbase = $signed({{32{b_qbeg[j][31]}}, b_qbeg[j]});
        qseg  = qbase + len64;                 // qbeg + len
        rbase = b_rbeg[j];                      // already signed 64
        rseg  = rbase + len64;                 // rbeg + len
    end

    typedef enum logic [1:0] { S_IDLE, S_Q, S_R, S_DONE } st_t;
    st_t state;
    logic signed [63:0] endv, wq, wr;
    assign busy = (state != S_IDLE);

    localparam logic signed [63:0] CAP = 64'sd1073741824;   // 1<<30

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state<=S_IDLE; done<=1'b0; w<='0;
        end else begin
            done<=1'b0;
            case (state)
                S_IDLE: if (start) begin
                    n<=n_in; j<=16'd0; endv<=64'd0; wq<=64'd0; wr<=64'd0;
                    state <= (n_in==16'd0) ? S_DONE : S_Q;
                end

                // pass 1 — query coverage
                S_Q: begin
                    if (qbase >= endv)      wq <= wq + len64;
                    else if (qseg > endv)   wq <= wq + (qseg - endv);
                    if (j + 16'd1 >= n) begin
                        j<=16'd0; endv<=64'd0; state<=S_R;   // reset for pass 2 (overrides max below)
                    end else begin
                        j<=j+16'd1; endv <= (endv > qseg) ? endv : qseg;
                    end
                end

                // pass 2 — reference coverage
                S_R: begin
                    if (rbase >= endv)      wr <= wr + len64;
                    else if (rseg > endv)   wr <= wr + (rseg - endv);
                    if (j + 16'd1 >= n) state<=S_DONE;
                    else begin j<=j+16'd1; endv <= (endv > rseg) ? endv : rseg; end
                end

                S_DONE: begin
                    // w = min(wq,wr), capped at (1<<30)-1
                    if (wq < wr) w <= (wq >= CAP) ? 32'sd1073741823 : wq[31:0];
                    else         w <= (wr >= CAP) ? 32'sd1073741823 : wr[31:0];
                    done<=1'b1; state<=S_IDLE;
                end
                default: state<=S_IDLE;
            endcase
        end
    end
endmodule
