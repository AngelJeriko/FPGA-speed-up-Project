# Making `ksw_extend2` synthesizable

Second step of the HLS milestone. `docs/swa_golden_capture.md` covers the
golden vectors; this covers the kernel that has to reproduce them.

`host/extend_orchestrator/ksw.h` is a verbatim port of bwa-mem2's
`ksw_extend2` and stays verbatim — the whole extend-orchestrator model is
built on it. The synthesizable kernel is a separate file,
`host/swa_hls/ksw_hls.h`, holding the same arithmetic and the same control
flow with everything Vitis HLS cannot synthesize removed.

## What HLS could not accept, and what replaced it

| # | Blocker | Replacement | Why it preserves behaviour |
|---|---|---|---|
| 1 | `malloc(qlen*m)`, `calloc(qlen+1,8)`, `free` | fixed arrays sized from `rtl/bsw_pkg.sv` (`MAX_QLEN=160`, `MAX_TLEN=1024`, `m=5`) | same envelope as the SystemVerilog core; an explicit bounded loop does what `calloc` did |
| 2 | loops bounded by runtime `qlen`/`tlen` | compile-time bounds with the original test as an inner `break` | each rewrite leaves the loop variable at the *same* exit value |
| 3 | five `int*` out-params | a returned `struct` | becomes output ports |
| 4 | two `(int)((double)X/e + 1.)` | `(X + e) / e` | exhaustively proven identical (below) |
| 5 | `eh_t{h,e}` array-of-structs | two parallel arrays | two independent memory ports instead of one |
| 6 | unchecked `mat[query[j]]`, `qp[target[i]*qlen]` | index clamped to `[0,m-1]` | inert for bases 0..4; makes bad input safe rather than undefined |
| 7 | no bounds behaviour | `status` field | reports an out-of-envelope input instead of overflowing |

Widths stay `int32_t`, matching the reference exactly. The `H_MAX = 1184`
bound for 160/1024 means 16 bits would suffice, so the `eh` arrays are a
narrowing candidate — deliberately *not* bundled with this milestone, because
a resource change and a bit-exactness claim should not land together.

### Change (2) is the subtle one

The DP loop's exit value is read afterwards:

```c
for (j = beg; LIKELY(j < end); ++j) { ... }
eh[end].h = h1; eh[end].e = 0;
if (j == qlen) { ... gscore ... }       // <-- reads j
```

so `for (j = beg; j < MAX_QLEN; ++j) { if (j >= end) break; ... }` is only
correct because it leaves `j == end` when the band is non-empty and `j == beg`
when it is empty, exactly as the original does. The same care applies to the
two band-trimming loops, one of which counts *down* and is expected to exit at
`beg - 1`.

### Change (4) is proven, not sampled

`test_div_transform.cpp` checks `(int)((double)X/e + 1.) == (X + e)/e` over
`X` in ±100,000 and `e` in 1..256 — **51,200,256 / 51,200,256 exact**. The
`+1.0` is applied before truncation, so `trunc(X/e + 1) == trunc((X+e)/e)`,
and C integer division truncates toward zero like `trunc()`. This removes the
only floating point in the kernel. It is the same transform already proven for
`cal_max_gap_int`.

## Result

```
records : 49468
reference vs golden    : PASS  49468/49468 bit-exact, 0 mismatches
hls       vs golden    : PASS  49468/49468 bit-exact, 0 mismatches
hls       vs reference : PASS  49468/49468 bit-exact, 0 mismatches
```

Across all seven captures (default, two band widths, asymmetric gaps, and two
tight-gap configurations — 345,000+ records) **`hls == reference` everywhere**,
including on the records where the reference itself disagrees with bwa-mem2.
That is the invariant that matters: the HLS kernel is a port of `ksw_extend2`,
so it must track the port rather than paper over its quirks. `make check`
enforces it.

## Mutation check

| mutant | change | result |
|---|---|---|
| MH2 | band loop exit `j >= end` -> `j > end` | **RED** 49,288 mismatches |
| MH6 | drop `+ e_del` from the division transform | **RED** on the band-clamp vectors |
| MH1 | division transform off-by-one (`+ e - 1`) | GREEN — *absorbed*, see below |
| MH3 | `TRIM_HI` exit `j < beg` -> `j <= beg` | GREEN — *provably equivalent* |
| MH7 | `TRIM_LO` exit `j >= end` -> `j > end` | GREEN — *provably equivalent* |
| MH4 | base clamp `m-1` -> `0` | GREEN — inert, as documented |
| MH5 | `eh` zeroing range off-by-one | GREEN — the cell is written before it is read |

**MH3 / MH7 are equivalent, not uncovered.** Both only change the exit value
when the entire band is zero — and `if (mm == 0) break;` fires first in that
case, so the trimming loops are unreachable with an all-zero band.

**MH1 is absorbed by the clamp structure.** `w = min(w, max_ins)` then
`w = min(w, max_del)`; with bwa's parameters `max_del <= max_ins`, so a
&plusmn;1 error in `max_ins` never reaches `w`. The exhaustive proof above
covers the identity directly, which is why it is a proof and not a sample.

**Coverage had to be extended to kill MH6.** With default `e_del = e_ins = 1`
the band clamp never binds (`max_ins ~ 131` against `w = 100`), so the
division transform is dead weight on the default vectors and *every* mutation
of it survived. Captures with `-E 20,20` and `-O 30,30 -E 12,9` make the clamp
bind; the 14 records where it is load-bearing are committed as
`vectors/bandclamp_*.bin.gz` and MH6 is red on them.

