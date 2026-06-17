// gen_window_vectors.cpp — descriptors for the window-builder (orch_window.sv).
// For each seed, the left/right extension windows are slices of the read query and
// the chain reference window, in the order bsw_top consumes them:
//   Lq: query[qbeg-1 .. 0]            (reversed),   len qbeg        (if qbeg>0)
//   Lr: ref[tmp-1 .. 0]               (reversed),   len tmp=rbeg-rmax0
//   Rq: query[qe0 .. l_query-1]       (forward),    len l_query-qe0 (if qe0!=l_query)
//   Rr: ref[re0 .. (rmax1-rmax0)-1]   (forward),    len (rmax1-rmax0)-re0
// where qe0=qbeg+len, re0=rbeg+len-rmax0. We emit the geometry (start,len per
// window + need flags); the TB expands to the expected source-address stream.
//
//   make window     # writes vectors/window_vectors.txt
//
// Flat decimal: count, then per seed:
//   rbeg qbeg len rmax0 rmax1 l_query
//   need_left Lq_start Lq_len Lr_start Lr_len  need_right Rq_start Rq_len Rr_start Rr_len
#include <cstdio>
#include <vector>
#include "parse.h"

int main(int argc, char **argv) {
    const char *in  = argc > 1 ? argv[1] : "vectors/ext_vec.bin";
    const char *out = argc > 2 ? argv[2] : "vectors/window_vectors.txt";
    std::vector<ReadVec> reads = load_reads(in);
    if (reads.empty()) { fprintf(stderr, "no reads from %s\n", in); return 2; }
    FILE *f = fopen(out, "w");
    if (!f) { fprintf(stderr, "cannot write %s\n", out); return 2; }

    long count = 0;
    for (const ReadVec &rv : reads) for (const Chain &c : rv.chains) count += c.seeds.size();
    fprintf(f, "%ld\n", count);

    for (const ReadVec &rv : reads) {
        const int l_query = rv.l_query;
        for (const Chain &c : rv.chains) {
            for (const Seed &s : c.seeds) {
                int     need_left  = (s.qbeg != 0);
                int64_t tmp        = s.rbeg - c.rmax0;
                int     qe0        = s.qbeg + s.len;
                int64_t re0        = s.rbeg + s.len - c.rmax0;
                int     need_right = (qe0 != l_query);
                int64_t len2       = l_query - qe0;
                int64_t len1       = (c.rmax1 - c.rmax0) - re0;
                long Lq_start = s.qbeg - 1,        Lq_len = need_left  ? s.qbeg : 0;
                long Lr_start = (long)tmp - 1,     Lr_len = need_left  ? (long)tmp  : 0;
                long Rq_start = qe0,               Rq_len = need_right ? (long)len2 : 0;
                long Rr_start = (long)re0,         Rr_len = need_right ? (long)len1 : 0;
                fprintf(f, "%lld %d %d %lld %lld %d  %d %ld %ld %ld %ld  %d %ld %ld %ld %ld\n",
                        (long long)s.rbeg, s.qbeg, s.len, (long long)c.rmax0,
                        (long long)c.rmax1, l_query,
                        need_left,  Lq_start, Lq_len, Lr_start, Lr_len,
                        need_right, Rq_start, Rq_len, Rr_start, Rr_len);
            }
        }
    }
    fclose(f);
    printf("window vectors: %ld seeds -> %s\n", count, out);
    return 0;
}
