// gen_pesel_vectors.cpp — golden vectors for tb_matesw_pe_sel_top (the on-chip
// candidate SELECTION + rescue loop). Builds a scenario with a score-sorted candidate
// SOURCE (read i's alnregs), an entry ma list (read !i), a shared mate sequence, and
// per-source-candidate host-fed windows, then runs matesw_pe_select (pe.h) to select
// the good prefix (score >= top - pen_unpaired, capped at max_matesw) and thread each
// selected candidate through matesw_orchestrate. Emits the source, params, entry ma,
// ms, all windows, and the final ma. Build with -DMR_DEDUP_INT so the oracle uses the
// HW redundancy surrogate (matches matesw_dedup), like the other RTL generators.
//
// Format:
//   <count>
//   per case:
//     l_ms l_pac msl a o_del e_del o_ins e_ins pen_unpaired max_matesw
//     pes_failed[4]  pes_low[4]  pes_high[4]
//     n_ma_init  n_ma_init*{rb re qb qe rid score cov}
//     ms[l_ms]
//     n_src
//     per source candidate (score-sorted DESC): rb rid alt score
//     per source candidate:
//        win_used[4]  win_rb[4]  win_re[4]  win_rid[4]
//        for r 0..3: reflen  ref[0..reflen-1]
//     n_ma_final  n_ma_final*{rb re qb qe rid score cov}
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <vector>
#include <array>
#include <algorithm>
#include <string>
#include "macro.h"
#include "pe.h"

uint64_t tprof[LIM_R][LIM_C];
static uint64_t st = 0xc0ffee1234567890ull;
static inline uint32_t rnd() { st = st*6364136223846793005ull + 1442695040888963407ull; return (uint32_t)(st>>33); }
static inline bool is_rev_r(int r) { return r==1 || r==2; }

