// gen_chaining_extend_vectors.cpp — END-TO-END golden for tb_chaining_extend_top (RTL
// chaining_top -> chain2aln_setup -> accel_top). Runs the full software pipeline on raw seeds:
//   chain.h c_mem_chain + c_mem_chain_flt  (chaining; dup-pos/combsort -> read SW-fallback)
//   chain2aln.h c_compute_rmax             (per surviving chain: ref-window bounds)
//   synthetic genome g(pos) = pos & 3      (ref window bytes; the TB serves the SAME g)
//   orch.h orchestrate (HWMODEL+INTPURGE)  (extension + seedcov + purge)
//   compact (keep qe>qb) + accel fallback (equal-re tie / n>1024) + v2_dedup (sort+dedup)
// The query is built on the PRIMARY surviving chain's diagonal so its seeds are real matches in
// g (-> non-trivial extensions); secondary chains score low (realistic).
//
// Fallback is emitted STAGE-SPECIFICALLY (fb_chain = chaining dup-pos/combsort, fb_sort = accel
// equal-re tie / n>1024) so the TB can check each bit on its own -- the host redoes only the
// failed stage. Chaining short-circuits the read, so fb_chain=1 implies fb_sort=0. Either bit
// makes the RTL raise `fallback` and the TB skips the output check.
//
// Build with -DHWMODEL -DINTPURGE (so extension+purge match the RTL), -I../chaining.
// Output:
//   <count>
//   per read:
//     l_query a o_del e_del o_ins e_ins zdrop w pen5 pen3 max_chain_gap min_seed_len max_chain_extend l_pac n_seeds
//     n_seeds * { rbeg qbeg len score rid is_alt }
//     query[0..l_query-1]
//     fb_chain fb_sort nout
//     nout * { rb re qb qe rid score }
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <vector>
#include <string>
#include <algorithm>
#include "chain.h"          // ../chaining/chain.h  (CSeed,CChain,COpt, c_mem_chain[_flt])
#include "chain2aln.h"      // c_compute_rmax (+ orch.h: Seed,Cfg,Chain,ReadVec,orchestrate)
#include "../merge_sorter/v2_dedup.h"

static uint64_t st = 0x70d1ad2c0a1f3e70ull;
static inline uint32_t rnd() { st = st*6364136223846793005ull + 1442695040888963407ull; return (uint32_t)(st>>33); }
static inline uint8_t g(int64_t pos) { return (uint8_t)(pos & 3); }   // synthetic genome

