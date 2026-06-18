// gen_matesw_vectors.cpp — golden vectors for tb_matesw_top (the RTL mate-rescue
// engine). Expected outputs come from hw_align2 (host/mate_rescue/hw.h), which is
// cross-checked bit-exact vs the upstream ksw_align2. Uses realistic mem_matesw
// xtra (KSW_XSUBO|KSW_XSTART, subo = min_seed_len*a >= 1) so the degenerate
// score<1 reverse path never occurs.
//
// Output:
//   <count>
//   per case:
//     qlen tlen o_del e_del o_ins e_ins subo xstart xsubo \
//     exp_score exp_te exp_qe exp_tb exp_qb
//     query[0..qlen-1]
//     target[0..tlen-1]
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <vector>
#include <string>
#include "macro.h"
#include "ksw_ref.h"
#include "hw.h"

uint64_t tprof[LIM_R][LIM_C];

static void fill_scmat(int a, int b, int8_t mat[25]) {
    int i, j, k;
    for (i = k = 0; i < 4; ++i) { for (j = 0; j < 4; ++j) mat[k++] = i==j? a : -b; mat[k++] = -1; }
    for (j = 0; j < 5; ++j) mat[k++] = -1;
}
static uint64_t st = 0xfeedface12345678ull;
static inline uint32_t rnd() { st = st*6364136223846793005ull + 1442695040888963407ull; return (uint32_t)(st>>33); }

int main(int argc, char** argv) {
    if (argc < 2) { fprintf(stderr, "usage: %s out.txt [n]\n", argv[0]); return 1; }
    int n = argc > 2 ? atoi(argv[2]) : 4000;
    int8_t mat[25]; fill_scmat(1, 4, mat);
    const int od=6, ed=1, oi=6, ei=1;

    std::string buf; buf.reserve(8<<20);
    char line[128];
    long reached = 0;
    for (int it = 0; it < n; ++it) {
        int qlen = 1 + rnd() % 120;            // mate read length
        int tlen = 1 + rnd() % 200;            // reference window
        std::vector<uint8_t> q(qlen), t(tlen);
        for (int i = 0; i < tlen; ++i) t[i] = rnd() % 4;
        bool embed = (rnd() & 1) && tlen >= qlen;
        if (embed) {
            int off = rnd() % (tlen - qlen + 1);
            for (int j = 0; j < qlen; ++j) {
                uint8_t b = t[off + j]; uint32_t r = rnd() % 100;
                if (r < 12) b = rnd() % 4; else if (r < 16) b = 4;
                q[j] = b;
            }
        } else for (int j = 0; j < qlen; ++j) q[j] = rnd() % 5;

        int subo = 19 + (int)(rnd() % 12);     // realistic min_seed_len*a
        int xtra = KSW_XSUBO | KSW_XSTART | KSW_XBYTE | subo;
        HR r = hw_align2(qlen, q.data(), tlen, t.data(), mat, od, ed, oi, ei, xtra);
        if (r.qb >= 0) reached++;

        snprintf(line, sizeof line, "%d %d %d %d %d %d %d %d %d %d %d %d %d %d\n",
                 qlen, tlen, od, ed, oi, ei, subo, 1, 1,
                 r.score, r.te, r.qe, r.tb, r.qb);
        buf += line;
        for (int j = 0; j < qlen; ++j) { snprintf(line,sizeof line,"%d ",q[j]); buf+=line; } buf += '\n';
        for (int i = 0; i < tlen; ++i) { snprintf(line,sizeof line,"%d ",t[i]); buf+=line; } buf += '\n';
    }
    FILE* out = fopen(argv[1], "w");
    fprintf(out, "%d\n", n);
    fwrite(buf.data(), 1, buf.size(), out);
    fclose(out);
    fprintf(stderr, "wrote %d matesw vectors (%ld reach the start pass) to %s\n", n, reached, argv[1]);
    return 0;
}
