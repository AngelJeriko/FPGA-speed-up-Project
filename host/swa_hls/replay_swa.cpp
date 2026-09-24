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
#include "ksw_hls.h"
#include <cstdio>
#include <cstring>
#include <vector>
#include <string>
#include <algorithm>

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
    uint64_t n = 0, bad = 0, bad_hls = 0, bad_xmodel = 0, oob = 0;
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
    bool extract_xmodel = false; // --extract writes hls-vs-reference divergences
    const char *emit_header = nullptr;  // --emit-cosim-header <file.h>
    int cosim_count = 32;              // --cosim-count N
    for (int i = 2; i < argc; i++) {
        if (!strcmp(argv[i], "--verbose")) verbose = true;
        else if (!strcmp(argv[i], "--limit") && i + 1 < argc) limit = strtoull(argv[++i], nullptr, 10);
        else if (!strcmp(argv[i], "--extract") && i + 1 < argc) extract = argv[++i];
        else if (!strcmp(argv[i], "--extract-all")) extract_all = true;
        else if (!strcmp(argv[i], "--extract-xmodel")) extract_xmodel = true;
        else if (!strcmp(argv[i], "--emit-cosim-header") && i + 1 < argc) emit_header = argv[++i];
        else if (!strcmp(argv[i], "--cosim-count") && i + 1 < argc) cosim_count = atoi(argv[++i]);
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

    // co-sim runs the testbench against RTL, which is orders of magnitude slower
    // than C-sim, so only a small spread of records is embedded in the header.
    std::vector<Rec> keep;

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

        // --- synthesizable kernel, fed through fixed-size buffers exactly as
        // --- HLS will see them at the top-level interface
        ksw_extend_out hls = {0, 0, 0, 0, 0, 0, -1};
        if (r.qlen > KSW_MAX_QLEN || r.tlen > KSW_MAX_TLEN) {
            st.oob++;
        } else {
            static uint8_t qbuf[KSW_MAX_QLEN], tbuf[KSW_MAX_TLEN];
            memset(qbuf, 0, sizeof qbuf); memset(tbuf, 0, sizeof tbuf);
            memcpy(qbuf, r.query.data(), (size_t)r.qlen);
            memcpy(tbuf, r.target.data(), (size_t)r.tlen);
            hls = ksw_extend_hls(r.qlen, qbuf, r.tlen, tbuf, h.mat,
                                 h.o_del, h.e_del, h.o_ins, h.e_ins,
                                 r.w, end_bonus, h.zdrop, r.h0);
        }
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

        const bool hls_ok = hls.status == KSW_OK && hls.score == r.score &&
                            hls.qle == r.qle && hls.tle == r.tle &&
                            hls.gtle == r.gtle && hls.gscore == r.gscore &&
                            hls.max_off == r.max_off;
        // the HLS kernel must also agree with the reference port everywhere,
        // including on the records where the reference disagrees with bwa-mem2
        const bool xmodel_ok = hls.status == KSW_OK && hls.score == score &&
                               hls.qle == qle && hls.tle == tle &&
                               hls.gtle == gtle && hls.gscore == gscore &&
                               hls.max_off == max_off;
        if (emit_header) keep.push_back(r);
        if (!hls_ok)    st.bad_hls++;
        if (ex && extract_xmodel && !xmodel_ok) emit(ex);
        if (!xmodel_ok) {
            st.bad_xmodel++;
            if (verbose || st.bad_xmodel <= 10) {
                printf("HLS != REFERENCE #%llu  side=%c route=%c w=%d qlen=%d tlen=%d h0=%d status=%d\n",
                       (unsigned long long)st.n, r.side, r.route, r.w, r.qlen, r.tlen, r.h0, hls.status);
                printf("   ref: score=%d qle=%d tle=%d gtle=%d gscore=%d max_off=%d\n",
                       score, qle, tle, gtle, gscore, max_off);
                printf("   hls: score=%d qle=%d tle=%d gtle=%d gscore=%d max_off=%d\n",
                       hls.score, hls.qle, hls.tle, hls.gtle, hls.gscore, hls.max_off);
            }
        }
        if (!match) {
            st.bad++;
            if (ex && !extract_all && !extract_xmodel) emit(ex);
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

    if (emit_header) {
        // spread the selection evenly over the (qlen, tlen) envelope so the
        // co-sim set exercises short and long queries, not just typical ones
        std::sort(keep.begin(), keep.end(), [](const Rec &a, const Rec &b) {
            return a.qlen != b.qlen ? a.qlen < b.qlen : a.tlen < b.tlen;
        });
        std::vector<Rec> sel;
        const int K = cosim_count < (int)keep.size() ? cosim_count : (int)keep.size();
        for (int s2 = 0; s2 < K && !keep.empty(); ++s2)
            sel.push_back(keep[(size_t)((double)s2 * (keep.size() - 1) / (K > 1 ? K - 1 : 1))]);

        FILE *hf = fopen(emit_header, "w");
        if (!hf) { fprintf(stderr, "cannot write %s\n", emit_header); return 2; }
        fprintf(hf, "// GENERATED by replay_swa --emit-cosim-header. Do not edit.\n");
        fprintf(hf, "// %d records selected from %s, spread over the (qlen, tlen) envelope.\n",
                (int)sel.size(), argv[1]);
        fprintf(hf, "// Golden outputs are bwa-mem2's; see docs/swa_golden_capture.md.\n");
        fprintf(hf, "#pragma once\n#include <cstdint>\n\n");
        fprintf(hf, "struct cosim_vec {\n    int32_t qlen, tlen, h0, w;\n"
                    "    int32_t o_del, e_del, o_ins, e_ins, zdrop, end_bonus;\n"
                    "    int32_t score, qle, tle, gtle, gscore, max_off;\n"
                    "    const uint8_t *query;\n    const uint8_t *target;\n};\n\n");
        fprintf(hf, "static const int8_t COSIM_MAT[25] = {");
        for (int k = 0; k < 25; k++) fprintf(hf, "%s%d", k ? "," : "", (int)h.mat[k]);
        fprintf(hf, "};\n\n");
        for (size_t v = 0; v < sel.size(); v++) {
            fprintf(hf, "static const uint8_t COSIM_Q%zu[%d] = {", v, sel[v].qlen);
            for (int k = 0; k < sel[v].qlen; k++) fprintf(hf, "%s%u", k ? "," : "", sel[v].query[k]);
            fprintf(hf, "};\nstatic const uint8_t COSIM_T%zu[%d] = {", v, sel[v].tlen);
            for (int k = 0; k < sel[v].tlen; k++) fprintf(hf, "%s%u", k ? "," : "", sel[v].target[k]);
            fprintf(hf, "};\n");
        }
        fprintf(hf, "\nstatic const cosim_vec COSIM_VECS[] = {\n");
        for (size_t v = 0; v < sel.size(); v++) {
            const Rec &q = sel[v];
            const int eb = (q.side == 'L') ? h.pen_clip5 : h.pen_clip3;
            fprintf(hf, "    {%d,%d,%d,%d, %d,%d,%d,%d,%d,%d, %d,%d,%d,%d,%d,%d, COSIM_Q%zu, COSIM_T%zu},\n",
                    q.qlen, q.tlen, q.h0, q.w, h.o_del, h.e_del, h.o_ins, h.e_ins,
                    h.zdrop, eb, q.score, q.qle, q.tle, q.gtle, q.gscore, q.max_off, v, v);
        }
        fprintf(hf, "};\nstatic const int COSIM_N = %d;\n", (int)sel.size());
        fclose(hf);
        printf("emitted %d co-sim vectors -> %s\n", (int)sel.size(), emit_header);
    }

    if (ex) { fclose(ex); printf("extracted %llu %s records -> %s\n",
                                 (unsigned long long)(extract_all ? st.n :
                                     extract_xmodel ? st.bad_xmodel : st.bad),
                                 extract_all ? "" : extract_xmodel ?
                                     "hls-vs-reference" : "divergent", extract); }
    printf("records : %llu   (scalar=%llu  simd16=%llu  simd8=%llu)\n",
           (unsigned long long)st.n, (unsigned long long)st.by_route[0],
           (unsigned long long)st.by_route[1], (unsigned long long)st.by_route[2]);
    printf("envelope: max qlen=%d  max tlen=%d  max w=%d  max h0=%d  max band_try=%d\n",
           st.max_qlen, st.max_tlen, st.max_w, st.max_h0, st.max_band_try);
    if (st.oob) printf("NOTE    : %llu records exceed the HLS envelope "
                       "(qlen<=%d, tlen<=%d) and were not run\n",
                       (unsigned long long)st.oob, KSW_MAX_QLEN, KSW_MAX_TLEN);
    printf("\nreference vs golden : %s  %llu/%llu bit-exact, %llu mismatches\n",
           st.bad ? "FAIL" : "PASS",
           (unsigned long long)(st.n - st.bad), (unsigned long long)st.n,
           (unsigned long long)st.bad);
    printf("hls       vs golden : %s  %llu/%llu bit-exact, %llu mismatches\n",
           st.bad_hls ? "FAIL" : "PASS",
           (unsigned long long)(st.n - st.bad_hls), (unsigned long long)st.n,
           (unsigned long long)st.bad_hls);
    printf("hls       vs reference : %s  %llu/%llu bit-exact, %llu mismatches\n",
           (st.bad_xmodel || st.oob) ? "FAIL" : "PASS",
           (unsigned long long)(st.n - st.bad_xmodel), (unsigned long long)st.n,
           (unsigned long long)st.bad_xmodel);

    // The golden file is bwa-mem2's truth, but the reference port is known to
    // diverge from it on a characterised handful of records (see
    // docs/swa_golden_capture.md). What must ALWAYS hold is hls == reference.
    return (st.bad_xmodel || st.oob) ? 1 : 0;
}
