// gen_chain_weight_vectors.cpp — golden vectors for tb_chain_weight (RTL mem_chain_weight).
// Expected = host/chaining/chain.h::c_chain_weight. Builds random small seed streams with
// clustered qbeg/rbeg so the three coverage branches (disjoint / partial overlap / fully
// contained) all fire on both the query and reference passes, plus a few wide-coordinate
// cases near the (1<<30) cap. Order is the stream order (weight's `end` accumulator is
// order-sensitive) — the RTL walks the same order, so it must match bit-exact.
//
// Format:
//   <count>
//   per case:  n_seeds  ;  n_seeds * { qbeg rbeg len }  ;  w
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <vector>
#include <string>
#include "chain.h"

static uint64_t st = 0x9e3779b97f4a7c15ull;
static inline uint32_t rnd() { st = st*6364136223846793005ull + 1442695040888963407ull; return (uint32_t)(st>>33); }

int main(int argc, char** argv) {
    if (argc < 2) { fprintf(stderr, "usage: %s out.txt [n]\n", argv[0]); return 1; }
    int n = argc > 2 ? atoi(argv[2]) : 4000;

    std::string buf; buf.reserve(8<<20);
    char line[96];
    for (int it = 0; it < n; ++it) {
        int ns = 1 + rnd() % 24;
        std::vector<CSeed> seeds;
        // ~1 in 16 cases uses wide coords to probe the cap path
        bool wide = (rnd() % 16) == 0;
        for (int k = 0; k < ns; ++k) {
            CSeed s;
            if (wide) {
                s.qbeg = (int)(rnd() % 100000);
                s.rbeg = (int64_t)(rnd() % 100000000);
                s.len  = (int)(20000000 + rnd() % 60000000);   // huge -> push toward 1<<30
            } else {
                s.qbeg = (int)(rnd() % 150);                    // tight -> query overlaps
                s.rbeg = (int64_t)(rnd() % 250);                // tight -> ref overlaps
                s.len  = (int)(19 + rnd() % 70);
            }
            s.score = s.len;
            seeds.push_back(s);
        }
        CChain c; c.seeds = seeds;
        int w = c_chain_weight(c);

        snprintf(line,sizeof line,"%d\n", ns); buf+=line;
        for (auto& s : seeds) { snprintf(line,sizeof line,"%d %lld %d\n",
            s.qbeg, (long long)s.rbeg, s.len); buf+=line; }
        snprintf(line,sizeof line,"%d\n", w); buf+=line;
    }
    FILE* out = fopen(argv[1], "w");
    fprintf(out, "%d\n", n);
    fwrite(buf.data(), 1, buf.size(), out);
    fclose(out);
    fprintf(stderr, "wrote %d chain-weight vectors to %s\n", n, argv[1]);
    return 0;
}
