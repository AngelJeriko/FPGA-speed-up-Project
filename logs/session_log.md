# BSW FPGA — Session Log

Running detailed log of work done in this session. Append-only; each entry has a
header so you can grep for it.

---

## 2026-05-31 — Resume: get the testbench actually running

### Goal
Continue from prior session, which had architected 7 SV modules (~1100 lines)
for a parameterized banded Smith-Waterman accelerator targeting Intel FPGA.
RTL elaborated but never ran — Icarus Verilog choked on typedef'd ports in
module headers. Decision at start of this resume: install WSL + Verilator.

### Step 1: WSL + Verilator install
- User installed WSL Ubuntu and ran `sudo apt install -y verilator gtkwave build-essential`.
- Verilator 5.032 (Debian package) confirmed working.

### Step 2: First Verilator invocation
- Symptom: 7 `TIMESCALEMOD` warnings promoted to errors. Verilator wants
  every module under a timescale, and the package/RTL had none — only the
  testbench had ``` `timescale 1ns/1ps ```.
- Fix: added `--timescale 1ns/1ps` and `-Wno-TIMESCALEMOD` to both
  `scripts/run_sim.sh` and `scripts/run_sim.ps1`.

### Step 3: Make couldn't handle paths with spaces
- Symptom: `make: *** /mnt/c/Users/kanak/OneDrive/Desktop/BWA-MEM2: No such file or directory.`
  Verilator's generated `Makefile` doesn't quote its build dir, and
  `BWA-MEM2 repo` contains a space.
- First attempt: symlink the project at `~/bsw` → didn't help; Verilator
  `realpath`s `--Mdir` back through the symlink to the spaced path. Symlink
  was still useful (cleaner cd).
- Working fix: put the obj dir under `/tmp/bsw/obj_<tb>` (no spaces).
  Edited `run_sim.sh` to use `OBJ="${BSW_BUILD_DIR:-/tmp/bsw}/obj_${TB}"`.
  Verilator's makefile only needs the *build* dir to be space-free; source
  paths in spaced directories are fine because make only `cd`s into the
  build dir.

### Step 4: First successful build — PE tests 6/18 passing
- Build succeeded; tests ran. H output stuck at 0 in most failing tests, but
  `target_o` forwarded correctly (T9 PASS, value=2), so the wavefront/active
  pipeline works — only the DP datapath was dead.
- Root cause: every combinational signal in `bsw_pe.sv` was written as
  `score_t M_term = diag_nz ? ... : '0;` at module scope. For `score_t`
  (a `logic` typedef = variable, not a net), `=` is a **one-time initializer**,
  not a continuous assignment. Variables get computed once at time 0 with
  unknown inputs and never update again. The `wire diag_nz = ...` worked
  because `wire` is a net type.
- Fix: wrapped the entire recurrence (`M_term`, `H_max_ME`, `H_max_MEF`,
  `H_new`, `oe_del`, `E_open`, `E_ext`, `E_pick`, `E_new`, `oe_ins`,
  `F_open`, `F_ext`, `F_pick`, `F_new`, `diag_nz`) in an `always_comb` block.
  See `rtl/bsw_pe.sv` lines ~85-120.

### Step 5: 14/18 passing — two remaining bugs
After the `always_comb` fix, four tests still failed:
- `T2 mismatch E got=3 expected=0`
- `T2 mismatch F_out got=-1 expected=0`
- `T5 semi-global zero got=2 expected=0`
- `T8 h_diag after 1 cyc got=9 expected=0`

#### Bug A: unsized `'0` literal breaks the clamp-to-zero
- `(F_pick > '0) ? F_pick : '0` — the unsized `'0` literal is **unsigned**.
  When one operand of `>` is unsigned, the comparison becomes unsigned.
  A negative `F_pick` like `-1` is `16'hFFFF` = 65535 unsigned, which is
  "greater than 0", so the clamp passes the negative value through. That
  produced the `F_out = -1` in T2.
- Fix: introduced `localparam score_t SZERO = score_t'(0);` in `bsw_pe.sv`
  and replaced every `'0` in the comparison RHS with `SZERO`. Signed both
  sides → signed compare → clamp works.

