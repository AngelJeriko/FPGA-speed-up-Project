# Putting the genome on the device — design options for external review

**Status:** ⏸️ **DECISION PENDING — awaiting review. No RTL has been written.** **Date:** 2026-07-17.
**Audience:** external reviewers who are *not* assumed to know this codebase or the internals of
read alignment. Every term is defined in the Glossary (Section 2); on first use a term is
*italicised*. Companion to `chaining_extension_wiring_options.md`, which deferred this work as
its **Decision B2**.

**Safe checkpoint:** git tag **`pre-genome-fetch-safe`** (= `94f72a7`, pushed) marks the last
fully-validated state *before* any genome-fetch work: the join complete and bit-exact, full
regression green, reference bytes still host-fed. Revert there if this proves unviable.

---

## 0. Decision sheet — the questions to answer

Read Sections 3–4 for the reasoning; this is the summary to decide against. Recommendations are
the author's, and each is defensible to overturn — the reasoning is in the linked section.

| # | Question | Options | Recommended | Why / what it hinges on | § |
|---|----------|---------|-------------|--------------------------|---|
| **A** | How is the reference stored on the device? | **A1** byte (`.0123`-style, 2.0 GB / ~6.2 GB full hg38) · **A2** packed (`.pac`-style, 254 MB / ~775 MB) · **A3** packed + on-chip cache | **A1 to start; A2 as a measured follow-up** | Bandwidth is <1% of HBM, so this is **capacity + simplicity**, not throughput. A1 has *zero* fetch logic (§3.3). A2 is 8× smaller — matters only if the future seeding front-end contends for HBM. | §4-A |
| **B** | Where does it live? | **B-i** HBM · **B-ii** DDR · **B-iii** on-chip SRAM | **B-i (HBM)** | Mostly decided by the target board. B-iii is impossible (tens of MB vs ≥775 MB). Seeding will want HBM anyway. | §4-B |
| **C** | When do we build the contig clamp? | **C1** fold into B2 · **C2** land first, standalone, verified | **C2** | **The one piece with real bit-exactness risk.** It's pure arithmetic — it needs no memory subsystem to validate. Landing it first means any later end-to-end mismatch is unambiguously a *fetch* bug. | §3.4, §4-C |
| **D** | How is latency hidden? | **D1** blocking · **D2** prefetch on `rmax` · **D3** deep multi-chain pipelining | **D1 → D2**; D3 only if measured | This is where the win is. A host round trip *cannot* be pipelined away; a memory read *can*. D2 is modest logic for most of the benefit. | §4-D |
| **E** | Do we cache windows? | **E1** none · **E2** small window cache | **E1 until measured** | Locality is a *hypothesis* (mate sits within ~300–500 bp of the read). Cheap to test from the capture we already have. Bandwidth is 99% idle, so re-fetching is nearly free. | §4-E |
| **F** | How is it verified? | — | Capture → model → RTL → **mutation-test the tb** | Needs a **4th capture** (`bns_fetch_seq_v2` I/O) added to `remote_capture_plan.md`, and a **multi-contig test genome** — `g(pos)=pos&3` has no contigs and cannot exercise the clamp at all. | §4-F |

**Recommended path if you agree with all of the above:**
`C2` (clamp first, verified) → `A1 + B-i + D1` (simplest working fetch) → `D2` (prefetch — most of
the win) → then `A2` / `D3` / `E2` **only if measurement justifies them**.

**The two facts that should drive the decision** (both measured/verified this session, not estimated):
1. **Latency is the entire problem; bandwidth is a non-issue.** 8.03 fetches/read × ~2–4 µs host
   round trip ≈ **16–32 µs/read of stall** (worst read: 615 fetches ≈ 1.2–2.5 ms). Meanwhile the
   data rate is ~2.3 GB/s per Mread/s = **<1% of HBM**. Simulation hides all of this. (§3.1–3.2)
