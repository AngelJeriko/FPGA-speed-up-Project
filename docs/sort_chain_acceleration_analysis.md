# Sort / Chaining Acceleration Analysis (post-seeding hotspots)

Source-level investigation of the two under-attacked hotspots from our profile:
sorting alignment registers (~22%) and chaining (~11%) — together ~33%, as large
as FM-index seeding, and **compute-bound** (no memory wall), unlike seeding.

Date: 2026-06-13. Source: `bwa-mem2/src/bwamem.cpp`, `bwamem_pair.cpp`.

---

## What the ~22% "sort" actually is

It is **not one large sort** — it is hundreds of millions of **tiny per-read sorts**
of `mem_alnreg_t` (a read's candidate alignment regions), via `ks_introsort`.

Comparators (bwamem.cpp:149-159):
- `mem_ars2` / `alnreg_slt2`: sort by **reference END position** `re` ascending.
  Used first in `mem_sort_dedup_patch` (line 298: "sort by the END position").
- `mem_ars` / `alnreg_slt`: sort by **score desc**, tie-break `rb` then `qb`
  (line 342, after dedup).
- `mem_ars_hash` / `_hash2`: score/is_alt/hash ordering for stable output.

Call sites: `mem_sort_dedup_patch` (single-end de-overlap, bwamem.cpp:292) and the
paired-end paths `sort_alnreg_re` / `sort_alnreg_score` (bwamem_pair.cpp), invoked
once or more **per read**.

### Why it costs ~22%
- `introsort` per-call overhead (median-of-3 pivot, recursion, insertion-sort
  fallback) is large relative to the tiny arrays, × ~hundreds of millions of reads.
- It is interleaved with an O(n²)-within-window **de-overlap / dedup** loop
  (`mem_sort_dedup_patch`): for each region, scan prior regions within
  `max_chain_gap`, test overlap (`or_`,`oq` vs `mask_level_redun`), and either drop
  the redundant one or **merge** via `mem_patch_reg` → `bwa_gen_cigar2` (a banded
  global re-alignment). The profile attributes ~22% to the introsort symbols
  specifically (compare/swap work), separate from the dedup loop.

## Chaining (~11%)
`mem_chain2aln_across_reads_V2` (bwamem.cpp:2069) + `test_and_merge` (line 357):
builds chains by scanning seeds and merging colinear ones via integer containment
and gap tests (`qbeg`/`rbeg`/`len`, `max_chain_gap`). Sequential/streaming with
simple arithmetic.

## FPGA implications

**Sort = textbook FPGA win.** Small, bounded-`n` sorts map directly to a **bitonic
sorting network**: fixed latency, fully pipelined, no recursion/branching. Cap
alnregs per read at ~32-64 and the sorter is tiny and fast. Advantages over the
seeding engine:
- **No memory wall** — operates on small on-chip arrays (M20K/registers), not DRAM.
- **Bit-exact checkable** — deterministic output → validates vs golden vectors.
- Classic, well-understood hardware pattern.

**But sort is glued to dedup/de-overlap.** A pure sort accelerator captures only
part of the 22%. The real engine is a combined **sort + de-overlap + dedup unit**:
- sort by end-pos (bitonic),
- overlap/redundancy test = integer range arithmetic on `rb/re/qb/qe` → HW-friendly,
- the occasional `mem_patch_reg` merge re-alignment (`bwa_gen_cigar2`) **reuses the
  same banded-SW primitive already on our build list**,
- re-sort by score (bitonic), final dedup pass.

**Chaining** maps to a streaming chain-builder (integer compare/merge), also a good
FPGA fit; needs a deeper read of `mem_chain2aln_across_reads_V2` to fully scope.

## Amdahl ceilings (compute-bound — no memory wall)
| Target | % runtime | Ceiling |
|---|---|---|
| sort/dedup | ~22% | 1.28× |
| chaining | ~11% | 1.12× |
| sort + chaining | ~33% | **1.49×** |

Comparable to seeding's 1.43× ceiling — but **easier to build and verify** (compute-
bound, small on-chip data, bit-exact, reuses SW core).

## Strategic takeaway
The sort/dedup stage is an under-rated, attractive FPGA target and a candidate to
build **early** — alongside or even before the harder, memory-bound seeding engine —
because it is bit-exact-verifiable now, needs no HBM, uses a classic HW pattern, and
shares the banded-SW primitive. In the full on-chip pipeline it sits as the
"de-overlap/dedup" stage after extension:
EMF → seeding (FMA/ERT) → chaining → extend (banded SW) → **sort+dedup** → pair/output.

## Open / next
- Read `mem_chain2aln_across_reads_V2` in full to scope the chaining engine.
- Measure the actual per-read alnreg count distribution (sets the bitonic network
  size) — derivable from a golden run.
- Cross-check against the cited research pass (mm2-fast vectorized chaining, HW
  sorting networks) — workflow `w32du8bwz`.
