# Does accelerating the back half pay off? (speedup re-examination)

**Date:** 2026-06-17. Re-examines the real-runtime case for the `accel_top` engine
(the on-chip extend-orchestrator + merge-sorter) now that it is built and verified,
with the explicit goal of **offloading as much of the mapper as possible to the
FPGA**, not just the banded SW kernel.

Profiling basis: the measured baseline (101 bp human PE reads, hg38 chr1-5,
AVX-512, 16 threads) and the diverse-sample runs. See
`baseline_profiling_setup.md` §9–10, `diverse_alignment_timing.md`,
`post_seeding_acceleration_research.md`. All self-time %.

## 1. What `accel_top` replaces today

`accel_top` = `orch_read_top` (extension + seedcov + cross-chain purge) →
compaction → `msort_v2_top` (sort + de-overlap + dedup). Mapped to the profile:

| Replaced function | self-time |
|---|---|
| `smithWaterman512_*` (banded SW extension) | 6.5% |
| `mem_chain2aln_across_reads_V2` (extension orchestration) | 6.1% |
| `ks_introsort_mem_ars` + `_ars2` (both sorts in `mem_sort_dedup_patch`) | 20.9% |
| `mem_sort_dedup_patch` body (dedup loop) | not separately profiled (small) |
| **Total covered** | **≈ 33%** |

This is the **largest bit-exact, compute-bound, untargeted chunk** of bwa-mem2 —
and it is ~5× the banded-SW kernel alone. The headline number to internalize:
**`accel_top` targets ~⅓ of runtime, not the 6.5% of BSW-alone.**

(Accounting caveat: the exact figure needs a direct wall-time measurement of
`mem_chain2aln` + `mem_sort_dedup_patch` as a unit; the ~33% is summed self-times.
A 5-minute instrumented run on the remote would pin it down — see §7.)

## 2. Amdahl: ceiling and realistic speedup

`speedup = 1 / ((1-p) + p/s)` where `p` = offloaded fraction, `s` = per-stage HW
speedup over the AVX-512 CPU.

| Engine | p | ceiling (s→∞) | s=10× | s=5× | s=3× |
|---|---|---|---|---|---|
| **BSW alone** | 0.065 | 1.07× | 1.06× | 1.05× | 1.04× |
| **accel_top (this build)** | 0.33 | **1.49×** | 1.42× | 1.36× | 1.28× |

So `accel_top` is a **~1.3–1.45× engine** vs BSW-alone's 1.07×. That is the
difference between "not worth a standalone project" and "a real ~30–45% win."

## 3. Does it pay off? — verdict

**Yes, conditionally, and far more than BSW alone.** Three regimes:

- **Typical WGS (101 bp, well-mapped):** ~1.3–1.45×. A solid, real win.
- **Longer reads (150/250 bp):** the extension (X-drop) grows → the covered
  fraction and the win both rise (not yet measured; flagged as the biggest lever
  on the SW fraction in `baseline_profiling_setup.md` §10).
- **Divergent genomes:** the payoff is large. On NA19240 (Yoruba), WORKER_SAM
  (pairing + `mem_sort_dedup_patch` + SAM) is **79% of compute** — the sort/dedup
  we built dominates ~⅘ of the aligner. There `accel_top` is plausibly a **2–4×**
  engine. The hardest genomes are exactly where it helps most.

The payoff is therefore **not a single number** — it scales with read length and
genetic divergence, both of which push work into the back half we now own.

## 4. The data-movement reality (why the back half is offload-safe)

A common Amdahl-killer for single-kernel PCIe offload is data movement. For the
back half it is **not** a problem, because the per-read payload is small:

- **To FPGA, per read:** query (~150 B) + chains/seeds metadata (~hundreds of B) +
  reference windows (Stage-1, host-fed: ≤811 B/chain, typically a few chains) ≈
  **~2–4 KB/read**.
- **From FPGA, per read:** sorted alnregs (~few × 24 B) ≈ **~0.1–0.5 KB/read**.
- At bwa-mem2's ~58k reads/s (16 cores), that is **~0.2–0.3 GB/s** — ~2% of PCIe
  Gen3 x16 (16 GB/s). Bandwidth is a non-issue; latency hides behind read-batch
  DMA and CPU/FPGA pipelining (CPU seeds read N+1 while FPGA does the back half of
  read N).

So for the back half specifically, **the case for "offload more" is Amdahl
(cumulative fraction), not bandwidth.** Bandwidth only becomes the axis once you
move the *reference/index* on-board (seeding), which is the separate memory story
in `memory_placement_analysis.md`.

## 5. The "max offload" trajectory (cumulative ceilings)

Each added stage compounds. Ceilings (s→∞) on the 101 bp / chr1-5 profile:

| Cumulative offload | added | p | ceiling | notes |
|---|---|---|---|---|
| accel_top | — | 0.33 | 1.49× | **built + verified** |
| + mate-rescue SW (`kswv`) | +9.4% | 0.42 | 1.74× | **reuses the BSW datapath**; "all SW" |
| + chaining (`mem_chain`/`_flt`) | +11% | 0.53 | 2.15× | mm2-ax / Arria-10 precedent; bit-exact achievable |
| + seeding (FM-index) | +30% | 0.83 | 6.0×* | *FM-index roofline ≈2.1× (memory-bound); needs ERT/FMA + HBM |
| + ref-fetch/pairing/SAM/IO | rest | →1.0 | 10–30×* | *full hardware mapper, aspirational, memory-gated |

