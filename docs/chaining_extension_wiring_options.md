# Wiring the Chaining stage into the Extension pipeline — design options for external review

**Status:** decision record / options analysis. **Date:** 2026-06-20.
**Audience:** external reviewers who are *not* assumed to know this codebase or the
internals of read alignment. Every term is defined in the Glossary (Section 2); on first
use a term is *italicised*.

---

## 1. What this document is for

We are building an **FPGA** (Field-Programmable Gate Array — a reconfigurable hardware chip)
accelerator for **BWA-MEM2**, the most widely used software tool for *read alignment* in DNA
sequencing. Read alignment is the step that takes the short DNA fragments a sequencing machine
produces ("*reads*", typically 100–150 letters of A/C/G/T) and figures out **where each one came
from** in a large *reference genome* (for humans, ~3 billion letters).

BWA-MEM2 runs as a multi-stage pipeline. We have already built and verified several of the later
stages as hardware (described below). This document concerns **one specific connection**: joining
the **Chaining** stage to the **Extension** stage. That join is not a single wire — a small amount
of computation sits between them — and there are several legitimate ways to build it, each with
different consequences for **speed** (how much faster than software) and **accuracy** (whether the
hardware produces *exactly* the same answer as the software).

The goal of the project is a **bit-exact** accelerator: for every input, the hardware must produce
**byte-for-byte the same output** as unmodified BWA-MEM2. This is a hard requirement because
clinical and research users validate against the standard software; "almost the same" is not
acceptable. Every option below is evaluated against that constraint.

---

## 2. Glossary (plain-language definitions)

| Term | Meaning |
|------|---------|
| **Read** | A short DNA fragment from the sequencer, e.g. 150 letters of {A,C,G,T}, encoded as numbers 0–3. |
| **Reference genome** | The known, complete DNA sequence we align reads against (~3 billion letters for human). Stored "*packed*" at 2 bits per letter. |
| **Read alignment / mapping** | Finding where in the reference each read most likely originated. |
| **Seed** | A short exact match between a read and the reference — a starting anchor. Each seed records where it sits in the read (`qbeg`) and in the reference (`rbeg`) and its length (`len`). |
| **Seeding / FM-index** | The first pipeline stage that finds seeds. (Not part of this document; it is the remaining unbuilt front-end.) |
| **Chaining** | Groups seeds that line up consistently (same diagonal) into *chains*, and filters out redundant/weak chains. Two sub-steps: `mem_chain` (form chains) and `mem_chain_flt` (filter chains). **Already built in hardware and validated.** |
| **Chain** | A set of co-linear seeds that together suggest one candidate alignment location. |
| **Extension** | Takes each surviving chain and extends the alignment left and right using a full dynamic-programming alignment, producing a scored *alignment region* (*alnreg*). This is the compute-heavy stage. **Already built in hardware.** |
| **`mem_chain2aln`** | The BWA-MEM2 function that performs Extension. Its *setup* portion — computing the reference window for each chain — is the "glue" this document is about. |
| **`rmax` (reference window bounds)** | For each chain, the start and end positions in the reference (`rmax0`, `rmax1`) that the extension is allowed to look at. Computed from the chain's seeds plus the read length. Defines which slice of the genome must be fetched. |
| **`cal_max_gap`** | A small BWA-MEM2 helper that bounds how far an alignment could drift, used inside the `rmax` calculation. Originally uses floating-point division; we use a proven integer-exact equivalent. |
| **Smith-Waterman / dynamic programming (DP)** | The classic algorithm that finds the best-scoring alignment between two sequences by filling a grid of scores. The expensive inner loop of Extension. |
| **Systolic array** | A hardware structure of many small processing elements working in lockstep; how we compute the Smith-Waterman grid quickly in the FPGA. |
| **`alnreg` (alignment region)** | The output of Extension: a scored candidate alignment with reference start/end, query start/end, score, etc. |
| **`orch_read_top`** | Our hardware module implementing the per-read Extension orchestration (drive every chain through extension, collect results, purge redundant ones). |
| **`accel_top`** | A larger hardware module = `orch_read_top` **plus** compaction **plus** a merge-sorter, i.e. the full "extend pipeline" that outputs a sorted, de-duplicated alnreg list. |
| **Compaction / merge-sorter** | Post-extension cleanup: drop empty results, then sort and remove duplicate/overlapping alnregs. Already built and verified. |
| **Bit-exact** | The hardware output is identical, byte-for-byte, to the reference software. Our universal correctness bar. |
| **SW-fallback (software fallback)** | A safety valve: for rare inputs the hardware cannot reproduce exactly, the hardware *flags* the input and the host CPU redoes just that one in software. Keeps the system bit-exact at the cost of a small amount of CPU work. |
| **Host** | The CPU/server that drives the FPGA, feeds it data, and handles any fallbacks. |
| **`l_pac`** | The packed length of the reference. Used only at the very edges of the genome (first/last bases, or the forward/reverse-strand boundary). |
| **Forward/reverse strand** | DNA is double-stranded; a read can match either strand. BWA-MEM2 stores the reference twice (forward then reverse-complement); `l_pac` is the boundary between them. |
| **Throughput / latency** | Throughput = reads processed per second. Latency = time for one read. For sequencing we care mostly about throughput. |
| **Roofline** | The theoretical maximum speedup a given approach can reach, regardless of implementation effort. |