This is worth remembering: the first mutation run on this kernel reported all
five mutants green, which was a broken harness — `#include "ksw_hls.h"` from
`replay_swa.cpp` resolves to the file *next to the source* before any `-I`
path, so the mutants were never compiled in. The real result only appeared
after the harness compiled from the mutant's own directory.

## Next: co-simulation

C-sim is done — that is what `make check` is. The HLS project is
`host/swa_hls/hls/` (see its README for the exact command):

- `ksw_kernel.cpp` wraps `ksw_extend_hls` as the top function `ksw_extend_top`
- `tb_ksw_hls.cpp` is shared by C-sim and co-sim
- `cosim_vectors.h` embeds 24 golden records spread over the (qlen, tlen)
  envelope — co-sim runs against RTL, so the full 49,468 would not finish
- `run_hls.tcl` runs csim -> csynth -> cosim and prints one PASS/FAIL block

The target box has Vitis 2026.1 with **no** `vitis_hls.bat` — the 2024.1+
unified flow, driven by `vitis-run --mode hls --tcl`. The script detects this
and uses `open_component`, falling back to `open_project`/`open_solution`
otherwise, so it works on either. It was syntax-checked under `tclsh` with the
HLS commands stubbed (both branches, the report parser, and the failure path);
the real command behaviour in 2026.1 is still unverified.

---

# Co-simulation result (2026-10-03)

Run on Vitis HLS 2026.1, part `xcku5p-ffvb676-2-e`, 8.0 ns clock (125 MHz).

```
csim   : PASS   24/24 vectors bit-exact
csynth : PASS   Estimated Fmax 174.56 MHz
cosim  : PASS   *** C/RTL co-simulation finished: PASS ***
```

**The milestone is met**: the same golden vectors reproduce bit-for-bit in
C-simulation and in C/RTL co-simulation against the generated Verilog, under
XSIM. Co-sim checks the testbench's comparison *twice* — once pre-RTL and once
in post-check — and both printed `PASS: 24/24`.

## Timing closure

`Estimated Fmax 174.56 MHz` against a 125 MHz target: ~40% margin, so the
kernel is not timing-limited at the F2 kernel-domain clock.

## Throughput, and the honest comparison to `bsw_top`

The synthesis report's `1504411` cycles / `12.035 ms` is the **static worst-case
bound** HLS derives from the loop bounds (`MAX_TLEN=1024` x `MAX_QLEN=160`
x the trim loops' II). It is not what the design does on real data, and quoting
it unqualified would be badly misleading.

Measured from the XSIM progress timestamps:

| | cycles |
|---|---|
| total, 24 vectors | 274,194 |
| mean per extension call | 11,424 |
| max per call (qlen=131, tlen=257) | 21,441 |
| min per call | 132 |

Against the hand-written systolic core on the same device family:

| | HLS `ksw_extend_top` | `bsw_top` (SystemVerilog) |
|---|---|---|
| architecture | sequential scalar DP, 1 cell/cycle | 160-PE systolic, 1 *band*/cycle |
| cycles, qlen=131 tlen=257 | 21,441 | ~417 (`tlen` + fill) |
| LUT | 8,404 | 63,985 |
| FF | 4,631 | 31,308 |
| DSP | 5 | 140 |
| BRAM_18K | 5 | 0 |
| Fmax | 174.6 MHz (est.) | 219.2 MHz (post-route) |

So HLS is **7.6x smaller and ~51x slower** — the systolic array wins on
area-time product by ~6.8x. This is the expected outcome and not a mark against
HLS: the C source describes a scalar recurrence, and HLS faithfully built a
scalar machine. Getting a systolic array out of HLS would require restructuring
the C into a wavefront form, which is a different exercise from proving
bit-exactness. **`bsw_top` remains the path to silicon**; the HLS kernel's value
is that it is provably the same arithmetic, derived from C, in a form reviewers
can read.

## The II violations, and where the cycles actually go

`csynth` reported `Loop Constraint Status: Not all loop constraints were
satisfied`. Per-loop:

| loop | target II | achieved II | runs |
|---|---|---|---|
| `QP_ROW`/`QP_COL` (flattened) | 1 | **1** | once per call |
| `EH_ZERO` | 1 | **1** | once per call |
| `MAT_MAX` | 1 | **1** | once per call |
| `BAND` (the DP) | 1 | **1** | per target row |
| `EH_INIT` | 1 | 2 | once per call |
| `TRIM_LO` | 1 | **4** | **per target row** |
| `TRIM_HI` | 1 | **4** | **per target row** |

The DP loop itself hit II=1, which is the part that had to work. The cost is in
the two band-trimming loops: they achieve only II=4 *and run once per target
row*, so they dominate. Each iteration reads both `eh_h[j]` and `eh_e[j]` and
can break, and `eh_h` was mapped to a 1R1W RAM — two dependent reads plus a
loop-carried control dependency serialise it.

Note the tension with change (5): splitting `eh_t` into two arrays gave the
`BAND` loop independent ports (II=1, good), but it cost the trim loops a second
dependent read. Packing `h` and `e` back into one 64-bit word would help the
trim loops and hurt `BAND`.

**The better fix removes the loops entirely.** `BAND` already visits every `j`
in `[beg, end)` and writes both arrays, so it can track the lowest and highest
`j` with a nonzero `(h, e)` as a side effect at II=1 — making the separate
rescans unnecessary. That is an algorithmic restructuring, so it must be proven
bit-exact against the same vectors before it is believed. **Deliberately not
done here**: the milestone was bit-exactness, and an optimisation should not
land in the same change as the claim it might invalidate.

Also present: two `sdiv_32s_32s_31_36_seq_1` sequential dividers (36 cycles
each, once per call) for `max_ins`/`max_del`. Cheap, but they are the only
reason the design uses DSPs at all.