#### Bug B: stale cycle between `clear_state` and `drive_cell` in the testbench
- `clear_state()` only toggled `clear_i`. Between its return and the next
  `drive_cell`'s negedge, one full clock cycle elapsed during which the
  PE saw `clear_i=0` and the previous test's stale `active_i=1`, stale
  `target_i`, stale `h_diag_i`. That cycle ran the DP recurrence on the
  freshly-cleared regs with stale inputs and stored bogus values into
  `E_reg` and `H_curr_reg`. The next `drive_cell` then saw a polluted
  state instead of a clean one.
- Symptoms: `T2 E=3` (E_reg polluted from stale T1 inputs);
  `T5 H=2` (E_reg polluted to 2 from stale T4 inputs, then dominates the
  T5 DP); `T8 h_diag=9` (stale cycle computed `H=9` from T7 ambiguous
  inputs, which rolled into H_prev_reg one cycle later).
- Fix: `clear_state()` now also drives `active_i=0`, `target_i='0`,
  `h_diag_i='0`, `f_i='0` during its window. With `active_i=0`, the always_ff
  in the PE holds its registers regardless of what the DP combinational
  computes. The bogus DP output is discarded.
- See `tb/tb_bsw_pe.sv` lines ~115-126.

### Step 6: 18/18 PASS
- After both fixes: `==== tb_bsw_pe done: 18 checks, 0 errors ==== PASS`
- Verilator walltime: ~5s (g++ compile), sim: <1ms.
- Build is single-threaded. At this size threading wouldn't help; will revisit
  for the full top-level build (64 PEs).

### Files modified in this session
- `rtl/bsw_pe.sv` — wrapped recurrence in `always_comb`; introduced `SZERO`.
- `tb/tb_bsw_pe.sv` — `clear_state()` now idles the wavefront inputs.
- `scripts/run_sim.sh` — added `--timescale 1ns/1ps`, `-Wno-TIMESCALEMOD`,
  `/tmp/bsw/obj_<tb>` build dir.
- `scripts/run_sim.ps1` — same timescale flags (for parity, not used today).
- `logs/session_log.md` — this file.

### Files unchanged
- `rtl/bsw_pkg.sv`, `rtl/bsw_score_matrix.sv`, `rtl/bsw_systolic_array.sv`,
  `rtl/bsw_max_tracker.sv`, `rtl/bsw_ctrl_fsm.sv`, `rtl/bsw_top.sv`.
- `tb/tb_bsw_top.sv` (not yet run).

### Open items
- Run `tb_bsw_top` (4 end-to-end tests: perfect match, all-mismatch,
  match+tail, single insertion).
- Likely surface: the same `'0` clamp bug pattern in `bsw_max_tracker.sv`?
  Already confirmed clean — its zdrop math was already in an `always_comb`.
- Cycle-counter off-by-one between FSM and tracker (suspected from prior
  session) — TBD on first top-level run.

### Step 7: tb_bsw_top first run — every score is 0 (algorithmic bug)
- Build succeeded (~13s, single-threaded; threading would matter at this size).
- Result: 9 / 11 checks FAIL. Every "should be > 0" score returns 0; only
  the "expected 0" checks pass (T1 max_off, T2 all-mismatch).
- Root cause: I implemented the C++ "M = M ? M + S : 0" gate in `bsw_pe.sv`
  faithfully, but the C++ code RELIES on two boundary-initialization steps
  that the hardware doesn't replicate:
  1. **First row** `eh[j]` initialized from `h0`: `eh[0]=h0`,
     `eh[1]=h0-oe_ins`, `eh[j]=eh[j-1]-e_ins` (clamped) — see
     `bandedSWA.cpp:142-145`.
  2. **First column** boundary recomputed each row:
     `h1 = h0 - (o_del + e_del*(i+1))` clamped to 0 — see
     `bandedSWA.cpp:171-173`.
