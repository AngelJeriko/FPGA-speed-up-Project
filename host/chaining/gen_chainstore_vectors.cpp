// gen_chainstore_vectors.cpp — golden vectors for tb_chain_store (the RTL mem_chain).
// Expected = host/chaining/chain.h::c_mem_chain (the validated sorted-array model). Builds
// small clustered seed streams (near/equal rbeg to force dup-pos, colinear runs to force
// appends, containment, both strands) and emits the pre-flt chains + the dup-pos `fb`.
// The RTL is the SAME sorted-array algorithm, so it must match c_mem_chain on ALL cases
// (including fb cases) AND reproduce fb exactly.
//
// Format:
//   <count>
//   per case:
//     w max_chain_gap l_pac n_seeds
//     n_seeds * { rbeg qbeg len score rid is_alt }
//     fb n_chains
//     per chain: pos rid is_alt n_cseeds  ;  n_cseeds * { rbeg qbeg len score }
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <vector>
#include <string>
#include "chain.h"

static uint64_t st = 0xc4a1bde5f0091723ull;
static inline uint32_t rnd() { st = st*6364136223846793005ull + 1442695040888963407ull; return (uint32_t)(st>>33); }

int main(int argc, char** argv) {
    if (argc < 2) { fprintf(stderr, "usage: %s out.txt [n]\n", argv[0]); return 1; }
    int n = argc > 2 ? atoi(argv[2]) : 4000;
    COpt o;                                   // w=100, gap=10000, msl=19, a=1
    const int64_t l_pac = 4000;               // span rbeg both sides to exercise the strand block

    std::string buf; buf.reserve(16<<20);
    char line[160];
    long fbcount = 0;
    for (int it = 0; it < n; ++it) {
        int ns = 1 + rnd() % 30;
        std::vector<CSeed> seeds; std::vector<int> rid; std::vector<bool> alt;
        for (int k = 0; k < ns; ++k) {
            // cluster rbeg around a few bases (some exactly equal -> dup-pos / containment)
            int64_t base = (int64_t)(rnd() % 4) * 1500;
            int64_t rb   = base + (int64_t)(rnd() % 60);     // tight cluster -> equal/near pos
            int32_t qb   = (int32_t)(rnd() % 200);
            int32_t ln   = 19 + (int32_t)(rnd() % 60);
            int32_t sc   = ln;
            int r        = (int)(rnd() % 2);                 // 2 ref ids
            CSeed s; s.rbeg = rb; s.qbeg = qb; s.len = ln; s.score = sc;
            seeds.push_back(s); rid.push_back(r); alt.push_back((rnd()&1)!=0);
        }
        bool fb = false;
        std::vector<CChain> ch = c_mem_chain(o, l_pac, it, seeds, rid, alt, &fb);
        if (fb) fbcount++;

        snprintf(line,sizeof line,"%d %d %lld %d\n", o.w, o.max_chain_gap, (long long)l_pac, ns); buf+=line;
        for (int k=0;k<ns;++k){ snprintf(line,sizeof line,"%lld %d %d %d %d %d\n",
            (long long)seeds[k].rbeg,seeds[k].qbeg,seeds[k].len,seeds[k].score,rid[k],alt[k]?1:0); buf+=line; }
        snprintf(line,sizeof line,"%d %d\n", fb?1:0, (int)ch.size()); buf+=line;
        for (auto& c : ch) {
            snprintf(line,sizeof line,"%lld %d %d %d\n",
                     (long long)c.pos, c.rid, c.is_alt?1:0, (int)c.seeds.size()); buf+=line;
            for (auto& s : c.seeds) { snprintf(line,sizeof line,"%lld %d %d %d\n",
                (long long)s.rbeg,s.qbeg,s.len,s.score); buf+=line; }
        }
    }
    FILE* out = fopen(argv[1], "w");
    fprintf(out, "%d\n", n);
    fwrite(buf.data(), 1, buf.size(), out);
    fclose(out);
    fprintf(stderr, "wrote %d chain-store vectors (%ld dup-pos fb) to %s\n", n, fbcount, argv[1]);
    return 0;
}