2. **The contig clamp is unmodelled work that cannot stay on the host** — asking the host to clamp
   *is* the round trip we're removing. It is the only genuinely new correctness surface here. (§3.4)

**Smallest useful first commitment** if you want to de-risk before committing to the whole thing:
approve **C2 alone**. It is independently valuable (it closes a real gap between our model and
bwa-mem2), independently verifiable against a capture, and it does not presuppose A, B, D or E.

---

## 1. What this document is for

We are building an **FPGA** (Field-Programmable Gate Array — a reconfigurable hardware chip)
accelerator for **BWA-MEM2**, the standard software for *read alignment* in DNA sequencing. The
accelerator now runs the whole back half of the mapper on chip — *chaining* → *extension* → sort →
*mate-rescue* — and produces byte-for-byte the same answers as the software (verified in
simulation).

There is one hole left in that picture. To score a candidate location, the hardware needs a small
slice of the **reference genome** around it. Today it does **not** have the genome; it asks the
**host** CPU for each slice and waits. This document is about closing that hole: **putting the
genome on the device and fetching each slice in hardware.**

This is not a micro-optimisation. **The current design's speedup numbers assume the accelerator is
compute-bound. With a host round-trip per candidate it would be latency-bound, and the speedup
would largely evaporate on real hardware** — a cost that simulation hides completely (our
testbench answers a request in a few clock cycles; a real PCIe round trip does not). So this is
the item standing between "bit-exact in simulation" and "actually faster in a machine".

Everything here preserves **bit-exactness** — byte-for-byte identical output to unmodified
BWA-MEM2 — which is non-negotiable (clinical and research users validate against the standard
software). The options differ in speed, memory cost, and risk.

---

## 2. Glossary (plain-language definitions)

| Term | Meaning |
|------|---------|
| **Read** | A short DNA fragment from the sequencer, e.g. 150 letters of {A,C,G,T}, encoded 0–3. |
| **Reference genome** | The known complete DNA sequence reads are aligned against (~3.1 billion letters for human). |
| **Chain** | A group of consistent seed matches suggesting one candidate location for a read. A read has several. |
| **Extension** | Scoring a chain in detail with dynamic programming. Needs the reference slice around the chain. |
| **`rmax` / window** | The slice of reference a chain's extension is allowed to look at: `[rmax0, rmax1)`. Computed on chip already (`chain2aln_setup`, validated on 241,018 real chains). |
| **Mate-rescue** | A second alignment attempt for a read's paired partner near the first read's location. Also needs a reference slice. |
| **Host** | The CPU/server that drives the FPGA. |
| **PCIe** | The bus between host and FPGA. A round trip costs roughly 1–2 µs *each way* — enormous next to a ~3 ns clock cycle. |
| **HBM** | High-Bandwidth Memory — DRAM stacked next to the FPGA die. Large (8–32 GB) and fast (hundreds of GB/s), but each access still costs ~200–400 ns of *latency*. |
| **DDR** | Conventional DRAM on the card. Larger and cheaper than HBM, lower bandwidth, similar-or-worse latency. |
| **On-chip SRAM (BRAM/M20K)** | Memory built into the FPGA fabric. Tiny (tens of MB at most) but ~1–2 cycles away. The genome does not fit; a *cache* could. |
| **Bandwidth vs latency** | Bandwidth = bytes/second the memory can stream. Latency = the wait for one request. Random small reads are limited by **latency**, not bandwidth — unless you keep many requests in flight. |
| **Prefetch / outstanding requests** | Issuing a read *before* you need the data, and having many in flight at once, so waiting overlaps with useful work. The standard cure for latency. |
| **`.pac`** | BWA's **packed** reference file: 2 bits per letter, 4 letters per byte, **forward strand only**. |
| **`.0123`** | BWA-MEM2's **byte** reference file: 1 byte per letter, holding forward *and* reverse-complement already spelled out. 8× bigger than `.pac`. |
| **Forward / reverse strand** | DNA is double-stranded. BWA works in a coordinate space of `2*l_pac` positions: the first half is the forward strand, the second half the reverse-complement. |
| **`l_pac`** | The number of letters on the forward strand (≈1.01 billion for our chr1-5 reference; ~3.1 billion for full human). |
| **Contig** | One chromosome or scaffold within the reference. The genome is a concatenation of contigs. |
| **`bns_fetch_seq`** | BWA's function that returns the reference slice. It also **clamps** the slice to the contig it lands in and reports which contig (`rid`). |
| **Bit-exact** | Hardware output identical to the reference software. Our universal correctness bar. |
| **SW-fallback** | Safety valve: for rare inputs the hardware flags the case and the host redoes just that one in software. Preserves exactness at a small CPU cost. |