int main(int argc, char** argv) {
    if (argc < 2) { fprintf(stderr, "usage: %s out.txt [n]\n", argv[0]); return 1; }
    int n = argc > 2 ? atoi(argv[2]) : 2000;
    const int   l_query = 130;
    const int64_t l_pac = (int64_t)1 << 34;     // large -> no l_pac upper clamp/boundary (those tested in tb_chain2aln_setup)

    // fixed bwa-mem2 defaults (the RTL hardcodes match=+1/mismatch=-4)
    COpt copt;                                  // w=100, gap=10000, msl=19, mcw=0, mce=1<<30
    Cfg  ecfg{}; ecfg.a=1; ecfg.b=4; ecfg.o_del=6; ecfg.e_del=1; ecfg.o_ins=6; ecfg.e_ins=1;
    ecfg.w=100; ecfg.zdrop=100; ecfg.pen_clip5=5; ecfg.pen_clip3=5; bwa_fill_scmat(ecfg.a, ecfg.b, ecfg.mat);

    std::string buf; buf.reserve(32<<20);
    char line[256];
    long nfb=0, nfb_chain=0, nfb_sort=0;
    for (int it=0; it<n; ++it) {
        COpt o = copt;
        if ((rnd()%6)==0) o.max_chain_extend = 1 + rnd()%5;     // exercise the cap path

        int ns = 1 + rnd()%24;
        std::vector<CSeed> seeds; std::vector<int> rid; std::vector<bool> alt;
        for (int k=0;k<ns;++k){
            int64_t base = (int64_t)(rnd()%4)*1500;
            int64_t rb   = base + (int64_t)(rnd()%40);          // tight cluster -> dup-pos + small windows
            int qb       = (int)(rnd()%80);
            int ln       = 19 + (int)(rnd()%30);                // qb+ln <= 109 < l_query
            CSeed s; s.rbeg=rb; s.qbeg=qb; s.len=ln; s.score=ln;
            seeds.push_back(s); rid.push_back((int)(rnd()%2)); alt.push_back((rnd()&1)!=0);
        }

        bool fb_chain=false, fb_comb=false;
        std::vector<CChain> chains = c_mem_chain(o, l_pac, 0, seeds, rid, alt, &fb_chain);
        for (size_t i=0;i<chains.size();++i) chains[i].seqid=(int)i;
        std::vector<CChain> surv = c_mem_chain_flt(o, chains, &fb_comb);
        bool fb_chaining = fb_chain || fb_comb;

        // query on the primary surviving chain's diagonal (its seeds match g there)
        int64_t D = (!surv.empty() && !surv[0].seeds.empty())
                    ? (surv[0].seeds[0].rbeg - surv[0].seeds[0].qbeg) : 0;
        std::vector<uint8_t> query(l_query);
        for (int j=0;j<l_query;++j) query[j] = g(D + j);

        bool fb_accel=false; int nout=0; std::vector<V2Key> a2;
        if (!fb_chaining) {
            ReadVec rv; rv.l_query=l_query; rv.cfg=ecfg; rv.query=query;
            for (const CChain& c : surv) {
                Chain ch; ch.chain_idx=(int)rv.chains.size(); ch.rid=c.rid;
                for (const CSeed& s : c.seeds){ Seed t; t.rbeg=s.rbeg; t.qbeg=s.qbeg; t.len=s.len; t.score=s.score; ch.seeds.push_back(t); }
                c_compute_rmax(ch.seeds, l_query, l_pac, ecfg, ch.rmax0, ch.rmax1);
                ch.ref.resize((size_t)(ch.rmax1-ch.rmax0));
                for (int64_t i=0;i<ch.rmax1-ch.rmax0;++i) ch.ref[i]=g(ch.rmax0+i);
                rv.chains.push_back(std::move(ch));
            }
            std::vector<Alnreg> av = orchestrate(rv);
            std::vector<V2Key> arr;
            for (auto& A : av) if (A.qe>A.qb) arr.push_back({A.rb,A.re,A.qb,A.qe,A.rid,A.score});
            fb_accel = ((int)arr.size() > 1024);
            if (!fb_accel) { std::vector<int64_t> res; for(auto&k:arr) res.push_back(k.re);
                std::sort(res.begin(),res.end());
                for (size_t i=1;i<res.size();++i) if (res[i]==res[i-1]){ fb_accel=true; break; } }
            a2 = arr;
            if (!fb_accel) nout = v2_dedup(a2.data(), (int)a2.size());
        }
        bool fb = fb_chaining || fb_accel;
        if (fb) nfb++;
        if (fb_chaining) nfb_chain++;
        if (fb_accel)    nfb_sort++;

        snprintf(line,sizeof line,"%d %d %d %d %d %d %d %d %d %d %d %d %d %lld %d\n",
            l_query, ecfg.a, ecfg.o_del, ecfg.e_del, ecfg.o_ins, ecfg.e_ins, ecfg.zdrop, ecfg.w,
            ecfg.pen_clip5, ecfg.pen_clip3, o.max_chain_gap, o.min_seed_len, o.max_chain_extend,
            (long long)l_pac, ns); buf+=line;
        for (int k=0;k<ns;++k){ snprintf(line,sizeof line,"%lld %d %d %d %d %d\n",
            (long long)seeds[k].rbeg,seeds[k].qbeg,seeds[k].len,seeds[k].score,rid[k],alt[k]?1:0); buf+=line; }
        for (int j=0;j<l_query;++j){ snprintf(line,sizeof line,"%d ",query[j]); buf+=line; } buf+='\n';
        snprintf(line,sizeof line,"%d %d %d\n", fb_chaining?1:0, fb_accel?1:0, fb?0:nout); buf+=line;
        if (!fb) for (int i=0;i<nout;++i){ snprintf(line,sizeof line,"%lld %lld %d %d %d %d\n",
            (long long)a2[i].rb,(long long)a2[i].re,a2[i].qb,a2[i].qe,a2[i].rid,a2[i].score); buf+=line; }
    }
    FILE* out=fopen(argv[1],"w"); if(!out){ fprintf(stderr,"cannot open %s\n",argv[1]); return 1; }
    fprintf(out,"%d\n",n);
    fwrite(buf.data(),1,buf.size(),out); fclose(out);
    fprintf(stderr,"wrote %d chaining-extend vectors (%ld fallback: %ld chaining, %ld sort) to %s\n",
            n, nfb, nfb_chain, nfb_sort, argv[1]);
    return 0;
}
