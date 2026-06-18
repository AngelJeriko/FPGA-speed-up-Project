// gen_chain_vectors.cpp — per-chain golden for tb_orch_chain_unit.
//
// For each chain, emit its inputs (cfg, geometry, seeds, query, ref window) and
// the EXPECTED pre-purge alnregs in append order (= the chain's contiguous slice
// of extend_only()'s av). Build with -DHWMODEL so the expected values match the
// full-rectangle array (bsw_top). extend_only appends exactly n_seeds alnregs per
// chain, in seed-score-descending order, so chain cj's block is av[base .. base+n).
//
// Subset (chains can be very numerous): keep chains with many seeds / a large ref
// window (stress the sort + tail), plus a 1/SAMPLE sample of the rest.
//
// Output (text):
//   <count>
//   per chain:
//     l_query a o_del e_del o_ins e_ins zdrop w pen5 pen3 rid rmax0 rmax1 n_seeds reflen n_out
//     n_seeds * {rbeg qbeg len score}
//     query[0..l_query-1]
//     ref[0..reflen-1]
//     n_out * {rb re qb qe score truesc w seedcov seedlen0 rid}
#include <cstdio>
#include <cstdlib>
#include <vector>
#include <string>
#include "parse.h"

static const int SAMPLE = 120;

int main(int argc, char** argv) {
    if (argc < 3) { fprintf(stderr, "usage: %s vectors.bin out.txt\n", argv[0]); return 1; }
    auto reads = load_reads(argv[1]);
    FILE* out = fopen(argv[2], "w");
    if (!out) { fprintf(stderr, "cannot open %s\n", argv[2]); return 1; }

    std::string buf; buf.reserve(64<<20);
    char line[512];
    long n = 0, ctr = 0;

    for (auto& rv : reads) {
        const Cfg& o = rv.cfg;
        std::vector<std::vector<int>> seed_aln;
        std::vector<Alnreg> av = extend_only(rv, seed_aln);   // HWMODEL -> hw.h
        size_t base = 0;
        for (size_t cj = 0; cj < rv.chains.size(); ++cj) {
            const Chain& c = rv.chains[cj];
            const int n_seeds = (int)c.seeds.size();
            const int reflen  = (int)c.ref.size();
            bool keep = (n_seeds >= 8) || (reflen >= 400) || (ctr++ % SAMPLE == 0);
            if (keep) {
                snprintf(line, sizeof line,
                    "%d %d %d %d %d %d %d %d %d %d %d %lld %lld %d %d %d\n",
                    rv.l_query, o.a, o.o_del, o.e_del, o.o_ins, o.e_ins, o.zdrop, o.w,
                    o.pen_clip5, o.pen_clip3, c.rid,
                    (long long)c.rmax0, (long long)c.rmax1, n_seeds, reflen, n_seeds);
                buf += line;
                for (int i = 0; i < n_seeds; ++i) {
                    snprintf(line, sizeof line, "%lld %d %d %d\n",
                        (long long)c.seeds[i].rbeg, c.seeds[i].qbeg, c.seeds[i].len, c.seeds[i].score);
                    buf += line;
                }
                for (int i = 0; i < rv.l_query; ++i) { snprintf(line,sizeof line,"%d ",rv.query[i]); buf+=line; }
                buf += '\n';
                for (int i = 0; i < reflen; ++i) { snprintf(line,sizeof line,"%d ",c.ref[i]); buf+=line; }
                buf += '\n';
                for (int k = 0; k < n_seeds; ++k) {
                    const Alnreg& A = av[base + k];
                    snprintf(line, sizeof line, "%lld %lld %d %d %d %d %d %d %d %d\n",
                        (long long)A.rb, (long long)A.re, A.qb, A.qe, A.score, A.truesc,
                        A.w, A.seedcov, A.seedlen0, A.rid);
                    buf += line;
                }
                n++;
            }
            base += n_seeds;
        }
    }
    fprintf(out, "%ld\n", n);
    fwrite(buf.data(), 1, buf.size(), out);
    fclose(out);
    fprintf(stderr, "wrote %ld chain vectors to %s\n", n, argv[2]);
    return 0;
}
