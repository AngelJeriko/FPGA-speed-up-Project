// HLS top-level declaration for the banded SWA extension kernel.
// The kernel body lives in ../ksw_hls.h; this is the synthesis entry point.
#pragma once
#include "ksw_hls.h"

void ksw_extend_top(
    int32_t qlen, const uint8_t query[KSW_MAX_QLEN],
    int32_t tlen, const uint8_t target[KSW_MAX_TLEN],
    const int8_t mat[KSW_M * KSW_M],
    int32_t o_del, int32_t e_del, int32_t o_ins, int32_t e_ins,
    int32_t w, int32_t end_bonus, int32_t zdrop, int32_t h0,
    ksw_extend_out *out);
