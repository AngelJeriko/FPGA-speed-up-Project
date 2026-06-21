// gen_chaining_top_vectors.cpp — END-TO-END golden vectors for tb_chaining_top (RTL full
// chaining stage = chain_store -> chain_flt_top). Expected = chain.h::c_mem_chain_flt(
// c_mem_chain(raw seeds)). Reuses the clustered seed streams of gen_chainstore (near/equal rbeg
// -> dup-pos, colinear runs, both strands), plus some descending-weight-prone shapes; emits the
// surviving chains' pos-sorted indices. `fb` = chain_store dup-pos OR introsort combsort -> the
// RTL top raises fallback and the TB skips the output check (host SW redo).
//
// Format:
//   <count>
//   per case:  w gap l_pac msl mce n_seeds
//              n_seeds * { rbeg qbeg len score rid is_alt }
//              fb n_out
//              n_out * { id }
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <vector>
#include <string>
#include "chain.h"

static uint64_t st = 0x51ce0fadebabe001ull;
static inline uint32_t rnd() { st = st*6364136223846793005ull + 1442695040888963407ull; return (uint32_t)(st>>33); }

int main(int argc, char** argv) {
    if (argc < 2) { fprintf(stderr, "usage: %s out.txt [n]\n", argv[0]); return 1; }
    int n = argc > 2 ? atoi(argv[2]) : 4000;
    const int64_t l_pac = 4000;

    std::string buf; buf.reserve(16<<20);
    char line[160];
    long fbcount = 0;
    for (int it = 0; it < n; ++it) {
        int ns = 1 + rnd() % 30;
        COpt o;                                   // w=100, gap=10000, msl=19, mce=1<<30
        if ((rnd() % 6) == 0) o.max_chain_extend = 1 + rnd() % 5;

        std::vector<CSeed> seeds; std::vector<int> rid; std::vector<bool> alt;
        for (int k = 0; k < ns; ++k) {
            int64_t base = (int64_t)(rnd() % 4) * 1500;
            int64_t rb   = base + (int64_t)(rnd() % 60);     // tight cluster -> equal/near pos
            int32_t qb   = (int32_t)(rnd() % 200);
            int32_t ln   = 19 + (int32_t)(rnd() % 60);
            CSeed s; s.rbeg = rb; s.qbeg = qb; s.len = ln; s.score = ln;
            seeds.push_back(s); rid.push_back((int)(rnd() % 2)); alt.push_back((rnd()&1)!=0);
        }

        bool fb_chain = false, fb_comb = false;
        std::vector<CChain> chains = c_mem_chain(o, l_pac, 0, seeds, rid, alt, &fb_chain);
        for (size_t i = 0; i < chains.size(); ++i) chains[i].seqid = (int)i;   // tag pos-sorted index
        std::vector<CChain> outc = c_mem_chain_flt(o, chains, &fb_comb);
        bool fb = fb_chain || fb_comb;
        if (fb) fbcount++;

        snprintf(line,sizeof line,"%d %d %lld %d %d %d\n",
                 o.w, o.max_chain_gap, (long long)l_pac, o.min_seed_len, o.max_chain_extend, ns); buf+=line;
        for (int k=0;k<ns;++k){ snprintf(line,sizeof line,"%lld %d %d %d %d %d\n",
            (long long)seeds[k].rbeg,seeds[k].qbeg,seeds[k].len,seeds[k].score,rid[k],alt[k]?1:0); buf+=line; }
        snprintf(line,sizeof line,"%d %d\n", fb?1:0, (int)outc.size()); buf+=line;
        for (auto& c : outc) { snprintf(line,sizeof line,"%d\n", c.seqid); buf+=line; }
    }
    FILE* out = fopen(argv[1], "w");
    fprintf(out, "%d\n", n);
    fwrite(buf.data(), 1, buf.size(), out);
    fclose(out);
    fprintf(stderr, "wrote %d chaining-top vectors (%ld fallback) to %s\n", n, fbcount, argv[1]);
    return 0;
}
