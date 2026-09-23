# Golden I/O capture for the banded SWA extension kernel

Milestone: *"dump the ksw_extend inputs/outputs from bwa-mem2 on a small test
set (a few thousand reads vs E. coli), then show an HLS kernel reproducing
them bit-for-bit in C-sim and co-sim."*

This document covers the first half — the dump and its verification. The HLS
kernel is the next step.

## The catch: `ksw_extend` is dead code in bwa-mem2

`ksw_extend()` / `ksw_extend2()` live at `src/ksw.cpp:432` and `:537`. Nothing
outside `src/ksw*` calls them:

```
$ grep -rn 'ksw_extend' src/ --include=*.cpp --include=*.h | grep -v '^src/ksw'
$            # (no output)
```

A hook there captures nothing. The extension that actually runs is Intel's
`BandedPairWiseSW`, driven in **batches** from `mem_chain2aln`
(`src/bwamem.cpp`) over arrays of `SeqPair`.

A `SeqPair` *is* one `ksw_extend` call. From
`BandedPairWiseSW::scalarBandedSWAWrapper` (`src/bandedSWA.cpp`):

```c
uint8_t *seq1 = seqBufRef + p->idr;              // target
uint8_t *seq2 = seqBufQer + p->idq;              // query
p->score = scalarBandedSWA(p->len2, seq2, p->len1, seq1, w, p->h0,
                           &p->qle, &p->tle, &p->gtle, &p->gscore, &p->max_off);
```

which is `ksw_extend2`'s signature exactly. So we capture at the `SeqPair`
level: inputs `len2`/`len1`/`h0` + the two sequence slices + `w` and the
scoring parameters; outputs the six fields `score, qle, tle, gtle, gscore,
max_off`.

## Where the hook goes

`mem_chain2aln` runs **six** extension batches — left and right, each split
three ways by sequence length: a scalar batch, a 16-bit SIMD batch
(`getScores16`) and an 8-bit SIMD batch (`getScores8`). Each sits inside a
`MAX_BAND_TRY` retry loop that widens the band (`w = opt->w << i`) and
re-runs the pairs that did not converge, ping-ponging through `pair_ar_aux`.

`host/bwamem2_patch/swa_capture.inc` adds one `bswcap_batch()` call after each
of the six batches, anchored structurally on the `tprof[PE*][0] += nump;`
accounting lines. `host/bwamem2_patch/apply_swa_capture.sh` inserts them
mechanically and is idempotent. Capture is off unless `BSW_CAPTURE_OUT` is set.

Capturing per band-try iteration means a retried pair yields one record per
attempt — each is a legitimate independent extension call with its own `w`.

## Reproducing

```sh
./scripts/make_ecoli_dataset.sh      # ASM584v2 + 5,000 wgsim pairs x 150 bp, seed 42
./scripts/capture_swa_ecoli.sh       # patch, build, align, verify
./scripts/capture_swa_ecoli.sh --restore
```

Run bwa-mem2 with `-t 1` (the script does) so record order is deterministic.

## Result

```
records : 49468   (scalar=0  simd16=44621  simd8=4847)
envelope: max qlen=131  max tlen=437  max w=100  max h0=149  max band_try=0
PASS: 49468/49468 bit-exact, 0 mismatches
```

49,468 extension calls from 5,000 read pairs, every one replayed through
`host/extend_orchestrator/ksw.h` (our `ksw_extend2` port — the numeric
reference the FPGA BSW core reproduces) and matched on all six outputs.

The hook is non-invasive: the SAM from the instrumented run is byte-identical
to the stock run.

`host/swa_hls/` holds the verifier (`replay_swa.cpp`) and `make check`. The
committed vectors are a 2,000-record subset (`vectors/ecoli_swa_2k.bin.gz`,
127 KB); the full 49,468 regenerate from the script above.

## Mutation check

A green replay proves nothing until it can go red. Mutating `ksw.h`:

| mutant | change | result |
|---|---|---|
| M1 | deletion gap-open `M - oe_del` -> `M - o_del` | **RED** 395 mismatches |
| M2 | swap `e_del`/`e_ins` in the z-drop test | GREEN — *equivalent mutant* |
| M3 | `eh[0].h = h0` -> `h0 + 1` | **RED** 48,882 mismatches |
| M4 | drop `end_bonus` from `max_ins` | **RED** 364 mismatches |

M2 survives legitimately: bwa-mem2's defaults are `e_del == e_ins == 1`, so the
swap is a semantic no-op. It is a coverage limit, not a weak test — see below.

## Characterised divergence (ksw_extend2 vs bwa-mem2, perturbed parameters)

At **default parameters the model is exact** (0 / 49,468). Perturbing the
scoring or the band exposes a rare disagreement — 7 records across four
configurations, ~0.004%:

| config | records | mismatches |
|---|---|---|
| defaults | 49,468 | **0** |
| `-O 6,7 -E 2,1 -w 12` | 49,408 | 2 |
| `-O 6,7 -E 2,1` | 49,468 | 1 |
| `-w 12` | 49,408 | 2 |
| `-w 30` | 49,413 | 2 |

Every divergence is confined to `gtle`/`gscore`; `score`, `qle`, `tle` and
`max_off` always agree. In all 7, bwa-mem2 reports `gscore = 0`. In 5 of them
the model reports `gscore = -1` — its initial value, i.e. *"no cell reached the
end of the query within the band"*. The two kernels use **different sentinels
for the unreachable-query-end case**, and `gtle` is then a companion value that
was never meaningfully set. The remaining 2 records have model `gscore = 3` vs
golden `0`.

This is SAM-neutral in every observed case. The consumer in `bwamem.cpp` is:

```c
if (sp->gscore <= 0 || sp->gscore <= a->score - opt->pen_clip5) {
    a->qb -= sp->qle; a->rb -= sp->tle;      /* gtle unused on this branch */
```

`0`, `-1` and `3` (against `score=19`, `pen_clip5=5`) all take the same branch,
so `gtle` is never read. That is *why* the defaults run is clean and why this
never perturbs alignment output — but it is a real fidelity limit of `ksw.h`
as a reference model, and it lands squarely on `gscore`, the same output that
the 2026-08-07 `bsw_pe` gap-open fix turned out to affect.

The 7 records are committed as `host/swa_hls/vectors/divergent_*.bin.gz`.
`make check` asserts they still fail — if one starts passing, the edge moved
and this section is stale.

## Coverage limits of this vector set

Worth knowing before sizing the HLS kernel:

- **`scalar = 0`** — no pair was long enough to fall out of the SIMD lanes, so
  the scalar-overflow route is unexercised.
- **`max band_try = 0`** — with the default `w = 100` the band-widening retry
  never fired. `-w 12` forces it.
- **symmetric gaps** — defaults give `e_del == e_ins`, so del/ins asymmetry is
  not distinguished (this is what lets M2 survive).
- **envelope** — `qlen <= 131`, `tlen <= 437`, `w <= 100`, `h0 <= 149`. 150 bp
  reads against a 4.6 Mbp reference; longer reads or a larger reference will
  widen it. Size HLS buffers from the envelope *plus headroom*, not from it.
