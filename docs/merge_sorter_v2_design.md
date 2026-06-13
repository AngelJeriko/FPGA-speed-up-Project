# Merge-Sorter v2 — Design (sort + de-overlap + dedup)

v2 extends the verified v1 score-sorter to capture the **full ~22%** `mem_sort_dedup_patch`
hotspot (v1 captured ~half — the post-dedup score sort). Scope is now fully de-risked by
three measurements; this doc fixes the architecture before the build.

Reference: `bwa-mem2/src/bwamem.cpp :: mem_sort_dedup_patch` (lines ~387–453).
Builds on: `docs/merge_sorter_engine_scope.md` (v1), `docs/merge_sorter_v2_tie_analysis.md`.

## What v2 does (the function, in order)

1. **re-sort**: `ks_introsort(mem_ars2)` — by `re` (reference end) ascending.
2. **windowed dedup loop**: for each `i`, scan `j=i-1` down while `same rid` and
   `a[i].rb < a[j].re + max_chain_gap`:
   - **branch A — redundancy** (pure integer): if overlap `or_`/`oq` exceed
     `mask_level_redun · (mr/mq)`, drop the lower-scoring of the pair (`qe=qb`).
   - **branch B — patch/merge**: else if `q.rb<p.rb` and `mem_patch_reg(...)>0` (a banded
     Smith-Waterman gap-fill), merge `q` into `p`.
3. **exclude** dropped hits; **score-sort** (`ks_introsort(mem_ars)`, = v1); **remove
   identical** `(score,rb,qb)` hits; return survivors.

## The three measurements that fix the design

| finding | value | implication |
|---|---|---|
| **N_max** (v1) | true max 1060; N=1024 = 99.97% cost | sorter sized 1024 + n>1024 SW-fallback |
| **re-tie order-sensitivity** | stable≠introsort on 0.063% of arrays; fallback cost 1.21% | re-sort must be stable + **fall back equal-`re`-tie arrays** (1.25%) |
| **branch-B (SW merge) frequency** | **0 merges in 20.09M arrays** (branch A fired 867,341×) | **NO banded-SW core needed**; merge arrays (~0%) fall back |

The third is the key v2 simplifier: on short reads the dedup is **integer-only**. v2 needs
no `mem_patch_reg` / `bsw_*` integration — it is the v1 sorter plus an integer dedup
datapath. (Longer-read workloads may exercise branch B; those arrays take the software
fallback, measured here at ~0%.)

## v2 datapath

```
pre-dedup alnreg array (rb,re,qb,qe,rid,score; in on-chip RAM)
  → STABLE merge-sorter on re-key   (reuse v1 engine, key = re)            [done in v1 form]
  → TIE DETECT: any adjacent equal re? -> raise SW_FALLBACK, abort HW       [cheap compare]
  → WINDOWED DEDUP (integer):
       for i: scan j=i-1 down while rid==  &&  rb_i < re_j + max_chain_gap
         compute or_=re_j-rb_i, oq, mr, mq  (int adds/subs/min)
         if or_*1 > mask_level_redun*mr && oq > mask_level_redun*mq:        [redundancy]
            drop lower-scoring (mark qe=qb)
         else if q.rb<p.rb: -> branch B would fire -> raise SW_FALLBACK      [~0%, abort HW]
  → compact (drop qe==qb)
  → STABLE score-sorter (alnreg_slt, = v1) + identical-(score,rb,qb) removal
  → emit survivors
```

`mask_level_redun` is a float (default 0.5). To stay integer/bit-exact, compare
`2·or_ > mr` style after clearing denominators, or use the exact fixed-point the C++ uses
(`or_ > 0.5·mr` ⇒ `2·or_ > mr`); confirm against the float path in the C++ model.

### Fallback triggers (all bit-exact; hardware emits a "redo in SW" flag)
1. `n > 1024` (oversize) — ~0.03% of cost.
2. array contains an equal-`re` tie — 1.25% of arrays, 1.21% of cost.
3. branch B would fire (a patch/merge) — ~0% on short reads.

## Microarchitecture notes

- **Sorter**: the v1 `msort_merge_sorter` already does a stable key+index merge. v2 uses
  it twice (re-key pre-dedup, score-key post-dedup) — same engine, two passes, or two
  instances. Key width: re ≈ 40 b (already provisioned), score-key 96 b (v1).
- **Windowed dedup**: the hard part. An O(n·window) nested loop with data-dependent early
  termination (`rb_i < re_j + gap`), in-place "excluded" marking (`qe=qb`, skipped via
  `q.qe==q.qb`), and a `break` on the redundancy-and-lower-score case. Maps to a small FSM
  with two index pointers over the re-sorted on-chip array + the integer compare block.
  Throughput is ample (dedup is a fraction of the 22%); optimize for area/correctness.
- **Compaction**: stream-compact survivors (qe>qb) — a single pass with a write pointer.

## Verification plan (same pattern as v1)

1. **Capture v2 golden vectors**: dump each pre-dedup array (rb,re,qb,qe,rid,score, +the
   fields dedup mutates: seedcov,sub,csub,n_comp,w) and the final output array, for
   tie-free / merge-free arrays (the HW-handled set). Skip tie/merge/oversize arrays (they
   fall back).
2. **C++ reference model** (`host/merge_sorter/v2_dedup.*`): stable re-sort + integer
   redundancy dedup + score-sort + identical removal — self-contained (no SW). Already
   validated in essence: the instrumented `tie_test_dedup` (stable variant) matches real
   bwa-mem2 on 99.94% of arrays; the 0.063% are exactly the tie arrays v2 falls back.
3. **RTL** + self-checking TB on the golden vectors, bit-exact.

## Status / next steps

- Architecture: **FIXED** (this doc). No SW core; integer-only; 3 fallback triggers.
- Golden vectors: **CAPTURED** (`host/merge_sorter/vectors/alnreg_v2_vectors.bin.gz` —
  pre-dedup input + real output + has_tie flag, per-size quota 4).
- C++ reference model: **BUILT & VERIFIED** (`host/merge_sorter/v2_dedup.h`, `test_v2.cpp`)
  — **2625/2625 tie-free arrays bit-exact** vs. real bwa-mem2; 815 tie arrays are the
  fallback set (57 diverge, confirming the fallback). Run: `make run_v2`.
- Integer redundancy surrogate: **PROVEN** (`host/merge_sorter/check_redun_int.cpp`) —
  `20·x > 19·y` == float `x > 0.95f·y` with 0 mismatches over the operand range, so the
  RTL uses integer arithmetic, bit-exact.
- **Windowed-dedup RTL: BUILT & VERIFIED** (`rtl/msort_v2_pkg.sv`, `rtl/msort_dedup.sv`,
  `tb/tb_msort_dedup.sv`) — the nested loop + integer redundancy test + in-place exclusion
  + load-time tie-detect (raises a SW-fallback flag), block-RAM (registered read/write).
  Verilator: **1696/1696 records ALL PASS** vs. the validated golden survivors. Run:
  `scripts/run_sim.sh tb_msort_dedup`.
- Next (final v2 integration): wire v1 `msort_merge_sorter` (re-key) → `msort_dedup` →
  `msort_merge_sorter` (score-key) + identical-removal into one top, with the tie/oversize
  fallback flags, and an end-to-end TB on the captured `alnreg_v2_vectors`.
