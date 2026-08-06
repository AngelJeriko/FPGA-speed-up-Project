# Reproducing the project from scratch

An ordered walkthrough for someone new to the repo. Each stage links to the detailed
doc; this page is the spine that puts them in order and fills the gaps (dataset fetch,
the external profiling patch) that were previously only implied.

Tool versions for every stage: [`../REQUIREMENTS.md`](../REQUIREMENTS.md).

**What is fully self-contained vs. what needs external inputs:**

| Stage | Self-contained in this repo? |
|-------|------------------------------|
| 1. Simulation (verify the RTL) | ✅ Yes — vectors bootstrap from committed `.gz` |
| 2a. Profiling breakdown (the "why") | ✅ Reproducible from **stock** bwa-mem2 + `perf` |
| 2b. Fresh golden-vector capture | ⚠️ Needs external `bwamem.cpp` instrumentation (documented) |
| 3. Synthesis / timing | ✅ Scripts here; needs your local Vivado |
| 4. F1 AFI | ✅ Steps here; needs your AWS account |

---

## Stage 1 — Simulation (start here; proves the RTL)

Fully self-contained. Verify any engine bit-exact against its golden model:

```bash
bash scripts/run_sim.sh tb_bsw_top          # ACGT/ACGT -> score=5, "PASS"
bash scripts/run_sim.sh tb_cl_bsw_ocl       # F1 OCL wrapper: 13/13, score=5
bash scripts/run_sim.sh tb_orch_purge       # orchestrator, golden-checked (200/0)
bash scripts/run_sim.sh tb_chaining_pe_pair_top   # full pipeline (100/0; minutes)
```
Vector files (some large) are bootstrapped from committed `.gz` on first run. The
golden C++ models and vector generators live under `host/` — see
[`../host/integration.md`](../host/integration.md) and
[`../host/extend_orchestrator/README.md`](../host/extend_orchestrator/README.md) for
the golden → vector → testbench workflow. Full engine/testbench inventory:
[`project_status.md`](project_status.md) §2–3.

> **CI note:** testbenches signal pass/fail on their printed summary line and end on
> `$finish` — a *failing* run still exits 0. Grep the summary line, not `$?`.

## Stage 2 — Software baseline + profiling (the motivation)

Details and rationale: [`baseline_profiling_setup.md`](baseline_profiling_setup.md).

### 2.0 Build BWA-MEM2
```bash
git clone --recursive https://github.com/bwa-mem2/bwa-mem2
cd bwa-mem2 && make        # multi-arch binary incl. avx512
```

### 2.1 Reference — GRCh38 chr1–5 (fits a 32 GB box; full hg38 index needs ~87 GB)
```bash
for c in chr1 chr2 chr3 chr4 chr5; do
  wget -c https://hgdownload.soe.ucsc.edu/goldenPath/hg38/chromosomes/$c.fa.gz
done
zcat chr1.fa.gz chr2.fa.gz chr3.fa.gz chr4.fa.gz chr5.fa.gz > hg38_chr1-5.fa
./bwa-mem2 index hg38_chr1-5.fa
```

### 2.2 Reads — NA12878 / ERR174310 (Illumina Platinum Genomes, 2×101, paired-end)
Resolve the FASTQ URLs from ENA (robust to path changes), then fetch:
```bash
curl -s "https://www.ebi.ac.uk/ena/portal/api/filereport?accession=ERR174310&result=read_run&fields=fastq_ftp" 
# -> ftp.sra.ebi.ac.uk/vol1/fastq/ERR174/ERR174310/ERR174310_1.fastq.gz;.../ERR174310_2.fastq.gz
wget -c https://ftp.sra.ebi.ac.uk/vol1/fastq/ERR174/ERR174310/ERR174310_1.fastq.gz
wget -c https://ftp.sra.ebi.ac.uk/vol1/fastq/ERR174/ERR174310/ERR174310_2.fastq.gz
```
The diversity panel (HG002/HG005/HG00733/NA19240 and their SRR/ERR accessions) is
tabulated in [`diverse_test_fastqs.md`](diverse_test_fastqs.md); fetch the same way.