---

## 3. The specific problem

Per chain, the extension needs the reference bytes for `[rmax0, rmax1)`. Today:

```
FPGA: compute rmax on chip  →  raise ref_req  →  ... WAIT FOR HOST ...  →  receive bytes  →  extend
```

The interface for this already exists and is deliberately isolated (`ref_req`/`ref_rbeg`/`ref_len`
out; `ref_in_*` in), plumbed up through `chaining_pe2_top` → `chaining_pe_pair_top` to the host.
**Replacing the host with an on-device memory changes only what sits behind those ports.**

### 3.1 Measured inputs (real data — 30,000 reads, 241,018 chains, hg38 chr1-5 / HG00733)

Measured with `measure_fetch` over the captured extension vectors (`vectors/ext_vec.bin`):

| quantity | mean | p50 | p95 | p99 | max |
|---|---|---|---|---|---|
| **chains per read** (= fetches per read) | **8.03** | 3 | 11 | 122 | **615** |
| **window bytes per chain** | **282** | 276 | 390 | 397 | **811** |
| **reference bytes per read** (sum of its windows) | **2,267** | 1,052 | 3,709 | — | 160,630 |

Reference file sizes measured on this machine (chr1-5, `l_pac` ≈ 1.01 Gbase):

| file | layout | size (chr1-5) | projected, full hg38 (~3.1 Gbase) |
|---|---|---|---|
| `hg38_chr1-5.fa.pac` | 2 bits/letter, forward only | **254 MB** | ~775 MB |
| `hg38_chr1-5.fa.0123` | 1 byte/letter, forward + reverse-complement | **2,025 MB** | ~6.2 GB |

### 3.2 What these numbers mean

**Latency is the problem; bandwidth is not.** Two consequences fall straight out:

- **Bandwidth:** 2,267 bytes/read is ~2.3 GB/s *per million reads/second* (byte layout), or
  ~0.6 GB/s packed. HBM delivers hundreds of GB/s. **Under 1% of the available bandwidth** — this
  matches the earlier finding that back-half data movement is a non-issue (`back_half_speedup_analysis.md`).
- **Latency:** at a mean of **8.03 fetches per read**, a host round trip of ~2–4 µs costs roughly
  **16–32 µs per read of pure stall**, and the *tail* is brutal — a p99 read (122 chains) stalls
  ~0.25–0.5 ms, and the worst observed read (615 chains) would stall **1.2–2.5 ms on its own**.
  An on-device fetch replaces each ~2–4 µs round trip with a ~200–400 ns memory access — **roughly
  10× better before any overlap**, and far more once requests are pipelined (Decision D).

So the layout question below is **not** a bandwidth question. It is a **capacity and simplicity**
question. That reframing is the main result of the measurement.

### 3.3 A significant simplification (found by reading the source)

BWA-MEM2 has already done the hard part at index-build time. `bns_get_seq_v2` (`bwamem.cpp:1851`)
reduces to a single line — **in both the forward and the reverse-strand branch**:

```c
seq = ref_string + beg;      // ref_string = the .0123 array
```

The classic BWA logic — unpack 2 bits (`_get_pac`), mirror the coordinate (`2*l_pac-1-k`),
complement the letter (`3 - base`) — is still in the file but `#if 0`'d out, with asserts left
behind proving the two are equivalent. BWA-MEM2 **pre-materialises** the entire `2*l_pac`
coordinate space at one byte per letter so a fetch is a pure pointer offset.

