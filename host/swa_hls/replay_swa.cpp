// replay_swa.cpp -- replay a BSWCAP01 golden capture through the scalar
// reference model (ksw.h :: ksw_extend2) and diff all six outputs.
//
// This is the acceptance test for host/bwamem2_patch/swa_capture.inc: it
// proves the captured records are a faithful, self-contained description of
// bwa-mem2's real extension kernel, and that the C model this project uses
// as its numeric reference reproduces them bit-for-bit. The HLS kernel is
// then held to this same file.
//
//   g++ -O2 -std=c++17 -I../extend_orchestrator -o replay_swa replay_swa.cpp
//   ./replay_swa ecoli_swa.bin [--verbose] [--limit N]
#include "ksw.h"
#include <cstdio>
#include <cstring>
#include <vector>
#include <string>

namespace {

struct Hdr {
    int32_t m;
    int8_t  mat[25];
    int32_t a, b, o_del, e_del, o_ins, e_ins, zdrop, pen_clip5, pen_clip3, w_base;
};

struct Rec {
    uint8_t side, route;
    int16_t band_try;
    int32_t w, qlen, tlen, h0;
    int32_t score, qle, tle, gtle, gscore, max_off;
    std::vector<uint8_t> query, target;
};

class Reader {
public:
    explicit Reader(const char *p) : f_(fopen(p, "rb")), path_(p) {}
    ~Reader() { if (f_) fclose(f_); }
    bool ok() const { return f_ != nullptr; }

    bool header(Hdr &h) {
        char magic[8];
        if (!rd(magic, 8)) return false;
        if (memcmp(magic, "BSWCAP01", 8) != 0) {
            fprintf(stderr, "%s: bad magic\n", path_); return false;
        }
        return rd(&h.m, 4) && rd(h.mat, 25) && rd(&h.a, 4) && rd(&h.b, 4) &&
               rd(&h.o_del, 4) && rd(&h.e_del, 4) && rd(&h.o_ins, 4) &&
               rd(&h.e_ins, 4) && rd(&h.zdrop, 4) && rd(&h.pen_clip5, 4) &&
               rd(&h.pen_clip3, 4) && rd(&h.w_base, 4);
    }

