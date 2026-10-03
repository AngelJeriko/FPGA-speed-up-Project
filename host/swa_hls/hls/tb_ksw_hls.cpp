// C-sim / co-sim testbench: replays the embedded golden vectors through
// ksw_extend_top and compares all six outputs against bwa-mem2's.
//
// The vectors come from several bwa-mem2 runs with different scoring, so the
// set spans more than one point in the parameter space:
//
//   COSIM   default parameters          (-O 6,6 -E 1,1 -w 100)
//   COSIMT  tight gaps, narrow band     (-O 30,30 -E 12,9)  band clamp binds
//   COSIME  tight extension             (-E 20,20)          band clamp binds
//   COSIMW  narrow band only            (-w 12)             band-shrink active
//
// The two tight-gap sets matter: at bwa's default e_del=e_ins=1 the
// max_ins/max_del clamp never binds, so the kernel's integer division
// transform is dead weight on default vectors. See docs/swa_hls_kernel.md.
//
// The same source compiles with plain g++, so the testbench can be checked
// before it is ever handed to Vitis:
//   g++ -O2 -std=c++17 -I.. -I. -o tb tb_ksw_hls.cpp ksw_kernel.cpp && ./tb
//
// Vitis HLS treats a non-zero return from main() as a failure, which is what
// makes csim_design / cosim_design pass or fail on bit-exactness.
#include "ksw_kernel.h"
#include "cosim_vectors.h"
#include "cosim_vectors_tight.h"
#include "cosim_vectors_tE.h"
#include "cosim_vectors_w12.h"
#include <cstdio>
#include <cstring>

namespace {

struct vec_set {
    const char        *name;
    const cosim_vec   *vecs;
    const int8_t      *mat;
    int                n;
};

int run_set(const vec_set &s) {
    int fail = 0;
    for (int v = 0; v < s.n; ++v) {
        const cosim_vec &c = s.vecs[v];

        // fixed-size buffers, exactly as the RTL top-level sees them
        uint8_t q[KSW_MAX_QLEN], t[KSW_MAX_TLEN];
        memset(q, 0, sizeof q);
        memset(t, 0, sizeof t);
        memcpy(q, c.query, (size_t)c.qlen);
        memcpy(t, c.target, (size_t)c.tlen);

        ksw_extend_out o;
        ksw_extend_top(c.qlen, q, c.tlen, t, s.mat,
                       c.o_del, c.e_del, c.o_ins, c.e_ins,
                       c.w, c.end_bonus, c.zdrop, c.h0, &o);

        const bool ok = o.status == KSW_OK && o.score == c.score &&
                        o.qle == c.qle && o.tle == c.tle && o.gtle == c.gtle &&
                        o.gscore == c.gscore && o.max_off == c.max_off;
        if (!ok) {
            ++fail;
            printf("FAIL %s[%d]  qlen=%d tlen=%d h0=%d w=%d "
                   "o_del=%d e_del=%d o_ins=%d e_ins=%d status=%d\n",
                   s.name, v, c.qlen, c.tlen, c.h0, c.w,
                   c.o_del, c.e_del, c.o_ins, c.e_ins, o.status);
            printf("   golden: score=%d qle=%d tle=%d gtle=%d gscore=%d max_off=%d\n",
                   c.score, c.qle, c.tle, c.gtle, c.gscore, c.max_off);
            printf("   kernel: score=%d qle=%d tle=%d gtle=%d gscore=%d max_off=%d\n",
                   o.score, o.qle, o.tle, o.gtle, o.gscore, o.max_off);
        }
    }
    return fail;
}

} // namespace

int main() {
    const vec_set sets[] = {
        {"default",   COSIM_VECS,  COSIM_MAT,  COSIM_N },
        {"tight-gap", COSIMT_VECS, COSIMT_MAT, COSIMT_N},
        {"tight-ext", COSIME_VECS, COSIME_MAT, COSIME_N},
        {"narrow-w",  COSIMW_VECS, COSIMW_MAT, COSIMW_N},
    };
    const int n_sets = (int)(sizeof sets / sizeof sets[0]);

    int total = 0, fail = 0;
    for (int i = 0; i < n_sets; ++i) {
        const int f = run_set(sets[i]);
        printf("  %-10s %3d vectors, %d failures\n", sets[i].name, sets[i].n, f);
        total += sets[i].n;
        fail  += f;
    }

    printf("\n%s: %d/%d vectors bit-exact\n", fail ? "FAIL" : "PASS",
           total - fail, total);
    return fail ? 1 : 0;
}