---

## 3. The specific decision: how to connect Chaining to Extension

The Chaining hardware produces, per read, a list of surviving **chains** (each a small set of
seeds). The Extension hardware (`orch_read_top` / `accel_top`) needs, per chain:

1. the chain's **seeds** — produced by Chaining ✅
2. the chain's **`rmax` window bounds** — *must be computed* (the "glue")
3. the **reference bytes** for that window — must be *fetched* from the genome
4. the **read's query sequence** — available at the read level ✅

Items (2) and (3) are why this is not a direct wire. We have **already built and validated the
glue for (2)**: a hardware module `chain2aln_setup` that computes `rmax` exactly. It was checked
against **241,018 real chains from real sequencing data with zero mismatches**, and the hardware
matches its software model on 4,000 synthetic cases including the rare genome-edge cases.

Item (3), the reference fetch, is a larger subsystem and is the main axis of choice below.

---

## 4. The options

Each option is rated on **Accuracy** (does it stay bit-exact?) and **Speed** (effect on
throughput), plus **Effort/Risk**. Note: *every* option preserves bit-exactness — that is
non-negotiable — so the Accuracy column describes *how* correctness is maintained, not whether.

### Decision A — Where the Extension wiring connects

| Option | Description | Accuracy | Speed | Effort/Risk |
|--------|-------------|----------|-------|-------------|
| **A1. Wire to `orch_read_top`** (extension core only) | Chaining → `rmax` glue → Extension → alignment regions. The later compaction + sorting stays a separate already-built block, added afterwards. | Bit-exact. | Slightly less work done on-chip per read; the host (or a later stage) still triggers sorting. | Lower — lighter hardware and a lighter test harness. Faster to a working result. |
| **A2. Wire to `accel_top`** (full extend pipeline) — **chosen** | Chaining → `rmax` glue → Extension → compaction → merge-sorter → sorted, de-duplicated regions out. | Bit-exact. | More of the pipeline runs on-chip in one pass → fewer hand-offs to the host → **higher throughput**. | Higher — a bigger module and a much heavier simulation (it instantiates the whole extension engine, the Smith-Waterman array, and the sorter). |

**Why A2 was chosen:** it delivers the complete "accel extend pipeline" — a read's chains go in,
fully sorted alignment regions come out — which is the more useful integration boundary for the
eventual full mapper. The cost is build/debug complexity, mitigated by the revert plan (Section 6).

### Decision B — How the per-chain reference window is fetched

