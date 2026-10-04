// gen_rtl_vectors_from_cap.cpp -- turn a BSWCAP01 capture into the text vector
// format that tb/tb_bsw_ext.sv feeds into the real SystemVerilog bsw_top.
//
// WHY: the RTL golden set (host/extend_orchestrator/vectors/ext_sw_vectors.txt)
// is 15,887 extensions from the OLDER ext_capture hook. The E. coli and human
// captures come through the newer swa_capture.inc at the SeqPair level and are a
// different, far larger dataset -- and the human stress set reaches tlen=997,
// which exercises bsw_top right up against MAX_TLEN=1024. The existing vectors
// top out well below that.
//
// Output format (from gen_ext_vectors.cpp):
//   <count>
//   per extension:
//     side qlen tlen h0 end_bonus o_del e_del o_ins e_ins zdrop
//        exp_score exp_qle exp_tle exp_gscore exp_gtle exp_maxoff
//     q[0..qlen-1]
//     t[0..tlen-1]
//
// ELIGIBILITY -- a record is only usable if the RTL is expected to match it:
//   * qlen <= MAX_QLEN and tlen <= MAX_TLEN, or bsw_top rejects it by design
//   * w == 100. bsw_top computes the FULL unbanded DP; it agrees with bwa-mem2's
//     banded kernel only while 2*w+1 >= qlen. At the default w=100 with
//     qlen<=160 the band covers the whole query so banding is a no-op. A
//     narrow-band capture (e.g. -w 12) would diverge for reasons that are not
//     RTL bugs, so those records are excluded rather than reported as failures.
//
// Expected outputs are bwa-mem2's own, straight from the capture. Note that
// tb_bsw_ext gates gtle on gscore>0 and treats max_off as informational; both
// are characterised array-vs-ksw differences documented in that testbench.
//
//   g++ -O2 -std=c++17 -o gen_rtl_vectors_from_cap gen_rtl_vectors_from_cap.cpp
//   ./gen_rtl_vectors_from_cap cap.bin out.txt [--count N] [--min-tlen T]
#include "ksw.h"   // bwa_fill_scmat
#include "hw.h"    // hw_extend2: the full-DP array model bsw_top implements
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <vector>
#include <string>
#include <algorithm>

namespace {

struct Hdr { int32_t m; int8_t mat[25];
             int32_t a,b,o_del,e_del,o_ins,e_ins,zdrop,pen_clip5,pen_clip3,w_base; };

struct Rec {
    uint8_t side, route; int16_t band_try;
    int32_t w,qlen,tlen,h0,score,qle,tle,gtle,gscore,max_off;
};

struct Cand { long long off; int32_t tlen; };

bool read_hdr(FILE *f, Hdr &h) {
    char magic[8];
    if (fread(magic,1,8,f)!=8 || memcmp(magic,"BSWCAP01",8)) return false;
    // a..w_base are 10 contiguous int32 fields; one read covers all of them.
    return fread(&h.m,4,1,f)==1 && fread(h.mat,1,25,f)==25 &&
           fread(&h.a,4,10,f)==10;
}

// returns 1 record, 0 clean EOF, -1 truncated
int read_rec(FILE *f, Rec &r) {
    if (fread(&r.side,1,1,f)!=1) return feof(f)?0:-1;
    if (fread(&r.route,1,1,f)!=1 || fread(&r.band_try,2,1,f)!=1) return -1;
    if (fread(&r.w,4,10,f)!=10) return -1;
    if (r.qlen<0||r.tlen<0||r.qlen>(1<<20)||r.tlen>(1<<20)) return -1;
    return 1;
}

} // namespace