**Consequence:** if we adopt the same layout, the hardware fetch is *a flat byte read at offset
`beg`* — no unpacking, no mirroring, no complement. That is dramatically less logic than
reimplementing `bns_get_seq`, and it is the strongest argument for Option A1 below.

### 3.4 A scope finding reviewers should not miss

The extension does **not** call the raw `bns_get_seq_v2`. It calls **`bns_fetch_seq_v2`**
(`bwamem.cpp:2172`), which additionally:

1. derives the contig: `rid = bns_pos2rid(bns, bns_depos(bns, mid, &is_rev))` — a binary search
   over the contig offset table;
2. **clamps** the window to that contig's `[offset, offset+len)`, flipping those bounds into
   reverse-strand space when `is_rev`.

That clamp is what stops an alignment running off the end of chr1 into chr2. **Our accelerator
does not model this today.** `orch.h` states its windows are *"post-`bns_fetch_seq` values"* — the
host clamps and hands us the result — and `chain2aln_setup` computes only the *pre-clamp* `rmax`.

Crucially, **this cannot be left with the host**: asking the host to clamp is exactly the round
trip we are removing. So the contig clamp *must* come on chip as part of this work. It needs the
contig table in on-chip SRAM (5 contigs here; ~3,366 for full hg38 with alts/decoys — still only
tens of KB), a small binary search, and the `is_rev` flip. It also needs **new model and golden
coverage**, because our synthetic test genome `g(pos) = pos & 3` has no contigs at all. This is the
one part of B2 with genuine bit-exactness risk, and Decision C is about how to de-risk it.

One further edge case: `bns_get_seq` returns `len = 0` if a window *bridges* the forward/reverse
boundary. The contig clamp makes this unreachable in practice (no contig spans `l_pac`), but the
hardware still needs a defined behaviour rather than undefined output.

---

## 4. The options

Ratings: **Accuracy** describes *how* bit-exactness is maintained (every option preserves it —
that is non-negotiable). **Speed** is the effect on throughput. **Effort/Risk** is build cost.

### Decision A — How the reference is stored on the device

| Option | Description | Accuracy | Speed | Memory | Effort/Risk |
|--------|-------------|----------|-------|--------|-------------|
| **A1. Byte layout (`.0123`), mirroring BWA-MEM2** — *recommended to start* | Store the pre-materialised forward+reverse-complement array, 1 byte/letter. Fetch = flat read at offset `beg`; **zero fetch logic** (§3.3). | Bit-exact by construction — byte-identical to the array the software itself reads. Lowest risk of a subtle strand/packing bug. | Full speed. Bandwidth is <1% of HBM either way (§3.2). | **2.0 GB** chr1-5 / **~6.2 GB** full hg38. Fits HBM (8–32 GB), but consumes most of a small HBM. | **Lowest.** An address generator and a burst read. |
| **A2. Packed layout (`.pac`)** | Store 2 bits/letter, forward only. Hardware unpacks (`(pac[k>>2] >> ((~k&3)<<1)) & 3`) and, for reverse-strand windows, mirrors and complements. | Bit-exact, but we must reproduce the strand/packing maths exactly — the mirror and the reversed-within-byte order (`~k & 3`) are classic off-by-one traps. Verified against a capture. | Same (bandwidth is not the constraint). Fewer bytes per request slightly reduces DRAM traffic and burst count. | **254 MB** chr1-5 / **~775 MB** full hg38 — **8× smaller**. Leaves HBM free for future stages (e.g. seeding). | **Medium.** The logic is cheap in hardware — a barrel shifter and `3 - x` are nearly free and fully pipelined — but it is *new* logic that must be proven bit-exact. |
| **A3. Packed in memory, byte cache on chip** | Store `.pac`; unpack into a small on-chip cache of recently used windows. | As A2. | Best *if* locality exists (Decision E) — otherwise equal. | As A2 + cache. | **Highest.** Combines A2's risk with a cache's. Only justified if E measures real locality. |

