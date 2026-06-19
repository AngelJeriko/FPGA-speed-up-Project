// pe.h — C++ model of the pe-level mate-rescue CANDIDATE SELECTION + loop: the
// b[i] candidate loop of mem_sam_pe_batch_post (!MATE_SORT, bwamem_pair.cpp). One
// step ABOVE orch.h (which models a single mem_matesw call):
//
//   read i's alnregs a[i] (the candidate SOURCE, score-sorted DESC by dedup) and
//   read !i's list a[!i] (the entry ma, mutated in place) ->
//     top = a[i][0].score
//     for j: if a[i][j].score >= top - pen_unpaired   (capped at max_matesw)
//              matesw_orchestrate(a[i][j], mate_seq=!i, ma=a[!i])
//
// Because the source is sorted descending by score, the "good" set is a contiguous
// PREFIX (once a score drops below top-pen_unpaired, all later ones do too) — so the
// gate is a clean break, and the max_matesw cap applies to that prefix in order.
// This matches bwa's two-step form (build b[i] = all passing, then rescue
// min(b[i].n, max_matesw) of them) exactly for sorted-desc input.
//
// SCOPE / what is modeled vs deferred:
//  - The SELECTION predicate (score gate + max_matesw cap) is transcribed from the
//    well-known mem_sam_pe logic; it is NOT yet validated against the BATCHED source
//    on real data. Defer to a pe-level capture (see docs/remote_capture_plan.md):
//    the existing orch capture validates each mem_matesw CALL, not which candidates
//    fire. pen_unpaired / max_matesw are runtime scalars here (MPeOpt), so the RTL
//    takes them as inputs and no default is baked in — but confirm the defaults
//    (pen_unpaired=17, max_matesw=50) and the exact predicate at capture.
//  - Stage-1: candidate is_alt is dropped on-chip (the merge-sorter rec_t carries no
//    is_alt), so candidates enter rescue with is_alt=0. The generator sets is_alt=0
//    on the source to keep the golden bit-exact with the RTL; the VALUE loss is the
//    pre-existing accel/merge-sorter simplification, not introduced here.
#pragma once
#include <array>
#include <vector>
#include <cstdint>
#include "orch.h"

struct MPeOpt {                  // pe-level mate-rescue selection knobs (runtime)
    int pen_unpaired = 17;       // bwa default — CONFIRM vs batched source at capture
    int max_matesw   = 50;       // bwa default — CONFIRM vs batched source at capture
};

// One direction of the pair: rescue read !i's ma against read i's good candidates.
//   cand_src : read i's alnregs, SORTED DESC by score (== accel / mem_sort_dedup_patch
//              emit order). cand_src[k].is_alt is taken as given (0 on-chip, Stage-1).
//   win[k]   : candidate k's host-fed per-orientation windows (parallel to cand_src;
//              only the selected prefix is consumed).
//   ms,l_ms  : the UNMAPPED mate's sequence (read !i).
//   ma       : read !i's alnreg list — mutated in place across candidates.
// Returns the final ma size. Selected-candidate count is (return is via ma).
static inline int matesw_pe_select(const MOpt& o, const MPeOpt& po, int64_t l_pac,
                                   const std::vector<MAln>& cand_src,
                                   int l_ms, const uint8_t* ms,
                                   const MPes pes[4],
                                   const std::vector<std::array<MWin,4>>& win,
                                   std::vector<MAln>& ma) {
    if (cand_src.empty()) return (int)ma.size();
    const int top = cand_src[0].score;          // a[i][0] = highest (sorted desc)
    const int thr = top - po.pen_unpaired;
    for (int j = 0; j < (int)cand_src.size() && j < po.max_matesw; ++j) {
        if (cand_src[j].score < thr) break;      // sorted desc -> rest also fail
        matesw_orchestrate(o, l_pac, cand_src[j], l_ms, ms, pes, win[j].data(), ma);
    }
    return (int)ma.size();
}
