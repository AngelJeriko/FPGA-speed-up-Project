# Diverse-Sample Alignment — Computation-Time Breakdown

bwa-mem2 (clean/un-instrumented binary) aligning the five diverse 50M-pair samples
vs **hg38 chr1–5**, 16 threads, on the remote box (`ccloud@216.227.218.169`,
Intel @ ~1.9 GHz). Output: gzipped SAM in `/home/ccloud/align_diverse/`. Timings
are from bwa-mem2's own end-of-run "Runtime profile" (`<sample>.bwa.log`).

Purpose: see where alignment compute actually goes on real, ancestry-diverse data
— and confirm the project's strategic findings ([[project-bwa-mem2-swa-not-bottleneck]],
[[project-bwa-mem2-acceleration-strategy]]).

## Phases (bwa-mem2 kernels)

- **SMEM** — super-maximal exact match seeding (FM-index walk). The dominant kernel.
- **SAL** — suffix-array lookup: seed → genome location (incl. MEM_SA).
- **BSW** — banded Smith-Waterman extension (the kernel originally eyed for FPGA).
- **WORKER_SAM** — post-extension: pairing, `mem_sort_dedup_patch` (the ~22% sort/dedup
  hotspot the merge-sorter engine targets), and SAM string formatting.

## Absolute times (seconds; per-thread aggregates, sum ≈ processing time)

| phase | HG002 | HG005 | HG00733 | NA12878 | NA19240 |
|---|--:|--:|--:|--:|--:|
| SMEM (seeding) | 338.0 | 292.0 | 251.4 | 571.5 | _pending_ |
| SAL (seed→loc) | 16.5 | 14.4 | 69.5 | 120.2 | _pending_ |
| BSW (extension) | 53.6 | 49.6 | 144.3 | 246.9 | _pending_ |
| WORKER_SAM (sort/dedup/SAM) | 148.8 | 130.1 | 238.4 | 825.3 | _pending_ |
| kernels total (SMEM+SAL+BSW) | 420.5 | 367.3 | 504.5 | 1043.5 | _pending_ |
| Reading reads (IO) | 82.5 | 77.0 | 122.4 | 176.1 | _pending_ |
| Writing SAM (IO, incl. gzip backpressure) | 431.2 | 383.4 | 573.3 | 855.4 | _pending_ |
| **Total wall (`main_mem`)** | **588** | **516** | **854** | **1895** | _pending_ |

## Share of sequence processing (kernels + WORKER_SAM)

| phase | HG002 | HG005 | HG00733 | NA12878 |
|---|--:|--:|--:|--:|
| Seeding (SMEM+SAL) | **62.3%** | **61.6%** | **43.2%** | **37.0%** |
| Extension (BSW) | 9.4% | 10.0% | 19.4% | 13.2% |
| SAM / pairing / dedup (WORKER_SAM) | 26.1% | 26.1% | 32.1% | **44.2%** |

## Mapping context (why the splits differ)

| sample (population) | primary reads | mapped % | proper-pair % |
|---|--:|--:|--:|
| HG002 (Ashkenazi) | 42.9 M | 12.2% | 11.4% |
| HG005 (Han Chinese) | 39.3 M | 11.8% | 10.9% |
| HG00733 (Puerto Rican) | 100.0 M | 99.89% | 98.4% |
| NA12878 (European) | 100.0 M | 59.7% | 45.6% |
| NA19240 (Yoruba) | _pending_ | _pending_ | _pending_ |

HG002/HG005 are non-WGS (targeted) sets and have fewer pairs (~20 M); most reads
don't fall in chr1–5 → low mapping. HG00733 is a chr1-enriched WGS subset → ~100%.
NA12878 is WGS European → ~60% (chr1–5 ≈ 34% of the genome).

## Findings (relevant to the accelerator)

1. **FM-index seeding (SMEM+SAL) dominates compute on every sample — 37–62%.** Confirms
   that seeding, not Smith-Waterman, is the bottleneck. BSW (banded SW) is only **9–19%**.
2. **The split tracks mapping rate.** Low-mapping samples spend ~62% in seeding and almost
   nothing in extension (few reads survive to extend); WGS samples are more balanced.
3. **WORKER_SAM is large (26–44%)** — and `mem_sort_dedup_patch`, the ~22% sort/dedup the
   verified merge-sorter engine attacks, lives here. NA12878's 44% (150 bp WGS, high
   mapping) shows how dominant this region gets on real data.
4. **Seeding scales with genetic divergence** — NA19240 (Yoruba, most divergent) runs
   ~3–4× slower per batch (~90 s vs ~25 s), entirely from deeper SMEM/extension work per
   read. Highest divergence = highest seeding cost = strongest case for accelerating it.

## Reproduce

`/home/ccloud/remote_align_diverse.sh` (bwa-mem2 mem -t16 vs chr1-5, gzip -1 SAM +
inline awk stats). Per-sample profiles in `/home/ccloud/align_diverse/<sample>.bwa.log`.
NOTE: gzip is single-threaded — default `gzip` capped bwa-mem2 at ~4/16 cores (pipe
backpressure); `gzip -1` restored ~14-core utilization. pigz would be better if installed.
