// gen_orchrtl_vectors.cpp — golden vectors for tb_matesw_orch_top (the full mate-
// rescue orchestration in HW). Builds synthetic mem_matesw calls and computes the
// truth with orch.h::matesw_orchestrate. Coordinates kept < 2^21 so the TB reads
// 32-bit. Exercises: skip[4] (via ma entries near a), per-orientation host-fed
// windows (some embedding the oriented mate seq -> rescue, some not), insertion-sort
// by score, and the per-orientation dedup.
//
// Format (whitespace-separated ints unless noted):
//   <count>
//   per case:
//     l_ms l_pac a_rb a_rid a_is_alt min_seed_len a o_del e_del o_ins e_ins
//     pes_failed[4]
//     pes_low[4] pes_high[4]
//     win_used[4] win_rb[4] win_re[4] win_rid[4]
//     n_ma_in   n_ma_in*{rb re qb qe rid score cov}
//     ms[l_ms]
//     for r in 0..3: reflen[r]  ref[r][0..reflen-1]      (reflen=0 when !used)
//     n_ma_out fb   n_ma_out*{rb re qb qe rid score cov}   (fb = dedup-tie SW-fallback)
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <vector>
#include <string>
#include "macro.h"
#include "orch.h"

uint64_t tprof[LIM_R][LIM_C];
static uint64_t st = 0x1234abcd5678ef90ull;
static inline uint32_t rnd() { st = st*6364136223846793005ull + 1442695040888963407ull; return (uint32_t)(st>>33); }

static inline bool is_rev_r(int r) { return r==1 || r==2; }

