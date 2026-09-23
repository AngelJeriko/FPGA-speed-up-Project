// ksw_hls.h -- synthesizable form of ksw_extend2, for Vitis HLS.
//
// host/extend_orchestrator/ksw.h is the verbatim reference port and must stay
// verbatim. This file is the HLS kernel: same arithmetic, same control flow,
// but with everything HLS cannot synthesize removed. It is validated against
// the reference and against the bwa-mem2 golden capture by replay_swa
// (see docs/swa_golden_capture.md).
//
// WHAT CHANGED, AND WHY EACH CHANGE IS BEHAVIOUR-PRESERVING
//
//  1. malloc/calloc/free  ->  fixed-size local arrays sized from the RTL
//     envelope in rtl/bsw_pkg.sv (MAX_QLEN=160, MAX_TLEN=1024, m=5), so the
//     HLS kernel and the SystemVerilog core accept exactly the same inputs.
//     calloc() zeroed eh[]; an explicit bounded zeroing loop replaces it.
//
//  2. Unbounded loop trip counts  ->  every loop is bounded by a compile-time
//     constant with the original condition as an inner `break`. Each rewrite
//     leaves the loop variable with the identical exit value, which matters:
//     the DP loop's exit `j` is read afterwards by `if (j == qlen)`.
//
//  3. Pointer out-params  ->  a returned struct (real output ports in RTL).
//
//  4. The two `(int)((double)X / e + 1.)` expressions  ->  `(X + e) / e`.
//     The +1.0 is applied before truncation, so trunc(X/e + 1) == trunc((X+e)/e),
//     and C integer division truncates toward zero like trunc(). Exact for
//     e > 0. This is the same transform already proven for cal_max_gap_int.
//     It removes the only floating point in the kernel.
//
//  5. eh_t array-of-structs  ->  two parallel arrays (h and e). Identical
//     semantics; gives HLS two independent memory ports instead of one.
//
//  6. Alphabet indices are clamped to [0, m-1] before indexing mat/qp. With
//     valid bwa input (bases 0..4) this is inert; it makes out-of-range input
//     safe against fixed-size arrays rather than undefined.
//
//  7. `status` reports an input outside the envelope instead of overflowing.
//
// Widths are int32_t throughout, matching the reference exactly. The score
// bound proof (H_MAX=1184 for 160/1024, see docs) shows 16 bits suffice, so
// the eh arrays are a candidate for narrowing later; that is a resource
// optimisation, deliberately not bundled with the bit-exactness milestone.
#pragma once
#include <cstdint>

#ifndef KSW_MAX_QLEN
#define KSW_MAX_QLEN 160        // rtl/bsw_pkg.sv :: MAX_QLEN
#endif
#ifndef KSW_MAX_TLEN
#define KSW_MAX_TLEN 1024       // rtl/bsw_pkg.sv :: MAX_TLEN
#endif
#ifndef KSW_M
#define KSW_M 5                 // rtl/bsw_pkg.sv :: M_ALPHABET
#endif

enum ksw_status_t {
    KSW_OK          = 0,
    KSW_ERR_QLEN    = 1,        // qlen outside [1, KSW_MAX_QLEN]
    KSW_ERR_TLEN    = 2,        // tlen outside [0, KSW_MAX_TLEN]
    KSW_ERR_H0      = 3,        // h0 <= 0 (the reference asserts this)
    KSW_ERR_GAP     = 4         // e_del <= 0 or e_ins <= 0 (division by zero)
};

struct ksw_extend_out {
    int32_t score;              // == ksw_extend2 return value
    int32_t qle, tle, gtle, gscore, max_off;
    int32_t status;             // ksw_status_t; outputs are 0 unless KSW_OK
};

