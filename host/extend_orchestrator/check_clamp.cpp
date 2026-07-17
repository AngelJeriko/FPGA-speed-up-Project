// check_clamp.cpp — validate the contig-clamp model (bns_clamp.h) BIT-EXACT vs real bwa-mem2.
// Consumes the 4th capture (clamp_vec.bin, from capture/clamp_capture.inc) and replays every
// captured bns_fetch_seq_v2 call through bns_clamp, comparing the clamped beg/end/rid to what
// real bwa-mem2 produced. This is the confidence half of Decision F (§4-F): the directed test
// (test_bns_clamp) proves hand-derived edge cases; this proves the model on the real distribution.
//
// The contig table comes from the .ann file (same reference the capture ran on: chr1-5). Each
// record also carries the returned window bytes (for the future A1 byte-fetch); this validator
// checks the clamp only and reports byte-coverage stats.
//
// Build: make checkclamp    Run: ./check_clamp [clamp_vec.bin] [hg38_chr1-5.fa.ann]
#include "bns_clamp.h"
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <string>
#include <vector>

template <class T> static bool rd(FILE* f, T& v) { return fread(&v, sizeof(T), 1, f) == 1; }

int main(int argc, char** argv) {
    const char* vec = (argc > 1) ? argv[1] : "vectors/clamp_vec.bin";
    const char* ann = (argc > 2) ? argv[2] : "/home/ccloud/ref/hg38_chr1-5.fa.ann";

    BnsTable t;
    if (!bns_load_ann(ann, t)) { fprintf(stderr, "cannot load .ann: %s\n", ann); return 2; }
    printf("[table] l_pac=%lld n_seqs=%zu\n", (long long)t.l_pac, t.anns.size());

    FILE* f = fopen(vec, "rb");
    if (!f) { fprintf(stderr, "cannot open capture: %s\n", vec); return 2; }

    long n = 0, pass = 0, fail = 0, lpac_mismatch = 0;
    long clamped_beg = 0, clamped_end = 0, rev = 0;   // how many records actually got clamped / are rev
    long fail_shown = 0;
    int64_t max_win = 0; double sum_win = 0;

    for (;;) {
        int32_t type;
        if (!rd(f, type)) break;                       // clean EOF
        int64_t cid, lpac, beg_in, mid, end_in, beg_out, end_out;
        int32_t rid, nbytes;
        if (!rd(f, cid) || !rd(f, lpac) || !rd(f, beg_in) || !rd(f, mid) || !rd(f, end_in) ||
            !rd(f, beg_out) || !rd(f, end_out) || !rd(f, rid) || !rd(f, nbytes)) {
            fprintf(stderr, "truncated record at n=%ld\n", n); break;
        }
        std::vector<uint8_t> bytes(nbytes > 0 ? nbytes : 0);
        if (nbytes > 0 && fread(bytes.data(), 1, nbytes, f) != (size_t)nbytes) {
            fprintf(stderr, "truncated bytes at n=%ld\n", n); break;
        }
        ++n;
        if (lpac != t.l_pac) ++lpac_mismatch;

        // Replay through the model.
        int64_t m_beg = beg_in, m_end = end_in;
        int m_rid = -99, m_rev = -99;
        int64_t m_len = bns_clamp(t, m_beg, mid, m_end, m_rid, m_rev);

        bool ok = (m_beg == beg_out) && (m_end == end_out) && (m_rid == rid) &&
                  (m_len == end_out - beg_out);
        if (ok) ++pass;
        else {
            ++fail;
            if (fail_shown++ < 10) {
                printf("  FAIL cid=%lld  in[beg=%lld mid=%lld end=%lld]\n",
                       (long long)cid, (long long)beg_in, (long long)mid, (long long)end_in);
                printf("       bwa   beg=%lld end=%lld rid=%d\n",
                       (long long)beg_out, (long long)end_out, rid);
                printf("       model beg=%lld end=%lld rid=%d rev=%d len=%lld\n",
                       (long long)m_beg, (long long)m_end, m_rid, m_rev, (long long)m_len);
            }
        }
        if (beg_out != beg_in) ++clamped_beg;          // clamp moved the start
        if (end_out != end_in) ++clamped_end;          // clamp moved the end
        if (m_rev) ++rev;
        int64_t w = end_out - beg_out;
        if (w > max_win) max_win = w;
        sum_win += (double)w;
    }
    fclose(f);

    printf("\n[coverage] records=%ld  clamped_beg=%ld  clamped_end=%ld  reverse_strand=%ld\n",
           n, clamped_beg, clamped_end, rev);
    printf("[coverage] window bytes: mean=%.1f max=%lld\n", n ? sum_win / n : 0.0, (long long)max_win);
    if (lpac_mismatch) printf("[WARN] %ld records had l_pac != table (wrong reference?)\n", lpac_mismatch);
    printf("\n%s: %ld passed, %ld failed (of %ld)\n",
           fail == 0 ? "ALL PASS" : "FAILURES", pass, fail, n);
    return fail == 0 ? 0 : 1;
}
