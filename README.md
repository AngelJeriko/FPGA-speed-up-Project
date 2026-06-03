# FPGA Banded Smith-Waterman Accelerator

A parameterized SystemVerilog implementation of the banded Smith-Waterman
alignment kernel from [BWA-MEM2](https://github.com/bwa-mem2/bwa-mem2),
targeting Intel FPGAs (Quartus toolchain). The RTL is a hardware port of
`BandedPairWiseSW::scalarBandedSWA` in `src/bandedSWA.cpp` and preserves
BWA-MEM2's seed-extension / semi-global semantics — not pure local SW.

## Status

**29 / 29 self-checking testbench passes.**

| Testbench       | Checks | Status |
|-----------------|:------:|:------:|
| `tb_bsw_pe`     | 18     | PASS   |
| `tb_bsw_top`    | 11     | PASS   |

Coverage includes match/mismatch recurrence, semi-global `H_diag=0` gate,
local-clamp on negative scores, ambiguous-`N` scoring, pipeline forwarding,
target forwarding, first-row `eh[]` initialisation, first-column `h0`-decay
boundary, dead-row early exit, and the full result tuple (`score`, `qle`,
`tle`, `gscore`, `gtle`, `max_off`).

## Architecture

A linear systolic array of `N_PE = BAND_WIDTH` processing elements computes
the dynamic-programming matrix one anti-diagonal per cycle. Each PE holds
one query base and one column of state (`H`, `E`, `F`); the target stream
flows left-to-right through the array.

```
                     target  →  PE_0  →  PE_1  →  …  →  PE_{N-1}
                                 |       |              |
                                 H,E,F   H,E,F          H,E,F
                                 ▼       ▼              ▼
                            ┌────────── max-tracker ──────────┐
                            │  score, qle, tle, gscore, …    │
                            └─────────────────────────────────┘
```

Top-level pieces:

- **`bsw_pe`** — one DP cell. Affine-gap recurrence with the BWA-MEM2
  `H_diag != 0` gate (`M = H_diag ? H_diag + S : 0`).
- **`bsw_systolic_array`** — `N_PE` PEs wired wavefront-style.
- **`bsw_ctrl_fsm`** — request handshake → load → run → drain → done.
  Generates the first-row `eh[j]` seed for each PE and the decaying
  first-column boundary fed to `PE_0`.
- **`bsw_max_tracker`** — row-tail pipeline that tracks `(score, qle, tle)`
  and `(gscore, gtle)`, plus dead-row early-exit and z-drop.
- **`bsw_top`** — host-facing wrapper with valid/ready handshakes.

## Repository layout

```
rtl/
  bsw_pkg.sv             package: parameters, types, scoring function
  bsw_pe.sv              one DP cell (HEF affine-gap recurrence)
  bsw_systolic_array.sv  N_PE-wide wavefront array
  bsw_ctrl_fsm.sv        top-level control FSM
  bsw_max_tracker.sv     row-tail pipeline + early-exit
  bsw_score_matrix.sv    5×5 score matrix lookup
  bsw_top.sv             host-facing wrapper
tb/
  tb_bsw_pe.sv           PE unit tests (18 checks)
  tb_bsw_top.sv          full-alignment integration tests (11 checks)
scripts/
  file_list.f            ordered SV file list for tool flows
  run_sim.sh             Verilator runner (Linux / WSL)
  run_sim.ps1            Verilator runner (PowerShell wrapper)
logs/
  session_log.md         dev history — bug hunt and design decisions
```

## Build & test

### Requirements

- [Verilator](https://verilator.org/) ≥ 5.0 (tested on 5.032 under WSL Ubuntu)
- A C++ toolchain (`g++`, `make`)
- For Windows users: run under WSL — Verilator's `make` step does not tolerate
  spaces in absolute paths.

### Run the testbenches

```bash
# From the repo root, inside WSL (or any Linux shell):
./scripts/run_sim.sh tb_bsw_pe
./scripts/run_sim.sh tb_bsw_top
```

Each invocation builds a Verilator binary under `/tmp/bsw/obj_<tb>/` and
prints per-check pass/fail lines followed by `PASS` or `FAIL`. Override the
build directory with `BSW_BUILD_DIR=/some/path` if `/tmp` isn't writable.

Expected last line of `tb_bsw_top`:

```
==== tb_bsw_top done: 11 checks, 0 errors ====
PASS
```

## Configuration

All sizing and scoring lives in `rtl/bsw_pkg.sv`:

| Parameter       | Default | Meaning                                           |
|-----------------|--------:|---------------------------------------------------|
| `MAX_QLEN`      | 128     | maximum query length (matches BWA-MEM2)           |
| `MAX_TLEN`      | 256     | maximum target length                             |
| `SCORE_WIDTH`   | 16      | signed score bit-width (matches C++ SIMD path)    |
| `BAND_WIDTH`    | 64      | PEs in the systolic array (≥ `2*w + 1`)           |
| `W_MATCH`       |   1     | match bonus                                       |
| `W_MISMATCH`    |  −4     | mismatch penalty                                  |
| `W_O_DEL` / `W_E_DEL` |  6 / 1 | gap open / extend (deletion)                |
| `W_O_INS` / `W_E_INS` |  6 / 1 | gap open / extend (insertion)               |
| `W_AMBIG`       |  −1     | `N`-vs-anything penalty                           |
| `W_ZDROP`       | 100     | z-drop threshold (0 disables)                     |

Per-alignment runtime values (`h0`, `qlen`, `tlen`, penalties, `zdrop`,
`end_bonus`, band half-width `w`) are passed in the `bsw_config_t` struct
on the request handshake.

## Known TODOs

These are documented but not blocking the current correctness milestone:

- **Full BWA-MEM2 banding.** The current array processes the full
  `BAND_WIDTH` of PEs per row. The C++ reference also dynamically shrinks
  the active range (`beg` / `end`) within the band as scores die off.
- **Swath processing.** Queries longer than `BAND_WIDTH` need to be
  processed in vertical swaths. The control FSM currently assumes
  `qlen ≤ N_PE`.
- **Bit-width audit.** `SCORE_WIDTH = 16` matches the C++ SIMD path but
  has not been formally proven sufficient for `MAX_QLEN = 128`.
- **Dedicated z-drop test.** Z-drop early-exit is wired but only covered
  incidentally; an explicit failing-tail test vector would tighten coverage.

## License

[MIT](LICENSE). Algorithm credits to the BWA-MEM2 authors — see the upstream
project for the original C++ reference.
