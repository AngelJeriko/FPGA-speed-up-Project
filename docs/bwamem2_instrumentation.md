# bwa-mem2 Instrumentation — Status & Inventory

All measurements driving the merge-sorter design came from temporary
instrumentation added to **one file**: `bwa-mem2/src/bwamem.cpp` (the production
aligner, NOT in this repo — it lives on the remote `ccloud@216.227.218.169` and the
local Desktop checkout). This documents what is currently in that file, how to
drive it, its overhead, and how to revert to a clean binary.

Pristine backup: `bwamem.cpp.orig` (LF, 116,545 B). Instrumented: `bwamem.cpp`
(125,908 B, ~+9.4 KB ≈ ~200 lines). All additions are tagged `/* INSTRUMENTATION */`
or wrapped in `--- INSTRUMENTATION ... ---` comment banners.

## The three instruments

| # | name | source lines | activated by | output | overhead |
|---|---|---|---|---|---|
| 1 | alnreg count **histogram** | ~161–200 + hooks 484/485/557 | **always on** | `ALNREG_HIST_OUT` (default `alnreg_hist.tsv`) at exit | negligible (atomic increments) |
| 2 | score-sort **vector dumper** | ~202–246 + hook ~536 | env `ALNREG_VEC_OUT` set | that path (binary) | none unless enabled |
| 3 | re-sort **tie-order test** | ~380–475 + hooks 486–489/558 | env `ALNREG_TIE_TEST` set | `ALNREG_TIE_OUT` (default `alnreg_tie.txt`) at exit | ~2× dedup cost when on |

### 1. Histogram (`AlnregHistDumper`)
Counts the pre-dedup array length `n` and post-dedup length `m` entering/leaving
`mem_sort_dedup_patch`, plus an unbounded true-max tracker. Buckets clamp at
`ALNREG_HIST_MAX=4096`. Produced the **N=1024 sizing / true-max 1060** result.
**NOTE: this one is NOT env-gated** — it always counts and always writes a `.tsv`
at process exit. Harmless, but it means even a "normal" run is not pristine. Revert
to `.orig` for a truly clean binary.

### 2. Vector dumper (`VecDumper`)
When `ALNREG_VEC_OUT` is set, captures real `(score,rb,qb)` arrays entering the
post-dedup score sort plus the `ks_introsort` output (ground truth), per-size quota
`VEC_QUOTA_PER_N=32`, `n` in `[2, VEC_NMAX=1060]`. Produced the **21,386 golden
vectors** that verify the v1 C++ model and the RTL (committed as
`host/merge_sorter/vectors/alnreg_vectors.bin.gz`).

### 3. Tie-order test (`TieDumper` / `tie_test_dedup`)
When `ALNREG_TIE_TEST` is set, runs the full dedup twice per array (real
`ks_introsort` re-sort vs `std::stable_sort`) and compares outputs field-by-field,
accumulating divergence + cost-weight stats. Produced the **v2 tie analysis**
(0.063% divergence, 1.21% fallback cost). Doubles dedup work while enabled (a
fraction of total runtime; the run still finishes in ~3.5 min on 10M pairs).

## Output files on the remote (`/home/ccloud/firerate_results/`)

| file | bytes | from |
|---|---|---|
| `alnreg_hist.tsv` | 39,171 | histogram (sizing run) |
| `alnreg_hist_vecrun.tsv` / `alnreg_hist_tierun.tsv` | 39,171 | histogram side-output of the vec / tie runs |
| `alnreg_vectors.bin` (+`.bin.gz`) | 235 MB / 23.5 MB | vector dumper (gz committed to repo) |
| `alnreg_tie.txt` | 347 | tie-order test stats |
| `firerate_summary.tsv` | 436 | earlier EMF fire-rate run |

## Reproduce / drive

```sh
# remote, from the bwa-mem2 dir; pick the env per instrument
ALNREG_VEC_OUT=out.bin  ./bwa-mem2 mem -t16 ref.fa r1 r2 >/dev/null   # vectors
ALNREG_TIE_TEST=1 ALNREG_TIE_OUT=tie.txt ./bwa-mem2 mem ... >/dev/null # tie test
# histogram needs no env (writes alnreg_hist.tsv); set ALNREG_HIST_OUT to redirect
```
Helper scripts on the remote: `remote_alnreg_hist.sh`, `remote_vec_dump.sh`,
`remote_tie_test.sh`.

## Revert to a clean binary (housekeeping — not yet done)

```sh
# remote
cd "/home/ccloud/BWA-MEM2 repo/bwa-mem2" && cp src/bwamem.cpp.orig src/bwamem.cpp && make -j$(nproc)
# local Desktop checkout: restore from its bwamem.cpp.orig (or git checkout) the same way
```
All instrumentation is contained in `bwamem.cpp`; no other source files were
touched, so this single restore fully cleans the tree. Recommended once no further
measurements are planned (none are currently pending — sizing, vectors, and tie
analysis are all complete).

## Status summary

- Sizing (histogram): **DONE** — true max n=1060, N=1024.
- Golden vectors (dumper): **DONE** — committed, verify v1 model + RTL.
- v2 tie analysis (tie test): **DONE** — fallback 1.21%, v2 worth building.
- No further measurement runs pending → instrumentation can be reverted whenever
  convenient. Left in place for now (env-gated except the harmless histogram).
