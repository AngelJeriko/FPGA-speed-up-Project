// gen_chain_introsort_vectors.cpp — golden vectors for tb_chain_introsort (RTL
// ks_introsort(mem_flt)). Expected = host/chaining/chain.h::ks_introsort_memflt, sorting
// (w,id) pairs by w DESC with the exact UNSTABLE tie order. id = original index, the payload
// tag that pins down where equal-w elements land. Heavy on duplicate weights (and structured
// patterns: ascending/descending/organ-pipe/sawtooth/all-equal) to stress tie order and try
// to trip the depth limit. `fb` flags a case where combsort would run (RTL falls back) — ~0.
//
// Format:
//   <count>
//   per case:  n  ;  n * { w id }  (input)  ;  fb  ;  n * { w id }  (sorted output)
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <vector>
#include <string>
#include "chain.h"

static uint64_t st = 0x1234abcd5678ef90ull;
static inline uint32_t rnd() { st = st*6364136223846793005ull + 1442695040888963407ull; return (uint32_t)(st>>33); }

int main(int argc, char** argv) {
    if (argc < 2) { fprintf(stderr, "usage: %s out.txt [n]\n", argv[0]); return 1; }
    int n = argc > 2 ? atoi(argv[2]) : 4000;

    std::string buf; buf.reserve(8<<20);
    char line[64];
    long fbcount = 0;
    for (int it = 0; it < n; ++it) {
        int ns = 1 + rnd() % 60;
        int pat = rnd() % 7;                       // input pattern
        int range = (pat == 6) ? 1 : (3 + rnd() % 8);   // small range -> many ties
        std::vector<CChain> b(ns);
        std::vector<int> in_w(ns), in_id(ns);
        for (int k = 0; k < ns; ++k) {
            int wv;
            switch (pat) {
                case 0: wv = rnd() % range; break;                  // random, many dups
                case 1: wv = k; break;                              // ascending
                case 2: wv = ns - 1 - k; break;                     // descending
                case 3: wv = (k < ns/2) ? k : (ns-1-k); break;      // organ pipe
                case 4: wv = (k & 1) ? 1000 : (int)(rnd()%range); break; // sawtooth
                case 5: wv = rnd() % (ns + 1); break;               // wide-ish
                default: wv = 7; break;                             // all equal
            }
            b[k].w = wv; b[k].seqid = k;            // seqid = id tag (read back after sort)
            in_w[k] = wv; in_id[k] = k;             // capture input BEFORE the in-place sort
        }
        bool comb = false;
        ks_introsort_memflt((size_t)ns, b.data(), &comb);
        if (comb) fbcount++;

        snprintf(line,sizeof line,"%d\n", ns); buf+=line;
        for (int k=0;k<ns;++k){ snprintf(line,sizeof line,"%d %d\n", in_w[k], in_id[k]); buf+=line; }
        snprintf(line,sizeof line,"%d\n", comb?1:0); buf+=line;
        for (int k=0;k<ns;++k){ snprintf(line,sizeof line,"%d %d\n", b[k].w, b[k].seqid); buf+=line; }
    }
    FILE* out = fopen(argv[1], "w");
    fprintf(out, "%d\n", n);
    fwrite(buf.data(), 1, buf.size(), out);
    fclose(out);
    fprintf(stderr, "wrote %d chain-introsort vectors (%ld combsort/fallback) to %s\n", n, fbcount, argv[1]);
    return 0;
}
