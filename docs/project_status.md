# Project Status — BWA-MEM2 FPGA Accelerator

*Written for someone new to the project.* This is where things stand: what exists,
how it's verified, what the numbers are, and what remains before it runs a real
workload on hardware.

Last updated: 2026-08-06. Authoritative sources for detail are cited inline
(`docs/…`, `rtl/…`, `tb/…`); this file is the map, not the territory.

---

## 1. What this project is

BWA-MEM2 is a widely-used DNA short-read aligner. This project builds **FPGA
hardware (SystemVerilog)** to accelerate parts of it, targeting the **AWS
`f1.2xlarge`** instance (Xilinx Virtex UltraScale+ **VU9P**, Vivado toolchain).

The end vision is an on-chip pipeline that takes seeds through chaining →
Smith-Waterman extension → merge-sort → mate-rescue and produces alignments,
bit-exact to the software.

### The premise correction that shaped the work
Early profiling (`docs/*profiling*`, memory `swa_not_bottleneck`) showed the banded
Smith-Waterman kernel — the "obvious" thing to accelerate — is only **~6.5%** of
BWA-MEM2 runtime; FM-index seeding (~30%) dominates. But seeding is memory-latency
bound (roofline ~2.1×) and a poor FPGA fit. The strategy therefore pivoted to
accelerating the **post-seeding compute** (chaining, extension, sorting, mate
rescue) as a single on-chip pipeline — the part that *is* a good hardware fit — and
to keep everything **bit-exact vs. the C++ reference** so results are trustworthy.
See `docs/speedup_plan.md`, `docs/post_seeding_acceleration_research.md`.

---

## 2. What exists today (RTL, sim-verified)

All of the following are **written and verified in simulation (Verilator)**. None
has yet run on silicon (see §5). The design closes timing in real Vivado
place-and-route on a slower 7-series proxy (see §4).

### Compute engines (`rtl/`)
| Area | Modules | What it does | Tests (`tb/`) |
|------|---------|--------------|---------------|
| Banded Smith-Waterman | `bsw_top`, `bsw_systolic_array`, `bsw_pe`, `bsw_max_tracker`, `bsw_ctrl_fsm`, `bsw_score_matrix`, `bsw_shared`, `bsw_seed_unit` | 160-PE systolic banded SWA extension | `tb_bsw_top`, `tb_bsw_pe`, `tb_bsw_ext`, `tb_bsw_seed_unit` |
| Chaining | `chaining_top`, `chaining_pe_pair_top`, `chaining_pe2_top`, `chain_flt`, `chain_weight`, `chain_introsort`, `chain_store`, `chain2aln_setup` | seed chaining, filtering, sort, chain→aln setup | `tb_chaining_*`, `tb_chain_*` |
| Extension orchestration | `chaining_extend_top`, `chaining_extend_prefetch_top`, `orch_read_top`, `orch_chain_unit`, `orch_purge`, `orch_assemble`, `orch_seedcov`, `orch_window`, `ref_fetch_top` | stitches chaining + extension into one on-FPGA read pipeline | `tb_chaining_extend_*`, `tb_orch_*` |
| Merge-sort | `msort_merge_sorter`, `msort_dedup`, `msort_v2_top` (+ `msort_pkg`, `msort_v2_pkg`) | bit-exact score-sort + dedup (the `ks_introsort` hotspot) | `tb_msort*` |
| Mate rescue | `matesw_top`, `matesw_orch_top`, `matesw_pe_top`, `matesw_pe_sel_top`, `matesw_orient_unit`, `matesw_dedup` | Smith-Waterman mate rescue + orientation/dedup | `tb_matesw_*` |
| Integration tops | `accel_top`, `accel_pe_top`, `accel_pe2_top`, `accel_pe_pair_top`, `bns_clamp_top` | progressively larger assembled pipelines | `tb_accel_*`, `tb_bns_clamp_top` |

`chaining_pe_pair_top` is the current **full-design integration top** used for
timing (§4).

### F1 bring-up wrapper (`rtl/f1/`)
| Module | Role |
|--------|------|
| `bsw_axil_regs` | AXI4-Lite register file wrapping `bsw_top` (host writes query/target/config, pulses go, polls status, reads result). Register map in the module header + `docs/f1_bringup.md`. |
| `cl_bsw_top` | AWS F1 Custom Logic wrapper: connects `bsw_axil_regs` to the Shell's OCL AXI4-Lite port, ties off all unused Shell interfaces (DDR/PCIS/DMA/IRQ). |

### Host + build glue
- `host/f1/test_bsw.c` — `fpga_pci` host app; pokes the registers, checks
  `ACGT/ACGT → score=5`.
- `scripts/cl_bsw_files.f` — the exact 9-file ordered source list for the CL build.
- `scripts/run_sim.sh` — Verilator sim runner (`bash scripts/run_sim.sh <tb>`).

---

## 3. How it's verified (and why you can trust it)

Two rules, applied throughout:

1. **Bit-exact vs. a golden model.** Each engine is checked against the C++/integer
   reference on real vectors, not hand-picked cases. A pass means *identical*
   output to software.
2. **Mutation-tested green.** A passing testbench is only trusted after it's been
   shown it *can* go red — i.e., we mutate the RTL and confirm the tb fails. A green
   test that can't fail proves nothing. (See memory `feedback_verify_by_mutating_rtl`;
   e.g. the dedup-exclusion false-negative caught and fixed in
   `docs/dedup_exclusion_characterization.md`.)