- Without these, every diagonal stays 0 and the "M=0 if H_diag=0" gate kills
  every cell. The C++ uses h0 as the seed score (this is a seed-extension
  algorithm, not pure local SW); the testbench was written assuming pure
  local SW with h0=0.

### Decision: Option B — keep BWA-MEM2 semi-global semantics, fix the boundary
- User chose: implement the boundary correctly rather than weaken the
  algorithm.
- Plan (chunky change, ~150-200 lines across 4 RTL files + testbench update):
  1. `bsw_pe.sv`: add `init_h_curr_i` port; on `load_q_i` pulse, latch
     `H_curr_reg <= init_h_curr_i` (this pre-fills each PE's state so the
     chain delivers the right H_diag for the first cell each PE processes).
  2. `bsw_systolic_array.sv`: add `init_h_curr_i [N_PE-1:0]` array port,
     wire through to each PE instance.
  3. `bsw_ctrl_fsm.sv`:
     - Compute `eh_init[j]` for j=0..MAX_QLEN-1 as a combinational
       saturating-subtract ladder (h0, h0-oe_ins, then -e_ins per stage,
       clamped at 0). Drive these to the array as `sa_init_h_curr_o`.
     - Add a `bound_reg` that starts at h0 on the S_LOAD→S_RUN transition,
       decays by oe_del on the first cycle of S_RUN then by e_del each
       subsequent cycle, saturated at 0. Drive `sa_h_diag_o = bound_reg`
       (was hard-wired to '0).
  4. `bsw_top.sv`: wire the new array port through.
  5. `tb_bsw_top.sv`: set cfg.h0=1 in tests; recompute expected scores by
     hand-walking the BWA-MEM2 recurrence:
     - T1 (ACGT/ACGT): score=5 (h0 propagates: H(0,0)=2, H(1,1)=3, H(2,2)=4,
       H(3,3)=5), qle=4, tle=4, gscore=5, gtle=4.
     - T2 (AAAA/CCCC): score=1 (max initialised to h0; all-mismatch never
       improves it).
     - T3 (ACGT/ACGT+GGGG): score=5 (same as T1; tail rows break via m=0).
     - T4 (ACGT/ACAGT): score≥2 still holds (works out to 3).
  6. `tb_bsw_pe.sv`: T5 ("semi-global zero") still passes — when
     init_h_curr_i defaults to 0, the gate still kills the cell. Just need
     to wire the new init port (drive 0).

### Step 8: Implemented Option B — boundary streaming + eh[] init
- `rtl/bsw_pe.sv`: added `init_h_curr_i` port; clear/load logic now pre-loads
  H_curr_reg with init value during load_q_i. PE T5 still passes (init=0).
- `rtl/bsw_systolic_array.sv`: added `init_h_curr_i [N_PE-1:0]` array; wired
  through to each PE.
- `rtl/bsw_ctrl_fsm.sv`:
  - eh_init[] saturating ladder using helper arrays `eh_sub[]`/`eh_diff[]`
    (hoisted out of the for-loop to avoid Verilator picking up automatic-
    variable declarations inside an always_comb block).
  - `bound_reg`/`bound_first` decay register driving `sa_h_diag_o`. Starts
    at h0 at S_LOAD→S_RUN transition, decays by oe_del on the first run
    cycle then by e_del each cycle, saturated at 0.
- `rtl/bsw_top.sv`: routed `sa_init_h_curr` through FSM→array.
- `tb/tb_bsw_top.sv`: cfg.h0=1; recomputed expected scores for T1/T2/T3.
- `tb/tb_bsw_pe.sv`: wired `init_h_curr_i = score_t'(0)` for parity.

### Step 9: Top test — scores correct, but indices wrap to 65k
- Build OK. Got: T1 score=5, qle=4, gscore=5, max_off=0 — PASS.
  But T1 tle=65533, gtle=0, max_off (in some build) shows wrap.
- Root cause: `tr_clear_o` and `tr_start_o` both fire at the same posedge
  (the S_LOAD→S_RUN transition). The tracker's cyc-counter logic gives
  clear_i precedence:
  ```
  if (!rst_n || clear_i) cyc <= '0;
  else if (start_i) cyc <= 1;
  ```
  Result: `cyc <= 0` (clear wins), and stays at 0 because the
  `cyc != 0` increment guard never trips. `row_of_pe[j] = 0 - 1 - j` wraps
  to a huge unsigned, so max_i/max_j/max_off all come back as garbage near
  65k.
- Fix in FSM: delay `tr_start_o` by 1 cycle. Added `state_q` (one-cycle-
  delayed state register) and changed:
  ```
  // was: tr_start = (state == S_LOAD) && (state_n == S_RUN);
  // now: tr_start = (state == S_RUN) && (state_q != S_RUN);
  ```
  Now tr_start fires on the FIRST cycle of S_RUN, by which time tr_clear
  has dropped (since state is no longer S_LOAD). No race, cyc actually
  starts counting.
- Verified: 10/11 pass. score, qle, tle, gscore, max_off all correct. Only
  T1 gtle remained off (got 3, expected 4).

### Step 10: gtle off-by-one — h_last/row_idx skew in the row pipeline
- The row pipeline shifts each row's data through stages 0..qlen-1 with a
  1-cycle delay per stage. When stage qlen-1 (= stage 3 here) carries
  row R's `m`/`mj`/`idx`, the cycle index has advanced — so
  `h_cells_i[qlen-1]` no longer reflects row R's last-column H; it shows
  PE_3's *current* cell for row R+1.
- The old code did `row_tail_h_last = cell_valid ? h_cells[k] : row_m_pipe[k]`,
  which combined row R's `idx` with row R+1's `h_cells[3]`. So gscore was
  fine for the final row (cell_valid drops, falls through to row_m), but
  the recorded `max_ie` was off by one for each row, and the last update
  ended up writing max_ie=2 instead of 3.
- Fix in `bsw_max_tracker.sv`: added `h_last_delayed` — a 1-cycle-delayed
  copy of `h_cells_i[tail_idx]`. By the cycle when stage 3 publishes row
  R, `h_last_delayed` carries H(R, qlen-1). Tail logic now reads
  `row_tail_h_last = h_last_delayed`.

### Step 11: All green — 29/29
- `tb_bsw_pe`: 18 / 18 PASS (PE unchanged from step 6).
- `tb_bsw_top`: 11 / 11 PASS.
  - T1 (ACGT/ACGT, h0=1): score=5, qle=4, tle=4, gscore=5, gtle=4, max_off=0.
  - T2 (AAAA/CCCC, h0=1): score=1 (= h0 floor, dead-row break).
  - T3 (ACGT/ACGT+GGGG, h0=1): score=5, tle=4, qle=4.
  - T4 (ACGT/ACAGT, h0=1): score=3 (passes ≥2 check).
- End-to-end BWA-MEM2 semi-global semantics verified against C++
  reference math.

### Files touched in step 7-11 (Option B)
- `rtl/bsw_pe.sv` — new `init_h_curr_i` port + clear/load latching.
- `rtl/bsw_systolic_array.sv` — pass-through of init_h_curr array.
- `rtl/bsw_ctrl_fsm.sv` — eh_init ladder, bound_reg streaming, state_q,
  delayed tr_start_o.
- `rtl/bsw_max_tracker.sv` — h_last_delayed register, swapped into
  row_tail_h_last.
- `rtl/bsw_top.sv` — wired init_h_curr through.
- `tb/tb_bsw_top.sv` — h0=1, new expected scores.
- `tb/tb_bsw_pe.sv` — wired init_h_curr_i = 0.

### Known TODOs (future work, NOT blockers)
- Full BWA-MEM2 banding (dynamic beg/end shrink each row) not implemented.
  Current hardware processes the full column band — correct but
  inefficient. The score will still match the unbanded reference.
- Swath processing for qlen > N_PE not implemented (asserts qlen <= N_PE).
- Score/index bit widths are conservative (16-bit signed scores, 16-bit
  unsigned lengths). For very long reads or large h0 may need to grow.
- zdrop early-exit math is implemented in the tracker but only tested
  implicitly (T2 dead-row exit). Need a dedicated zdrop test case.