    // returns 1 = record, 0 = clean EOF, -1 = truncated
    int record(Rec &r) {
        if (fread(&r.side, 1, 1, f_) != 1) return feof(f_) ? 0 : -1;
        if (!(rd(&r.route, 1) && rd(&r.band_try, 2) && rd(&r.w, 4) &&
              rd(&r.qlen, 4) && rd(&r.tlen, 4) && rd(&r.h0, 4) &&
              rd(&r.score, 4) && rd(&r.qle, 4) && rd(&r.tle, 4) &&
              rd(&r.gtle, 4) && rd(&r.gscore, 4) && rd(&r.max_off, 4)))
            return -1;
        if (r.qlen < 0 || r.tlen < 0 || r.qlen > (1 << 20) || r.tlen > (1 << 20))
            return -1;
        r.query.resize(r.qlen);
        r.target.resize(r.tlen);
        if (!rd(r.query.data(), r.qlen) || !rd(r.target.data(), r.tlen)) return -1;
        return 1;
    }

private:
    template <class T> bool rd(T *dst, size_t n) { return fread(dst, 1, n, f_) == n; }
    FILE *f_;
    const char *path_;
};

struct Stats {
    uint64_t n = 0, bad = 0;
    int32_t  max_qlen = 0, max_tlen = 0, max_w = 0, max_h0 = 0, max_band_try = 0;
    uint64_t by_route[3] = {0, 0, 0};   // S, 1, 8
};

} // namespace

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: replay_swa <capture.bin> [--verbose] [--limit N]\n"); return 2; }
    bool verbose = false;
    uint64_t limit = UINT64_MAX;
    const char *extract = nullptr;
    bool extract_all = false;   // --extract writes every record, not just failures
    for (int i = 2; i < argc; i++) {
        if (!strcmp(argv[i], "--verbose")) verbose = true;
        else if (!strcmp(argv[i], "--limit") && i + 1 < argc) limit = strtoull(argv[++i], nullptr, 10);
        else if (!strcmp(argv[i], "--extract") && i + 1 < argc) extract = argv[++i];
        else if (!strcmp(argv[i], "--extract-all")) extract_all = true;
    }

    Reader in(argv[1]);
    if (!in.ok()) { fprintf(stderr, "cannot open %s\n", argv[1]); return 2; }

    Hdr h;
    if (!in.header(h)) { fprintf(stderr, "bad header\n"); return 2; }

    printf("capture : %s\n", argv[1]);
    printf("scoring : a=%d b=%d o_del=%d e_del=%d o_ins=%d e_ins=%d zdrop=%d\n",
           h.a, h.b, h.o_del, h.e_del, h.o_ins, h.e_ins, h.zdrop);
    printf("          pen_clip5=%d pen_clip3=%d w_base=%d m=%d\n\n",
           h.pen_clip5, h.pen_clip3, h.w_base, h.m);

    // the matrix in the file must be the one bwa derives from (a,b)
    int8_t ref_mat[25];
    bwa_fill_scmat(h.a, h.b, ref_mat);
    if (memcmp(ref_mat, h.mat, 25) != 0) {
        printf("FAIL: captured scoring matrix != bwa_fill_scmat(%d,%d)\n", h.a, h.b);
        return 1;
    }

    // --extract writes the divergent records back out as a BSWCAP01 file, so
    // they become a standalone, replayable regression vector set.
    FILE *ex = nullptr;
    if (extract) {
        ex = fopen(extract, "wb");
        if (!ex) { fprintf(stderr, "cannot open %s for writing\n", extract); return 2; }
        int32_t v;
        fwrite("BSWCAP01", 1, 8, ex);
        v = h.m; fwrite(&v, 4, 1, ex);
        fwrite(h.mat, 1, 25, ex);
        const int32_t hf[] = {h.a, h.b, h.o_del, h.e_del, h.o_ins, h.e_ins,
                              h.zdrop, h.pen_clip5, h.pen_clip3, h.w_base};
        fwrite(hf, 4, 10, ex);
    }

    Stats st;
    Rec r;
    int rc;
    while (st.n < limit && (rc = in.record(r)) == 1) {
        st.n++;
        st.by_route[r.route == 'S' ? 0 : r.route == '1' ? 1 : 2]++;
        if (r.qlen > st.max_qlen) st.max_qlen = r.qlen;
        if (r.tlen > st.max_tlen) st.max_tlen = r.tlen;
        if (r.w > st.max_w) st.max_w = r.w;
        if (r.h0 > st.max_h0) st.max_h0 = r.h0;
        if (r.band_try > st.max_band_try) st.max_band_try = r.band_try;

        const int end_bonus = (r.side == 'L') ? h.pen_clip5 : h.pen_clip3;
        int qle = -1, tle = -1, gtle = -1, gscore = -1, max_off = -1;
        const int score = ksw_extend2(r.qlen, r.query.data(), r.tlen, r.target.data(),
                                      h.m, h.mat, h.o_del, h.e_del, h.o_ins, h.e_ins,
                                      r.w, end_bonus, h.zdrop, r.h0,
                                      &qle, &tle, &gtle, &gscore, &max_off);

        auto emit = [&](FILE *o) {
            fwrite(&r.side, 1, 1, o); fwrite(&r.route, 1, 1, o);
            fwrite(&r.band_try, 2, 1, o);
            const int32_t rf[] = {r.w, r.qlen, r.tlen, r.h0, r.score,
                                  r.qle, r.tle, r.gtle, r.gscore, r.max_off};
            fwrite(rf, 4, 10, o);
            fwrite(r.query.data(), 1, (size_t)r.qlen, o);
            fwrite(r.target.data(), 1, (size_t)r.tlen, o);
        };
        if (ex && extract_all) emit(ex);

        const bool match = score == r.score && qle == r.qle && tle == r.tle &&
                           gtle == r.gtle && gscore == r.gscore && max_off == r.max_off;
        if (!match) {
            st.bad++;
            if (ex && !extract_all) emit(ex);
            if (verbose || st.bad <= 10) {
                printf("MISMATCH #%llu  side=%c route=%c band_try=%d w=%d qlen=%d tlen=%d h0=%d\n",
                       (unsigned long long)st.n, r.side, r.route, r.band_try,
                       r.w, r.qlen, r.tlen, r.h0);
                printf("   golden: score=%d qle=%d tle=%d gtle=%d gscore=%d max_off=%d\n",
                       r.score, r.qle, r.tle, r.gtle, r.gscore, r.max_off);
                printf("   model : score=%d qle=%d tle=%d gtle=%d gscore=%d max_off=%d\n",
                       score, qle, tle, gtle, gscore, max_off);
            }
        }
    }
    if (rc < 0) { printf("FAIL: truncated record after %llu\n", (unsigned long long)st.n); return 1; }

    if (ex) { fclose(ex); printf("extracted %llu %s records -> %s\n",
                                 (unsigned long long)(extract_all ? st.n : st.bad),
                                 extract_all ? "" : "divergent", extract); }
    printf("records : %llu   (scalar=%llu  simd16=%llu  simd8=%llu)\n",
           (unsigned long long)st.n, (unsigned long long)st.by_route[0],
           (unsigned long long)st.by_route[1], (unsigned long long)st.by_route[2]);
    printf("envelope: max qlen=%d  max tlen=%d  max w=%d  max h0=%d  max band_try=%d\n",
           st.max_qlen, st.max_tlen, st.max_w, st.max_h0, st.max_band_try);
    printf("\n%s: %llu/%llu bit-exact, %llu mismatches\n",
           st.bad ? "FAIL" : "PASS",
           (unsigned long long)(st.n - st.bad), (unsigned long long)st.n,
           (unsigned long long)st.bad);
    return st.bad ? 1 : 0;
}