int main(int argc, char** argv) {
    if (argc < 2) { fprintf(stderr, "usage: %s out.txt [n]\n", argv[0]); return 1; }
    int n = argc > 2 ? atoi(argv[2]) : 3000;
    MOpt o;   // a=1,b=4,od6/ed1/oi6/ei1,min_seed_len=19,max_chain_gap=10000,mask=0.95

    std::string buf; buf.reserve(16<<20);
    char line[256];
    long with_rescue = 0;
    for (int it = 0; it < n; ++it) {
        int l_ms = 40 + rnd() % 50;
        int64_t l_pac = 200000 + (int64_t)(rnd() % 800000);
        int64_t a_rb = 100000 + (int64_t)(rnd() % 40000);
        int a_rid = 0, a_is_alt = (int)(rnd() & 1);
        int msl = 19 + (int)(rnd() % 10);
        o.min_seed_len = msl;          // oracle must gate at the SAME threshold the RTL uses

        std::vector<uint8_t> ms(l_ms);
        for (int i = 0; i < l_ms; ++i) ms[i] = rnd() % 4;

        // pes: each orientation fails with some prob; non-failed gets a [low,high].
        MPes pes[4];
        for (int r = 0; r < 4; ++r) {
            pes[r].failed = (rnd() % 100) < 30 ? 1 : 0;
            pes[r].low = 50; pes[r].high = 400 + rnd() % 400;
        }

        // entry ma list: a few entries; some placed to trigger skip in an orientation.
        int n_in = rnd() % 4;
        std::vector<MAln> ma;
        for (int k = 0; k < n_in; ++k) {
            MAln m{}; m.rid = 0;
            m.rb = a_rb + 100 + (int64_t)(rnd() % 500);   // forward, within a window band
            m.re = m.rb + 100; m.qb = 0; m.qe = 100;
            m.score = 30 + rnd() % 60; m.seedcov = rnd() % 50;
            ma.push_back(m);
        }

        // build windows + the oriented refs (embed the oriented seq with prob -> rescue)
        MWin win[4];
        std::vector<std::vector<uint8_t>> refs(4);
        for (int r = 0; r < 4; ++r) {
            win[r].used = 0; win[r].rid = -1; win[r].rb = 0; win[r].re = 0;
            if (pes[r].failed) continue;
            win[r].used = 1;
            win[r].rid  = (rnd() % 100) < 85 ? a_rid : (a_rid + 1);   // mostly matches a.rid
            int pre = rnd() % 30, suf = rnd() % 30, rlen = pre + l_ms + suf;
            std::vector<uint8_t> ref(rlen);
            for (int i = 0; i < rlen; ++i) ref[i] = rnd() % 4;
            if ((rnd() % 100) < 60) {                 // embed the ORIENTED seq -> high score
                std::vector<uint8_t> seq(ms.begin(), ms.end());
                if (is_rev_r(r)) { // revcomp, as orch.h forms it
                    std::vector<uint8_t> rc(l_ms);
                    for (int i = 0; i < l_ms; ++i) rc[l_ms-1-i] = ms[i] < 4 ? 3 - ms[i] : 4;
                    seq = rc;
                }
                for (int i = 0; i < l_ms; ++i) { uint8_t bse = seq[i];
                    if (rnd()%100 < 8) bse = rnd()%4; ref[pre+i] = bse; }
            }
            win[r].rb = a_rb + 50 + (rnd() % 50);
            win[r].re = win[r].rb + rlen;
            win[r].ref = ref;
            refs[r] = ref;
        }

        std::vector<MAln> ma_in = ma;
        bool fb = false;
        matesw_orchestrate(o, l_pac, MAln{a_rb,0,0,0,a_rid,a_is_alt,0,0,0,0,0,0,0,-1}, l_ms, ms.data(), pes, win, ma, &fb);
        if ((int)ma.size() != (int)ma_in.size()) with_rescue++;

        // ---- emit ----
        snprintf(line,sizeof line,"%d %lld %lld %d %d %d %d %d %d %d %d\n",
                 l_ms,(long long)l_pac,(long long)a_rb,a_rid,a_is_alt,msl,o.a,o.o_del,o.e_del,o.o_ins,o.e_ins);
        buf+=line;
        snprintf(line,sizeof line,"%d %d %d %d\n",pes[0].failed,pes[1].failed,pes[2].failed,pes[3].failed); buf+=line;
        snprintf(line,sizeof line,"%lld %lld %lld %lld\n",(long long)pes[0].low,(long long)pes[1].low,(long long)pes[2].low,(long long)pes[3].low); buf+=line;
        snprintf(line,sizeof line,"%lld %lld %lld %lld\n",(long long)pes[0].high,(long long)pes[1].high,(long long)pes[2].high,(long long)pes[3].high); buf+=line;
        snprintf(line,sizeof line,"%d %d %d %d\n",win[0].used,win[1].used,win[2].used,win[3].used); buf+=line;
        snprintf(line,sizeof line,"%lld %lld %lld %lld\n",(long long)win[0].rb,(long long)win[1].rb,(long long)win[2].rb,(long long)win[3].rb); buf+=line;
        snprintf(line,sizeof line,"%lld %lld %lld %lld\n",(long long)win[0].re,(long long)win[1].re,(long long)win[2].re,(long long)win[3].re); buf+=line;
        snprintf(line,sizeof line,"%d %d %d %d\n",win[0].rid,win[1].rid,win[2].rid,win[3].rid); buf+=line;
        snprintf(line,sizeof line,"%d\n",(int)ma_in.size()); buf+=line;
        for (auto&m:ma_in){ snprintf(line,sizeof line,"%lld %lld %d %d %d %d %d\n",
            (long long)m.rb,(long long)m.re,m.qb,m.qe,m.rid,m.score,m.seedcov); buf+=line; }
        for (int i=0;i<l_ms;++i){ snprintf(line,sizeof line,"%d ",ms[i]); buf+=line; } buf+='\n';
        for (int r=0;r<4;++r){
            int rl = win[r].used ? (int)refs[r].size() : 0;
            snprintf(line,sizeof line,"%d ",rl); buf+=line;
            for (int i=0;i<rl;++i){ snprintf(line,sizeof line,"%d ",refs[r][i]); buf+=line; }
            buf+='\n';
        }
        snprintf(line,sizeof line,"%d %d\n",(int)ma.size(),fb?1:0); buf+=line;
        for (auto&m:ma){ snprintf(line,sizeof line,"%lld %lld %d %d %d %d %d\n",
            (long long)m.rb,(long long)m.re,m.qb,m.qe,m.rid,m.score,m.seedcov); buf+=line; }
    }
    FILE* out = fopen(argv[1], "w");
    fprintf(out, "%d\n", n);
    fwrite(buf.data(), 1, buf.size(), out);
    fclose(out);
    fprintf(stderr, "wrote %d orch-top vectors (%ld changed the ma list) to %s\n", n, with_rescue, argv[1]);
    return 0;
}
