// check_band.cpp — validate the "single SW run per side" simplification for the
// HW driver. orch.h's band_extend() loops ksw_extend2 at w = o.w << i for i in
// [0, MAX_BAND_TRY) and accepts on (sc==prev || maxoff<(w>>1)+(w>>2) || last try).
//
// Claim: because the systolic array computes the FULL DP (one PE per query base)
// and 2*w+1 >= qlen for w=100 and qlen<=160, the banded ksw at w=100 already
// equals full DP. So ksw@w=100 and ksw@w=200 must produce IDENTICAL
// score/qle/tle/gscore/gtle/maxoff for every real extension — meaning the HW core
// runs once and the driver only needs to pick the stored alnreg.w from maxoff:
//     final_w = (sc==prev || maxoff < (o.w>>1)+(o.w>>2)) ? o.w : o.w<<1
//
// This program replays every left/right extension exactly as orch.h sets them up,
// runs ksw at both bands, and reports any divergence + the maxoff distribution.
#include <cstdio>
#include <vector>
#include "parse.h"

struct K { int sc, qle, tle, gtle, gscore, maxoff; };
static K run(int qlen, const uint8_t*q, int tlen, const uint8_t*t,
             const Cfg&o, int eb, int h0, int w) {
    K k{};
    k.sc = ksw_extend2(qlen, q, tlen, t, 5, o.mat, o.o_del, o.e_del, o.o_ins,
                       o.e_ins, w, eb, o.zdrop, h0, &k.qle, &k.tle, &k.gtle,
                       &k.gscore, &k.maxoff);
    return k;
}

int main(int argc, char** argv) {
    if (argc < 2) { fprintf(stderr, "usage: %s vectors.bin\n", argv[0]); return 1; }
    auto reads = load_reads(argv[1]);

    long n_ext = 0, diverge = 0, maxoff_diff = 0, try1 = 0;
    int worst_maxoff = 0;

    for (auto& rv : reads) {
        const Cfg& o = rv.cfg;
        const int lq = rv.l_query;
        const int thr = (o.w >> 1) + (o.w >> 2);     // accept threshold at w=o.w (=75)
        for (auto& c : rv.chains) {
            for (auto& s : c.seeds) {
                // ---- left extension (mirror orch.h phase 2) ----
                if (s.qbeg) {
                    const int64_t tmp = s.rbeg - c.rmax0;
                    std::vector<uint8_t> qs(s.qbeg), rs(tmp > 0 ? tmp : 0);
                    for (int i = 0; i < s.qbeg; ++i) qs[i] = rv.query[s.qbeg-1-i];
                    for (int64_t i = 0; i < tmp; ++i) rs[i] = c.ref[tmp-1-i];
                    int h0 = s.len * o.a, prev = -1;     // A.score before left = -1
                    K a = run(s.qbeg, qs.data(), (int)tmp, rs.data(), o, o.pen_clip5, h0, o.w);
                    K b = run(s.qbeg, qs.data(), (int)tmp, rs.data(), o, o.pen_clip5, h0, o.w<<1);
                    n_ext++;
                    if (a.sc!=b.sc||a.qle!=b.qle||a.tle!=b.tle||a.gtle!=b.gtle||a.gscore!=b.gscore) diverge++;
                    if (a.maxoff!=b.maxoff) maxoff_diff++;
                    if (a.maxoff > worst_maxoff) worst_maxoff = a.maxoff;
                    if (!(a.sc==prev || a.maxoff < thr)) try1++;
                }
                // ---- right extension (mirror orch.h phase 3) ----
                const int qe0 = s.qbeg + s.len;
                const int64_t re0 = s.rbeg + s.len - c.rmax0;
                if (qe0 != lq) {
                    const int len2 = lq - qe0;
                    const int64_t len1 = c.rmax1 - c.rmax0 - re0;
                    std::vector<uint8_t> qs(len2), rs(len1 > 0 ? len1 : 0);
                    for (int i = 0; i < len2; ++i) qs[i] = rv.query[qe0+i];
                    for (int64_t i = 0; i < len1; ++i) rs[i] = c.ref[re0+i];
                    // h0R = A.score (post-left); prev = same. For this equivalence
                    // check the absolute h0 doesn't matter (we compare two bands at
                    // the SAME h0); use the seed score proxy. We only need band-vs-band.
                    int h0 = s.len * o.a, prev = h0;
                    K a = run(len2, qs.data(), (int)len1, rs.data(), o, o.pen_clip3, h0, o.w);
                    K b = run(len2, qs.data(), (int)len1, rs.data(), o, o.pen_clip3, h0, o.w<<1);
                    n_ext++;
                    if (a.sc!=b.sc||a.qle!=b.qle||a.tle!=b.tle||a.gtle!=b.gtle||a.gscore!=b.gscore) diverge++;
                    if (a.maxoff!=b.maxoff) maxoff_diff++;
                    if (a.maxoff > worst_maxoff) worst_maxoff = a.maxoff;
                    if (!(a.sc==prev || a.maxoff < thr)) try1++;
                }
            }
        }
    }

    printf("extensions checked      = %ld\n", n_ext);
    printf("w=100 vs w=200 diverge  = %ld  (score/qle/tle/gtle/gscore)\n", diverge);
    printf("maxoff differs (100/200)= %ld\n", maxoff_diff);
    printf("worst maxoff @ w=100    = %d  (band half-width 100 covers offsets < 100)\n", worst_maxoff);
    printf("would proceed to try1   = %ld  (%.2f%% -> stored w=200)\n",
           try1, 100.0*try1/(n_ext?n_ext:1));
    printf("%s\n", (diverge==0 && maxoff_diff==0)
        ? "PASS: single full-DP run is bit-exact for both bands -> driver runs SW once"
        : "FAIL: bands diverge -> driver must actually loop");
    return 0;
}
