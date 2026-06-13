# FPGA Acceleration Strategy for BWA-MEM2 Post-Seeding Stages: A Decision-Grade Research Report

Provenance: cited multi-agent research pass (workflow `track1-acceleration-research`,
25 agents, ~603k tokens, adversarial verification). The verification step REFUTED or
corrected several claims — see §8. Numbers are reported with their evidence strength;
ASIC vs FPGA vs CPU baselines are flagged. Personal/repo doc (no DRAGEN content).

Date: 2026-06-13.

---

## 0. Executive Summary

Self-time profile:

| Stage | Self-time | Already targeted? |
|---|---|---|
| FM-index seeding | ~30% | Yes (exact-match filter + FMA/ERT) |
| **Sorting alignment registers** (`ks_introsort` on `mem_alnreg_t`) | **~22%** | No |
| **Mate-rescue SW** | **~11%** | No |
| **Chaining** (`mem_chain2aln`) | **~11%** | No |
| **Banded SWA** | **~6.5%** | No |

Post-seeding attackable work = ~50.5% → **Amdahl ceiling ~2.02× end-to-end** for ALL
post-seeding combined (infinite speedup, free integration). No single post-seeding
stage exceeds ~1.28×. Gains come from BREADTH (reusable hardware across stages), not
from crushing one stage.

**Headline recommendation (priority order):**
1. **Alignment-register sorting** via FPGA streaming merge-sorter (largest untargeted
   hotspot 22%, highest ceiling 1.28×, inherently bit-exact, textbook FPGA fit).
2. **GenASM-style bitvector engine** serving banded SWA + mate-rescue SW + a DC-only
   pre-alignment filter from one datapath (best work-per-area, ~17.5%+ combined).
3. **Chaining** as a pipelined DP kernel (only stage with direct Intel-FPGA precedent).
4. Pre-alignment filters (SneakySnake) ONLY as a front-end folded into #2, not
   standalone (Amdahl ≈ 0 against 6.5% SWA).
5. BiWFA-on-FPGA fallback only if exact gap-affine optimality (not output identity)
   becomes a requirement.

---

## 1. Amdahl ceilings

| Target stage(s) | p | Ceiling (s→∞) | Realistic (s=10×) |
|---|---|---|---|
| Sorting alone | 0.22 | **1.28×** | 1.25× |
| Mate-rescue SW alone | 0.11 | 1.12× | 1.10× |
| Chaining alone | 0.11 | 1.12× | 1.10× |
| Banded SWA alone | 0.065 | 1.07× | 1.06× |
| SWA + mate-rescue (shared SW engine) | 0.175 | **1.21×** | 1.19× |
| All post-seeding combined | 0.505 | **2.02×** | 1.67× |
| Post-seeding + seeding (0.30) | 0.805 | 5.13× | — |

Single-stage banded-SWA accelerator (1.07× ceiling) is not worth a standalone project.

---

## 2. Family A — FPGA Pre-Alignment Filters (GateKeeper / Shouji / SneakySnake / MAGNET / GRIM-Filter)

Lossless filters between seeding and SWA: cheaply reject candidate locations that
cannot be within edit threshold E, **0% false-reject** → surviving alignments
bit-identical; only wasted SWA work removed.

- **GateKeeper** (confirmed): first FPGA pre-align filter; Hamming mask, 2E shifted
  masks for indels. 90× vs Adjacency, 130× vs SHD; ~10× mrFAST verification cut.
  Lossless, ~4% false accepts. VC709 Virtex-7, 250 MHz; 300bp/E=15 → ~69% LUTs/91%
  regs (resource pressure climbs with length/E).
  https://academic.oup.com/bioinformatics/article/33/21/3355/3859176
- **Shouji** (confirmed): non-overlapping common subsequences in an E-band. FPGA ~3
  orders over CPU Shouji; integrating cuts aligner runtime up to 18.8×; ~3.3 GB/s.
  Lossless, far fewer false accepts than GateKeeper. VC709, 250 MHz, 16 units; VHDL,
  older toolchain. https://academic.oup.com/bioinformatics/article/35/21/4255/5421509
- **MAGNET** (confirmed): MATLAB accuracy study, NOT hardware. Methodology only.
  https://arxiv.org/abs/1707.01631
- **GRIM-Filter** (confirmed): PIM 3D-DRAM SEED-LOCATION filter, NOT an FPGA SWA
  pre-filter; reduces false negatives, not lossless; not portable here.
  https://link.springer.com/article/10.1186/s12864-018-4460-0
- **SneakySnake** — speedup attribution REFUTED: 413×/689× are GPU (Snake-on-GPU);
  FPGA Snake-on-Chip is up to **321× (Edlib) / 536× (Parasail)**. The HLS-HBM variant
  is later/separate work. Corrected usable facts: universal CPU/GPU/FPGA lossless
  filter; highest accuracy of the family; synthesizable Verilog, **<1.5% resources
  per unit**; best-maintained repo; easiest Intel port.
  https://academic.oup.com/bioinformatics/article/36/22-23/5282/6033580

