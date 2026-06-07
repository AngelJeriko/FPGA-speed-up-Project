# Speed-Up Plan

Reference document for accelerating the banded SWA kernel. The kernel runs on
FPGA; the rest of BWA-MEM2 runs on the host CPU in C++. End-to-end throughput
depends on:

1. **Per-alignment cycles** in the RTL (how fast we crunch one alignment)
2. **Fmax** (how short the clock period is)
3. **Number of accelerator instances** (how many alignments in parallel)
4. **Host↔FPGA interface** (how efficiently the CPU keeps the FPGA fed)

The optimum is rarely "make the kernel itself faster" — it's almost always
"keep the kernel busier" (replicate + batch). Treat that as the first lever.

---

## Glossary

| Term            | Meaning                                                     |
|-----------------|-------------------------------------------------------------|
| **Fmax**        | Maximum stable clock frequency after place-and-route        |
| **Throughput**  | Alignments per second = `Fmax × instances ÷ cycles_per_alignment` |
| **Latency**     | Cycles between request and result for one alignment         |
| **Critical path** | Longest combinational chain between two registers; sets Fmax |
| **Retiming**    | Synthesis transform that moves registers around a path to balance stage delays |
| **C-slow**      | Time-multiplex K independent streams through one pipeline to allow K-stage retiming inside a feedback loop |
| **OPAE / CCI-P**| Intel's standard host↔FPGA accelerator interface            |
| **AXI-Stream**  | Common streaming interface for DMA between host and FPGA    |

---

## The full menu

Organized by **where the win comes from**, with rough cost / payoff estimates.

### Category 1 — Throughput via parallelism (biggest wins, lowest risk)

#### (A) Replicate `bsw_top` N times
Instantiate the whole accelerator 4–16× (depending on FPGA area), round-robin
alignments across instances with a small arbiter. Linear throughput scaling,
no algorithm changes, **zero accuracy loss**, easy to verify (each instance is
independent). For BWA-MEM2 this is almost always the right first move.

- **Effort:** small (a top-level wrapper + arbiter, ~150 lines)
- **Payoff:** ×N where N = "how many fit on the device"
- **Risk:** very low
- **Limit:** FPGA logic + memory budget

#### (B) Streamline the request handoff (BEING DONE NOW)
Currently `S_DONE → S_IDLE → S_LOAD` requires at least one IDLE cycle between
alignments. With a direct `S_DONE → S_LOAD` path when the host has the next
request ready (`req_valid_i` high during `S_DONE`), we eliminate that cycle.
Lays groundwork for a request FIFO later.

- **Effort:** ~30 lines of FSM change
- **Payoff:** 1–2 cycles per alignment (small but free, compounding with A)
- **Risk:** very low — adds a state transition, doesn't change recurrence

#### (B+) Multi-deep request FIFO (future)
The natural next step after (B): a 2- or 4-deep FIFO of pending requests so the
host can pre-queue work and the FSM never stalls. Required if the host is
issuing alignments faster than the kernel can finish them and round-trip
latency would otherwise dominate.

- **Effort:** moderate (FIFO + back-pressure)
- **Payoff:** eliminates handshake bubbles entirely
- **Defer until:** profiling shows handshake stalls are real

### Category 2 — Host↔FPGA interface (often the *actual* bottleneck)

#### (C) Batch DMA
Single-request handshake is fine for simulation, brutal for PCIe. Gen3 x16
round-trip latency is roughly 500 ns–1 µs. If the C++ side calls the FPGA
*one alignment at a time*, that overhead dominates every other optimization.

Switch to an AXI-Stream / OPAE batch interface: accept 64–512 alignments per
kernel call, write back 64–512 results. PCIe overhead amortizes to near-zero.

- **Effort:** large (depends on host stack — OPAE, DPDK, custom)
- **Payoff:** can be 10× or more vs single-request, depending on how chatty the
  host side is currently
- **Risk:** moderate — most of the work is on the host side, not RTL
- **For BWA-MEM2 specifically:** this is the lever that decides whether the
  FPGA actually beats AVX-512 C++

#### (D) Pack base encoding on the wire
Today the host sends `MAX_QLEN + MAX_TLEN` = 384 bytes per request even when
the actual `qlen` = 150 bp. Two improvements:
- Use the 3-bit packed encoding the C++ side already uses
- Send only `(qlen, tlen)` worth of data with a length prefix

