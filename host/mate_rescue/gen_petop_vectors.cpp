// gen_petop_vectors.cpp — golden vectors for tb_matesw_pe_top (the paired-end
// candidate loop). Builds a scenario with an entry ma list, a shared mate sequence,
// and several rescue candidates (each with its own host-fed windows), then threads
// ma through matesw_orchestrate once per candidate (== the b[i] loop of
// mem_sam_pe_batch_post). Emits the entry ma, ms, the candidates, and the final ma.
// -DMR_DEDUP_INT: oracle uses the HW redundancy surrogate.
//
// Format:
//   <count>
//   per case:
//     l_ms l_pac msl a o_del e_del o_ins e_ins
//     pes_failed[4]  pes_low[4]  pes_high[4]
//     n_ma_init  n_ma_init*{rb re qb qe rid score cov}
//     ms[l_ms]
//     n_cand
//     per candidate:
//        a_rb a_rid a_is_alt
//        win_used[4]  win_rb[4]  win_re[4]  win_rid[4]
//        for r 0..3: reflen  ref[0..reflen-1]
//     n_ma_final  n_ma_final*{rb re qb qe rid score cov}
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <vector>
#include <string>
#include "macro.h"
#include "orch.h"

uint64_t tprof[LIM_R][LIM_C];
static uint64_t st = 0xfee1baadd00dfaceull;
static inline uint32_t rnd() { st = st*6364136223846793005ull + 1442695040888963407ull; return (uint32_t)(st>>33); }
static inline bool is_rev_r(int r) { return r==1 || r==2; }

