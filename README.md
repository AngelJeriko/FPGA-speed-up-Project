# BWA-MEM2 FPGA Accelerator

Hardware (SystemVerilog) acceleration of the **post-seeding compute pipeline** of
[BWA-MEM2](https://github.com/bwa-mem2/bwa-mem2), targeting the **AWS `f1.2xlarge`**
instance (Xilinx Virtex UltraScale+ **VU9P**, Vivado toolchain). Every engine is
verified **bit-exact against the BWA-MEM2 C++ reference** and mutation-tested.

> **New here? Start with [`docs/project_status.md`](docs/project_status.md)** — it is
> the current, outside-reader map of what exists, how it's verified, and what remains.
> To reproduce the project from scratch, follow [`docs/reproducing.md`](docs/reproducing.md).

> ⚠️ **Scope note (2026-08).** Earlier versions of this README described a
> standalone banded-Smith-Waterman kernel targeting *Intel/Quartus*. That is
> superseded: the target is **AWS F1 / Xilinx VU9P / Vivado**, and the project now
> spans the full post-seeding pipeline (chaining, extension, merge-sort, mate rescue),
> not just the SW kernel.

## What this is

BWA-MEM2 profiling (see below) shows FM-index **seeding ~32%** of runtime dominates,
and it is a poor FPGA fit (memory-latency bound). So this project accelerates the
**post-seeding compute** — a good hardware fit — as a single on-chip pipeline,
bit-exact to software:

**seed chaining → banded Smith-Waterman extension → merge-sort/dedup → mate rescue.**

## Status (2026-08-06)

- **All engines built & bit-exact in simulation** (Verilator 5.020). 42 testbenches;
  a representative set was independently re-run and confirmed green, including a
  mutation check that the harness goes red. Highlights: `tb_bsw_top` (score=5),
  `tb_cl_bsw_ocl` 13/13, `tb_orch_purge` 200/0, `tb_matesw_top` 4000/0, full
  `tb_chaining_pe_pair_top` 100/0.
- **Timing (real Vivado P&R, 7-series proxy):** `bsw_top` closes **124.4 MHz** (→ clears
  the 125 MHz F1 target on the faster VU9P); full `chaining_pe_pair_top` at **115.6 MHz**
  and climbing. Detail: [`docs/synth_ooc_results.md`](docs/synth_ooc_results.md).
- **F1 bring-up:** the OCL AXI-Lite wrapper (`rtl/f1/cl_bsw_top.sv`) + host
  (`host/f1/test_bsw.c`) are built and verified; the AWS AFI build is the pending,
  user-side step — steps in [`docs/f1_build_runbook.md`](docs/f1_build_runbook.md).

## Architecture (banded SW core)

A linear systolic array of `N_PE = BAND_WIDTH` processing elements computes the
DP matrix one anti-diagonal per cycle; each PE holds one query base and a column of
state (`H`, `E`, `F`); the target stream flows through the array.

```
        target →  PE_0 → PE_1 → … → PE_{N-1}
                   |      |          |
                  H,E,F  H,E,F      H,E,F
                   ▼      ▼          ▼
              ┌──────── max-tracker ────────┐
              │  score, qle, tle, gscore…   │
              └─────────────────────────────┘
```

- **`bsw_pe`** — one DP cell (affine-gap, BWA `H_diag != 0` gate).
- **`bsw_systolic_array`** — `N_PE` PEs, wavefront-wired.
- **`bsw_ctrl_fsm`** — request → load → run → drain → done.
- **`bsw_max_tracker`** — row-tail pipeline (score/qle/tle, gscore/gtle), dead-row
  early-exit, z-drop.
- **`bsw_top`** — host-facing wrapper (valid/ready handshakes).

The chaining, merge-sort, mate-rescue, and orchestrator engines wrap this core into
the full pipeline — see [`docs/project_status.md`](docs/project_status.md) §2 for the
module inventory.

## Repository layout

```
rtl/            46 SystemVerilog files — the compute engines + F1 CL wrapper (rtl/f1/)
tb/             42 self-checking testbenches (Verilator)
host/           C++ golden models + vector generators (host/integration.md);
                host/f1/test_bsw.c is the F1 host app
synth/ooc/      out-of-context synthesis/timing harness (synth/ooc/README.md)
scripts/        run_sim.sh (Verilator runner), cl_bsw_files.f (F1 CL source list)
docs/           29 docs — status, runbooks, profiling, and design rationale
REQUIREMENTS.md tool/version requirements per stage
```

## Quick start (simulation — fully self-contained)

Requires Verilator ≥5.0 and a C++ toolchain (see [`REQUIREMENTS.md`](REQUIREMENTS.md)).

```bash
bash scripts/run_sim.sh tb_bsw_top       # -> "... 0 errors" + "PASS"; ACGT/ACGT score=5
bash scripts/run_sim.sh tb_cl_bsw_ocl    # F1 OCL wrapper: 13/13, score=5
```
Each build lands under `/tmp/bsw/obj_<tb>/` (override with `BSW_BUILD_DIR=...`).
**CI note:** testbenches report pass/fail on their printed summary line and end on
`$finish`, so a *failing* run still exits 0 — grep the summary line, not `$?`.

## Configuration

Sizing and scoring live in [`rtl/bsw_pkg.sv`](rtl/bsw_pkg.sv):

| Parameter | Default | Meaning |
|-----------|--------:|---------|
| `MAX_QLEN` | 160 | maximum query length |
| `MAX_TLEN` | 1024 | maximum target length |
| `BAND_WIDTH` = `N_PE` | 160 | PEs in the systolic array (must be ≥ `MAX_QLEN`) |
| `SCORE_WIDTH` | 16 | signed score bit-width (matches C++ SIMD path) |
| `M_ALPHABET` / `BASE_WIDTH` | 5 / 3 | {A,C,G,T,N}, 3 bits/base |
| `W_MATCH` / `W_MISMATCH` | 1 / −4 | match bonus / mismatch penalty |
| `W_O_DEL` / `W_E_DEL` | 6 / 1 | gap open / extend (deletion) |
| `W_O_INS` / `W_E_INS` | 6 / 1 | gap open / extend (insertion) |
| `W_AMBIG` | −1 | `N`-vs-anything |
| `W_ZDROP` | 100 | z-drop threshold (0 disables) |
| `W_END_BONUS` | 5 | end bonus |

These match BWA-MEM2 defaults (`-A 1 -B 4 -O 6 -E 1`). Per-alignment runtime values
(`h0`, `qlen`, `tlen`, penalties, `w`, …) arrive in the `bsw_config_t` struct on the
request handshake. A static 16-bit overflow proof is in
[`docs/bit_width_proof.md`](docs/bit_width_proof.md).

## Reproducing the whole project

See **[`docs/reproducing.md`](docs/reproducing.md)** for the ordered, from-scratch
recipe: environment → software baseline + profiling → simulation → synthesis/timing →
F1 AFI. Tool versions are pinned in [`REQUIREMENTS.md`](REQUIREMENTS.md).

## License

[MIT](LICENSE). Algorithm credit to the BWA-MEM2 authors (Vasimuddin, Misra, Li,
Aluru, *IPDPS 2019*); see the upstream project for the original C++ reference.
