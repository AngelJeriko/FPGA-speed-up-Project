// gen_chaining_pe2_vectors.cpp — golden for tb_chaining_pe2_top: THE JOIN driven end-to-end
// from RAW SEEDS (chaining -> extension -> sort -> mate-rescue) with the FINAL rescued ma checked
// bit-exact.
//
// Key idea (same TU-isolation trick as gen_pe2_vectors, one stage further back): the
// chaining->extend->sort outputs are already in chainingext_vectors.txt (produced by
// gen_chaining_extend_vectors), and tb_chaining_extend_top already proved the RTL reproduces
// those records from raw seeds. So this generator PARSES chainingext_vectors.txt — taking read
// i's output as the candidate SOURCE and read !i's output as the entry ma — then runs ONLY
// pe.h::matesw_pe_select for the rescue. It re-emits both reads' RAW-SEED input blocks (so the
// RTL regenerates the identical source/ma on-chip, chaining included), plus the rescue params +
// ms + synthesized windows + final ma. This keeps the chaining and mate-rescue header
// subsystems in separate translation units.
//
// The reference bytes are NOT emitted per chain: the RTL computes rmax on chip and requests each
// window over ref_req, which the TB serves from the SAME synthetic genome g(pos)=pos&3 the
// chaining-extend golden used.
//
// Build: -DMR_DEDUP_INT (pe.h mr_dedup uses the integer redundancy surrogate == matesw_dedup).
// Only pairs where BOTH reads are non-fallback (either stage), non-empty, and within the
// buffers are emitted. The mate sequence ms = read !i's query (parsed from its input block).
//
// Format (per case): two chaining-extend input blocks (read i, read !i), then:
//   l_ms msl a_sc mo_del me_del mo_ins me_ins pen_unpaired max_matesw
//   pes_failed[4] pes_low[4] pes_high[4] ; ms[l_ms]
//   per source candidate (nsrc = read-i nout): win_used[4] win_rb[4] win_re[4] win_rid[4] ; for r: reflen ref[...]
//   n_ma_final fb ; n_ma_final*{rb re qb qe rid score cov}
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
static const int NSRC   = 64;   // RTL candidate-source buffer. Safe for any n_src:
                                // only the first max_matesw (<=50) entries are ever read,
                                // and the sorter output is already score-sorted desc.
static const int MA_MAX = 256;  // RTL ma regfile -- sized in docs/ma_max_sizing_analysis.md

static uint64_t st = 0x51a3f00dc0ffee11ull;
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

// parse one read block (gen_chaining_extend layout) from fd
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

int main(int argc, char** argv) {
    if (argc < 3) { fprintf(stderr, "usage: %s chainingext_vectors.txt out.txt [max_cases]\n", argv[0]); return 1; }
    FILE* fd = fopen(argv[1],"r");
    if (!fd) { fprintf(stderr,"cannot open %s\n",argv[1]); return 1; }
    int nreads=0; if (fscanf(fd,"%d",&nreads)!=1) { fprintf(stderr,"bad header\n"); return 1; }
    std::vector<CRead> reads(nreads);
    for (int i=0;i<nreads;++i) if (!parse_read(fd,reads[i])) { fprintf(stderr,"parse fail at read %d\n",i); return 1; }
    fclose(fd);

    int max_cases = argc > 3 ? atoi(argv[3]) : 200;
    std::string buf; buf.reserve(64<<20);
    char line[256];
    long ncases=0, total_sel=0, skipped=0;

    for (int p = 0; p + 1 < nreads && ncases < max_cases; p += 2) {
        const CRead& ri = reads[p];
        const CRead& rj = reads[p+1];
        if (ri.fb_chain || ri.fb_sort || rj.fb_chain || rj.fb_sort) { ++skipped; continue; }
        // ri = candidate source (NSRC), rj = entry ma (MA_MAX, with orch_top's 4-insert headroom)
        if (ri.nout==0 || ri.nout>NSRC || rj.nout>MA_MAX-4) { ++skipped; continue; }

        // l_pac is one value in bwa (bns->l_pac); the RTL shares the port between chaining and
        // the rescue, so the golden must use the same one the chaining block was generated with.
        const int64_t l_pac = ri.l_pac;

        MOpt o; o.min_seed_len = ri.min_seed_len;
        MPeOpt po; po.pen_unpaired = 10 + (int)(rnd()%16); po.max_matesw = (rnd()%100)<20 ? (1+(int)(rnd()%3)) : 50;
        int l_ms = rj.l_query;
        std::vector<uint8_t> ms(l_ms);
        for (int i=0;i<l_ms;++i) ms[i] = (uint8_t)(rj.query[i] & 0xff);

        MPes pes[4];
        for (int r=0;r<4;++r){ pes[r].failed=(rnd()%100)<25?1:0; pes[r].low=50; pes[r].high=400+rnd()%400; }

        // source = read i's chaining->extend output ; entry ma = read !i's
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

        bool fb = false;
        matesw_pe_select(o, po, l_pac, source, l_ms, ms.data(), pes, win, ma, nullptr, &fb);
        { int thr = source[0].score - po.pen_unpaired, k=0;
          for (int j=0;j<nsrc && j<po.max_matesw;++j){ if (source[j].score<thr) break; ++k; }
          total_sel += k; }

        // ---- emit ----
        emit_read(buf, ri);
        emit_read(buf, rj);
        snprintf(line,sizeof line,"%d %d %d %d %d %d %d %d %d\n",
            l_ms,o.min_seed_len,o.a,o.o_del,o.e_del,o.o_ins,o.e_ins,
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
        snprintf(line,sizeof line,"%d %d\n",(int)ma.size(),fb?1:0); buf+=line;
        for (auto&m:ma){ snprintf(line,sizeof line,"%lld %lld %d %d %d %d %d\n",
            (long long)m.rb,(long long)m.re,m.qb,m.qe,m.rid,m.score,m.seedcov); buf+=line; }
        ++ncases;
    }
    FILE* out = fopen(argv[2], "w");
    fprintf(out, "%ld\n", ncases);
    fwrite(buf.data(), 1, buf.size(), out);
    fclose(out);
    fprintf(stderr, "wrote %ld chaining-pe2 cases (%ld selected, %ld pairs skipped) to %s\n",
            ncases, total_sel, skipped, argv[2]);
    return 0;
}
