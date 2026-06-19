// gen_pe2pair_vectors.cpp — BOTH-DIRECTIONS closed-loop golden for tb_accel_pe_pair_top.
// Like gen_pe2_vectors but emits a full pair: two directions, each its own two accel runs
// + rescue, sharing the pair's orientation stats / selection params.
//
//   Dir 0: cand=read0 (source a[0]), ma=read1 (a[1]), mate seq=read1 -> a[1]'
//   Dir 1: cand=read1 (source a[1]), ma=read0 (a[0]), mate seq=read0 -> a[0]'
//
// bwa semantics: BOTH sources are the ORIGINAL a[0]/a[1]. The model uses a fresh copy of
// the entry ma per direction (matesw_pe_select never mutates the source), so dir 1's source
// is the original a[1], not a[1]'. Accel re-derives each source deterministically, so the
// RTL matches. Accel outputs are read from accel_vectors.txt (already proven == RTL by
// tb_accel_pe2_top). Build: -DMR_DEDUP_INT.
//
// Format (per pair): for dir in {0,1}: accel(cand) block ; accel(ma) block ;
//   l_ms l_pac msl a_sc mo_del me_del mo_ins me_ins pen_unpaired max_matesw ;
//   pes_failed[4] pes_low[4] pes_high[4] ; ms[l_ms] ;
//   per cand: win_used[4] win_rb[4] win_re[4] win_rid[4] ; for r: reflen ref[...] ;
//   n_out  n_out*{rb re qb qe rid score cov}      (dir0 -> a[1]', dir1 -> a[0]')
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <vector>
#include <array>
#include <string>
#include "macro.h"
#include "pe.h"

uint64_t tprof[LIM_R][LIM_C];
static const int BUF = 64;
static uint64_t st = 0x243f6a8885a308d3ull;
static inline uint32_t rnd() { st = st*6364136223846793005ull + 1442695040888963407ull; return (uint32_t)(st>>33); }
static inline bool is_rev_r(int r) { return r==1 || r==2; }

struct OutRec { int64_t rb, re; int qb, qe, rid, score; };
struct Seed   { int64_t rbeg; int qbeg, len, score; };
struct Chain  { int rid; int64_t rmax0, rmax1; int nseeds, reflen; std::vector<Seed> seeds; std::vector<int> ref; };
struct ARead {
    int l_query,a,o_del,e_del,o_ins,e_ins,zdrop,w,pen5,pen3,nch,nav;
    std::vector<int> query; std::vector<Chain> chains; int fb, nout; std::vector<OutRec> out;
};

