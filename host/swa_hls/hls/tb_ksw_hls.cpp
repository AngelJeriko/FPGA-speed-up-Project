// C-sim / co-sim testbench: replays the embedded golden vectors through
// ksw_extend_top and compares all six outputs against bwa-mem2's.
//
// The same source compiles with plain g++, so the testbench can be checked
// before it is ever handed to Vitis:
//   g++ -O2 -std=c++17 -I.. -I. -o tb tb_ksw_hls.cpp ksw_kernel.cpp && ./tb
//
// Vitis HLS treats a non-zero return from main() as a failure, which is what
// makes csim_design / cosim_design pass or fail on bit-exactness.
#include "ksw_kernel.h"
#include "cosim_vectors.h"
#include <cstdio>
#include <cstring>

int main() {
    int fail = 0;

    for (int v = 0; v < COSIM_N; ++v) {
        const cosim_vec &c = COSIM_VECS[v];

        // fixed-size buffers, exactly as the RTL top-level sees them
        uint8_t q[KSW_MAX_QLEN], t[KSW_MAX_TLEN];
        memset(q, 0, sizeof q);
        memset(t, 0, sizeof t);
        memcpy(q, c.query, (size_t)c.qlen);
        memcpy(t, c.target, (size_t)c.tlen);

        ksw_extend_out o;
        ksw_extend_top(c.qlen, q, c.tlen, t, COSIM_MAT,
                       c.o_del, c.e_del, c.o_ins, c.e_ins,
                       c.w, c.end_bonus, c.zdrop, c.h0, &o);

        const bool ok = o.status == KSW_OK && o.score == c.score &&
                        o.qle == c.qle && o.tle == c.tle && o.gtle == c.gtle &&
                        o.gscore == c.gscore && o.max_off == c.max_off;
        if (!ok) {
            ++fail;
            printf("FAIL vec %2d  qlen=%d tlen=%d h0=%d w=%d status=%d\n",
                   v, c.qlen, c.tlen, c.h0, c.w, o.status);
            printf("   golden: score=%d qle=%d tle=%d gtle=%d gscore=%d max_off=%d\n",
                   c.score, c.qle, c.tle, c.gtle, c.gscore, c.max_off);
            printf("   kernel: score=%d qle=%d tle=%d gtle=%d gscore=%d max_off=%d\n",
                   o.score, o.qle, o.tle, o.gtle, o.gscore, o.max_off);
        }
    }

    printf("\n%s: %d/%d vectors bit-exact\n", fail ? "FAIL" : "PASS",
           COSIM_N - fail, COSIM_N);
    return fail ? 1 : 0;
}
