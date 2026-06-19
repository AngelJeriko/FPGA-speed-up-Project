# Remote capture plan — one batched session (mate-rescue + chaining)

**Date:** 2026-06-18. The next remote session validates the two C++ models that are
built but **unvalidated against real data**: mate-rescue (`host/mate_rescue/hw.h`)
and chaining (`host/chaining/chain.h`). Item 3 of the old plan — back-half timing —
is **already DONE** (commit `0b2f56b`; accel_top 1.53×, +mate-rescue 1.89×,
+chaining 2.10×), so this session does NOT re-profile.

Everything here is **staged and compile-checked locally**; the remote session is a
mechanical paste → build → run → copy-back → revert. Remote =
`ccloud@216.227.218.169`, SSH **via WSL** (`wsl bash -lc "ssh ccloud@... ..."` —
Windows-side ssh fails "too many auth failures"). Repo symlink `~/bwa2`.

## What gets instrumented

| capture | file | env (out / cap) | model it validates |
|---|---|---|---|
| mate-rescue kernel | `src/bwamem_pair.cpp` | `ALNREG_MATE_OUT` / `ALNREG_MATE_MAX=200000` | `hw_align2` (kswv512 == ksw_align2 == hw.h on real data) |
| mate-rescue orchestration | `src/bwamem_pair.cpp` | `ALNREG_ORCH_OUT` / `ALNREG_ORCH_MAX=100000` | `matesw_orchestrate` (orch.h: skip/window/SW/transform/insert/dedup) |
| chaining | `src/bwamem.cpp` | `ALNREG_CHAIN_OUT` / `ALNREG_CHAIN_MAX=30000` | `c_mem_chain` + `c_mem_chain_flt` |

Both are env-gated (zero cost unless the env var is set) and follow the proven
`ExtDumper` pattern (spinlock + globally-unique id + tagged binary records).
**Note: this touches a SECOND source file** (`bwamem_pair.cpp`) beyond the usual
`bwamem.cpp` — both must be reverted afterward.

## Staged artifacts (this repo)

- `host/mate_rescue/capture/matesw_capture.inc` — paste-ready infra + 2 hooks
  (snapshot inputs before the forward `getScores`, outputs after the reverse pass).
- `host/mate_rescue/capture/orch_capture.inc` — paste-ready infra + 3 hooks in
  `mem_matesw_batch_post` (entry snapshot, per-orientation window, write-at-return);
  validates the orchestration model `orch.h`. Both `.inc` go in `bwamem_pair.cpp`.
- `host/chaining/capture/chain_capture.inc` — paste-ready infra + 3 hooks
  (seed-stream accumulate in `mem_chain`; SEEDSTREAM+pre-flt record after
  `__kb_traverse`; pre/post snapshot around the `mem_chain_flt` call).
- `scripts/remote_batched_capture.sh` — arch-detect → rebuild → 50k-pair PE run
  with **all three** captures armed → one paired run produces all three `.bin`s.
- `host/mate_rescue/check_capture.cpp` (`make checkcap`) — runs `hw_align2` on each
  captured input, compares score/qb/qe/tb/te to the captured kswv output.
- `host/mate_rescue/check_orch.cpp` (`make checkorch`) — replays each captured
  `mem_matesw` call through `matesw_orchestrate`, compares the exit ma list
  (rb/re/qb/qe/rid/score/is_alt/seedcov). Round-trip self-tested 3000/3000.
- `host/chaining/check_capture.cpp` (`make checkcap`) — runs `c_mem_chain` /
  `c_mem_chain_flt` on each captured input, compares to captured chains.

## Record formats (binary, native little-endian)

**Mate-rescue** (`matesw_capture.inc`; join INPUT↔OUTPUT by `aln_id`):
```
type 0 INPUT : i32 type=0; i64 aln_id; i32 qlen; i32 tlen; i32 xtra;
               i32 a; i32 b; i32 o_del; i32 e_del; i32 o_ins; i32 e_ins;
               u8 query[qlen]; u8 ref[tlen]
type 1 OUTPUT: i32 type=1; i64 aln_id; i32 score; i32 qb; i32 qe; i32 tb; i32 te
```
The host rebuilds `mat` from (a,b) via `bwa_fill_scmat` (match=a, mismatch=−b, N=−1).

**Mate-rescue orchestration** (`orch_capture.inc`; one record per `mem_matesw_batch_post`
call). `ALNREG_REC` (32 B) = `i64 rb; i64 re; i32 qb; i32 qe; i32 rid; i32 is_alt; i32 score; i32 seedcov`.
```
type 0 ORCH: i32 type=0; i64 call_id; i64 a_rb; i32 a_rid; i32 a_is_alt;
             i64 l_pac; i32 l_ms; u8 ms[l_ms];
             i32 cfg[7]={a,b,o_del,e_del,o_ins,e_ins,min_seed_len};
             4*{ i32 failed; i64 low; i64 high };               // pes[4]
             i32 n_in;  n_in *ALNREG_REC;                        // ma @entry
             4*{ i32 used; i64 rb; i64 re; i32 rid; i64 reflen; u8 ref[reflen] };  // host-fed windows
             i32 n_out; n_out*ALNREG_REC;                        // ma @exit
```
Host-fed reference (Stage-1): the model takes the post-`bns_fetch_seq` windows as given.

