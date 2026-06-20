// chain.h — C++ model of bwa-mem2 seed chaining (mem_chain + mem_chain_flt),
// per read. The kbtree-of-chains is replaced by a sorted-by-pos array with a
// predecessor query, which returns the SAME `lower` chain the kbtree does, so the
// chaining output is identical. Faithful to bwamem.cpp; integer surrogates for the
// 0.5 float ratios are exact. See docs/chaining_engine_scope.md.
//
// REAL-DATA VALIDATION 2026-06-19 -- BIT-EXACT, check_capture ALL PASS (HG00733 50k pairs,
// 30000 reads each of mem_chain + mem_chain_flt):
//   - mem_chain_flt : 0 failures. FIXED by porting klib ks_introsort(mem_flt) VERBATIM (below)
//     -- the model's std::stable_sort reordered equal-weight ties; ks_introsort is unstable.
//     (An apparent 1125 residual was a CAPTURE BUG: mem_chain_flt free()s dropped chains' seeds
//     [SEEDS_PER_CHAIN=1], and the old HOOK-C shallow snapshot was written after the call ->
//     garbage; chain_capture.inc HOOK-C now deep-copies. Re-capture -> 0.)
//   - mem_chain     : 0 NON-FALLBACK failures. Two fixes make the sorted-array predecessor
//     match the kbtree: (1) predecessor = kb_intervalp (exact pos -> LEFTMOST equal; else
//     rightmost pos<key); (2) new chains insert at lo+1 (kb_putp position), replicating the
//     kbtree array order for duplicate pos. A multi-node B-tree still reorders dup-pos chains
//     in ways a flat array cannot, so DUPLICATE-POS reads are a SW-FALLBACK condition (the `fb`
//     flag below; ~3-4% of reads, ~0.4% runtime; a superset of the true ~0.8% divergence --
//     measured, all real divergences caught). The RTL detects it the same way (dup-pos insert).
//   So chain.h is the bit-exact sorted-array reference for the chaining RTL, with the dup-pos
//   SW-fallback (cf. merge-sorter equal-re tie / accel n>1024). Vectors: vectors/chain_vec.bin.
#pragma once
#include <cstdint>
#include <cstdlib>
#include <vector>
#include <algorithm>

struct CSeed { int64_t rbeg; int qbeg, len, score; };
struct CChain {
    int rid, seqid; int64_t pos; bool is_alt;
    std::vector<CSeed> seeds;
    int w = 0, first = -1, kept = 0;
};
struct COpt { int w=100, max_chain_gap=10000, min_seed_len=19, a=1;
              int min_chain_weight=0, max_chain_extend=(1<<30);
              // mask_level=drop_ratio=0.5 -> exact integer surrogates below
            };

// bwamem.cpp:test_and_merge — append seed s to chain c if colinear. 1=merged/absorbed.
static inline int c_test_and_merge(const COpt& o, int64_t l_pac, CChain& c,
                                   const CSeed& p, int seed_rid) {
    const CSeed& last = c.seeds[c.seeds.size()-1];
    int64_t qend = last.qbeg + last.len, rend = last.rbeg + last.len, x, y;
    if (seed_rid != c.rid) return 0;
    if (p.qbeg >= c.seeds[0].qbeg && p.qbeg + p.len <= qend &&
        p.rbeg >= c.seeds[0].rbeg && p.rbeg + p.len <= rend) return 1;   // contained
    if ((last.rbeg < l_pac || c.seeds[0].rbeg < l_pac) && p.rbeg >= l_pac) return 0; // strand
    x = p.qbeg - last.qbeg; y = p.rbeg - last.rbeg;
    if (y >= 0 && x - y <= o.w && y - x <= o.w &&
        x - last.len < o.max_chain_gap && y - last.len < o.max_chain_gap) {
        c.seeds.push_back(p); return 1;
    }
    return 0;
}

// bwamem.cpp:mem_chain_weight
static inline int c_chain_weight(const CChain& c) {
    int64_t end; int j, w = 0, tmp;
    for (j = 0, end = 0; j < (int)c.seeds.size(); ++j) {
        const CSeed& s = c.seeds[j];
        if (s.qbeg >= end) w += s.len;
        else if (s.qbeg + s.len > end) w += s.qbeg + s.len - end;
        end = end > s.qbeg + s.len ? end : s.qbeg + s.len;
    }
    tmp = w; w = 0;
    for (j = 0, end = 0; j < (int)c.seeds.size(); ++j) {
        const CSeed& s = c.seeds[j];
        if (s.rbeg >= end) w += s.len;
        else if (s.rbeg + s.len > end) w += s.rbeg + s.len - end;
        end = end > s.rbeg + s.len ? end : s.rbeg + s.len;
    }
    w = w < tmp ? w : tmp;
    return w < (1<<30) ? w : (1<<30)-1;
}

