// ref_test.cpp — smoke test that the upstream ksw_align2 (golden reference for
// mate-rescue) compiles + runs standalone. Later this same ksw_align2 becomes the
// reference the scalar HW model (hw_align2) is cross-checked against.
#include <cstdio>
#include <cstdint>
#include <cstring>
#include "macro.h"
#include "ksw_ref.h"

uint64_t tprof[LIM_R][LIM_C];   // satisfy ksw_ref.cpp's extern

// bwa.cpp:bwa_fill_scmat (m=5; match=a, mismatch=-b, ambiguous=-1)
static void fill_scmat(int a, int b, int8_t mat[25]) {
    int i, j, k;
    for (i = k = 0; i < 4; ++i) { for (j = 0; j < 4; ++j) mat[k++] = i==j? a : -b; mat[k++] = -1; }
    for (j = 0; j < 5; ++j) mat[k++] = -1;
}

static void run(const char* name, int qlen, uint8_t* q, int tlen, uint8_t* t,
                const int8_t* mat, int min_seed_len) {
    // mem_matesw xtra: KSW_XSUBO | KSW_XSTART | (l_ms*a<250?KSW_XBYTE:0) | (min_seed_len*a)
    int xtra = KSW_XSUBO | KSW_XSTART | KSW_XBYTE | (min_seed_len * 1);
    kswr_t r = ksw_align2(qlen, q, tlen, t, 5, mat, 6, 1, 6, 1, xtra, 0);
    printf("%-12s score=%d qb=%d qe=%d tb=%d te=%d score2=%d te2=%d\n",
           name, r.score, r.qb, r.qe, r.tb, r.te, r.score2, r.te2);
}

int main() {
    int8_t mat[25]; fill_scmat(1, 4, mat);
    // A=0 C=1 G=2 T=3
    uint8_t q1[] = {0,1,2,3,0,1,2,3};            // ACGTACGT
    uint8_t t1[] = {0,1,2,3,0,1,2,3};            // perfect match
    run("perfect8", 8, q1, 8, t1, mat, 19);

    uint8_t q2[] = {0,1,2,3,0,1,2,3,0,1};        // ACGTACGTAC
    uint8_t t2[] = {3,3,0,1,2,3,0,1,2,3,0,1,3,3};// ..ACGTACGTAC.. embedded
    run("embedded",  10, q2, 14, t2, mat, 19);

    uint8_t q3[] = {0,0,0,0,1,1,1,1};            // AAAACCCC
    uint8_t t3[] = {2,2,0,0,0,0,3,3};            // GGAAAATT (AAAA match in middle)
    run("partial",   8, q3, 8, t3, mat, 4);
    return 0;
}
