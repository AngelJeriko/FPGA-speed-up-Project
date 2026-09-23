// test_div_transform.cpp -- exhaustive proof of change (4) in ksw_hls.h:
//
//     (int)((double)X / e + 1.)   ==   (X + e) / e        for e > 0
//
// ksw_extend2 uses the left form twice (max_ins, max_del) and it is the only
// floating point in the kernel. The mutation run over captured data only
// exercises the cases the data happens to reach, so this checks the identity
// directly over a range that covers every value the kernel can produce:
// X = qlen*max + end_bonus - o, with qlen <= 160 and realistic scoring, and
// well beyond it in both directions.
#include <cstdio>
#include <cstdlib>

int main() {
    long checked = 0, bad = 0;
    for (int e = 1; e <= 256; ++e) {
        for (long X = -100000; X <= 100000; ++X) {
            const int ref = (int)((double)X / e + 1.);
            const int hls = (int)((X + e) / e);
            ++checked;
            if (ref != hls) {
                if (++bad <= 10)
                    printf("MISMATCH X=%ld e=%d  double-form=%d int-form=%d\n", X, e, ref, hls);
            }
        }
    }
    printf("%s: %ld/%ld agree (%ld mismatches)\n",
           bad ? "FAIL" : "PASS", checked - bad, checked, bad);
    return bad ? 1 : 0;
}
