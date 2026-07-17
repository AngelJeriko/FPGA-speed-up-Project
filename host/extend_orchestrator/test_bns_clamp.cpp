// test_bns_clamp.cpp — directed, self-checking sanity test for the C2 contig clamp (bns_clamp.h).
// This is the DIRECTED half of Decision F (docs/genome_fetch_options.md §4-F): every expected value
// below is hand-derived from the contig table so a model bug shows up as a mismatch. The other half
// — bit-exact confidence vs a capture of REAL bns_fetch_seq_v2 I/O — is a separate step (the 4th
// capture). Our synthetic extension genome g(pos)=pos&3 has NO contigs, so it cannot exercise any
// of this; hence a real table (chr1-5 .ann) and a trivial synthetic table are used here.
//
// Build: make clamp   (or: g++ -O2 -std=c++17 -o test_bns_clamp test_bns_clamp.cpp)
// Run:   ./test_bns_clamp [path/to/hg38_chr1-5.fa.ann]
#include "bns_clamp.h"
#include <cstdio>
#include <string>

static int pass = 0, fail = 0;

// Run one clamp and check beg/end/rid/is_rev/len against hand-derived expectations.
static void check(const char* name, const BnsTable& t,
                  int64_t beg_in, int64_t mid, int64_t end_in,
                  int64_t exp_beg, int64_t exp_end, int exp_rid, int exp_rev) {
    int64_t beg = beg_in, end = end_in;
    int rid = -99, is_rev = -99;
    int64_t len = bns_clamp(t, beg, mid, end, rid, is_rev);
    int64_t exp_len = exp_end - exp_beg;
    bool ok = (beg == exp_beg) && (end == exp_end) && (rid == exp_rid) &&
              (is_rev == exp_rev) && (len == exp_len);
    if (ok) { ++pass; }
    else {
        ++fail;
        printf("  FAIL %-34s got  beg=%lld end=%lld rid=%d rev=%d len=%lld\n",
               name, (long long)beg, (long long)end, rid, is_rev, (long long)len);
        printf("       %-34s want beg=%lld end=%lld rid=%d rev=%d len=%lld\n",
               "", (long long)exp_beg, (long long)exp_end, exp_rid, exp_rev, (long long)exp_len);
    }
}

int main(int argc, char** argv) {
    // ---- Table 1: a trivial synthetic genome, 3 contigs of length 100. l_pac=300, 2*l_pac=600. ----
    // A=[0,100)  B=[100,200)  C=[200,300).  RC image of contig X[o,o+L) is [600-(o+L), 600-o).
    BnsTable syn;
    syn.l_pac = 300;
    syn.anns = { {0,100}, {100,200-100}, {200,300-200} };   // {offset,len}: A,B,C each len 100
    printf("[synthetic 3-contig table, l_pac=300]\n");
    // forward, fully inside B, no clamp
    check("syn fwd inside B",        syn, 140, 150, 160,  140, 160, 1, 0);
    // forward, window runs off A's end into B -> end clamped down to 100
    check("syn fwd off A-end",       syn,  80,  90, 120,   80, 100, 0, 0);
    // forward, mid just inside B but window starts before B -> beg clamped up to 100
    check("syn fwd before B-start",  syn,  95, 110, 130,  100, 130, 1, 0);
    // mid exactly on C's offset -> rid=2 (bracketed at the low edge)
    check("syn fwd mid==C.offset",   syn, 200, 200, 210,  200, 210, 2, 0);
    // reverse strand inside A's RC image [500,600); mid=550 -> depos 49 -> rid A(0); no clamp
    check("syn rev inside A-RC",     syn, 510, 550, 560,  510, 560, 0, 1);
    // reverse strand, window runs below A-RC start 500 -> beg clamped up to 500
    check("syn rev off A-RC start",  syn, 490, 550, 560,  500, 560, 0, 1);

    // ---- Table 2: the real chr1-5 .ann (loaded), same cases at real coordinates. ----
    std::string ann = (argc > 1) ? argv[1] : "/home/ccloud/ref/hg38_chr1-5.fa.ann";
    BnsTable real;
    if (bns_load_ann(ann.c_str(), real)) {
        printf("[real chr1-5 table, l_pac=%lld, n_seqs=%zu]\n",
               (long long)real.l_pac, real.anns.size());
        const int64_t L  = real.l_pac;            // 1061198324
        const int64_t L2 = L << 1;                // 2122396648
        const int64_t c1_end = real.anns[0].len;  // 248956422 (chr1 end / chr2 offset)
        const int64_t c2_off = real.anns[1].offset;
        const int64_t c3_off = real.anns[2].offset;
        // forward, fully inside chr2
        check("real fwd inside chr2",   real, 299999000, 300000000, 300001000,
              299999000, 300001000, 1, 0);
        // forward, off chr1's end into chr2 -> end clamped to chr1_end
        check("real fwd off chr1-end",  real, 248955000, 248956000, 248957000,
              248955000, c1_end, 0, 0);
        // forward, mid just inside chr2, window starts before chr2 -> beg clamped up
        check("real fwd before chr2",   real, 248956000, 248957000, 248958000,
              c2_off, 248958000, 1, 0);
        // mid exactly on chr3's offset -> rid=2
        check("real fwd mid==chr3.off", real, c3_off, c3_off, c3_off + 1049,
              c3_off, c3_off + 1049, 2, 0);
        // last forward base of chr5 -> off-end clamp to l_pac
        check("real fwd chr5 off-end",  real, L - 1324, L - 1, L + 676,
              L - 1324, L, 4, 0);
        // reverse strand inside chr1's RC image [L2-c1_end, L2); mid=2e9 -> depos -> chr1
        check("real rev inside chr1-RC",real, 1999999000, 2000000000, 2000001000,
              1999999000, 2000001000, 0, 1);
        // reverse strand, window below chr1-RC start -> beg clamped up to L2-c1_end
        check("real rev off chr1-RC",   real, L2 - c1_end - 774, L2 - c1_end + 774, L2 - c1_end + 1226,
              L2 - c1_end, L2 - c1_end + 1226, 0, 1);
    } else {
        printf("[real chr1-5 table: %s not found — skipping real-coordinate cases]\n", ann.c_str());
    }

    printf("\n%s: %d passed, %d failed\n", fail == 0 ? "ALL PASS" : "FAILURES", pass, fail);
    return fail == 0 ? 0 : 1;
}
