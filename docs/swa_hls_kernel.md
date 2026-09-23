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

## Next

C-sim is done — that is what `make check` is. Co-simulation needs Vitis HLS:
wrap `ksw_extend_hls` as the top function, `csim_design` then `cosim_design`
against the same vectors.