static bool parse_read(FILE* fd, ARead& r) {
    if (fscanf(fd,"%d %d %d %d %d %d %d %d %d %d %d %d",
        &r.l_query,&r.a,&r.o_del,&r.e_del,&r.o_ins,&r.e_ins,&r.zdrop,&r.w,&r.pen5,&r.pen3,&r.nch,&r.nav)!=12) return false;
    r.query.resize(r.l_query);
    for (int i=0;i<r.l_query;++i) if (fscanf(fd,"%d",&r.query[i])!=1) return false;
    r.chains.resize(r.nch);
    for (int c=0;c<r.nch;++c){ Chain& ch=r.chains[c];
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

static std::vector<MAln> to_maln(const ARead& r) {
    std::vector<MAln> v(r.nout);
    for (int c=0;c<r.nout;++c){ MAln& m=v[c]; m={}; m.rb=r.out[c].rb; m.re=r.out[c].re;
        m.qb=r.out[c].qb; m.qe=r.out[c].qe; m.rid=r.out[c].rid; m.is_alt=0; m.score=r.out[c].score; m.seedcov=0; }
    return v;
}

// synth host-fed windows for `source` candidates (rel to rb, planting `ms`)
static void synth_windows(const std::vector<MAln>& source, const std::vector<uint8_t>& ms,
                          const MPes pes[4], std::vector<std::array<MWin,4>>& win) {
    int l_ms=(int)ms.size(); win.assign(source.size(), {});
    for (size_t c=0;c<source.size();++c){
        int64_t a_rb=source[c].rb; int a_rid=source[c].rid;
        for (int r=0;r<4;++r){ MWin& w=win[c][r]; w.used=0; w.rid=-1; w.rb=0; w.re=0;
            if (pes[r].failed) continue;
            w.used=1; w.rid=(rnd()%100)<85 ? a_rid : a_rid+1;
            int pre=rnd()%30, suf=rnd()%30, rlen=pre+l_ms+suf;
            std::vector<uint8_t> ref(rlen); for (int i=0;i<rlen;++i) ref[i]=rnd()%4;
            if ((rnd()%100)<60){ std::vector<uint8_t> seq(ms.begin(),ms.end());
                if (is_rev_r(r)){ std::vector<uint8_t> rc(l_ms);
                    for (int i=0;i<l_ms;++i) rc[l_ms-1-i]=ms[i]<4?3-ms[i]:4; seq=rc; }
                for (int i=0;i<l_ms;++i){ uint8_t bse=seq[i]; if(rnd()%100<8) bse=rnd()%4; ref[pre+i]=bse; } }
            w.rb=a_rb+50+(rnd()%50); w.re=w.rb+rlen; w.ref=ref;
        }
    }
}

static void emit_dir(std::string& buf, const ARead& cand, const ARead& ma_read,
                     const std::vector<uint8_t>& ms, const MOpt& o, const MPeOpt& po, int64_t l_pac,
                     const MPes pes[4], const std::vector<std::array<MWin,4>>& win,
                     const std::vector<MAln>& result) {
    char line[256];
    emit_read(buf, cand);
    emit_read(buf, ma_read);
    snprintf(line,sizeof line,"%d %lld %d %d %d %d %d %d %d %d\n",
        (int)ms.size(),(long long)l_pac,o.min_seed_len,o.a,o.o_del,o.e_del,o.o_ins,o.e_ins,
        po.pen_unpaired,po.max_matesw); buf+=line;
    snprintf(line,sizeof line,"%d %d %d %d\n",pes[0].failed,pes[1].failed,pes[2].failed,pes[3].failed); buf+=line;
    snprintf(line,sizeof line,"%lld %lld %lld %lld\n",(long long)pes[0].low,(long long)pes[1].low,(long long)pes[2].low,(long long)pes[3].low); buf+=line;
    snprintf(line,sizeof line,"%lld %lld %lld %lld\n",(long long)pes[0].high,(long long)pes[1].high,(long long)pes[2].high,(long long)pes[3].high); buf+=line;
    for (size_t i=0;i<ms.size();++i){ snprintf(line,sizeof line,"%d ",ms[i]); buf+=line; } buf+='\n';
    for (size_t c=0;c<win.size();++c){
        snprintf(line,sizeof line,"%d %d %d %d\n",win[c][0].used,win[c][1].used,win[c][2].used,win[c][3].used); buf+=line;
        snprintf(line,sizeof line,"%lld %lld %lld %lld\n",(long long)win[c][0].rb,(long long)win[c][1].rb,(long long)win[c][2].rb,(long long)win[c][3].rb); buf+=line;
        snprintf(line,sizeof line,"%lld %lld %lld %lld\n",(long long)win[c][0].re,(long long)win[c][1].re,(long long)win[c][2].re,(long long)win[c][3].re); buf+=line;
        snprintf(line,sizeof line,"%d %d %d %d\n",win[c][0].rid,win[c][1].rid,win[c][2].rid,win[c][3].rid); buf+=line;
        for (int r=0;r<4;++r){ int rl=win[c][r].used?(int)win[c][r].ref.size():0;
            snprintf(line,sizeof line,"%d ",rl); buf+=line;
            for (int i=0;i<rl;++i){ snprintf(line,sizeof line,"%d ",win[c][r].ref[i]); buf+=line; } buf+='\n'; }
    }
    snprintf(line,sizeof line,"%d\n",(int)result.size()); buf+=line;
    for (auto&m:result){ snprintf(line,sizeof line,"%lld %lld %d %d %d %d %d\n",
        (long long)m.rb,(long long)m.re,m.qb,m.qe,m.rid,m.score,m.seedcov); buf+=line; }
}

int main(int argc, char** argv) {
    if (argc < 3) { fprintf(stderr, "usage: %s accel_vectors.txt out.txt [max_pairs]\n", argv[0]); return 1; }
    FILE* fd = fopen(argv[1],"r"); if (!fd){ fprintf(stderr,"cannot open %s\n",argv[1]); return 1; }
    int nreads=0; if (fscanf(fd,"%d",&nreads)!=1){ fprintf(stderr,"bad header\n"); return 1; }
    std::vector<ARead> reads(nreads);
    for (int i=0;i<nreads;++i) if (!parse_read(fd,reads[i])){ fprintf(stderr,"parse fail at %d\n",i); return 1; }
    fclose(fd);

    int max_pairs = argc > 3 ? atoi(argv[3]) : 300;
    std::string buf; buf.reserve(64<<20);
    long npairs=0, skipped=0; const int64_t l_pac=3000000000LL;

    for (int p=0; p+1<nreads && npairs<max_pairs; p+=2) {
        const ARead& r0 = reads[p];
        const ARead& r1 = reads[p+1];
        if (r0.fb || r1.fb || r0.nout==0 || r1.nout==0 || r0.nout>BUF || r1.nout>BUF) { ++skipped; continue; }

        MOpt o; o.min_seed_len=19;
        MPeOpt po; po.pen_unpaired=10+(int)(rnd()%16); po.max_matesw=(rnd()%100)<20?(1+(int)(rnd()%3)):50;
        MPes pes[4]; for (int r=0;r<4;++r){ pes[r].failed=(rnd()%100)<25?1:0; pes[r].low=50; pes[r].high=400+rnd()%400; }

        std::vector<uint8_t> ms0(r1.l_query), ms1(r0.l_query);   // dir0 mate=read1, dir1 mate=read0
        for (int i=0;i<r1.l_query;++i) ms0[i]=(uint8_t)(r1.query[i]&0xff);
        for (int i=0;i<r0.l_query;++i) ms1[i]=(uint8_t)(r0.query[i]&0xff);

        std::vector<MAln> a0 = to_maln(r0), a1 = to_maln(r1);    // ORIGINAL sources

        // dir 0: source=a0, mate=read1, ma=copy(a1) -> a1'
        std::vector<std::array<MWin,4>> winA; synth_windows(a0, ms0, pes, winA);
        std::vector<MAln> maA = a1; int peakA = 0;
        matesw_pe_select(o, po, l_pac, a0, (int)ms0.size(), ms0.data(), pes, winA, maA, &peakA);
        // dir 1: source=a1 (ORIGINAL), mate=read0, ma=copy(a0) -> a0'
        std::vector<std::array<MWin,4>> winB; synth_windows(a1, ms1, pes, winB);
        std::vector<MAln> maB = a0; int peakB = 0;
        matesw_pe_select(o, po, l_pac, a1, (int)ms1.size(), ms1.data(), pes, winB, maB, &peakB);

        // either direction overflowing the on-chip ma buffer (entry count > MA_MAX-4) is a
        // host SW-fallback case the matesw stack can't hold -> exclude (cf. sorter n>1024).
        if (peakA > BUF-4 || peakB > BUF-4) { ++skipped; continue; }

        emit_dir(buf, r0, r1, ms0, o, po, l_pac, pes, winA, maA);   // -> a1'
        emit_dir(buf, r1, r0, ms1, o, po, l_pac, pes, winB, maB);   // -> a0'
        ++npairs;
    }
    FILE* out = fopen(argv[2], "w");
    fprintf(out, "%ld\n", npairs);
    fwrite(buf.data(), 1, buf.size(), out);
    fclose(out);
    fprintf(stderr, "wrote %ld both-direction pairs (%ld skipped) to %s\n", npairs, skipped, argv[2]);
    return 0;
}
