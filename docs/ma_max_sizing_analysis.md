# MA_MAX sizing — the mate-rescue ma register file

**Decision: `MA_MAX = 256`.** Measured, not guessed. This note records the data, the
reasoning, and the options that were rejected, so the choice can be revisited when
synthesis numbers exist.

Date: 2026-07-15. Supersedes the unmeasured `MA_MAX = 64` default that the mate-rescue
stack was built with.

## What MA_MAX bounds

`matesw_pe_top` owns the shared `ma` register file — the mate's alignment-region list that
mate rescue reads, inserts into, and dedups. `MA_MAX` is its depth. The list enters as the
mate read's **post-dedup alnreg list** (`n_ma_init`) and can grow by up to 4 rescue inserts
per candidate, which is why `matesw_orch_top` reserves headroom and gates on
`n_ma_in > MA_MAX - 4`.

If the list does not fit, the read cannot be rescued on-chip and falls back to software.
Before 2026-07-15 the overflow was **not** signalled at all (see
`candidate_extraction_build_log.md`, KNOWN GAP): `matesw_orch_top` raised `overflow` but
`matesw_pe_top` dropped it, and the capacity check happened too late to stop `P_LDMA` from
reading `w_*[k]` past the regfile. Both are now fixed; this note sizes the array.

## The measurement

Source: `firerate_results/alnreg_hist.tsv` — the histogram captured by the merge-sorter
sizing instrumentation (env `ALNREG_HIST`) over a full bwa-mem2 run, hg38 chr1-5.
**26,886,863 post-dedup alnreg lists.** The `post_dedup_m` column is exactly the quantity
that becomes `n_ma_init`, so no new capture was needed.

Reproduce:

```bash
awk -F'\t' 'NR>3 && $1 ~ /^[0-9]+$/ { n=$1+0; m=$3+0; tot+=m; if (n > 60) over+=m }
            END { printf "%d / %d = %.3f%%\n", over, tot, 100*over/tot }' \
    firerate_results/alnreg_hist.tsv
```

### Distribution

The list size is **heavy-tailed** — this is the whole story:

| statistic | value |
|---|---|
| median | 2 |
| mean | 13.36 |
| p90 | 30 |
| p95 | 57 |
| p99 | 228 |
| p99.9 | 525 |
| max | 1060 |

Median 2 but max 1060. Sizing on the mean (or on intuition) is badly wrong here; almost all
reads need a handful of entries and a thin tail needs hundreds.

### Overflow rate vs MA_MAX

| `MA_MAX` | threshold (`MA_MAX-4`) | reads over | per-read rate | ~per-pair rate |
|---|---|---|---|---|
| 64 (old) | 60 | 1,268,729 | **4.719%** | ~9% |
| 128 | 124 | 628,991 | 2.339% | ~4.6% |
| **256 (chosen)** | 252 | 226,588 | **0.843%** | ~1.7% |
| 512 | 508 | 51,291 | 0.191% | ~0.4% |
| 1024 | 1020 | 78 | 0.0003% | ~0.001% |

`MA_MAX=64` lands almost exactly on p95, which is why it overflowed ~4.7% of reads — at
that size it was the **largest single fallback in the design**, bigger than chaining's
dup-pos 3.94%.

The per-pair column assumes the two directions overflow independently
(`1-(1-p)^2`). Mates in repetitive regions are correlated, so the true rate is somewhere
between the per-read and per-pair columns.

Corroboration: `gen_pe2pair_vectors` drops 3 of 94 pairs (3.2%) for having an alnreg list
over 64, which sits inside that band. **Correction to an earlier claim:** those 3 were
described in `candidate_extraction_build_log.md` as "ma-overflow pairs". They are not —
raising `MA_MAX` to 256 did not readmit them, so they are excluded by the *source* bound
(`nout > NSRC`), not the ma bound. Both bounds are driven by the same alnreg-count
distribution, so the number still corroborates the tail; only the attribution was wrong.

## Why 256

Ceiling impact, isolating this lever (52.4% of runtime mapped; rescue alone is 12.5%):

| host redoes... | `MA_MAX=64` | `MA_MAX=256` |
|---|---|---|
| the whole read | 1.91x | 2.06x |
| only the rescue stage | 2.05x | 2.09x |

Two observations drove the decision:

1. **256 buys most of the available win.** 64 -> 256 removes ~82% of the overflow
   (4.72% -> 0.84%) . Going 256 -> 1024 removes almost all the rest but buys only ~0.03x
   more ceiling, because rescue is only 12.5% of runtime.
2. **Fallback granularity matters more than MA_MAX.** Compare the rows, not the columns:
   even at `MA_MAX=64`, redoing only the rescue caps the loss at ~0.05x. The joined top
   therefore uses **stage-specific fallback** — the accel's sorted alnregs have already
   streamed out before rescue runs, so a rescue overflow must not force chaining +
   extension + sort to be redone. That decision is recorded in
   `chaining_extension_wiring_options.md`.

Cost: the regfile is **288 bits/entry** (rb 64 + re 64 + qb/qe/rid/score/cov 32 each).

