// gen_pe2_vectors.cpp — FULL closed-loop golden for tb_accel_pe2_loop: drives the entire
// fold through the RTL on real-accel data and checks the FINAL rescued ma bit-exact.
//
// Key idea (avoids combining the extend + mate header subsystems in one TU): the accel
// outputs are already in accel_vectors.txt (produced by gen_accel_vectors), and
// tb_accel_pe2_top already proved the RTL accel output equals those records. So this
// generator PARSES accel_vectors.txt — taking read i's output as the candidate SOURCE and
// read !i's output as the entry ma — then runs ONLY pe.h::matesw_pe_select for the rescue.
// It re-emits both reads' accel INPUT blocks (so the RTL regenerates the identical
// source/ma on-chip), plus the rescue params + ms + synthesized windows + final ma.
//
// Build: -DMR_DEDUP_INT (pe.h mr_dedup uses the integer redundancy surrogate == matesw_dedup).
// Only pairs where BOTH reads are non-fallback, non-empty, and within the 64-deep buffers
// are emitted. The mate sequence ms = read !i's query (parsed from its accel input block).
//
// Format (per case): two accel blocks (read i, read !i) in gen_accel layout, then:
//   l_ms l_pac msl a_sc mo_del me_del mo_ins me_ins pen_unpaired max_matesw
//   pes_failed[4] pes_low[4] pes_high[4] ; ms[l_ms]
//   per source candidate (nsrc = read-i nout): win_used[4] win_rb[4] win_re[4] win_rid[4] ; for r: reflen ref[...]
//   n_ma_final  n_ma_final*{rb re qb qe rid score cov}
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <vector>
#include <array>
#include <string>
#include "macro.h"
#include "pe.h"

uint64_t tprof[LIM_R][LIM_C];
static const int BUF = 64;          // RTL NSRC / MA_MAX

static uint64_t st = 0x9e3779b97f4a7c15ull;
static inline uint32_t rnd() { st = st*6364136223846793005ull + 1442695040888963407ull; return (uint32_t)(st>>33); }
static inline bool is_rev_r(int r) { return r==1 || r==2; }

struct OutRec { int64_t rb, re; int qb, qe, rid, score; };
struct Seed   { int64_t rbeg; int qbeg, len, score; };
struct Chain  { int rid; int64_t rmax0, rmax1; int nseeds, reflen; std::vector<Seed> seeds; std::vector<int> ref; };
struct ARead {
    int l_query,a,o_del,e_del,o_ins,e_ins,zdrop,w,pen5,pen3,nch,nav;
    std::vector<int> query;
    std::vector<Chain> chains;
    int fb, nout;
    std::vector<OutRec> out;
};

// parse one read block (gen_accel layout) from fd
static bool parse_read(FILE* fd, ARead& r) {
    if (fscanf(fd,"%d %d %d %d %d %d %d %d %d %d %d %d",
        &r.l_query,&r.a,&r.o_del,&r.e_del,&r.o_ins,&r.e_ins,&r.zdrop,&r.w,&r.pen5,&r.pen3,&r.nch,&r.nav)!=12) return false;
    r.query.resize(r.l_query);
    for (int i=0;i<r.l_query;++i) if (fscanf(fd,"%d",&r.query[i])!=1) return false;
    r.chains.resize(r.nch);
    for (int c=0;c<r.nch;++c){
        Chain& ch=r.chains[c];
        if (fscanf(fd,"%d %lld %lld %d %d",&ch.rid,(long long*)&ch.rmax0,(long long*)&ch.rmax1,&ch.nseeds,&ch.reflen)!=5) return false;
        ch.seeds.resize(ch.nseeds);
        for (int s=0;s<ch.nseeds;++s){ Seed& sd=ch.seeds[s];
            if (fscanf(fd,"%lld %d %d %d",(long long*)&sd.rbeg,&sd.qbeg,&sd.len,&sd.score)!=4) return false; }
        ch.ref.resize(ch.reflen);
        for (int i=0;i<ch.reflen;++i) if (fscanf(fd,"%d",&ch.ref[i])!=1) return false;
    }
    if (fscanf(fd,"%d %d",&r.fb,&r.nout)!=2) return false;
    r.out.resize(r.nout);
    for (int i=0;i<r.nout;++i){ OutRec& o=r.out[i];
        if (fscanf(fd,"%lld %lld %d %d %d %d",(long long*)&o.rb,(long long*)&o.re,&o.qb,&o.qe,&o.rid,&o.score)!=6) return false; }
    return true;
}

