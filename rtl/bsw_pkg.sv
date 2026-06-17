// bsw_pkg.sv
// Parameters and types for the banded Smith-Waterman accelerator.
// Reference: bwa-mem2/src/bandedSWA.cpp :: BandedPairWiseSW::scalarBandedSWA

`ifndef BSW_PKG_SV
`define BSW_PKG_SV

package bsw_pkg;

    // ---- Sequence sizing ----
    // Sized for real bwa-mem2 150bp short-read extension. Measured maxima over
    // 747,258 captured ksw_extend2 calls (hg38 chr1-5 / HG00733): qlen<=131,
    // tlen<=786, ref window<=811. MAX_QLEN/N_PE carry headroom to 160; MAX_TLEN
    // rounds to 1024 (power of 2). Because the systolic array computes the FULL
    // DP (one PE per query base, no in-array banding), it is bit-exact with the
    // banded C++ ksw_extend2 only while 2*w+1 >= qlen; with the default band
    // w=100 and qlen<=160, 2*100+1=201 covers the whole query, so banding is a
    // no-op and the result matches. (See docs / measure_dims.cpp.)
    parameter int MAX_QLEN     = 160;
    parameter int MAX_TLEN     = 1024;
    parameter int LEN_WIDTH    = 16;  // wide enough for both lengths and i/j indices

    // ---- Alphabet (A,C,G,T,N) ----
    parameter int M_ALPHABET   = 5;
    parameter int BASE_WIDTH   = 3;   // ceil(log2(5))

    // ---- Score width ----
    // With qlen<=160 and match score up to a few units, H stays within ~11 bits
    // (peak ~ qlen + h0 + end_bonus, well under 2^15). 16-bit signed gives ample
    // headroom and matches the C++ 16-bit SIMD path.
    parameter int SCORE_WIDTH  = 16;

    // ---- Systolic array sizing ----
    // PEs in the linear array. Each PE holds one query position and computes one
    // (H,E,F) cell per cycle. The array is full-width (one PE per query base), so
    // qlen must be <= N_PE (= BAND_WIDTH); a request with qlen > N_PE is rejected
    // by the FSM. BAND_WIDTH must therefore be >= MAX_QLEN.
    parameter int BAND_WIDTH   = 160;
    parameter int PE_IDX_WIDTH = $clog2(BAND_WIDTH);

    // ---- Default scoring (BWA-MEM2 defaults) ----
    parameter int W_MATCH      =  1;
    parameter int W_MISMATCH   = -4;
    parameter int W_AMBIG      = -1;  // score for N
    parameter int W_O_DEL      =  6;
    parameter int W_E_DEL      =  1;
    parameter int W_O_INS      =  6;
    parameter int W_E_INS      =  1;
    parameter int W_ZDROP      = 100;
    parameter int W_END_BONUS  =  5;
    parameter int W_BAND       = 100;

    // ---- Types ----
    typedef logic signed [SCORE_WIDTH-1:0] score_t;
    typedef logic        [BASE_WIDTH-1:0]  base_t;
    typedef logic        [LEN_WIDTH-1:0]   len_t;

    // Runtime configuration written by the host per alignment.
    // All penalty fields are stored as positive magnitudes; the PE applies the sign.
    typedef struct packed {
        score_t  h0;           // initial H value
        score_t  o_del;        // gap-open  (deletion)
        score_t  e_del;        // gap-extend (deletion)
        score_t  o_ins;        // gap-open  (insertion)
        score_t  e_ins;        // gap-extend (insertion)
        score_t  zdrop;        // z-drop threshold (0 disables)
        score_t  end_bonus;    // end-of-query bonus
        len_t    w;            // band half-width
        len_t    qlen;         // query length
        len_t    tlen;         // target length
    } bsw_config_t;

    // Output result, matches scalarBandedSWA return + reference pointer outputs.
    // `error` is set when the request was rejected — currently the only cause
    // is qlen > BAND_WIDTH (the synthesized PE array width). When error=1, all
    // other result fields are forced to 0 to prevent the host from acting on
    // stale tracker state. The host must check error before using score.
    typedef struct packed {
        logic    error;        // 1 = request rejected (e.g., qlen > N_PE)
        score_t  score;        // max alignment score
        score_t  gscore;       // best score reaching end of query
        len_t    qle;          // query length consumed at max
        len_t    tle;          // target length consumed at max
        len_t    gtle;         // target length consumed at gscore
        len_t    max_off;      // max |i - j| anti-diagonal offset
    } bsw_result_t;

    // ---- Score matrix (5x5, stored row-major, flat) ----
    // Index: mat[q*M_ALPHABET + t]. Matches the BWA-MEM2 convention.
    function automatic score_t default_score(input base_t q, input base_t t);
        if (q >= M_ALPHABET || t >= M_ALPHABET) begin
            return score_t'(W_AMBIG);
        end else if (q == base_t'(4) || t == base_t'(4)) begin
            return score_t'(W_AMBIG);  // any-vs-N
        end else if (q == t) begin
            return score_t'(W_MATCH);
        end else begin
            return score_t'(W_MISMATCH);
        end
    endfunction

endpackage : bsw_pkg

`endif
