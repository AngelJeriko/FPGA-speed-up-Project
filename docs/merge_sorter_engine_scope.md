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

  | cap N | % reads | % sort cost |
  |---|---|---|
  | ≤4 | 77.9% | 1.5% |
  | ≤16 | 85.4% | 4.3% |
  | ≤32 | 90.5% | 11.2% |
  | ≤64 | 95.6% | 26.7% |
  | ≤128 | 97.7% | 42.0% |

  Max nonzero bucket = 512 (clamp); 46,201 reads at ≥512 (true n higher). **~58% of
  sort cost is in reads with n>128 (only 2.3% of reads).** → A FIXED small network
  (e.g. N=32) covers 90% of reads but captures only ~11% of the cost — wrong design.
  Need a **scalable/folded merge-sorter that handles the large-N tail (≥512)** plus a
  **fast-path for n=1** (25%, already sorted) and cheap n≤4. Optimize the TAIL, bypass
  the trivial bulk. (Spatial bitonic CAS = N·log₂N·(log₂N+1)/4 is impractical at N=512
  → folded/iterative merge is required regardless.)
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
- **v1 (build):** standalone bit-exact score-sort (`alnreg_slt`) engine — key-extract +
  folded merge-sorter + gather + self-checking TB on real arrays. Captures roughly half
  the ~22% (the post-dedup sort).
- **v2:** combined **sort + de-overlap + dedup** engine — adds the `alnreg_slt2` re-sort
  (with tie-order analysis), the integer-arithmetic overlap/redundancy test, and the
  `mem_patch_reg` merge (reusing the banded-SW core). Captures the full ~22% + dedup.
- **Deferred:** the hash orderings (`alnreg_hlt/_hlt2`) for XA/output; paired-end
  `sort_alnreg_re/score` paths (same engine, different call site).

## 7. Risks / open
1. ~~N_max distribution unknown~~ **MEASURED (§4)** — cost is tail-dominated (n>128 = 58%
   of cost); design must scale to the tail, not the bulk. Open follow-up: raise the 512
   clamp to find true max n (sets the fallback threshold); re-measure on a more
   repetitive sample/full genome (tail may be heavier).
2. **`alnreg_slt2` tie-order** vs `ks_introsort` for v2 — measure how often equal-`re`
   pairs occur and whether output changes; may force replicating introsort tie-order or
   an order-invariant dedup.
3. **rb width** — chr1-5 fits ~31 b; full hg38 needs ~32 b → size keys for full genome.
4. Negative/զero scores: confirm SW score range so the `0x7FFFFFFF - score` descending
   trick stays monotonic (SW scores ≥ T=30 in practice).

## 8. First steps (in order)
1. ~~Measure the per-read alnreg count distribution~~ **DONE (§4)** via instrumented
   bwa-mem2 (`alnreg_hist.tsv`): cost is tail-dominated → scalable folded merge-sorter,
   not a fixed small network. (Optional follow-up: raise the 512 clamp for true max n.)
2. Build the key-extract + **folded/scalable merge-sorter** model (handles large-N tail
   + n=1 fast-path) + self-checking TB (v1).
3. Synthesize for Fmax/area on the assumed part; confirm the area/throughput knob.
4. Then scope v2 (sort+dedup) with the tie-order measurement.
