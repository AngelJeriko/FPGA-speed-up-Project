// test_sorter.cpp — self-checking testbench for the folded merge-sorter model.
//
// Reads the binary vector file dumped from a real bwa-mem2 run (the INPUT key
// arrays entering the post-dedup alnreg_slt score sort, plus the EXPECTED order
// = the actual ks_introsort output = ground truth). For every record it:
//   1. packs INPUT keys into 96-bit composite keys,
//   2. runs the folded merge-sorter model,
//   3. gathers INPUT by the model's index permutation,
//   4. asserts the result == EXPECTED, field-by-field (bit-exact),
//   5. cross-checks the packed-key compare vs. the alnreg_slt comparator.
// Prints aggregate stats: pass/fail, size & pass-count distribution, hardware
// vs. software-fallback split, and key-field width headroom.
//
// Binary format (little-endian), repeated:
//   int32 n; n*{int32 score, int64 rb, int32 qb} INPUT;
//            n*{int32 score, int64 rb, int32 qb} EXPECTED
#include <cstdio>
#include <cstdint>
#include <cstring>
#include <vector>
#include <string>
#include <algorithm>
#include "key.h"
#include "folded_sorter.h"

struct Rec { std::vector<AlnKey> in, exp; };

static bool read_keys(FILE* f, int n, std::vector<AlnKey>& out) {
    out.resize(n);
    for (int i = 0; i < n; ++i) {
        int32_t s, q; int64_t r;
        if (fread(&s, 4, 1, f) != 1) return false;
        if (fread(&r, 8, 1, f) != 1) return false;
        if (fread(&q, 4, 1, f) != 1) return false;
        out[i] = {s, r, q};
    }
    return true;
}

int main(int argc, char** argv) {
    const char* path = argc > 1 ? argv[1] : "vectors/alnreg_vectors.bin";
    FILE* f = fopen(path, "rb");
    if (!f) { fprintf(stderr, "cannot open %s\n", path); return 2; }

    long records = 0, passed = 0, failed = 0;
    long hw = 0, n1 = 0, fallback = 0;
    int  max_n = 0, max_passes = 0;
    int64_t max_rb = 0; int32_t max_qb = 0, min_score = INT32_MAX, max_score = 0;
    long pack_mismatch = 0;
    int  first_fail_n = -1;

    int32_t n;
    while (fread(&n, 4, 1, f) == 1) {
        Rec rc;
        if (!read_keys(f, n, rc.in) || !read_keys(f, n, rc.exp)) {
            fprintf(stderr, "truncated record at #%ld\n", records); break;
        }
        ++records;
        if (n > max_n) max_n = n;

        // field-width headroom + packing-vs-comparator cross-check
        for (int i = 0; i < n; ++i) {
            max_rb = std::max(max_rb, rc.in[i].rb);
            max_qb = std::max(max_qb, rc.in[i].qb);
            min_score = std::min(min_score, rc.in[i].score);
            max_score = std::max(max_score, rc.in[i].score);
        }
        for (int i = 0; i + 1 < n; ++i) {
            const AlnKey &a = rc.in[i], &b = rc.in[i + 1];
            bool by_cmp  = alnreg_slt(a, b);
            bool by_pack = pack_key(a) < pack_key(b);
            bool eq_cmp  = !alnreg_slt(a, b) && !alnreg_slt(b, a);
            if (!eq_cmp && by_cmp != by_pack) ++pack_mismatch;
        }

        // build packed keys, run the model
        std::vector<u128> keys(n);
        for (int i = 0; i < n; ++i) keys[i] = pack_key(rc.in[i]);
        FoldedResult r = folded_merge_sort(keys);
        max_passes = std::max(max_passes, r.passes);
        if (r.path == SortPath::FastPathN1) ++n1;
        else if (r.path == SortPath::SoftwareFallback) ++fallback;
        else ++hw;

        // gather and compare to EXPECTED, bit-exact
        bool ok = true;
        for (int i = 0; i < n; ++i) {
            const AlnKey& g = rc.in[r.order[i]];
            const AlnKey& e = rc.exp[i];
            if (g.score != e.score || g.rb != e.rb || g.qb != e.qb) { ok = false; break; }
        }
        if (ok) ++passed;
        else { ++failed; if (first_fail_n < 0) first_fail_n = n; }
    }
    fclose(f);

    printf("=== folded merge-sorter testbench ===\n");
    printf("vectors file       : %s\n", path);
    printf("records            : %ld\n", records);
    printf("PASSED (bit-exact) : %ld\n", passed);
    printf("FAILED             : %ld%s", failed, failed ? "  <-- " : "\n");
    if (failed) printf("first failing n=%d\n", first_fail_n);
    printf("packing!=cmp       : %ld (must be 0)\n", pack_mismatch);
    printf("path split         : n1_fastpath=%ld  hardware=%ld  software_fallback(n>%d)=%ld\n",
           n1, hw, N_MAX, fallback);
    printf("max n              : %d\n", max_n);
    printf("max merge passes   : %d (ceil(log2 n))\n", max_passes);
    printf("score range        : [%d, %d]\n", min_score, max_score);
    printf("max rb             : %lld  (RB_BITS=%d cap=%lld)\n",
           (long long)max_rb, RB_BITS, (long long)RB_MAX);
    printf("max qb             : %d  (QB_BITS=%d cap=%d)\n", max_qb, QB_BITS, QB_MAX);
    bool good = (failed == 0 && pack_mismatch == 0 && records > 0);
    printf("RESULT             : %s\n", good ? "ALL PASS" : "FAIL");
    return good ? 0 : 1;
}
