// cross_check.cpp — validate the scalar hw_align2 model against the upstream
// ksw_align2 (the bit-exact reference) over many random + boundary inputs. Checks
// the fields mem_matesw consumes: score, qe, te, qb, tb. score2/te2 are not
// consumed and not compared. No remote / capture needed.
#include <cstdio>
#include <cstdint>
#include <vector>
#include "macro.h"
#include "ksw_ref.h"
#include "hw.h"

uint64_t tprof[LIM_R][LIM_C];

static void fill_scmat(int a, int b, int8_t mat[25]) {
    int i, j, k;
    for (i = k = 0; i < 4; ++i) { for (j = 0; j < 4; ++j) mat[k++] = i==j? a : -b; mat[k++] = -1; }
    for (j = 0; j < 5; ++j) mat[k++] = -1;
}

// simple deterministic LCG (Date/rand-free, reproducible)
static uint64_t rng_state = 0x123456789abcdef0ull;
static inline uint32_t rnd() { rng_state = rng_state*6364136223846793005ull + 1442695040888963407ull; return (uint32_t)(rng_state>>33); }

int main(int argc, char** argv) {
    int trials = argc > 1 ? atoi(argv[1]) : 200000;
    int8_t mat[25]; fill_scmat(1, 4, mat);
    const int o_del=6, e_del=1, o_ins=6, e_ins=1, a=1;

    long fails = 0, checked = 0, with_start = 0;
    for (int it = 0; it < trials; ++it) {
        int qlen = 1 + rnd() % 100;
        int tlen = 1 + rnd() % 150;
        // bias the query to be a (mutated) substring of the target so real
        // alignments occur, plus pure-random cases.
        std::vector<uint8_t> q(qlen), t(tlen);
        for (int i = 0; i < tlen; ++i) t[i] = rnd() % 4;
        bool embed = (rnd() & 1) && tlen >= qlen;
        if (embed) {
            int off = rnd() % (tlen - qlen + 1);
            for (int j = 0; j < qlen; ++j) {
                uint8_t base = t[off + j];
                uint32_t r = rnd() % 100;
                if (r < 12) base = rnd() % 4;        // ~12% mismatch
                else if (r < 16) base = 4;            // a few N
                q[j] = base;
            }
        } else {
            for (int j = 0; j < qlen; ++j) q[j] = rnd() % 5;   // includes N
        }
        // xtra like mem_matesw: XSUBO|XSTART|XBYTE | (min_seed_len*a)
        int min_seed_len = (int)(rnd() % 40);   // vary the subo threshold incl. 0
        int xtra = KSW_XSUBO | KSW_XSTART | KSW_XBYTE | (min_seed_len * a);

        // reference (ksw_align2 mutates query/target via revseq then restores; pass copies)
        std::vector<uint8_t> qr = q, tr = t;
        kswr_t ref = ksw_align2(qlen, qr.data(), tlen, tr.data(), 5, mat,
                                o_del, e_del, o_ins, e_ins, xtra, 0);
        HR hw = hw_align2(qlen, q.data(), tlen, t.data(), mat, o_del, e_del, o_ins, e_ins, xtra);

        checked++;
        if (ref.qb >= 0) with_start++;
        bool bad = (hw.score != ref.score) || (hw.te != ref.te) || (hw.qe != ref.qe) ||
                   (hw.tb != ref.tb) || (hw.qb != ref.qb);
        if (bad) {
            fails++;
            if (fails <= 15)
                printf("MISMATCH it=%d qlen=%d tlen=%d subo=%d | "
                       "score %d/%d te %d/%d qe %d/%d tb %d/%d qb %d/%d\n",
                       it, qlen, tlen, min_seed_len,
                       hw.score, ref.score, hw.te, ref.te, hw.qe, ref.qe,
                       hw.tb, ref.tb, hw.qb, ref.qb);
        }
    }
    printf("cross_check: %ld trials, %ld with start-pass, %ld failures -> %s\n",
           checked, with_start, fails, fails == 0 ? "ALL PASS" : "FAIL");
    return fails == 0 ? 0 : 1;
}
