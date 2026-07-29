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
