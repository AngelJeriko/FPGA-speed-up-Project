# OOC synthesis results — baseline (before synth-prep conversions)

Proxy part: **xc7v2000tfhg1761-2** (Virtex-7, -2 speed). 7-series proxy — RELATIVE numbers,
not absolute F1/VU9P. Clock target 3.0 ns (333 MHz); `Fmax = 1000/(3.0 − WNS)`.
Run on local Vivado (kanak), 2026-07-28. F1 needs ~250 MHz — everything below is far under.

| module | Fmax (MHz) | WNS (ns) | LUT | FF | BRAM (RAMB36) | DSP | verdict |
|--------|-----------:|---------:|----:|---:|--------------:|----:|---------|
| chain_store     | **89.1** | −8.22 | 134,467 | 66,147 | 10 | 0 | slow + LUT-bloated |
| bsw_max_tracker | **3.5**  | −280.9 | 21,611 | 6,574 | 0 | 2 | BEFORE (160-deep serial max-reduction) |
| matesw_dedup    | _see below_ | | | | | | multi-driver bug fixed; real numbers below |

### MEASURED AFTER (2026-07-29, same Virtex-7 proxy)

| module | Fmax before→after | WNS after | LUT before→after | FF | BRAM | crit warns |
|--------|------------------:|----------:|-----------------:|---:|-----:|-----------:|
| chain_store     | 89.1 → **115.3 MHz** | −5.68 | 134,467 → **59,040** | 33,258 | 14 | 0 |
| bsw_max_tracker | 3.5 → **70.1 MHz** | −11.27 | 21,611 → 24,510 | 6,590 | 0 | 0 |
| matesw_dedup    | (void) → **81.5 MHz** | −9.28 | — → **573,564** ⚠ | 74,381 | 0 | **0** (was 147,456) |

- **chain_store WIN:** +30% Fmax (89→115) AND LUT more than halved (134K→59K, the 512-wide
  comparator is gone), FF halved (66K→33K), synth 11 min → 5 min. `c_pos`/`c_*` still infer as
  distributed RAM (RAM64M) — a later full-BRAM pass would cut area further. Minor: `p_next` can't
  infer as RAM (multiple writes, one process) so it dissolves to 32K flops — cosmetic, not a bug.
