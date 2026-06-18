# Mate-rescue SW engine — scope, algorithm, and BSW-core reuse

**Date:** 2026-06-17. Next FPGA offload target after `accel_top` (see
`back_half_speedup_analysis.md`): mate-rescue Smith-Waterman, ~9–11% of runtime
(`kswv512_u8`), lifting the cumulative Amdahl ceiling ~1.5×→~1.75×. It **reuses the
verified BSW systolic core** as a second SW mode, so it is mostly orchestration +
a small PE change, not a new datapath.

## What mate-rescue is (bwa-mem2 source)

When one mate of a pair maps but the other doesn't (or maps far away),
`mem_matesw` (`bwamem_pair.cpp:150`) rescues the missing mate: fetch a reference
window around the expected position and run a **full local Smith-Waterman** of the
unmapped read against it. The scalar bit-exact reference is **`ksw_align2`**
(`ksw.cpp:347`); the batched SIMD form actually run is `kswv` (== same result, like
`BandedPairWiseSW`↔`ksw_extend2` for extension).

Call (`bwamem_pair.cpp:208`):
```
xtra = KSW_XSUBO | KSW_XSTART | (l_ms*a < 250 ? KSW_XBYTE : 0) | (min_seed_len*a);
aln  = ksw_align2(qe-qb, query+qb, re-rb, rseq, 5, mat, o_del,e_del,o_ins,e_ins, xtra, 0);
if (aln.score >= min_seed_len && aln.qb >= 0) { ...build alnreg from qb,qe,tb,te... }
```
Consumed result fields: **score, qb, qe, tb, te** (kswr_t also has score2, te2).

## Algorithm = `ksw_align2` (two-pass local SW)

`kswr_t { score, te, qe, score2, te2, tb, qb }`. `ksw_align2`:
1. **Forward pass** — striped local SW (`ksw_u8` / `ksw_i16`, Farrar) over the full
   qlen×tlen rectangle (NO band, NO h0 seed carry-in) → `score, qe, te` (+ XSUBO:
   `score2, te2` = 2nd-best score and its target end).
2. If `KSW_XSTART` and score worth it: **reverse pass** — reverse `query[0..qe]` and
   `target[0..te]`, run the SW again on that prefix with `KSW_XSTOP|score` (stop
   once the score is reached) → `rr`. Then `tb = te - rr.te`, `qb = qe - rr.qe`.
3. `KSW_XBYTE` selects the 8-bit kernel (used when `l_ms*a < 250`); else 16-bit.

So unlike extension (`ksw_extend2`, our current core), mate-rescue is:
- **standard local SW with fresh restart** (a positive-scoring cell can start a new
  alignment anywhere): `H = max(0, diag+s, E, F)` — NOT the `M = diag?diag+s:0`
  no-restart rule of extension.
- **h0 = 0** and all boundaries 0 (no decaying seed-score boundary).
- **two passes** (forward for score+end, reverse for start).
- reports **2nd-best** (`score2, te2`) and an **early-stop** (XSTOP) on the reverse.
- **8-bit OR 16-bit** score width, chosen at runtime.

## BSW-core reuse plan

The systolic array datapath transfers; the differences are localized:

| Piece | Extension (have) | Mate-rescue (need) |
|---|---|---|
| PE recurrence | `M = diag_nz ? diag+s : 0` | **restart mode:** `M = diag + s` (0-floor already from E,F≥0) — add a 1-bit mode |
| first-row init | eh ladder from h0 | all-zero (h0=0) |
| PE_0 col boundary | decaying `h0-(o_del+e_del*(i+1))` | constant 0 |
| max tracker | global max + qle/tle (ext semantics) | max + (qe,te); **plus 2nd-best (score2,te2)** for XSUBO |
| orchestrator | left+right per seed, band-double (no-op) | **2 passes**: forward, then reverse-prefix; combine tb/qb |
| output | rb/re/qb/qe/score/truesc/w | kswr_t {score,qb,qe,tb,te,score2,te2} |
| score width | 16-bit | 8-bit and 16-bit (start 16-bit; XBYTE path later) |

Net new RTL: a restart-mode bit in `bsw_pe`; a zero-init path in `bsw_ctrl_fsm`
(h0=0); a 2nd-best add to `bsw_max_tracker`; and a new 2-pass orchestrator
(`matesw_top`) that runs the array forward, then feeds the reversed prefix and
derives tb/qb. The XSTOP early-stop is a performance opt — a full reverse SW finds
the same argmax, so the model/RTL can run the full reverse pass and match (verified
against golden, like the BSW max_off case).

## Verification strategy (golden-vector methodology, as for BSW)

1. **C++ reference** = the real `ksw_align2` (compile `ksw.cpp` standalone in WSL,
   SSE2 — it IS the bit-exact reference; zero risk).
2. **HW model** `hw_align2`: scalar full-rectangle local SW + 2-pass + kswr_t,
   replicating ksw's score/endpoint/score2 tie-break. Cross-check vs (1) over random
   + boundary inputs (no remote needed).
3. **Capture** real mate-rescue vectors from the remote (instrument the batched
   `kswv` path: query, ref window, scoring, xtra → kswr_t) → confirms `kswv512 ==
   ksw_align2` on real data (as `getScores`↔`ksw_extend2` for extension).
4. **RTL**: array(restart) + 2-pass `matesw_top` + tracker(score2); verify vs the
   HW model on the captured/synthetic vectors.

## Open questions to settle during the build

- **XSUBO / score2**: `mem_matesw` passes XSUBO with subo=min_seed_len*a but only
  reads score/qb/qe/tb/te — confirm score2 never affects the consumed result (it may
  only gate an early return). If so, the tracker can skip 2nd-best for bit-exactness.
- **XBYTE 8-bit overflow**: the 8-bit kernel saturates at 255; `l_ms*a<250` guards it.
  Confirm scores stay in range for our read lengths or model the saturation.
- **Reverse-pass / XSTOP tie-break**: confirm full reverse SW argmax == XSTOP stop
  position on all captured vectors.
- **Reference-window sizing**: measure max (qe-qb) and (re-rb) fed to ksw_align2 for
  mate-rescue (analogous to the BSW resize measurement) to size the array.