### 2.3 Reproduce the profiling breakdown (no source patch needed)
Run stock bwa-mem2 under `perf` — this reproduces the seeding/SW self-time split
(the flat profiles in [`profiling_results/`](profiling_results/)):
```bash
perf record -g ./bwa-mem2 mem -t16 hg38_chr1-5.fa ERR174310_1.fastq.gz ERR174310_2.fastq.gz > /dev/null
perf report --stdio | head -40
```
Expected: FM-index seeding (`backwardExt` + `getSMEMs…` + `get_sa_entries…` +
`bwtSeed…`) ≈ **~32%** self-time; banded SW (`smithWaterman512_*`) small on these
short reads (**see the dataset caveat** in [`project_status.md`](project_status.md) §1).

### 2.4 (Optional) Capture fresh golden vectors — needs the external patch
The RTL golden vectors are already committed (as `.gz`, bootstrapped in Stage 1), so
this is only needed to regenerate them. The capture hooks live in
`bwa-mem2/src/bwamem.cpp` and are **not vendored in this repo** (they were applied on
the profiling box and reverted). [`bwamem2_instrumentation.md`](bwamem2_instrumentation.md)
documents them exactly — the env-gated dumpers and their line ranges:

| Env var | Captures |
|---------|----------|
| `ALNREG_VEC_OUT=out.bin` | score-sort `(score,rb,qb)` arrays (merge-sorter vectors) |
| `ALNREG_V2_OUT=out.bin` | v2 dedup vectors |
| `ALNREG_EXT_OUT=out.bin` (`ALNREG_EXT_MAX` caps reads) | extend-orchestrator capture |
| `ALNREG_TIE_TEST=1` | dedup tie-order test |

The hooks are now **assembled as an apply-able patch** in
[`../host/bwamem2_patch/`](../host/bwamem2_patch/) — a master apply/build/capture/revert
guide that indexes the five committed authoritative snippets (chaining, clamp, matesw,
orch, sel) and adds a reconstructed `ext_capture.inc` for the extend-orchestrator
capture (with an acceptance test that regenerates the `30000/30000` golden). Apply per
that README, rebuild, and run with the env var set (e.g.
`ALNREG_EXT_OUT=ext_vec.bin ./bwa-mem2 mem -t16 hg38_chr1-5.fa r1 r2 >/dev/null`);
`scripts/remote_ext_capture.sh` / `scripts/remote_batched_capture.sh` automate the
capture harness. **Remaining caveat:** the snippets are anchored to bwa-mem2 code
landmarks (not a fixed-commit `.diff`), so confirm the `⟨BIND⟩` local names against your
checkout before building — the acceptance test then proves the capture is byte-correct.

## Stage 3 — Synthesis / timing (needs local Vivado)

Out-of-context per-module Fmax/area on a free UltraScale+ proxy part (no board):
```bash
cd synth/ooc && ./run_ooc.sh          # top targets; or call ooc_synth.tcl per module
```
Full-design P&R (the 115.6 MHz figure) uses `synth/ooc/impl_chaining_pe_pair_top.tcl`.
Setup, part numbers, and share-back format: [`../synth/ooc/README.md`](../synth/ooc/README.md).
Results log: [`synth_ooc_results.md`](synth_ooc_results.md).

## Stage 4 — F1 AFI build (needs AWS)

Build the control-only `cl_bsw_top` kernel into a loadable AFI and run it on real
VU9P silicon. Full step-by-step with per-step roadblocks:
[`f1_build_runbook.md`](f1_build_runbook.md). Register-map / host contract:
[`f1_bringup.md`](f1_bringup.md). Clock recipe **A0 = 125 MHz**.

## Design rationale (why it's built this way)

Not a build step, but essential context: [`speedup_plan.md`](speedup_plan.md),
[`post_seeding_acceleration_research.md`](post_seeding_acceleration_research.md), the
per-engine `*_scope.md` / `*_engine_scope.md` docs, and the `*_options.md` decision
docs. [`project_status.md`](project_status.md) is the top-level map.