**Chaining** (`chain_capture.inc`; each record self-contained — no cross-join).
CHAIN sub-record = `i32 rid; i32 seqid; i64 pos; i32 is_alt; i32 n;
n*{i64 rbeg; i32 qbeg; i32 len; i32 score}`.
```
type 0 SEEDSTREAM: i32 type=0; i64 read_id; i32 seqid; i64 l_pac; i32 n_seeds;
                   n_seeds*{i64 rbeg; i32 qbeg; i32 len; i32 score; i32 rid; i32 is_alt};
                   i32 n_chains; n_chains*CHAIN   (= pre-flt chains)
type 1 FLT:        i32 type=1; i64 flt_id; i32 n_in;  n_in *CHAIN (pre-flt);
                                            i32 n_out; n_out*CHAIN (post-flt)
```

## Runbook

1. **Backup** (if not already): `cp src/bwamem.cpp src/bwamem.cpp.orig` and
   `cp src/bwamem_pair.cpp src/bwamem_pair.cpp.orig`. (bwamem.cpp.orig already
   exists from prior sessions — confirm it is the CLEAN one first.)
2. **Paste** the three `.inc` files per their `STEP` headers (anchors are quoted in
   each file). `matesw_capture.inc` **and** `orch_capture.inc` → `bwamem_pair.cpp`;
   `chain_capture.inc` → `bwamem.cpp`.
3. **Run** `scripts/remote_batched_capture.sh` (rebuilds the dispatched arch,
   produces `~/cap_batched/{mate_vec.bin,orch_vec.bin,chain_vec.bin}`).
4. **Copy back** (via WSL scp → /tmp → cp), gzip, drop into
   `host/mate_rescue/vectors/` and `host/chaining/vectors/`.
5. **Validate locally:**
   - `cd host/mate_rescue && make checkcap && ./check_capture vectors/mate_vec.bin`
     → expect `ALL PASS` (confirms kswv512 == hw_align2 on real data).
   - `cd host/mate_rescue && make checkorch && ./check_orch vectors/orch_vec.bin`
     → expect `ALL PASS` (confirms orch.h reproduces mem_matesw orchestration).
   - `cd host/chaining && make checkcap && ./check_capture vectors/chain_vec.bin`
     → expect `mem_chain 0 failures` + `mem_chain_flt 0 failures`.
6. **REVERT both files** and rebuild a clean binary:
   ```sh
   cp src/bwamem.cpp.orig src/bwamem.cpp
   cp src/bwamem_pair.cpp.orig src/bwamem_pair.cpp
   make arch=avx512 EXE=bwa-mem2.avx512bw all
   ```

## What to watch for (the model risks this run resolves)

- **Chaining `mem_chain_flt` tie-order** — `ks_introsort(mem_flt)` is unstable; the
  model uses `std::stable_sort`. If `check_capture` shows `mem_chain_flt` failures,
  they are almost certainly equal-weight tie reorderings → add a tie fallback
  (mirror the merge-sorter v2 equal-`re` decision), then re-validate offline.
- **Chaining duplicate-`pos`** — two chains sharing a first-seed `rbeg`; the
  sorted-array predecessor must return the same `lower` the kbtree does. Surfaces
  as a `mem_chain` failure if wrong.
- **Mate-rescue XBYTE saturation** — the 8-bit kernel saturates at 255 (guarded by
  `l_ms*a<250`). hw.h does not model saturation; if any `make checkcap` mismatch
  has a near-255 score, that is the cause (expected to be none for 101–250 bp).
- **score2/te2** — captured for neither (mem_matesw ignores them); not compared.
- **Orchestration `mr_dedup` re-sort** — uses `std::stable_sort`; real `mem_sort_dedup_patch`
  uses unstable `ks_introsort`, but mate-rescue ma arrays are tiny (below introsort's
  insertion-sort threshold ⇒ stable), so equal-`re` ties should match. A `check_orch`
  failure on an equal-`re` array means revisit (same fallback story as merge-sorter v2).
  `csub` (=`aln.score2`) is intentionally not modeled and excluded from the comparison.

## After this session

- Chaining RTL (sorted-array chain store + `test_and_merge` + weight/overlap filter;
  reuse merge-sorter for the chain sort, restart SW core for `mem_flt_chained_seeds`).
- Fold `matesw_top` into a paired-end / accel top-level (it is built + sim-verified
  at 4000/0, just not yet wired into a top).
- Deferred: physical synthesis (Quartus); Stage-2 on-chip reference-fetch.