Halves input DMA bandwidth.

- **Effort:** small (~50 lines of input unpacking + host-side packing)
- **Payoff:** halves PCIe bandwidth → larger batches fit in the same DMA budget
- **Risk:** very low

#### (E) Compact result writeback
`bsw_result_t` is 7 fields ≈ 14 bytes packed. With batching, this matters at
scale. Pack tightly, write back N results in one DMA burst.

- **Effort:** small
- **Payoff:** small per-result but compounds with batch size
- **Risk:** very low

### Category 3 — RTL micro-architecture (Fmax improvements)

#### (F) PE recurrence Fmax improvements (BEING DONE NOW)
**Important caveat:** true PE-internal pipelining for big Fmax gains is harder
than it looks. The `E_reg` feedback loop is single-cycle (`E_new` depends on
`H_new`, which depends on `E_reg`), and you can't naively split that across
two register stages without one of:
- C-slow retiming (run two independent alignments alternating through the same
  array — doubles area-efficient throughput but is a major redesign)
- Algorithm change (use the "old H" affine-gap formulation — diverges from
  BWA-MEM2's exact output)

What we **can** do without changing semantics or adding cycle latency:

1. **Restructure the H_new max as a balanced 2-level tree.**
   Current chain: `max(M, E) → max(prev, F) → max(prev, 0)` — three sequential
   comparators.
   Restructured: `(M, E) → maxA` in parallel with `(F, 0) → maxB` then
   `(maxA, maxB) → H_new` — two levels, one comparator dropped from the
   critical path.

2. **Pre-register `oe_del = o_del + e_del` and `oe_ins = o_ins + e_ins`** per
   PE at load time. These are constant during an alignment, so the adder
   doesn't need to be in the per-cycle critical path. Drops one adder.

3. **Drop the redundant `max(H_new, 0)` clamp.** Provable: `E_reg ≥ 0`,
   `f_i ≥ 0`, so the tree's output is always `≥ 0` even if `M_term < 0`.
   One comparator gone.

- **Effort:** small (~30 lines per change in `bsw_pe.sv`)
- **Payoff:** roughly 10–20% Fmax (rough estimate — confirm with Quartus)
- **Risk:** very low — no algorithm change, all 41 tests must still pass

#### (F+) C-slow retiming (future, deferred)
Run two independent alignments through one PE array on alternating cycles.
This adds one register stage inside each PE without breaking the feedback,
which lets retiming push Fmax close to 2×. The array now produces one cell
every cycle but each "cell" belongs to alignment A or B — aggregate throughput
doubles.

- **Effort:** large (control logic, separate per-alignment state, extensive
  verification)
- **Payoff:** ~2× Fmax → ~2× throughput per instance
- **Risk:** higher — needs careful design of per-alignment state
- **Defer until:** baseline Fmax measured + we're sure throughput is the
  binding constraint

#### (G) Pipeline the row-max and global-max reduction trees
`bsw_max_tracker.sv` currently does both reductions in one combinational pass
across all N_PE cells. For `N_PE = 64` that's a wide network that will likely
dominate the critical path once (F) is done. Convert to a balanced 6-level
tree with 1–2 register stages.

- **Effort:** moderate (~80 lines in `bsw_max_tracker.sv`)
- **Payoff:** keeps Fmax up as `N_PE` grows; only matters past `N_PE ≈ 32`
- **Risk:** low — pure RTL refactor with the same answer

#### (H) Move boundary-decay subtract and `eh[]` ladder into registered stages
The `eh[]` initialization ladder in `bsw_ctrl_fsm.sv` is currently one big
combinational ladder. For wide arrays it could become the critical path.
Almost certainly not the bottleneck today — listed for completeness.

### Category 4 — Algorithmic / heuristic

#### (I) Adaptive z-drop threshold
Tighter `zdrop` exits faster at small accuracy cost. Only worth doing if
profiling shows lots of late-tail wasted work *after* the (F) + (G) work
is done.

### Category 5 — CPU side (outside this repo, but determines real speedup)

The C++ host code in BWA-MEM2 currently batches alignments for SIMD. To get
the FPGA's win, you need analogous batching on the host:
- **Queue at least one batch ahead** so the FPGA never sits idle
- **Background the result polling** so CPU work continues during FPGA compute
- **Use multiple FPGA submission queues** if the device supports them

None of this is RTL work, but without it the RTL improvements are wasted.

---

## What we will NOT do, and why

- **Dynamic band narrowing.** Saves software cycles but not FPGA cycles — PEs
  clock either way. Early-exit benefit is already covered by `dead_row` and
  z-drop.
- **Multi-tenant single array** (without C-slow). Doubles utilization in
  theory but the control logic is hairy. You can get most of the benefit by
  just instantiating two arrays (option A). Skip unless area is binding.
- **Lower `SCORE_WIDTH`.** Score paths aren't the critical path. Headroom
  isn't costing anything. Re-doing the proof isn't worth the risk.
- **Aggressive z-drop tuning.** Already implemented as a knob. Tightening it
  trades accuracy for speed but the wins are small for short reads.

---

## Recommended implementation order

1. **Get synthesis numbers first.** Run Quartus on the current RTL → Fmax,
   LUT/ALM count, M20K usage. Without these every other decision is a guess.
   ~30 min of work; do this immediately after picking a board.
2. **(C) batch DMA** — if you don't have this, nothing else matters.
3. **(A) instance replication** — usually 4 instances fit; ×4 throughput.
4. **(F) PE Fmax tweaks** *(BEING DONE NOW)* — multiplies (A)'s win.
5. **(B) request handoff** *(BEING DONE NOW)* — small but compounds.
6. **(G) reduction tree pipelining** — only if (F) reveals it's the new
   critical path.
7. **(D)(E) wire-format packing** — optimization, do last.
8. **(F+) C-slow retiming** — only if maximum per-instance throughput matters
   after (A) is fully populated.

---

## Board recommendations

The right board depends on three things: (1) how serious the project is,
(2) budget, and (3) whether you want a tight CPU+FPGA coupling or a clean
PCIe accelerator model. The Intel/Quartus flow this repo uses works on all
of these.

### For learning + non-trivial scale (recommended for this project)

- **Terasic DE10-Pro (Stratix 10 SX)** — Stratix 10 device with embedded ARM
  HPS, PCIe Gen3 x8, HBM2 memory. Big enough for `N_PE = 64` + 8–16 replicated
  instances. The HPS makes host↔FPGA experimentation easier than a pure PCIe
  card. ~$8k-ish list, often available cheaper on academic programs. *This is
  what I'd pick for the next 6–12 months of this project.*

- **Terasic DE10-Standard (Cyclone V SoC)** — much cheaper (~$300), Cyclone V
  with HPS. Fits `N_PE = 64` but limited room for replication. Good for
  development and proving the design before moving to a bigger device.

### For datacenter / production acceleration

- **Intel D5005 PAC (Stratix 10 GX)** — PCIe Gen3 x16, OPAE software stack,
  the "standard" platform for Intel-flow accelerator papers (including most
  published BWA-MEM2 FPGA work). If the end-state is "FPGA card in a server
  next to bwa-mem2", this is the target. ~$10–15k.

- **Intel Agilex 7 FM dev kit** — Stratix 10's successor. Higher Fmax,
  better DSP density, PCIe Gen4. Newer toolchain but lots of capacity.

### What to avoid for this project

- **Cyclone 10 GX / smaller Arria devices** — too small for `N_PE = 64` plus
  replication. Possible for a *demo* but not for production throughput.
- **Lattice / Xilinx parts** — this repo targets Intel/Quartus; porting to a
  different vendor is a significant time sink for no win.
- **Boards without PCIe** (pure dev kits with only GPIO/HDMI) — fine for
  proving the RTL but can't be used as an accelerator next to BWA-MEM2.

### How to decide

If you don't yet have a board and aren't tied to one, the call is:

| Constraint                  | Pick                                    |
|-----------------------------|-----------------------------------------|
| You're a student / hobby    | DE10-Standard (Cyclone V SoC), ~$300    |
| Serious project, real fund  | DE10-Pro (Stratix 10 SX)                |
| Production / paper / shipping | Intel D5005 PAC (Stratix 10 GX)       |
| Cutting-edge / future-proof | Agilex 7 FM dev kit                     |

For any of these the next concrete steps are the same: run synthesis to get
real Fmax + area numbers, then revisit this plan with data.
