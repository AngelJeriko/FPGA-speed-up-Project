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

`mask_level_redun` is a float, **default 0.95** (distinct from `mask_level`/`drop_ratio`,
which are 0.5 and are used elsewhere — chaining/primary-marking — NOT in this redundancy
test). To stay integer/bit-exact, clear the denominator: `or_ > 0.95·mr` ⇒ `20·or_ > 19·mr`
(0.95 = 19/20, exact rational). This surrogate is **proven** equal to the float path
`or_ > 0.95f·mr` over the operand range with 0 mismatches by
`host/merge_sorter/check_redun_int.cpp`; the C++ model (`v2_dedup.h`) uses the float form,
the RTL (`msort_v2_pkg.sv`, `RED_NUM/RED_DEN = 20/19`) uses the surrogate.

### Fallback triggers (all bit-exact; hardware emits a "redo in SW" flag)
1. `n > 1024` (oversize) — ~0.03% of cost.
2. array contains an equal-`re` tie — 1.25% of arrays, 1.21% of cost.
3. branch B would fire (a patch/merge) — ~0% on short reads.

> **~~KNOWN GAP (logged 2026-06-19)~~ FIXED 2026-07-15: trigger #1 is specified but NOT
> implemented in RTL.** No module actually checks the element count against `N_MAX`:
> - `msort_v2_top` raises `fallback` only on the adjacent-equal-`re` tie; load uses
>   `wr_addr = wptr[IDX_W-1:0]` (low 10 bits), so element 1024 aliases to address 0 and
>   `n` (11-bit `cnt_t`) keeps counting — the sort then runs over a corrupted bank.
> - `accel_top` wires `fallback <= ms_fallback` and has no `surv_cnt > N_MAX` check (even
>   though `surv_cnt` is already computed in pass A / `C_FIND_EVAL`).
> - `orch_read_top` is the *earliest* overflow point: it writes `av_*[av_wptr]` into
>   `NAV=1024`-deep arrays with an uncapped 16-bit `av_wptr` and exports `o_nav = av_wptr`
>   with no cap, so the orchestrator's own buffers alias on write before accel even counts.
>
> Effect: an oversize read (`n > 1024`) produces **silently wrong output with `fallback`
> stuck low**, instead of the intended clean SW handoff. It is currently masked because
> oversize arrays are rare (~0.03% of cost) and none appear in the sampled `tb_accel_top`
> vectors, so all tests pass.
>
> **FIXED 2026-07-15, exactly as prescribed above — guarded at all three layers:**
>
> | layer | guard | role |
> |---|---|---|
> | `orch_read_top` | `av_wptr >= NAV` (and `cj >= NCH`) -> `overflow` output | **earliest**: stops the aliasing write before it happens; `av_wptr` holds at `NAV` so `o_nav` stays truthful; the read still completes |
> | `accel_top` | `rt_ovf \|\| surv_cnt > N_MAX` in `C_DECIDE` -> `fb_latch`, `C_DONE` | never streams an oversize array; `surv_cnt` was already computed by pass A, so the check is free |
> | `msort_v2_top` | load gated on `wptr < N_MAX`, `wptr` saturates, run ends in `fallback` with no beats | self-guard: the module is independently verified and directly drivable (`tb_msort_v2`), so it must honour its own port contract regardless of who drives it |
>
> The purge av-buffer write (`pg_av_ld`) is gated on the same capacity so it cannot alias
> either.
>
> Verified: tb_msort_v2 2480 arrays unchanged + **OVF-TEST** (n=1029, strictly increasing
> `re` so the tie path cannot be the cause -> `fallback=1`, 0 beats) + **RECOVERY** (a clean
> array immediately after an overflow is still bit-exact, proving no stuck state);
> tb_orch_read_top 200/0 with `overflow` asserted low on every real-data read;
> tb_accel_top 200/0. The directed test feeds a real >`N_MAX` array rather than a
> small-`N_MAX` build, because `N_MAX` is a package parameter (`msort_v2_pkg`), not a module
> parameter, so a second shrunken DUT is not instantiable the way `chain_store`'s
> `NCHAIN=8` OVF-TEST is.

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
  `tb/tb_msort_dedup.sv`) — Verilator **1696/1696 ALL PASS**. Run: `scripts/run_sim.sh
  tb_msort_dedup`.
- **FULL v2 ENGINE: BUILT & VERIFIED** (`rtl/msort_v2_top.sv`, `tb/tb_msort_v2.sv`) —
  one module doing LOAD → re-sort → windowed dedup → compact → score-sort →
  identical-removal → OUT over two ping-pong record banks, reusing the verified merge-sort
  algorithm (key-selectable comparator) for both sort passes and the verified dedup loop;
  raises `fallback` on equal-`re`-tie arrays. Verilator end-to-end (raw pre-dedup input →
  final output) vs. **real bwa-mem2**: **1696/1696 tie-free arrays ALL PASS**. Run:
  `scripts/run_sim.sh tb_msort_v2`. **v2 COMPLETE.**

## Final status: the merge-sorter engine is DONE

v1 (score sort) and v2 (full sort + de-overlap + dedup) are both implemented in
SystemVerilog and verified bit-exact against real bwa-mem2 data:
`scripts/run_sim.sh {tb_msort, tb_msort_dedup, tb_msort_v2}` → all ALL PASS.
Remaining: synthesis on Quartus (`scripts/synth_msort.tcl`, needs the tool) for Fmax/area.