**Discussion.** The instinct is "packed is obviously better — 8× less memory, 4× fewer bytes per
window". The measurement undercuts half of that: **bandwidth is not the bottleneck**, so the
4×-fewer-bytes argument buys little. What remains is a real **capacity** argument (775 MB vs
6.2 GB for a full genome) that matters mostly *later*, if the genome must share HBM with a future
seeding front-end — which is precisely the stage that is memory-hungry and currently unbuilt.

Note the interesting asymmetry: **BWA-MEM2 chose bytes because it runs on a CPU**, where the
unpacking sits in an inner loop and costs real cycles, and where host RAM is cheap. On an FPGA
that calculus inverts — the shifter is free and pipelined, and device memory is the scarce
resource. So A2 is *not* obviously wrong for us even though A1 is what the software does; the
honest position is that **A1 is the better starting point** (least risk, and it makes the fetch
provably identical to what the software reads) with **A2 as a measured follow-up** if HBM capacity
becomes contended.

### Decision B — Where the reference lives

| Option | Description | Speed | Effort/Risk |
|--------|-------------|-------|-------------|
| **B-i. HBM** — *recommended* | The stacked DRAM on Agilex 7 M-series / Stratix 10 MX (the parts already named as our synthesis targets). | ~200–400 ns latency, huge bandwidth headroom. Latency is hidden by Decision D, not by bandwidth. | Standard. The board must actually have HBM (our named targets do). |
| **B-ii. DDR** | Conventional card DRAM. | Similar or slightly worse latency; far less bandwidth — still ample at ~2.3 GB/s per Mread/s. | Standard; more widely available. A reasonable fallback if the chosen board has no HBM. |
| **B-iii. Entirely on-chip SRAM** | Keep the genome in FPGA block RAM. | Would be ideal (~1–2 cycles). | **Not possible.** Tens of MB of on-chip SRAM vs 775 MB (packed) or 6.2 GB (bytes). Listed only to close it off explicitly. |

Given bandwidth is a non-issue, **B is mostly decided by what the target board has**; HBM is
preferred because the future seeding front-end will need it anyway.

### Decision C — Scope of the contig clamp (the real risk, see §3.4)

| Option | Description | Accuracy | Effort/Risk |
|--------|-------------|----------|-------------|
| **C1. Fold the clamp into B2 in one go** | Build the memory fetch *and* the contig clamp + `rid` derivation together; verify end-to-end. | Bit-exact when done, but the failure surface is large: a clamp bug and a fetch bug look alike in an end-to-end diff. | **Higher.** One big step, harder to bisect. |
| **C2. Land the contig clamp FIRST, as its own verified step** — *recommended* | Extend `chain2aln_setup` (or a new `bns_clamp` block) with the contig table + `bns_pos2rid` binary search + `is_rev` flip. Verify it standalone against a capture of real `bns_fetch_seq_v2` inputs/outputs, while the host still supplies the bytes. Then swap the byte source underneath. | Bit-exact, and the risky part is isolated and proven *before* the memory subsystem exists. | **Lower overall.** Two smaller steps; each independently testable. Matches how every prior stage in this project was landed (model → RTL → bit-exact → integrate). |

**Why C2.** The clamp is pure arithmetic over a tiny table — it does not need the memory subsystem
to exist in order to be validated. Landing it first means that when the fetch does arrive, any
end-to-end mismatch is unambiguously a *fetch* bug. It also gives our models and goldens a real
contig table, which they have never had (the synthetic genome has none).

### Decision D — How the fetch latency is hidden

