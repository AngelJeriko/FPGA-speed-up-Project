// gen_chain_flt_vectors.cpp — golden vectors for tb_chain_flt (RTL mem_chain_flt filter stage).
// Expected = host/chaining/chain.h::c_chain_flt_post on WEIGHTED + SORTED chains. We synthesise
// chains with independent (w, cbeg, cend, is_alt): w set directly (so weight is decoupled from
// span), a single seed carrying the query span (qbeg=cbeg, len=cend-cbeg), random is_alt. We
// sort by w DESC with the real ks_introsort (any combsort is harmless here — the filter is fed
// the post-sort array), then run c_chain_flt_post and emit per-chain kept. Heavy overlap/weight
// clustering exercises the shadow-drop, resurrect (kept=1), and max_chain_extend paths.
//
// Format:
//   <count>
//   per case:  n gap msl mce  ;  n * { w cbeg cend isalt }  ;  n * { kept }
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <vector>
#include <string>
#include "chain.h"

static uint64_t st = 0xfeedface12345678ull;
static inline uint32_t rnd() { st = st*6364136223846793005ull + 1442695040888963407ull; return (uint32_t)(st>>33); }

int main(int argc, char** argv) {
    if (argc < 2) { fprintf(stderr, "usage: %s out.txt [n]\n", argv[0]); return 1; }
    int n = argc > 2 ? atoi(argv[2]) : 4000;

    std::string buf; buf.reserve(8<<20);
    char line[96];
    long ext_cases = 0;
    for (int it = 0; it < n; ++it) {
        int ns = 1 + rnd() % 40;
        COpt o;                                   // gap=10000, msl=19, mce=1<<30
        // ~1 in 6 cases uses a small max_chain_extend to exercise the cap path
        if ((rnd() % 6) == 0) { o.max_chain_extend = 1 + rnd() % 5; ext_cases++; }

        std::vector<CChain> b(ns);
        for (int k = 0; k < ns; ++k) {
            int wv   = 10 + rnd() % 200;           // weight (dups -> ties)
            int cbeg = rnd() % 100;                // clustered query starts -> overlaps
            int span = 20 + rnd() % 120;
            b[k].w = wv; b[k].is_alt = ((rnd() % 10) < 3);   // ~30% alt
            CSeed s; s.rbeg = k; s.qbeg = cbeg; s.len = span; s.score = wv;
            b[k].seeds.push_back(s);
        }
        ks_introsort_memflt((size_t)ns, b.data());     // sort by w DESC (unstable tie order)
        c_chain_flt_post(o, b);                        // annotates b[i].kept

        snprintf(line,sizeof line,"%d %d %d %d\n", ns, o.max_chain_gap, o.min_seed_len, o.max_chain_extend); buf+=line;
        for (int k=0;k<ns;++k){
            int cbeg = b[k].seeds[0].qbeg;
            int cend = b[k].seeds.back().qbeg + b[k].seeds.back().len;
            snprintf(line,sizeof line,"%d %d %d %d\n", b[k].w, cbeg, cend, b[k].is_alt?1:0); buf+=line;
        }
        for (int k=0;k<ns;++k){ snprintf(line,sizeof line,"%d\n", b[k].kept); buf+=line; }
    }
    FILE* out = fopen(argv[1], "w");
    fprintf(out, "%d\n", n);
    fwrite(buf.data(), 1, buf.size(), out);
    fclose(out);
    fprintf(stderr, "wrote %d chain-flt vectors (%ld small-mce) to %s\n", n, ext_cases, argv[1]);
    return 0;
}
