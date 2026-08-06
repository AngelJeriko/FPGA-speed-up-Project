# AWS F1 bring-up (board-bringup branch)

Goal: get **one kernel running on a real F1 (VU9P) FPGA** through the smallest
possible path, disregarding speedup. This is the plumbing track; it runs in
parallel with the timing track on `main`.

> **Status update (2026-08-06):** the board-bringup work described here is **now merged
> into `main`** (Track B files `rtl/f1/*.sv`, `host/f1/test_bsw.c`, `scripts/cl_bsw_files.f`).
> The historical text below is kept for context; see `docs/project_status.md` for the
> current state and `docs/f1_build_runbook.md` for the build steps.

## The path: Custom Logic (CL) + AWS Shell

On F1 you don't get raw board pins. Your kernel is **Custom Logic (CL)** that
plugs into the fixed **AWS Shell (SH)** via the `aws-fpga` HDK, and you talk to it
from the host over PCIe. The minimal control path is the Shell's **OCL AXI4-Lite**
port (a BAR the host peeks/pokes) — **no DDR4, no PCIe DMA needed** for a first
test. Build flow:

    aws_build_dcp_from_cl.sh  ->  DCP  ->  S3  ->  aws ec2 create-fpga-image  ->  AFI
    (on a running f1.2xlarge)  fpga-load-local-image  +  a host app using fpga_pci

## Rung A — what is built + verified here (no AWS needed yet)

| File | Role | Status |
|------|------|--------|
| `rtl/f1/bsw_axil_regs.sv` | AXI4-Lite register file wrapping `bsw_top` | ✅ built |
| `tb/tb_bsw_axil.sv` | Verilator tb: drives AXI-Lite, checks vs a bare `bsw_top` | ✅ 13/13 pass |

`bsw_axil_regs` marshals a query/target/config written over AXI-Lite into
`bsw_top`'s wide parallel ports, pulses the request, and captures the result for
read-back. The testbench proves the wrapper is **transparent**: the same vectors
run through the AXI-Lite path (DUT) and directly into a bare `bsw_top` (REF)
produce identical results (`ACGT/ACGT -> score=5`, matches `tb_bsw_top`), and a
marshalling mutation (swapped query words) makes it go red (4/13 fail). Run it:

    bash scripts/run_sim.sh tb_bsw_axil     # -> "13 pass, 0 fail / PASS"

### Register map (byte offsets in the OCL BAR)

| Offset | Reg | Acc | Contents |
|--------|-----|-----|----------|
| `0x000` | CONTROL | W | bit0 = go (self-clearing pulse) |
| `0x004` | STATUS  | R | bit0 busy, bit1 done, bit2 error |
| `0x010`..`0x023` | CONFIG | W | `bsw_config_t`, 5 words LSW-first (h0,o_del,e_del,o_ins,e_ins,zdrop,end_bonus,w,qlen,tlen) |
| `0x100`..`0x138` | QUERY  | W | 160 bases x 3b = 480b -> 15 words |
| `0x200`..`0x37C` | TARGET | W | 1024 bases x 3b = 3072b -> 96 words |
| `0x400`..`0x40C` | RESULT | R | `bsw_result_t`, 4 words LSW-first (error,score,gscore,qle,tle,gtle,max_off) |

Host sequence: write CONFIG + QUERY + TARGET, write CONTROL=1, poll STATUS until
bit1 (done), read RESULT.

## Build-out status (updated 2026-08-06)

The three items below were "not built" when this doc was first written; items 1 and 2
are now **built and verified**, and item 3 is fully documented and waiting only on the
user-side AWS run. See the Progress Update section further down for the verification
detail, and `docs/f1_build_runbook.md` for the step-by-step build.

1. ✅ **`cl_bsw_top.sv`** — the CL wrapper (OCL AXI4-Lite → `bsw_axil_regs`, all unused
   Shell IFs tied off via the `cl_hello_world` template). Verified: `tb_cl_bsw_ocl`
   13/13, score=5.
2. ✅ **Host app** (`host/f1/test_bsw.c`) — `fpga_pci` peek/poke; host↔RTL contract
   cross-checked; built-in `score=5` golden self-check.
3. ⏳ **Build harness** — `aws_build_dcp_from_cl.sh -clock_recipe_a A0` → AFI. Steps +
   roadblocks in `docs/f1_build_runbook.md`. **Needs your AWS account + FPGA Developer
   AMI + S3 + an F1 instance** — the only remaining step.

## The one hard prerequisite: 125 MHz

