// ksw.h — scalar banded Smith-Waterman extension, ported verbatim from
// bwa-mem2 src/ksw.cpp (ksw_extend2) + the scoring-matrix / max-gap helpers
// from bwa.cpp / bwamem.cpp. This is the numeric reference the FPGA BSW core
// reproduces; the extend_orchestrator model calls it for every seed extension.
//
// Faithful copy — do not "improve". Only cosmetic: C++ header, <cstdint>.
#pragma once
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <cassert>

#ifndef LIKELY
#define LIKELY(x) (x)
#endif

struct eh_t { int32_t h, e; };

// bwa.cpp:bwa_fill_scmat  (m = 5; match=a, mismatch=-b, ambiguous=-1)
static inline void bwa_fill_scmat(int a, int b, int8_t mat[25]) {
    int i, j, k;
    for (i = k = 0; i < 4; ++i) {
        for (j = 0; j < 4; ++j) mat[k++] = i == j ? a : -b;
        mat[k++] = -1;                 // ambiguous base
    }
    for (j = 0; j < 5; ++j) mat[k++] = -1;
}

// bwamem.cpp:cal_max_gap
static inline int cal_max_gap(int a, int o_del, int e_del, int o_ins, int e_ins,
                              int w, int qlen) {
    int l_del = (int)((double)(qlen * a - o_del) / e_del + 1.);
    int l_ins = (int)((double)(qlen * a - o_ins) / e_ins + 1.);
    int l = l_del > l_ins ? l_del : l_ins;
    l = l > 1 ? l : 1;
    return l < w << 1 ? l : w << 1;
}

// ksw.cpp:ksw_extend2  (verbatim)
static inline int ksw_extend2(int qlen, const uint8_t *query, int tlen,
        const uint8_t *target, int m, const int8_t *mat, int o_del, int e_del,
        int o_ins, int e_ins, int w, int end_bonus, int zdrop, int h0,
        int *_qle, int *_tle, int *_gtle, int *_gscore, int *_max_off) {
    eh_t *eh;
    int8_t *qp;
    int i, j, k, oe_del = o_del + e_del, oe_ins = o_ins + e_ins, beg, end, max,
        max_i, max_j, max_ins, max_del, max_ie, gscore, max_off;
    assert(h0 > 0);
    qp = (int8_t *) malloc(qlen * m);
    eh = (eh_t *) calloc(qlen + 1, 8);
    for (k = i = 0; k < m; ++k) {
        const int8_t *p = &mat[k * m];
        for (j = 0; j < qlen; ++j) qp[i++] = p[query[j]];
    }
    eh[0].h = h0; eh[1].h = h0 > oe_ins ? h0 - oe_ins : 0;
    for (j = 2; j <= qlen && eh[j-1].h > e_ins; ++j)
        eh[j].h = eh[j-1].h - e_ins;
    k = m * m;
    for (i = 0, max = 0; i < k; ++i) max = max > mat[i] ? max : mat[i];
    max_ins = (int)((double)(qlen * max + end_bonus - o_ins) / e_ins + 1.);
    max_ins = max_ins > 1 ? max_ins : 1;
    w = w < max_ins ? w : max_ins;
    max_del = (int)((double)(qlen * max + end_bonus - o_del) / e_del + 1.);
    max_del = max_del > 1 ? max_del : 1;
    w = w < max_del ? w : max_del;
    max = h0, max_i = max_j = -1; max_ie = -1, gscore = -1;
    max_off = 0;
    beg = 0, end = qlen;
    for (i = 0; LIKELY(i < tlen); ++i) {
        int t, f = 0, h1, mm = 0, mj = -1;
        int8_t *q = &qp[target[i] * qlen];
        if (beg < i - w) beg = i - w;
        if (end > i + w + 1) end = i + w + 1;
        if (end > qlen) end = qlen;
        if (beg == 0) {
            h1 = h0 - (o_del + e_del * (i + 1));
            if (h1 < 0) h1 = 0;
        } else h1 = 0;
        for (j = beg; LIKELY(j < end); ++j) {
            eh_t *p = &eh[j];
            int h, M = p->h, e = p->e;
            p->h = h1;
            M = M ? M + q[j] : 0;
            h = M > e ? M : e;
            h = h > f ? h : f;
            h1 = h;
            mj = mm > h ? mj : j;
            mm = mm > h ? mm : h;
            t = M - oe_del; t = t > 0 ? t : 0;
            e -= e_del; e = e > t ? e : t; p->e = e;
            t = M - oe_ins; t = t > 0 ? t : 0;
            f -= e_ins; f = f > t ? f : t;
        }
        eh[end].h = h1; eh[end].e = 0;
        if (j == qlen) {
            max_ie = gscore > h1 ? max_ie : i;
            gscore = gscore > h1 ? gscore : h1;
        }
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
        for (j = beg; LIKELY(j < end) && eh[j].h == 0 && eh[j].e == 0; ++j);
        beg = j;
        for (j = end; LIKELY(j >= beg) && eh[j].h == 0 && eh[j].e == 0; --j);
        end = j + 2 < qlen ? j + 2 : qlen;
    }
    free(eh); free(qp);
    if (_qle) *_qle = max_j + 1;
    if (_tle) *_tle = max_i + 1;
    if (_gtle) *_gtle = max_ie + 1;
    if (_gscore) *_gscore = gscore;
    if (_max_off) *_max_off = max_off;
    return max;
}
