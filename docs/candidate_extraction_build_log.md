# Candidate-extraction build log (fully on-chip both-direction paired-end mate-rescue)

Detailed, step-by-step record of the candidate-extraction work — making the mate-rescue
candidate selection (the `b[i]` loop of `mem_sam_pe_batch`) and the candidate source
(read `i`'s alnregs) come from the accelerator ON-CHIP, instead of being host-driven.

Context going in: `accel_pe_top` already folds ONE accel run (read `!i`) into the rescue
ma list; the candidates `b[i]` and their windows were still host-fed. Goal: feed the
candidates from a SECOND accel run over read `i`, with the score-gate selection on-chip.

NOT committed yet (per request — commit the batch later). Working tree carries all of the
below on top of `origin/main` + the two doc-fix commits (`7f9e177`, `2d49c50`).

---

## Step 1 — pe-level selection MODEL (`host/mate_rescue/pe.h`)  ✅ verified-by-construction

**What.** A C++ model one level above `orch.h`: given read `i`'s score-sorted alnreg list
(the candidate SOURCE) and read `!i`'s entry ma list, select the "good" candidates and
thread each through `matesw_orchestrate` into the mate's ma list.

**The predicate** (transcribed from the well-known `mem_sam_pe` mate-SW selection):
```
top = src[0].score                            // src sorted DESC by score (dedup output)
K   = # leading j with src[j].score >= top - pen_unpaired,  capped at max_matesw
for j in 0..K-1:  matesw_orchestrate(src[j], mate_seq=!i, ma=a[!i])
```
Key simplification: because the source is score-sorted **descending**, the good set is a
contiguous **prefix** (once a score drops below `top - pen_unpaired`, all later ones do
too) → a clean `break`, and `max_matesw` caps that prefix in order. This is bit-equivalent
to bwa's two-step form (build `b[i]` = all passing, then rescue `min(b[i].n, max_matesw)`).

**Why a runtime scalar, not a constant.** `pen_unpaired` / `max_matesw` are `MPeOpt`
fields, so the RTL takes them as input ports — no default baked into hardware. Defaults
`pen_unpaired=17`, `max_matesw=50` (bwa) are noted FOR CONFIRMATION at capture.

**Validation posture / deferred.** The SELECTION predicate is not yet validated against the
BATCHED source on real data — the existing `orch_capture` validates each `mem_matesw` CALL,
not which candidates fire. Deferred to a pe-level capture (logged in
`docs/remote_capture_plan.md`'s scope). Stage-1: candidate `is_alt` is dropped on-chip (the
merge-sorter `rec_t` has no `is_alt`) → candidates enter with `is_alt=0`; the generator sets
`is_alt=0` to keep the golden bit-exact with the RTL. `is_alt` is not a dedup key and is not
in the compared output fields, so this is inert w.r.t. correctness of the compared result.

**Files.** `host/mate_rescue/pe.h` (new). Compile-checked with `g++ -fsyntax-only` (SYNTAX_OK).

---

## Step 2 — selection RTL (`rtl/matesw_pe_sel_top.sv`)  ✅ 2000/0 bit-exact vs pe.h

**What.** Wraps the verified `matesw_pe_top` with the on-chip selection layer:
- a candidate-SOURCE register file (`s_rb/s_rid/s_alt/s_sc`, depth `NSRC`), host/accel-loaded
  via `src_ld_*`;
- the `K`-prefix counter: `S_TOP` reads `top = s_sc[0]`, `thr = top - pen_unpaired`; `S_CHECK`
  gates `j < n_src && j < max_matesw && s_sc[j] >= thr` (else done);
- a driver that, per selected `j`, pulls `a_rb/a_rid/a_is_alt = s_*[j]` and pulses the inner
  `matesw_pe_top.cand_start` — so the DUT decides WHICH/HOW MANY candidates fire, not the host.

**Windows stay host-fed (Stage-1).** Each selected candidate's per-orientation reference
windows are requested on demand via a handshake: the wrapper raises `cand_req` with
`cur_cand=j`; the host loads that candidate's windows + `ld_ref` ref bytes and asserts
`cand_wins_ready`; the wrapper then pulses `cand_start`. (No on-chip `bns_fetch_seq`.)

**FSM.** `S_IDLE`(sel_start → pulse pe_top.init, latch n_src/pen/maxm) → `S_TOP` → `S_CHECK`
→ `S_REQ`(wait cand_wins_ready) → `S_START`(pulse cand_start) → `S_RUN`(wait cand_done; j++)
→ back to `S_CHECK`; `S_DONE` pulses `done`. `n_src==0` short-circuits to done.

**Verification.** `host/mate_rescue/gen_pesel_vectors.cpp` (-DMR_DEDUP_INT, golden = pe.h)
emits 2000 cases: score-sorted source straddling the gate (`pen_unpaired` 10..25;
`max_matesw` occasionally 1..3 to exercise the cap), entry ma, ms, all per-candidate
windows, expected final ma. `tb/tb_matesw_pe_sel_top.sv` plays host (loads source+params,
pulses sel_start, services each `cand_req`). Result:
`tb_matesw_pe_sel_top: 2000 cases, 0 failures -> ALL PASS` (3931/6978 candidates selected —
healthy gate coverage). `run_sim.sh` branch + Makefile (`peselvec`) + `.gitignore` added.

**Files.** `rtl/matesw_pe_sel_top.sv`, `tb/tb_matesw_pe_sel_top.sv`,
`host/mate_rescue/gen_pesel_vectors.cpp`, edits to `scripts/run_sim.sh`,
`host/mate_rescue/Makefile`, `host/mate_rescue/.gitignore`.

---

## Step 3 — accel two-run fold (`rtl/accel_pe2_top.sv`)  ✅ 200/0 capture routing verified

**Goal.** Source the candidate buffer AND the rescue ma list from accel runs, on-chip:
- Run 1 (`run_is_cand=1`): accel over read `i` → score-sorted `a[i]` beats captured into
  `matesw_pe_sel_top`'s SOURCE buffer (`src_ld_*`); `src_alt=0` (Stage-1, rec_t has no is_alt).
- Run 2 (`run_is_cand=0`): accel over read `!i` → `a[!i]` beats captured into the rescue ma
  regfile (`ld_ma_*`, passed through to `matesw_pe_top`).
- Host then loads ms (read `!i`) + drives windows per `cand_req`, pulses `sel_start`.

`n_src` / `n_ma_init` are latched from the per-run capture beat count at each accel `done`.
The accel output is already score-sorted descending (merge-sorter), so the source ordering
the prefix-gate needs is free. Either run raising accel `fallback` (equal-`re` tie / >1024)
propagates out → host redoes that read in SW.

**Built.** `rtl/accel_pe2_top.sv` instantiates one `accel_top` (reused for both runs) +
`matesw_pe_sel_top`. Capture FSM: `run_is_cand` latched at `read_start` into `run_cand_r`;
`cap_cnt` resets at `read_start`, increments per `ac_tvalid` beat; at the `ac_done` edge it
latches `n_src_r`/`n_ma_r` (by run) and registers `accel_fallback = ac_fb` (host samples at
the `accel_done` pulse). Beats route combinationally: `run_cand_r` → `src_ld_*` (rb/rid/
score; `alt=0`); else → `ld_ma_*` (full record; `cov=0`). The selector's `n_src`/`n_ma_init`
take `n_src_r`/`n_ma_r`; `sel_start` + windows + ms remain host-driven.

**Debug tap added.** `matesw_pe_sel_top` got an additive, logic-inert candidate-source
readback (`src_rd_idx` → `src_o_rb/rid/alt/sc`) so the fold's tb can verify the captured
source (mirrors how the ma is read back via `rd_idx`). Re-ran `tb_matesw_pe_sel_top` after the
change: still **2000/0** (additive ports, no behavior change).

**Verification.** `tb/tb_accel_pe2_top.sv` reuses `accel_vectors`, driving accel per read with
`run_is_cand` alternating — even reads as source-runs (check the SOURCE buffer == a[R]:
rb/rid/score, alt==0, count == n_src_o), odd reads as ma-runs (check the ma regfile == a[R]:
rb/re/qb/qe/rid/score, cov==0, count == n_ma_init_o). Fallback reads must raise
`accel_fallback`; not compared. It does NOT pulse `sel_start` — the selection + rescue
datapath is already covered bit-exact by `tb_matesw_pe_sel_top`; this isolates the new
capture FSM (same decomposition `tb_accel_pe_top` used for the single-run handoff). Result:
`tb_accel_pe2_top: 200 reads, 0 failures -> ALL PASS`. `run_sim.sh` branch added (reuses the
accel vectors).

**Files.** `rtl/accel_pe2_top.sv` (new), `tb/tb_accel_pe2_top.sv` (new),
`rtl/matesw_pe_sel_top.sv` (+debug readback), `tb/tb_matesw_pe_sel_top.sv` (+debug port tie),
`scripts/run_sim.sh` (+branch).

---

## Status / what's on-chip now

The mate-rescue back-half is, in simulation, fully composable on-chip for one direction:
accel(read i) → candidate source → on-chip SELECTION (score gate + max_matesw cap) →
rescue each into ma = accel(read !i) → final a[!i]. The host now only supplies what the
FPGA structurally cannot (Stage-1): the mate sequence and the per-candidate reference
windows (no on-chip `bns_fetch_seq`), plus the selection scalars `pen_unpaired`/`max_matesw`.

## Remaining / deferred

- **Full rescue-golden end-to-end for the fold** (heavier follow-on): a combined generator
  (gen_accel×2 for source+ma + synthesized windows + `pe.h` selection) feeding one
  `tb_accel_pe2_top` run that pulses `sel_start` and checks the FINAL rescued ma bit-exact.
  Current coverage = capture routing (here) ∘ selection+rescue (`tb_matesw_pe_sel_top`),
  composed but not yet checked as one closed loop on real-accel data.
- **Selection-predicate validation on real data** — confirm `score >= top - pen_unpaired`
  + `max_matesw` cap (and the defaults) against the BATCHED `mem_sam_pe_batch` source at the
  next remote capture (extend the prepped capture set).
- **Both directions** — a full pair = two `accel_pe2_top` invocations (swap cand/ma roles);
  a thin outer sequencer could drive both, or the host issues them.
- Oversize-fallback gap (logged in `merge_sorter_v2_design.md`) still applies to the accel
  runs feeding this fold.
