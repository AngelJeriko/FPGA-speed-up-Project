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

A line-by-line walkthrough of both scripts — every flag, and the guards that
exist because something once went wrong — is in `docs/ecoli_dataset.md`.

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

---

# Human-genome re-capture (2026-10-03)

The *E. coli* set was small and clean by design. This run repeats the capture on
human data to answer two questions: does bit-exactness hold at scale on real,
messy reads, and is the RTL's input envelope (`MAX_QLEN=160`, `MAX_TLEN=1024`)
actually big enough?

## Two sets

| Set | Reads | Reference | Records |
| --- | --- | --- | --- |
| Real | 200,000 pairs of ERR174310, 101 bp | hg38 chr1-5 | **15,437,657** |
| Stress | 60,000 simulated pairs, 150 bp, 10x mutation rate, 2x indel fraction, seed 42 | hg38 chr1-5 | **2,718,372** |

The real reads are 101 bp, which cannot stress `qlen`. The stress set exists to
cover that: 150 bp is the length the hardware is sized for, and the elevated
divergence widens the reference windows that set `tlen`.

## Bit-exactness: 18,156,029 records, zero mismatches

```
real   : reference vs golden PASS 15437657/15437657   hls vs golden PASS   hls vs reference PASS
stress : reference vs golden PASS  2718372/2718372    hls vs golden PASS   hls vs reference PASS
```

That is **367x the original *E. coli* evidence**, on real human reads, with no
disagreement anywhere.

## Envelope: the headroom is much thinner than *E. coli* suggested

| Set | max qlen | max tlen | tlen vs `MAX_TLEN=1024` |
| --- | --- | --- | --- |
| *E. coli*, 150 bp simulated | 131 | 437 | 43% |
| Human real, 101 bp | 82 | 783 | 76% |
| **Human stress, 150 bp** | **131** | **997** | **97.4%** |

`rtl/bsw_pkg.sv` already documented `tlen <= 786` from an earlier HG00733
capture, and the 101 bp real set corroborates it at 783. But the 150 bp stress
set reaches **997 — 27 bases from the limit**. The envelope is sound for the
workload it was sized against, and it is *not* comfortable: a longer read set,
or a more divergent sample, can exceed it.

`qlen` tops out at exactly 131 on both 150 bp sets, matching the documented
figure, against `MAX_QLEN=160` (22% headroom).

Also notable: the SIMD route mix inverted. *E. coli* was 90% 16-bit path; the
real human set is 83% **8-bit** path. So this run exercised a materially
different route through bwa-mem2's batching than the original capture did.
Still unexercised by any real dataset: the scalar-overflow route (`scalar=0`)
and the band-widening retry (`max band_try=0`).

`tlen == 0` does not occur: the minimum across all 18.2M records is 2.

## The defect this found

Measuring 997 against a 1024 limit prompted the obvious question: what does the
hardware do if `tlen` ever exceeds `MAX_TLEN`? The answer was **nothing good**.

`bsw_ctrl_fsm.sv` rejected only `qlen > N_PE`. There was no `tlen` check, and
the target read indexes with

```systemverilog
tgt_r <= target_q[tgt_ra_idx[$clog2(MAX_TLEN)-1:0]];
```

a 10-bit truncation. An oversize `tlen` would **silently wrap** the target walk
and return a plausible-looking score with `error = 0` — the worst failure mode
available, since the host has no way to detect it.

Fixed by extending the existing guard, with the condition factored into one
named wire so it cannot drift between its three use sites:

```systemverilog
wire req_oversize = (cfg_i.qlen > len_t'(N_PE)) ||
                    (cfg_i.tlen > len_t'(MAX_TLEN));
```

Two new tests in `tb/tb_bsw_top.sv`, both mutation-checked:

| Test | Asserts | Mutant that kills it |
| --- | --- | --- |
| T7b | `tlen > MAX_TLEN` sets `error`, zeroes outputs | dropping the `tlen` term -> **returns score=2, qle=1, tle=1, error=0** |
| T7c | `tlen == MAX_TLEN` is still **accepted** | `>` becomes `>=` -> boundary wrongly rejected |

MF1's failure output is the bug demonstrated rather than argued: without the
guard the design answers an impossible request with a confident wrong number.

Full suite re-run after the fix: `tb_bsw_top` 31/0, `tb_bsw_pe` 18/0,
`tb_bsw_axil`, `tb_bsw_axil_cdc`, `tb_bsw_axis`, `tb_bsw_ext` (15,887 real
extensions, 0 failures), `tb_cl_bsw_ocl`, `tb_cl_bsw_ocl_f2` — all pass.

## Reproducing

```sh
# real reads
head -n 800000 ~/reads/sub10_1.fq > h200k_1.fq   # and _2
# stress set
wgsim -N 60000 -1 150 -2 150 -r 0.01 -R 0.3 -X 0.5 -S 42 \
      hg38_chr1-5.fa sim150_1.fq sim150_2.fq
# then, for each pair:
host/bwamem2_patch/apply_swa_capture.sh <bwa-mem2>
BSW_CAPTURE_OUT=out.bin <bwa-mem2>/bwa-mem2 mem -t 1 hg38_chr1-5.fa R1 R2 > /dev/null
host/swa_hls/replay_swa out.bin
```

