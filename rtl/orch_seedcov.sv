// orch_seedcov.sv
// Seedcov stage of the extend-orchestrator: seedcov = sum of seed.len over the
// chain's seeds fully contained in the alnreg's final [qb,qe) x [rb,re). Streaming
// accumulator — `clear` latches the alnreg coords and resets the sum, then seeds
// are presented one per cycle (in_valid), `in_last` on the final seed; `done`
// pulses with the final `seedcov`. Mirrors the containment test in
// mem_chain2aln_across_reads_V2.
//
// Verified bit-exact vs the C++ model via tb_orch_seedcov + vectors/seedcov_vectors.txt.

module orch_seedcov (
    input  logic               clk,
    input  logic               rst_n,
    // latch alnreg coords + reset accumulator (one cycle, before the seeds)
    input  logic               clear,
    input  logic signed [31:0] qb,
    input  logic signed [31:0] qe,
    input  logic signed [63:0] rb,
    input  logic signed [63:0] re,
    // seed stream
    input  logic               in_valid,
    input  logic signed [63:0] s_rbeg,
    input  logic signed [31:0] s_qbeg,
    input  logic signed [31:0] s_len,
    input  logic               in_last,
    // result
    output logic signed [31:0] seedcov,
    output logic               done
);
    logic signed [31:0] acc, qb_r, qe_r;
    logic signed [63:0] rb_r, re_r;

    logic contained;
    always_comb contained = (s_qbeg >= qb_r) && ((s_qbeg + s_len) <= qe_r) &&
                            (s_rbeg >= rb_r) && ((s_rbeg + 64'(s_len)) <= re_r);
    logic signed [31:0] acc_next;
    always_comb acc_next = acc + (contained ? s_len : 32'sd0);

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            acc <= '0; done <= 1'b0; seedcov <= '0;
        end else begin
            done <= 1'b0;
            if (clear) begin
                acc <= '0; qb_r <= qb; qe_r <= qe; rb_r <= rb; re_r <= re;
            end else if (in_valid) begin
                acc <= acc_next;
                if (in_last) begin
                    seedcov <= acc_next;
                    done    <= 1'b1;
                    acc     <= '0;
                end
            end
        end
    end
endmodule
