# Candidate-extraction build log (fully on-chip both-direction paired-end mate-rescue)

Detailed, step-by-step record of the candidate-extraction work — making the mate-rescue
candidate selection (the `b[i]` loop of `mem_sam_pe_batch`) and the candidate source
(read `i`'s alnregs) come from the accelerator ON-CHIP, instead of being host-driven.

Context going in: `accel_pe_top` already folds ONE accel run (read `!i`) into the rescue
ma list; the candidates `b[i]` and their windows were still host-fed. Goal: feed the
candidates from a SECOND accel run over read `i`, with the score-gate selection on-chip.

All of the below is COMMITTED + PUSHED on `main`. Steps 1–5 = `7007f9a` / `35a4a0e` / `7b25ac0`;
Steps 6–8 (real-data validation) = `7019d7a`; **Step 9 (THE JOIN) = `15e03a1`** (2026-07-16).
(This header used to read "NOT committed yet" — that was true only for the original June batch.)

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

## Status snapshot AS OF STEP 3 (superseded — see Step 9 for the current picture)

The mate-rescue back-half is, in simulation, fully composable on-chip for one direction:
accel(read i) → candidate source → on-chip SELECTION (score gate + max_matesw cap) →
rescue each into ma = accel(read !i) → final a[!i]. The host now only supplies what the
FPGA structurally cannot (Stage-1): the mate sequence and the per-candidate reference
windows (no on-chip `bns_fetch_seq`), plus the selection scalars `pen_unpaired`/`max_matesw`.

## Step 4 — full closed-loop golden (`tb_accel_pe2_loop`)  ✅ 94/94 bit-exact end-to-end

**What.** Closes the loop the per-stage tbs only covered separately: drives the WHOLE fold
through the RTL on real-accel data and checks the FINAL rescued ma bit-exact.

**Generator (`host/mate_rescue/gen_pe2_vectors.cpp`, `-DMR_DEDUP_INT`).** Combining the
extend + mate header subsystems in one TU collides (`ksw_extend2` C-vs-C++ linkage in
extend `ksw.h` vs mate `ksw_ref.h`; `LIM_*` scope). Sidestepped entirely: the accel outputs
are ALREADY in `accel_vectors.txt` (gen_accel) and `tb_accel_pe2_top` already proved the RTL
accel output equals them — so the generator just PARSES `accel_vectors.txt`, taking read i's
output as the candidate SOURCE and read !i's as the entry ma, and runs ONLY
`pe.h::matesw_pe_select` for the rescue (mate headers only, no clash). It re-emits both reads'
accel INPUT blocks (so the RTL regenerates the identical source/ma on-chip) + rescue params +
ms (= read !i's query) + synthesized per-candidate windows + the final ma. Pairs are emitted
only when both reads are non-fallback, non-empty, and ≤64 (94 cases from 200 reads / 100
pairs; 6 skipped; 391 candidates selected). `l_pac` = 3e9 (> all coords; host-fed identically
to the RTL so any value is bit-consistent).

**Verification (`tb/tb_accel_pe2_loop.sv`).** Per case: drive accel for read i
(`run_is_cand=1` → source), assert `n_src_o==nout_i` & no fallback; drive accel for read !i
(`run_is_cand=0` → ma), assert `n_ma_init_o==nout_j`; load ms + selection params, pulse
`sel_start`; service each `cand_req` with that candidate's windows; check the FINAL ma
bit-exact. Result: `tb_accel_pe2_loop: 94 cases, 0 failures -> ALL PASS`. `run_sim.sh` branch
+ Makefile (`pe2vec`) + `.gitignore` added.

**Files.** `host/mate_rescue/gen_pe2_vectors.cpp` (new), `tb/tb_accel_pe2_loop.sv` (new),
edits to `host/mate_rescue/Makefile`, `host/mate_rescue/.gitignore`, `scripts/run_sim.sh`.

**Coverage now = closed loop.** accel(i)→source ∘ accel(!i)→ma ∘ on-chip selection ∘ rescue,
checked as ONE pass through the RTL against the accel-pipeline ∘ pe.h golden — not just the
per-stage tbs composed.

## Step 5 — both-directions sequencer (`rtl/accel_pe_pair_top.sv`)  ✅ 91/91 bit-exact

**What.** A full pair rescues BOTH mates (`mem_sam_pe` runs the candidate loop for i=0 and
i=1): dir 0 candidates=a[0]→a[1]', dir 1 candidates=a[1]→a[0]'. bwa semantics: BOTH sources
are the ORIGINAL a[0]/a[1] (b[i] snapshotted before any rescue) — accel re-derives each
source deterministically per run, so dir 1's source is the original a[1], not a[1]'.

**RTL.** `accel_pe_pair_top` wraps ONE `accel_pe2_top` (each direction = its own two accel
runs + rescue, host-driven) and adds a RESULT-A snapshot buffer: after dir 0's rescue the
host pulses `snap_a_start` → a small FSM copies a[1]' (via the inner rd_idx/o_* readback)
into an internal buffer; dir 1 then reuses the inner regfile for a[0]'. At the end BOTH
coexist: `res_from_a=1` reads a[1]' (buffer), `res_from_a=0` reads a[0]' (inner live). All
accel data / windows / control are relayed from the host unchanged; only rd_idx/o_*/n_ma are
intercepted for the snapshot + result mux.

**Golden (`gen_pe2pair_vectors.cpp`, `-DMR_DEDUP_INT`).** Parses `accel_vectors.txt`, and per
pair runs `pe.h::matesw_pe_select` TWICE with the original sources (fresh ma copy each
direction; the model never mutates the source), emitting both directions' accel input blocks
+ params + ms + windows + the two expected results (a[1]', a[0]').

**Overflow finding + skip.** First run: 3/94 FAIL, all with expected `n_ma` ≥ 62 (62/70/74),
i.e. the rescue grows the ma list past the on-chip buffer. Root cause: `matesw_orch_top`
no-ops a `mem_matesw` call and raises `overflow` when its entry count exceeds `MA_MAX-4`, but
`matesw_pe_top`/`matesw_pe_sel_top` **don't surface that overflow as a fallback** — they take
the (unchanged) count and continue, so the RTL silently truncates while the uncapped golden
keeps growing. Fixed the TEST by detecting it in the golden: `matesw_pe_select` now reports
`max_entry_ma` (max ma count at entry to any call) and `gen_pe2pair_vectors` skips any pair
where either direction exceeds `MA_MAX-4` — a host SW-fallback case, excluded from the
bit-exact comparison exactly like the sorter's `n>1024`. Result: 91 pairs (3 excluded),
`tb_accel_pe_pair_top: 91 pairs, 0 failures -> ALL PASS`.

**Files.** `rtl/accel_pe_pair_top.sv` (new), `tb/tb_accel_pe_pair_top.sv` (new),
`host/mate_rescue/gen_pe2pair_vectors.cpp` (new), `host/mate_rescue/pe.h` (+`max_entry_ma`),
edits to `host/mate_rescue/Makefile`, `host/mate_rescue/.gitignore`, `scripts/run_sim.sh`.

> **~~KNOWN GAP (logged 2026-06-19)~~ FIXED 2026-07-15: matesw ma-overflow is not surfaced
> as a fallback.** `matesw_orch_top` raises `overflow` (entry ma count > `MA_MAX-4`) and
> no-ops that `mem_matesw` call, but `matesw_pe_top` / `matesw_pe_sel_top` / `accel_pe2_top` /
> `accel_pe_pair_top` neither check `ot_ovf` nor expose an `overflow`/`fallback` output — so an
> oversize rescue is **silently truncated** instead of triggering a host SW redo. Currently
> masked because the closed-loop goldens skip such cases (rare).
>
> **Fixed:** `overflow` is now threaded up the whole stack (mirroring `tie`). The check was
> also **too late** to be correct: `n_ma_init` is an unbounded upstream count (in
> `accel_pe2_top` it is the accel beat count, up to the sorter's 1024), so `P_LDMA` read
> `w_*[k]` past the regfile before `orch_top` ever saw `n_ma_in`. `matesw_pe_top` now checks
> capacity at `cand_start` with `orch_top`'s own predicate. Verified: tb_matesw_pe_top
> 2000/0 + OVF-TEST, and `overflow` asserted low across all 2000 golden cases.
>
> The rate was **not** rare: at the then-current `MA_MAX=64` it was **4.72% of reads** —
> the largest single fallback in the design. `MA_MAX` is now **256** (0.84%). Measurement,
> alternatives, and the deferred block-RAM conversion: `docs/ma_max_sizing_analysis.md`.

## Step 6 — selection-predicate validation on REAL data  ✅ 100000/100000 ends, ALL PASS

**What.** Validated `pe.h`'s candidate selection against real bwa-mem2 on the remote
(ccloud@216.227.218.169, hg38 chr1-5, HG00733 50k read pairs).

**First confirmed by source reading** (`bwamem_pair.cpp`, MATE_SORT=0 build): the selection is
verbatim `pe.h` — `b[i]` = all `a[i].a[j]` with `score >= a[i].a[0].score - opt->pen_unpaired`
(line 749), then rescue `min(b[i].n, opt->max_matesw)` (line 781 loop). Since `a[i]` is
score-sorted desc, that passing set is a contiguous prefix == `pe.h`'s prefix-break + cap.

**Then validated on data.** New minimal capture `host/mate_rescue/capture/sel_capture.inc`
(one hook after the `b[i]` build, env `ALNREG_SEL_OUT`) records, per read pair, the `a[i]`
scores + `pen_unpaired`/`max_matesw` + real `b[i].n`. Validator `host/mate_rescue/check_sel.cpp`
(`make checksel`, self-contained) recomputes `pe.h`'s selection and checks: (1) `b[i].n` ==
count of `score >= top - pen`; (2) that count is a contiguous prefix (i.e. `a[i]` IS
score-sorted desc — the one assumption not provable by source reading); (3) `min(b[i].n,
max_matesw)` matches. Round-trip self-tested first (deliberate unsorted end trips the prefix
check). Remote run: `check_sel: 50000 pairs, 100000 ends (14 empty) | predicate_fail=0
prefix_fail=0 cap_fail=0 | b_total=848568 pe_selected=594747 -> ALL PASS`. The cap fires
meaningfully (848568 gated, 594747 rescued). Remote source reverted to clean `.orig` + rebuilt.

**pe.h selection is now real-data validated** (it had none before — this session's transcription).
`scripts/remote_batched_capture.sh` updated to arm `ALNREG_SEL_OUT` as a 4th capture.

## Step 7 — chaining model validation on REAL data  ⚠️ chain.h NOT bit-exact (2 bugs found)

Ran `chain_capture.inc` on the remote (HG00733 50k pairs, 30000 reads). The capture did its
job — it caught `chain.h` diverging from real bwa-mem2 in exactly the two ways prep predicted:
- **mem_chain: 662/30000 (2.2%)** differ, model chain count < real → the sorted-array
  predecessor / `c_test_and_merge` does not reproduce the kbtree on dup-`pos` cases.
- **mem_chain_flt: 15434/30000 (51%)** differ with EQUAL counts → chain order/content diverges;
  `ks_introsort(mem_flt)` is unstable vs the model's `std::stable_sort` (equal-weight ties).

Both are FIX-before-chaining-RTL items (chaining RTL is gated on chain.h being bit-exact).
Logged in `host/chaining/chain.h` header + `docs/chaining_engine_scope.md`. Remote reverted
clean (both source files). Capture mechanics now fully proven (pull→edit→push→build→run→
validate→revert), including the WSL `~`-expansion gotcha (use absolute `/home/ccloud` paths).

## Step 8 — chain.h fixes (2026-06-19)  ✅ BIT-EXACT (check_capture ALL PASS)

**Final:** `mem_chain_flt: 0 failures`, `mem_chain: 0 non-fallback failures` (dup-pos reads
SW-fallback, ~3-4%). Both fixes below confirmed on a fresh real-data re-capture.

Iterated `chain.h` against the local `chain_vec.bin` (re-validation is local — fast):
- **mem_chain_flt (was 51%):** ported klib `ks_introsort(mem_flt)` VERBATIM (median-of-3,
  threshold-16 quicksort, combsort-on-depth, final insertion sort) replacing `std::stable_sort`
  → fixed the bulk. The 1125 residual was traced to a **capture bug** (not the model):
  `mem_chain_flt` `free()`s dropped chains' seeds (`SEEDS_PER_CHAIN=1`), and HOOK-C's shallow
  snapshot was written after the call → garbage seeds. **Fixed `chain_capture.inc` to deep-copy
  flt input seeds.** The flt model is believed bit-exact; a re-capture will confirm 0.
- **mem_chain (was 2.2% = 662):** two correct fixes → **236 (0.79%)**: (1) predecessor matches
  `kb_intervalp` (exact pos → leftmost equal; else rightmost `pos<key`); (2) insert new chains at
  `lo+1` (the `kb_putp` position) to replicate the kbtree array order for duplicate `pos`.
  **Residual 236 = MULTI-NODE B-tree** cases (mostly order-only, counts match): on tree splits
  (~>9 chains) `kb_intervalp` returns an internal-node separator a single sorted array can't
  reproduce. That order feeds the unstable flt sort, so it matters.

**RESOLVED (Option 1 — SW-fallback):** measured the dup-pos detector — it catches ALL real
divergences (0 misses) and flags ~2.8-3.9% of reads (over-approx of the true ~0.8%). Added a
`fb` flag to `c_mem_chain` (set on a duplicate-pos chain insert; the RTL detects it the same
way) and excluded those reads from the comparison. Re-captured with the fixed HOOK-C and got
`check_capture: ALL PASS` (mem_chain 0 non-fallback, mem_chain_flt 0). chain.h is now the
bit-exact sorted-array reference for the chaining RTL, with the dup-pos SW-fallback (cf.
merge-sorter equal-re tie / accel n>1024). Cost ~0.4% runtime.

## Remaining / deferred

- **Chaining RTL** — STARTED (chain.h bit-exact validated). Decomposition: (1) chain_store
  (mem_chain), (2) chain_weight, (3) chain_introsort (ks_introsort(mem_flt) — can't reuse the
  STABLE merge-sorter; need exact unstable tie order), (4) chain_flt (weight+sort+overlap filter).
  - **chain_store DONE 2026-06-20** (`rtl/chain_store.sv`): sorted-array chain metadata + an
    append-only seed POOL (linked list per chain via head/tail/next), so sorted insert shifts
    only metadata and append is O(1). kb_intervalp predecessor + test_and_merge (contained/
    colinear/strand) + dup-pos `fallback`. Verified vs chain.h::c_mem_chain: tb_chain_store
    4000/0 (incl. fallback + full seed lists). gen_chainstore_vectors + run_sim branch.
    GOTCHA fixed: a `[31:0]` part-select of a signed value is UNSIGNED in SV -> poisoned the
    colinear diffs; use sign-extended 64-bit signed arithmetic throughout.
  - **chain_store REVIEW 2026-06-20** (walkthrough + self-review before commit). Findings:
    F1 (fixed) capacity-overflow was unguarded — `nch>=NCHAIN || pool_n>=NSEED` now raises
    `fallback` (host SW redo) and skips the write, same pattern as accel n>1024 / mate max_entry.
    Directed test added (2nd DUT, NCHAIN=8, 16 non-merging seeds): OVF-TEST PASS, guard fires at
    cap. F2 (fixed) hardened `contained`'s mid comparisons with `$signed(...)` (were unsigned via
    concat — only worked because coords are non-negative). F3 (logged gap) the predecessor is an
    O(NCHAIN) combinational chain — fine at TB's 64, but tanks Fmax at NCHAIN=512; future fix =
    pipelined/binary-search predecessor. F4 done (overflow vector). F5 done (header contract note).
    Re-ran: tb_chain_store 4000/0 + OVF-TEST PASS.
  - **chain_weight DONE 2026-06-20** (`rtl/chain_weight.sv`): mem_chain_weight = two sequential
    coverage passes (query then ref) over a chain's seeds in stream order, each accumulating a
    running `end` max (disjoint -> +len, partial -> +overhang, contained -> +0), then
    w=min(passes) capped at (1<<30)-1. 1 seed/cycle/pass FSM (S_Q/S_R), 64-bit signed math.
    Verified vs chain.h::c_chain_weight: tb_chain_weight 4000/0 (incl. wide-coord cap-path cases).
    gen_chain_weight_vectors + run_sim branch. (gen needed `#include <string>`.)
  - **chain_introsort DONE 2026-06-20** (`rtl/chain_introsort.sv`): klib ks_introsort(mem_flt)
    sorting (w,id) pairs by w DESC, mirroring chain.h::ks_introsort_memflt control flow EXACTLY
    so the UNSTABLE equal-weight tie order is bit-exact (the merge-sorter is STABLE -> can't
    reuse; this tie order was the original real-data chaining divergence). Median-of-3 quicksort
    ({first,last,mid+1}) with an explicit segment stack down to >16 segments, then ONE whole-
    array insertion sort. id = original index (payload tag the TB checks to pin tie order).
    Verified vs chain.h: tb_chain_introsort 4000/0 incl. structured patterns (asc/desc/organ-
    pipe/sawtooth/all-equal). gen_chain_introsort_vectors + run_sim branch. chain.h got an
    additive `bool* comb` out-param (default null) so the generator can flag combsort cases —
    sort logic UNCHANGED (still validated).
    **COMBSORT = SW-FALLBACK:** the depth-limit path runs combsort, whose `gap/=1.2473..` is a
    float divide we can't reproduce bit-exact -> on d==0 the RTL raises `fallback` (host SW redo),
    same pattern as dup-pos/overflow. 335/4000 synthetic cases hit it (RTL raised fallback on all,
    TB verified). **CAVEAT/FOLLOW-UP:** all-equal-weight arrays trip combsort once n>~2*ceil(log2
    n) (degenerate partition), which is NOT purely adversarial — so the real-data combsort/
    fallback RATE is unmeasured and could matter. Options if high: measure on real reads (like
    dup-pos), or implement combsort with VERIFIED fixed-point gap (Rfix=round(2^B/S), prove
    floor(gap*Rfix>>B)==(size_t)(gap/S) for all gap<=NMAX). Replacing the fallback branch with a
    combsort FSM is purely additive — no rework. My synthetic 8.4% is inflated (1/7 cases all-equal).
  - **chain_flt DONE 2026-06-20** (`rtl/chain_flt.sv`): mem_chain_flt POST-SORT stage = the
    greedy overlap/shadow filter + max_chain_extend cap + kept annotation. Operates on chains
    already WEIGHTED + SORTED-by-w-DESC (upstream chain_weight + chain_introsort), each reduced
    to (w, cbeg, cend, isalt). Greedy keptlist: each chain i vs every survivor j — a SIGNIFICANT
    query overlap (>= half smaller span via 2*(e_min-b_max)>=min_l, span<gap, j not-alt-unless-i-
    alt) records a shadow (first[j]=i) and DROPS i if much weaker (2*w_i<w_j && gap>=2*msl).
    Survivors resurrect their first-shadowed (kept=1). kept: 0 drop/1 resurrected/2 overlapped/
    3 primary; chain set = kept!=0. FSM L_CLR/L_OUTER/L_INNER/L_ADD/L_NEXT/L_RES/L_EXT1/L_EXT2.
    Verified vs chain.h::c_chain_flt_post: tb_chain_flt 4000/0 incl. 661 small-mce (cap path) +
    shadow-drop + resurrect. gen_chain_flt_vectors decouples w from span (w set directly, single
    seed carries span). chain.h refactor: extracted c_chain_flt_post (behaviour-identical) so RTL
    + generator share one reference; c_mem_chain_flt now = weight+drop+sort+c_chain_flt_post.
  - **CHAINING RTL UNITS COMPLETE** (4/4): chain_store, chain_weight, chain_introsort, chain_flt
    all bit-exact.
  - **chain_flt_top DONE 2026-06-20** (`rtl/chain_flt_top.sv`): the FULL mem_chain_flt pipeline,
    wiring chain_weight(xN) + chain_introsort + chain_flt into one engine. FSM: WEIGH (stream each
    chain's seeds through chain_weight -> w[ci]; grab cbeg/cend) -> SORT (introsort (w,id) pairs;
    perm[p]=sorted original index) -> GATHER (load sorted metadata into chain_flt) -> FILTER ->
    COMPACT (emit perm[p] for kept[p]!=0). combsort fallback from introsort propagates to the top.
    Sub-units driven combinationally (same-cycle load, no pipeline hazard). Assumes
    min_chain_weight==0 (only value bwa uses) so no pre-sort drop. Verified vs chain.h::
    c_mem_chain_flt: tb_chain_flt_top 4000/0 (surviving chain-id sequence bit-exact), incl. 501
    degenerate combsort cases (descending-weight input, n>=30) where the top correctly raised
    fallback. gen_chain_flt_top_vectors + run_sim branch; chain.h c_mem_chain_flt got an additive
    `bool* comb` out-param. FINDING: combsort needs descending-weight input n>=30 (NOT all-equal —
    those partition balanced); realistic varied-weight reads produced 0 combsort over 3499 cases,
    so the real combsort/fallback rate looks LOW (still warrants a real-data measurement).
  - **chaining_top DONE 2026-06-20** (`rtl/chaining_top.sv`): the COMPLETE chaining stage on chip
    = chain_store (mem_chain) -> chain_flt_top (mem_chain_flt). ADAPTER phase bridges the two: it
    walks chain_store's linked-list seed POOL (per-chain head->next) into chain_flt_top's FLAT
    (offset,count) seed buffer, latching (n_seeds,is_alt,head) per chain. Both sub-blocks reused
    UNMODIFIED. FSM: G_CS_RUN/WAIT -> G_AD_CMETA/G_AD_SEED (adapter walk) -> G_FLT_RUN/WAIT.
    chain_store readback is muxed (adapter during the walk, host otherwise) + passed through so
    the host can fetch surviving chains' data. fallback = chain_store dup-pos OR introsort
    combsort -> whole-read SW redo. Output = surviving chains' chain_store indices (pos-sorted),
    in weight-sorted order. Verified vs chain.h::c_mem_chain_flt(c_mem_chain(...)): tb_chaining_top
    4000/0 (surviving index sequence bit-exact), incl. 1071 combined-fallback cases (dup-pos +
    combsort). gen_chaining_top_vectors (clustered seeds -> dup-pos) + run_sim branch.
  - **CHAINING RTL FULLY COMPLETE end-to-end** (raw seeds -> filtered chains, one block, bit-exact
    vs chain.h).
  - **REAL-DATA VALIDATION DONE 2026-06-20** (on the EXISTING capture vectors/chain_vec.bin = 30000
    real reads, HG00733; no new remote capture needed). check_capture rebuilt against the refactored
    chain.h: **mem_chain 30000 / 0 non-fallback failures, mem_chain_flt 30000 / 0 failures -> ALL
    PASS** — confirms this session's chain.h refactor (c_chain_flt_post extraction + comb params) is
    behaviour-preserving on real data. Added a combsort counter (pass &comb to c_mem_chain_flt).
    **TRUE RTL chaining fallback rate: dup-pos 3.943% (1183/30000) + combsort 0.000% (0/30000).**
    => COMBSORT NEVER FIRES ON REAL DATA (real chain weights are spread; the depth limit needs
    descending-weight n>=30, which doesn't occur) -> the fixed-point-combsort option is NOT needed;
    the combsort fallback path costs ~nothing. Only real chaining fallback is dup-pos (~3.9%).
    **CHAINING STAGE FULLY DONE + REAL-DATA-VALIDATED.**
- **CHAINING -> EXTENSION wiring** (STARTED 2026-06-20). The two stages don't connect directly:
  the extension (orch_read_top) needs per chain {seeds, rid} (from chaining) PLUS rmax0/rmax1 (ref-
  window bounds) + the ref bytes + query. The ref-byte FETCH (bns_fetch_seq over the packed genome)
  is a separate memory subsystem — DEFERRED (user choice); orch_read_top already takes ref bytes as
  an input. The buildable glue is the rmax computation (mem_chain2aln setup).
  - **chain2aln_setup DONE 2026-06-20** (`rtl/chain2aln_setup.sv`, model `host/extend_orchestrator/
    chain2aln.h::c_compute_rmax`): per chain, rmax0=min over seeds of rbeg-(qbeg+cal_max_gap(qbeg)),
    rmax1=max of rbeg+len+(tail+cal_max_gap(tail)), then clamp [0, l_pac<<1] + fwd/rev boundary fix.
    cal_max_gap = integer-exact (ksw.h cal_max_gap_int; 2 signed divisions — needs a divider in a
    real build, fine for sim). MODEL REAL-DATA VALIDATED: check_rmax vs captured rmax in
    ext_vec.bin = **241018 chains / 0 mismatch** (l_pac edge clamps never fired — interior reads).
    RTL vs model: tb_chain2aln_setup 4000/0 incl. small-l_pac clamp+boundary coverage.
  - **chaining_extend_top DONE 2026-06-20** (`rtl/chaining_extend_top.sv`): wires the COMPLETE
    chaining stage into the FULL extend pipeline = chaining_top -> chain2aln_setup -> accel_top
    (extension + compaction + merge-sort). Per surviving chain (weight-sorted): read its
    chain_store index, walk its seed pool (head->next) into a buffer, compute rmax, fetch the ref
    window (DEFERRED genome fetch: top raises ref_req{rbeg,len}, host streams bytes -> forwarded to
    accel r_ld), then drive accel_top (r_ld ref, s_ld seeds, ch_go{n,rid,rmax0,rmax1}). Query
    buffered + replayed. fallback = chaining dup-pos/combsort OR accel equal-re tie/n>1024. Output =
    sorted alnregs via AXI-Stream. All 3 sub-blocks reused UNMODIFIED. Decision record +
    speed/accuracy options for external review: docs/chaining_extension_wiring_options.md.
    END-TO-END verified vs the full software pipeline orchestrate(c_mem_chain_flt(c_mem_chain(seeds)))
    with synthetic genome g(pos)=pos&3 (TB serves the same g on demand from the RTL-provided rmax;
    query built on the primary chain's diagonal so seeds really match -> non-trivial extensions):
    **tb_chaining_extend_top 2000/0 ALL PASS** (incl. 537 fallback + ~1463 non-fallback reads with
    full alnreg records checked). gen_chaining_extend_vectors (chain.h + chain2aln.h + orch.h
    HWMODEL + v2_dedup) + run_sim branch (28 modules). Built on branch accel-wiring (safe revert
    tag pre-accel-wiring-safe); merged to main on success. **CHAINING NOW WIRED INTO THE ACCEL
    EXTEND PIPELINE — raw seeds -> sorted alignment regions, one on-chip block, bit-exact.**
    Remaining for a self-contained pipeline: the on-chip genome-memory subsystem (bns_fetch_seq)
    to replace the deferred ref fetch (see the options doc, Decision B2).
- ~~**orch.h real-data validation**~~ DONE 2026-06-19: orch_capture.inc, 100000 mem_matesw
  calls, `check_orch` ALL PASS (0 non-fallback failures). Found the SAME ks_introsort tie-order
  issue as chaining: `mr_dedup` uses std::stable_sort, real uses unstable ks_introsort → on
  sort-key TIES the surviving identical-key alnreg (its seedcov/order) differs. Fix = additive
  `fb` SW-fallback flag on equal-re / equal-(score,rb,qb) ties (~1.66% of calls, over-approx of
  the true ~0.04%; RTL matesw_dedup detects the same). orch.h transitively validates the SW
  kernel (its only SW is hw_align2). Remote reverted clean.
- **hw.h direct kernel capture** — still un-run (transitively covered by orch.h above; the
  matesw_capture HOOK-A has a seqPairArray-indexing subtlety to resolve first). Lower priority.
- ~~**Propagate the dedup-tie fallback to the RTL matesw_dedup**~~ DONE 2026-06-19: added a
  `tie` output to `matesw_dedup.sv` set on equal-`re` (S_RED_OUT) or equal-(score,rb,qb) (S_ID),
  mirroring orch.h::mr_dedup's `fb`. gen_dedup_vectors emits the expected fb; `tb_matesw_dedup`
  checks `tie==fb` → 6000/0 ALL PASS. The output is left unconnected upstream for now (legal).
- ~~**Thread the `tie` up the matesw stack**~~ DONE 2026-06-20: threaded through matesw_orch_top
  (ORs per-orientation dedup tie), matesw_pe_top (ORs per-candidate, resets at init),
  matesw_pe_sel_top, accel_pe_top, accel_pe2_top, accel_pe_pair_top. Verified at each level by
  emitting the orch.h/pe.h `fb` in the generators and checking `tie==fb`: matesw_orch_top 3000/0,
  matesw_pe_top 2000/0, matesw_pe_sel_top 2000/0, accel_pe2_loop 94/94 (real-accel, tie checked);
  accel_pe_top 200/0, accel_pe2_top, accel_pe_pair_top 91/91 (tie wired, capture/pair tbs).
  The host now has a top-level dedup-tie fallback signal at every accel rescue top.
- ~~(tiny optional) explicit `tie==fb` check at the pair level (gen_pe2pair fb column)~~ DONE
  2026-07-16 for the JOIN's pair top: `gen_chaining_pe2pair_vectors` emits each direction's
  rescue `fb` and `tb_chaining_pe_pair_top` checks `tie==fb` per direction. (Still absent from
  the older `gen_pe2pair_vectors`/`tb_accel_pe_pair_top`, where the pair tie remains the same
  pass-through signal already verified at accel_pe2_loop.)
- **hw.h / orch.h real-data validation** — the mate SW kernel + per-call orchestration captures
  (`matesw_/orch_capture.inc`) still un-run. orch.h transitively covers the kernel (its only SW
  is hw_align2). orch.h's hooks need care: bwamem_pair.cpp has near-duplicate mem_matesw /
  mem_matesw_batch_post, so anchor uniqueness matters. (This session validated selection + chaining.)
- ~~**Both directions**~~ — DONE (Step 5, `accel_pe_pair_top`, 91/91).
- ~~**matesw ma-overflow → fallback**~~ DONE 2026-07-15 (KNOWN GAP above): `overflow`
  threaded up the stack, capacity checked at `cand_start`, `MA_MAX` resized 64 → 256 on
  measured data. See `docs/ma_max_sizing_analysis.md`.
- ~~Oversize-fallback gap (logged in `merge_sorter_v2_design.md`)~~ DONE 2026-07-15:
  `msort_v2_top` now gates its load on `wptr < N_MAX`, saturates instead of wrapping, and
  ends the run in `fallback` with no output beats. (The port comment had always claimed
  `n>N_MAX` was covered; no code implemented it, and `wr_addr = wptr[IDX_W-1:0]` truncated
  11 bits to 10, so record 1024 silently overwrote slot 0. Real data reaches n=1060.)
- **NEW (open): `max_matesw <= NSRC` is an unchecked invariant.** Safe at bwa defaults
  (50 <= 64) and the selection only reads the first `min(n_src, max_matesw)` candidates, so
  `NSRC` needs no fallback — but nothing enforces it. See the "Related: NSRC" section of
  `docs/ma_max_sizing_analysis.md`.

---

## Step 9 — THE JOIN: `chaining_pe2_top` + `chaining_pe_pair_top`  ✅ 2026-07-16

> Numbering note: Steps 1–8 above are the candidate-extraction work (through 2026-06-19); the
> "Remaining / deferred" section sits between them and this step because it was written then and
> is kept updated in place. Step 9 is chronologically last (2026-07-16).

**Why.** The RTL had **two separate integration trees that both sat on `accel_top` but did not
contain each other**:

```
Tree A (front): chaining_top + chain2aln_setup + accel_top    -> chaining_extend_top
Tree B (back):  accel_top + matesw_pe_sel_top                 -> accel_pe2_top -> accel_pe_pair_top
```

So `chaining -> extension -> sort -> mate-rescue` had **never run as one block**. Step 6 fuses
them: substitute `chaining_extend_top` for `accel_top` inside `accel_pe2_top`.

**Why it's mostly interface work.** `chaining_extend_top` and `accel_top` already share an
IDENTICAL output contract — the same `m_axis_tvalid/tdata/tlast/tready` carrying `rec_t`. The
capture FSM's `.m_axis_tready(1'b1)` and its `ac_done` edge-detect both survive the substitution
unchanged. What actually changes:

1. **Input side** — raw seeds + query + `start`/`n_in` (chaining derives the chains itself)
   replace `accel_top`'s pre-chained per-chain drive (`ch_go` / `s_ld` / `rmax`).
2. **Ref fetch** — `rmax` is now computed on chip, so the per-chain window is no longer
   host-known up front: the deferred-fetch handshake (`ref_req` / `ref_in_*`) is plumbed UP
   through pe2 → pair to the host. Swapping in an on-chip genome fetch later (Decision B2 of
   `chaining_extension_wiring_options.md`) touches only these ports.
3. **Run reset** — the run is latched at `start` (was `read_start`).

**Run-reset risk: checked, already safe.** The plan flagged "chaining state must reset cleanly
between the two runs". It does: `chain_store` zeroes `nch`/`pool_n`/`fallback` on its own `start`
pulse (`C_IDLE: if (start)`), and `chaining_top` clears `fallback`/`n_out`. The raw-seed buffer is
bounded by `n_in`, so a shorter run 2 never reads run 1's stale tail. No new logic was needed.
The tbs exercise this hard: 2 runs/case × 200 cases, and 4 runs/pair × 100 pairs.

**Timing note (why the substitution is *safer* than the original).** `accel_pe2_top` captures
`cap_cnt` at the `ac_done` edge, which would race a same-cycle final beat. `chaining_extend_top`
waits for `ac_done` in `E_AXI` and pulses its own `done` a state later, so its `done` sits
strictly later relative to the stream than `accel_top`'s — strictly more margin than the
already-verified `accel_pe2_top`.

### STAGE-SPECIFIC FALLBACK (the user decision — worth more than the MA_MAX bump)

Fallback used to be ONE OR'd bit → the host redid the WHOLE read. Now each stage reports its own:

| bit | stage | raised by | sampled at |
|-----|-------|-----------|------------|
| `fb_chain` | chaining | dup-pos / capacity / combsort depth | `ce_done` (per run) |
| `fb_sort`  | extension+sort | equal-`re` tie / `n > N_MAX` oversize | `ce_done` (per run) |
| `tie`      | rescue | mr_dedup equal-key tie | `sel_done` |
| `overflow` | rescue | ma list > `MA_MAX` | `sel_done` |

`chaining_extend_top` gained `fb_chain`/`fb_sort` outputs (`fallback` kept as their OR for
callers that only need "something needs SW"). A chaining fallback short-circuits the read —
extension never runs — so **`fb_chain=1` implies `fb_sort=0`**; the generator's measured split
confirms it (537 total = 451 chaining + 86 sort, exactly disjoint).

Why it matters: fallbacks are a DIRECT tax, ceiling = `1/(0.476 + 0.524*f)`. Rescue is only 12.5%
of runtime, so redoing just rescue caps its damage at ~0.05x vs ~0.15x for a whole-read redo.

### Verification

- **`gen_chaining_extend_vectors` now emits `fb_chain fb_sort nout`** (was `fb nout`), and
  `tb_chaining_extend_top` checks **each bit independently, not their OR** — attributing a
  fallback to the wrong stage would silently corrupt the read. **2000 cases, 0 failures**
  (451 chaining + 86 sort fallbacks all correctly attributed).
- **`gen_chaining_pe2_vectors`** — same TU-isolation trick as `gen_pe2_vectors`, one stage
  further back: PARSES `chainingext_vectors.txt` (read `i`'s output = candidate source, read
  `!i`'s = entry ma) and runs ONLY `pe.h::matesw_pe_select`. Keeps the chaining and mate-rescue
  headers in separate translation units. Re-emits both reads' RAW-SEED blocks so the RTL
  regenerates the identical source/ma on chip, chaining included. Ref bytes are NOT emitted —
  the TB serves each on-chip `rmax` request from the same synthetic genome `g(pos)=pos&3`.
- **`tb_chaining_pe2_top`: 200 cases, 0 failures** (688 selected rescues).
- **`tb_chaining_pe_pair_top`: 100 pairs** — both directions + result-A snapshot; also checks
  `tie==fb` per direction, closing the logged pair-level follow-on.

**Shared config ports.** `wcfg` / `min_seed_len` / `l_pac` are ONE opt field each in bwa
(`opt->w`, `opt->min_seed_len`, `bns->l_pac`), so the join shares one port rather than
duplicating chaining-side and rescue-side copies. Verified consistent: `MOpt` defaults
(`min_seed_len=19`, `a=1`, `o_del=6`, `e_del=1`, `o_ins=6`, `e_ins=1`) match the chaining
block's `COpt`/`Cfg` exactly. The golden takes `l_pac` from the read block for the same reason.

### The tbs have teeth — two RTL mutation tests (negative controls)

Motivated by the `bsw_top` episode (it passed 9 hand-written cases, then turned out ~19%
over-scored on real data). A green test proves nothing until it has been shown to go red:

| mutant | change | result |
|--------|--------|--------|
| **M1** | `run_cand_r <= 1'b1` (break run routing) | **CAUGHT** — `n_ma_init=0/5, 0/7, 0/1, 0/6`: run 2's beats landed in the source buffer, ma left empty. Proves the routing is checked AND that the ma counts are real on-chip values, not pass-through zeros. |
| **M2** | `s_ma_sc = ce_tdata.score + 1` (corrupt record datapath) | **CAUGHT** — `sc 130/129` on every captured record, and ONLY the score field (`qb`/`qe`/`rb`/`re` still match). Records `ma[3..5]` did NOT fail: those are computed by the on-chip rescue SW core and don't flow through the mutated capture path — the mutation hit exactly the records it should. |

RTL restored byte-identical (md5 verified) after each.

**Files.**
- `rtl/chaining_pe2_top.sv` (new) — the join, one direction.
- `rtl/chaining_pe_pair_top.sv` (new) — both-directions sequencer + result-A snapshot.
- `tb/tb_chaining_pe2_top.sv`, `tb/tb_chaining_pe_pair_top.sv` (new) — each carries the
  concurrent synthetic-genome ref server (`g(pos)=pos&3`) that answers on-chip `ref_req`.
- `host/mate_rescue/gen_chaining_pe2_vectors.cpp`, `gen_chaining_pe2pair_vectors.cpp` (new).
- `rtl/chaining_extend_top.sv` — +`fb_chain`/`fb_sort` outputs; `fallback` becomes their OR
  (a wire now, not a reg — same timing: the stage regs are set on the clock edges the old
  single reg was).
- `host/extend_orchestrator/gen_chaining_extend_vectors.cpp` — emits `fb_chain fb_sort nout`
  (**FORMAT CHANGE**; `chainingext_vectors.txt` must be regenerated) + a stderr breakdown.
- `tb/tb_chaining_extend_top.sv` — parses/checks both bits independently.
- `scripts/run_sim.sh` — `tb_chaining_pe2_top` + `tb_chaining_pe_pair_top` branches, each with
  a TWO-STAGE vector bootstrap (build `chainingext_vectors.txt` first if absent, then the
  pe2/pair vectors via the Makefile).
- `host/mate_rescue/Makefile` — `chainpe2vec` / `chainpe2pairvec` targets.
- `host/mate_rescue/.gitignore` — the two new generator binaries.
- `docs/candidate_extraction_build_log.md` — this step; the pair-level `tie==fb` follow-on
  marked done in "Remaining / deferred".

**Reproduce.** `bash scripts/run_sim.sh tb_chaining_pe2_top` (and `..._pe_pair_top`) — both
bootstrap their vectors. NOTE `run_sim.sh` is mode 644, so invoke it via `bash`, not `./`.
`BSW_BUILD_DIR=/tmp/bsw_reg` lets a second sim run concurrently without clashing on the obj dir.


## Step 10 — CONTIG CLAMP model + 4th capture (Decision C2 of the genome fetch)  ✅ 2026-07-17

**Context.** After the join (Step 9), the user reviewed `docs/genome_fetch_options.md` and chose the
on-chip genome-fetch path: **A1** byte layout to start (→ A2 packed later), **B-i** HBM, **C2** land
the contig clamp FIRST as its own verified step, **D2** prefetch on `rmax`, **E1** no cache. This step
is C2: the clamp is the one genuinely new correctness surface (§3.4 of the options doc), so it is
modelled and proven bit-exact *before* any memory subsystem exists.

**What the clamp is.** The extension does not call raw `bns_get_seq_v2`; it calls **`bns_fetch_seq_v2`**
(`bwamem.cpp:1890`, invoked at `:2172`), which after `chain2aln_setup` produces `rmax[0..1]`:
1. derives the contig `rid = bns_pos2rid(bns_depos(mid, &is_rev))` — binary search over the ascending
   `.ann` offset table (`bntseq.cpp:378`), `mid = c->seeds[0].rbeg`;
2. clamps `[beg,end)` to that contig's `[offset, offset+len)`, flipping both bounds into reverse-strand
   space (`far_beg = 2*l_pac - far_end`, etc.) when `is_rev`.

**Seam.** The caller passes `beg=rmax[0]`, `end=rmax[1]`, `mid=c->seeds[0].rbeg` — and our
`chain2aln_setup` RTL already outputs all three (`rmax0`, `rmax1`, `s0_rbeg = b_rbeg[0]`), so C2 slots
in immediately after it with **no upstream change**. Bonus: the caller does `assert(c->rid == rid)`, so
recomputing `rid` on chip and comparing to the chain's `rid` is a free consistency check / fallback.

**Model.** `host/extend_orchestrator/bns_clamp.h` — line-for-line faithful to those three functions
(`BnsTable`, `bns_depos_m`, `bns_pos2rid_m`, `bns_clamp`, plus `bns_load_ann` to read the contig
table). Validated bit-exact **three ways**:

| golden | how | result | what it proves |
|---|---|---|---|
| directed (`make clamp`) | `test_bns_clamp.cpp`, 6 synthetic + 7 real chr1-5 coords | **13/13** | every edge by hand: no-clamp, run-off-end, start-before-contig, `is_rev` flip, rev clamp, mid==boundary |
| real chr1-5 (`make checkclampreal`) | 4th capture `clamp_vec.bin`, 400k records | **400000/0** | rid-derivation + `is_rev` (193,755 rev) + no-op path on the real distribution |
| synthetic firing (`make checkclamp`) | `clamp_synth.bin`, 16 records | **16/16** | the actual clamp arithmetic vs real bwa: clamped_beg=4, clamped_end=12, rev=8 |

**KEY FINDING — the clamp never fires on real chr1-5.** The 400k capture had `clamped_beg=0,
clamped_end=0`; a firing-only capture (`ALNREG_CLAMP_FIRED=1`) over *all* 50k pairs produced a
**0-byte** file. Reason: chr1-5 are 5 huge contigs whose ends are N-masked telomeres, so no read ever
seeds within a ~280-byte window of a boundary. The clamp is a rare safety net here (it *would* fire on
full hg38's ~3,366 small alt/decoy contigs). So the firing path **cannot** be validated against real
chr1-5 data — hence the synthetic multi-contig genome (`vectors/synth.fa`, 3 non-N contigs 4k/6k/5k;
`synth.fq` boundary reads), which §4-F of the options doc anticipated. This is the same lesson as the
`bsw_top` episode: a rare path that real data doesn't exercise needs a *directed* golden, or it ships
unproven.

**Capture mechanics (all local now — no WSL/SSH hop).** Instrumentation artifact
`host/extend_orchestrator/capture/clamp_capture.inc` = infra block + one hook around `bwamem.cpp:2172`
(snapshot `rmax` before the mutating call, write `beg_out/end_out/rid` + the returned window BYTES
after). Env-gated `ALNREG_CLAMP_OUT` / `ALNREG_CLAMP_MAX` / `ALNREG_CLAMP_FIRED`. The record carries the
bytes so the *same* capture later validates the A1 byte-fetch without re-instrumenting. Flow: apply the
2 edits → `make arch=avx512 EXE=bwa-mem2.avx512bw all -j16` → run with the env vars on `cap_sel/c1.fq`
+`c2.fq` (50k HG00733 pairs, same corpus as `ext_vec`) → `cp bwamem.cpp.orig bwamem.cpp` to REVERT →
rebuild clean. Verified pristine (identical to `.orig`, 0 markers) + clean binary rebuilt.

**Files.** `host/extend_orchestrator/`: `bns_clamp.h` (model), `test_bns_clamp.cpp` (directed),
`check_clamp.cpp` (capture validator), `capture/clamp_capture.inc` (instrumentation), Makefile targets
`clamp` / `checkclamp` / `checkclampreal`, `.gitignore` (keeps the 4 KB `clamp_synth.bin`, drops the
139 MB `clamp_vec.bin` + regenerable synth index files). Committed goldens: `vectors/synth.fa`,
`synth.fq`, `synth.fa.ann`, `clamp_synth.bin`.

**NEXT (Step 11) = the C2 RTL:** contig table in on-chip SRAM (5 entries here; tens of KB for full
hg38) + `bns_pos2rid` binary search + `is_rev` flip + min/max clamp, fed by `chain2aln_setup`, verified
bit-exact vs `bns_clamp.h` over both goldens, then mutation-tested. Host still supplies the ref BYTES
until the A1 fetch datapath lands after C2.


## Step 11 — CONTIG CLAMP RTL (`rtl/bns_clamp_top.sv`)  ✅ 2026-07-17  5536/0, mutation-tested

**Module.** `rtl/bns_clamp_top.sv` — bit-exact to `bns_clamp.h`. FSM `S_IDLE → S_SEARCH → S_CLAMP →
S_DONE`: latch + swap `beg/end`, `bns_depos` (`is_rev` + forward coord `midf`), then an **iterative
`bns_pos2rid` binary search** (one probe per cycle, ~⌈log₂ n_seqs⌉ cycles) over the contig offset
table, then a combinational flip + min/max clamp latched in `S_CLAMP`. Contig table (`offset`,`len`
per contig) in registers, loaded via `tbl_we`; `n_seqs`/`l_pac` held. Inputs are exactly
`chain2aln_setup`'s outputs (`rmax0`=beg, `rmax1`=end, `s0_rbeg`=mid) so it drops in after it with no
upstream change. All math signed 64-bit (`2*l_pac` ≈ 2.1e9 chr1-5 / 6.2e9 full hg38 exceeds 32 bits).
`NCTG` param (8 default; raise + convert `off_r`/`len_r` to SRAM for full hg38's ~3,366 contigs).

**Search faithfulness.** The C loop `while(left<right){ mid=(left+right)>>1; ... } return mid;` is
mirrored exactly, including: the `bm==n_seqs-1` top-edge guard (also guards the `off_r[bm+1]` read
from going OOB), the `left=bm+1` / `right=bm` recurrence, and the "loop-exit returns the last computed
mid" case (`bmid` register). Verified this matters — mutation M2 below.

**Verification.** `tb/tb_bns_clamp_top.sv` + `host/extend_orchestrator/gen_clamp_vectors.cpp` (expected
from `bns_clamp.h` → transitively == bwa). Three table blocks in one run: the synthetic 3-contig table
(firing arithmetic, both strands), a programmatic **deep 64-contig** table (full search depth + every
clamp direction on both strands), and 5000 real chr1-5 records (real distribution + `is_rev` + no-op).
`bash scripts/run_sim.sh tb_bns_clamp_top` → **5536 checks, 0 failures**.

**Mutation-tested** (per the `feedback-verify-by-mutating-rtl` rule; RTL restored byte-identical via
md5 after each):
- **M1 (data)** `ce = min(end_s,fe)` → `ce = end_s` (drop end clamp): **132 fails**, every one on
  `end_out`/`len` ONLY, `beg_out`/`rid`/`rev` correct — exactly the near-end firing records; no-clamp
  records pass. The end-clamp datapath is genuinely exercised.
- **M2 (control)** search init `right = n_seqs` → `n_seqs-1` (last contig unreachable): **896 fails**,
  ALL with true `rid == n_seqs-1` (synth ctgC → resolves to rid 1; deep block → all want rid 63);
  every other contig passes. The binary-search control path is genuinely exercised.

**Files.** `rtl/bns_clamp_top.sv`, `tb/tb_bns_clamp_top.sv`,
`host/extend_orchestrator/gen_clamp_vectors.cpp` (+ Makefile `clampvec`, `.gitignore`,
`scripts/run_sim.sh` `tb_bns_clamp_top` branch). **NEXT = integrate**: wire `bns_clamp_top` between
`chain2aln_setup` and the ref-fetch inside `chaining_extend_top` (clamped `beg/end` feed the window;
host still supplies BYTES), then the A1 byte-fetch (Decision A1) replaces the host behind `ref_req`.