Amdahl: reduces invocations of SWA(6.5%)+mate-rescue(11%); ceiling ≤1.21×, ≈0
standalone. Bit-exact by construction (lossless). Verdict: pursue ONLY as a front-end
to a SW engine; prefer SneakySnake.

---

## 3. Family B — WFA / BiWFA (exact gap-affine alignment)

WFA expands wavefronts by score s; work scales with divergence (great for high-identity
short reads). O(ns) time, O(s²) memory; BiWFA = O(s) memory.

- WFA optimal, O(ns)/O(s²); WFA2-lib `ultralow`/BiWFA O(s) memory (confirmed).
  https://academic.oup.com/bioinformatics/article/37/4/456/5904262 ,
  https://github.com/smarco/WFA2-lib/blob/main/README.md
- Tie-breaking (confirmed, critical): scores match bwa-mem2 SW (same penalties, no
  banding) but **CIGAR/traceback can differ on ties → NOT bit-identical**.
- BiWFA (confirmed): O((m+n)s) time, O(s) memory; 32–1000× less memory than KSW2-Z2,
  1.4–4.7× faster (CPU). FPGA BiWFA published 2024.
  https://pmc.ncbi.nlm.nih.gov/articles/PMC9940620/
- WFA-FPGA / Haghi et al. (confirmed): first FPGA WFA; 4.5–8.8× (1 FPGA) / 8.2–13.5×
  (2 FPGAs) vs CPU-WFA; Xilinx Alveo. (vs CPU-WFA, not vs an FPGA banded-SW kernel.)
  https://www.sciencedirect.com/science/article/abs/pii/S0167739X2300256X

Caveats: WFA O(s²) memory bad for FPGA (BiWFA fixes); data-dependent timing fights
systolic design; **global/ends-free ≠ bwa-mem2 local X-drop SW** + tie CIGARs → poor
drop-in. Verdict: fallback only.

---

## 4. Family C — GenASM (Bitap/bitvector ASM framework)

Parallelized Bitap. **GenASM-DC** (64-PE systolic, bitvector matrices) +
**GenASM-TB** (divide-and-conquer traceback, CIGAR). Accelerates read alignment
(DC+TB), pre-alignment filtering (DC only), edit-distance (DC only); short & long reads.

All claims confirmed (strongest evidence base here):
- short-read alignment **111× vs software, 1.9× vs hardware**.
- pre-align filtering (short) **3.7× vs Shouji, 1.7× less power**; false-accept 0.02%
  (100bp) / 0.002% (250bp) vs Shouji 4%/17%.
- long-read 116× vs Minimap2 align (12-thread); edit-distance 22–12501× vs Edlib.
- HW cost (paper Table 1): 1 accelerator = 0.334 mm² / 101 mW @ 28nm, 1 GHz.
  https://arxiv.org/abs/2009.07692

Amdahl: one datapath covers SWA(6.5%) + mate-rescue(11%) + filter → 17.5%+ → 1.21×.
**Caveats: the paper is a 28nm ASIC-in-3D-stacked-memory, NOT an FPGA** (the FPGA
"BitMAc" is follow-up). Approximate (Bitap) → CIGAR not guaranteed bit-identical
(scores close); DC-only filter mode can be lossless-grade. Verdict: best breadth-per-
area; adopt the ALGORITHM, re-establish FPGA perf in sim, build an output-equivalence
harness.

---

## 5. Family D — Chaining & alignment-register sorting

### 5a. Chaining (`mem_chain2aln`, ~11%)
- **mm2-ax** (confirmed): forward-transform (bounded successor scan, `>=` tie-break)
  → **100% identical alignments** to mm2-fast; 2.57–5.41× chaining on A100. The
  backward→forward restructuring is directly portable to a streaming FPGA pipeline.
  https://pmc.ncbi.nlm.nih.gov/articles/PMC10018915/
- **minimap2-fpga** (confirmed, our target): pipelined FPGA chaining on **Intel Arria
  10 GX 1150**; without base alignment 79% (ONT)/53% (PacBio) faster; output 99.24–
  99.68% (NOT bit-exact). Splits HEAVIER chains to FPGA.
  https://pmc.ncbi.nlm.nih.gov/articles/PMC10656460/
- **Guo et al. FCCM 2019** (confirmed): open-source MIT HLS FPGA chaining kernel +
  CUDA + SIMD; reusable Intel-port starting point. ~7% long-read misalign if score-tie
  transform uncorrected. https://github.com/UCLA-VAST/minimap2-acceleration
- **mm2-fast** chaining figures REFUTED: no "6.1× isolated"; real **3.1×** on the DP
  module, **~1.8× end-to-end**, LONG reads. https://github.com/bwa-mem2/mm2-fast

