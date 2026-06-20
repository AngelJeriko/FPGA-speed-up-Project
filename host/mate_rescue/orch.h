// orch.h — C++ model of mate-rescue ORCHESTRATION (mem_matesw / the !MATE_SORT
// mem_matesw_batch_post, bwamem_pair.cpp). One step above the SW kernel: given a
// mapped mate's alnreg, the unmapped mate's sequence, the pair-orientation stats,
// and the (host-fed) reference windows, it produces the rescue alnreg(s) appended
// to the mate's list — bit-exact with bwa-mem2.
//
// SCOPE — Stage-1 "host-fed reference" (mirrors the extend-orchestrator decision):
// the model does NOT call bns_fetch_seq; each non-skipped orientation's post-fetch
// window {rb, re, rid, ref[]} is supplied (captured on the remote). The model owns
// everything else: the skip[4] decision (mem_infer_dir), the reverse-complement,
// the gate, the SW (hw_align2 from hw.h == ksw_align2), the kswr→alnreg transform,
// the insertion-sort by score, and the per-orientation mem_sort_dedup_patch.
//
// Faithful to mem_matesw_batch_post (!MATE_SORT path, bwamem_pair.cpp:1095-1248).
// REAL-DATA VALIDATED 2026-06-19 (orch_capture.inc, HG00733 50k pairs, 100000 calls):
// check_orch ALL PASS, 0 non-fallback failures. Bit-exact on rb/re/qb/qe/score/is_alt/
// seedcov EXCEPT mr_dedup sort-key TIES, where real's unstable ks_introsort reorders
// equal elements differently from std::stable_sort (changing which identical-key alnreg
// survives -> seedcov/order). Those tie arrays are a SW-FALLBACK (the `fb` flag in
// mr_dedup/matesw_orchestrate; ~1.66% of calls, an over-approx of the true ~0.04%
// divergence; the RTL matesw_dedup detects the same way). csub (=aln.score2) is
// NOT modeled (hw.h omits score2; mem_matesw stores it but it is not a sort/dedup
// key and never affects the consumed ma_out fields) — so csub is excluded from the
// comparison, like the kernel-level check.
#pragma once
#include <cstdint>
#include <vector>
#include <algorithm>
#include "ksw_ref.h"   // KSW_X* + kswr_t types
#include "hw.h"         // hw_align2

struct MAln {            // subset of mem_alnreg_t the orchestration touches
    int64_t rb, re; int qb, qe;
    int rid, is_alt, score, sub, csub, seedcov, truesc, w, n_comp, secondary;
};
struct MOpt { int a=1, b=4, o_del=6, e_del=1, o_ins=6, e_ins=1, min_seed_len=19;
              int max_chain_gap=10000; float mask_level_redun=0.95f; };
struct MPes { int failed; int64_t low, high; };   // avg/std unused by mate-rescue
struct MWin { int used;                            // orientation reached the gate
              int64_t rb, re; int rid;             // post-bns_fetch_seq values
              std::vector<uint8_t> ref; };         // length re-rb (only if SW ran)

static inline void mr_fill_scmat(int a, int b, int8_t mat[25]) {
    int i, j, k;
    for (i = k = 0; i < 4; ++i) { for (j = 0; j < 4; ++j) mat[k++] = i==j? a : -b; mat[k++] = -1; }
    for (j = 0; j < 5; ++j) mat[k++] = -1;
}

// bwamem_pair.cpp:58 — verbatim.
static inline int mr_infer_dir(int64_t l_pac, int64_t b1, int64_t b2, int64_t* dist) {
    int64_t p2; int r1 = (b1 >= l_pac), r2 = (b2 >= l_pac);
    p2 = r1 == r2? b2 : (l_pac<<1) - 1 - b2;
    *dist = p2 > b1? p2 - b1 : b1 - p2;
    return (r1 == r2? 0 : 1) ^ (p2 > b1? 0 : 3);
}

