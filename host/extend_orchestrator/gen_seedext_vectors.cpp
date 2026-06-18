// gen_seedext_vectors.cpp — per-seed golden for tb_bsw_seed_unit.
//
// For each seed, emit the unit's inputs (seed/chain geometry + cfg, the read's
// query bases, the chain's reference window) and the EXPECTED assembled alnreg
// (rb/re/qb/qe/score/truesc/w) = exactly what extend_only() produces pre-purge
// for that seed. Build with -DHWMODEL so band_extend uses the full-rectangle
// array model (hw.h) that bsw_top reproduces bit-exactly.
//
// Subset (565,446 seeds total, each a full SW run): keep every seed whose larger
// window target length >= TAIL_MIN (exercises the resize) plus 1/SAMPLE of the
// rest.
//
// Output (text):
//   <count>
//   per seed:
//     l_query a o_del e_del o_ins e_ins zdrop w pen5 pen3 \
//     rbeg qbeg len rid rmax0 rmax1 reflen \
//     exp_rb exp_re exp_qb exp_qe exp_score exp_truesc exp_w
//     query[0..l_query-1]
//     ref[0..reflen-1]
#include <cstdio>
#include <cstdlib>
#include <vector>
#include <string>
#include "parse.h"

static const int TAIL_MIN = 320, SAMPLE = 80;

int main(int argc, char** argv) {
    if (argc < 3) { fprintf(stderr, "usage: %s vectors.bin out.txt\n", argv[0]); return 1; }
    auto reads = load_reads(argv[1]);
    FILE* out = fopen(argv[2], "w");
    if (!out) { fprintf(stderr, "cannot open %s\n", argv[2]); return 1; }

    std::string buf; buf.reserve(64<<20);
    char line[512];
    long n = 0, sctr = 0;

    for (auto& rv : reads) {
        const Cfg& o = rv.cfg;
        std::vector<std::vector<int>> seed_aln;
        std::vector<Alnreg> av = extend_only(rv, seed_aln);   // HWMODEL -> hw.h
        for (size_t cj = 0; cj < rv.chains.size(); ++cj) {
            const Chain& c = rv.chains[cj];
            for (size_t si = 0; si < c.seeds.size(); ++si) {
                const Seed& s = c.seeds[si];
                const int   tmp  = (int)(s.rbeg - c.rmax0);                    // left tlen
                const int   qe0  = s.qbeg + s.len;
                const long  re0  = s.rbeg + s.len - c.rmax0;
                const int   len1 = (qe0 != rv.l_query) ? (int)(c.rmax1 - c.rmax0 - re0) : 0;
                const int   big  = tmp > len1 ? tmp : len1;
                bool keep = (big >= TAIL_MIN) || (sctr++ % SAMPLE == 0);
                if (!keep) continue;

                const Alnreg& A = av[seed_aln[cj][si]];
                const int reflen = (int)c.ref.size();
                snprintf(line, sizeof line,
                    "%d %d %d %d %d %d %d %d %d %d %lld %d %d %d %lld %lld %d "
                    "%lld %lld %d %d %d %d %d\n",
                    rv.l_query, o.a, o.o_del, o.e_del, o.o_ins, o.e_ins, o.zdrop, o.w,
                    o.pen_clip5, o.pen_clip3,
                    (long long)s.rbeg, s.qbeg, s.len, c.rid,
                    (long long)c.rmax0, (long long)c.rmax1, reflen,
                    (long long)A.rb, (long long)A.re, A.qb, A.qe, A.score, A.truesc, A.w);
                buf += line;
                for (int i = 0; i < rv.l_query; ++i) { snprintf(line, sizeof line, "%d ", rv.query[i]); buf += line; }
                buf += '\n';
                for (int i = 0; i < reflen; ++i) { snprintf(line, sizeof line, "%d ", c.ref[i]); buf += line; }
                buf += '\n';
                n++;
            }
        }
    }
    fprintf(out, "%ld\n", n);
    fwrite(buf.data(), 1, buf.size(), out);
    fclose(out);
    fprintf(stderr, "wrote %ld seed vectors to %s\n", n, argv[2]);
    return 0;
}
