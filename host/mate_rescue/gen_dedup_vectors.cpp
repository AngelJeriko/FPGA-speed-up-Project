// gen_dedup_vectors.cpp — golden vectors for tb_matesw_dedup (the RTL mate-rescue
// mem_sort_dedup_patch). Expected outputs come from orch.h::mr_dedup. Builds small
// alnreg arrays with overlapping/identical members to exercise the stable re-sort,
// the integer redundancy de-overlap, and the identical-hit removal. Coordinates are
// kept < 2^30 so 32-bit TB reads suffice.
//
// Output:
//   <count>
//   per case:
//     n_in
//     n_in * { rb re qb qe rid score cov }
//     n_out fb            (fb = dedup sort-key tie -> SW-fallback, mr_dedup's flag)
//     n_out * { rb re qb qe rid score cov }
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <vector>
#include <string>
#include "macro.h"
#include "orch.h"

uint64_t tprof[LIM_R][LIM_C];

static uint64_t st = 0xdeadbeefcafef00dull;
static inline uint32_t rnd() { st = st*6364136223846793005ull + 1442695040888963407ull; return (uint32_t)(st>>33); }

static void emit(std::string& buf, const MAln& m) {
    char line[160];
    snprintf(line, sizeof line, "%lld %lld %d %d %d %d %d\n",
             (long long)m.rb, (long long)m.re, m.qb, m.qe, m.rid, m.score, m.seedcov);
    buf += line;
}

int main(int argc, char** argv) {
    if (argc < 2) { fprintf(stderr, "usage: %s out.txt [n]\n", argv[0]); return 1; }
    int n = argc > 2 ? atoi(argv[2]) : 6000;
    MOpt o;

    std::string buf; buf.reserve(8<<20);
    long touched = 0;
    for (int it = 0; it < n; ++it) {
        int nn = rnd() % 20;                       // 0..19
        std::vector<MAln> a;
        for (int k = 0; k < nn; ++k) {
            MAln m{};
            // cluster around a few bases to force overlaps within the chain-gap window
            int64_t base = (int64_t)(rnd() % 3) * 2000;
            m.rid   = rnd() % 2;
            m.rb    = base + (int64_t)(rnd() % 400);
            int len = 20 + rnd() % 200;
            m.re    = m.rb + len;
            m.qb    = rnd() % 120;
            m.qe    = m.qb + (20 + rnd() % 150);
            m.score = 10 + rnd() % 90;
            m.seedcov = rnd() % 60;
            // ~15%: duplicate a previous record verbatim (exercise identical removal)
            if (!a.empty() && (rnd() % 100) < 15) m = a[rnd() % a.size()];
            a.push_back(m);
        }
        std::vector<MAln> in = a;
        bool fb = false;
        int m_out = mr_dedup(o, a, &fb);           // a now holds survivors [0..m_out)
        if (m_out != (int)in.size()) touched++;

        char hdr[32]; snprintf(hdr, sizeof hdr, "%d\n", (int)in.size()); buf += hdr;
        for (auto& m : in) emit(buf, m);
        snprintf(hdr, sizeof hdr, "%d %d\n", m_out, fb?1:0); buf += hdr;
        for (int k = 0; k < m_out; ++k) emit(buf, a[k]);
    }
    FILE* out = fopen(argv[1], "w");
    fprintf(out, "%d\n", n);
    fwrite(buf.data(), 1, buf.size(), out);
    fclose(out);
    fprintf(stderr, "wrote %d dedup vectors (%ld changed n) to %s\n", n, touched, argv[1]);
    return 0;
}
