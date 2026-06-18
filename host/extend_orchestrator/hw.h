// hw.h — faithful C++ model of the full-rectangle systolic array (bsw_top).
// It is ksw_extend2 with the dynamic band REMOVED: every row processes all
// query columns [0,qlen) and there is no [beg,end] narrowing. This is exactly
// what the hardware computes (one PE per query base, full rectangle). Used to
// check whether the array's gscore/gtle (which, unlike ksw, are updated on every
// row that reaches the last query column = every row) still drive a bit-exact
// orchestrator output.
//
// Differences from ksw_extend2, all intentional:
//   * beg=0, end=qlen every row (no band, no narrowing)
//   * gscore therefore updates on every row (j always reaches qlen)
//   * the mm==0 break is kept (matches the FSM dead_row early-exit; harmless to
//     score/gscore since a fully-zero row cannot revive under the M?:0 rule)
//   * zdrop kept (matches FSM)
#pragma once
#include <cstdint>
#include <cstdlib>
#include "ksw.h"   // eh_t

static inline int hw_extend2(int qlen, const uint8_t *query, int tlen,
        const uint8_t *target, int m, const int8_t *mat, int o_del, int e_del,
        int o_ins, int e_ins, int /*w*/, int /*end_bonus*/, int zdrop, int h0,
        int *_qle, int *_tle, int *_gtle, int *_gscore, int *_max_off) {
    eh_t *eh; int8_t *qp;
    int i, j, k, oe_del = o_del + e_del, oe_ins = o_ins + e_ins,
        max, max_i, max_j, max_ie, gscore, max_off;
    qp = (int8_t *) malloc(qlen * m);
    eh = (eh_t *) calloc(qlen + 1, sizeof(eh_t));
    for (k = i = 0; k < m; ++k) {
        const int8_t *p = &mat[k * m];
        for (j = 0; j < qlen; ++j) qp[i++] = p[query[j]];
    }
    // first-row init ladder (identical to ksw)
    eh[0].h = h0; eh[1].h = h0 > oe_ins ? h0 - oe_ins : 0;
    for (j = 2; j <= qlen; ++j) { eh[j].h = eh[j-1].h > e_ins ? eh[j-1].h - e_ins : 0; }
    max = h0, max_i = max_j = -1; max_ie = -1, gscore = -1; max_off = 0;
    for (i = 0; i < tlen; ++i) {
        int t, f = 0, h1, mm = 0, mj = -1;
        int8_t *q = &qp[target[i] * qlen];
        // NO band: beg=0, end=qlen always; first-column boundary h1 like ksw beg==0
        h1 = h0 - (o_del + e_del * (i + 1)); if (h1 < 0) h1 = 0;
        for (j = 0; j < qlen; ++j) {
            eh_t *p = &eh[j];
            int h, M = p->h, e = p->e;
            p->h = h1;
            M = M ? M + q[j] : 0;
            h = M > e ? M : e; h = h > f ? h : f;
            h1 = h;
            mj = mm > h ? mj : j;
            mm = mm > h ? mm : h;
            t = M - oe_del; t = t > 0 ? t : 0; e -= e_del; e = e > t ? e : t; p->e = e;
            t = M - oe_ins; t = t > 0 ? t : 0; f -= e_ins; f = f > t ? f : t;
        }
        eh[qlen].h = h1; eh[qlen].e = 0;
        // gscore updated EVERY row (full rectangle always reaches last column);
        // tie -> later row, matching the RTL tracker (>=).
        if (h1 >= gscore) { gscore = h1; max_ie = i; }
        if (mm == 0) break;
        if (mm > max) {
            max = mm, max_i = i, max_j = mj;
            max_off = max_off > abs(mj - i) ? max_off : abs(mj - i);
        } else if (zdrop > 0) {
            if (i - max_i > mj - max_j) {
                if (max - mm - ((i - max_i) - (mj - max_j)) * e_del > zdrop) break;
            } else {
                if (max - mm - ((mj - max_j) - (i - max_i)) * e_ins > zdrop) break;
            }
        }
    }
    free(eh); free(qp);
    if (_qle) *_qle = max_j + 1;
    if (_tle) *_tle = max_i + 1;
    if (_gtle) *_gtle = max_ie + 1;
    if (_gscore) *_gscore = gscore;
    if (_max_off) *_max_off = max_off;
    return max;
}