int main(int argc, char** argv) {
    if (argc < 2) { fprintf(stderr, "usage: %s out.txt [n]\n", argv[0]); return 1; }
    int n = argc > 2 ? atoi(argv[2]) : 2000;
    MOpt o;

    std::string buf; buf.reserve(24<<20);
    char line[256];
    long total_cand = 0;
    for (int it = 0; it < n; ++it) {
        int l_ms = 40 + rnd() % 50;
        int64_t l_pac = 200000 + (int64_t)(rnd() % 800000);
        int msl = 19 + (int)(rnd() % 10); o.min_seed_len = msl;
        std::vector<uint8_t> ms(l_ms);
        for (int i = 0; i < l_ms; ++i) ms[i] = rnd() % 4;

        MPes pes[4];
        for (int r = 0; r < 4; ++r) { pes[r].failed = (rnd()%100)<25?1:0; pes[r].low=50; pes[r].high=400+rnd()%400; }

        // entry ma
        int n_init = rnd() % 3;
        std::vector<MAln> ma;
        int64_t base_pos = 100000 + (int64_t)(rnd()%40000);
        for (int k = 0; k < n_init; ++k) {
            MAln m{}; m.rid=0; m.rb=base_pos+200+(int64_t)(rnd()%500); m.re=m.rb+100;
            m.qb=0; m.qe=100; m.score=30+rnd()%60; m.seedcov=rnd()%50; ma.push_back(m);
        }

        int n_cand = 1 + rnd() % 4;
        // pre-build per-candidate data so we can emit AFTER computing the final ma
        struct Cand { int64_t a_rb; int a_rid, a_is_alt; MWin win[4]; std::vector<std::vector<uint8_t>> refs; };
        std::vector<Cand> cands(n_cand);
        for (int c = 0; c < n_cand; ++c) {
            Cand& cd = cands[c]; cd.refs.resize(4);
            cd.a_rb = base_pos + (int64_t)(rnd()%2000); cd.a_rid = 0; cd.a_is_alt = (int)(rnd()&1);
            for (int r = 0; r < 4; ++r) {
                cd.win[r].used=0; cd.win[r].rid=-1; cd.win[r].rb=0; cd.win[r].re=0;
                if (pes[r].failed) continue;
                cd.win[r].used=1;
                cd.win[r].rid = (rnd()%100)<85 ? cd.a_rid : cd.a_rid+1;
                int pre=rnd()%30, suf=rnd()%30, rlen=pre+l_ms+suf;
                std::vector<uint8_t> ref(rlen);
                for (int i=0;i<rlen;++i) ref[i]=rnd()%4;
                if ((rnd()%100)<60) {
                    std::vector<uint8_t> seq(ms.begin(), ms.end());
                    if (is_rev_r(r)) { std::vector<uint8_t> rc(l_ms);
                        for (int i=0;i<l_ms;++i) rc[l_ms-1-i]=ms[i]<4?3-ms[i]:4; seq=rc; }
                    for (int i=0;i<l_ms;++i){ uint8_t bse=seq[i]; if(rnd()%100<8) bse=rnd()%4; ref[pre+i]=bse; }
                }
                cd.win[r].rb = cd.a_rb + 50 + (rnd()%50);
                cd.win[r].re = cd.win[r].rb + rlen;
                cd.win[r].ref = ref; cd.refs[r] = ref;
            }
        }

        std::vector<MAln> ma_init = ma;
        bool fb = false;
        for (int c = 0; c < n_cand; ++c) {
            Cand& cd = cands[c];
            MAln A{cd.a_rb,0,0,0,cd.a_rid,cd.a_is_alt,0,0,0,0,0,0,0,-1};
            matesw_orchestrate(o, l_pac, A, l_ms, ms.data(), pes, cd.win, ma, &fb);  // fb accumulates
        }
        total_cand += n_cand;

        // ---- emit ----
        snprintf(line,sizeof line,"%d %lld %d %d %d %d %d %d\n",
                 l_ms,(long long)l_pac,msl,o.a,o.o_del,o.e_del,o.o_ins,o.e_ins); buf+=line;
        snprintf(line,sizeof line,"%d %d %d %d\n",pes[0].failed,pes[1].failed,pes[2].failed,pes[3].failed); buf+=line;
        snprintf(line,sizeof line,"%lld %lld %lld %lld\n",(long long)pes[0].low,(long long)pes[1].low,(long long)pes[2].low,(long long)pes[3].low); buf+=line;
        snprintf(line,sizeof line,"%lld %lld %lld %lld\n",(long long)pes[0].high,(long long)pes[1].high,(long long)pes[2].high,(long long)pes[3].high); buf+=line;
        snprintf(line,sizeof line,"%d\n",(int)ma_init.size()); buf+=line;
        for (auto&m:ma_init){ snprintf(line,sizeof line,"%lld %lld %d %d %d %d %d\n",
            (long long)m.rb,(long long)m.re,m.qb,m.qe,m.rid,m.score,m.seedcov); buf+=line; }
        for (int i=0;i<l_ms;++i){ snprintf(line,sizeof line,"%d ",ms[i]); buf+=line; } buf+='\n';
        snprintf(line,sizeof line,"%d\n",n_cand); buf+=line;
        for (int c=0;c<n_cand;++c){ Cand& cd=cands[c];
            snprintf(line,sizeof line,"%lld %d %d\n",(long long)cd.a_rb,cd.a_rid,cd.a_is_alt); buf+=line;
            snprintf(line,sizeof line,"%d %d %d %d\n",cd.win[0].used,cd.win[1].used,cd.win[2].used,cd.win[3].used); buf+=line;
            snprintf(line,sizeof line,"%lld %lld %lld %lld\n",(long long)cd.win[0].rb,(long long)cd.win[1].rb,(long long)cd.win[2].rb,(long long)cd.win[3].rb); buf+=line;
            snprintf(line,sizeof line,"%lld %lld %lld %lld\n",(long long)cd.win[0].re,(long long)cd.win[1].re,(long long)cd.win[2].re,(long long)cd.win[3].re); buf+=line;
            snprintf(line,sizeof line,"%d %d %d %d\n",cd.win[0].rid,cd.win[1].rid,cd.win[2].rid,cd.win[3].rid); buf+=line;
            for (int r=0;r<4;++r){ int rl = cd.win[r].used ? (int)cd.refs[r].size() : 0;
                snprintf(line,sizeof line,"%d ",rl); buf+=line;
                for (int i=0;i<rl;++i){ snprintf(line,sizeof line,"%d ",cd.refs[r][i]); buf+=line; } buf+='\n'; }
        }
        snprintf(line,sizeof line,"%d %d\n",(int)ma.size(),fb?1:0); buf+=line;
        for (auto&m:ma){ snprintf(line,sizeof line,"%lld %lld %d %d %d %d %d\n",
            (long long)m.rb,(long long)m.re,m.qb,m.qe,m.rid,m.score,m.seedcov); buf+=line; }
    }
    FILE* out = fopen(argv[1], "w");
    fprintf(out, "%d\n", n);
    fwrite(buf.data(), 1, buf.size(), out);
    fclose(out);
    fprintf(stderr, "wrote %d pe-top cases (%ld candidates total) to %s\n", n, total_cand, argv[1]);
    return 0;
}