Fit good (DP scan → deep pipeline); Intel Arria 10 precedent exists; bit-exact
achievable via mm2-ax. **Caveat: speedups are long-read-biased** (chaining 60–70%
there vs 11% here, shorter short-read chains) → expect smaller gains. Ceiling 1.12×.

### 5b. Alignment-register sorting (`ks_introsort` on `mem_alnreg_t`, ~22% — LARGEST untargeted)
- Evidence UNCERTAIN/flagged: merge-network theory solid (pipelined ~200 MHz,
  bitonic CAS formula correct), but the **49×/19× speedups are MISATTRIBUTED**
  (actually Papaphilippou et al., FPL 2020, not the cited 2017 paper); "~8 elem/cycle"
  unverified; relevance to `mem_alnreg_t` sort is our inference.
  https://dl.acm.org/doi/10.1145/3039902.3039905
- Fit moderate-good. **Caveat: bwa-mem2 sorts VARIABLE-LENGTH arrays of wide
  multi-key `mem_alnreg_t` with a custom comparator → a FIXED bitonic network is
  awkward; use a STREAMING/adaptable merge-sorter (key-only sort + payload pointers).**
- **Bit-exact: strongest of any technique** — a correct comparator yields identical
  ordering; no approximation. Ceiling **1.28×** (highest single untargeted stage).
- Verdict: most attractive untargeted stage; thin genomics-specific evidence but
  rock-solid theory and bit-exactness → build-and-measure-in-sim.

---

## 6. Cross-family comparison

| Family | Attacks | Ceiling | FPGA fit | Bit-exact? | Evidence | Intel precedent |
|---|---|---|---|---|---|---|
| Sorting networks | Sort 22% | **1.28×** | Moderate-good (variable-N merge) | **Yes (inherent)** | Thin/partly misattributed; theory solid | None genomics |
| GenASM bitvector | SWA+rescue+filter 17.5%+ | 1.21× | Good algo; **ASIC not FPGA** | No (approx; close scores) | **Strongest** but ASIC/PIM | No |
| Chaining | Chaining 11% | 1.12× | Good (DP) | Achievable (mm2-ax 100%) | Strong but long-read-biased | **Yes (Arria 10)** |
| Pre-align filters | Wasted SW work | ≤1.21× (≈0 standalone) | Excellent | **Yes (lossless)** | Strong (1 refuted) | No (Xilinx) |
| WFA/BiWFA | SWA+rescue 17.5% | 1.21× | BiWFA good; data-dependent | No (global≠local; ties) | Strong; CPU/Xilinx | No |

---

## 7. Ranked recommendation (sim-first)
1. **FPGA streaming merge-sorter for `mem_alnreg_t`** (22%, 1.28×, inherently bit-exact,
   lowest correctness risk). Adaptable/streaming, key+payload-pointer, ~200 MHz.
2. **GenASM-style bitvector DC+TB engine** = SWA + mate-rescue + DC-only filter (17.5%+,
   breadth). Re-derive FPGA perf in sim; output-equivalence harness.
3. **Pipelined chaining kernel on Intel FPGA** using mm2-ax forward transform (11%,
   1.12×, bit-exact achievable, Arria-10 precedent + Guo HLS IP).
4. **SneakySnake filter** only as front-end folded into #2.
5. **BiWFA-on-FPGA** fallback only if exact gap-affine (not output identity) required.

---

## 8. Where the evidence is thin (explicit)
1. Sorting-for-genomics: no `mem_alnreg_t` precedent; 49×/19× misattributed (real:
   Papaphilippou FPL 2020); "~8 elem/cycle" unverified. Theory solid + bit-exact.
2. GenASM: all numbers are 28nm ASIC-in-PIM, not FPGA → re-derive in sim.
3. Chaining: speedups are long-read minimap2 (60–70% there vs 11% here) → smaller gains.
4. SneakySnake FPGA speedup: refuted (413×/689× are GPU; FPGA 321×/536×).
5. mm2-fast: "6.1× isolated" fabricated; real 3.1× module / ~1.8× e2e, long-read.
6. WFA: not bit-exact vs bwa-mem2 (global-vs-local + tie CIGARs).

---

## 9. Bottom line
Against a ~2.02× post-seeding ceiling: (1) bit-exact FPGA merge-sorter for the 22%
sort (biggest, safest, highest ceiling), (2) versatile GenASM-style bitvector engine
covering SWA + mate-rescue + filtering for breadth, (3) Intel-FPGA chaining pipeline
via mm2-ax for bit-exactness. Pre-align filters live INSIDE the SW engine, not
standalone. Combined with the already-targeted 30% seeding, breadth across
sort + SW/mate-rescue + chaining is what moves end-to-end toward the 5×-class regime
the full-mapper goal requires.