int main(int argc, char** argv) {
    if (argc < 2) { fprintf(stderr, "usage: %s out.txt [n]\n", argv[0]); return 1; }
    int n = argc > 2 ? atoi(argv[2]) : 2000;
    MOpt o;

    std::string buf; buf.reserve(24<<20);
    char line[256];
    long total_sel = 0, total_src = 0;
    for (int it = 0; it < n; ++it) {
        int l_ms = 40 + rnd() % 50;
        int64_t l_pac = 200000 + (int64_t)(rnd() % 800000);
        int msl = 19 + (int)(rnd() % 10); o.min_seed_len = msl;
        std::vector<uint8_t> ms(l_ms);
        for (int i = 0; i < l_ms; ++i) ms[i] = rnd() % 4;

        MPeOpt po;
        po.pen_unpaired = 10 + (int)(rnd() % 16);              // 10..25 (bwa default 17)
        po.max_matesw   = (rnd()%100) < 20 ? (1 + (int)(rnd()%3)) : 50;  // sometimes cap small

        MPes pes[4];
        for (int r = 0; r < 4; ++r) { pes[r].failed = (rnd()%100)<25?1:0; pes[r].low=50; pes[r].high=400+rnd()%400; }

        // entry ma (read !i's list)
        int n_init = rnd() % 3;
        std::vector<MAln> ma;
        int64_t base_pos = 100000 + (int64_t)(rnd()%40000);
        for (int k = 0; k < n_init; ++k) {
            MAln m{}; m.rid=0; m.rb=base_pos+200+(int64_t)(rnd()%500); m.re=m.rb+100;
            m.qb=0; m.qe=100; m.score=30+rnd()%60; m.seedcov=rnd()%50; ma.push_back(m);
        }

        // candidate source (read i's alnregs). scores straddle top - pen_unpaired so
        // the prefix gate selects a varying count; sorted DESC by score (== accel/dedup).
        int n_src = 1 + rnd() % 6;
        int top = 60 + (int)(rnd()%40);
        std::vector<MAln> src(n_src);
        for (int c = 0; c < n_src; ++c) {
            MAln& s = src[c];
            s.rb  = base_pos + (int64_t)(rnd()%2000);
            s.rid = 0; s.is_alt = 0;          // Stage-1: is_alt dropped on-chip (=0)
            // spread scores around the gate boundary (some pass, some fail)
            s.score = top - (int)(rnd() % (po.pen_unpaired + 15));
        }
        std::sort(src.begin(), src.end(), [](const MAln& x, const MAln& y){ return x.score > y.score; });
        src[0].score = top;                   // ensure src[0] is the true top

        // per-source-candidate host-fed windows (parallel to src; only the selected
        // prefix is consumed by matesw_pe_select / requested by the RTL)
        std::vector<std::array<MWin,4>> win(n_src);
        for (int c = 0; c < n_src; ++c) {
            int64_t a_rb = src[c].rb; int a_rid = src[c].rid;
            for (int r = 0; r < 4; ++r) {
                MWin& w = win[c][r];
                w.used=0; w.rid=-1; w.rb=0; w.re=0;
                if (pes[r].failed) continue;
                w.used=1;
                w.rid = (rnd()%100)<85 ? a_rid : a_rid+1;
                int pre=rnd()%30, suf=rnd()%30, rlen=pre+l_ms+suf;
                std::vector<uint8_t> ref(rlen);
                for (int i=0;i<rlen;++i) ref[i]=rnd()%4;
                if ((rnd()%100)<60) {                 // plant the mate so SW can fire
                    std::vector<uint8_t> seq(ms.begin(), ms.end());
                    if (is_rev_r(r)) { std::vector<uint8_t> rc(l_ms);
                        for (int i=0;i<l_ms;++i) rc[l_ms-1-i]=ms[i]<4?3-ms[i]:4; seq=rc; }
                    for (int i=0;i<l_ms;++i){ uint8_t bse=seq[i]; if(rnd()%100<8) bse=rnd()%4; ref[pre+i]=bse; }
                }
                w.rb = a_rb + 50 + (rnd()%50);
                w.re = w.rb + rlen;
                w.ref = ref;
            }
        }

        // ---- run the model -> final ma ----
        std::vector<MAln> ma_init = ma;
        matesw_pe_select(o, po, l_pac, src, l_ms, ms.data(), pes, win, ma);

        // count selected (for the stderr summary only — matches the RTL's K)
        { int thr = src[0].score - po.pen_unpaired, k=0;
          for (int j=0;j<n_src && j<po.max_matesw;++j){ if (src[j].score<thr) break; ++k; }
          total_sel += k; }
        total_src += n_src;

        // ---- emit ----
        snprintf(line,sizeof line,"%d %lld %d %d %d %d %d %d %d %d\n",
                 l_ms,(long long)l_pac,msl,o.a,o.o_del,o.e_del,o.o_ins,o.e_ins,
                 po.pen_unpaired,po.max_matesw); buf+=line;
        snprintf(line,sizeof line,"%d %d %d %d\n",pes[0].failed,pes[1].failed,pes[2].failed,pes[3].failed); buf+=line;
        snprintf(line,sizeof line,"%lld %lld %lld %lld\n",(long long)pes[0].low,(long long)pes[1].low,(long long)pes[2].low,(long long)pes[3].low); buf+=line;
        snprintf(line,sizeof line,"%lld %lld %lld %lld\n",(long long)pes[0].high,(long long)pes[1].high,(long long)pes[2].high,(long long)pes[3].high); buf+=line;
        snprintf(line,sizeof line,"%d\n",(int)ma_init.size()); buf+=line;
        for (auto&m:ma_init){ snprintf(line,sizeof line,"%lld %lld %d %d %d %d %d\n",
            (long long)m.rb,(long long)m.re,m.qb,m.qe,m.rid,m.score,m.seedcov); buf+=line; }
        for (int i=0;i<l_ms;++i){ snprintf(line,sizeof line,"%d ",ms[i]); buf+=line; } buf+='\n';
        snprintf(line,sizeof line,"%d\n",n_src); buf+=line;
        for (int c=0;c<n_src;++c){ snprintf(line,sizeof line,"%lld %d %d %d\n",
            (long long)src[c].rb,src[c].rid,src[c].is_alt,src[c].score); buf+=line; }
        for (int c=0;c<n_src;++c){
            snprintf(line,sizeof line,"%d %d %d %d\n",win[c][0].used,win[c][1].used,win[c][2].used,win[c][3].used); buf+=line;
            snprintf(line,sizeof line,"%lld %lld %lld %lld\n",(long long)win[c][0].rb,(long long)win[c][1].rb,(long long)win[c][2].rb,(long long)win[c][3].rb); buf+=line;
            snprintf(line,sizeof line,"%lld %lld %lld %lld\n",(long long)win[c][0].re,(long long)win[c][1].re,(long long)win[c][2].re,(long long)win[c][3].re); buf+=line;
            snprintf(line,sizeof line,"%d %d %d %d\n",win[c][0].rid,win[c][1].rid,win[c][2].rid,win[c][3].rid); buf+=line;
            for (int r=0;r<4;++r){ int rl = win[c][r].used ? (int)win[c][r].ref.size() : 0;
                snprintf(line,sizeof line,"%d ",rl); buf+=line;
                for (int i=0;i<rl;++i){ snprintf(line,sizeof line,"%d ",win[c][r].ref[i]); buf+=line; } buf+='\n'; }
        }
        snprintf(line,sizeof line,"%d\n",(int)ma.size()); buf+=line;
        for (auto&m:ma){ snprintf(line,sizeof line,"%lld %lld %d %d %d %d %d\n",
            (long long)m.rb,(long long)m.re,m.qb,m.qe,m.rid,m.score,m.seedcov); buf+=line; }
    }
    FILE* out = fopen(argv[1], "w");
    fprintf(out, "%d\n", n);
    fwrite(buf.data(), 1, buf.size(), out);
    fclose(out);
    fprintf(stderr, "wrote %d pe-sel cases (%ld src, %ld selected) to %s\n", n, total_src, total_sel, argv[1]);
    return 0;
}
