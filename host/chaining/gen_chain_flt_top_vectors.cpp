// gen_chain_flt_top_vectors.cpp — END-TO-END golden vectors for tb_chain_flt_top (RTL full
// mem_chain_flt = weight+sort+filter). Expected = host/chaining/chain.h::c_mem_chain_flt:
// chains-with-seeds -> surviving chains in weight-sorted order. Each input chain is tagged with
// seqid = its input index; the output chains retain it, so we emit the surviving indices. `fb`
// flags combsort (the only fallback source); the RTL top raises fallback and the TB skips the
// output check there (host SW redo). Varied seeds -> varied weights/ties; clustered qbeg ->
// overlapping query spans to exercise the filter.
//
// Format:
//   <count>
//   per case:  n gap msl mce total_seeds
//              per chain: off ns isalt
//              total_seeds * { rbeg qbeg len }
//              fb n_out
//              n_out * { id }
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <vector>
#include <string>
#include "chain.h"

static uint64_t st = 0x0badf00dcafebabeull;
static inline uint32_t rnd() { st = st*6364136223846793005ull + 1442695040888963407ull; return (uint32_t)(st>>33); }

int main(int argc, char** argv) {
    if (argc < 2) { fprintf(stderr, "usage: %s out.txt [n]\n", argv[0]); return 1; }
    int n = argc > 2 ? atoi(argv[2]) : 4000;

    std::string buf; buf.reserve(8<<20);
    char line[96];
    long fbcount = 0;
    for (int it = 0; it < n; ++it) {
        // ~1 in 8 cases is DEGENERATE: many single-seed chains whose weights are ALREADY in
        // target (descending) order -> worst-case median-of-3 pivots -> the introsort hits its
        // depth limit -> combsort -> the top must raise `fallback` (exercises the fallback-
        // propagation path end-to-end).
        bool degen = (rnd() % 8) == 0;
        int nc = degen ? (30 + rnd() % 20) : (1 + rnd() % 24);  // degen needs n>=30 to trip combsort
        COpt o;                                   // gap=10000, msl=19, mce=1<<30
        if (!degen && (rnd() % 6) == 0) o.max_chain_extend = 1 + rnd() % 5;   // exercise the cap path

        std::vector<CChain> chains(nc);
        std::vector<int>     off(nc), nsv(nc);
        std::vector<int64_t> p_rbeg; std::vector<int> p_qbeg, p_len;
        for (int c = 0; c < nc; ++c) {
            int ns = degen ? 1 : (1 + rnd() % 4);
            off[c] = (int)p_qbeg.size(); nsv[c] = ns;
            chains[c].seqid = c; chains[c].is_alt = ((rnd()%10) < 3);
            for (int k = 0; k < ns; ++k) {
                int64_t rb = rnd() % 4000;
                int     qb = rnd() % 100;          // clustered -> overlapping spans
                int     ln = degen ? (100 - c) : (19 + rnd() % 80);  // degen: descending weight (worst pivots)
                CSeed s; s.rbeg = rb; s.qbeg = qb; s.len = ln; s.score = ln;
                chains[c].seeds.push_back(s);
                p_rbeg.push_back(rb); p_qbeg.push_back(qb); p_len.push_back(ln);
            }
        }
        bool comb = false;
        std::vector<CChain> outc = c_mem_chain_flt(o, chains, &comb);
        if (comb) fbcount++;

        int tot = (int)p_qbeg.size();
        snprintf(line,sizeof line,"%d %d %d %d %d\n", nc, o.max_chain_gap, o.min_seed_len, o.max_chain_extend, tot); buf+=line;
        for (int c=0;c<nc;++c){ snprintf(line,sizeof line,"%d %d %d\n", off[c], nsv[c], chains[c].is_alt?1:0); buf+=line; }
        for (int k=0;k<tot;++k){ snprintf(line,sizeof line,"%lld %d %d\n",(long long)p_rbeg[k],p_qbeg[k],p_len[k]); buf+=line; }
        snprintf(line,sizeof line,"%d %d\n", comb?1:0, (int)outc.size()); buf+=line;
        for (auto& c : outc) { snprintf(line,sizeof line,"%d\n", c.seqid); buf+=line; }
    }
    FILE* out = fopen(argv[1], "w");
    fprintf(out, "%d\n", n);
    fwrite(buf.data(), 1, buf.size(), out);
    fclose(out);
    fprintf(stderr, "wrote %d chain-flt-top vectors (%ld combsort/fallback) to %s\n", n, fbcount, argv[1]);
    return 0;
}