| Option | Description | Accuracy | Speed | Effort/Risk |
|--------|-------------|----------|-------|-------------|
| **B1. Deferred fetch (external/host-supplied)** — **chosen for now** | The hardware computes `rmax` and *requests* the reference window; the surrounding system (host, or a future memory block) supplies the bytes. The Extension hardware already accepts reference bytes as an input by design. | Bit-exact. | Adds a hand-off per chain to obtain reference bytes — a real but bounded overhead; acceptable while the genome-memory block does not yet exist. | Low — no new subsystem; lets us complete the wiring now. |
| **B2. On-chip genome-memory subsystem** | Build dedicated hardware that holds the packed reference in fast memory and fetches/orients each window itself (including the reverse-strand handling). | Bit-exact (must reproduce BWA's fetch + reverse-complement exactly). | **Largest speed win** — removes the per-chain host round-trip entirely; the pipeline becomes self-contained from chains onward. | High — a whole new memory subsystem; needs the packed reference loaded into the device and careful strand handling. A separate future project. |

**Why B1 for now:** B2 is a large independent effort. B1 lets us finish and validate the wiring
immediately, and B2 can replace the external fetch later **without changing any other module**
(the interface stays the same). This was the explicit reviewer choice.

### Decision C — The Smith-Waterman computation style (already settled, noted for completeness)

| Option | Description | Accuracy | Speed |
|--------|-------------|----------|-------|
| **C1. Band-doubling** (software's adaptive approach) | Re-runs alignment with a widening "band" until stable. | Bit-exact. | Variable per read. |
| **C2. Full-rectangle DP** — **in use** | Computes the entire alignment grid once with no banding. | **Proven bit-exact** to C1 over all captured data — band-doubling is a no-op here. | Predictable, regular hardware; more cells computed but in fixed-latency lockstep. |

This is already decided in the existing Extension hardware; the wiring does not revisit it.

### Decision D — `cal_max_gap` division (inside the `rmax` glue)

| Option | Description | Accuracy | Speed/Area |
|--------|-------------|----------|------------|
| **D1. Runtime hardware divider** — **in use** | Two integer divisions per seed, by the read's gap-penalty parameters. | Integer-exact (proven equal to BWA's floating-point version over all captured data). | A hardware divider is relatively costly; fine for simulation, and `rmax` is not the throughput bottleneck. |
| **D2. Reciprocal-multiply** | The divisors are constant for a whole read, so compute each reciprocal once and multiply. | Must be proven bit-exact to D1 (a finite, checkable claim). | Cheaper/faster hardware. A possible later optimisation if `rmax` ever matters for timing. |

### Decision E — Software-fallback budget (how rare cases are handled)

Throughout the accelerator, a handful of rare inputs are punted to the host to keep everything
bit-exact (see Glossary: *SW-fallback*). Their measured real-data rates:

| Fallback case | Stage | Real-data rate | Speed impact |
|---------------|-------|----------------|--------------|
| Duplicate-position chains | Chaining | **3.9%** of reads | Small; the host redoes ~1 read in 25. |
| Combsort depth-limit | Chaining (sort) | **0.0%** (never observed in 30,000 reads) | None. |
| Sorter tie / oversize | Extension sorter | Rare | Small. |

These rates are **measured on real sequencing data**, not estimated. The combined cost is low, and
each fallback trades a tiny amount of host CPU for guaranteed exactness. **No change is proposed** —
this row exists so reviewers can see the accuracy mechanism and its modest speed cost.

---

## 5. Speed vs accuracy — the summary

- **Accuracy is fixed at "bit-exact" for every option.** We never trade accuracy for speed; instead,
  rare hard-to-reproduce inputs are detected and redone in software (the *SW-fallback* mechanism),
  which preserves exactness at a small, *measured* CPU cost (~4% of reads, dominated by chaining
  duplicate-position cases).
- **Speed is the axis we are choosing on.** The biggest lever is **Decision B** (the reference
  fetch): an on-chip genome memory (B2) would give the largest throughput gain by eliminating
  per-chain host hand-offs, but is a large separate build. For now we take the deferred fetch (B1)
  and the fuller on-chip pipeline (A2), which already moves Chaining → Extension → sort on-chip in
  one pass.
- **The chosen path (A2 + B1)** maximises how much runs on-chip *today* without committing to the
  genome-memory subsystem, and leaves a clean upgrade path to B2 later with no rework elsewhere.

---

## 6. Risk and revert plan

The `accel_top` wiring (A2) is the highest-complexity integration so far: it composes the chaining
engine, the `rmax` glue, the full extension engine, the Smith-Waterman systolic array, and the
sorter into one design, verified end-to-end against the software model on synthetic data with a
synthetic genome.

To bound the risk, a **named safe checkpoint** was created **before** starting this integration:

- Git tag **`pre-accel-wiring-safe`** (pushed to the remote) marks the last fully-validated state:
  the complete, real-data-validated Chaining stage plus the validated `chain2aln_setup` glue.
- The integration work happens on a separate branch (**`accel-wiring`**), isolated from the
  validated `main` line.
- If the integration proves unviable or too costly to debug, we revert simply by returning to
  `main` / the tag; **nothing already validated is lost.**

---

## 7. One-paragraph summary for a non-specialist

We are connecting two finished hardware stages of a DNA read-aligner: the stage that groups
matches into candidate locations ("Chaining") and the stage that scores each location in detail
("Extension"). They don't connect with a single wire because each candidate needs a slice of the
reference genome computed and fetched first. We have already built and **proven correct against
240,000+ real cases** the part that computes which slice is needed. We are now building the full
connection into the complete extension-and-sort pipeline. Every design choice keeps the hardware
output **identical to the standard software**; where that is impossible for rare inputs, the
hardware flags them and the host computer redoes those few (~4%, measured) — so correctness is
never compromised, only a small amount of speed. The main remaining speed opportunity — putting the
genome itself on-chip — is deliberately left as a clean, separate future upgrade.