| Option | Description | Speed | Effort/Risk |
|--------|-------------|-------|-------------|
| **D1. Blocking fetch** | Issue the read, stall until the bytes arrive, then extend. | Replaces ~2–4 µs (host) with ~200–400 ns (HBM) — already ~10× better, but still ~8 stalls/read (~2–3 µs/read). Leaves most of the win on the table. | Lowest. A reasonable first milestone. |
| **D2. Prefetch on `rmax`** — *recommended* | `rmax` is known **well before** the bytes are needed. Issue the fetch the instant `chain2aln_setup` produces it and overlap it with the *previous* chain's Smith-Waterman. | Hides most of the latency: extension of a ~282-byte window takes far longer than one memory access, so one chain of lookahead is likely enough. | Moderate — one window of buffering + a small request/reply queue. |
| **D3. Deep multi-chain pipelining** | Keep N fetches in flight across chains (and reads), reordering replies as needed. | Fully converts latency into bandwidth — and bandwidth is 99% idle (§3.2), so there is enormous headroom. Best for the heavy tail (p99 = 122 chains, max = 615). | Highest — needs tag/reorder logic and out-of-order reply handling. |

**Why D2 first.** This is the key structural argument for the whole project: **a host round trip
cannot be pipelined away, but a memory read can.** D2 captures most of that with modest logic; D3
is a later optimisation aimed squarely at the heavy tail, and should be justified by measurement
rather than assumed.

### Decision E — Caching (measure before building)

| Option | Description | Speed | Effort/Risk |
|--------|-------------|-------|-------------|
| **E1. No cache** — *recommended until measured* | Every window is fetched from device memory. | Baseline. Bandwidth is 99% idle, so re-fetching costs little. | None. |
| **E2. Small window cache** | Cache recent windows/DRAM rows on chip. | Only helps if locality exists. Two plausible sources: (a) a read's several chains sometimes cluster near one locus; (b) **mate-rescue looks within the insert size (~300–500 bp) of the read's own location**, so the mate's window plausibly overlaps rows already fetched. | Moderate — and *speculative*. |

**Position.** Do not build E2 on a hunch. The locality hypothesis is **cheap to test from the
capture we already have** (do a read's window addresses cluster? does the mate's window overlap
the read's?). Given bandwidth is 99% idle, the payoff would be latency-side only — and D2/D3
already attack latency more directly. **Measure, then decide.**

**MEASURED (2026-07-17, `make locality` over the 30k-read extension capture — source-a only).**
Merging each read's chain windows into address intervals: **19.0% of fetched bytes are within-read
"cacheable" (union < sum)** — but it is a *tail*, not typical locality. Only **2.4% of multi-chain
reads have any window overlap at all**; the per-read overlap distribution is **p50=0%, p90=0%,
p99=38%**. The 19% is concentrated in ~699 highly-repetitive (multi-mapping) reads whose many chains
pile up at one locus; the typical read's chains map to **distinct loci** (no locality — as chaining
implies). **Verdict on source (a): E2 not justified.** It would add cache complexity to help ~2.4% of
reads on the *byte* side, and bytes/bandwidth is not the constraint (D2 already amortises the latency
side). Source (b) — the mate-rescue window overlapping the read's own window — is untested here (it
needs a mate-rescue window capture, a separate instrumentation) and is the only remaining reason to
revisit E2. **Decision E stands at E1 (no cache).**

### Decision F — How this is verified (bit-exactness)

Unchanged methodology, and the reason every prior stage landed clean:

1. **Capture** real `bns_fetch_seq_v2` inputs/outputs from instrumented BWA-MEM2
   (`rmax0`/`rmax1`/`mid` → clamped `beg`/`end`/`rid` + the returned bytes). This is a **4th
   capture** to add to `remote_capture_plan.md`'s set; it can be armed in the same run.
2. **Model** it in C++ and check bit-exact against the capture.
3. **RTL**, checked bit-exact against the model.
4. **Mutation-test the testbench** — mutate the RTL and confirm the test goes red before trusting
   it green. (See the `bsw_top` precedent: it passed 9 hand-written cases and was later found
   ~19% over-scored on real data. Applied to the join in Step 9 of
   `candidate_extraction_build_log.md`.)

