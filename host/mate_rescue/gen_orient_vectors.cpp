// gen_orient_vectors.cpp — golden vectors for tb_matesw_orient_unit (the RTL
// per-orientation mate-rescue unit). Exercises the SW (hw_align2 == matesw_top)
// PLUS the mem_matesw kswr->alnreg transform (orch.h). Coordinates are kept small
// (l_pac < 2^20) so every field fits 32-bit for the TB; the is_rev transform math
// (2*l_pac - ...) is identical at any scale.
//
// Output:
//   <count>
//   per case:
//     l_ms tlen o_del e_del o_ins e_ins a min_seed_len is_rev rb l_pac a_rid a_is_alt \
//     exp_rescue b_rb b_re b_qb b_qe b_score b_seedcov b_rid b_is_alt
//     query[0..l_ms-1]            (oriented mate seq — caller reverse-complements when is_rev)
//     ref[0..tlen-1]
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
static uint64_t st = 0x0a1e7ab1eed5eed1ull;
static inline uint32_t rnd() { st = st*6364136223846793005ull + 1442695040888963407ull; return (uint32_t)(st>>33); }

int main(int argc, char** argv) {
    if (argc < 2) { fprintf(stderr, "usage: %s out.txt [n]\n", argv[0]); return 1; }
    int n = argc > 2 ? atoi(argv[2]) : 4000;
    const int a = 1, b = 4, od=6, ed=1, oi=6, ei=1;
    int8_t mat[25]; fill_scmat(a, b, mat);

    std::string buf; buf.reserve(8<<20);
    char line[256];
    long reached = 0;
    for (int it = 0; it < n; ++it) {
        int l_ms = 1 + rnd() % 120;
        int tlen = 1 + rnd() % 200;
        std::vector<uint8_t> q(l_ms), t(tlen);
        for (int i = 0; i < tlen; ++i) t[i] = rnd() % 4;
        bool embed = (rnd() & 1) && tlen >= l_ms;
        if (embed) {
            int off = rnd() % (tlen - l_ms + 1);
            for (int j = 0; j < l_ms; ++j) {
                uint8_t base = t[off + j]; uint32_t r = rnd() % 100;
                if (r < 12) base = rnd() % 4; else if (r < 16) base = 4;
                q[j] = base;
            }
        } else for (int j = 0; j < l_ms; ++j) q[j] = rnd() % 5;

        int min_seed_len = 19 + (int)(rnd() % 12);
        int is_rev = rnd() & 1;
        long long l_pac = 100000 + (long long)(rnd() % 900000);
        long long rb    = (long long)(rnd() % 200000);
        int a_rid = (int)(rnd() % 24);
        int a_is_alt = (int)(rnd() & 1);

        int xtra = KSW_XSUBO | KSW_XSTART | KSW_XBYTE | (min_seed_len * a);
        HR r = hw_align2(l_ms, q.data(), tlen, t.data(), mat, od, ed, oi, ei, xtra);

        // mem_matesw kswr->alnreg transform (orch.h::matesw_orchestrate)
        long long b_qb = is_rev ? (long long)l_ms - (r.qe + 1) : r.qb;
        long long b_qe = is_rev ? (long long)l_ms - r.qb       : r.qe + 1;
        long long b_rb = is_rev ? 2*l_pac - (rb + r.te + 1)    : rb + r.tb;
        long long b_re = is_rev ? 2*l_pac - (rb + r.tb)        : rb + r.te + 1;
        long long b_score = r.score;
        long long b_cov = ((b_re - b_rb < b_qe - b_qb) ? (b_re - b_rb) : (b_qe - b_qb)) >> 1;
        int rescue = (r.score >= min_seed_len && r.qb >= 0) ? 1 : 0;
        if (rescue) reached++;

        snprintf(line, sizeof line,
                 "%d %d %d %d %d %d %d %d %d %lld %lld %d %d %d %lld %lld %lld %lld %lld %lld %d %d\n",
                 l_ms, tlen, od, ed, oi, ei, a, min_seed_len, is_rev, rb, l_pac, a_rid, a_is_alt,
                 rescue, b_rb, b_re, b_qb, b_qe, b_score, b_cov, a_rid, a_is_alt);
        buf += line;
        for (int j = 0; j < l_ms; ++j) { snprintf(line,sizeof line,"%d ",q[j]); buf+=line; } buf += '\n';
        for (int i = 0; i < tlen; ++i) { snprintf(line,sizeof line,"%d ",t[i]); buf+=line; } buf += '\n';
    }
    FILE* out = fopen(argv[1], "w");
    fprintf(out, "%d\n", n);
    fwrite(buf.data(), 1, buf.size(), out);
    fclose(out);
    fprintf(stderr, "wrote %d orient vectors (%ld produce a rescue) to %s\n", n, reached, argv[1]);
    return 0;
}
