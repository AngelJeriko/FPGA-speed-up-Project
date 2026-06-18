// gen_purge_vectors.cpp — per-read golden for tb_orch_purge.
//
// Emits the inputs to the HW purge (pre-purge av, the per-chain table, all seeds
// grouped by chain in natural index order) and the expected post-purge qb/qe.
// Build with -DHWMODEL -DINTPURGE so the pre-purge av matches the full-rectangle
// array and the expected purge matches the integer-only logic the RTL implements.
//
// Identities used: one alnreg per seed, av appended per chain in score-desc order,
// so abase[cj] == sbase[cj] == cumulative seed count; the RTL recomputes srt2.
//
// Subset reads (purge is O(nav^2) worst case): keep 1/SAMPLE of reads (covers all
// sizes since it's index-strided).
//
// Output:
//   <nreads>
//   per read:
//     nav nchain a o_del e_del o_ins e_ins w l_query
//     nav   * { rb re qb qe w seedlen0 }        (pre-purge av)
//     nchain* { sbase n abase }
//     nav   * { rbeg qbeg len score }           (seeds, grouped by chain)
//     nav   * { qb qe }                         (expected post-purge)
#include <cstdio>
#include <cstdlib>
#include <vector>
#include <string>
#include "parse.h"

static const int SAMPLE = 150;

int main(int argc, char** argv) {
    if (argc < 3) { fprintf(stderr, "usage: %s vectors.bin out.txt\n", argv[0]); return 1; }
    auto reads = load_reads(argv[1]);
    FILE* out = fopen(argv[2], "w");
    if (!out) { fprintf(stderr, "cannot open %s\n", argv[2]); return 1; }

    std::string buf; buf.reserve(64<<20);
    char line[256];
    long nreads = 0, ctr = 0;

    for (auto& rv : reads) {
        if (ctr++ % SAMPLE != 0) continue;
        const Cfg& o = rv.cfg;
        std::vector<std::vector<int>> seed_aln;
        std::vector<Alnreg> av = extend_only(rv, seed_aln);   // HWMODEL pre-purge
        std::vector<Alnreg> avp = av;                          // copy to purge
        purge(rv, avp, seed_aln);                              // INTPURGE
        const int nav = (int)av.size();
        const int nch = (int)rv.chains.size();

        snprintf(line,sizeof line,"%d %d %d %d %d %d %d %d %d\n",
            nav, nch, o.a, o.o_del, o.e_del, o.o_ins, o.e_ins, o.w, rv.l_query);
        buf += line;
        for (int i=0;i<nav;++i){
            snprintf(line,sizeof line,"%lld %lld %d %d %d %d\n",
                (long long)av[i].rb,(long long)av[i].re,av[i].qb,av[i].qe,av[i].w,av[i].seedlen0);
            buf += line;
        }
        int base = 0;
        for (int cj=0;cj<nch;++cj){
            int n=(int)rv.chains[cj].seeds.size();
            snprintf(line,sizeof line,"%d %d %d\n", base, n, base);  // sbase n abase
            buf += line; base += n;
        }
        for (int cj=0;cj<nch;++cj)
            for (auto& s : rv.chains[cj].seeds){
                snprintf(line,sizeof line,"%lld %d %d %d\n",(long long)s.rbeg,s.qbeg,s.len,s.score);
                buf += line;
            }
        for (int i=0;i<nav;++i){
            snprintf(line,sizeof line,"%d %d\n", avp[i].qb, avp[i].qe);
            buf += line;
        }
        nreads++;
    }
    fprintf(out,"%ld\n",nreads);
    fwrite(buf.data(),1,buf.size(),out);
    fclose(out);
    fprintf(stderr,"wrote %ld read purge-vectors to %s\n", nreads, argv[2]);
    return 0;
}