// mem_chain over one read's ordered seed stream. seeds[i] carries rid[i].
// fb (optional): set true if a DUPLICATE pos chain is created. The sorted-array
// predecessor matches the kbtree EXACTLY for distinct pos and for single-node dup pos,
// but a multi-node B-tree reorders dup-pos chains in ways a flat array cannot reproduce
// (and that order feeds the unstable mem_chain_flt sort). So duplicate-pos reads are a
// SW-fallback condition for the RTL (measured ~2.79% of reads, ~0.3% runtime; a superset
// of the real divergences — see docs/chaining_engine_scope.md). The RTL detects this the
// same way: a new chain whose pos equals an existing chain's pos.
static inline std::vector<CChain> c_mem_chain(const COpt& o, int64_t l_pac, int seqid,
        const std::vector<CSeed>& seeds, const std::vector<int>& rid,
        const std::vector<bool>& is_alt, bool* fb = nullptr) {
    if (fb) *fb = false;
    std::vector<CChain> chains;   // kept sorted by pos ascending (kbtree replacement)
    for (size_t i = 0; i < seeds.size(); ++i) {
        const CSeed& s = seeds[i];
        // predecessor matching klib kb_intervalp (single-leaf): an EXACT pos match
        // returns the LEFTMOST equal chain; otherwise the RIGHTMOST chain with pos <
        // s.rbeg (last of the predecessor group). (The model picked rightmost-<=, which
        // differs on exact dup-pos matches — the real-data mem_chain discrepancy.)
        int beg = 0, nc_ = (int)chains.size();
        while (beg < nc_ && chains[beg].pos < s.rbeg) ++beg;
        int lo = (beg < nc_ && chains[beg].pos == s.rbeg) ? beg : beg - 1;
        int to_add = 1;
        if (lo >= 0 && c_test_and_merge(o, l_pac, chains[lo], s, rid[i])) to_add = 0;
        if (to_add) {
            if (fb && lo >= 0 && chains[lo].pos == s.rbeg) *fb = true;  // duplicate pos -> SW fallback
            CChain nc; nc.rid = rid[i]; nc.seqid = seqid; nc.pos = s.rbeg;
            nc.is_alt = is_alt[i]; nc.seeds.push_back(s);
            // kb_putp inserts at __kb_getp_aux(k)+1 = lo+1. For duplicate pos this yields
            // the kbtree's array order [first, newest, .., second] that __kb_traverse emits
            // (NOT plain insertion order); still keeps the array sorted by pos.
            chains.insert(chains.begin() + (lo + 1), nc);
        }
    }
    return chains;
}

// ---- EXACT port of klib ks_introsort(mem_flt) (ksort.h), comparator flt_lt(a,b)=
//      (a.w > b.w). Verbatim: median-of-3 pivot, threshold-16 quicksort, combsort on
//      depth-limit, final whole-array insertion sort. Reproduces bwa's UNSTABLE
//      equal-weight tie order bit-exact (std::stable_sort did not). ------------------
struct ks_isort_stack_t { CChain *left, *right; int depth; };
static inline bool flt_lt(const CChain& a, const CChain& b){ return a.w > b.w; }
static inline void ks_insertsort_memflt(CChain* s, CChain* t){
    CChain *i, *j, swap_tmp;
    for (i = s + 1; i < t; ++i)
        for (j = i; j > s && flt_lt(*j, *(j-1)); --j){ swap_tmp = *j; *j = *(j-1); *(j-1) = swap_tmp; }
}
static inline void ks_combsort_memflt(size_t n, CChain a[]){
    const double shrink_factor = 1.2473309501039786540366528676643;
    int do_swap; size_t gap = n; CChain tmp, *i, *j;
    do {
        if (gap > 2){ gap = (size_t)(gap / shrink_factor); if (gap==9||gap==10) gap=11; }
        do_swap = 0;
        for (i = a; i < a + n - gap; ++i){ j = i + gap;
            if (flt_lt(*j, *i)){ tmp = *i; *i = *j; *j = tmp; do_swap = 1; } }
    } while (do_swap || gap > 2);
    if (gap != 1) ks_insertsort_memflt(a, a + n);
}
// `comb` (optional, additive): set true if the depth limit is ever hit and combsort runs.
// The RTL chain_introsort treats that as a SW-fallback condition (it can't reproduce the
// float gap division bit-exact), so the generator emits this to flag expected-fallback cases.
// Combsort only fires on median-of-3-adversarial input -> ~never for chain-count arrays.
static inline void ks_introsort_memflt(size_t n, CChain a[], bool* comb=nullptr){
    int d; ks_isort_stack_t *top, *stack; CChain rp, swap_tmp; CChain *s, *t, *i, *j, *k;
    if (n < 1) return;
    else if (n == 2){ if (flt_lt(a[1], a[0])){ swap_tmp=a[0]; a[0]=a[1]; a[1]=swap_tmp; } return; }
    for (d = 2; (size_t)(1ul<<d) < n; ++d);
    stack = (ks_isort_stack_t*)malloc(sizeof(ks_isort_stack_t) * ((sizeof(size_t)*d)+2));
    top = stack; s = a; t = a + (n-1); d <<= 1;
    while (1){
        if (s < t){
            if (--d == 0){ if (comb) *comb = true; ks_combsort_memflt(t - s + 1, s); t = s; continue; }
            i = s; j = t; k = i + ((j-i)>>1) + 1;
            if (flt_lt(*k, *i)){ if (flt_lt(*k, *j)) k = j; }
            else k = flt_lt(*j, *i)? i : j;
            rp = *k;
            if (k != t){ swap_tmp = *k; *k = *t; *t = swap_tmp; }
            for (;;){
                do ++i; while (flt_lt(*i, rp));
                do --j; while (i <= j && flt_lt(rp, *j));
                if (j <= i) break;
                swap_tmp = *i; *i = *j; *j = swap_tmp;
            }
            swap_tmp = *i; *i = *t; *t = swap_tmp;
            if (i-s > t-i){
                if (i-s > 16){ top->left = s; top->right = i-1; top->depth = d; ++top; }
                s = t-i > 16? i+1 : t;
            } else {
                if (t-i > 16){ top->left = i+1; top->right = t; top->depth = d; ++top; }
                t = i-s > 16? i-1 : s;
            }
        } else {
            if (top == stack){ free(stack); ks_insertsort_memflt(a, a+n); return; }
            else { --top; s = top->left; t = top->right; d = top->depth; }
        }
    }
}