static inline ksw_extend_out ksw_extend_hls(
        int32_t qlen, const uint8_t query[KSW_MAX_QLEN],
        int32_t tlen, const uint8_t target[KSW_MAX_TLEN],
        const int8_t mat[KSW_M * KSW_M],
        int32_t o_del, int32_t e_del, int32_t o_ins, int32_t e_ins,
        int32_t w, int32_t end_bonus, int32_t zdrop, int32_t h0)
{
#pragma HLS INLINE off

    ksw_extend_out out;
    out.score = out.qle = out.tle = out.gtle = out.gscore = out.max_off = 0;

    if (qlen < 1 || qlen > KSW_MAX_QLEN) { out.status = KSW_ERR_QLEN; return out; }
    if (tlen < 0 || tlen > KSW_MAX_TLEN) { out.status = KSW_ERR_TLEN; return out; }
    if (h0 <= 0)                         { out.status = KSW_ERR_H0;   return out; }
    if (e_del <= 0 || e_ins <= 0)        { out.status = KSW_ERR_GAP;  return out; }
    out.status = KSW_OK;

    // (1) fixed-size replacements for malloc/calloc. eh is MAX_QLEN+2 because
    // the reference writes eh[1] unconditionally and eh[end] with end <= qlen.
    int8_t  qp[KSW_M * KSW_MAX_QLEN];
    int32_t eh_h[KSW_MAX_QLEN + 2];
    int32_t eh_e[KSW_MAX_QLEN + 2];

    int32_t i, j, k;
    const int32_t oe_del = o_del + e_del;
    const int32_t oe_ins = o_ins + e_ins;
    int32_t beg, end, max, max_i, max_j, max_ins, max_del, max_ie, gscore, max_off;

    // query profile: qp[k][j] = mat[k][query[j]]
  QP_ROW:
    for (k = 0; k < KSW_M; ++k) {
      QP_COL:
        for (j = 0; j < KSW_MAX_QLEN; ++j) {
#pragma HLS LOOP_TRIPCOUNT min=32 max=KSW_MAX_QLEN
#pragma HLS PIPELINE II=1
            if (j >= qlen) break;
            uint8_t qb = query[j];
            if (qb >= KSW_M) qb = KSW_M - 1;                 // (6)
            qp[k * KSW_MAX_QLEN + j] = mat[k * KSW_M + qb];
        }
    }

    // (1) calloc(qlen + 1, 8)
  EH_ZERO:
    for (j = 0; j < KSW_MAX_QLEN + 2; ++j) {
#pragma HLS LOOP_TRIPCOUNT min=32 max=KSW_MAX_QLEN
#pragma HLS PIPELINE II=1
        if (j > qlen) break;
        eh_h[j] = 0; eh_e[j] = 0;
    }

    eh_h[0] = h0;
    eh_h[1] = h0 > oe_ins ? h0 - oe_ins : 0;
  EH_INIT:
    for (j = 2; j < KSW_MAX_QLEN + 1; ++j) {
#pragma HLS LOOP_TRIPCOUNT min=0 max=KSW_MAX_QLEN
#pragma HLS PIPELINE II=1
        if (j > qlen || eh_h[j - 1] <= e_ins) break;
        eh_h[j] = eh_h[j - 1] - e_ins;
    }

    max = 0;
  MAT_MAX:
    for (i = 0; i < KSW_M * KSW_M; ++i) {
#pragma HLS PIPELINE II=1
        max = max > mat[i] ? max : mat[i];
    }

    // (4) integer-exact replacement for (int)((double)X / e + 1.)
    max_ins = (qlen * max + end_bonus - o_ins + e_ins) / e_ins;
    max_ins = max_ins > 1 ? max_ins : 1;
    w = w < max_ins ? w : max_ins;
    max_del = (qlen * max + end_bonus - o_del + e_del) / e_del;
    max_del = max_del > 1 ? max_del : 1;
    w = w < max_del ? w : max_del;

    max = h0; max_i = max_j = -1; max_ie = -1; gscore = -1;
    max_off = 0;
    beg = 0; end = qlen;
    j = 0;                       // (2) exit value is read after the DP loop

  TARGET:
    for (i = 0; i < KSW_MAX_TLEN; ++i) {
#pragma HLS LOOP_TRIPCOUNT min=32 max=KSW_MAX_TLEN
        if (i >= tlen) break;

        int32_t t, f = 0, h1, mm = 0, mj = -1;
        uint8_t tb = target[i];
        if (tb >= KSW_M) tb = KSW_M - 1;                     // (6)
        const int8_t *q = &qp[tb * KSW_MAX_QLEN];

        if (beg < i - w) beg = i - w;
        if (end > i + w + 1) end = i + w + 1;
        if (end > qlen) end = qlen;
        if (beg == 0) {
            h1 = h0 - (o_del + e_del * (i + 1));
            if (h1 < 0) h1 = 0;
        } else h1 = 0;

      BAND:
        for (j = beg; j < KSW_MAX_QLEN; ++j) {
#pragma HLS LOOP_TRIPCOUNT min=1 max=KSW_MAX_QLEN
#pragma HLS PIPELINE II=1
            if (j >= end) break;
            int32_t h, M = eh_h[j], e = eh_e[j];
            eh_h[j] = h1;
            M = M ? M + q[j] : 0;
            h = M > e ? M : e;
            h = h > f ? h : f;
            h1 = h;
            mj = mm > h ? mj : j;
            mm = mm > h ? mm : h;
            t = M - oe_del; t = t > 0 ? t : 0;
            e -= e_del; e = e > t ? e : t; eh_e[j] = e;
            t = M - oe_ins; t = t > 0 ? t : 0;
            f -= e_ins; f = f > t ? f : t;
        }
        eh_h[end] = h1; eh_e[end] = 0;

        if (j == qlen) {
            max_ie = gscore > h1 ? max_ie : i;
            gscore = gscore > h1 ? gscore : h1;
        }
        if (mm == 0) break;
        if (mm > max) {
            int32_t d = mj - i; if (d < 0) d = -d;
            max = mm; max_i = i; max_j = mj;
            max_off = max_off > d ? max_off : d;
        } else if (zdrop > 0) {
            if (i - max_i > mj - max_j) {
                if (max - mm - ((i - max_i) - (mj - max_j)) * e_del > zdrop) break;
            } else {
                if (max - mm - ((mj - max_j) - (i - max_i)) * e_ins > zdrop) break;
            }
        }

        // (2) shrink the band; both loops leave j at the reference's exit value
      TRIM_LO:
        for (j = beg; j < KSW_MAX_QLEN; ++j) {
#pragma HLS LOOP_TRIPCOUNT min=0 max=KSW_MAX_QLEN
#pragma HLS PIPELINE II=1
            if (j >= end) break;
            if (eh_h[j] != 0 || eh_e[j] != 0) break;
        }
        beg = j;
      TRIM_HI:
        for (j = end; j >= 0; --j) {
#pragma HLS LOOP_TRIPCOUNT min=0 max=KSW_MAX_QLEN
#pragma HLS PIPELINE II=1
            if (j < beg) break;
            if (eh_h[j] != 0 || eh_e[j] != 0) break;
        }
        end = j + 2 < qlen ? j + 2 : qlen;
    }

    out.score   = max;
    out.qle     = max_j + 1;
    out.tle     = max_i + 1;
    out.gtle    = max_ie + 1;
    out.gscore  = gscore;
    out.max_off = max_off;
    return out;
}
