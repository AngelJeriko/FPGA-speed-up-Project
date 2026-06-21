// gen_chain2aln_vectors.cpp — golden vectors for tb_chain2aln_setup (RTL rmax computation).
// Expected = chain2aln.h::c_compute_rmax. Synthetic chains with a SMALL l_pac and rbeg spanning
// [0, 2*l_pac) so the l_pac upper-clamp, the rmax0>=0 clamp, and the fwd/rev boundary fix all
// fire (the real capture never hit them — interior reads — so we cover them here). Config varied
// to exercise cal_max_gap (the two signed divisions).
//
// Format:
//   <count>
//   per case:  a o_del e_del o_ins e_ins w l_query l_pac n_seeds
//              n_seeds * { rbeg qbeg len }
//              rmax0 rmax1
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <vector>
#include <string>
#include "chain2aln.h"

static uint64_t st = 0xa5a5c3c30f0f1234ull;
static inline uint32_t rnd() { st = st*6364136223846793005ull + 1442695040888963407ull; return (uint32_t)(st>>33); }

int main(int argc, char** argv) {
    if (argc < 2) { fprintf(stderr, "usage: %s out.txt [n]\n", argv[0]); return 1; }
    int n = argc > 2 ? atoi(argv[2]) : 4000;

    std::string buf; buf.reserve(8<<20);
    char line[160];
    for (int it = 0; it < n; ++it) {
        Cfg o{};
        o.a = 1 + (int)(rnd()%2);            // 1..2
        o.o_del = 4 + (int)(rnd()%6);  o.e_del = 1 + (int)(rnd()%3);
        o.o_ins = 4 + (int)(rnd()%6);  o.e_ins = 1 + (int)(rnd()%3);
        o.w = 50 + (int)(rnd()%120);
        int l_query = 80 + (int)(rnd()%120);
        int64_t l_pac = (rnd()%4==0) ? (int64_t)(2000 + rnd()%4000)   // small -> exercise clamps
                                     : (int64_t)((uint64_t)1<<40);    // huge -> interior (like real)
        int ns = 1 + rnd()%6;
        std::vector<Seed> seeds(ns);
        for (int k=0;k<ns;++k){
            int64_t rb = (l_pac < (1LL<<30)) ? (int64_t)(rnd() % (uint64_t)(l_pac*2))   // span both strands
                                             : (int64_t)(rnd() % 1000000000ull);
            int qb = (int)(rnd() % (l_query>1?l_query-1:1));
            int maxln = l_query - qb; if (maxln < 1) maxln = 1;
            int ln = 1 + (int)(rnd() % maxln);            // qbeg+len <= l_query -> tail>=0
            seeds[k].rbeg=rb; seeds[k].qbeg=qb; seeds[k].len=ln; seeds[k].score=ln;
        }
        int64_t r0, r1;
        c_compute_rmax(seeds, l_query, l_pac, o, r0, r1);

        snprintf(line,sizeof line,"%d %d %d %d %d %d %d %lld %d\n",
                 o.a,o.o_del,o.e_del,o.o_ins,o.e_ins,o.w,l_query,(long long)l_pac,ns); buf+=line;
        for (int k=0;k<ns;++k){ snprintf(line,sizeof line,"%lld %d %d\n",
            (long long)seeds[k].rbeg,seeds[k].qbeg,seeds[k].len); buf+=line; }
        snprintf(line,sizeof line,"%lld %lld\n",(long long)r0,(long long)r1); buf+=line;
    }
    FILE* out = fopen(argv[1], "w");
    fprintf(out, "%d\n", n);
    fwrite(buf.data(), 1, buf.size(), out);
    fclose(out);
    fprintf(stderr, "wrote %d chain2aln-setup vectors to %s\n", n, argv[1]);
    return 0;
}
