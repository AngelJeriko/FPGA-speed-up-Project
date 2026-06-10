# Profiling Results — Reference BWA-MEM2 Baseline

Raw artifacts backing `docs/baseline_profiling_setup.md`. Generated on a remote
Ubuntu 24.04 box (16 cores, 31 GiB RAM, AVX-512) running the unmodified bwa-mem2
on ERR174310 (NA12878, 101 bp paired-end human reads) against an hg38 chr1–5
reference.

## Headline finding
On short-read human WGS with bwa-mem2 (SIMD/AVX-512), the **banded SWA kernel is
only ~6.3–6.5% of CPU self-time** — not the bottleneck. The real hotspots are
**FM-index seeding ~33%**, **sort/dedup ~23%**, **mate-rescue SW ~12%**, and
**chaining ~11%**. This is reproducible across runs and stable from 10M up to 200M
read pairs. See the parent doc §9–10 for the full analysis and implications.

## Files
| File | What it is |
|------|------------|
| `flat_profile_10M.txt` | `perf` flat profile (self-time per symbol), 10M-pair run, 536K samples |
| `flat_profile_200M_2hr.txt` | `perf` flat profile, 200M-pair / ~2-hour production run, 11M samples |
| `reproducibility_3runs.txt` | Top-15 self-time symbols across 3 identical 10M-pair runs (variance <0.3 pp) |
| `scripts/remote_setup.sh` | Build bwa-mem2 + download/concat/index hg38 chr1–5 |
| `scripts/remote_calibrate.sh` | 50M-pair timed calibration (throughput + peak RAM) |
| `scripts/remote_perf.sh` | 10M-pair `perf` profiling run |
| `scripts/remote_repro.sh` | 3× reproducibility profiling |
| `scripts/remote_2hr_test.sh` | 200M-pair / ~2-hour production-scale profiling run |

## Reproduce
On a comparable Linux box with `build-essential`, `zlib1g-dev`, `perf`, and the
bwa-mem2 source: run `remote_setup.sh`, then any of the profiling scripts. Each
writes a log next to itself and prints a flat `perf` profile. Paths inside the
scripts assume `/home/ccloud/...` — adjust as needed.