The captures are 2.5 GB and 0.4 GB, so they are not committed; the commands
above regenerate them.

---

# Driving the new captures through the real RTL (2026-10-04)

The captures above verify the C models. This section pushes them through the
hand-written SystemVerilog `bsw_top` — the design that actually goes to silicon.

`tb/tb_bsw_ext.sv` already did this against `ext_sw_vectors.txt`, 15,887
extensions from the *older* `ext_capture` hook. The new captures come through
`swa_capture.inc` at the `SeqPair` level and are a different, much larger
dataset, so `host/swa_hls/gen_rtl_vectors_from_cap.cpp` converts them into the
testbench's vector format.

## Result: 34,000 extensions, 0 failures

| Vector set | From | Extensions | Max tlen | Result |
| --- | --- | --- | --- | --- |
| `rtl_ecoli` | E. coli capture | 10,000 | 437 | **0 failures** |
| `rtl_human` | 200k real ERR174310 pairs | 12,000 | 783 | **0 failures** |
| `rtl_sim150` | 150 bp high-divergence set | 12,000 | **997** | **0 failures** |

The sim150 set includes both records in the whole 2.7M capture with
`tlen >= 900`, so this is the first time `bsw_top` has been exercised within 27
bases of its `MAX_TLEN = 1024` limit — the same boundary the new `req_oversize`
guard protects.

`run_sim.sh` gained a `BSW_EXT_VEC` override so the same testbench can run
against any generated set.

## Which model supplies which expected value, and why

Getting this wrong cost two debugging rounds, so it is worth stating plainly.

**`score`, `qle`, `tle` come from bwa-mem2.** That is the real cross-check.
Across all 34,000 records the full-DP array model agreed with bwa-mem2 on all
three, every time — the generator drops any record where it does not, and it
never fired.

**`gscore` and `gtle` cannot come from bwa-mem2.** `bsw_top` computes the
**full unbanded DP** and so updates `gscore`/`gtle` on every row; ksw stops once
its band narrows past the query end. Both are correct for their own algorithm.
Feeding ksw's raw values produced 865 mismatches in 12,000:

- **864** were the sentinel difference: ksw leaves `gscore` at its `-1`
  initialiser when no cell reaches the query end, while the array clamps to `0`.
  Harmless — `orch.h:149/168` and bwa-mem2 both branch on `gscore <= 0`, so the
  two values take the same path. `gen_bsw_mvsh.cpp:100` already documents the
  convention ("RTL/golden convention: gscore clamped >=0") and
  `check_fulldp.cpp` already records that the difference never changes the
  assembly branch.
- **1** was a genuine banded-vs-full difference. Record `qlen=2, tlen=52,
  h0=52`:

  | | score | qle | tle | gtle | gscore |
  | --- | --- | --- | --- | --- | --- |
  | ksw, banded w=100 | 52 | 0 | 0 | 2 | 44 |
  | hw, full-DP array | 52 | 0 | 0 | **5** | **45** |
  | **RTL** | 52 | 0 | 0 | **5** | **45** |

  The RTL matches the array model exactly. It is right by its own
  specification; ksw's band had narrowed and stopped looking.

So the generator recomputes `gscore`/`gtle` with `hw_extend2`, which is exactly
what `gen_ext_vectors.cpp` already does ("expected outputs come from the
full-rectangle ARRAY model, not ksw"). Working this out from first principles
rediscovered why that choice was made.

**One caveat this implies:** `bsw_top` is bit-exact with bwa-mem2 on
`score`/`qle`/`tle` unconditionally (within the envelope, at `w=100`), and on
`gscore`/`gtle` only up to the banded-vs-full difference. The difference is
benign under the documented consumer branch, but a `±1` `gscore` difference
could in principle flip `gscore <= score - pen_clip` if a value sat exactly on
that boundary. Not observed in 34,000 records; worth knowing.

Records with `w != 100` are excluded. `bsw_top` is unbanded and matches the
banded kernel only while `2w+1 >= qlen`, so the narrow-band probe captures
(`-w 12`, `-w 30`) would diverge for reasons that are not RTL bugs.

## Mutation check: the new vectors catch a bug the committed set misses

| Mutant in `rtl/bsw_pe.sv` | ecoli | human | sim150 | committed set |
| --- | --- | --- | --- | --- |
| none (baseline) | 0 | 0 | 0 | 0 |
| **gaps open from `H_new` instead of `M_term`** — the historic 2026-08-07 defect | 0 | 0 | **1** | **0** |
| drop the gap-extension penalty (`E_ext = E_reg`) | 113 | 2420 | 1432 | 3342 |

The second row is the coverage argument for this whole exercise. That mutant is
the real bug fixed in `docs/bsw_gapopen_fix.md` — it inflates `gscore` for short
reads, and the original note records that "existing goldens missed it (coverage
gap)", which is why `disc_mvsh.txt` was written as a dedicated regression. The
150 bp high-divergence set now catches it **organically**, and the committed
golden set still does not.

The third row confirms all four sets detect a gross arithmetic error, so the
first two rows are measuring coverage rather than a broken harness.
