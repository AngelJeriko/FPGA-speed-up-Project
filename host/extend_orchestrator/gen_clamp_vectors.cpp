// gen_clamp_vectors.cpp — emit tb vectors for rtl/bns_clamp_top.sv. Expected outputs come from
// bns_clamp.h (proven bit-exact vs real bwa-mem2: 400k real chr1-5 + 16 synthetic firing events).
// Since RTL == bns_clamp establishes RTL == bwa transitively, driving the tb from the model is sound.
//
// Emits several self-contained "table blocks" so one tb run exercises: the committed synthetic firing
// golden (clamp arithmetic, both strands), a programmatically-built DEEP 64-contig table (full
// binary-search depth + every clamp direction on both strands), and — when the (gitignored) real
// chr1-5 capture is present — the real distribution (5-contig search + is_rev + no-op path).
//
// Numeric-only format (all decimal, signed; large values are 64-bit):
//   <num_blocks>
//   per block: <l_pac> <n_seqs>
//              n_seqs lines: <offset> <len>
//              <nrec>
//              nrec lines: <beg_in> <midpos> <end_in> <beg_out> <end_out> <rid> <is_rev> <len>
//
// Build: make clampvec    Usage: ./gen_clamp_vectors <out.txt> [chr1-5.fa.ann clamp_vec.bin]
#include "bns_clamp.h"
#include <cstdio>
#include <cstdint>
#include <vector>
#include <string>

struct Rec { int64_t beg_in, mid, end_in, beg_out, end_out, len; int rid, is_rev; };

// Run one input triple through the model, capturing all outputs.
static Rec run(const BnsTable& t, int64_t beg, int64_t mid, int64_t end) {
    Rec r; r.beg_in = beg; r.mid = mid; r.end_in = end;
    int64_t b = beg, e = end; int rid = -1, rev = -1;
    int64_t len = bns_clamp(t, b, mid, e, rid, rev);
    r.beg_out = b; r.end_out = e; r.rid = rid; r.is_rev = rev; r.len = len;
    return r;
}

static void emit_block(FILE* f, const BnsTable& t, const std::vector<Rec>& recs) {
    fprintf(f, "%lld %zu\n", (long long)t.l_pac, t.anns.size());
    for (auto& a : t.anns) fprintf(f, "%lld %lld\n", (long long)a.offset, (long long)a.len);
    fprintf(f, "%zu\n", recs.size());
    for (auto& r : recs)
        fprintf(f, "%lld %lld %lld %lld %lld %d %d %lld\n",
                (long long)r.beg_in, (long long)r.mid, (long long)r.end_in,
                (long long)r.beg_out, (long long)r.end_out, r.rid, r.is_rev, (long long)r.len);
}

// Build directed records for a table: for each contig, forward + reverse strand, and no-clamp /
// end-clamp / beg-clamp, by placing the midpoint near the middle / end / start of the contig.
static std::vector<Rec> directed(const BnsTable& t) {
    std::vector<Rec> v;
    const int64_t L2 = t.l_pac << 1;
    for (size_t i = 0; i < t.anns.size(); ++i) {
        int64_t off = t.anns[i].offset, len = t.anns[i].len;
        if (len < 8) continue;
        int64_t mids[3] = { off + len/2, off + len - 2, off + 1 };   // middle, near-end, near-start
        for (int k = 0; k < 3; ++k) {
            int64_t fp = mids[k];
            // forward: window straddles fp with generous half-widths to force clamps at the edges
            v.push_back(run(t, fp - 400, fp, fp + 400));
            // reverse strand: same forward point mapped to its reverse coordinate
            int64_t rp = L2 - 1 - fp;
            v.push_back(run(t, rp - 400, rp, rp + 400));
        }
        // tight no-clamp cases squarely inside the contig (both strands)
        int64_t c = off + len/2;
        v.push_back(run(t, c - 50, c, c + 50));
        v.push_back(run(t, (L2-1-c) - 50, L2-1-c, (L2-1-c) + 50));
    }
    return v;
}

// A deep table: NC contigs of varied lengths, offsets cumulative, to exercise full search depth.
static BnsTable deep_table(int NC) {
    BnsTable t; int64_t off = 0;
    for (int i = 0; i < NC; ++i) {
        int64_t len = 1000 + ((i * 2654435761u) % 9000);   // 1000..9999, deterministic spread
        t.anns.push_back({ off, len });
        off += len;
    }
    t.l_pac = off;
    return t;
}

template <class T> static bool rd(FILE* f, T& v) { return fread(&v, sizeof(T), 1, f) == 1; }

// Read the real capture (clamp_capture.inc format), replay through the model, emit up to `cap` recs.
static bool read_capture(const char* path, const BnsTable& t, std::vector<Rec>& out, size_t cap) {
    FILE* f = fopen(path, "rb");
    if (!f) return false;
    for (size_t n = 0; n < cap;) {
        int32_t type; if (!rd(f, type)) break;
        int64_t cid, lpac, beg_in, mid, end_in, beg_out, end_out; int32_t rid, nbytes;
        if (!rd(f, cid) || !rd(f, lpac) || !rd(f, beg_in) || !rd(f, mid) || !rd(f, end_in) ||
            !rd(f, beg_out) || !rd(f, end_out) || !rd(f, rid) || !rd(f, nbytes)) break;
        if (nbytes > 0) fseek(f, nbytes, SEEK_CUR);   // skip the window bytes (not needed here)
        out.push_back(run(t, beg_in, mid, end_in));
        ++n;
    }
    fclose(f);
    return true;
}

int main(int argc, char** argv) {
    if (argc < 2) { fprintf(stderr, "usage: %s out.txt [chr1-5.fa.ann clamp_vec.bin]\n", argv[0]); return 2; }
    const char* out = argv[1];

    std::vector<std::pair<BnsTable, std::vector<Rec>>> blocks;

    // Block A: the committed synthetic firing golden's table (3 contigs) + directed cases.
    BnsTable synth;
    if (bns_load_ann("vectors/synth.fa.ann", synth)) blocks.push_back({ synth, directed(synth) });

    // Block B: a deep 64-contig table for full binary-search depth + every clamp direction.
    BnsTable deep = deep_table(64);
    blocks.push_back({ deep, directed(deep) });

    // Block C (optional): the real chr1-5 capture, if both the .ann and the capture are present.
    if (argc >= 4) {
        BnsTable real;
        std::vector<Rec> rr;
        if (bns_load_ann(argv[2], real) && read_capture(argv[3], real, rr, 5000))
            blocks.push_back({ real, rr });
    }

    FILE* f = fopen(out, "w");
    if (!f) { fprintf(stderr, "cannot write %s\n", out); return 2; }
    fprintf(f, "%zu\n", blocks.size());
    size_t total = 0;
    for (auto& b : blocks) { emit_block(f, b.first, b.second); total += b.second.size(); }
    fclose(f);
    fprintf(stderr, "wrote %zu blocks, %zu records to %s\n", blocks.size(), total, out);
    return 0;
}
