// gen_read_vectors.cpp — per-read golden for tb_orch_read_top.
//
// Emits a read's full inputs (cfg, query, and each chain's rid/rmax/seeds/ref)
// and the expected POST-PURGE alnreg array = orchestrate() in orch.h. Build with
// -DHWMODEL -DINTPURGE so the expected output matches the full-rectangle array +
// integer purge that the RTL implements (== real bwa-mem2, proven 30000/30000).
//
// av index i in orchestrate() == the i-th alnreg collected by orch_read_top
// (chains in order, score-desc within a chain), so expected[i] maps 1:1.
//
// Subset: 1/SAMPLE of reads (purge is O(nav^2)).
//
// Output:
//   <nreads>
//   per read:
//     l_query a o_del e_del o_ins e_ins zdrop w pen5 pen3 nchain nav
//     query[0..l_query-1]
//     per chain: rid rmax0 rmax1 n_seeds reflen
//                n_seeds*{rbeg qbeg len score}
//                ref[0..reflen-1]
//     nav*{rb re qb qe score truesc w seedcov seedlen0 rid}
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
        std::vector<Alnreg> av = orchestrate(rv);            // HWMODEL + INTPURGE
        const int nch = (int)rv.chains.size();
        const int nav = (int)av.size();

        snprintf(line,sizeof line,"%d %d %d %d %d %d %d %d %d %d %d %d\n",
            rv.l_query, o.a, o.o_del, o.e_del, o.o_ins, o.e_ins, o.zdrop, o.w,
            o.pen_clip5, o.pen_clip3, nch, nav);
        buf += line;
        for (int i=0;i<rv.l_query;++i){ snprintf(line,sizeof line,"%d ",rv.query[i]); buf+=line; }
        buf += '\n';
        for (int cj=0;cj<nch;++cj){
            const Chain& c = rv.chains[cj];
            const int n=(int)c.seeds.size(), reflen=(int)c.ref.size();
            snprintf(line,sizeof line,"%d %lld %lld %d %d\n",
                c.rid,(long long)c.rmax0,(long long)c.rmax1,n,reflen);
            buf += line;
            for (auto& s : c.seeds){
                snprintf(line,sizeof line,"%lld %d %d %d\n",(long long)s.rbeg,s.qbeg,s.len,s.score);
                buf += line;
            }
            for (int i=0;i<reflen;++i){ snprintf(line,sizeof line,"%d ",c.ref[i]); buf+=line; }
            buf += '\n';
        }
        for (int i=0;i<nav;++i){
            const Alnreg& A=av[i];
            snprintf(line,sizeof line,"%lld %lld %d %d %d %d %d %d %d %d\n",
                (long long)A.rb,(long long)A.re,A.qb,A.qe,A.score,A.truesc,A.w,A.seedcov,A.seedlen0,A.rid);
            buf += line;
        }
        nreads++;
    }
    fprintf(out,"%ld\n",nreads);
    fwrite(buf.data(),1,buf.size(),out);
    fclose(out);
    fprintf(stderr,"wrote %ld read vectors to %s\n", nreads, argv[2]);
    return 0;
}