static void emit_read(std::string& buf, const ARead& r) {
    char line[256];
    snprintf(line,sizeof line,"%d %d %d %d %d %d %d %d %d %d %d %d\n",
        r.l_query,r.a,r.o_del,r.e_del,r.o_ins,r.e_ins,r.zdrop,r.w,r.pen5,r.pen3,r.nch,r.nav); buf+=line;
    for (int i=0;i<r.l_query;++i){ snprintf(line,sizeof line,"%d ",r.query[i]); buf+=line; } buf+='\n';
    for (auto& ch : r.chains){
        snprintf(line,sizeof line,"%d %lld %lld %d %d\n",ch.rid,(long long)ch.rmax0,(long long)ch.rmax1,ch.nseeds,ch.reflen); buf+=line;
        for (auto& s : ch.seeds){ snprintf(line,sizeof line,"%lld %d %d %d\n",(long long)s.rbeg,s.qbeg,s.len,s.score); buf+=line; }
        for (int i=0;i<ch.reflen;++i){ snprintf(line,sizeof line,"%d ",ch.ref[i]); buf+=line; } buf+='\n';
    }
    snprintf(line,sizeof line,"%d %d\n",r.fb,r.nout); buf+=line;
    for (auto& o : r.out){ snprintf(line,sizeof line,"%lld %lld %d %d %d %d\n",
        (long long)o.rb,(long long)o.re,o.qb,o.qe,o.rid,o.score); buf+=line; }
}

