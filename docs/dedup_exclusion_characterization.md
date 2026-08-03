# dedup-exclusion coverage gap — characterized & CLOSED (2026-08-03)

**Question:** the redundancy-exclusion decision in the v2 dedup was flagged as a coverage
gap — mutating the RTL to disable it (`excl_p = excl_q = 1'b0`) left `tb_msort_dedup` at
1696/0. Same "never observed to change a result" shape as the [zdrop gap](zdrop_characterization.md).
Is the exclusion inert (like zdrop), or is the test blind?

**Answer: unlike zdrop, the exclusion is NOT inert — it is the module's core function and
changes output constantly. The green mutation was a FALSE NEGATIVE caused by a bug in the
`tb_msort_dedup` vector generator. The gap is now CLOSED: the enriched corpus makes the
disable-exclusion mutation go RED, while the shipping integration tests already caught it.**

## What the exclusion does
`mem_sort_dedup_patch` branch-A: after the stable re-sort by `re`, for each overlapping
pair (same `rid`, within `max_chain_gap`) that overlaps by > `mask_level_redun` (0.95, via
the integer surrogate `20·ov > 19·minlen`) on **both** ref and query, drop the
lower-scoring hit by setting its `qe = qb` (`excl_p` if p loses, `excl_q` if q loses).

## It is highly active (opposite of zdrop) — `host/merge_sorter/dedup_probe.cpp`
Running `v2_dedup` with exclusion ON vs OFF:

| population | exclusion fires | arrays whose output CHANGES if disabled |
|---|---|---|
| **real captured corpus** (`alnreg_v2_vectors.bin`, 3440 arrays) | **25,867×** (in 936 arrays) | **776** — of which **126 tie-free** (the hardware-handled set), 650 tie (SW-fallback) |
| random (2M arrays, gen_dedup clustering) | 3.18M× | 483,649 |
| directed 2-hit >0.95-overlap, distinct score & (rb,qb) | 1× | n_out 1→2 (loser survives) |

So the decision is observable on **126 tie-free real arrays** — it is emphatically *not*
architecturally dormant. The mutation *should* have gone red.

## Root cause — TWO compounding bugs in `gen_v2_rtl_vectors.py`
1. **Baked-in exclusion (the real one).** The generator emitted `sorted_in`, the array
   returned from `dedup(inp)` — but `dedup` mutates its array **in place**, setting
   `qe = qb` on every excluded loser. So the RTL was fed an input where the redundant
   losers **already arrived with `qe == qb`**. The RTL just skipped them (`q_excl`) and the
   survivor filter (`qe > qb`) dropped them regardless of `excl_p`/`excl_q`. The exclusion
   decision was **bypassed entirely — even at baseline it was never exercised.** Reading the
   emitted `.hex` back, **0 of 1696** arrays could distinguish exclusion on/off.
2. **Size-diversity sampling.** `PER_N = 2` kept only 2 arrays per distinct array size — a
   size sampler, not a redundancy sampler — so even without bug (1) it rarely included a
   firing array.

## The fix
- Emit the re-sorted **original** input (`resorted_in = sorted(copy(inp), key=re)`), not
  dedup's in-place-mutated array, so the RTL must perform the exclusion itself.
- Add an `EXCL_MAX` (=300) quota that additionally keeps redundancy-**observable** tie-free
  arrays (`excl_observable()`: final output depends on the decision), independent of the
  size cap. Result: 1730 arrays, **126 exclusion-observable**.
- Every emitted array is still validated against the real bwa-mem2 output (0 failed).

## Verification (mutation testing — the gap is closed)
| DUT / tb | baseline | mutant (`excl_p=excl_q=0`, or `red2_redun=0`) |
|---|---|---|
| **`msort_dedup` / tb_msort_dedup** (the fixed unit test) | 1730/1730 PASS | **RED — 126 arrays fail** (e.g. rec 10 got 6 exp 3; rec 44 got 172 exp 34) |
| `msort_v2_top` / tb_msort_v2 (shipping full chain) | 2480 PASS | **RED — 92 tie-free fail** (already covered) |
| `matesw_dedup` / tb_matesw_dedup (mate-rescue) | 6000/0 PASS | **RED — 1432/6000 fail** (already covered) |

## Conclusion
- The dedup exclusion is **not** a latent design risk: the **shipping** engine
  (`msort_v2_top`) and the mate-rescue path (`matesw_dedup`) both had their exclusion
  genuinely exercised by their integration tests all along — their generators feed raw
  input + final/real output, so there was nothing to bake.
- The gap was a **standalone unit-test false-negative**: `tb_msort_dedup` fed pre-excluded
  inputs, so it could never turn the mutation red. That is now fixed, and the unit test
  once again *earns* its green — it can go red.
- Methodology note (cf. [[feedback_verify_by_mutating_rtl]]): a green tb that feeds the DUT
  an input with the answer pre-computed proves nothing. This gap was invisible until the
  mutation was actually run — reinforcing that every decision path needs a red witness.
