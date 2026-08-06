# Requirements

Tools and versions needed per stage. Only the **Simulation** stage is required to
verify the RTL; the others are for reproducing the timing, the F1 AFI, and the
software profiling that motivates the project. See [`docs/reproducing.md`](docs/reproducing.md)
for the ordered walkthrough.

## Simulation (required — fully self-contained)

| Tool | Version | Notes |
|------|---------|-------|
| Verilator | ≥ 5.0 | Verified on **5.020** (this repo's audit) and 5.032. |
| C++ toolchain | g++ ≥ 11 | Verified on **g++ 13.3.0**. Builds the `host/` golden models + vector generators. |
| GNU make | any recent | Drives `host/**/Makefile`. |
| Python | 3.x | Verified on **3.12**. A few vector generators/helpers are Python. |
| bash + coreutils | — | `scripts/run_sim.sh`; also `gzip`/`zcat` to bootstrap committed vector `.gz` files. |

Windows: run under WSL (Verilator's make step dislikes spaces in absolute paths).

## Synthesis / timing (optional — needs Xilinx Vivado)

| Tool | Version | Notes |
|------|---------|-------|
| Xilinx Vivado | 2026.1 used locally | **ML Standard is sufficient** for the out-of-context proxy runs in `synth/ooc/`. Full/enterprise not required for OOC. |
| Proxy FPGA part | — | OOC harness targets a free UltraScale+ proxy (`xcku5p-ffvb676-2-e`) or 7-series (`xc7v2000t`); same LUT6/RAMB36/DSP48 fabric family as the F1 `xcvu9p`. No board needed. |

Run per [`synth/ooc/README.md`](synth/ooc/README.md). Vivado is **not** on the dev
sandbox — timing numbers come from a local Vivado install.

## F1 AFI build (optional — needs AWS)

| Requirement | Notes |
|-------------|-------|
| AWS **FPGA Developer AMI** | Ships a licensed Vivado matched to the HDK. Do **not** use an arbitrary local Vivado — the HDK pins specific versions. |
| `aws-fpga` HDK | F1 release tag **v1.4.25** (the last F1 line; `master` is now F2-only). `source hdk_setup.sh`. |
| AWS CLI + S3 bucket | For `create-fpga-image` (DCP → AFI). |
| `f1.2xlarge` instance | To load the AFI and run `host/f1/test_bsw.c` (built with `-lfpga_mgmt`). |

Full steps + roadblocks: [`docs/f1_build_runbook.md`](docs/f1_build_runbook.md).
Clock recipe **A0 = 125 MHz** `clk_main_a0` (verified against `aws-fpga/hdk/docs/clock_recipes.csv`).

## Software baseline + profiling (optional — reproduces the "why")

| Tool | Notes |
|------|-------|
| BWA-MEM2 | Built from source (`git clone --recursive`; `make` produces the multi-arch binary incl. AVX-512). NOT vendored here. |
| Linux `perf` | Reproduces the seeding/SW self-time breakdown on the **stock** binary — no source patch needed. |
| `wget`, `samtools` (optional) | Fetch/prepare the GRCh38 chr1–5 reference. |
| Host RAM | ≥ ~32 GB to build the chr1–5 index (full GRCh38 needs ~87 GB — infeasible on 32 GB; hence the chr1–5 subset). |
| CPU | An AVX-512 machine matches the profiled baseline (16-core box used). |

Note: capturing **fresh golden vectors** (as opposed to using the committed `.gz`
vectors, or reproducing the perf breakdown) additionally requires the instrumentation
hooks in `bwa-mem2/src/bwamem.cpp`, which are **external to this repo** — documented in
[`docs/bwamem2_instrumentation.md`](docs/bwamem2_instrumentation.md). See
[`docs/reproducing.md`](docs/reproducing.md) §2.
