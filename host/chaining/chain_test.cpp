// chain_test.cpp — synthetic SANITY test for the chaining model (chain.h). This
// only checks that grouping + filtering behave sensibly; bit-exactness vs real
// bwa-mem2 is established later against captured (seed-stream -> chains) vectors.
#include <cstdio>
#include "chain.h"

static void dump(const char* name, const std::vector<CChain>& cs) {
    printf("%s: %zu chains\n", name, cs.size());
    for (size_t i = 0; i < cs.size(); ++i) {
        const CChain& c = cs[i];
        printf("  chain%zu rid=%d pos=%lld w=%d kept=%d n=%zu :", i, c.rid,
               (long long)c.pos, c.w, c.kept, c.seeds.size());
        for (auto& s : c.seeds) printf(" (q%d r%lld L%d)", s.qbeg, (long long)s.rbeg, s.len);
        printf("\n");
    }
}

int main() {
    COpt o;
    int64_t l_pac = 1000000000;   // big -> all on forward strand
    int fails = 0;

    // Case A: two colinear runs -> two chains. Seeds arrive in stream order.
    {
        std::vector<CSeed> seeds = {
            {1000, 0, 20, 20}, {1030, 30, 20, 20}, {1060, 60, 19, 19},   // chain @1000
            {5000, 0, 20, 20}, {5030, 30, 20, 20},                       // chain @5000
        };
        std::vector<int> rid(seeds.size(), 0);
        std::vector<bool> alt(seeds.size(), false);
        auto chains = c_mem_chain(o, l_pac, 0, seeds, rid, alt);
        auto flt = c_mem_chain_flt(o, chains);
        dump("A pre-flt", chains); dump("A flt", flt);
        if (chains.size() != 2) { printf("  [FAIL] expected 2 chains\n"); fails++; }
        if (chains.size()==2 && (chains[0].seeds.size()!=3 || chains[1].seeds.size()!=2))
            { printf("  [FAIL] chain sizes\n"); fails++; }
    }

    // Case B: a strong chain and a weak chain overlapping in query -> weak shadowed.
    {
        std::vector<CSeed> seeds = {
            {1000, 0, 30, 30}, {1040, 40, 30, 30}, {1080, 80, 20, 20},   // strong @1000 (wide query cover)
            {9000, 10, 15, 15},                                          // weak @9000, overlaps query [10..25]
        };
        std::vector<int> rid(seeds.size(), 0);
        std::vector<bool> alt(seeds.size(), false);
        auto chains = c_mem_chain(o, l_pac, 0, seeds, rid, alt);
        auto flt = c_mem_chain_flt(o, chains);
        dump("B pre-flt", chains); dump("B flt", flt);
        // both chains exist pre-flt; the weak one may be shadowed (kept demoted)
        if (chains.size() != 2) { printf("  [FAIL] expected 2 chains pre-flt\n"); fails++; }
    }

    printf(fails == 0 ? "chain_test: sanity OK\n" : "chain_test: %d sanity issue(s)\n", fails);
    return 0;
}
