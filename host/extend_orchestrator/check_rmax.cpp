// check_rmax.cpp — validate c_compute_rmax (chain2aln.h) against the REAL captured rmax0/rmax1
// in the ext capture (ext_vec.bin). l_pac is NOT captured, so we run with a huge l_pac: this
// reproduces the bwa rmax loop minus the l_pac upper-clamp / fwd-rev boundary fix, which only
// fire for chains near the reference ends/midpoint (rare). So the vast majority must match the
// captured rmax exactly; the few mismatches are the l_pac-edge cases (captured is tighter).
//
// Build:  g++ -O2 -std=c++17 -o check_rmax check_rmax.cpp
// Run:    ./check_rmax vectors/ext_vec.bin
#include <cstdio>
#include "parse.h"
#include "chain2aln.h"

int main(int argc, char** argv) {
    if (argc < 2) { fprintf(stderr, "usage: %s ext_vec.bin\n", argv[0]); return 2; }
    std::vector<ReadVec> reads = load_reads(argv[1]);
    const int64_t BIG = (int64_t)1 << 60;          // huge l_pac -> no upper clamp / no boundary fix
    long nchk=0, match=0, mism=0;
    long m_lo=0, m_hi=0;                            // mismatch direction (captured tighter low / high)
    for (const ReadVec& rv : reads) {
        if (!rv.has_hdr) continue;
        for (const Chain& ch : rv.chains) {
            if (ch.seeds.empty()) continue;
            int64_t r0, r1;
            c_compute_rmax(ch.seeds, rv.l_query, BIG, rv.cfg, r0, r1);
            nchk++;
            if (r0==ch.rmax0 && r1==ch.rmax1) { match++; continue; }
            mism++;
            if (ch.rmax0 > r0) m_lo++;              // captured rmax0 raised (boundary -> l_pac)
            if (ch.rmax1 < r1) m_hi++;              // captured rmax1 lowered (clamp/boundary)
            if (mism<=15) printf("MISMATCH rid=%d got[%lld,%lld] cap[%lld,%lld] qlen=%d ns=%zu seed0.rbeg=%lld\n",
                ch.rid,(long long)r0,(long long)r1,(long long)ch.rmax0,(long long)ch.rmax1,
                rv.l_query,ch.seeds.size(),(long long)ch.seeds[0].rbeg);
        }
    }
    printf("c_compute_rmax vs captured: %ld checked, %ld match, %ld mismatch (%.4f%%)\n",
           nchk, match, mism, nchk? 100.0*mism/nchk : 0.0);
    printf("  mismatch direction: %ld captured-rmax0-raised, %ld captured-rmax1-lowered (l_pac-edge)\n", m_lo, m_hi);
    return 0;
}
