// gen_ext_vectors.cpp — per-extension golden vectors for the resized bsw_top.
//
// For each left/right extension (replaying extend_only's exact window setup and
// h0 threading), emit the windowed query + target bytes, the SW config, and the
// EXPECTED outputs from ksw_extend2 run at an effectively-infinite band
// (w=BIG) — which is exactly what the full-rectangle systolic array computes
// (end_bonus only clamps ksw's band to ~qlen, i.e. full query coverage). The
// RTL tb (tb_bsw_ext) packs each vector into bsw_top and checks bit-exact.
//
// Subsetting (the full set is 747,258 extensions): keep ALL extensions with a
// large target (tlen >= TAIL_MIN) — those exercise the resize most — and sample
// the rest at 1/SAMPLE. Keeps the vector file modest while covering the tail.
//
// Output (text, whitespace-separated):
//   <count>
//   per extension:
//     side qlen tlen h0 end_bonus o_del e_del o_ins e_ins zdrop \
//        exp_score exp_qle exp_tle exp_gscore exp_gtle exp_maxoff
//     q[0..qlen-1]
//     t[0..tlen-1]
#include <cstdio>
#include <cstdlib>
#include <vector>
#include <string>
#include "parse.h"

static const int BIG = 1000000;
static const int TAIL_MIN = 320;   // keep every extension with tlen >= this
static const int SAMPLE   = 100;   // sample 1/SAMPLE of the rest
// Debug: set SMALLQ/SMALLT env to keep ONLY extensions with qlen<=SMALLQ &&
// tlen<=SMALLT (no sampling) — for isolating small failing cases.
static int SMALLQ = 0, SMALLT = 0;

struct K { int sc, qle, tle, gtle, gscore, maxoff; };
static K run(int qlen, const uint8_t*q, int tlen, const uint8_t*t,
             const Cfg&o, int eb, int h0) {
    K k{};
    k.sc = ksw_extend2(qlen, q, tlen, t, 5, o.mat, o.o_del, o.e_del, o.o_ins,
                       o.e_ins, BIG, eb, o.zdrop, h0, &k.qle, &k.tle, &k.gtle,
                       &k.gscore, &k.maxoff);
    return k;
}

int main(int argc, char** argv) {
    if (argc < 3) { fprintf(stderr, "usage: %s vectors.bin out.txt\n", argv[0]); return 1; }
    if (getenv("SMALLQ")) SMALLQ = atoi(getenv("SMALLQ"));
    if (getenv("SMALLT")) SMALLT = atoi(getenv("SMALLT"));
    const bool small_mode = (SMALLQ && SMALLT);
    auto reads = load_reads(argv[1]);
    FILE* out = fopen(argv[2], "w");
    if (!out) { fprintf(stderr, "cannot open %s\n", argv[2]); return 1; }

    // collect into a buffer so we can write the count first
    std::string buf; buf.reserve(64<<20);
    char line[256];
    long n = 0, sample_ctr = 0;

    auto emit = [&](int side, int qlen, const uint8_t* q, int tlen,
                    const uint8_t* t, const Cfg& o, int eb, int h0, const K& k) {
        snprintf(line, sizeof line,
            "%d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d\n",
            side, qlen, tlen, h0, eb, o.o_del, o.e_del, o.o_ins, o.e_ins, o.zdrop,
            k.sc, k.qle, k.tle, k.gscore, k.gtle, k.maxoff);
        buf += line;
        for (int i = 0; i < qlen; ++i) { snprintf(line, sizeof line, "%d ", q[i]); buf += line; }
        buf += '\n';
        for (int i = 0; i < tlen; ++i) { snprintf(line, sizeof line, "%d ", t[i]); buf += line; }
        buf += '\n';
        n++;
    };

    for (auto& rv : reads) {
        const Cfg& o = rv.cfg;
        const int lq = rv.l_query;
        for (auto& c : rv.chains) {
            for (auto& s : c.seeds) {
                int score = -1;
                // ---- left ----
                if (s.qbeg) {
                    const int64_t tmp = s.rbeg - c.rmax0;
                    std::vector<uint8_t> qs(s.qbeg), rs(tmp > 0 ? tmp : 0);
                    for (int i = 0; i < s.qbeg; ++i) qs[i] = rv.query[s.qbeg-1-i];
                    for (int64_t i = 0; i < tmp; ++i) rs[i] = c.ref[tmp-1-i];
                    int h0 = s.len * o.a;
                    K k = run(s.qbeg, qs.data(), (int)tmp, rs.data(), o, o.pen_clip5, h0);
                    bool keep = small_mode ? (s.qbeg <= SMALLQ && (int)tmp <= SMALLT)
                                           : (((int)tmp >= TAIL_MIN) || (sample_ctr++ % SAMPLE == 0));
                    if (keep) emit(0, s.qbeg, qs.data(), (int)tmp, rs.data(), o, o.pen_clip5, h0, k);
                    score = k.sc;
                } else {
                    score = s.len * o.a;
                }
                // ---- right ----
                const int qe0 = s.qbeg + s.len;
                const int64_t re0 = s.rbeg + s.len - c.rmax0;
                if (qe0 != lq) {
                    const int len2 = lq - qe0;
                    const int64_t len1 = c.rmax1 - c.rmax0 - re0;
                    std::vector<uint8_t> qs(len2), rs(len1 > 0 ? len1 : 0);
                    for (int i = 0; i < len2; ++i) qs[i] = rv.query[qe0+i];
                    for (int64_t i = 0; i < len1; ++i) rs[i] = c.ref[re0+i];
                    int h0 = score;
                    K k = run(len2, qs.data(), (int)len1, rs.data(), o, o.pen_clip3, h0);
                    bool keep = small_mode ? (len2 <= SMALLQ && (int)len1 <= SMALLT)
                                           : (((int)len1 >= TAIL_MIN) || (sample_ctr++ % SAMPLE == 0));
                    if (keep) emit(1, len2, qs.data(), (int)len1, rs.data(), o, o.pen_clip3, h0, k);
                }
            }
        }
    }

    fprintf(out, "%ld\n", n);
    fwrite(buf.data(), 1, buf.size(), out);
    fclose(out);
    fprintf(stderr, "wrote %ld extension vectors to %s\n", n, argv[2]);
    return 0;
}
