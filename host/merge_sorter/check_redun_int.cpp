// check_redun_int.cpp — verify an INTEGER surrogate for the redundancy test's
// float comparison `x > 0.95f * y` (bwamem.cpp: or_ > opt->mask_level_redun*mr),
// so the RTL can use integer arithmetic and stay bit-exact.
//
// Operands on short reads: or_/oq are reference/query overlaps, mr/mq are min
// alignment lengths — all small (<= a few hundred). We exhaustively compare the
// real float expression against candidate integer forms over a generous range.
#include <cstdio>
#include <cstdint>

int main() {
    const int LO = -4096, HI = 4096;      // x range (overlap can be negative)
    const int MHI = 4096;                 // y range (length >= 0)
    long tested = 0, mis_20_19 = 0, mis_100_95 = 0;
    int  ex_x = 0, ex_y = 0;
    for (int y = 0; y <= MHI; ++y) {
        float thr = 0.95f * (float)y;     // exactly the production RHS
        for (int x = LO; x <= HI; ++x) {
            bool fref = ((float)x > thr);
            bool i1   = (20LL * x  > 19LL * y);    // 0.95 = 19/20 (exact rational)
            bool i2   = (100LL * x > 95LL * y);    // 0.95 = 95/100
            tested++;
            if (i1 != fref) { if (!mis_20_19) { ex_x = x; ex_y = y; } mis_20_19++; }
            if (i2 != fref) mis_100_95++;
        }
    }
    printf("tested pairs        : %ld  (x in [%d,%d], y in [0,%d])\n", tested, LO, HI, MHI);
    printf("mismatches 20x>19y  : %ld\n", mis_20_19);
    printf("mismatches 100x>95y : %ld\n", mis_100_95);
    if (mis_20_19) printf("first 20/19 mismatch: x=%d y=%d (float=%d)\n",
                          ex_x, ex_y, (int)((float)ex_x > 0.95f*(float)ex_y));
    printf("RESULT: %s\n", (mis_20_19==0) ? "20*x>19*y is EXACT over range" :
                           (mis_100_95==0) ? "100*x>95*y is EXACT over range" : "NO simple surrogate exact");
    return 0;
}
