// gen_chaining_pe2pair_vectors.cpp — BOTH-DIRECTIONS golden for tb_chaining_pe_pair_top: the
// full mapper back half (chaining -> extension -> sort -> mate-rescue) for BOTH mates of a pair,
// driven from RAW SEEDS. Like gen_chaining_pe2_vectors but emits a full pair: two directions,
// each its own two chaining->extend runs + rescue, sharing the pair's orientation stats /
// selection params.
//   Dir 0: cand=read0 (source a[0]), ma=read1 (a[1]), mate seq=read1 -> a[1]'
//   Dir 1: cand=read1 (source a[1]), ma=read0 (a[0]), mate seq=read0 -> a[0]'
//
// bwa semantics: BOTH sources are the ORIGINAL a[0]/a[1]. The model uses a fresh copy of the
// entry ma per direction (matesw_pe_select never mutates the source), so dir 1's source is the
// original a[1], not a[1]'. The RTL re-derives each source deterministically by re-running
// chaining+extension (chain_store zeroes its state on each `start`), so the RTL matches.
//
// Chaining->extend outputs are read from chainingext_vectors.txt (already proven == RTL by
// tb_chaining_extend_top); the reference bytes are NOT emitted -- the RTL computes rmax on chip
// and requests each window over ref_req, which the TB serves from the same synthetic genome
// g(pos)=pos&3. Build: -DMR_DEDUP_INT.
//
// Unlike gen_pe2pair_vectors, each direction also emits its rescue `fb` (dedup tie) so the TB
// can check tie==fb at the PAIR level, not just at the single-direction level.
//
// Format (per pair): for dir in {0,1}: chaining_read(cand) block ; chaining_read(ma) block ;
//   l_ms msl a_sc mo_del me_del mo_ins me_ins pen_unpaired max_matesw ;
//   pes_failed[4] pes_low[4] pes_high[4] ; ms[l_ms] ;
//   per cand: win_used[4] win_rb[4] win_re[4] win_rid[4] ; for r: reflen ref[...] ;
//   n_out fb ; n_out*{rb re qb qe rid score cov}      (dir0 -> a[1]', dir1 -> a[0]')
// l_pac is carried in each read block (shared by chaining and the rescue, as in bwa).
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <vector>
#include <array>
#include <string>
#include "macro.h"
#include "pe.h"

uint64_t tprof[LIM_R][LIM_C];
static const int NSRC   = 64;   // RTL candidate-source buffer (see gen_chaining_pe2_vectors.cpp)
static const int MA_MAX = 256;  // RTL ma regfile -- sized in docs/ma_max_sizing_analysis.md

static uint64_t st = 0xb5026f5aa96619e9ull;
static inline uint32_t rnd() { st = st*6364136223846793005ull + 1442695040888963407ull; return (uint32_t)(st>>33); }
static inline bool is_rev_r(int r) { return r==1 || r==2; }

struct OutRec { int64_t rb, re; int qb, qe, rid, score; };
struct RawSeed { int64_t rbeg; int qbeg, len, score, rid, is_alt; };
struct CRead {
    int l_query,a,o_del,e_del,o_ins,e_ins,zdrop,w,pen5,pen3,max_chain_gap,min_seed_len,max_chain_extend;
    int64_t l_pac;
    int n_seeds;
    std::vector<RawSeed> seeds;
    std::vector<int> query;
    int fb_chain, fb_sort, nout;
    std::vector<OutRec> out;
};

static bool parse_read(FILE* fd, CRead& r) {
    if (fscanf(fd,"%d %d %d %d %d %d %d %d %d %d %d %d %d %lld %d",
        &r.l_query,&r.a,&r.o_del,&r.e_del,&r.o_ins,&r.e_ins,&r.zdrop,&r.w,&r.pen5,&r.pen3,
        &r.max_chain_gap,&r.min_seed_len,&r.max_chain_extend,(long long*)&r.l_pac,&r.n_seeds)!=15) return false;
    r.seeds.resize(r.n_seeds);
    for (int k=0;k<r.n_seeds;++k){ RawSeed& s=r.seeds[k];
        if (fscanf(fd,"%lld %d %d %d %d %d",(long long*)&s.rbeg,&s.qbeg,&s.len,&s.score,&s.rid,&s.is_alt)!=6) return false; }
    r.query.resize(r.l_query);
    for (int j=0;j<r.l_query;++j) if (fscanf(fd,"%d",&r.query[j])!=1) return false;
    if (fscanf(fd,"%d %d %d",&r.fb_chain,&r.fb_sort,&r.nout)!=3) return false;
    r.out.resize(r.nout);
    for (int i=0;i<r.nout;++i){ OutRec& o=r.out[i];
        if (fscanf(fd,"%lld %lld %d %d %d %d",(long long*)&o.rb,(long long*)&o.re,&o.qb,&o.qe,&o.rid,&o.score)!=6) return false; }
    return true;
}

static void emit_read(std::string& buf, const CRead& r) {
    char line[256];
    snprintf(line,sizeof line,"%d %d %d %d %d %d %d %d %d %d %d %d %d %lld %d\n",
        r.l_query,r.a,r.o_del,r.e_del,r.o_ins,r.e_ins,r.zdrop,r.w,r.pen5,r.pen3,
        r.max_chain_gap,r.min_seed_len,r.max_chain_extend,(long long)r.l_pac,r.n_seeds); buf+=line;
    for (auto& s : r.seeds){ snprintf(line,sizeof line,"%lld %d %d %d %d %d\n",
        (long long)s.rbeg,s.qbeg,s.len,s.score,s.rid,s.is_alt); buf+=line; }
    for (int j=0;j<r.l_query;++j){ snprintf(line,sizeof line,"%d ",r.query[j]); buf+=line; } buf+='\n';
    snprintf(line,sizeof line,"%d\n",r.nout); buf+=line;
}

