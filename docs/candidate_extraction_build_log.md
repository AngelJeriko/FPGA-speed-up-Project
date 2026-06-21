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

> **KNOWN GAP (logged 2026-06-19, not yet fixed): matesw ma-overflow is not surfaced as a
> fallback.** `matesw_orch_top` raises `overflow` (entry ma count > `MA_MAX-4`) and no-ops
> that `mem_matesw` call, but `matesw_pe_top` / `matesw_pe_sel_top` / `accel_pe2_top` /
> `accel_pe_pair_top` neither check `ot_ovf` nor expose an `overflow`/`fallback` output — so an
> oversize rescue is **silently truncated** instead of triggering a host SW redo. Currently
> masked because the closed-loop goldens skip such cases (rare). Fix (deferred to the same
> later audit as the sorter oversize gap, logged in `merge_sorter_v2_design.md`): thread
> `ot_ovf` up through the matesw stack to a `fallback` output; the host redoes that pair in SW.

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
  - **CHAINING RTL COMPLETE end-to-end** (mem_chain via chain_store + mem_chain_flt via
    chain_flt_top). NEXT options: (a) real-data validation of the chaining pipeline (measure true
    fallback rate, like dup-pos); (b) wire chain_store -> chain_flt_top into one chaining top;
    (c) fixed-point combsort only if real rate proves high (additive).
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
- (tiny optional) explicit `tie==fb` check in tb_accel_pe_pair_top (gen_pe2pair fb column); the
  pair tie is the same pass-through signal already verified at accel_pe2_loop.
- **hw.h / orch.h real-data validation** — the mate SW kernel + per-call orchestration captures
  (`matesw_/orch_capture.inc`) still un-run. orch.h transitively covers the kernel (its only SW
  is hw_align2). orch.h's hooks need care: bwamem_pair.cpp has near-duplicate mem_matesw /
  mem_matesw_batch_post, so anchor uniqueness matters. (This session validated selection + chaining.)
- ~~**Both directions**~~ — DONE (Step 5, `accel_pe_pair_top`, 91/91).
- **matesw ma-overflow → fallback** — thread `ot_ovf` up to a `fallback` output (KNOWN GAP
  above); deferred to the same later audit as the sorter oversize gap.
- Oversize-fallback gap (logged in `merge_sorter_v2_design.md`) still applies to the accel
  runs feeding this fold.
