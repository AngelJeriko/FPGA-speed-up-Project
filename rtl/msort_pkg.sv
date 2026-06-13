// msort_pkg.sv
// Parameters and types for the alignment-register merge-sorter.
// Reproduces the post-dedup `alnreg_slt` score sort in bwa-mem2
//   (bwa-mem2/src/bwamem.cpp :: mem_sort_dedup_patch, line ~385):
//   score DESCending, then rb ASCending, then qb ASCending.
// Reference C++ model: host/merge_sorter/ (key.h, folded_sorter.h) — verified
// bit-exact vs ks_introsort on 21,386 real vectors (n=2..1060).

`ifndef MSORT_PKG_SV
`define MSORT_PKG_SV

package msort_pkg;

    // ---- Composite key (matches host/merge_sorter/key.h pack_key) ----------
    // One UNSIGNED ascending compare of this 96-bit key == alnreg_slt:
    //   [95:64] ks = 0x7FFFFFFF - score   (32b)  larger score -> smaller ks
    //   [63:24] rb                         (40b)  reference begin, ascending
    //   [23: 0] qb                         (24b)  query  begin,    ascending
    parameter int KS_BITS  = 32;
    parameter int RB_BITS  = 40;
    parameter int QB_BITS  = 24;
    parameter int KEY_W    = KS_BITS + RB_BITS + QB_BITS;  // 96

    // ---- Capacity / sizing (measured 2026-06-13: true max n = 1060) --------
    // N_MAX captures 99.97% of sort cost at 1024; n in (1024,1060] -> software
    // fallback on the host (not handled in hardware). The host must not enqueue
    // arrays with n > N_MAX.
    parameter int N_MAX    = 1024;
    parameter int IDX_W    = $clog2(N_MAX);       // 10 : index 0..1023
    parameter int CNT_W    = $clog2(N_MAX + 1);   // 11 : count 0..1024
    parameter int PASS_W   = $clog2(N_MAX + 1);   // run-width counter

    // ---- (key,index) pair carried through the network ----------------------
    parameter int PAIR_W   = KEY_W + IDX_W;       // 106

    typedef logic [KEY_W-1:0]  key_t;
    typedef logic [IDX_W-1:0]  idx_t;
    typedef logic [CNT_W-1:0]  cnt_t;

    // pair packing: {key, idx}; sort on key (high bits) only.
    typedef struct packed {
        key_t key;
        idx_t idx;
    } pair_t;

endpackage : msort_pkg

`endif