int main(int argc, char** argv) {
    if (argc < 3) { fprintf(stderr, "usage: %s accel_vectors.txt out.txt [max_cases]\n", argv[0]); return 1; }
    FILE* fd = fopen(argv[1],"r");
    if (!fd) { fprintf(stderr,"cannot open %s\n",argv[1]); return 1; }
    int nreads=0; if (fscanf(fd,"%d",&nreads)!=1) { fprintf(stderr,"bad header\n"); return 1; }
    std::vector<ARead> reads(nreads);
    for (int i=0;i<nreads;++i) if (!parse_read(fd,reads[i])) { fprintf(stderr,"parse fail at read %d\n",i); return 1; }
    fclose(fd);

    int max_cases = argc > 3 ? atoi(argv[3]) : 300;
    std::string buf; buf.reserve(64<<20);
    char line[256];
    long ncases=0, total_sel=0, skipped=0;
    const int64_t l_pac = 3000000000LL;        // > all coords; host-fed identically to the RTL

    for (int p = 0; p + 1 < nreads && ncases < max_cases; p += 2) {
        const ARead& ri = reads[p];
        const ARead& rj = reads[p+1];
        if (ri.fb || rj.fb) { ++skipped; continue; }
        if (ri.nout==0 || ri.nout>BUF || rj.nout>BUF) { ++skipped; continue; }

        MOpt o; o.min_seed_len = 19;
        MPeOpt po; po.pen_unpaired = 10 + (int)(rnd()%16); po.max_matesw = (rnd()%100)<20 ? (1+(int)(rnd()%3)) : 50;
        int l_ms = rj.l_query;
        std::vector<uint8_t> ms(l_ms);
        for (int i=0;i<l_ms;++i) ms[i] = (uint8_t)(rj.query[i] & 0xff);

        MPes pes[4];
        for (int r=0;r<4;++r){ pes[r].failed=(rnd()%100)<25?1:0; pes[r].low=50; pes[r].high=400+rnd()%400; }

        // source = read i's accel output ; entry ma = read !i's accel output
        std::vector<MAln> source(ri.nout);
        for (int c=0;c<ri.nout;++c){ MAln& s=source[c]; s={}; s.rb=ri.out[c].rb; s.re=ri.out[c].re;
            s.qb=ri.out[c].qb; s.qe=ri.out[c].qe; s.rid=ri.out[c].rid; s.is_alt=0; s.score=ri.out[c].score; }
        std::vector<MAln> ma(rj.nout);
        for (int c=0;c<rj.nout;++c){ MAln& m=ma[c]; m={}; m.rb=rj.out[c].rb; m.re=rj.out[c].re;
            m.qb=rj.out[c].qb; m.qe=rj.out[c].qe; m.rid=rj.out[c].rid; m.is_alt=0; m.score=rj.out[c].score; m.seedcov=0; }

        // per-source-candidate host-fed windows (parallel to source; selected prefix consumed)
        int nsrc = (int)source.size();
        std::vector<std::array<MWin,4>> win(nsrc);
        for (int c=0;c<nsrc;++c){
            int64_t a_rb = source[c].rb; int a_rid = source[c].rid;
            for (int r=0;r<4;++r){
                MWin& w = win[c][r]; w.used=0; w.rid=-1; w.rb=0; w.re=0;
                if (pes[r].failed) continue;
                w.used=1;
                w.rid = (rnd()%100)<85 ? a_rid : a_rid+1;
                int pre=rnd()%30, suf=rnd()%30, rlen=pre+l_ms+suf;
                std::vector<uint8_t> ref(rlen);
                for (int i=0;i<rlen;++i) ref[i]=rnd()%4;
                if ((rnd()%100)<60){
                    std::vector<uint8_t> seq(ms.begin(), ms.end());
                    if (is_rev_r(r)){ std::vector<uint8_t> rc(l_ms);
                        for (int i=0;i<l_ms;++i) rc[l_ms-1-i]=ms[i]<4?3-ms[i]:4; seq=rc; }
                    for (int i=0;i<l_ms;++i){ uint8_t bse=seq[i]; if(rnd()%100<8) bse=rnd()%4; ref[pre+i]=bse; }
                }
                w.rb = a_rb + 50 + (rnd()%50);
                w.re = w.rb + rlen;
                w.ref = ref;
            }
        }

        matesw_pe_select(o, po, l_pac, source, l_ms, ms.data(), pes, win, ma);
        { int thr = source[0].score - po.pen_unpaired, k=0;
          for (int j=0;j<nsrc && j<po.max_matesw;++j){ if (source[j].score<thr) break; ++k; }
          total_sel += k; }

        // ---- emit ----
        emit_read(buf, ri);
        emit_read(buf, rj);
        snprintf(line,sizeof line,"%d %lld %d %d %d %d %d %d %d %d\n",
            l_ms,(long long)l_pac,o.min_seed_len,o.a,o.o_del,o.e_del,o.o_ins,o.e_ins,
            po.pen_unpaired,po.max_matesw); buf+=line;
        snprintf(line,sizeof line,"%d %d %d %d\n",pes[0].failed,pes[1].failed,pes[2].failed,pes[3].failed); buf+=line;
        snprintf(line,sizeof line,"%lld %lld %lld %lld\n",(long long)pes[0].low,(long long)pes[1].low,(long long)pes[2].low,(long long)pes[3].low); buf+=line;
        snprintf(line,sizeof line,"%lld %lld %lld %lld\n",(long long)pes[0].high,(long long)pes[1].high,(long long)pes[2].high,(long long)pes[3].high); buf+=line;
        for (int i=0;i<l_ms;++i){ snprintf(line,sizeof line,"%d ",ms[i]); buf+=line; } buf+='\n';
        for (int c=0;c<nsrc;++c){
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
        ++ncases;
    }
    FILE* out = fopen(argv[2], "w");
    fprintf(out, "%ld\n", ncases);
    fwrite(buf.data(), 1, buf.size(), out);
    fclose(out);
    fprintf(stderr, "wrote %ld closed-loop pe2 cases (%ld selected, %ld pairs skipped) to %s\n",
            ncases, total_sel, skipped, argv[2]);
    return 0;
}