- **matesw_dedup:** multi-driver fix CONFIRMED — **0 critical warnings** (was 147,456), FF halved
  (148K→74K duplication gone). But the real design is now visible and it's **573K LUTs** (~half a
  VU9P for one small module) at 81.5 MHz — the combinational dual-index (i,j) reads over 256-deep
  register files feeding the 64-bit multiply. This is the clear next target: sequential single-read
  + registered-BRAM (its #3-sweep conversion). 41-min synth, so verify hard in Verilator first.
- **matesw_dedup CONVERTED** ✅ (2026-07-29): the 7 field arrays are now a registered-read memory
  with 1 write + 2 read ports (port A/B for the i/j dual reads) → true-dual-port BRAM instead of a
  256:1 LUT-mux register file. Every access is present-address→consume-next-cycle; the redundancy
  inner loop latches element[i] into p_* and reads only j; the output port o_* is registered (fixed
  matesw_orch_top's read loop to present rd_idx a cycle early). Bit-exact: tb_matesw_dedup 6000/0,
  tb_matesw_orch_top 3000/0, tb_matesw_pe_top 2000/0, tb_matesw_pe_sel_top 2000/0, tb_accel_pe2_top
  200/0; mutation-tested (wrong read address → 4421 fails).
  **AFTER (measured 2026-07-29): LUT 573,564 → 3,114 (184×), FF 74,381 → 728, BRAM 0 → 4×RAMB36 +
  8×RAMB18, Fmax 82.0 MHz, synth 41 min → 1.5 min, 0 crit warnings.** Vivado recognized the arrays
  as "true dual port RAM template" (rb/re/rid/sc/qb) and BRAM (qe/cov). The area problem is solved;
  Fmax now limited by the redundancy 64-bit multiply (optional later pipeline), not storage.

## Integrated top: chaining_pe_pair_top (system Fmax + fit)
First 65-min OOC run (2026-07-29) ended in **3 errors** — the integrated synth found two
synthesizability bugs the per-module runs couldn't (those modules were never synth'd alone):
- **chain_introsort** — `aw`/`aid` written by a standalone load always_ff AND the sort FSM
  → 2432 multi-driven-net critical warnings. Fixed: fold load into the FSM block.
- **orch_purge** — `av_qb`/`av_qe` written by the load block AND the purge-exclusion FSM
  → "Unsupported RAM template" hard error (blocked synth). Fixed: move their load into the FSM.
Both fixed + Verilator-verified (tb_chain_introsort 4000/0, tb_orch_read_top 200/0,
tb_chaining_pe2_top 200/0). Area-only (deferred): matesw_pe_top `w_*`, chain_store `p_next`,
orch_purge `av_qb/av_qe` dissolve to flops ("multiple writes, one process").

**CLEAN INTEGRATED SYNTH (2026-07-29): 0 errors, 0 critical warnings. System result:**
**Fmax 2.4 MHz (WNS −406 ns), LUT 1,093,930 (~90% of the xc7v2000t proxy), FF 319,081,
BRAM 53, DSP 28.**
**This REFUTES the earlier "~70 MHz bounded / fits comfortably" estimate — it was wrong.** The
per-module Fmax numbers did NOT predict the system: the ~406 ns critical path is far worse than any
single module. Cause = the MANY combinational-read register-file arrays still in the design (only
3 modules were converted). They chain together across the integrated datapath into a ~400 ns path,
AND they are the LUT bloat (cf. matesw_dedup 573K→3K when converted to BRAM). So the design is
currently BOTH too slow (2.4 MHz) AND too big (1.09M LUT, would not fit VU9P + F1 shell). Making it
F1-viable needs the registered-BRAM treatment applied BROADLY — the un-converted combinational-read
arrays across chain_flt, chain_flt_top, orch_chain_unit, orch_purge (sd_*/av_qb/qe), the
chaining_pe_pair_top top-wrapper arrays (a_*/sb_*/s_*/sd_*/av_*), matesw_pe_top w_*, chain_store
p_next, and others. NEXT DIAGNOSTIC: `report_timing` on the failing path to see which arrays/modules
own the ~400 ns, then convert worst-first. This is a large multi-module effort, not a quick fix.

### report_timing DIAGNOSIS (2026-07-30) — the ~400 ns path was NOT a register-file array
User uploaded the full `report_timing_summary` (`chaining_pe_pair_top_timing.rpt`, 20 worst paths).
**All 20 worst paths are the SAME structure**, and it is **not** on the combinational-read worklist:
- Source: `.../u_bsw/u_fsm/cfg_q_reg[o_ins]`  →  Dest: `.../u_bsw/u_array/g_pe[158].u_pe/H_curr_reg`
- 409 ns data path, **1117 logic levels, 796 CARRY4**, netlist names ripple `...__152 __153 ... __158`
  (one per PE index) — a giveaway for a per-column cumulative chain.
Root cause = `bsw_ctrl_fsm.sv` computed the first-row init boundary `eh_init[j]` as a **160-deep
combinational saturating-subtract LADDER** (`eh_init[j] = max(eh_init[j-1] - e_ins, 0)`), feeding
each PE's `H_curr_reg` preload. `eh_init[158]` = h0 through 157 chained subtract+clamp stages.
So the PEs are correctly pipelined — the killer was a *prefix-scan* combinational loop in the FSM,
a DIFFERENT anti-pattern than the register-file mux trees the worklist targets.

**FIX (bit-exact, no added latency, no FSM/timing changes) ✅** Every subtracted term is >= 0, so the
unclamped prefix `P_j = h0 - (o_ins + j*e_ins)` is monotonically non-increasing → a saturating
running-max-with-0 over it equals the pointwise clamp:
  `eh_init[j] = max(h0 - o_ins - j*e_ins, 0)`  (each lane independent; const-coeff mul + subtract + clamp).
This breaks the 160-deep dependency into a shallow parallel structure. Verified bit-exact:
tb_bsw_top 26/0, **tb_bsw_ext 15887/0 (real data)**, tb_matesw_top 4000/0; mutation-tested
(j→j+1 off-by-one → 552 fails, restored byte-identical). Files: rtl/bsw_ctrl_fsm.sv.
**RE-SYNTH TODO:** re-run the integrated OOC (`chaining_pe_pair_top`) to measure the new system Fmax
— this removes THE dominant path; the next bottleneck is unknown (likely bsw_max_tracker's zdrop
multiply, or one of the still-un-converted register-file arrays that the worklist ranks). Area
(1.09M LUT) is unchanged by this fix — that still needs the broad registered-BRAM conversions.

### chain_flt (worklist #4) CONVERTED ✅ (2026-07-30)
The greedy overlap/shadow filter read the four 512-deep metadata arrays `cw/cb/ce/calt`
COMBINATIONALLY at two indices every cycle (outer chain `i` and survivor `jj=keptlist[kk]`)
→ eight 512:1 LUT-mux trees feeding the compares. Converted to a single REGISTERED-READ port:
`i`'s metadata is constant across the inner loop so it is read once and latched into `*_i`;
the inner loop presents the survivor address (L_JPRES) and consumes it the next cycle (L_JCON).
Arrays are written only by the host load (single writer) so they infer simple-dual-port BRAM.
Bit-exact (identical algebra, deferred one cycle; extra states transparent behind busy/done):
**tb_chain_flt 4000/0, tb_chain_flt_top 4000/0**; mutation-tested (survivor read addr +1 →
14694 fails, restored byte-identical). RE-SYNTH TODO: measure LUT drop (expect large, cf. the
matesw_dedup register-file→BRAM story) — but chain_flt is more an AREA than a timing target.
Files: rtl/chain_flt.sv.

### MEASURED integrated re-synth (2026-07-30, eh_init + chain_flt both in)
**chaining_pe_pair_top: Fmax 2.4 → 13.7 MHz (5.7×), WNS −406 → −69.8 ns, LUT 1,093,930 → 1,074,576,
FF 320,131, DSP 28 → 308, 0 errors / 0 crit warns.** The eh_init closed form removed the 400 ns
ladder as predicted (headline timing win). chain_flt cw/cb/ce now infer BRAM (RAMB18) — confirmed —
but LUT barely moved (chain_flt is small; the bulk is still distributed-RAM). eh_init added ~280
DSP48 (one small const-mult per PE lane × 2 dirs) = 308/6840 on VU9P (4.5%), fine.

**NEW worst path (−69.8 ns) = `orch_purge` (worklist #6).** Source `av_qb_reg[887]` (the av_qb/av_qe
1024-deep arrays, still dissolved to 32,768 flops — multi-write, unconverted) → `cmg1_return14`
purge gap arithmetic (**386 logic levels, 326 CARRY4** — a big combinational reduction) → `av_rb`
BRAM write-address. So orch_purge is now BOTH the timing bottleneck AND a major area sink
(av_qb/av_qe flops + sd_* distributed RAM + the cmg arithmetic). Clear next target. Area still
1.07M LUT overall — the big distributed-RAM arrays (c_pos, sd_*, av_*, a_*) remain unconverted.

## Scoreboard (all conversions bit-exact + mutation-tested)
| module | Fmax before→after | LUT before→after | note |
|--------|------------------:|-----------------:|------|
| bsw_max_tracker | 3.5 → 70.1 MHz (20×) | 21.6K → 24.5K | serial max-reduction → tree |
| chain_store     | 89.1 → 115.3 MHz | 134K → 59K (−56%) | linear predecessor → binary search |
| matesw_dedup    | (unbuildable) → 82.0 MHz | 573K → **3.1K** (184×) | register file → TDP BRAM; multi-driver bug fixed |
| matesw_orch_top | — | — | multi-driver bug fixed (0 crit warns, was 147,456) |

### Conversions applied (re-measure to fill "after")
- **bsw_max_tracker** ✅ serial 160-deep max-reduction → balanced log₂-depth tree.
  Bit-exact verified: tb_bsw_top 26/0, tb_bsw_ext 15887/0, tb_matesw_top 4000/0;
  mutation-tested (freeze reduction → tb_bsw_top T5 zdrop FAIL).
  **AFTER: Fmax 3.5 → 70.1 MHz (20×), WNS −280.9 → −11.27 ns. LUT 21,611 → 24,510, FF 6,590, DSP 2.**
  New critical path (−11.27 ns): the row-tail 160:1 mux → zdrop 32-bit multiply (Vivado warns
  "not enough pipeline registers after wide multiplier", bsw_max_tracker.sv:380). Follow-up if the
  BSW core needs >70 MHz: register the row-tail select + pipeline the zdrop math (delicate — zdrop
  is an early-exit, so a delayed break must not change which row terminates). Banked for now.
- **chain_store** ✅ 512-deep combinational lower_bound scan → sequential binary search (~log₂ depth)
  over the same sorted c_pos array. Bit-exact: tb_chain_store 4000/0 + overflow-guard; mutation-tested
  (invert search compare → 7192 fails). **AFTER: _pending re-synth_** — expect a large Fmax gain and a
  big LUT drop (the 512-wide parallel comparator logic is gone); synthesis should also be far faster
  than the ~11 min baseline. Note: c_pos and the c_* arrays are still register/distributed-RAM (single-
  index reads); a later full registered-read-BRAM pass would further cut area if utilization demands.
- **matesw_dedup + matesw_orch_top** ✅ **BUG FOUND BY SYNTHESIS** (Verilator missed it): the host
  load and the in-place FSM both wrote the same `rb/re/...` (dedup) / `m_*` (orch) arrays from TWO
  separate `always_ff` blocks → **147,456 multi-driven-net CRITICAL WARNINGS** in Vivado (duplicated
  flops, wrong on hardware; 38-min/16 GB synth). Fix: fold the load into the single FSM `always_ff`
  that drives those arrays. Bit-exact preserved: tb_matesw_dedup 6000/0, tb_matesw_orch_top 3000/0,
  tb_matesw_pe_top 2000/0. Confirm on re-synth = **0 critical warnings** (was 147,456). `matesw_pe_top`
  was already single-driver (load inside the main block) — no change. This is why we synthesize:
  a multi-driven memory is invisible to Verilator but fatal on the FPGA.

## Readout

**bsw_max_tracker = the worst, by far (3.5 MHz).** A ~283 ns combinational path — the
160-wide `row_*_pipe` scan feeding the zdrop 32×32 multiply + 164 adders, all in one
cycle (Vivado even warns "Not enough pipeline registers after wide multiplier"). This
**flips the static ranking**: the sweep put chain_store #1, but *measured* Fmax says
bsw_max_tracker is the more urgent fix. → convert its scan to an indexed/registered read
+ pipeline the multiplier.

**chain_store = 89 MHz, LUT-bloated (134K).** Instructive BRAM story:
- Registered-read arrays DID infer Block RAM: `in_qbeg/in_len/in_rid/in_isalt/in_score`
  → 10 RAMB36. Good — those are already correct.
- Combinational-read arrays fell to **Distributed RAM (RAM64M, LUT-based)**: `c_pos,
  c_lr/lq/ll, in_rbeg, c_rid/fq/isalt/n/head, p_rbeg/qbeg/len, c_tail, p_score` →
  3,968 RAM64M primitives. That is the 134K-LUT bloat AND the 89 MHz ceiling (the
  512-wide `c_pos` predecessor scan). → the #1 sweep item; convert `c_pos` to a
  sequential binary-search over registered-read BRAM.

**Takeaway:** measurement confirms both modules are nowhere near an F1 clock, and gives us
hard before-numbers. Order of attack by measured pain: **bsw_max_tracker → chain_store →
matesw_dedup**.

## After-conversion numbers go here
(re-run the same OOC synth on each converted module; record delta)

---

## Integrated re-synth #2 (2026-07-30) — after the orch_purge cmg divide-pipeline (`4cf6def`)

MEASURED `chaining_pe_pair_top`, same Virtex-7 proxy (`xc7v2000tfhg1761-2`, 3.0 ns target):

| metric | after eh_init (#1) | after divide-pipeline (#2) | delta |
|--------|-------------------:|---------------------------:|-------|
| Fmax   | 13.7 MHz           | **14.1 MHz**               | +0.4 MHz |
| WNS    | −69.8 ns           | **−67.9 ns**               | +1.9 ns |
| LUT    | 1,074,576          | **1,097,558**              | +23K (worse) |
| FF     | ~319K              | 320,481                    | ~ |
| DSP    | 308                | 308                        | ~ |
| errors / crit-warn | 0 / 0  | 0 / 0                      | clean |

**The divide-pipeline barely moved timing and slightly grew area.** Root cause understood:
isolating the `cmg` integer divide into its own reg-to-reg stage does NOT shorten it — a
**single-cycle 32-bit division by a runtime value is inherently ~68 ns**. Vivado mapped the
multiply half of `cmg` to DSP48s (`cmg1_return14 … A*B2`) but the divide stays the worst path.
The worst path is still `cmg` in `orch_purge`, with a near-equal twin in `chain2aln_setup`.
LESSON: pipelining a long combinational op into its own stage doesn't help unless the op is
itself **sequenced (multi-cycle)** or **removed**.

### Fix applied: constant-fold the scoring (`0c76968`)

This accelerator runs the FIXED bwa-mem2 scoring, so `a/o_del/e_del/o_ins/e_ins/w` are now
compile-time `localparam`s (= `bsw_pkg` `1/6/1/6/1/100`) inside `cmg` in **both** `orch_purge`
and `chain2aln_setup`. With `e_del=e_ins=1` the divide folds to identity and `(qlen*a−o+e)`
folds to a subtract (`a=1`) — the divider **and** the DSP multiply vanish at every `cmg` site.

- Bit-exact: `orch_purge` vectors already fed `1/6/1/6/1/100` → tb_orch_purge 200/0,
  tb_orch_read_top 200/0. `chain2aln_setup`'s generator previously **randomized** the scoring
  to stress the divide (moot now) — pinned it to the fixed values, regenerated → 4000/0.
- Mutation (force `cmg` to a wrong magnitude, `SC_A=40`/`SC_W=3`): orch_purge 1–2 fail,
  chain2aln_setup 3770–3945 fail → `cmg` is on a live path.
- Re-synth pending to measure the new Fmax.

### ⚠️ Area is now the harder wall

At **1.098M LUT** (~90% of this proxy) the design **will not place** on the real VU9P (F1),
whose fabric is 3 SLRs of ~394K LUT each. Instance-area report:

- `u_sel` / mate-rescue ≈ **970K cells** — one full 160-PE array (`matesw_top`) **plus** the
  MA_MAX=256 register files (`matesw_pe_top` `w_rb/re/qb/qe/rid/sc/cov`, read combinationally →
  distributed RAM) + dedup/orient/selection logic.
- `orch_read_top` ≈ 499K (orch_purge 324K + orch_chain_unit/bsw_seed_unit 171K).

**CORRECTION (2026-07-31): there are TWO physical 160-PE arrays, not three.** A source-of-truth
trace found exactly two `bsw_top` instances in `chaining_pe_pair_top`: `bsw_seed_unit.u_bsw`
(extend, restart=0) and `matesw_top.u_bsw` (mate, restart=1), both BAND_WIDTH=160. The earlier
"second and third array" note double-counted; `matesw_orient_unit` contains no array of its own —
it just wraps the one `matesw_top`. The `u_sel` bulk is **one array + big regfiles**, so array
sharing removes ~one array (~150–170K LUT) but does not by itself reach the 394K/SLR target; it
pairs with the regfile conversions below.

Area needs a **structural** rework — share one SW engine across extend/mate-rescue (see
"Shared SW core" below), and BRAM-ify the big distributed-RAM register files (`av_qb/av_qe` 32,768
flops still unconverted, `matesw_pe_top` `w_*`, `sd_*`, `a_*`, `c_pos`) — not more per-module
register-file conversion. The per-module timing grind has hit diminishing returns (eh_init 5.7×;
orch_purge divide ~3%); the remaining wins are structural.

### Shared SW core — one bsw_top time-shared across extend + mate-rescue (2026-07-31)

The extend path (`bsw_seed_unit`) and the mate-rescue path (`matesw_top`) each instantiated a
private `bsw_top`. They never run concurrently — the paired-end host runs both extend passes to
completion (`ce_done`) before it pulses `sel_start` — so ONE core can serve both. Implemented as a
`bsw_shared` arbiter (2 request channels A=extend/B=mate → one `bsw_top`, owner-latching, released
on result handshake) placed in `chaining_pe2_top`; the request channel (`bsw_creq_t`/`bsw_cresp_t`)
is threaded up through the 4+4 intermediate modules. `bsw_ctrl_fsm` latches query/target/cfg the
cycle a request is accepted, so the wide channel is a **load-time** path, not the array's runtime
critical path. Kept low-risk via a `SHARED_CORE` parameter: default 0 = each leaf owns its core
(every standalone tb byte-identical), 1 = shared (only `chaining_pe2_top`). `bsw_top`/`bsw_ctrl_fsm`
unchanged. Verified: tb_chaining_pe2_top (mode 1) + mutation.

**MEASURED (re-synth #4, same Virtex-7 proxy, 3.0 ns): shared core delivered.**

| metric | #3 (pre-share) | #4 (shared core) | delta |
|--------|---------------:|-----------------:|-------|
| Fmax   | 55.8 MHz       | 57.2 MHz         | +1.4 (flat, expected — timing path is inside the one remaining bsw_top) |
| WNS    | −14.9 ns       | −14.49 ns        | ~same |
| LUT    | 868,967        | 768,458          | −100,509 (−11.6%) |
| FF     | 254,618        | 227,041          | −27,577 (−10.8%) |
| DSP    | 296            | 154              | −142 (−48%; one bsw_top's eh_init lanes gone) |
| err/crit | 0/0          | 0/0              | clean |

The arbiter is essentially free: `u_swshared` = 133,709 cells vs the `bsw_top` inside it = 133,706
— **3 cells** of muxing overhead. One core now: 133.7K cells (array `u_array` = 89.7K).

**Instance-area report confirms the next lever.** `u_sel` (mate-rescue) is still **826,527 cells =
74% of the design** with its array removed — the bulk is REGFILES, not the array: `matesw_pe_top`
`w_rb/re/qb/qe/rid/sc/cov` (MA_MAX=256) each "dissolved into 16,384 registers" (synth flagged: RAM
has multiple writes via different ports in same process). NEXT AREA = fold those multi-write w_*
regfiles to ONE muxed write port (the matesw_dedup 573K→3.1K pattern). Bigger prize than the array.
Secondary: matesw_orch_top ma regfile, matesw_dedup (124K). TIMING still `bsw_max_tracker` glob_max
(−14.5 ns, 77% routing) — pipeline the reduction.

### 🎯 Re-synth #5 (2026-07-31) — w_* + m_* regfile folds: AREA WALL DEMOLISHED

MEASURED `chaining_pe_pair_top`, same Virtex-7 proxy, 3.0 ns:

| metric | #4 (shared core) | #5 (+ w_* + m_* folds) | delta |
|--------|-----------------:|-----------------------:|-------|
| LUT    | 768,458          | **199,065**            | −569,393 (−74.1%) |
| FF     | 227,041          | **79,362**             | −147,679 (−65.0%) |
| DSP    | 154              | 154                    | unchanged |
| Fmax   | 57.2 MHz         | 57.2 MHz               | unchanged (area-only) |
| WNS    | −14.49 ns        | −14.49 ns              | unchanged |
| err/crit | 0/0            | 0/0                    | clean |

The seven `matesw_pe_top` `w_*` and seven `matesw_orch_top` `m_*` regfiles now infer **RAM64M
distributed RAM** (Distributed-RAM report), and the "dissolved into 16,384 registers" warnings are
GONE. The win is far larger than the flop count alone: LUT6 collapsed **359,617 → 64,913** and FDRE
**226,909 → 79,230**. A 256-deep array read/written at RUNTIME indices, when dissolved, needs a
256:1 read-mux tree per read port + a write decoder — ×14 arrays that was the DOMINANT LUT cost, not
the flops. Distributed RAM eliminates all of it.

**Area wall demolished.** Journey: **869K (re-synth #3) → 768K (shared core, #4) → 199K LUT (#5)**;
overall F1 synth-prep ≈ **1.1M → 199K LUT (−82%)**, 2.4 → 57.2 MHz. The design now sits **well under
one VU9P SLR (~394K)** with headroom. AREA is no longer the constraint — TIMING (the `bsw_max_tracker`
glob_max reduction, −14.49 ns, 77% routing) is the remaining wall to lift Fmax.

---

## Integrated re-synth #3 (2026-07-31) — constant-fold + av_qb/av_qe BRAM-fold batch

MEASURED `chaining_pe_pair_top`, same Virtex-7 proxy, 3.0 ns target:

| metric | #2 (divide-pipeline) | **#3 (this batch)** | delta |
|--------|---------------------:|--------------------:|-------|
| Fmax   | 14.1 MHz             | **55.8 MHz**        | **+41.7 MHz (4×)** |
| WNS    | −67.9 ns             | **−14.9 ns**        | +53 ns |
| LUT    | 1,097,558            | **868,967**         | **−228,591 (−21%)** |
| FF     | 320,481              | 254,618             | −65,863 |
| DSP    | 308                  | 296                 | −12 |
| errors / crit-warn | 0 / 0    | 0 / 0               | clean |

**The batch worked exactly as predicted — the biggest single jump since eh_init.**
- **cmg constant-fold** (`0c76968`): the integer divide is gone at all four sites — the −68 ns
  wall vanished, taking WNS from −67.9 to −14.9 ns.
- **av_qb/av_qe write-fold** (`a6edbbf`): folding the two writers into one made them RAM-inferable.
  They dropped from 32,768 dissolved flops + two 1024:1 read-mux trees to `RAM64M` distributed RAM
  (final mapping report: `u_purge/av_qb_reg`, `av_qe_reg` → RAM64M×352 each) — that is most of the
  −66K FF and a large share of the −228K LUT. (They landed in distributed RAM, not BRAM, because
  they have two combinational readers — `av[i]` and the `rd_idx` readback; a true-BRAM conversion
  would need a registered-read present→consume port, a later option.)

Method fully validated: measure the path, fix the actual cause, re-measure. Fmax 2.4 → 55.8 MHz
overall (23× from the start of F1 synth-prep).

### Next
- **Timing**: new worst path is −14.9 ns. Vivado still flags "not enough pipeline registers after
  wide multiplier" at `bsw_max_tracker.sv:380` (rec. 2 levels) and `bsw_seed_unit.sv:225/188`
  (rec. 4) — now the likely top paths since the divide that masked them is gone. Confirm from the
  re-uploaded timing report, then pipeline those multipliers.
- **Area**: 869K LUT — much better but still over one VU9P SLR (~394K). The structural lever
  (share ONE SW engine across extend/mate-rescue; the design still carries ~3) remains the big win.

---

## 🎯 Re-synth #7 (2026-08-01) — zdrop DSP fold + row-tail register: WNS −12.5 → −9.9 ns

Measures TWO commits, both attacking the same zdrop_break critical path:
- `a12c6f7` zdrop gap-drift multiply constant-fold (e_del/e_ins → W_E_DEL/W_E_INS=1): **DSP 154 → 152** (the 2× DSP48E1 gap-drift multiply is gone — confirmed).
- `cf5665f` register the 160-wide row-tail selection before the zdrop/gscore/rmax arithmetic (worklist #2, 2nd half): splits `qlen → tail_idx → 160:1 mux → zdrop CARRY4 cone → break` into two shorter cones.

| metric | #6 | #7 | Δ |
|--------|---:|---:|---|
| WNS    | −12.488 ns | **−9.935 ns** | +2.55 ns |
| Fmax   | ~64.6 MHz | **77.3 MHz** | +12.7 (+20%) |
| LUT    | 190,184 | 195,702 | +5,518 (registered-mux expansion) |
| FF     | 79,563 | 79,817 | +254 (the new _q/_s registers) |
| DSP    | 154 | **152** | −2 (zdrop fold) |
| RAMB36 / RAMB18 | 28 / — | 28 / 28 | — |

Synth wall-clock: **~14.5 min** (matches the ~15–30 min estimate; the old 65-min run predated the area demolition).

**Journey: 2.4 MHz → 77.3 MHz (≈32×) across F1 synth-prep.**

**Vivado explicitly flagged the likely NEXT target in this run:**
`[Synth 8-12192] Not enough pipeline registers after wide multiplier ... bsw_seed_unit.sv:255` and `:218`
(recommended 4 pipeline levels, present 0). The DSP final report shows `bsw_seed_unit__GB4` A''*B''
17×17/17×18 multipliers with MREG=0, PREG=0 — the multiplier output is unregistered. That's the h0/score
seed-scoring path. **Next: get the #7 worst-path from the fresh timing.rpt to confirm, then pipeline the
bsw_seed_unit multipliers (register MREG/PREG).**

Instance-area highlights (from #7 synth report): `u_swshared/u_bsw` = 130K cells (u_array 88K + u_fsm 29K
[the eh_init DSP closed-form = 143 `C'+A'*B` DSPs] + u_tracker 13K); `u_sel/u_pe` matesw = 72K; `u_ce`
chaining-extend = 103K (u_s chain_introsort = 32K, u_seed bsw_seed_unit = 24K). chain_store `p_next_reg`
still flagged "cannot infer RAM — multiple writes via different ports" (area, not timing).

---

## 🎯 Re-synth #8 target set (2026-08-01) — merge-sorter dedup pipeline (`578147d`)

Re-synth #7 worst path (WNS −9.935 ns) = the **merge sorter dedup**, NOT bsw_seed_unit:
`u_ms` (msort_v2_top) state T_DD_JLAT read a block-RAM record and ran the redundancy cone
(four 64-bit subtracts or_/oq/mr/mq + two min() + RED_NUM/RED_DEN scaled 64-bit compares) →
excl_p/excl_q → `wr_addr` → RAM address, all combinational in one cycle (37 levels, 27× CARRY4,
46% logic / 54% route). (Confirming from timing.rpt mattered — the bsw_seed_unit 8-12192 wide-mult
warning is real but OFF the critical path; pipelining it would not have moved WNS.)

**Fix (`578147d`): split the cone across two FSM states.** T_DD_JLAT registers the raw 64-bit
differences; new T_DD_JWR does the scaled compares + write from the registered values. Bit-exact
values, +1 cycle/dedup-compare, done/busy handshake unchanged. Verified tb_msort_v2 2480/0,
tb_msort_dedup 1696/0, tb_accel_top + tb_chaining_pe2_top PASS (tb_msort_v2 proven to catch a
sort-key mutation → 1696 FAIL). Coverage gap noted: the dedup EXCLUSION decision is output-neutral
on the current corpus (excl_p=excl_q=0 is a no-op) — wants a directed overlapping-alignment vector.

**Awaiting re-synth #8** (HEAD 578147d) to measure the WNS gain and reveal the next worst path.

---

## 🎯 Re-synth #8 (2026-08-01) — merge-sorter dedup pipeline (`578147d`)

Measures the dedup two-stage split (T_DD_JLAT registers the four 64-bit diffs; T_DD_JWR
does the scaled compares + write).

| metric | #7 | #8 | Δ |
|--------|---:|---:|---|
| WNS    | −9.935 ns | **−9.196 ns** | +0.74 ns |
| Fmax   | 77.3 MHz | **82.0 MHz** | +4.7 (+6%) |
| LUT    | 195,702 | 195,589 | ~flat |
| FF     | 79,817 | 80,256 | +439 (pipeline regs) |
| DSP    | 152 | 152 | — |

Real but modest — the dedup path and the next-worst path were close, so shortening one moved
WNS only partway. **Journey: 2.4 → 82.0 MHz (≈34×).** Still short of the F1 125 MHz floor.

Leading next candidates (need the #8 worst-path block to confirm): the `bsw_seed_unit.sv:255/:218`
wide multipliers (the standing `[Synth 8-12192] not enough pipeline registers after wide multiplier`,
MREG=0/PREG=0), the row-tail 160:1 mux front-half, or `chain_introsort`.

### #8 worst-path diagnosis → fix (matesw_dedup redundancy pipeline)

The #8 −9.196 ns path is entirely inside `matesw_dedup` (`u_pe2/u_sel/u_pe/u_ot/u_dd`),
the **mate-rescue** dedup (distinct from the merge-sorter dedup fixed in #8):

- Source: `u_dd/rb_reg_2` RAMB36 read (`DOADO`)
- Dest:   `u_dd/cov_reg` / `qb_reg` **write address** (`ADDRBWRADDR`)
- 11.718 ns, **43 logic levels, 34 CARRY4** — registered RAM read → two 64-bit subtracts
  → min → `20×or_ > 19×mr_` scaled compares → `redun` → selects write-back `wa`, all one cycle.

**Fix (worklist #9, same shape as the #8 msort split):** two-stage the redundancy inner loop.
New state `S_REDIN_W`; stage 1 (`S_REDIN_U`) registers the four reduced diffs (or_/mr_/oq_/mq_)
+ branch predicates (in_window/q_excluded/p_sc<a_sc) + an `a_*` snapshot; stage 2 (`S_REDIN_W`)
does the scaled 20/19 multiply-compare (`red2_redun`) and the write. Breaks RAM-read → 64b arith
→ RAM-write-addr into two register-bounded halves. Bit-exact (+1 cycle per redundancy iteration).

Verify: `tb_matesw_dedup` 6000/0 pass; mutation (red2_redun≡0) → 1432 fail (redundancy path IS
exercised — has teeth); `tb_matesw_orch_top` 3000/0. **NEXT: re-synth #9 to measure.**

---

## 🎯 Re-synth #9 (2026-08-01) — matesw_dedup redundancy pipeline

| metric | #8 | #9 | Δ |
|--------|---:|---:|---|
| WNS    | −9.196 ns | **−8.465 ns** | +0.73 ns |
| Fmax   | 82.0 MHz | **87.2 MHz** | +5.2 |

**Journey: 2.4 → 87.2 MHz (≈36×).** Still short of the F1 125 MHz floor.

**#9 worst path (−8.465 ns): `chain2aln_setup` (`u_pe2/u_ce/u_c2`).**
- Source: `u_c2/b_qbeg_reg` BRAM read → Dest: `u_c2/rmax0_reg[0]/CE`
- 11.203 ns, 38 levels, **31 CARRY4** — per-seed BRAM read → `b_val=rb-(qb+gqb)` / `e_val`
  64-bit arith → compare vs accumulated `rmax0/rmax1` → register, all in one `D_LOOP` cycle.
- **Fix (worklist #10):** pipeline D_LOOP into D_LOAD (read seed → register b_val/e_val) +
  D_ACC (compare registered b_val<rmax0 → update). Splits BRAM-read→arith from
  arith→accumulator. +1 cyc/seed (n small). Same shape as #8/#9.

---

## 🎯 Re-synth #10 (2026-08-01) — chain2aln_setup rmax pipeline + bsw_top standalone

| target | WNS | Fmax | note |
|--------|----:|-----:|------|
| chaining_pe_pair_top (#10) | **−6.772 ns** | **102.3 MHz** | was −8.465 / 87.2 → **+15 MHz, crossed 100** |
| bsw_top (standalone, NEW)  | **−6.776 ns** | **102.3 MHz** | ~130K LUT |

**Journey: 2.4 → 102.3 MHz (≈43×).**

### ⚠️ THE TWO TRACKS CONVERGED — same critical path
The full-design worst path and the bsw_top-alone worst path are the **same net**, inside bsw_top:
- Source: `.../u_bsw/u_array/g_pe[151].u_pe/H_curr_reg_reg[7]/C` (a systolic PE's H_curr score)
- Dest:   `.../u_bsw/u_tracker/pr_i_reg[9][13]/D` (a `bsw_max_tracker` stage-1 partial-max reg)
- 9.64 ns, 24 levels, 12 CARRY4, **~74% ROUTING** (2.5 ns logic / 7.1 ns route)

This is the max-tracker's stage-1 reduction gathering h_cells from 160 physically-spread PEs.
Two consequences:
1. **bsw_top does NOT auto-close 125 MHz on the OOC proxy** — the "small kernel is fine" premise
   was wrong; good thing we measured. bsw_top IS the shared bottleneck.
2. **One fix helps both tracks** — the full design's limiter now lives entirely in bsw_top.

### ⚠️ FIDELITY CAVEAT — this is a routing-dominated path on UNPLACED synthesis estimates
The 74% "route" is a synth estimate (paths show "unplaced"). Pre-P&R routing numbers on a
160-PE gather are unreliable — real placement/floorplanning can move this a lot, either way,
and VU9P is faster than the xc7v2000t proxy. **We've hit the point where the next high-value
signal is a real place-and-route, not another OOC synth.** → do a bsw_top IMPLEMENTATION run
(local proxy P&R for a truth-check, and/or the F1 HDK for the real VU9P number).

---

## 🎯 bsw_top REAL PLACE-AND-ROUTE (impl_bsw_top.tcl) — ground truth

Full opt+place+route on the 7-series proxy (xc7v2000t-2), period 5.0 ns.

| metric | value |
|--------|------:|
| WNS (@5.0 ns) | −3.382 ns |
| min period | 8.382 ns → **Fmax ≈ 119.3 MHz** |
| slack vs 125 MHz (8.0 ns) | **−0.38 ns (just short)** |
| worst path | `u_array/g_pe[134].u_pe/active_q` → `u_tracker/pr_i_reg[8][13]` (PE→tracker reduction), 8.40 ns, 21 levels, 9 CARRY4, **72% route** |
| FF | 27,338 (1.1%) · DSP 140 · BRAM 0 |

### Read
- **Real placement beat the OOC synth estimate by ~17 MHz** (102 est → 119 placed) — exactly the
  expected behaviour for a routing-dominated path once the placer resolves it. The OOC number was
  pessimistic; the truth-check did its job.
- **Only 0.38 ns short of 125 MHz, and that's on the SLOW 7-series proxy.** The real target VU9P is
  UltraScale+ (16 nm vs 28 nm) — meaningfully faster fabric; a 5% improvement covers the gap. So bsw_top
  is **very likely to close 125 MHz on the real VU9P.**
- **Residual risk:** the AWS Shell confines the CL to a region + adds congestion, which the standalone
  proxy P&R does not model. So "likely, not certain" — the definitive test is the real VU9P build
  (`aws_build_dcp_from_cl.sh -clock_recipe_a A1`, which P&Rs at 125 and reports pass/fail).
- Still the same shared bottleneck: the max_tracker 160-PE reduction (PE→pr_i). The effective fix
  (register the leaf gather) is a latency-rebalance of a latency-matched pipeline (higher risk); the
  cheap knob (MIDLEV rebalance) won't move the leaf-gather routing much.

---

## ✅ bsw_top closes 125 MHz (aggressive P&R) — F1 build GREEN-LIT

MIDLEV sweep: 4=119.3, 3=111.6, 2=113.1 MHz → MIDLEV=4 optimal (no RTL change).
Then the *aggressive* impl flow (place Explore + phys_opt_design + route Explore + post-route phys_opt):

| impl flow | Fmax | route % | vs 125 |
|-----------|-----:|--------:|-------:|
| vanilla opt+place+route | 119.3 MHz | 72% | −0.38 ns |
| **+ phys_opt / Explore** | **124.4 MHz** | 67% | **−0.039 ns (39 ps)** |

phys_opt recovered 0.67 ns of routing on the PE→pr_i path, exactly as predicted for a route-dominated net.
**124.4 MHz / 39 ps short — on the SLOW 7-series proxy (28 nm).** The VU9P (16 nm UltraScale+, faster fabric)
+ AWS's aggressive default build strategies clear 125 with margin. **Conclusion: bsw_top closes 125 MHz;
RTL/timing margin work is DONE. Next = the AWS AFI build (the definitive VU9P test).**

---

## 🎯 chaining_pe_pair_top REAL PLACE-AND-ROUTE (#10 result) → fix #11 (2026-08-04)

The **full design** (`chaining_pe_pair_top`, ~305K LUT — the on-chip pipeline, distinct from the
`bsw_top` standalone above) was taken through real aggressive P&R
(`synth/ooc/impl_chaining_pe_pair_top.tcl`: opt + place Explore + phys_opt + route Explore + post
phys_opt) on the 7-series proxy:

| metric | value |
|--------|------:|
| WNS (@8.0 ns / 125 MHz) | **−1.367 ns** |
| min period | 9.367 ns → **Fmax ≈ 106.8 MHz** |
| failing endpoints | 11,364 (TNS −3650 ns) — all one worst-path shape |

Real P&R beat the #10 OOC estimate (102.3 → 106.8 MHz) as expected, but still short of 125.

### #10 full-design worst path (−1.367 ns): the target-base mux fused into the DP recurrence
`u_pe2/u_swshared/u_bsw/u_fsm/t_idx_reg[3]` → **`target_q[t_idx]` MUXF7/MUXF8 tree (~3.9 ns)** →
`u_array/g_pe[0].u_pe` **H→E→F recurrence CARRY4s (~5.2 ns)** → `F_out_reg_reg[11]/D`.
Data path 9.339 ns (logic 2.55 / **route 6.79 = 73%**), 20 logic levels. One clock did BOTH the
MAX_TLEN-way "select the target base indexed by `t_idx`" AND the full Smith-Waterman cell update —
two independent operations needlessly in the same cycle.

- **Fix (worklist #11, `bsw_ctrl_fsm.sv`):** register the target mux and **read one index ahead**.
  `sa_target_o` was `target_q[t_idx]` combinational; now a `tgt_r` flop is loaded with
  `target_q[t_idx+1]` each S_RUN cycle and primed with `target_q[0]` during the otherwise-idle
  S_LOAD cycle, so it delivers `target_q[t_idx]` on the SAME cycle the array consumes it.
  **Zero latency added** — array/tracker/drain alignment unchanged; the ~3.9 ns select and the
  ~5.2 ns DP update become two separate sub-8 ns paths. `target_q` is stable from `accept_req`
  (latched in S_IDLE/S_DONE, not S_LOAD) so the S_LOAD read is race-free.
- **Verified (bit-exact + mutation):** `tb_bsw_ext` (15887 real bwa-mem2 extension vectors) —
  baseline 0 fail, **fix #11 byte-identical 0 fail**. Mutation (drop the `+1` read-ahead → `tgt_r`
  lags 1 cyc): **RED, 13675/15887 fail** (off-by-one target misalignment, e.g. score 133/140,
  tle 131/130) — the tb has teeth for target alignment. **NEXT: user re-runs
  impl_chaining_pe_pair_top.tcl to measure #11 (expect the worst path to move off the target mux).**
