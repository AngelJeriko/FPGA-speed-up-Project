// check_orch.cpp — validate the mate-rescue ORCHESTRATION model (orch.h) bit-exact
// against REAL captured mem_matesw_batch_post calls (capture/orch_capture.inc, env
// ALNREG_ORCH_OUT). Replays each call through matesw_orchestrate() and compares the
// exit ma list (rb,re,qb,qe,rid,score,is_alt,seedcov — csub excluded; score2 n/a).
//
// Record format: see host/mate_rescue/capture/orch_capture.inc.
// Build: make checkorch     Run: ./check_orch vectors/orch_vec.bin
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <vector>
#include "macro.h"
#include "orch.h"

uint64_t tprof[LIM_R][LIM_C];

template<class T> static bool rd(FILE*f, T&v){ return fread(&v,sizeof(T),1,f)==1; }

static bool read_rec(FILE* f, MAln& m) {
    int64_t rb,re; int32_t qb,qe,rid,alt,sc,cov;
    if(!rd(f,rb)||!rd(f,re)||!rd(f,qb)||!rd(f,qe)||!rd(f,rid)||!rd(f,alt)||!rd(f,sc)||!rd(f,cov)) return false;
    m = MAln{}; m.rb=rb; m.re=re; m.qb=qb; m.qe=qe; m.rid=rid; m.is_alt=alt; m.score=sc; m.seedcov=cov;
    return true;
}
static bool eq(const MAln& x, const MAln& y) {
    return x.rb==y.rb && x.re==y.re && x.qb==y.qb && x.qe==y.qe &&
           x.rid==y.rid && x.score==y.score && x.is_alt==y.is_alt && x.seedcov==y.seedcov;
}

int main(int argc, char** argv){
    if (argc<2){ fprintf(stderr,"usage: %s capture.bin\n",argv[0]); return 2; }
    FILE* f=fopen(argv[1],"rb");
    if(!f){ fprintf(stderr,"cannot open %s\n",argv[1]); return 2; }

    long checked=0, fails=0, rescued=0, fbcount=0;
    int32_t type;
    while (rd(f,type)){
        if (type!=0){ fprintf(stderr,"bad type %d\n",type); break; }
        int64_t cid, a_rb, l_pac; int32_t a_rid, a_alt, l_ms;
        if(!rd(f,cid)||!rd(f,a_rb)||!rd(f,a_rid)||!rd(f,a_alt)||!rd(f,l_pac)||!rd(f,l_ms)){ fprintf(stderr,"trunc hdr\n"); break; }
        std::vector<uint8_t> ms(l_ms);
        if(l_ms && fread(ms.data(),1,l_ms,f)!=(size_t)l_ms){ fprintf(stderr,"trunc ms\n"); break; }
        int32_t cfg[7]; if(fread(cfg,4,7,f)!=7){ fprintf(stderr,"trunc cfg\n"); break; }
        MPes pes[4];
        bool ok=true;
        for (int r=0;r<4;++r){ int32_t fl; int64_t lo,hi;
            if(!rd(f,fl)||!rd(f,lo)||!rd(f,hi)){ ok=false; break; } pes[r].failed=fl; pes[r].low=lo; pes[r].high=hi; }
        if(!ok){ fprintf(stderr,"trunc pes\n"); break; }
        int32_t nin; if(!rd(f,nin)){ fprintf(stderr,"trunc nin\n"); break; }
        std::vector<MAln> ma;
        for (int i=0;i<nin;++i){ MAln m; if(!read_rec(f,m)){ ok=false; break; } ma.push_back(m); }
        if(!ok){ fprintf(stderr,"trunc ma_in\n"); break; }
        MWin win[4];
        for (int r=0;r<4;++r){ int32_t u; int64_t wrb,wre; int32_t wrid; int64_t rl;
            if(!rd(f,u)||!rd(f,wrb)||!rd(f,wre)||!rd(f,wrid)||!rd(f,rl)){ ok=false; break; }
            win[r].used=u; win[r].rb=wrb; win[r].re=wre; win[r].rid=wrid; win[r].ref.resize(rl);
            if(rl && fread(win[r].ref.data(),1,rl,f)!=(size_t)rl){ ok=false; break; } }
        if(!ok){ fprintf(stderr,"trunc win\n"); break; }
        int32_t nout; if(!rd(f,nout)){ fprintf(stderr,"trunc nout\n"); break; }
        std::vector<MAln> cap;
        for (int i=0;i<nout;++i){ MAln m; if(!read_rec(f,m)){ ok=false; break; } cap.push_back(m); }
        if(!ok){ fprintf(stderr,"trunc ma_out\n"); break; }

        MOpt o; o.a=cfg[0]; o.b=cfg[1]; o.o_del=cfg[2]; o.e_del=cfg[3];
        o.o_ins=cfg[4]; o.e_ins=cfg[5]; o.min_seed_len=cfg[6];
        MAln A{}; A.rb=a_rb; A.rid=a_rid; A.is_alt=a_alt;
        bool fb=false;
        matesw_orchestrate(o, l_pac, A, l_ms, ms.data(), pes, win, ma, &fb);

        checked++;
        if (fb) { fbcount++; continue; }   // dedup sort-key tie -> SW-fallback (introsort vs stable)
        if ((int)ma.size() > nin) rescued++;
        bool bad = ((int)ma.size()!=nout);
        if (!bad) for (int i=0;i<nout;++i) if(!eq(ma[i],cap[i])){ bad=true; break; }
        if (bad){ fails++;
            if (fails<=20){
                printf("MISMATCH call_id=%lld nin=%d got=%zu cap=%d\n",(long long)cid,nin,ma.size(),nout);
                for (size_t i=0;i<ma.size()||i<(size_t)nout;++i){
                    if(i<ma.size()) printf("  got[%zu] rb=%lld re=%lld qb=%d qe=%d sc=%d cov=%d\n",
                        i,(long long)ma[i].rb,(long long)ma[i].re,ma[i].qb,ma[i].qe,ma[i].score,ma[i].seedcov);
                    if(i<(size_t)nout) printf("  cap[%zu] rb=%lld re=%lld qb=%d qe=%d sc=%d cov=%d\n",
                        i,(long long)cap[i].rb,(long long)cap[i].re,cap[i].qb,cap[i].qe,cap[i].score,cap[i].seedcov);
                }
            }
        }
    }
    fclose(f);
    printf("check_orch: %ld calls checked, %ld SW-fallback (dedup tie, excluded), %ld rescue, %ld NON-FALLBACK failures -> %s\n",
           checked, fbcount, rescued, fails, (fails==0 && checked>0) ? "ALL PASS" : "FAIL");
    return (fails==0 && checked>0) ? 0 : 1;
}
