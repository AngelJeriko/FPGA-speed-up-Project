// bns_clamp.h — the CONTIG CLAMP that bwa-mem2 applies AFTER c_compute_rmax produces the window
// bounds rmax[0..1] and BEFORE the reference bytes are fetched. This is Decision C2 of
// docs/genome_fetch_options.md: the one genuinely new correctness surface in the on-chip genome
// fetch, pulled on chip because "ask the host to clamp" IS the round trip we are removing.
//
// Faithful, line-for-line, to unmodified BWA-MEM2:
//   bns_fetch_seq_v2 (bwamem.cpp:1890): swap; rid = bns_pos2rid(bns_depos(mid)); clamp [beg,end)
//                                       to the contig bounds, flipped into reverse-strand space
//                                       when is_rev; then bns_get_seq_v2.
//   bns_pos2rid      (bntseq.cpp:378) : binary search over the ascending contig offset table.
//   bns_depos        (bntseq.h:87)    : 2*l_pac-space position -> forward coordinate + is_rev.
//   bns_get_seq_v2   (bwamem.cpp:1851): end<=2*l_pac / beg>=0 clamps; len (0 iff bridging boundary).
//
// SEAM: the caller (bwamem.cpp:2172) passes beg=rmax[0], end=rmax[1], mid=c->seeds[0].rbeg. Our
// pipeline already has all three at the chain2aln_setup output (rmax0, rmax1, s0_rbeg=b_rbeg[0]),
// so C2 slots in immediately after chain2aln_setup and before the ref fetch. Today the HOST does
// this (orch.h windows are "post-bns_fetch_seq values"); this model lets us pull it on chip and
// prove it bit-exact against a capture of real bns_fetch_seq_v2 I/O.
#pragma once
#include <cstdint>
#include <vector>
#include <cassert>

// One contig (bwa's bntann1_t; only the two fields the clamp reads). Comes from the .ann file.
struct BnsAnn { int64_t offset; int64_t len; };

// The contig table (bwa's bntseq_t subset). anns are ascending by offset; sum(len) == l_pac.
struct BnsTable {
    int64_t l_pac = 0;
    std::vector<BnsAnn> anns;   // n_seqs entries
};

// bns_depos (bntseq.h:87): map a position in the 2*l_pac coordinate space to its FORWARD
// coordinate, reporting whether it lay on the reverse strand.
static inline int64_t bns_depos_m(const BnsTable& t, int64_t pos, int& is_rev) {
    is_rev = (pos >= t.l_pac);
    return is_rev ? (t.l_pac << 1) - 1 - pos : pos;
}

// bns_pos2rid (bntseq.cpp:378): binary search for the contig bracketing a FORWARD position.
// Returns -1 for a position past the forward strand (post-depos this cannot happen).
static inline int bns_pos2rid_m(const BnsTable& t, int64_t pos_f) {
    const int n = (int)t.anns.size();
    if (pos_f >= t.l_pac) return -1;
    int left = 0, mid = 0, right = n;
    while (left < right) {
        mid = (left + right) >> 1;
        if (pos_f >= t.anns[mid].offset) {
            if (mid == n - 1) break;
            if (pos_f < t.anns[mid + 1].offset) break;   // bracketed by [mid, mid+1)
            left = mid + 1;
        } else right = mid;
    }
    return mid;
}

// bns_fetch_seq_v2 (bwamem.cpp:1890) contig clamp. In: beg=rmax0, mid=seeds[0].rbeg, end=rmax1.
// Out (by ref): clamped beg, end, and the derived rid. Returns len = end-beg (0 only if the window
// bridges the forward/reverse boundary, which the contig clamp makes unreachable but which the
// hardware must still define). is_rev_out is exposed for the tb (the strand of the fetch).
static inline int64_t bns_clamp(const BnsTable& t, int64_t& beg, int64_t mid, int64_t& end,
                                int& rid, int& is_rev_out) {
    if (end < beg) { int64_t tmp = beg; beg = end; end = tmp; }   // source: XOR swap
    assert(beg <= mid && mid < end);

    int is_rev;
    rid = bns_pos2rid_m(t, bns_depos_m(t, mid, is_rev));
    is_rev_out = is_rev;
    int64_t far_beg = t.anns[rid].offset;
    int64_t far_end = far_beg + t.anns[rid].len;
    if (is_rev) {                                                 // flip contig bounds into RC space
        int64_t tmp = far_beg;
        far_beg = (t.l_pac << 1) - far_end;
        far_end = (t.l_pac << 1) - tmp;
    }
    beg = beg > far_beg ? beg : far_beg;                          // clamp up to the contig start
    end = end < far_end ? end : far_end;                          // clamp down to the contig end

    // bns_get_seq_v2 final clamps. Post contig-clamp far_beg>=0 and far_end<=2*l_pac, so these are
    // no-ops here, but they are modelled for faithfulness (and matter if the table is malformed).
    if (end > (t.l_pac << 1)) end = t.l_pac << 1;
    if (beg < 0) beg = 0;
    int64_t len = (beg >= t.l_pac || end <= t.l_pac) ? (end - beg) : 0;   // 0 == bridging boundary
    return len;
}

// Load a BnsTable from a bwa .ann file. Format: first line "l_pac n_seqs seed"; then per contig a
// line "gi name anno" followed by a line "offset len n_ambs". Only l_pac + per-contig offset/len
// are retained. (Small helper for goldens/tests; the hardware gets this table as parameters.)
#include <cstdio>
static inline bool bns_load_ann(const char* path, BnsTable& t) {
    FILE* f = fopen(path, "r");
    if (!f) return false;
    long long l_pac; int n_seqs; unsigned seed;
    if (fscanf(f, "%lld %d %u", &l_pac, &n_seqs, &seed) != 3) { fclose(f); return false; }
    t.l_pac = l_pac; t.anns.clear();
    for (int i = 0; i < n_seqs; ++i) {
        // Each contig is TWO lines: finish the current line, then skip the "gi name anno" line,
        // leaving the stream at the numeric "offset len n_ambs" line.
        for (int skipped = 0; skipped < 2; ) { int c = fgetc(f); if (c == EOF) break; if (c == '\n') ++skipped; }
        long long off, len, n_ambs;
        if (fscanf(f, "%lld %lld %lld", &off, &len, &n_ambs) != 3) { fclose(f); return false; }
        t.anns.push_back({ (int64_t)off, (int64_t)len });
    }
    fclose(f);
    return true;
}
