// Synthesis entry point. Kept as a thin wrapper so ksw_hls.h stays a header
// that plain g++ can also compile for the C-sim/replay harness.
#include "ksw_kernel.h"

void ksw_extend_top(
    int32_t qlen, const uint8_t query[KSW_MAX_QLEN],
    int32_t tlen, const uint8_t target[KSW_MAX_TLEN],
    const int8_t mat[KSW_M * KSW_M],
    int32_t o_del, int32_t e_del, int32_t o_ins, int32_t e_ins,
    int32_t w, int32_t end_bonus, int32_t zdrop, int32_t h0,
    ksw_extend_out *out)
{
    *out = ksw_extend_hls(qlen, query, tlen, target, mat,
                          o_del, e_del, o_ins, e_ins,
                          w, end_bonus, zdrop, h0);
}
