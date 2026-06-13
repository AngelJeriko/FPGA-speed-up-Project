# Alignment-Register Merge-Sorter Engine — Design Scope

The chosen FIRST post-seeding FPGA component (see `post_seeding_acceleration_research.md`
#1 and `sort_chain_acceleration_analysis.md`). Attacks the ~22% `ks_introsort` hotspot
on `mem_alnreg_t`. Picked first because it is the largest untargeted stage, has the
highest single-stage Amdahl ceiling (**1.28×**), is **compute-bound (no memory wall)**,
and is **inherently bit-exact** (correctness = "implement the same total order").

Date: 2026-06-13. Source: `bwa-mem2/src/bwamem.cpp` (comparators 149-159; sorts in
`mem_sort_dedup_patch` 292-353) and `bwamem.h` (`mem_alnreg_t` 137-158).

---

## 1. The data

`mem_alnreg_t` ≈ **104 bytes** (int64 rb,re; int qb,qe,rid; ptr c; ~11 score/aux ints;
n_comp:30/is_alt:2; float frac_rep; uint64 hash; int flg). Per read, bwa-mem2 holds a
**small, variable-length array** of these (one set of candidate alignment regions),
and sorts that array — hundreds of millions of tiny sorts, not one big sort.

### Comparators (the orders to reproduce)
| Name | Used | Order |
|---|---|---|
| `alnreg_slt2` | `mem_sort_dedup_patch` 1st sort (298) | by `re` ascending (ref END) |
| `alnreg_slt` | `mem_sort_dedup_patch` 2nd sort (342) | `score` desc, then `rb` asc, then `qb` asc |
| `alnreg_hlt` / `_hlt2` | output ordering | `score`/`is_alt`/`hash` |

### Design decision: sort KEYS + payload pointers
Never move the 104 B records through the network. Extract a fixed-width **composite
key** + a small **index** (pointer into the array); sort the (key,index) pairs; gather
records by the sorted indices. Key packing:
- `alnreg_slt` (score sort): `key = (0x7FFFFFFF - score)[31b] :: rb[~33b] :: qb[16b]`
  → one ascending compare reproduces "score desc, rb asc, qb asc". ~80 bits → pad 96.
- `alnreg_slt2` (re sort): `key = re` (~33-40 b).
- index: ≤10 b (per-read reg count is small).

---

## 2. THE bit-exactness finding (defines v1 vs v2)

`ks_introsort` is **not stable**; for elements that compare EQUAL its output order is
implementation-defined. So bit-exactness depends on whether ties exist:

- **2nd sort (`alnreg_slt`, post-dedup): provably bit-exact.** The dedup pass at
  bwamem.cpp:343-346 removes elements with equal `(score, rb, qb)`. So the survivors
  have a **strict total order** under `alnreg_slt` → ANY correct sort (incl. a merge
  network) yields the IDENTICAL order to `ks_introsort`. No tie ambiguity. ✅
- **1st sort (`alnreg_slt2` by `re`, pre-dedup): tie risk.** Two distinct regions can
  share the same `re` (ref end). Their relative order after sorting feeds the
  **order-dependent** O(n²)-in-window dedup/merge loop (which one becomes `p` vs `q`),
  so a different tie-order could change the deduped SET. Reproducing `ks_introsort`'s
  exact equal-key order in a different sorter is hard. ⚠

**Consequence:** v1 = the **post-dedup score sort** (clean, total-order, bit-exact,
self-contained). v2 = the **combined sort + de-overlap + dedup engine** (captures the
1st sort + the dedup loop + the `mem_patch_reg`→`bwa_gen_cigar2` merge that REUSES the
banded-SW core), which needs a tie-order analysis first.

---

## 3. v1 datapath — score-sort engine (bit-exact)

```
per-read alnreg array (in on-chip RAM)
  → key-extract unit: read score/rb/qb fields, pack 96-bit composite key + index
  → sentinel-pad to fixed N_max (pad keys = all-ones so they sort last)
  → merge-sorter (folded/iterative bitonic — see §4) on (key,index) pairs
  → gather: emit records in sorted index order (or just the reordered index list)
```
Output = the array permuted into `alnreg_slt` order — identical to `ks_introsort(mem_ars,...)`.

## 4. Microarchitecture & sizing
- **Network:** a **folded/iterative merge-sorter** (reuse one compare-exchange stage
  across cycles), NOT a fully-spatial bitonic — area-efficient and throughput is
  ample (see below). Research flagged fixed full bitonic as awkward for variable/wide
  records; folding + key-only sort resolves both.
- **N_max — MEASURED (2026-06-13, instrumented run, 26.9M sort calls on chr1-5/HG00733):**
  by COUNT reads are tiny (25% n=1 → no sort; ~78% n≤4; 90.5% n≤32) BUT by sort COST
  (~count·n·log₂n) the long tail dominates:

  | cap N | % reads | % sort cost | % cost ABOVE cap |
  |---|---|---|---|
  | ≤4 | 78.0% | 1.5% | 98.5% |
  | ≤16 | 85.4% | 4.3% | 95.8% |
  | ≤32 | 90.5% | 11.1% | 88.9% |
  | ≤64 | 95.6% | 26.5% | 73.5% |
  | ≤128 | 97.7% | 41.7% | 58.3% |
  | ≤256 | 99.2% | 65.4% | 34.6% |
  | ≤512 | 99.8% | 90.1% | 9.9% |
  | ≤1024 | 100.00% | 99.97% | 0.03% |

  **TRUE MAX n = 1060** (clamp raised 512→4096 on 2026-06-13 re-run + unbounded
  max-tracker; nothing reached 4096, so the distribution genuinely tops out at 1060 —
  earlier "≥512" was a censoring artifact). The tail is **bounded, not pathological**:
  a hardware sorter can cover the ENTIRE distribution. **A sorter sized to N=1024
  captures 99.97% of all sort cost**; the read-sets with n∈(1024,1060] are 0.03% of
  cost → trivial software fallback. → A FIXED small network (e.g. N=32) covers 90% of
  reads but only ~11% of cost — wrong design. Build a **scalable/folded merge-sorter
  sized to N=1024** (software-fallback threshold = 1024) plus a **fast-path for n=1**
  (25%, already sorted) and cheap n≤4. Optimize the TAIL, bypass the trivial bulk.
  (Spatial bitonic CAS = N·log₂N·(log₂N+1)/4 is impractical at N=1024 → folded/iterative
  merge is required regardless.)
- **Throughput:** fully/partly pipelined → ≈1 read-set per few cycles; at ~200-300 MHz
  that is >>10⁸ read-sets/s, far above need. The sorter is NOT the bottleneck — key
  extraction and (in v2) the dedup loop are. So optimize for AREA, not speed.

## 5. Verification (sim, no board)
- **Golden ordering vectors:** for the v1 total-order case, golden = the input array
  sorted by `alnreg_slt` in software (any correct sort matches, since no ties survive).
  Optionally instrument bwa-mem2 to dump the real pre/post-`ks_introsort` arrays from
  a chr1-5 run for end-to-end confidence.
- **Self-checking testbench:** feed real per-read alnreg arrays (keys), assert the RTL
  output index permutation == golden order, bit-for-bit, over millions of read-sets.
- **N-distribution harness** (first deliverable, pure software): dump per-read alnreg
  counts from a real run → sets N_max and the overflow rate.

## 6. v1 / v2 / deferred
- **v1 — C++ MODEL BUILT & VERIFIED (2026-06-13):** `host/merge_sorter/` — `key.h`
  (96-bit composite key + `pack_key`), `folded_sorter.h` (bottom-up folded merge sort,
  N_MAX=1024 + n>1024 fallback + n≤1 fast-path), `test_sorter.cpp` (self-checking TB).
  Run against 21,386 REAL vectors (n=2..1060, chr1-5/HG00733): **21,386/21,386 bit-exact
  vs. real `ks_introsort` output, packing==comparator (0 mismatches), 0 equal-key ties
  (confirms strict total order → v1 bit-exactness empirically proven)**. 61 records hit
  the n>1024 software fallback; worst case 11 merge passes; max rb 2.12e9 (fits 40b),
  max qb 131, scores [19,150] (inversion trick safe). NEXT: translate to SystemVerilog
  (`rtl/`) reusing these golden vectors.
- **v1 — SystemVerilog RTL BUILT & VERIFIED (2026-06-13):** `rtl/msort_pkg.sv` +
  `rtl/msort_merge_sorter.sv` (folded bottom-up merge sorter: ping-pong RAM banks, one
  reusable streaming merge unit swept ceil(log2 n) passes, load/sort/unload FSM, N_MAX=1024)
  + `tb/tb_msort.sv` (self-checking, reads the same golden vectors). Verilator sim:
  **3441/3441 records bit-exact (1,525,044 elements, n=2..1024) vs. real ks_introsort.**
  Vectors auto-bootstrapped by `scripts/run_sim.sh tb_msort` from the committed `.bin.gz`
  via `host/merge_sorter/gen_rtl_vectors.py`.
  **v1.1 (2026-06-13): registered-read BLOCK-RAM version** — memory is now synchronous
  read+write (infers M20K simple-dual-port); the merge unit keeps each run's head in a
  register and prefetches the refill to tolerate 1-cycle read latency (2-cycle/element
  STEP/LATCH merge). Re-verified **3441/3441 bit-exact**. Synthesis flow scaffolded:
  `scripts/synth_msort.tcl` (+ `msort.sdc`) for Quartus, analytical estimate in
  `docs/merge_sorter_synthesis.md` (~12 M20K, ~400-800 ALM, est. 250-350 MHz; engine is
  <0.2% of a Stratix 10 MX → replicate for throughput). NEXT: run synthesis (needs
  Quartus — not installed here) for real Fmax/area; then v2 (sort+dedup).
- ~~**v1 (build):**~~ (C++ model + RTL done, above) standalone bit-exact score-sort
  (`alnreg_slt`) engine. Captures roughly half the ~22% (the post-dedup sort).
- **v2:** combined **sort + de-overlap + dedup** engine — adds the `alnreg_slt2` re-sort,
  the integer-arithmetic overlap/redundancy test, and the `mem_patch_reg` merge (reusing
  the banded-SW core). Captures the full ~22% + dedup. **Tie-order analysis DONE**
  (`docs/merge_sorter_v2_tie_analysis.md`): the re-sort is order-sensitive — a stable
  merge sort diverges from `ks_introsort` on 0.063% of arrays → v2 keeps the HW sorter
  stable and **software-falls-back any array with an equal-`re` tie** (1.25% by count) for
  bit-exactness. Next v2 step: cost-weight the tie arrays, then design the overlap/merge
  datapath (reuses the banded-SW core already in `rtl/bsw_*`).
- **Deferred:** the hash orderings (`alnreg_hlt/_hlt2`) for XA/output; paired-end
  `sort_alnreg_re/score` paths (same engine, different call site).

## 7. Risks / open
1. ~~N_max distribution unknown~~ **MEASURED + RESOLVED (§4)** — cost is tail-dominated;
   ~~raise the 512 clamp to find true max n~~ **DONE: true max = 1060**, N=1024 captures
   99.97% of cost → fallback threshold = 1024. Remaining open follow-up: re-measure on a
   more repetitive sample / full-genome reference (tail could shift; chr1-5/HG00733 is
   one sample) — lower priority now that the bound is known.
2. ~~**`alnreg_slt2` tie-order** vs `ks_introsort` for v2~~ **MEASURED + RESOLVED
   (2026-06-13, `docs/merge_sorter_v2_tie_analysis.md`):** 1.25% of arrays have equal-`re`
   ties (max mult 35); a STABLE merge sort DIVERGES from `ks_introsort` on **0.063% of
   arrays** (5.05% of tie arrays; 634 even differ in element count) → **stable merge is
   NOT bit-exact for v2.** Decision: keep the HW sorter stable + **software-fallback any
   array containing an equal-`re` tie** (1.25% by count; mirrors the v1 n>1024 fallback).
   Open follow-up: cost-weight of tie arrays (they skew large) to size the realized v2
   speedup.
3. ~~**rb width**~~ **MEASURED:** chr1-5 max rb = 2.12e9 (~31 b); key sized RB_BITS=40
   (cap 1.1e12) → ample headroom for full hg38 bi-index (~6.4e9, ~33 b). qb max 131 (24 b
   field is overkill but kept for long reads).
4. ~~Negative/zero scores~~ **MEASURED:** observed SW score range [19,150], all positive
   (note: min 19 < opt->T=30 — sub-threshold regions still present at sort time, but still
   ≥0) → `0x7FFFFFFF - score` inversion stays monotonic. Confirmed safe.

## 8. First steps (in order)
1. ~~Measure the per-read alnreg count distribution~~ **DONE (§4)** via instrumented
   bwa-mem2 (`alnreg_hist.tsv`): cost is tail-dominated → scalable folded merge-sorter,
   not a fixed small network. Follow-up DONE: clamp raised → true max n = 1060, size
   sorter to N=1024 (fallback threshold 1024).
2. Build the key-extract + **folded/scalable merge-sorter** model (handles large-N tail
   + n=1 fast-path) + self-checking TB (v1).
3. Synthesize for Fmax/area on the assumed part; confirm the area/throughput knob.
4. Then scope v2 (sort+dedup) with the tie-order measurement.
