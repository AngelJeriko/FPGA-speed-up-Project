// gen_accel_vectors.cpp — per-read golden for tb_accel_top (full accelerator).
//
// Pipeline golden: orchestrate() -> compact (keep qe>qb, as bwamem.cpp does before
// mem_sort_dedup_patch) -> v2_dedup(). A read takes the SW fallback (no HW output
// compared) when its compacted array has an equal-re tie or n>1024 (the sorter's
// contract). Build with -DHWMODEL -DINTPURGE so the extension+purge match the RTL.
//
// Output:
//   <nreads>
//   per read:
//     l_query a o_del e_del o_ins e_ins zdrop w pen5 pen3 nchain nav
//     query[0..l_query-1]
//     per chain: rid rmax0 rmax1 n_seeds reflen ; seeds ; ref
//     fallback nout
//     nout*{rb re qb qe rid score}        (nout=0 when fallback)
#include <cstdio>
#include <cstdlib>
#include <vector>
#include <algorithm>
#include <string>
#include "parse.h"
#include "../merge_sorter/v2_dedup.h"

static const int SAMPLE = 150;
static const int N_MAX  = 1024;

int main(int argc, char** argv) {
    if (argc < 3) { fprintf(stderr, "usage: %s vectors.bin out.txt\n", argv[0]); return 1; }
    auto reads = load_reads(argv[1]);
    FILE* out = fopen(argv[2], "w");
    if (!out) { fprintf(stderr, "cannot open %s\n", argv[2]); return 1; }

    std::string buf; buf.reserve(64<<20);
    char line[256];
    long nreads = 0, ctr = 0, nfb = 0;

    for (auto& rv : reads) {
        if (ctr++ % SAMPLE != 0) continue;
        const Cfg& o = rv.cfg;
        std::vector<Alnreg> av = orchestrate(rv);            // HWMODEL + INTPURGE
        const int nch = (int)rv.chains.size();
        const int nav = (int)av.size();

        // compact: keep qe>qb, build V2Key array (sorter's record)
        std::vector<V2Key> arr;
        for (auto& A : av) if (A.qe > A.qb)
            arr.push_back({A.rb, A.re, A.qb, A.qe, A.rid, A.score});
        // fallback: equal-re tie (any duplicate re) or n>N_MAX
        bool fb = ((int)arr.size() > N_MAX);
        if (!fb) {
            std::vector<int64_t> res; for (auto& k : arr) res.push_back(k.re);
            std::sort(res.begin(), res.end());
            for (size_t i = 1; i < res.size(); ++i) if (res[i] == res[i-1]) { fb = true; break; }
        }
        int nout = 0;
        std::vector<V2Key> a2 = arr;
        if (!fb) nout = v2_dedup(a2.data(), (int)a2.size());
        if (fb) nfb++;

        // ---- emit inputs ----
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
                c.rid,(long long)c.rmax0,(long long)c.rmax1,n,reflen); buf += line;
            for (auto& s : c.seeds){
                snprintf(line,sizeof line,"%lld %d %d %d\n",(long long)s.rbeg,s.qbeg,s.len,s.score); buf+=line; }
            for (int i=0;i<reflen;++i){ snprintf(line,sizeof line,"%d ",c.ref[i]); buf+=line; }
            buf += '\n';
        }
        // ---- emit expected ----
        snprintf(line,sizeof line,"%d %d\n", fb?1:0, nout); buf += line;
        for (int i=0;i<nout;++i){
            snprintf(line,sizeof line,"%lld %lld %d %d %d %d\n",
                (long long)a2[i].rb,(long long)a2[i].re,a2[i].qb,a2[i].qe,a2[i].rid,a2[i].score);
            buf += line;
        }
        nreads++;
    }
    fprintf(out,"%ld\n",nreads);
    fwrite(buf.data(),1,buf.size(),out);
    fclose(out);
    fprintf(stderr,"wrote %ld read vectors (%ld fallback) to %s\n", nreads, nfb, argv[2]);
    return 0;
}
