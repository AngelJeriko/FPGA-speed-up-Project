// v2_dedup.h — C++ reference model of the FULL mem_sort_dedup_patch (v2 engine).
//
// Reproduces bwa-mem2's mem_sort_dedup_patch (bwamem.cpp ~387-453) for the
// hardware-handled case: stable re-sort + integer redundancy de-overlap + score
// sort + identical-hit removal. This is what the v2 FPGA engine implements.
//
// SELF-CONTAINED (no sequence data): the SW-merge branch (mem_patch_reg, "branch
// B") is OMITTED because it was measured to fire 0 times in 20.09M arrays on
// short reads (docs/merge_sorter_v2_design.md). Arrays that would need it (or that
// contain an equal-re tie, or n>1024) take the software fallback and are not the
// hardware's responsibility. For the captured short-read vectors, omitting branch
// B is exact: even when its condition is reached, mem_patch_reg never returned >0,
// so no mutation occurred.
//
// Defaults match mem_opt_init (bwamem.cpp): max_chain_gap=10000,
// mask_level_redun=0.95f (FLOAT — the comparison is done in float, matching the
// production expression `or_ > opt->mask_level_redun * mr`).
#pragma once
#include <algorithm>
#include <cstdint>

struct V2Key { int64_t rb, re; int32_t qb, qe, rid, score; };

static const int   V2_MAX_CHAIN_GAP    = 10000;
static const float V2_MASK_LEVEL_REDUN = 0.95f;

// stable re-sort key (alnreg_slt2): re ascending
static inline bool v2_re_lt(const V2Key& x, const V2Key& y) { return x.re < y.re; }
// score sort (alnreg_slt): score desc, rb asc, qb asc
static inline bool v2_score_lt(const V2Key& x, const V2Key& y) {
    if (x.score != y.score) return x.score > y.score;
    if (x.rb    != y.rb)    return x.rb    < y.rb;
    return x.qb < y.qb;
}

// Dedup in place; returns the final survivor count, a[0..ret) holds the output.
static inline int v2_dedup(V2Key* a, int n) {
    int m, i, j;
    if (n <= 1) return n;
    std::stable_sort(a, a + n, v2_re_lt);                // STABLE re-sort (hardware)

    for (i = 1; i < n; ++i) {
        V2Key* p = &a[i];
        if (p->rid != a[i-1].rid || p->rb >= a[i-1].re + V2_MAX_CHAIN_GAP) continue;
        for (j = i - 1; j >= 0 && p->rid == a[j].rid && p->rb < a[j].re + V2_MAX_CHAIN_GAP; --j) {
            V2Key* q = &a[j];
            int64_t or_, oq, mr, mq;
            if (q->qe == q->qb) continue;                // a[j] excluded
            or_ = q->re - p->rb;
            oq = q->qb < p->qb ? q->qe - p->qb : p->qe - q->qb;
            mr = q->re - q->rb < p->re - p->rb ? q->re - q->rb : p->re - p->rb;
            mq = q->qe - q->qb < p->qe - p->qb ? q->qe - q->qb : p->qe - p->qb;
            if (or_ > V2_MASK_LEVEL_REDUN * mr && oq > V2_MASK_LEVEL_REDUN * mq) { // redundant
                if (p->score < q->score) { p->qe = p->qb; break; }
                else q->qe = q->qb;
            }
            // branch B (mem_patch_reg SW merge) omitted — never fires (measured 0)
        }
    }
    for (i = 0, m = 0; i < n; ++i) if (a[i].qe > a[i].qb) { if (m != i) a[m++] = a[i]; else ++m; }
    n = m;
    std::stable_sort(a, a + n, v2_score_lt);             // score sort (v1; total order)
    for (i = 1; i < n; ++i)                              // mark identical (score,rb,qb)
        if (a[i].score==a[i-1].score && a[i].rb==a[i-1].rb && a[i].qb==a[i-1].qb) a[i].qe = a[i].qb;
    for (i = 1, m = 1; i < n; ++i) if (a[i].qe > a[i].qb) { if (m != i) a[m++] = a[i]; else ++m; }
    return m;
}
