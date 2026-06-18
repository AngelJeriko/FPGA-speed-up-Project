// check_capture.cpp — validate the mate-rescue HW model (hw_align2, hw.h) against
// REAL captured kswv/getScores outputs from bwa-mem2 (matesw_capture.inc, env
// ALNREG_MATE_OUT). Confirms kswv512 == ksw_align2 == hw_align2 on real data —
// the remote-capture leg of the mate-rescue verification (docs/mate_rescue_engine_scope.md).
//
// Record format (see host/mate_rescue/capture/matesw_capture.inc):
//   type 0 INPUT : i32 type=0; i64 aln_id; i32 qlen; i32 tlen; i32 xtra;
//                  i32 a; i32 b; i32 o_del; i32 e_del; i32 o_ins; i32 e_ins;
//                  u8 query[qlen]; u8 ref[tlen]
//   type 1 OUTPUT: i32 type=1; i64 aln_id; i32 score; i32 qb; i32 qe; i32 tb; i32 te
//
// Build:  make checkcap     Run:  ./check_capture vectors/mate_vec.bin
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <vector>
#include <unordered_map>
#include "macro.h"
#include "ksw_ref.h"
#include "hw.h"

uint64_t tprof[LIM_R][LIM_C];

static void fill_scmat(int a, int b, int8_t mat[25]) {
    int i, j, k;
    for (i = k = 0; i < 4; ++i) { for (j = 0; j < 4; ++j) mat[k++] = i==j? a : -b; mat[k++] = -1; }
    for (j = 0; j < 5; ++j) mat[k++] = -1;
}

struct Inp { int qlen, tlen, xtra, a, b, o_del, e_del, o_ins, e_ins;
             std::vector<uint8_t> q, t; };
struct Out { int score, qb, qe, tb, te; };

template<class T> static bool rd(FILE*f, T&v){ return fread(&v,sizeof(T),1,f)==1; }

int main(int argc, char** argv) {
    if (argc < 2) { fprintf(stderr, "usage: %s capture.bin\n", argv[0]); return 2; }
    FILE* f = fopen(argv[1], "rb");
    if (!f) { fprintf(stderr, "cannot open %s\n", argv[1]); return 2; }

    std::unordered_map<long long, Inp> inputs;
    std::unordered_map<long long, Out> outputs;
    int32_t type;
    long n_in = 0, n_out = 0;
    while (rd(f, type)) {
        int64_t aid;
        if (type == 0) {
            Inp in; int32_t qlen,tlen,xtra,a,b,od,ed,oi,ei;
            if(!rd(f,aid)||!rd(f,qlen)||!rd(f,tlen)||!rd(f,xtra)||!rd(f,a)||!rd(f,b)
               ||!rd(f,od)||!rd(f,ed)||!rd(f,oi)||!rd(f,ei)){ fprintf(stderr,"trunc INPUT\n"); break; }
            in.qlen=qlen; in.tlen=tlen; in.xtra=xtra; in.a=a; in.b=b;
            in.o_del=od; in.e_del=ed; in.o_ins=oi; in.e_ins=ei;
            in.q.resize(qlen); in.t.resize(tlen);
            if(fread(in.q.data(),1,qlen,f)!=(size_t)qlen){ fprintf(stderr,"trunc q\n"); break; }
            if(fread(in.t.data(),1,tlen,f)!=(size_t)tlen){ fprintf(stderr,"trunc t\n"); break; }
            inputs[aid] = std::move(in); n_in++;
        } else if (type == 1) {
            Out o; int32_t sc,qb,qe,tb,te;
            if(!rd(f,aid)||!rd(f,sc)||!rd(f,qb)||!rd(f,qe)||!rd(f,tb)||!rd(f,te)){ fprintf(stderr,"trunc OUTPUT\n"); break; }
            o.score=sc;o.qb=qb;o.qe=qe;o.tb=tb;o.te=te;
            outputs[aid]=o; n_out++;
        } else { fprintf(stderr, "bad type %d @offset\n", type); break; }
    }
    fclose(f);
    printf("parsed: %ld inputs, %ld outputs\n", n_in, n_out);

    long checked=0, with_start=0, fails=0, missing=0;
    for (auto& kv : outputs) {
        auto it = inputs.find(kv.first);
        if (it == inputs.end()) { missing++; continue; }
        Inp& in = it->second; Out& ref = kv.second;
        int8_t mat[25]; fill_scmat(in.a, in.b, mat);
        HR hw = hw_align2(in.qlen, in.q.data(), in.tlen, in.t.data(), mat,
                          in.o_del, in.e_del, in.o_ins, in.e_ins, in.xtra);
        checked++;
        if (ref.qb >= 0) with_start++;
        // mem_matesw consumes score, qb, qe, tb, te. (score2/te2 not captured.)
        bool bad = (hw.score!=ref.score)||(hw.qb!=ref.qb)||(hw.qe!=ref.qe)
                 ||(hw.tb!=ref.tb)||(hw.te!=ref.te);
        if (bad) {
            fails++;
            if (fails <= 20)
                printf("MISMATCH aid=%lld qlen=%d tlen=%d xtra=0x%x | "
                       "score %d/%d qb %d/%d qe %d/%d tb %d/%d te %d/%d\n",
                       (long long)kv.first, in.qlen, in.tlen, in.xtra,
                       hw.score,ref.score, hw.qb,ref.qb, hw.qe,ref.qe,
                       hw.tb,ref.tb, hw.te,ref.te);
        }
    }
    if (missing) printf("WARNING: %ld outputs had no matching input record\n", missing);
    printf("check_capture: %ld checked, %ld with start-pass, %ld failures -> %s\n",
           checked, with_start, fails, (fails==0 && checked>0) ? "ALL PASS" : "FAIL");
    return (fails==0 && checked>0) ? 0 : 1;
}
