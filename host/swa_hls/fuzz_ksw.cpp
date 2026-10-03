// fuzz_ksw.cpp -- randomized differential test: ksw_hls.h vs the reference
// ksw.h (ksw_extend2), over randomized inputs rather than captured ones.
//
// The captured vectors only cover what bwa-mem2 happens to produce on one
// dataset. This reaches the rare control-flow corners -- empty bands, all-zero
// prefixes, harsh scoring, degenerate lengths -- that decide whether a mutant
// is equivalent or merely unexercised.
//
//   g++ -O2 -std=c++17 -I. -I../extend_orchestrator -o fuzz_ksw fuzz_ksw.cpp
//   ./fuzz_ksw [--iters N] [--seed S] [--max-qlen Q] [--max-tlen T] [--verbose]
#include "ksw.h"
#include "ksw_hls.h"
#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <random>

int main(int argc, char **argv) {
    long iters = 200000;
    unsigned seed = 1;
    int maxq = 64, maxt = 128;
    bool verbose = false;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--iters") && i + 1 < argc) iters = atol(argv[++i]);
        else if (!strcmp(argv[i], "--seed") && i + 1 < argc) seed = (unsigned)atol(argv[++i]);
        else if (!strcmp(argv[i], "--max-qlen") && i + 1 < argc) maxq = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--max-tlen") && i + 1 < argc) maxt = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--verbose")) verbose = true;
    }
    if (maxq > KSW_MAX_QLEN) maxq = KSW_MAX_QLEN;
    if (maxt > KSW_MAX_TLEN) maxt = KSW_MAX_TLEN;

    std::mt19937 rng(seed);
    auto R = [&](int lo, int hi) { return (int)(lo + rng() % (unsigned)(hi - lo + 1)); };

    uint8_t q[KSW_MAX_QLEN], t[KSW_MAX_TLEN];
    long bad = 0, ran = 0;

    for (long it = 0; it < iters; ++it) {
        const int qlen = R(1, maxq);
        const int tlen = R(1, maxt);
        const int a = R(1, 5), b = R(1, 10);
        const int o_del = R(0, 40), e_del = R(1, 20);
        const int o_ins = R(0, 40), e_ins = R(1, 20);
        const int w = R(1, 200);
        const int end_bonus = R(0, 20);
        const int zdrop = (rng() % 4) ? R(1, 200) : 0;   // sometimes disabled
        const int h0 = R(1, 200);

        int8_t mat[25];
        bwa_fill_scmat(a, b, mat);

        memset(q, 0, sizeof q); memset(t, 0, sizeof t);
        for (int k = 0; k < qlen; k++) q[k] = (uint8_t)R(0, 4);
        // half the time make the target a mutated copy of the query, so real
        // alignments exist; otherwise fully random, which stresses the zero paths
        if (rng() % 2) {
            for (int k = 0; k < tlen; k++)
                t[k] = (k < qlen && (rng() % 100) < 85) ? q[k] : (uint8_t)R(0, 4);
        } else {
            for (int k = 0; k < tlen; k++) t[k] = (uint8_t)R(0, 4);
        }

        int rqle = -9, rtle = -9, rgtle = -9, rgscore = -9, rmax_off = -9;
        const int rscore = ksw_extend2(qlen, q, tlen, t, KSW_M, mat,
                                       o_del, e_del, o_ins, e_ins, w,
                                       end_bonus, zdrop, h0,
                                       &rqle, &rtle, &rgtle, &rgscore, &rmax_off);

        const ksw_extend_out o = ksw_extend_hls(qlen, q, tlen, t, mat,
                                                o_del, e_del, o_ins, e_ins, w,
                                                end_bonus, zdrop, h0);
        ran++;
        const bool ok = o.status == KSW_OK && o.score == rscore && o.qle == rqle &&
                        o.tle == rtle && o.gtle == rgtle && o.gscore == rgscore &&
                        o.max_off == rmax_off;
        if (!ok) {
            ++bad;
            if (verbose || bad <= 5) {
                printf("MISMATCH it=%ld  qlen=%d tlen=%d h0=%d w=%d zdrop=%d eb=%d\n"
                       "   a=%d b=%d o_del=%d e_del=%d o_ins=%d e_ins=%d status=%d\n",
                       it, qlen, tlen, h0, w, zdrop, end_bonus,
                       a, b, o_del, e_del, o_ins, e_ins, o.status);
                printf("   ref: score=%d qle=%d tle=%d gtle=%d gscore=%d max_off=%d\n",
                       rscore, rqle, rtle, rgtle, rgscore, rmax_off);
                printf("   hls: score=%d qle=%d tle=%d gtle=%d gscore=%d max_off=%d\n",
                       o.score, o.qle, o.tle, o.gtle, o.gscore, o.max_off);
            }
        }
    }

    printf("seed=%u iters=%ld maxq=%d maxt=%d\n", seed, iters, maxq, maxt);
#if defined(KSW_INSTRUMENT) && !defined(__SYNTHESIS__)
    extern unsigned long long ksw_fb_first_nz_none, ksw_fb_all_zero;
    printf("FALLBACK first_nz<0 : %llu\n", ksw_fb_first_nz_none);
    printf("FALLBACK all-zero   : %llu\n", ksw_fb_all_zero);
#endif
    printf("\n%s: %ld/%ld agree, %ld mismatches\n", bad ? "FAIL" : "PASS",
           ran - bad, ran, bad);
    return bad ? 1 : 0;
}
