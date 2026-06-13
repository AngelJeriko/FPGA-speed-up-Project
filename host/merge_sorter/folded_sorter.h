// folded_sorter.h — cycle-approximate model of the FOLDED merge-sorter engine.
//
// "Folded" = one reusable compare/merge datapath swept across the data once per
// pass, instead of a fully-spatial bitonic network (which is impractical at the
// measured N_max = 1060; a spatial bitonic at N=1024 is ~28k compare-exchanges).
//
// Algorithm = classic bottom-up (iterative) merge sort on (key, index) pairs:
//   pass 0: treat the array as n runs of length 1 (already sorted)
//   pass p: merge adjacent runs of length 2^p into runs of 2^(p+1)
//   repeat until one run remains  -> ceil(log2 n) passes
//
// Each pass is ONE streaming sweep of the single merge unit reading from one
// on-chip buffer and writing the other (ping-pong). `passes` is the cycle/
// latency proxy (sweeps over the data); it is what the folded design trades
// against area vs. a fully-spatial network.
//
// Sizing (measured 2026-06-13, chr1-5/HG00733): N_MAX = 1024 captures 99.97% of
// sort cost; n in (1024, 1060] -> software fallback (0.03% of cost). n <= 1 is a
// no-op fast-path. The model sorts EVERY input correctly (so the testbench can
// verify the whole distribution) but flags which path the hardware would take.
#pragma once
#include <vector>
#include <cstdint>
#include "key.h"

static constexpr int N_MAX = 1024;   // hardware sorter capacity / fallback threshold

enum class SortPath { FastPathN1, Hardware, SoftwareFallback };

struct FoldedResult {
    std::vector<int> order;   // permutation of [0..n): indices in sorted order
    int passes = 0;           // number of merge sweeps (ceil(log2 n))
    SortPath path = SortPath::Hardware;
};

// Stable bottom-up merge sort of indices by ascending packed key.
// (Stability is irrelevant for bit-exactness here — the inputs have a strict
// total order — but a real merge unit is naturally stable, so we model it so.)
inline FoldedResult folded_merge_sort(const std::vector<u128>& keys) {
    const int n = (int)keys.size();
    FoldedResult res;
    res.order.resize(n);
    for (int i = 0; i < n; ++i) res.order[i] = i;

    if (n <= 1) { res.passes = 0; res.path = SortPath::FastPathN1; return res; }
    res.path = (n <= N_MAX) ? SortPath::Hardware : SortPath::SoftwareFallback;

    std::vector<int> buf(n);
    int* cur = res.order.data();
    int* nxt = buf.data();
    int passes = 0;

    for (int width = 1; width < n; width <<= 1) {
        for (int lo = 0; lo < n; lo += 2 * width) {
            int mid = lo + width < n ? lo + width : n;
            int hi  = lo + 2 * width < n ? lo + 2 * width : n;
            int i = lo, j = mid, k = lo;
            // merge runs [lo,mid) and [mid,hi); left run wins on equal keys
            while (i < mid && j < hi)
                nxt[k++] = (keys[cur[j]] < keys[cur[i]]) ? cur[j++] : cur[i++];
            while (i < mid) nxt[k++] = cur[i++];
            while (j < hi)  nxt[k++] = cur[j++];
        }
        std::swap(cur, nxt);
        ++passes;
    }
    // if cur ended up pointing at buf, copy back into res.order
    if (cur != res.order.data())
        for (int i = 0; i < n; ++i) res.order[i] = cur[i];
    res.passes = passes;
    return res;
}
