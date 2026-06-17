// gen_asm_vectors.cpp — emit per-alnreg assembly vectors for the RTL assembly
// datapath (orch_assemble.sv). Each line: the SW results (left/right) + seed/cfg
// inputs and the expected assembled fields rb/re/qb/qe/score/truesc/w (seedcov is
// tested separately — it needs the chain seed list).
//
//   make asm     # writes vectors/asm_vectors.txt
//
// Line format (decimal, space-separated):
//   need_left need_right l_query a w pen5 pen3 rbeg rmax0 qbeg len rid
//   Lscore Lqle Ltle Lgscore Lgtle Lw  Rscore Rqle Rtle Rgscore Rgtle Rw
//   rb re qb qe score truesc wout
#include <cstdio>
#include <vector>
#include "parse.h"

int main(int argc, char **argv) {
    const char *in  = argc > 1 ? argv[1] : "vectors/ext_vec.bin";
    const char *out = argc > 2 ? argv[2] : "vectors/asm_vectors.txt";
    std::vector<ReadVec> reads = load_reads(in);
    if (reads.empty()) { fprintf(stderr, "no reads from %s\n", in); return 2; }

    std::vector<AsmVec> all;
    for (const ReadVec &rv : reads) {
        std::vector<std::vector<int>> seed_aln;
        extend_only(rv, seed_aln, &all);
    }
    FILE *f = fopen(out, "w");
    if (!f) { fprintf(stderr, "cannot write %s\n", out); return 2; }
    fprintf(f, "%zu\n", all.size());
    for (const AsmVec &t : all) {
        fprintf(f, "%d %d %d %d %d %d %d %lld %lld %d %d %d  %d %d %d %d %d %d  %d %d %d %d %d %d  %lld %lld %d %d %d %d %d\n",
            t.need_left, t.need_right, t.l_query, t.a, t.w, t.pen_clip5, t.pen_clip3,
            (long long)t.rbeg, (long long)t.rmax0, t.qbeg, t.len, t.rid,
            t.left.score, t.left.qle, t.left.tle, t.left.gscore, t.left.gtle, t.left.w,
            t.right.score, t.right.qle, t.right.tle, t.right.gscore, t.right.gtle, t.right.w,
            (long long)t.rb, (long long)t.re, t.qb, t.qe, t.score, t.truesc, t.wout);
    }
    fclose(f);
    printf("assembly vectors: %zu -> %s\n", all.size(), out);
    return 0;
}