**A note on the test genome.** Our synthetic `g(pos) = pos & 3` has no contigs and no strand
boundary, so it cannot exercise the clamp, the `l_pac` mirror, or the bridging case at all. The
goldens for this work need either a synthetic *multi-contig* genome (cheap, and it can be made to
hit every edge case deliberately) or the real `.0123`/`.pac`. **Recommend both:** synthetic for
directed edge cases, real capture for confidence.

---

## 5. Speed vs accuracy — the summary

- **Accuracy is fixed at bit-exact.** The one genuinely risky piece is the contig clamp (§3.4),
  which is new on-chip behaviour rather than a port of already-validated logic. Decision C2
  isolates and proves it before it can hide inside a bigger integration.
- **Speed is why this exists.** Today's ~8 host round trips per read (~16–32 µs of stall, and up
  to ~2.5 ms for the worst read) would dominate a design whose whole premise is being
  compute-bound. Moving the genome onto the device replaces each ~2–4 µs round trip with a
  ~200–400 ns access, and — unlike a host round trip — that access can be **prefetched and
  pipelined** into near-invisibility (Decision D).
- **The measurement changed the shape of the decision.** Bandwidth is under 1% of HBM, so the
  layout choice (Decision A) is about **capacity and simplicity**, not throughput. That argues for
  starting with the simple byte layout (A1, zero fetch logic, provably the same bytes the software
  reads) and treating the 8×-smaller packed form (A2) as a measured follow-up if HBM capacity
  becomes contended by the future seeding front-end.

**Recommended path:** **C2** (clamp first, standalone, verified) → **A1 + B-i + D1** (simplest
working fetch) → **D2** (prefetch — most of the win) → then, only if measurement justifies them,
**A2** (capacity) and **D3**/**E2** (tail latency).

---

## 6. Risk and revert plan

The risk here is unusually low **by construction**, because B1 was designed with B2 in mind:

- The fetch interface (`ref_req` / `ref_rbeg` / `ref_len` / `ref_in_*`) already exists and is
  already plumbed to the top of the design. **B2 replaces only what sits behind those ports** — no
  other module changes. This was the explicit promise of Decision B1 in
  `chaining_extension_wiring_options.md`, and it holds.
- Consequently the revert is trivial: re-point those ports at the host and the design is exactly
  what is on `main` today at `15e03a1` (chaining → extension → sort → mate-rescue, fully verified,
  full regression green).
- The contig clamp (C2) is additive and independently verified before integration, so it cannot
  silently corrupt the existing path.
- A named checkpoint should be tagged before starting, as was done for the previous integration
  (`pre-accel-wiring-safe`).

---

## 7. One-paragraph summary for a non-specialist

Our DNA-alignment accelerator now does all the heavy work on the chip, and produces exactly the
same answers as the standard software. But it doesn't hold the genome — every time it wants to
score a candidate location it has to ask the host computer for a small slice and wait. Measured on
real data, it asks about **8 times per read** (and, for the worst read we saw, **615 times**). Each
ask costs a couple of microseconds — an eternity in chip terms — and our simulation hides that cost
entirely because the test harness answers instantly. So the speed advantage we've measured would
largely disappear in a real machine. The fix is to put the genome in memory attached to the chip
and let the hardware fetch slices itself: each ask drops from microseconds to nanoseconds, and —
crucially — unlike asking the host, those fetches can be started early and overlapped with other
work, making the wait nearly invisible. Helpfully, the software already stores the genome in a form
that makes the hardware's job almost trivial (a plain lookup at an offset). The one genuinely
delicate part is a boundary rule that stops an alignment sliding off the end of one chromosome into
the next — the software does it, we currently let the host do it, and we can't keep doing that
without the very round trip we're removing. So we propose building and proving that small piece on
its own first, then swapping in the memory underneath it. Correctness is never traded for speed;
where the hardware can't reproduce a rare case exactly, it flags it and the host redoes that one.
