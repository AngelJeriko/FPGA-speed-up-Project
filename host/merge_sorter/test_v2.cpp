// test_v2.cpp — self-checking testbench for the v2 dedup reference model.
//
// Reads the golden vectors dumped from a real bwa-mem2 run
// (alnreg_v2_vectors.bin): per record the pre-dedup INPUT array, a has_tie flag,
// and the real mem_sort_dedup_patch OUTPUT. Runs v2_dedup() on the input and
// compares to the real output field-by-field.
//
// Expectation: TIE-FREE arrays (the hardware-handled set) must match bit-exact.
// TIE arrays are the software-fallback set (the stable re-sort can diverge from
// ks_introsort there) — reported separately, not counted as failures.
//
// Record format (little-endian, raw fwrite): int32 n; uint8 has_tie; int32 m;
//   n*V2Key INPUT; m*V2Key OUTPUT.   V2Key = int64 rb,re; int32 qb,qe,rid,score.
#include <cstdio>
#include <cstdint>
#include <vector>
#include "v2_dedup.h"

static bool rd(FILE* f, void* p, size_t n) { return fread(p, 1, n, f) == n; }
static bool rd_key(FILE* f, V2Key& k) {
    return rd(f,&k.rb,8) && rd(f,&k.re,8) && rd(f,&k.qb,4) && rd(f,&k.qe,4)
        && rd(f,&k.rid,4) && rd(f,&k.score,4);
}
static bool key_eq(const V2Key& a, const V2Key& b) {
    return a.rb==b.rb && a.re==b.re && a.qb==b.qb && a.qe==b.qe
        && a.rid==b.rid && a.score==b.score;
}

int main(int argc, char** argv) {
    const char* path = argc > 1 ? argv[1] : "vectors/alnreg_v2_vectors.bin";
    FILE* f = fopen(path, "rb");
    if (!f) { fprintf(stderr, "cannot open %s\n", path); return 2; }

    long records=0, tiefree=0, tiefree_pass=0, tiefree_fail=0;
    long tie=0, tie_match=0, tie_diverge=0;
    int  max_n=0, first_fail_n=-1;
    int32_t n, m; uint8_t has_tie;

    while (rd(f,&n,4)) {
        if (!rd(f,&has_tie,1) || !rd(f,&m,4)) break;
        std::vector<V2Key> in(n), exp(m);
        bool ok_read = true;
        for (int i=0;i<n;i++) if(!rd_key(f,in[i])){ok_read=false;break;}
        for (int i=0;i<m && ok_read;i++) if(!rd_key(f,exp[i])){ok_read=false;break;}
        if (!ok_read) { fprintf(stderr,"truncated at record %ld\n",records); break; }
        records++; if (n>max_n) max_n=n;

        std::vector<V2Key> work = in;
        int my_m = v2_dedup(work.data(), n);
        bool match = (my_m == m);
        if (match) for (int i=0;i<m;i++) if(!key_eq(work[i],exp[i])){ match=false; break; }

        if (!has_tie) {
            tiefree++;
            if (match) tiefree_pass++;
            else { tiefree_fail++; if (first_fail_n<0) first_fail_n=n; }
        } else {
            tie++;
            if (match) tie_match++; else tie_diverge++;
        }
    }
    fclose(f);

    printf("=== v2 dedup testbench ===\n");
    printf("vectors          : %s\n", path);
    printf("records          : %ld   (max n=%d)\n", records, max_n);
    printf("-- tie-free arrays (hardware-handled; must be bit-exact) --\n");
    printf("  count          : %ld\n", tiefree);
    printf("  PASS           : %ld\n", tiefree_pass);
    printf("  FAIL           : %ld%s\n", tiefree_fail, tiefree_fail?"   <-- ":"");
    if (tiefree_fail) printf("  first fail n   : %d\n", first_fail_n);
    printf("-- tie arrays (software-fallback set; divergence expected) --\n");
    printf("  count          : %ld   (match model: %ld, diverge: %ld)\n", tie, tie_match, tie_diverge);
    bool good = (tiefree_fail==0 && records>0);
    printf("RESULT           : %s\n", good ? "ALL PASS (tie-free bit-exact)" : "FAIL");
    return good ? 0 : 1;
}
