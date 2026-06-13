# Merge-Sorter — Synthesis Flow & Resource Estimate

How to synthesize `rtl/msort_merge_sorter.sv` for real Fmax/area, plus an
analytical estimate to expect. The functional design is verified bit-exact in
simulation (`docs/merge_sorter_engine_scope.md` §6, `tb/tb_msort.sv`); this step
turns it into timing/area numbers on the target Intel part.

## Running it

Requires Quartus Prime Pro (not installed in the current dev environment — this
is set up for when it is available):

```sh
# from repo root, Quartus on PATH
quartus_sh -t scripts/synth_msort.tcl                 # default: Stratix 10 MX (DE10-Pro)
quartus_sh -t scripts/synth_msort.tcl 1SX280HU2F50E2VG # override device (e.g. D5005)
```

Outputs land in `build/msort/`; the script prints an ALM/M20K/Fmax summary and
points at the full `*.fit.rpt` / `*.sta.rpt`. Clock target is in
`scripts/msort.sdc` (200 MHz start — tighten after the first fit to find Fmax).

## What the RTL maps to

- **Two simple-dual-port block RAMs** (`bankA`, `bankB`), each 1024 deep × 106 b
  ({96-bit key, 10-bit index}). Synchronous (registered) read + write → infers
  M20K. The merge unit keeps each run's head in a register and prefetches the
  refill, so it tolerates the 1-cycle RAM read latency.
- **One merge datapath**: a single 96-bit unsigned comparator + a small control
  FSM + a handful of 11-bit counters (the "fold" — reused every pass).

## Analytical estimate (to be confirmed by synthesis)

Target: Stratix 10 MX 2100 (`1SM21BHU2F53E1VG`) — ~933K ALMs, ~6,847 M20K.

| Resource | Estimate | % of device | Notes |
|---|---|---|---|
| M20K | ~12 blocks | ~0.18% | 2 banks × 1024×106 b = 217 Kb; width/depth quantization → ~6/bank |
| ALM | ~400–800 | <0.1% | dominated by the 96-bit comparator + FSM/counters |
| Registers | ~600–900 | <0.1% | hL/hR (2×106 b) + RAM output regs + counters |
| Fmax | ~250–350 MHz (expect) | — | critical path = 96-bit compare → take-mux → write addr |

The engine is **area-trivial**: it costs a fraction of a percent of the device.
Because the comparison key is only 96 bits and there is one merge unit, Fmax
should be comfortable; the registered-read RAM keeps the memory off the critical
path.

## Throughput & scaling

Per sort: ≈ **2·n·⌈log₂n⌉ + ~3·(#run-pairs)** cycles (current 2-cycle/element
merge + per-pair priming). At n=1024 that is ~23k cycles ≈ 92 µs @250 MHz.

Across a whole run the ~22% `ks_introsort` hotspot is ~2.2×10⁹ (n·log₂n) units
for 10M read pairs → ~4.4×10⁹ cycles ≈ 18 s @250 MHz for a *single* engine.
Since one engine is <0.2% of the device, **replicate**: 16 engines ≈ ~1 s, and
hundreds fit. Throughput is therefore not a constraint — area is the budget and
it is tiny.

Two cheap future speedups if ever needed:
1. **1-cycle/element merge** (read-forwarding instead of the 2-cycle STEP/LATCH)
   → ~2× fewer cycles. Adds a forwarding mux; left as a v1.2 once synthesis
   confirms timing headroom.
2. **Wider/parallel merge** (radix-k merge) → fewer passes. Larger area; only
   worthwhile if a single engine must keep up alone.