int main(int argc, char **argv) {
    if (argc < 3) {
        fprintf(stderr,"usage: %s <capture.bin> <out.txt> [--count N] [--min-tlen T]"
                       " [--max-qlen Q] [--max-tlen T]\n", argv[0]);
        return 2;
    }
    const char *in = argv[1], *out = argv[2];
    int count = 12000, min_tlen = 900, max_qlen = 160, max_tlen = 1024;
    for (int i=3;i<argc;i++) {
        if (!strcmp(argv[i],"--count")    && i+1<argc) count    = atoi(argv[++i]);
        else if (!strcmp(argv[i],"--min-tlen") && i+1<argc) min_tlen = atoi(argv[++i]);
        else if (!strcmp(argv[i],"--max-qlen") && i+1<argc) max_qlen = atoi(argv[++i]);
        else if (!strcmp(argv[i],"--max-tlen") && i+1<argc) max_tlen = atoi(argv[++i]);
    }

    // ---- pass 1: index the eligible records (headers only, payloads skipped) --
    FILE *f = fopen(in,"rb");
    if (!f) { fprintf(stderr,"cannot open %s\n",in); return 2; }
    Hdr h;
    if (!read_hdr(f,h)) { fprintf(stderr,"%s: bad header\n",in); return 2; }

    std::vector<Cand> cand;
    long long total=0, skip_env=0, skip_w=0;
    for (;;) {
        const long long off = ftell(f);
        Rec r; const int rc = read_rec(f,r);
        if (rc == 0) break;
        if (rc < 0) { fprintf(stderr,"truncated after %lld records\n",total); return 2; }
        total++;
        if (fseek(f,(long)(r.qlen+r.tlen),SEEK_CUR)) break;
        if (r.qlen > max_qlen || r.tlen > max_tlen) { skip_env++; continue; }
        if (r.w != 100)                              { skip_w++;   continue; }
        cand.push_back({off, r.tlen});
    }

    // ---- choose: every near-limit record, then an even spread over the rest ---
    std::vector<long long> pick;
    std::vector<Cand> rest;
    for (const Cand &c : cand) {
        if (c.tlen >= min_tlen) pick.push_back(c.off);
        else rest.push_back(c);
    }
    const long long n_near = (long long)pick.size();
    if ((int)pick.size() < count && !rest.empty()) {
        const int want = count - (int)pick.size();
        const int k = want < (int)rest.size() ? want : (int)rest.size();
        for (int s=0;s<k;s++)
            pick.push_back(rest[(size_t)((double)s*(rest.size()-1)/(k>1?k-1:1))].off);
    }
    std::sort(pick.begin(), pick.end());
    pick.erase(std::unique(pick.begin(),pick.end()), pick.end());

    // ---- pass 2: emit -------------------------------------------------------
    // Buffer the records so the header count always matches what was actually
    // emitted: a record dropped by the model check below must not be counted.
    std::string body;
    long long emitted = 0;
    char line[256];
    std::vector<uint8_t> q, t;
    int32_t emax_tlen=0, emax_qlen=0;
    long long clamped=0, gs_diff=0, model_skew=0;
    for (long long off : pick) {
        fseek(f,(long)off,SEEK_SET);
        Rec r;
        if (read_rec(f,r)!=1) { fprintf(stderr,"re-read failed at %lld\n",off); return 2; }
        q.resize(r.qlen); t.resize(r.tlen);
        if (fread(q.data(),1,r.qlen,f)!=(size_t)r.qlen ||
            fread(t.data(),1,r.tlen,f)!=(size_t)r.tlen) {
            fprintf(stderr,"payload re-read failed at %lld\n",off); return 2;
        }
        const int eb = (r.side=='L') ? h.pen_clip5 : h.pen_clip3;
        // EXPECTED VALUES -- which model each output comes from, and why.
        //
        // score/qle/tle come from the capture, i.e. from bwa-mem2 itself. That
        // is the real cross-check this vector set exists for.
        //
        // gscore/gtle CANNOT come from bwa-mem2. bsw_top computes the FULL
        // unbanded DP and therefore updates gscore/gtle on every row, whereas
        // ksw stops once its band narrows below the query end. Both are correct
        // for their own algorithm. Measured on one real record (qlen=2,
        // tlen=52, h0=52): ksw gives gtle=2 gscore=44, the full-DP array gives
        // gtle=5 gscore=45, and the RTL reports 5/45 -- i.e. the RTL is right by
        // its own specification. So gscore/gtle are recomputed here with
        // hw_extend2, the array model, exactly as gen_ext_vectors.cpp does
        // ("expected outputs come from the full-rectangle ARRAY model, not
        // ksw"). Feeding ksw's raw values instead produced 865 mismatches in
        // 12,000 vectors: 864 of them the gscore -1 vs 0 sentinel (harmless --
        // both orch.h:149/168 and bwa-mem2 branch on gscore <= 0) and 1 a
        // genuine banded-vs-full difference of the kind above.
        int8_t mat[25];
        bwa_fill_scmat(h.a, h.b, mat);
        int hq, ht, hgt, hgs, hmo;
        const int hsc = hw_extend2(r.qlen, q.data(), r.tlen, t.data(), h.m, mat,
                                   h.o_del, h.e_del, h.o_ins, h.e_ins,
                                   100, eb, h.zdrop, r.h0,
                                   &hq, &ht, &hgt, &hgs, &hmo);
        // The array model must still agree with bwa-mem2 on the three outputs
        // the two algorithms share, or the record is not a valid RTL vector.
        if (hsc != r.score || hq != r.qle || ht != r.tle) { model_skew++; continue; }
        const int exp_gscore = hgs < 0 ? 0 : hgs;
        const int exp_gtle   = hgt;
        if (exp_gscore != (r.gscore < 0 ? 0 : r.gscore) || exp_gtle != r.gtle) gs_diff++;
        snprintf(line,sizeof line,"%d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d\n",
                (r.side=='L')?0:1, r.qlen, r.tlen, r.h0, eb,
                h.o_del, h.e_del, h.o_ins, h.e_ins, h.zdrop,
                r.score, r.qle, r.tle, exp_gscore, exp_gtle, hmo);
        body += line;
        for (int i=0;i<r.qlen;i++) { snprintf(line,sizeof line,"%u%c", q[i], i+1==r.qlen?'\n':' '); body += line; }
        for (int i=0;i<r.tlen;i++) { snprintf(line,sizeof line,"%u%c", t[i], i+1==r.tlen?'\n':' '); body += line; }
        emitted++;
        if (r.gscore < 0) clamped++;
        if (r.tlen>emax_tlen) emax_tlen=r.tlen;
        if (r.qlen>emax_qlen) emax_qlen=r.qlen;
    }
    FILE *o = fopen(out,"w");
    if (!o) { fprintf(stderr,"cannot write %s\n",out); return 2; }
    fprintf(o,"%lld\n", emitted);
    fwrite(body.data(),1,body.size(),o);
    fclose(o); fclose(f);

    printf("scanned   : %lld records\n", total);
    printf("eligible  : %zu  (skipped %lld out-of-envelope, %lld with w!=100)\n",
           cand.size(), skip_env, skip_w);
    printf("emitted   : %lld of %zu selected  (%lld with tlen>=%d, rest evenly sampled)\n",
           emitted, pick.size(), n_near, min_tlen);
    printf("envelope  : max qlen=%d  max tlen=%d\n", emax_qlen, emax_tlen);
    printf("gscore    : %lld raw bwa-mem2 values were -1 (unreachable query end)\n", clamped);
    printf("array vs ksw: %lld of %zu records differ on gscore/gtle "
           "(banded-vs-full, expected)\n", gs_diff, (size_t)emitted);
    if (model_skew)
        printf("WARNING   : %lld records dropped -- array model disagreed with "
               "bwa-mem2 on score/qle/tle\n", model_skew);
    printf("-> %s\n", out);
    return 0;
}
