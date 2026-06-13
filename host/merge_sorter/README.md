# Alignment-Register Merge-Sorter — v1 C++ model

Cycle-approximate C++ model of the **folded merge-sorter** engine that attacks the
~22% `ks_introsort` hotspot in bwa-mem2 (see `docs/merge_sorter_engine_scope.md`).
This is the *reference/architecture* model built before the SystemVerilog RTL; the
RTL will be validated against the same golden vectors.

## What v1 does

Reproduces the **post-dedup `alnreg_slt` score sort** (`bwamem.cpp` line ~385):
`score` descending, then `rb` ascending, then `qb` ascending. This sort is
**provably bit-exact** to reproduce because its input has a strict total order —
measured 0 equal-`(score,rb,qb)` ties across 21,386 real records (n=2..1060), so any
correct sort yields the identical order to (unstable) `ks_introsort`.

## Files

| file | role |
|---|---|
| `key.h` | `AlnKey` struct, `alnreg_slt` comparator, and `pack_key()` — packs `(score,rb,qb)` into a 96-bit composite so one **unsigned** compare == the comparator. Layout: `[95:64] 0x7FFFFFFF-score`, `[63:24] rb`, `[23:0] qb`. |
| `folded_sorter.h` | `folded_merge_sort()` — bottom-up (iterative) merge sort on `(key,index)` pairs. Models one reusable merge unit swept once per pass (ceil(log2 n) passes); `N_MAX=1024` capacity with n>1024 software fallback and an n<=1 fast-path. |
| `test_sorter.cpp` | Self-checking testbench: packs real INPUT keys, runs the model, gathers, asserts output == EXPECTED (real `ks_introsort` output) bit-for-bit; cross-checks packing vs. comparator; reports size/pass/path stats and field-width headroom. |
| `vectors/alnreg_vectors.bin.gz` | Golden vectors from a real chr1-5/HG00733 run (gunzip before use). Per-record: `int32 n; n*{score,rb,qb} INPUT; n*{...} EXPECTED`. Per-size quota 32; n in [2,1060]. The raw `.bin` is git-ignored (235 MB). |

## Build & run

```sh
cd host/merge_sorter
gunzip -k vectors/alnreg_vectors.bin.gz   # -> vectors/alnreg_vectors.bin (235 MB)
make run
```

Expected: `RESULT: ALL PASS` — 21,386/21,386 records bit-exact, `packing!=cmp = 0`.

## Sizing (measured 2026-06-13, chr1-5/HG00733, 26.9M sort calls)

True max n = **1060**. `N_MAX=1024` captures **99.97%** of sort cost; n in (1024,1060]
= 0.03% of cost -> software fallback. Cost is tail-dominated (N<=128 = only 42% of
cost), so a fixed small bitonic network is the wrong design; a scalable folded merge
sorting `(key,index)` pairs is required. Worst-case 11 merge passes.

## Generating fresh vectors (optional)

The `INSTRUMENTATION` blocks in `bwa-mem2/src/bwamem.cpp` (histogram + vector dumper)
produce these. Set `ALNREG_VEC_OUT=path.bin` and run `bwa-mem2 mem`; per-size quota is
`VEC_QUOTA_PER_N`. Revert instrumentation (`bwamem.cpp.orig`) for a clean binary.

## RTL (done)

`folded_merge_sort` is implemented in SystemVerilog at `rtl/msort_merge_sorter.sv`
(+ `rtl/msort_pkg.sv`) and verified bit-exact against the same golden vectors by
`tb/tb_msort.sv`: **3441/3441 records, 1.5M elements, ALL PASS** under Verilator.
Run it with `scripts/run_sim.sh tb_msort` (it auto-generates the TB vector file from
`vectors/alnreg_vectors.bin.gz` via `gen_rtl_vectors.py`).

## Next

- Synthesize the RTL for Fmax/area on the target part; move from comb-read RAM to
  registered-read block RAM.
- v2: combined sort + de-overlap + dedup engine (the `alnreg_slt2` re-sort + the
  order-dependent dedup loop + the `mem_patch_reg` merge), capturing the full ~22%.
