# Merge-Sorter Engine — Verification Report

Consolidated record of how the merge-sorter engine (v1 score-sort + v2 full
sort/de-overlap/dedup) was verified, and the results of every check. The engine
reproduces bwa-mem2's `mem_sort_dedup_patch` (the ~22% `ks_introsort` hotspot);
see `merge_sorter_engine_scope.md`, `merge_sorter_v2_design.md`,
`merge_sorter_v2_tie_analysis.md`.

Status: **functionally signed off** (all simulation checks pass). Only physical
synthesis (Fmax/area on Quartus) remains — see `merge_sorter_synthesis.md`.

## Methodology

Golden vectors are captured from a **real bwa-mem2 run** (chr1-5 / HG00733, via the
temporary instrumentation in `docs/bwamem2_instrumentation.md`): the actual
pre-/post-sort and pre-dedup→final arrays the production aligner produced. "Bit-exact"
means the model/RTL output equals bwa-mem2's output field-for-field. The C++ models are
checked **exhaustively** (every captured vector); the RTL is checked on the full captured
set at `MSORT_PER_N=999`.

## Results

### C++ reference models (exhaustive vs real `ks_introsort`)
| model | vectors | result |
|---|---|---|
| v1 score sort (`host/merge_sorter/test_sorter`) | 21,386 (n=2..1060) | **21,386/21,386 bit-exact**, packing==comparator, 0 ties |
| v2 dedup (`host/merge_sorter/test_v2`) | 2,625 tie-free | **2,625/2,625 bit-exact** (815 tie arrays = SW-fallback set) |

### SystemVerilog RTL (Verilator)
| testbench | scope | vectors | result |
|---|---|---|---|
| `tb_msort` | v1 folded merge sorter (block-RAM) | 21,325 (all n≤1024) | **ALL PASS** |
| `tb_msort_dedup` | v2 windowed de-overlap FSM | 2,625 | **ALL PASS** |
| `tb_msort_v2` | full engine, raw input→final output | 2,625 tie-free | **ALL PASS** |

### Final hardening checks
| check | what it exercises | result |
|---|---|---|
| **Full coverage** (`MSORT_PER_N=999`) | every captured hardware-handled vector, not a per-size subset | v1 **21,325/21,325**, dedup **2,625/2,625**, top **2,625/2,625** |
| **N_MAX=1024 boundary** | the largest in-hardware array size | covered (included above) |
| **Output backpressure** (`+BP`) | `out_ready` deasserted ~1/8 cycles; output must hold stable | **2,625/2,625** bit-exact |
| **Fallback-on-tie** (positive) | equal-`re`-tie arrays must raise `fallback` (host redoes in SW) | **784/784 raise fallback**; tie-free never do |
| **Integer redundancy surrogate** | `20·x > 19·y` == float `x > 0.95f·y` over operand range | **0 mismatches** (`host/merge_sorter/check_redun_int.cpp`; see `merge_sorter_v2_design.md`) |
| **Lint** (`verilator --lint-only -Wall`) | width/unused/structural issues | **clean** on all 3 modules |

### Out-of-scope by design (handled on the host, bit-exact)
- `n ≤ 1`: returned trivially by bwa-mem2 before the sort; never reaches the engine.
- `n > 1024`: software fallback (the v1 sizing found these are 0.03% of cost).
- equal-`re`-tie arrays: software fallback (1.25% of arrays, 1.21% of cost) — the
  hardware raises `fallback` so the host knows.

## Reproduce

```sh
# C++ models (exhaustive)
cd host/merge_sorter && make run && make run_v2

# RTL, full coverage (auto-bootstraps vectors from the committed .bin.gz)
cd <repo root>
MSORT_PER_N=999 scripts/run_sim.sh tb_msort
MSORT_PER_N=999 scripts/run_sim.sh tb_msort_dedup
MSORT_PER_N=999 scripts/run_sim.sh tb_msort_v2          # tie-free + fallback-on-tie

# backpressure (build + run the binary with +BP)
verilator --binary --timing --top-module tb_msort_v2 --timescale 1ns/1ps \
  -Wno-WIDTH -Wno-UNOPTFLAT -Wno-TIMESCALEMOD -Irtl -Mdir /tmp/obj \
  rtl/msort_v2_pkg.sv rtl/msort_v2_top.sv tb/tb_msort_v2.sv
/tmp/obj/Vtb_msort_v2 +VEC=tb/vectors/msort_v2_vectors.hex +BP

# lint
verilator --lint-only -Wall -Wno-DECLFILENAME -Irtl rtl/msort_pkg.sv      rtl/msort_merge_sorter.sv
verilator --lint-only -Wall -Wno-DECLFILENAME -Irtl rtl/msort_v2_pkg.sv   rtl/msort_dedup.sv
verilator --lint-only -Wall -Wno-DECLFILENAME -Irtl rtl/msort_v2_pkg.sv   rtl/msort_v2_top.sv
```

## Remaining (not a simulation check)
- **Quartus synthesis** for real Fmax/area + timing closure (`scripts/synth_msort.tcl`;
  needs Quartus, not installed in the dev environment). Analytical estimate:
  `merge_sorter_synthesis.md` (~12 M20K, ~400–800 ALM, est. 250–350 MHz).