// bwamem.cpp:mem_chain_flt (per read = one seqid group).
static inline std::vector<CChain> c_mem_chain_flt(const COpt& o, std::vector<CChain> a) {
    if (a.empty()) return a;
    // weight + drop (min_chain_weight default 0 -> nothing dropped)
    std::vector<CChain> b;
    for (auto& c : a) { c.first=-1; c.kept=0; c.w=c_chain_weight(c);
        if (c.w >= o.min_chain_weight) b.push_back(c); }
    int n = (int)b.size(); if (n == 0) return b;
    // sort by weight desc using the EXACT ks_introsort(mem_flt) port (flt_lt: a.w>b.w),
    // so equal-weight tie order matches bwa bit-exact (real-data validated 2026-06-19).
    ks_introsort_memflt((size_t)n, b.data());
    auto cbeg = [](const CChain&c){ return c.seeds[0].qbeg; };
    auto cend = [](const CChain&c){ return c.seeds.back().qbeg + c.seeds.back().len; };
    std::vector<int> keptlist;
    b[0].kept = 3; keptlist.push_back(0);
    for (int i = 1; i < n; ++i) {
        int large_ovlp = 0, k;
        for (k = 0; k < (int)keptlist.size(); ++k) {
            int j = keptlist[k];
            int b_max = cbeg(b[j]) > cbeg(b[i]) ? cbeg(b[j]) : cbeg(b[i]);
            int e_min = cend(b[j]) < cend(b[i]) ? cend(b[j]) : cend(b[i]);
            if (e_min > b_max && (!b[j].is_alt || b[i].is_alt)) {
                int li = cend(b[i]) - cbeg(b[i]), lj = cend(b[j]) - cbeg(b[j]);
                int min_l = li < lj ? li : lj;
                // mask_level=0.5: e_min-b_max >= min_l*0.5  <=>  2*(e_min-b_max) >= min_l
                if (2*(e_min - b_max) >= min_l && min_l < o.max_chain_gap) {
                    large_ovlp = 1;
                    if (b[j].first < 0) b[j].first = i;
                    // drop_ratio=0.5: b[i].w < b[j].w*0.5  <=>  2*b[i].w < b[j].w
                    if (2*b[i].w < b[j].w && b[j].w - b[i].w >= (o.min_seed_len<<1)) break;
                }
            }
        }
        if (k == (int)keptlist.size()) { keptlist.push_back(i); b[i].kept = large_ovlp ? 2 : 3; }
    }
    for (int i = 0; i < (int)keptlist.size(); ++i)
        if (b[keptlist[i]].first >= 0) b[b[keptlist[i]].first].kept = 1;
    int i, k;
    for (i = k = 0; i < n; ++i) { if (b[i].kept == 0 || b[i].kept == 3) continue; if (++k >= o.max_chain_extend) break; }
    for (; i < n; ++i) if (b[i].kept < 3) b[i].kept = 0;
    std::vector<CChain> out;
    for (i = 0; i < n; ++i) if (b[i].kept != 0) out.push_back(b[i]);
    return out;
}