// mem_sort_dedup_patch (bwamem.cpp) for the host-fed (pac=0) case: the SW-merge
// branch (mem_patch_reg) is omitted — it needs the reference and was measured to
// fire 0× (docs/merge_sorter_v2_design.md). STABLE re-sort: mate-rescue ma arrays
// are tiny (n far below the introsort insertion-sort threshold), where ks_introsort
// IS insertion sort == stable; equal-re ties therefore match. Validate vs capture.
static inline bool mr_re_lt(const MAln& x, const MAln& y) { return x.re < y.re; }
static inline bool mr_score_lt(const MAln& x, const MAln& y) {
    if (x.score != y.score) return x.score > y.score;
    if (x.rb    != y.rb)    return x.rb    < y.rb;
    return x.qb < y.qb;
}
// fb (optional): set true if the dedup has a sort-key TIE (adjacent equal `re` in the
// re-sort, or equal (score,rb,qb) in the score-sort). Real mem_sort_dedup_patch uses
// UNSTABLE ks_introsort, which reorders such ties differently from this std::stable_sort
// (even for small arrays — the introsort partition can swap equal elements), changing
// which identical-key alnreg survives (its seedcov / order). So tie arrays are a
// SW-fallback condition (cf. merge-sorter equal-re tie / chaining dup-pos). Measured
// ~0.04% of mem_matesw calls. The RTL matesw_dedup detects the same way.
static inline int mr_dedup(const MOpt& o, std::vector<MAln>& a, bool* fb=nullptr) {
    int n = (int)a.size(), m, i, j;
    if (n <= 1) return n;
    std::stable_sort(a.begin(), a.end(), mr_re_lt);
    if (fb) for (i = 1; i < n; ++i) if (a[i].re == a[i-1].re) { *fb = true; break; }
    for (i = 0; i < n; ++i) a[i].n_comp = 1;
    for (i = 1; i < n; ++i) {
        MAln* p = &a[i];
        if (p->rid != a[i-1].rid || p->rb >= a[i-1].re + o.max_chain_gap) continue;
        for (j = i - 1; j >= 0 && p->rid == a[j].rid && p->rb < a[j].re + o.max_chain_gap; --j) {
            MAln* q = &a[j];
            int64_t or_, oq, mr, mq;
            if (q->qe == q->qb) continue;
            or_ = q->re - p->rb;
            oq = q->qb < p->qb? q->qe - p->qb : p->qe - q->qb;
            mr = q->re - q->rb < p->re - p->rb? q->re - q->rb : p->re - p->rb;
            mq = q->qe - q->qb < p->qe - p->qb? q->qe - q->qb : p->qe - p->qb;
            // mask_level_redun = 0.95. Real bwa-mem2 computes this in FLOAT; the HW
            // (matesw_dedup) uses the proven integer surrogate 20*ov > 19*minlen.
            // Build the RTL vector generators with -DMR_DEDUP_INT so the oracle
            // matches the HW; the surrogate-vs-float gap on REAL data is assessed at
            // capture (check_orch), mirroring the merge-sorter v2 methodology.
#ifdef MR_DEDUP_INT
            bool redundant = (20*or_ > 19*mr) && (20*oq > 19*mq);
#else
            bool redundant = (or_ > o.mask_level_redun * mr) && (oq > o.mask_level_redun * mq);
#endif
            if (redundant) {
                if (p->score < q->score) { p->qe = p->qb; break; }
                else q->qe = q->qb;
            }
            // mem_patch_reg SW-merge branch omitted (never fires; needs reference)
        }
    }
    for (i = 0, m = 0; i < n; ++i) if (a[i].qe > a[i].qb) { if (m != i) a[m++] = a[i]; else ++m; }
    n = m;
    a.resize(n);
    std::stable_sort(a.begin(), a.end(), mr_score_lt);
    if (fb) for (i = 1; i < n; ++i)
        if (a[i].score==a[i-1].score && a[i].rb==a[i-1].rb && a[i].qb==a[i-1].qb) { *fb = true; break; }
    for (i = 1; i < n; ++i)
        if (a[i].score==a[i-1].score && a[i].rb==a[i-1].rb && a[i].qb==a[i-1].qb) a[i].qe = a[i].qb;
    for (i = 1, m = 1; i < n; ++i) if (a[i].qe > a[i].qb) { if (m != i) a[m++] = a[i]; else ++m; }
    a.resize(m);
    return m;
}

