// bsw_score_matrix.sv
// Combinational 5x5 substitution-matrix lookup.
// Indexing matches BWA-MEM2: mat[q * M + t].

`include "bsw_pkg.sv"

module bsw_score_matrix
    import bsw_pkg::*;
#(
    parameter score_t W_MATCH_P    = score_t'(W_MATCH),
    parameter score_t W_MISMATCH_P = score_t'(W_MISMATCH),
    parameter score_t W_AMBIG_P    = score_t'(W_AMBIG)
)(
    input  base_t  q,
    input  base_t  t,
    output score_t s
);

    // A,C,G,T are 0..3; N is 4; anything else also treated as ambiguous.
    wire q_is_n = (q == base_t'(4));
    wire t_is_n = (t == base_t'(4));
    wire q_oob  = (q > base_t'(4));
    wire t_oob  = (t > base_t'(4));

    assign s = (q_oob || t_oob || q_is_n || t_is_n) ? W_AMBIG_P
             : (q == t)                              ? W_MATCH_P
             :                                        W_MISMATCH_P;

endmodule
