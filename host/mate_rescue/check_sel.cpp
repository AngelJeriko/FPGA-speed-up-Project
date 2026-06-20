// check_sel.cpp — validate the mate-rescue CANDIDATE SELECTION model
// (host/mate_rescue/pe.h::matesw_pe_select's prefix gate) against REAL bwa-mem2
// captures from capture/sel_capture.inc.
//
// For each read-pair record, for each end i it recomputes pe.h's selection from the
// captured a[i] scores + pen_unpaired and checks:
//   (1) b[i].n (real) == count of a[i] scores >= a[i].a[0].score - pen_unpaired   [predicate]
//   (2) that count is a contiguous PREFIX (== a[i] is score-sorted descending)    [assumption]
//   (3) the rescued count min(b[i].n, max_matesw) matches pe.h's prefix+cap
// Any (1)/(2) failure means pe.h's selection diverges from the source on real data.
//
// Usage: make checksel && ./check_sel vectors/sel_vec.bin
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <vector>

static bool rd(FILE* f, void* p, size_t n){ return fread(p,1,n,f)==n; }

int main(int argc, char** argv) {
    if (argc < 2) { fprintf(stderr, "usage: %s sel_vec.bin\n", argv[0]); return 1; }
    FILE* f = fopen(argv[1], "rb");
    if (!f) { fprintf(stderr, "cannot open %s\n", argv[1]); return 1; }

    long pairs=0, ends=0, predicate_fail=0, prefix_fail=0, capfail=0, empty_ends=0;
    long total_b=0, total_sel=0;
    int32_t type;
    while (rd(f, &type, 4)) {
        int64_t cid; int32_t pen, mm;
        if (!rd(f,&cid,8) || !rd(f,&pen,4) || !rd(f,&mm,4)) { fprintf(stderr,"trunc header\n"); break; }
        bool trunc=false;
        for (int i=0;i<2;++i) {
            int32_t an;
            if (!rd(f,&an,4)) { trunc=true; break; }
            std::vector<int32_t> sc(an);
            for (int j=0;j<an;++j) if (!rd(f,&sc[j],4)) { trunc=true; break; }
            int32_t bn;
            if (trunc || !rd(f,&bn,4)) { trunc=true; break; }
            ++ends;
            if (an==0) { ++empty_ends; if (bn!=0){ ++predicate_fail;
                if (predicate_fail<=10) printf("PRED-FAIL pair=%lld end=%d: a_n=0 but b_n=%d\n",(long long)cid,i,bn); }
                continue; }
            int top = sc[0], thr = top - pen;
            // count-all (real b[i] semantics) and prefix-run (pe.h semantics)
            int k_all=0; for (int j=0;j<an;++j) if (sc[j]>=thr) ++k_all;
            int k_pre=0; while (k_pre<an && sc[k_pre]>=thr) ++k_pre;
            bool sorted=true; for (int j=1;j<an;++j) if (sc[j]>sc[j-1]) { sorted=false; break; }
            if (bn != k_all) { ++predicate_fail;
                if (predicate_fail<=10) printf("PRED-FAIL pair=%lld end=%d: b_n=%d k_all=%d (top=%d pen=%d)\n",
                    (long long)cid,i,bn,k_all,top,pen); }
            if (k_pre != k_all || !sorted) { ++prefix_fail;
                if (prefix_fail<=10) printf("PREFIX-FAIL pair=%lld end=%d: k_pre=%d k_all=%d sorted=%d (a[i] not score-sorted desc)\n",
                    (long long)cid,i,k_pre,k_all,(int)sorted); }
            int real_sel = bn < mm ? bn : mm;          // real rescued count
            int pe_sel   = k_pre < mm ? k_pre : mm;    // pe.h rescued count
            if (real_sel != pe_sel) { ++capfail;
                if (capfail<=10) printf("CAP-FAIL pair=%lld end=%d: real=%d pe=%d (b_n=%d mm=%d)\n",
                    (long long)cid,i,real_sel,pe_sel,bn,mm); }
            total_b += bn; total_sel += pe_sel;
        }
        if (trunc) break;
        ++pairs;
    }
    fclose(f);
    long fails = predicate_fail + prefix_fail + capfail;
    printf("check_sel: %ld pairs, %ld ends (%ld empty) | predicate_fail=%ld prefix_fail=%ld cap_fail=%ld "
           "| b_total=%ld pe_selected=%ld -> %s\n",
           pairs, ends, empty_ends, predicate_fail, prefix_fail, capfail, total_b, total_sel,
           fails==0 ? "ALL PASS" : "FAIL");
    return fails==0 ? 0 : 1;
}