// One mem_matesw call: mutates `ma` in place (the unmapped mate's list), returns n
// (= number of orientations whose gate passed, matching the source's `n`).
static inline int matesw_orchestrate(const MOpt& o, int64_t l_pac, const MAln& a,
                                     int l_ms, const uint8_t* ms,
                                     const MPes pes[4], const MWin win[4],
                                     std::vector<MAln>& ma, bool* fb=nullptr) {
    int skip[4];
    for (int r = 0; r < 4; ++r) skip[r] = pes[r].failed? 1 : 0;
    for (size_t i = 0; i < ma.size(); ++i) {
        int64_t dist; int r = mr_infer_dir(l_pac, a.rb, ma[i].rb, &dist);
        if (dist >= pes[r].low && dist <= pes[r].high) skip[r] = 1;
    }
    if (skip[0] + skip[1] + skip[2] + skip[3] == 4) return 0;

    int8_t mat[25]; mr_fill_scmat(o.a, o.b, mat);
    std::vector<uint8_t> rev(l_ms);
    int n = 0;
    for (int r = 0; r < 4; ++r) {
        if (skip[r]) continue;
        int is_rev = (r>>1 != (r&1));
        const uint8_t* seq;
        if (is_rev) { for (int i = 0; i < l_ms; ++i) rev[l_ms-1-i] = ms[i] < 4? 3 - ms[i] : 4; seq = rev.data(); }
        else seq = ms;

        // A fetch happened (rb<re) iff win.used; only then is the gate evaluable.
        // The `if(n) dedup` below ALWAYS runs for a non-skipped orientation
        // (bwamem_pair.cpp:1238), even when no fetch / the gate fails — so this is
        // NOT an early continue.
        const MWin& wn = win[r];
        if (wn.used) {
            int64_t rb = wn.rb, re = wn.re; int rid = wn.rid;
            if (a.rid == rid && re - rb >= o.min_seed_len) {
                int xtra = KSW_XSUBO | KSW_XSTART | (l_ms * o.a < 250? KSW_XBYTE : 0) | (o.min_seed_len * o.a);
                HR aln = hw_align2(l_ms, seq, (int)(re - rb), wn.ref.data(), mat,
                                   o.o_del, o.e_del, o.o_ins, o.e_ins, xtra);
                if (aln.score >= o.min_seed_len && aln.qb >= 0) {
                    MAln b{}; b.rid = a.rid; b.is_alt = a.is_alt;
                    b.qb = is_rev? l_ms - (aln.qe + 1) : aln.qb;
                    b.qe = is_rev? l_ms - aln.qb : aln.qe + 1;
                    b.rb = is_rev? (l_pac<<1) - (rb + aln.te + 1) : rb + aln.tb;
                    b.re = is_rev? (l_pac<<1) - (rb + aln.tb) : rb + aln.te + 1;
                    b.score = aln.score; b.csub = 0 /*score2 n/a*/; b.secondary = -1;
                    b.seedcov = (int)((b.re - b.rb < b.qe - b.qb? b.re - b.rb : b.qe - b.qb) >> 1);
                    // insertion-sort b into ma by score (descending), as in source
                    ma.push_back(b);
                    int i, tmp, na = (int)ma.size();
                    for (i = 0; i < na - 1; ++i) if (ma[i].score < b.score) break;
                    tmp = i;
                    for (i = na - 1; i > tmp; --i) ma[i] = ma[i-1];
                    ma[i] = b;
                }
                ++n;
            }
        }
        if (n) mr_dedup(o, ma, fb);        // per-orientation dedup (!MATE_SORT)
    }
    return n;
}
