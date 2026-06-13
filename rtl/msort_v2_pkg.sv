// msort_v2_pkg.sv
// Types/params for the v2 windowed-dedup engine (de-overlap / redundancy pass of
// mem_sort_dedup_patch). Operates on records already re-sorted by `re` (the sort
// itself reuses the v1 msort_merge_sorter). See docs/merge_sorter_v2_design.md.

`ifndef MSORT_V2_PKG_SV
`define MSORT_V2_PKG_SV

package msort_v2_pkg;

    parameter int      N_MAX = 1024;
    parameter int      IDX_W = $clog2(N_MAX);       // 10
    parameter int      CNT_W = $clog2(N_MAX + 1);   // 11
    parameter longint  GAP   = 64'd10000;           // opt->max_chain_gap default

    // Redundancy threshold mask_level_redun = 0.95f. Integer-exact surrogate:
    //   x > 0.95f*y   <=>   20*x > 19*y   (verified 0 mismatches over the operand
    //   range by host/merge_sorter/check_redun_int.cpp).
    parameter int RED_NUM = 20;   // numerator on x
    parameter int RED_DEN = 19;   // numerator on y

    typedef logic [CNT_W-1:0] cnt_t;   // element counter / index (0..N_MAX)

    // Alignment record (fields used by the dedup). Matches host V2Key.
    typedef struct packed {
        logic signed [63:0] rb;
        logic signed [63:0] re;
        logic signed [31:0] qb;
        logic signed [31:0] qe;
        logic signed [31:0] rid;
        logic signed [31:0] score;
    } rec_t;

endpackage : msort_v2_pkg

`endif
