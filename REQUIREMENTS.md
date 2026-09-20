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
| Proxy FPGA part | — | OOC harness prefers the real F2 part `xcvu47p-fsvh2892-2-e`, else an UltraScale+ `-2` proxy (`xcku5p-ffvb676-2-e`, `xczu7ev-ffvc1156-2-e`), else 7-series (`xc7v2000t`). No board needed. |

Run per [`synth/ooc/README.md`](synth/ooc/README.md). Vivado is **not** on the dev
sandbox — timing numbers come from a local Vivado install.

**Version note:** the local scripts (`synth/ooc/*.tcl`) synthesise *our* RTL against
generic device models — no AWS shell checkpoint, no encrypted AWS IP — so any recent
Vivado works, including versions newer than the HDK supports. The pinned versions below
matter only for the AWS build itself.

**⚠️ Your UltraScale+ numbers may be silently falling back.** Every committed report says
`Device: 7v2000t`, meaning the UltraScale+ candidates were not installed and the harness
dropped to a 7-series part — a whole fabric generation older and systematically
pessimistic. Check with `get_parts -quiet xcku5p*`; if empty, add the family through the
Vivado installer ("Add Design Tools or Devices"). This is usually an install choice, not
a licence one.

### Approximate runtimes (measured on this project, same machine class)

| Run | Expect |
|-----|--------|
| `synth_cl_bsw_f2.tcl` (synthesis only, ~71K LUT) | ~5–15 min per invocation |
| `impl_bsw_top_f2.tcl` (synth + place + route + 2× phys_opt, Explore directives, 4 ns target) | ~30–60 min, longer if the router struggles |

Anchors: `chaining_pe_pair_top` at ~199K LUT synthesised in ~14.5 min; `matesw_dedup`
dropped from 41 min to 1.5 min once its arrays inferred as BRAM. `bsw_top` is 71,320 LUT
/ 27,370 FF / 140 DSP / 0 BRAM, so it sits well below the 14.5-min datapoint. 8 GB of
free RAM is comfortable.

## F2 AFI build (current target — needs AWS)

| Requirement | Notes |
|-------------|-------|
| AWS **FPGA Developer AMI** | Ships a licensed Vivado matched to the HDK, and is where the DCP build runs (a cheap CPU instance, *not* an F2). **Do not install a pinned Vivado locally just for this** — the build links against AWS's pre-built encrypted shell checkpoint, and the AMI already has both the right version and the licence. |
| Xilinx Vivado version | **2024.1 / 2024.2 / 2025.1 / 2025.2** only — from the `f2` branch's own `supported_vivado_versions.txt`. A newer Vivado cannot open AWS's shell checkpoint. |
| `aws-fpga` HDK | The **`f2` branch** (not `master`, which is the F1 line). `source hdk_setup.sh`. |
| AWS CLI + S3 bucket | For `hdk/scripts/create_afi.py` (DCP → AFI). |
| `f2.6xlarge` instance | Smallest F2 (1 FPGA, 24 vCPU). Loads the AFI and runs `host/test_bsw.c` (`-lfpga_mgmt`). |

Full steps + roadblocks: [`docs/f2_build_runbook.md`](docs/f2_build_runbook.md).
**`clk_main_a0` is FIXED at 250 MHz on F2** — no clock recipe changes it. See
[`docs/f2_bringup.md`](docs/f2_bringup.md).

## F1 AFI build (superseded — kept for reference)

| Requirement | Notes |
|-------------|-------|
| AWS **FPGA Developer AMI** | Ships a licensed Vivado matched to the HDK. Do **not** use an arbitrary local Vivado — the HDK pins specific versions. |
| `aws-fpga` HDK | F1 release tag **v1.4.25** (the last F1 line; `master` is now F2-only). `source hdk_setup.sh`. |
| AWS CLI + S3 bucket | For `create-fpga-image` (DCP → AFI). |
| `f1.2xlarge` instance | To load the AFI and run `host/test_bsw.c` (built with `-lfpga_mgmt`). |

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