`*` = ceiling is optimistic; seeding is the hard wall (see §6).

**Priority order to "assign as much as possible":**
1. **Mate-rescue SW** — cheapest high-value add. It is Smith-Waterman (`kswv512`),
   so it reuses the verified BSW systolic core (a second driver / mode), +9–11%,
   bit-exact. Lifts the ceiling ~1.5→1.75×. Makes one SW datapath do extension +
   mate-rescue = "all SW."
2. **Chaining** — +11%, medium difficulty, compute-bound, FPGA precedent exists
   (mm2-ax forward-transform; Intel Arria-10), bit-exact achievable. → ~2× ceiling.
   Also lets `accel_top` ingest seeds instead of host-provided chains (less host work).
3. **Seeding** — the big lever (~30%) but the make-or-break hard part (§6).
4. **Stage-2 on-chip reference fetch** — replaces host-fed reference (the 4.6%
   `bns_get_seq`) and, more importantly, keeps extension/seeding data on-chip so
   stages don't round-trip through the host. HBM-relevant. (Tracked separately.)

## 6. The seeding wall (the limiting factor for >2×)

Past ~2×, you must attack seeding (~30%, the largest single stage). A **faithful
FM-index seeder on FPGA is a dead end**: it is memory-latency-bound, and ISCA-2021
(ERT) shows even an infinitely fast FM-index accelerator is ≤ ~2.1× over a CPU.
The proven escapes trade memory capacity for sequential/local access — **ERT**
(enumerated radix tree, ~60 GB, 2.1× e2e, bit-identical) or **FMA** (precomputed
prefixes, ~1 GB, FPGA-friendly, ~3.2× e2e), both needing HBM-class memory. An
**exact-match filter** can also bypass ~⅔ of reads cheaply. This is a much larger
sub-project than the back half and is where the memory-placement analysis applies.

## 7. Recommendation

1. **The back half pays off** — `accel_top` is a ~1.3–1.45× engine on typical WGS
   and a 2–4× engine on divergent/long-read workloads, vs 1.07× for BSW alone.
   Building it was the right call under the "max offload" goal.
2. **Next, add mate-rescue SW** — highest ratio of payoff to effort, reuses the
   BSW core, keeps everything bit-exact. Then chaining. That path reaches a ~2×
   ceiling entirely in the bit-exact, compute-bound, FPGA-friendly regime.
3. **Seeding is the gate to >2×** and is a separate memory-bound program
   (ERT/FMA + HBM); decide on it explicitly, not by drift.
4. **Pin the exact covered fraction:** a direct timed run on the remote of
   `mem_chain2aln` + `mem_sort_dedup_patch` (vs total) would replace the ~33%
   estimate with a measured number, and a 150/250 bp run would quantify the
   read-length lever. Both are short remote jobs.

**Bottom line:** accelerating the back half is worth it, and the strategy of
offloading as much as possible is correct — the ceiling climbs from ~1.5× (today)
to ~2× (＋mate-rescue＋chaining, still easy/bit-exact) before hitting the seeding
wall, which is the real decision point for a full-hardware-mapper ambition.

## Addendum — fresh measurement (2026-06-17, perf cpu-clock, 2M pairs, 1.15M samples)

Re-profiled the clean binary (101 bp, chr1-5) and grouped self-times by engine:

| Engine / stage | self-time |
|---|---|
| Seeding (backwardExt 15.1 + getSMEMs 10.6 + get_sa 3.6 + bwtSeed 2.6) | 31.9% |
| Sort/dedup (ars 10.9 + ars2 9.2 + dedup_patch 1.8 + combsort 0.6 + hash 0.2) | 22.7% |
| Mate-rescue (kswv512 10.0 + wrapper 1.3 + matesw pre/post 1.2 + ksw_global2 1.3) | ~12.5–13.8% |
| Extension (mem_chain2aln 5.65 + sw512_8/16 5.1 + wrappers 1.3) | ~12.0% |
| Chaining (mem_chain_flt 3.46 + mem_chain_seeds 1.59 + mem_flt sort 0.14) | ~5.2% |
| ref fetch (bns_get_seq) | 4.4% |

**Confirmations + corrections vs the estimates above:**
- **accel_top (extension + sort/dedup) = ~34.7%** — confirms the ~33% estimate. Ceiling 1.53×.
- **Mate-rescue ≈ 12.5%**, *larger* than the ~9–11% estimate, and `kswv512_u8` alone (10.0%)
  is the single biggest SW kernel — bigger than all of extension SW (~5%). Building it before
  chaining was the right order.
- **Chaining ≈ 5.2%**, *smaller* than the ~11% estimate — the old "~11%" conflated the SA
  lookups (`get_sa_entries`, really seeding) with the chain logic. The actual chain
  grouping+filter is ~5%.

Cumulative on-chip ceilings (fresh): accel_top 34.7% → **1.53×**; ＋mate-rescue 47.2% →
**1.89×**; ＋chaining 52.4% → **2.10×**. The ~2× target holds, but **mate-rescue (~12.5%),
not chaining (~5%), is the bigger second lever** — already built. (The 150/250 bp read-length
run is still unmeasured — no long-read FASTQ on the server.)
