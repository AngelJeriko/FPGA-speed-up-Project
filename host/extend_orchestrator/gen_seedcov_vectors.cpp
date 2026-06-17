// gen_seedcov_vectors.cpp — per-alnreg seedcov vectors for orch_seedcov.sv.
// seedcov = sum of seed.len over chain seeds fully contained in the alnreg's
// final [qb,qe) x [rb,re). One record per alnreg (carries its chain's seed list).
//
//   make seedcov     # writes vectors/seedcov_vectors.txt
//
// Flat decimal token stream (newlines cosmetic):
//   count
//   per alnreg: qb qe rb re nseeds  (rbeg qbeg len)*nseeds  expected_seedcov
#include <cstdio>
#include <vector>
#include "parse.h"

int main(int argc, char **argv) {
    const char *in  = argc > 1 ? argv[1] : "vectors/ext_vec.bin";
    const char *out = argc > 2 ? argv[2] : "vectors/seedcov_vectors.txt";
    std::vector<ReadVec> reads = load_reads(in);
    if (reads.empty()) { fprintf(stderr, "no reads from %s\n", in); return 2; }

    FILE *f = fopen(out, "w");
    if (!f) { fprintf(stderr, "cannot write %s\n", out); return 2; }

    // first pass: count alnregs (= total seeds)
    long count = 0, seed_entries = 0;
    std::vector<std::vector<std::vector<int>>> seed_alns(reads.size());
    std::vector<std::vector<Alnreg>> avs(reads.size());
    for (size_t ri = 0; ri < reads.size(); ++ri) {
        avs[ri] = extend_only(reads[ri], seed_alns[ri]);
        for (const Chain &c : reads[ri].chains) { count += c.seeds.size();
                                                  seed_entries += (long)c.seeds.size()*c.seeds.size(); }
    }
    fprintf(f, "%ld\n", count);
    for (size_t ri = 0; ri < reads.size(); ++ri) {
        const ReadVec &rv = reads[ri];
        for (size_t cj = 0; cj < rv.chains.size(); ++cj) {
            const Chain &c = rv.chains[cj];
            for (size_t si = 0; si < c.seeds.size(); ++si) {
                const Alnreg &A = avs[ri][seed_alns[ri][cj][si]];
                fprintf(f, "%d %d %lld %lld %zu", A.qb, A.qe, (long long)A.rb,
                        (long long)A.re, c.seeds.size());
                for (const Seed &t : c.seeds)
                    fprintf(f, " %lld %d %d", (long long)t.rbeg, t.qbeg, t.len);
                fprintf(f, " %d\n", A.seedcov);
            }
        }
    }
    fclose(f);
    printf("seedcov vectors: %ld alnregs, %ld seed-entries -> %s\n",
           count, seed_entries, out);
    return 0;
}
