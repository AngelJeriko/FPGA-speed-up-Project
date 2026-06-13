# v2 Re-Sort Tie-Order Analysis — resolves scope risk #2

**Question.** v2 of the merge-sorter adds the *first* sort in `mem_sort_dedup_patch`
— `alnreg_slt2`, by `re` (reference end), **pre-dedup** — plus the order-dependent
overlap/dedup loop. `ks_introsort` is **unstable**: for equal-`re` elements its output
order is implementation-defined. The hardware merge-sorter is **stable** (preserves
input order on equal keys). Does that difference change the final deduped result? If
never, v2 can use a plain stable merge sort and stay bit-exact (like v1 did).

**Method.** Instrumented `mem_sort_dedup_patch` (env `ALNREG_TIE_TEST`) to run the FULL
dedup **twice** per array: once via the real `ks_introsort` re-sort (production path) and
once via `std::stable_sort` (exactly what the hardware does), then compare the final
deduped + score-sorted outputs field-by-field (rb, re, qb, qe, rid, score, truesc, sub,
csub, seedcov, n_comp, w). Both paths use the identical score sort, so any divergence is
attributable purely to re-sort tie order.

**Data** (chr1-5 / HG00733, 10M read pairs, 2026-06-13):

| metric | value |
|---|---|
| arrays tested (n≥2) | 20,091,814 |
| arrays with ≥1 equal-`re` tie | 251,570 (**1.25%**) |
| total equal-`re` tie pairs | 525,781 |
| max `re` multiplicity | **35** |
| **DIVERGENT arrays** (stable ≠ introsort) | **12,708** |
| — different element **count** | 634 |
| — same count, different **field values** | 12,074 |

Divergence = **0.063% of all arrays** (5.05% of tie-containing arrays).

**Conclusion.** A stable merge sort is **NOT bit-exact** for v2. In 0.063% of arrays the
equal-`re` order flips the dedup loop, changing which alignment survives — and in 634
cases even *how many* survive. Reproducing the exact production output therefore requires
matching `ks_introsort`'s tie order, which is implementation-defined (klib introsort =
median-of-3 quicksort + insertion-sort threshold); replicating it in hardware would mean
reimplementing that quicksort, defeating the merge-sorter design.

## v2 design decision: software fallback for tie arrays

The bit-exact strategy is to keep the hardware merge-sorter STABLE and **detect ties**:
- The sorter (or a cheap adjacent-`re`-equality check) flags any array containing an
  equal-`re` pair. Those arrays (1.25% by count) are redone on the CPU — guaranteeing
  bit-exact output.
- The 98.75% tie-free arrays are sorted + deduped entirely in hardware.

This mirrors the n>1024 software-fallback already in v1 (0.03% of cost), just with a
different trigger (presence of an equal-`re` tie instead of oversize).

## Fallback cost-weight — MEASURED (resolves the follow-up)

The 1.25% fallback is a count; the **cost-weight** (sum of n·log₂n) is what sizes the
realized speedup. Measured on the same run:

| metric | value |
|---|---|
| arrays with ties (count) | 1.25% |
| **sort+dedup cost in tie arrays** | **1.21%** |
| mean n, all arrays | 17.58 |
| mean n, tie arrays | 18.83 |
| total cost weight | 2.217×10⁹ (matches the independent histogram total 2.213×10⁹) |

**The hypothesis that tie arrays skew large is refuted** — mean n is barely higher
(18.83 vs 17.58), so the cost-weight (1.21%) tracks the count (1.25%) almost exactly.

**Verdict: v2 is worth building.** The conservative bit-exact fallback (redo *every*
tie-containing array on the CPU, not just the 0.063% that actually diverge — divergence
can't be detected cheaply at sort time) removes only ~1.2% of the re-sort+dedup work.
Hardware handles ~98.8%, so v2 lifts the engine from ~half the ~22% hotspot to nearly the
full ~22%, all bit-exact. (A cheap adjacent-equal-`re` detector triggers the fallback —
same mechanism as v1's n>1024 fallback.)
