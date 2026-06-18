// hw.h — scalar full-rectangle model of mate-rescue's ksw_align2, written to be
// reproduced by the FPGA engine (systolic array in "restart" local-SW mode + a
// two-pass orchestrator). Cross-checked bit-exact against the upstream ksw_align2
// (ksw_ref.cpp) by cross_check.cpp.
//
// Faithful to ksw_u8/ksw_i16 + ksw_align2 (ksw.cpp):
//   * standard local SW with fresh restart: H = max(0, H(i-1,j-1)+s, E, F);
//     gap-opens taken from H (not the diagonal M), all values 0-floored.
//   * forward pass: score = global max; te = FIRST target row whose column-max is
//     strictly greater; qe = argmax query position in the saved column at te, ties
//     -> smallest query index (matches ksw's de-striped min-index tie-break).
//   * KSW_XSTART: reverse query[0..qe] and target[0..te], run the same pass with
//     an XSTOP threshold = score (stop at the first row reaching it); then
//     tb = te - rr.te, qb = qe - rr.qe (only if scores match).
//   * KSW_XSUBO early-return: if score < (xtra & 0xffff), skip the start pass
//     (qb = tb = -1) — exactly as mem_matesw relies on.
//   * score2/te2 (2nd-best) are computed by ksw but NOT consumed by mem_matesw, so
//     they are intentionally omitted here.
//   * 8-bit (XBYTE) saturation at 255 is not modeled: for short-read mate-rescue
//     l_ms*a < 250 guarantees scores stay < 255 (the XBYTE guard); larger ranges
//     use the 16-bit kernel.
#pragma once
#include <cstdint>
#include <vector>
#include <algorithm>
#include "ksw_ref.h"   // KSW_XSTART / KSW_XSUBO / KSW_XBYTE / kswr_t

struct HR { int score, te, qe, tb, qb; };

// One local-SW pass over qlen x tlen. Returns the global max; fills te/qe and the
// H column at te. Stops early once the running max reaches `endsc` (>=), at the row
// that reached it (models KSW_XSTOP). Pass endsc huge to disable.
static inline int hw_local_sw(int qlen, const uint8_t* q, int tlen, const uint8_t* t,
                              const int8_t* mat, int o_del, int e_del, int o_ins, int e_ins,
                              int endsc, int* te_o, int* qe_o) {
    const int oe_del = o_del + e_del, oe_ins = o_ins + e_ins;
    std::vector<int> ehh(qlen, 0), ehe(qlen, 0);   // ehh[j]=H(i-1,j-1) rolling, ehe[j]=E
    std::vector<int> col(qlen, 0), best(qlen, 0);
    int gmax = 0, te = -1;
    for (int i = 0; i < tlen; ++i) {
        int f = 0, h1 = 0, colmax = 0;
        const int8_t* srow = &mat[t[i] * 5];
        for (int j = 0; j < qlen; ++j) {
            int M = ehh[j];          // H(i-1,j-1)
            ehh[j] = h1;             // H(i,j-1) for the next row's diagonal
            int e = ehe[j];
            M = M + srow[q[j]];
            int h = M; if (e > h) h = e; if (f > h) h = f; if (h < 0) h = 0;  // H(i,j)
            h1 = h; col[j] = h;
            if (h > colmax) colmax = h;
            int ne = e - e_del, nh = h - oe_del; ne = ne > nh ? ne : nh; ehe[j] = ne > 0 ? ne : 0;
            int nf = f - e_ins, nH = h - oe_ins; nf = nf > nH ? nf : nH; f = nf > 0 ? nf : 0;
        }
        if (colmax > gmax) {
            gmax = colmax; te = i; best = col;
            if (gmax >= endsc) break;   // KSW_XSTOP
        }
    }
    // qe = argmax in the column at te, smallest query index on ties
    int mx = -1, qe = -1;
    for (int j = 0; j < qlen; ++j) if (best[j] > mx) { mx = best[j]; qe = j; }
    *te_o = te; *qe_o = qe;
    return gmax;
}

static inline HR hw_align2(int qlen, const uint8_t* q, int tlen, const uint8_t* t,
                           const int8_t* mat, int o_del, int e_del, int o_ins, int e_ins,
                           int xtra) {
    const int BIG = 0x10000;
    int te, qe;
    int score = hw_local_sw(qlen, q, tlen, t, mat, o_del, e_del, o_ins, e_ins, BIG, &te, &qe);
    HR r{score, te, qe, -1, -1};
    const bool xstart = (xtra & KSW_XSTART) != 0;
    const bool xsubo  = (xtra & KSW_XSUBO) != 0;
    const int  subo   = xtra & 0xffff;
    if (!xstart || (xsubo && score < subo)) return r;
    // reverse pass over the prefix [0..qe] x [0..te]
    std::vector<uint8_t> rq(q, q + qe + 1), rt(t, t + te + 1);
    std::reverse(rq.begin(), rq.end());
    std::reverse(rt.begin(), rt.end());
    int rte, rqe;
    int rscore = hw_local_sw(qe + 1, rq.data(), te + 1, rt.data(), mat,
                             o_del, e_del, o_ins, e_ins, /*endsc=*/score, &rte, &rqe);
    if (score == rscore) { r.tb = te - rte; r.qb = qe - rqe; }
    return r;
}