The Shell's main clock `clk_main_a0` is **125 MHz** in its slowest common recipe.
The kernel must **close timing at ≥125 MHz post-place-and-route** to load and run
at all. **CLEARED (2026-08-02):** real P&R closed bsw_top at 124.4 MHz / −39 ps on the
slow 7-series proxy → the faster VU9P clears 125 with margin (see the cleared-prerequisite
note below). (Escape hatch, no longer needed: a slower divided CL clock, at the cost of a
CDC.)

---

## Progress update (2026-08-01) — B1 + B2 built & verified

- **B1 DONE — `rtl/f1/cl_bsw_top.sv`**: the CL wrapper. OCL AXI4-Lite → `bsw_axil_regs`;
  all other Shell IFs tied off via the HDK `unused_*_template.inc` includes (cl_hello_world
  pattern, so it tracks the user's HDK version); rst_main_n → CL reset synchroniser.
  Verified: `tb_cl_bsw_ocl` drives the exact OCL port set (sh_ocl_*/ocl_sh_*), DUT vs bare
  bsw_top REF → **13/13, ACGT/ACGT→score=5**. (`+define+CL_BSW_LINT` gives a self-contained
  OCL port list so the glue sims without the HDK; the real build uses the HDK includes.)
- **B2 DONE — `host/f1/test_bsw.c`**: `fpga_pci` peek/poke host. Marshals query/target/config
  into the 32-bit word registers (layout mirrors bsw_axil_regs + bsw_pkg packed structs, and
  was round-trip-checked in C against the RTL bit ranges), pulses GO, polls STATUS, reads the
  result. Built-in golden self-check: ACGT/ACGT must return **score=5**.

### ✅ 125 MHz prerequisite — CLEARED (2026-08-02)
`synth/ooc/impl_bsw_top.tcl` real place-and-route (aggressive: place Explore + phys_opt +
route Explore + post-route phys_opt) closed bsw_top at **124.4 MHz — just 39 ps short of 125
on the SLOW 7-series proxy (28 nm)**. The real VU9P (16 nm UltraScale+, faster fabric) plus
AWS's default build strategies clear 125 with margin. **bsw_top is green-lit for the AWS
build.** (See docs/synth_ooc_results.md "bsw_top closes 125 MHz".)

### Remaining (needs AWS + Vivado + HDK — user side)

**Pre-flight (do these before spending build time):**
1. **Source list** — enumerate the CL RTL from **`scripts/cl_bsw_files.f`** (the exact 9-file
   ordered set: bsw_pkg → compute core → bsw_axil_regs → cl_bsw_top, +incdir rtl rtl/f1).
   Do NOT use the old `scripts/file_list.f` (targets plain bsw_top, omits rtl/f1/*, pulls the
   unused axis adapter). A missing module here fails elaboration hours in.
2. **Clock** — `-clock_recipe_a A0` = 125 MHz `clk_main_a0` (verify against
   `$HDK_DIR/docs/clock_recipes.md`; A1 is 250 MHz). The kernel is single-clock (the
   whole chain runs on `clk_main_a0`; the only sequential element outside it is the 2-FF reset
   synchroniser) — **no CDC constraints needed**.
3. **IDs** — set `CL_SH_ID0/1` in `cl_id_defines.vh` for your AFI.
4. **Host↔CL contract** — VERIFIED by static cross-check of test_bsw.c against bsw_axil_regs.sv
   + bsw_pkg (offsets, the 0x2xx/0x3xx target `addr[8]` split, and the result unpack
   error[96]…max_off[15:0] with 16-bit fields all line up). If the AFI builds, `score=5` is
   wired to the right bits — no host rework expected.

**B3 — build the DCP:** drop `rtl/` into `$CL_DIR/design`, wire the sources per (1) above, then
`cd $CL_DIR/build/scripts && aws_build_dcp_from_cl.sh -clock_recipe_a A0`.
- **⚠️ TIMING GATE — check BEFORE creating the AFI.** The build's own post-route
  `*.timing_summary` (in `$CL_DIR/build/reports/`) must show **0 failing endpoints / WNS ≥ 0 on
  `clk_main_a0`**. If it fails there, the AFI would load but the kernel would be metastable —
  stop and fix timing first. AFI ingestion (B4) takes ~1 hr, so this gate saves a wasted round-trip.

**B4 — DCP → AFI → run:** `create-fpga-image` (DCP → S3 → AGFI, ~1 hr) →
`fpga-load-local-image -S 0 -I <agfi>` → `sudo ./test_bsw`. Expect
`GOLDEN OK (ACGT/ACGT -> score=5)`. Anything else = layout/AFI mismatch (re-check the source
list and that the loaded AGFI is the one you just built).