| `MA_MAX` | bits | bytes | ~M20K if block RAM |
|---|---|---|---|
| 64 | 18,432 | 2.3 KB | ~1 |
| 256 | 73,728 | 9.0 KB | ~4 |
| 512 | 147,456 | 18 KB | ~8 |
| 1024 | 294,912 | 36 KB | ~15 |

In simulation `MA_MAX` costs nothing, so the sim-verified design takes 256 for free.

## Known consequence — the block-RAM conversion (deferred)

`matesw_pe_top` / `matesw_dedup` currently read the ma arrays **combinationally**
(`w_rb[rd_idx]`, `w_rb[k]`, and the dedup's nested `i`/`j` walk). That style infers a
register file plus a `MA_MAX`-to-1 mux per field — fine at 64, and increasingly bad past
~128. At 256 this is 73.7 Kbit of flops and 7x 256-to-1 muxes if synthesized as written.

This is **the same problem the merge-sorter already solved once**: v1 -> v1.1 converted to
registered-read block RAM ("M20K-friendly, 2-cyc/element merge") and re-verified
3441/3441. The same treatment applies here, and the dedup's window break
(`p.rid != rd_q.rid || p.rb >= rd_q.re + GAP`) keeps the walk near-linear rather than
O(n^2), so the extra read latency is affordable.

Deferred because it is a synthesis concern and no synthesis has been run
(see task #12, Quartus). **If synthesis shows the ma regfile hurting Fmax or area, the fix
is the v1.1 conversion, not a smaller MA_MAX** — dropping back to 128 would re-introduce a
2.34%/~4.6% fallback to save 37 Kbit, which is a bad trade.

## Options considered and rejected

- **Keep `MA_MAX=64`.** Rejected: ~9% per-pair fallback is the largest in the design, and
  the array is small enough that the fix is nearly free.
- **`MA_MAX=128`.** The conservative choice — stays comfortably in register-file territory
  with no restructuring. Rejected because it leaves ~2.8x the fallback of 256 (2.34% vs
  0.84%) to save 37 Kbit, and the block-RAM conversion is precedented and deferrable.
- **`MA_MAX=512` / `1024`.** Rejected: 1024 makes overflow essentially vanish (78 reads in
  26.9M) but buys only ~0.03x of ceiling over 256 while doubling/quadrupling the array.
  Revisit **only** if a later measurement shows rescue is a larger share of runtime than
  the 12.5% measured in commit `0b2f56b`.
- **Spill the tail to host memory instead of falling back.** Rejected as premature: it
  trades a 0.84% software redo for a per-read host round-trip in the inner loop, which is
  the same mistake the deferred ref-fetch already represents. Reconsider only if the
  fallback rate ever dominates.
- **Size on the mean (13.4).** Noted only to reject it: the distribution's median is 2 and
  its max is 1060. Any central-tendency sizing is meaningless on this tail.

## Related: NSRC is a different bound, and it is safe (unchecked invariant)

`NSRC` (matesw_pe_sel_top's candidate-source buffer, 64) is fed by the *same* alnreg-count
distribution, so the obvious worry is that it overflows at the same ~4.7%. **It does not,
and it needs no fallback.** The selection is a prefix gate:

```
S_CHECK: if (j < nsrc_r && $signed({16'd0, j}) < maxm_r && s_sc[j] >= thr) ...
```

so it only ever examines the first `min(n_src, max_matesw)` candidates. bwa's default
`max_matesw` is **50**, below `NSRC=64`. Source beats past 64 are dropped by the write
guard (`src_ld_idx < NSRC`) but are never read, and since the accel output is already
score-sorted descending, the first 50 are exactly the ones the gate wants. Model (`pe.h`)
and RTL agree because both cap at `max_matesw`.

The safety therefore rests on **`max_matesw <= NSRC`**, which nothing checks. It holds at
bwa defaults and for every configuration the generators produce (`max_matesw` is 50, or
1-3 in 20% of cases). If `max_matesw` were ever configured above `NSRC`, `s_sc[j]` would be
read past the buffer and the selection would silently use garbage — the same failure class
as the two overflow gaps this note accompanies.

Follow-ups (not done):
- Guard the invariant explicitly (`max_matesw > NSRC` -> raise a fallback), consistent with
  how every other capacity limit in the design is handled.
- `gen_pe2_vectors` / `gen_pe2pair_vectors` skip cases with `nout > NSRC`. Per the argument
  above this is **over-conservative** — those cases are legal and would exercise the
  "n_src exceeds the buffer, only the prefix matters" path that nothing currently tests.
  Relaxing it would readmit the 3 pairs above.

## Caveats

- One reference (hg38 chr1-5) and one library. The tail is driven by repetitive/multi-
  mapping regions, so a full-genome reference or a more divergent sample would likely make
  it **heavier**, not lighter — 256 has margin (p99=228) but not much beyond p99.
- The histogram counts alnreg lists per read; the ma list additionally grows by up to 4 per
  rescued candidate. The `MA_MAX-4` headroom covers one candidate's inserts, and the
  per-candidate re-check catches growth across candidates, so the rates above are a slight
  **under**-estimate of the true overflow rate. The effect is small (most reads have very
  few candidates) but it is not zero.
