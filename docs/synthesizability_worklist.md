# Synthesizability worklist — combinational-read memories (VU9P / AWS F1)

> **UPDATE 2026-07-30 — the measured system critical path was NOT on this list.**
> `report_timing` on `chaining_pe_pair_top` showed all 20 worst paths (−406 ns) were a
> 160-deep combinational cumulative-subtract LADDER in `bsw_ctrl_fsm.sv` (`eh_init[j]`
> first-row boundary), a prefix-scan anti-pattern distinct from the register-file mux trees
> below. **FIXED** with a parallel closed form (bit-exact, tb_bsw_ext 15887/0; see
> `synth_ooc_results.md`). The items below remain the **AREA** problem (1.09M LUT) and are
> the likely NEXT timing paths — but re-synth `chaining_pe_pair_top` to confirm the new Fmax
> and worst path before assuming their static ranking is the timing order.

Tree-wide RTL sweep (2026-07-28). The design is Verilator-verified but never synthesized.
The dominant issue is **combinational array reads** → they infer DEPTH:1 LUT mux trees
(a register file), which burns flops AND (when the read feeds arithmetic in the same
cycle) creates long combinational paths that won't close timing at an F1 clock.

Fix pattern is already proven in this tree: **registered-read BRAM + FSM wait state(s)**
— see `bns_clamp_top.sv` (off_mem/len_mem) and `msort_v2_top.sv` (bankA/bankB ping-pong).

Severity metric = DEPTH × simultaneous-distinct-reads × feeds-arithmetic.
Priority = fix top-of-list first; MEASURE each with local OOC synth (proxy US+ part).

| # | file | array(s) | depth | simul-reads | feeds-arith | sev | fix |
|---|------|----------|------:|:-----------:|:-----------:|-----|-----|
| 1 | chain_store.sv | c_pos (+in_rbeg broadcast) | 512 | 512 (comb scan) | YES (512 `<`, adds/subs) | HIGH | replace kb_intervalp linear predecessor with sequential binary-search FSM over registered-read BRAM |
| 2 | bsw_max_tracker.sv | row_m/mj/idx/vld_pipe | 160 | 160 (comb scan) | YES (zdrop mul/sub/cmp, gscore, argmax) | HIGH | index by tail_idx (registered read), register selected tail before zdrop arith |
| 3 | matesw_dedup.sv | rb/re/qb/qe/rid | 256 | 3 (i,j,rd_idx) | YES (**64-bit multiply** 20*or_>19*mr_) | HIGH | sequence O(n²) redundancy test one index/cycle from BRAM; register operands ahead of multiplier |
| 4 | chain_flt.sv | cw/cb/ce/calt | 512 | 2 (i,jj) | YES (max/min, 2*(e-b), subs) | HIGH | read [i] then [jj] on successive cycles, or dup for 2 ports |
| 5 | chain_introsort.sv | aw | 512 | 3 (s,t,mid) | YES (median-of-3 cmp) | HIGH | latch 3 pivots over 3 cycles; compare-only (milder than #3) |
| 6 | orch_purge.sv | av_qb/av_qe | 1024 | 2 (rd_idx,i) | YES (contained/toolong) | HIGH | true-dual-port BRAM or duplicate; register compare operands |
| 7 | chain_store.sv | c_rid/c_fq/c_lq/c_lr/c_ll | 512 | 1 | YES (test_and_merge) | MED | registered-read RAM |
| 8 | orch_purge.sv | av_rb/re/w/sl0, sd_* | 1024 | 1 | YES | MED | registered-read BRAM (~426 Kib flops today) |
| 9 | chain_store.sv | in_rbeg | 2048 | 1 (fans to 512 cmps) | YES | MED | folds into #1 |
| 10 | chain2aln_setup.sv | b_rbeg/qbeg/len | 256 | 1 (j) | YES (cmg mul/div) | MED | register read; pipeline mul/div |
| 11 | orch_purge.sv | sd_score, srt2 (array-indexed-by-array) | 1024/128 | 1 | YES | MED | register the 2-stage lookup |
| 12 | matesw_orch_top.sv | m_rb (+m_* cluster) | 256 | 1 (ii) | YES (skip-scan) | MED | register read |
| 13 | chain_flt_top.sv | sd_*, c_off | 256/64 | 1 | YES (addr/coord add) | MED | register read |
| 14 | chain_weight.sv | b_qbeg/len/rbeg | 64 | 1 (j) | YES | MED | register read |
| 15 | matesw_pe_sel_top.sv | s_sc | 64 | ≤2 | YES | LOW | register read |
| 16 | orch_read_top.sv | av_* (9 arrays) | 1024 | 1 (rd_idx) | NO | LOW/area | pure output mux, ~327 Kib flops + 8×(1024:1) mux → biggest no-arith AREA win |
| 17 | matesw_pe_top.sv | w_rb..w_cov (7) | 256 | ≤2 | NO | LOW | registered-read RAM (plumbing) |
| 18 | accel/chaining_pe_pair_top.sv | a_rb..a_cov (7) | 256 | 1 (rd_idx) | NO | LOW | register read |
| 19 | chaining_extend_prefetch_top.sv | win_buf[2][1024] | 2048 | 1 + concurrent write | NO | LOW | ping-pong → true-dual-port BRAM, register read addr |
| 20 | chaining_extend_top.sv | sb_rbeg | 64 | 2 | NO | LOW | small dual-index |

**Category flop-burn (should be BRAM):** chain_store ≈991 Kib (c_pos is the blocker),
orch_purge ≈426 Kib, orch_read_top ≈327 Kib (no-arith, easy).

**Clean categories:** no unsized large literals; `$display` (`ifdef MOT_TRACE`) and `$error`
(`translate_off`) both guarded/safe; no latches in spot checks; sync reset except
bns_clamp_top/ref_fetch_top (async — normalize later, not a blocker).
Recommend a `verilator --lint-only -Wall` + Vivado `-Wlatch` elaboration pass before sign-off.

**Already DONE (templates):** bns_clamp_top, msort_v2_top, msort_merge_sorter, msort_dedup,
bsw_seed_unit — all registered-read BRAM, clean.

**Order of attack (measure each via local OOC synth):** #1 chain_store:c_pos → #2 bsw_max_tracker
→ #3 matesw_dedup → #4 chain_flt → #5 chain_introsort → #6/#8/#11 orch_purge → the MED single-index
mechanical ones → #16 orch_read_top (area) → prefetch win_buf (#19, only if the variant is adopted).