static std::vector<MAln> to_maln(const CRead& r) {
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

static void emit_dir(std::string& buf, const CRead& cand, const CRead& ma_read,
                     const std::vector<uint8_t>& ms, const MOpt& o, const MPeOpt& po,
                     const MPes pes[4], const std::vector<std::array<MWin,4>>& win,
                     const std::vector<MAln>& result, bool fb) {
    char line[256];
    emit_read(buf, cand);
    emit_read(buf, ma_read);
    snprintf(line,sizeof line,"%d %d %d %d %d %d %d %d %d\n",
        (int)ms.size(),o.min_seed_len,o.a,o.o_del,o.e_del,o.o_ins,o.e_ins,
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
    snprintf(line,sizeof line,"%d %d\n",(int)result.size(),fb?1:0); buf+=line;
    for (auto&m:result){ snprintf(line,sizeof line,"%lld %lld %d %d %d %d %d\n",
        (long long)m.rb,(long long)m.re,m.qb,m.qe,m.rid,m.score,m.seedcov); buf+=line; }
}

int main(int argc, char** argv) {
    if (argc < 3) { fprintf(stderr, "usage: %s chainingext_vectors.txt out.txt [max_pairs]\n", argv[0]); return 1; }
    FILE* fd = fopen(argv[1],"r"); if (!fd){ fprintf(stderr,"cannot open %s\n",argv[1]); return 1; }
    int nreads=0; if (fscanf(fd,"%d",&nreads)!=1){ fprintf(stderr,"bad header\n"); return 1; }
    std::vector<CRead> reads(nreads);
    for (int i=0;i<nreads;++i) if (!parse_read(fd,reads[i])){ fprintf(stderr,"parse fail at %d\n",i); return 1; }
    fclose(fd);

    int max_pairs = argc > 3 ? atoi(argv[3]) : 100;
    std::string buf; buf.reserve(64<<20);
    long npairs=0, skipped=0;

    for (int p=0; p+1<nreads && npairs<max_pairs; p+=2) {
        const CRead& r0 = reads[p];
        const CRead& r1 = reads[p+1];
        // both reads serve as source in one direction, so both are bounded by NSRC
        if (r0.fb_chain || r0.fb_sort || r1.fb_chain || r1.fb_sort ||
            r0.nout==0 || r1.nout==0 || r0.nout>NSRC || r1.nout>NSRC) { ++skipped; continue; }

        // l_pac is one value in bwa (bns->l_pac); the RTL shares the port between chaining and
        // the rescue, so the golden must use the same one the chaining block was generated with.
        const int64_t l_pac = r0.l_pac;

        MOpt o; o.min_seed_len=r0.min_seed_len;
        MPeOpt po; po.pen_unpaired=10+(int)(rnd()%16); po.max_matesw=(rnd()%100)<20?(1+(int)(rnd()%3)):50;
        MPes pes[4]; for (int r=0;r<4;++r){ pes[r].failed=(rnd()%100)<25?1:0; pes[r].low=50; pes[r].high=400+rnd()%400; }

        std::vector<uint8_t> ms0(r1.l_query), ms1(r0.l_query);   // dir0 mate=read1, dir1 mate=read0
        for (int i=0;i<r1.l_query;++i) ms0[i]=(uint8_t)(r1.query[i]&0xff);
        for (int i=0;i<r0.l_query;++i) ms1[i]=(uint8_t)(r0.query[i]&0xff);

        std::vector<MAln> a0 = to_maln(r0), a1 = to_maln(r1);    // ORIGINAL sources

        // dir 0: source=a0, mate=read1, ma=copy(a1) -> a1'
        std::vector<std::array<MWin,4>> winA; synth_windows(a0, ms0, pes, winA);
        std::vector<MAln> maA = a1; int peakA = 0; bool fbA = false;
        matesw_pe_select(o, po, l_pac, a0, (int)ms0.size(), ms0.data(), pes, winA, maA, &peakA, &fbA);
        // dir 1: source=a1 (ORIGINAL), mate=read0, ma=copy(a0) -> a0'
        std::vector<std::array<MWin,4>> winB; synth_windows(a1, ms1, pes, winB);
        std::vector<MAln> maB = a0; int peakB = 0; bool fbB = false;
        matesw_pe_select(o, po, l_pac, a1, (int)ms1.size(), ms1.data(), pes, winB, maB, &peakB, &fbB);

        // either direction overflowing the on-chip ma buffer (entry count > MA_MAX-4) is a
        // host SW-fallback case the matesw stack can't hold -> exclude (cf. sorter n>1024).
        if (peakA > MA_MAX-4 || peakB > MA_MAX-4) { ++skipped; continue; }

        emit_dir(buf, r0, r1, ms0, o, po, pes, winA, maA, fbA);   // -> a1'
        emit_dir(buf, r1, r0, ms1, o, po, pes, winB, maB, fbB);   // -> a0'
        ++npairs;
    }
    FILE* out = fopen(argv[2], "w");
    fprintf(out, "%ld\n", npairs);
    fwrite(buf.data(), 1, buf.size(), out);
    fclose(out);
    fprintf(stderr, "wrote %ld both-direction chaining pairs (%ld skipped) to %s\n", npairs, skipped, argv[2]);
    return 0;
}
