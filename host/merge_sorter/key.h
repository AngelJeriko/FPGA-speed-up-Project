// key.h — composite-key packing for the alignment-register score sorter.
//
// The hardware merge-sorter never moves the 104-byte mem_alnreg_t records. It
// sorts a fixed-width (key, index) pair: a single UNSIGNED key compare must
// reproduce the software comparator `alnreg_slt`:
//
//     alnreg_slt(a,b) = score DESC, then rb ASC, then qb ASC
//
// We pack a 96-bit composite key so that ascending unsigned compare == alnreg_slt:
//
//   [95:64] ks = 0x7FFFFFFF - score   (32b) -- invert so larger score sorts first
//   [63:24] rb                         (40b) -- reference begin, ascending
//   [23: 0] qb                         (24b) -- query begin, ascending
//
// 32+40+24 = 96 bits. Modeled here in `unsigned __int128` (a GCC/Clang builtin)
// so the C++ model uses the exact single-compare semantics the RTL will use.
#pragma once
#include <cstdint>
#include <cassert>

using u128 = unsigned __int128;

struct AlnKey {
    int32_t score;   // Smith-Waterman alignment score (>= 0 in practice, >= opt->T)
    int64_t rb;      // reference begin coordinate (concatenated fwd+rev index)
    int32_t qb;      // query begin coordinate (read position)
};

// Field widths in the composite key.
static constexpr int QB_BITS = 24;
static constexpr int RB_BITS = 40;
static constexpr int KS_BITS = 32;
static constexpr int64_t RB_MAX = (int64_t(1) << RB_BITS) - 1;  // ~1.1e12, >> full hg38 bi-index
static constexpr int32_t QB_MAX = (int32_t(1) << QB_BITS) - 1;  // 16M, >> any read length

// Software comparator: true iff a should sort strictly BEFORE b (a < b).
inline bool alnreg_slt(const AlnKey& a, const AlnKey& b) {
    if (a.score != b.score) return a.score > b.score;   // score descending
    if (a.rb    != b.rb)    return a.rb    < b.rb;       // rb ascending
    return a.qb < b.qb;                                  // qb ascending
}

// Pack into the 96-bit composite key. Asserts the fields fit their fields.
inline u128 pack_key(const AlnKey& k) {
    assert(k.score >= 0 && "score must be non-negative for the inversion trick");
    assert(k.rb >= 0 && k.rb <= RB_MAX && "rb exceeds RB_BITS");
    assert(k.qb >= 0 && k.qb <= QB_MAX && "qb exceeds QB_BITS");
    uint32_t ks = uint32_t(0x7FFFFFFF) - uint32_t(k.score);   // larger score -> smaller ks
    u128 comp = (u128)ks << (RB_BITS + QB_BITS);
    comp |= (u128)(uint64_t)k.rb << QB_BITS;
    comp |= (u128)(uint32_t)k.qb;
    return comp;
}
