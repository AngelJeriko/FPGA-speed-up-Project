# Chaining engine — scope, algorithm, FPGA feasibility

**Date:** 2026-06-17. Next offload after the SW engines (`accel_top` + mate-rescue):
seed chaining, ~11% of runtime, pushing the cumulative Amdahl ceiling toward ~2×
(`back_half_speedup_analysis.md`). Bonus: `accel_top` currently *ingests* chains;
offloading chaining lets the pipeline ingest seeds instead.

## Algorithm (bwa-mem2 source) — three stages

`mem_align1_core` runs, in order (bwamem.cpp): `mem_chain` → `mem_chain_flt` →
`mem_flt_chained_seeds` → `mem_chain2aln` (extension, already built).

### 1. `mem_chain` (grouping) — bwamem.cpp ~865-990
Seeds arrive in a fixed order (per SMEM, then per SA coordinate). A **kbtree of
chains keyed by `pos` = the chain's first-seed `rbeg`** maintains the chain set.
Per seed `s`:
- `kb_intervalp` finds `lower` = the chain with the largest `pos ≤ s.rbeg`
  (a predecessor query).
- `test_and_merge(opt, l_pac, lower, s, rid)` (bwamem.cpp:387) — integer colinearity
  vs the chain's **last** and **first** seed:
  - different rid → new chain;
  - `s` fully contained in `[first.qbeg,last.qend) × [first.rbeg,last.rend)` → absorb (no-op);
  - opposite strand (`l_pac` boundary) → new chain;
  - else with `x=s.qbeg-last.qbeg`, `y=s.rbeg-last.rbeg`: grow if
    `y≥0 && |x-y|≤opt->w && x-last.len<max_chain_gap && y-last.len<max_chain_gap`.
  Returns 1 (merged/absorbed) or 0 (→ new chain). The chain key `pos` never changes
  on merge (it stays the first seed's rbeg).

**FPGA:** the kbtree is just an **ordered-by-`pos` set with predecessor + insert**.
Replace it with a **sorted array** (insert at sorted position; predecessor by
scan/binary search). Chains/read are few (measured: typically <20, max ~615), so an
O(n) sorted array is fine and gives the **bit-identical `lower`** the kbtree returns.
The only subtlety to confirm against capture: duplicate-`pos` handling (rare — two
chains can't usually share a first-seed rbeg).

### 2. `mem_chain_flt` (filter) — bwamem.cpp:536-654
- `mem_chain_weight` (459): chain weight = min(query-cover, ref-cover) of its seeds
  (integer interval cover). Drop chains with `w < opt->min_chain_weight` (default 0).
- group chains by seqid, then per read: `ks_introsort(mem_flt)` (sort by weight) +
  a **greedy overlap filter**: keep the best; a later chain is shadowed if its query
  span overlaps a kept chain by `≥ min_l*mask_level` AND `min_l < max_chain_gap` and
  it is much weaker (`w < kept.w*drop_ratio`). Sets `kept` flags; caps at
  `max_chain_extend`; compacts.

**FPGA:** integer interval math + a small sort (reuse the merge-sorter style) + a
bounded greedy O(n²) overlap loop (n = chains/read, small). Float thresholds
`mask_level`/`drop_ratio` (both 0.5 default) and `min_chain_weight*COEF` →
integer surrogates (e.g. `2*(e_min-b_max) ≥ min_l`, `2*w_i < w_j`), proven against
capture like the purge/dedup surrogates.

### 3. `mem_flt_chained_seeds` (per-seed SW filter) — bwamem.cpp:502-534
Runs `mem_seed_sw` (→ `ksw_align2`, KSW_XSTART, score only) per seed, dropping
seeds with `score < min_HSP_score` (unless the seed is long enough to skip SW).
**This is Smith-Waterman → reuses the restart SW core** (the mate-rescue datapath,
score-only). Gated by `s->len < MEM_SHORT_LEN` and a window-size check.

## FPGA feasibility verdict

Buildable, no fundamental blocker. Complexity is higher than the SW engines
(dynamic insertion + overlap filter), but every piece is bounded and integer:
- kbtree → sorted-array predecessor (bit-identical).
- weight/overlap → integer interval math + small sort + float surrogates.
- per-seed SW → reuse the restart SW core.

Risk areas to pin against captured data: kbtree duplicate-`pos` order; the
`ks_introsort(mem_flt)` tie-order (unstable sort, like the merge-sorter v2 re-sort
— may need a tie fallback); the float-threshold surrogates.

## Verification strategy (differs from the SW engines)

The SW engines compiled their real reference (`ksw_*`) standalone. **Chaining's real
reference can't** — `mem_chain` depends on the FM-index, `kbtree.h`, `bns`, etc. So
bit-exact validation **requires remote capture**:
1. **Capture** (remote, instrument bwamem.cpp): per read, dump the ordered seed
   stream entering `mem_chain` (rbeg, qbeg, len, rid in processing order) and the
   chains exiting `mem_chain_flt` (and optionally after `mem_flt_chained_seeds`).
   Rebuild + run + REVERT to clean, as before.
2. **C++ model** `host/chaining/`: sorted-array `mem_chain` + `mem_chain_flt`
   (+ surrogates), verified bit-exact vs the captured chains.
3. **RTL**: sorted-array chain store + `test_and_merge` datapath + weight/overlap
   filter (+ reuse the merge-sorter for the chain sort and the restart SW core for
   `mem_flt_chained_seeds`); verify vs the model.

Until capture, the C++ model is exercised on synthetic seed streams for sanity only.

## Scope decision

Target stages 1–2 (`mem_chain` + `mem_chain_flt`) as the "chaining engine"; fold
stage 3 (`mem_flt_chained_seeds`) onto the existing restart SW core. This lands the
~11% (chaining) + lets `accel_top` ingest seeds, and the SW reuse keeps stage 3 cheap.