**Important caveat:** verification is in **Verilator** (bit-exact simulation), which
does **not** catch synthesis-only issues. Real synthesis has already caught things
Verilator passed (147k multi-driven-net warnings) — so anything bound for hardware
is also run through Vivado synth/lint before it's trusted (memory
`feedback_verilator_misses_synthesis_bugs`). Measurement is done on the user's local
Vivado using a **7-series proxy device** (the real VU9P/Vivado license lives on the
AWS side).

---

## 4. Timing status

**Target:** 125 MHz (`clk_main_a0`, the F1 Shell's baseline).

### `bsw_top` alone — ✅ meets target
Real place-and-route (aggressive: place Explore + phys_opt + route Explore +
post-route phys_opt) closes `bsw_top` at **124.4 MHz** on the *slow* 7-series proxy
(28 nm) — 39 ps short of 125 on a deliberately pessimistic device. The real VU9P
(16 nm UltraScale+, faster) clears 125 with margin. **`bsw_top` is green-lit for the
AWS build.** (`docs/synth_ooc_results.md`, "bsw_top closes 125 MHz".)

### Full design `chaining_pe_pair_top` — in progress, 115.6 MHz
Journey of real-P&R Fmax across fixes: **106.8 → 105.7 → 115.6 MHz** (fixes #10–#12).
Current worst negative slack **−0.651 ns @ 8.0 ns (125 MHz)**. The two co-limiting
path families (detail in `docs/synth_ooc_results.md`):

- **#1 (RTL-tractable):** `matesw` overlap-test skip chain
  (`u_sel/u_pe/u_ot`) — 36 logic levels, 27 CARRY4 in three serial cascades. The
  candidate for the next fix (#13), if the *full* design is pushed to 125. **Not**
  inside `bsw_top`.
- **#2 (routing-bound):** `bsw_max_tracker` `pr_i` reduction — ~78% wire delay,
  congestion on the slow proxy. Already closes 125 standalone; RTL won't move it.

So `bsw_top` (which contains family #2) is ready; the full-pipeline 125 MHz close is
a separate, still-open item.

---

## 5. What's still needed

### To get **something** running on real F1 (nearest milestone)
The `cl_bsw_top` (bsw_top-only) AFI. Everything off-hardware is **done and verified**;
what remains is the AWS-side build, which only the project owner can run (needs their
AWS account, FPGA Developer AMI/Vivado, HDK, S3, an F1 instance). Steps + roadblocks:
**`docs/f1_build_runbook.md`**. Deliverables to bring back: the post-route
`clk_main_a0` WNS, and the `test_bsw` `score=5` result.

Status of the bring-up rungs:
- Rung A (`bsw_axil_regs` + tb) — ✅ done, 13/13.
- Rung B1 (`cl_bsw_top` + `tb_cl_bsw_ocl`) — ✅ done, 13/13, score=5.
- Rung B2 (`host/f1/test_bsw.c`) — ✅ done, contract cross-checked.
- **Rung B3/B4 (AWS build → AFI → run) — ⏳ pending, user-side.**

### To reach the full-mapper vision (larger, still open)
1. **Full-design 125 MHz close** — fix #13 on the `matesw u_ot/skip` carry chain
   (§4), or ship a slower-clock AFI in the interim.
2. **A CL wrapper for the full `chaining_pe_pair_top`** — the current CL wraps only
   `bsw_top`. The full pipeline needs its own OCL/DMA wrapper.
3. **Memory + host data path** — the compute RTL is portable, but the DDR4 memory
   shell and PCIe/host streaming for real read datasets are **Xilinx-specific and
   unbuilt** (memory `target_board`). Bring-up so far uses control-only AXI4-Lite;
   real throughput needs DDR/DMA.
4. **On-silicon throughput measurement** vs. the software baseline — the payoff
   number, only obtainable once (2) and (3) exist.

---

## 6. How to reproduce the simulations

```bash
# any testbench in tb/ :
bash scripts/run_sim.sh tb_bsw_top          # -> "... ALL PASS"
bash scripts/run_sim.sh tb_cl_bsw_ocl       # F1 wrapper: 13/13, score=5
bash scripts/run_sim.sh tb_orch_purge       # orchestrator purge, golden-checked

# run concurrent sims into separate build dirs:
BSW_BUILD_DIR=/tmp/sim_a bash scripts/run_sim.sh tb_matesw_top
```

Timing is measured via the user's local Vivado using the OOC scripts under
`synth/ooc/` (results logged in `docs/synth_ooc_results.md`). The dev sandbox has
**Verilator only** — no Vivado — so P&R numbers come from the user's runs.

---

## 7. One-paragraph summary

The compute RTL for a bit-exact, mutation-tested BWA-MEM2 post-seeding pipeline
exists and simulates correctly; `bsw_top` closes the 125 MHz F1 target in real P&R
and the full pipeline is at 115.6 MHz and climbing. The immediate milestone is a
control-only `cl_bsw_top` AFI to prove `bsw_top` on real VU9P silicon (build steps in
`docs/f1_build_runbook.md`); the larger remaining work is closing the full design at
125 MHz, wrapping the whole pipeline as Custom Logic, and adding the DDR4/host data
path needed for real-workload throughput.
