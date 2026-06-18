// chain.h — C++ model of bwa-mem2 seed chaining (mem_chain + mem_chain_flt),
// per read. The kbtree-of-chains is replaced by a sorted-by-pos array with a
// predecessor query, which returns the SAME `lower` chain the kbtree does, so the
// chaining output is identical. Faithful to bwamem.cpp; integer surrogates for the
// 0.5 float ratios are exact. NOTE: validated bit-exact only after the remote
// capture of real (seed-stream -> chains) vectors (the real mem_chain can't be
// compiled standalone — kbtree/bns/FM-index deps). See docs/chaining_engine_scope.md.
#pragma once
#include <cstdint>
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
static inline std::vector<CChain> c_mem_chain(const COpt& o, int64_t l_pac, int seqid,
        const std::vector<CSeed>& seeds, const std::vector<int>& rid,
        const std::vector<bool>& is_alt) {
    std::vector<CChain> chains;   // kept sorted by pos ascending (kbtree replacement)
    for (size_t i = 0; i < seeds.size(); ++i) {
        const CSeed& s = seeds[i];
        // predecessor: chain with the largest pos <= s.rbeg
        int lo = -1;
        for (int c = 0; c < (int)chains.size(); ++c) {
            if (chains[c].pos <= s.rbeg) lo = c; else break;   // sorted -> first > breaks
        }
        int to_add = 1;
        if (lo >= 0 && c_test_and_merge(o, l_pac, chains[lo], s, rid[i])) to_add = 0;
        if (to_add) {
            CChain nc; nc.rid = rid[i]; nc.seqid = seqid; nc.pos = s.rbeg;
            nc.is_alt = is_alt[i]; nc.seeds.push_back(s);
            // insert keeping sorted-by-pos (stable for equal pos: after existing)
            int ins = (int)chains.size();
            for (int c = 0; c < (int)chains.size(); ++c) if (chains[c].pos > nc.pos) { ins = c; break; }
            chains.insert(chains.begin() + ins, nc);
        }
    }
    return chains;
}

// bwamem.cpp:mem_chain_flt (per read = one seqid group).
static inline std::vector<CChain> c_mem_chain_flt(const COpt& o, std::vector<CChain> a) {
    if (a.empty()) return a;
    // weight + drop (min_chain_weight default 0 -> nothing dropped)
    std::vector<CChain> b;
    for (auto& c : a) { c.first=-1; c.kept=0; c.w=c_chain_weight(c);
        if (c.w >= o.min_chain_weight) b.push_back(c); }
    int n = (int)b.size(); if (n == 0) return b;
    // sort by weight desc (ks_introsort mem_flt = flt_lt: a.w > b.w). UNSTABLE in
    // bwa; ties may need a fallback (validate vs capture). stable here for determinism.
    std::stable_sort(b.begin(), b.end(), [](const CChain&x, const CChain&y){ return x.w > y.w; });
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
