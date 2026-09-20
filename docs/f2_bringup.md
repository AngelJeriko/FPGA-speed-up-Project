# F2 bring-up — what changed from F1, and what is verified

Status as of 2026-09-20. Target moved from **f1.2xlarge / VU9P** to
**f2.6xlarge / AMD Virtex UltraScale+ HBM VU47P** (`xcvu47p-fsvh2892-2-e`).

Everything here was checked against a real checkout of the `f2` branch of
[aws/aws-fpga](https://github.com/aws/aws-fpga), not from documentation summaries.

## The headline: the compute RTL does not change

`bsw_pkg`, `bsw_score_matrix`, `bsw_pe`, `bsw_systolic_array`, `bsw_max_tracker`,
`bsw_ctrl_fsm`, `bsw_top` and `bsw_axil_regs` are all **untouched**. `bsw_axil_regs` is
shell-agnostic — a plain AXI4-Lite slave — so it is **shared** by both CL wrappers. It
moved out of the `f1/` namespace to `rtl/bsw_axil_regs.sv` on 2026-09-20, together with
`host/f1/test_bsw.c` → `host/test_bsw.c`, because filing them under `f1/` made them look
F1-specific and made `rtl/f1/` look safe to delete — deleting it would have broken the
**F2** build. Only the CL wrapper itself is new: `rtl/f2/cl_bsw_top.sv`, plus
`cl_bsw_defines.vh` and `cl_id_defines.vh` beside it.

The F1 path (`rtl/f1/cl_bsw_top.sv`, `scripts/f1/`, `docs/f1_*.md`,
`scripts/cl_bsw_files.f`) is kept and banner-marked **SUPERSEDED**: it is a verified
reference implementation and carries the 2.4 → 125 MHz timing history, but it will not
be re-tested against hardware.

## The one real engineering problem: the clock

On F1 we built at **125 MHz** (`clk_main_a0`, clock recipe A0), which is what the whole
timing-closure campaign (2.4 → 125 MHz) was aimed at.

On F2, from `hdk/docs/Clock_Recipes_User_Guide.md`:

> The `clk_main_a0` is now fixed at 250MHz. It does not support clock recipes or
> dynamic frequency reconfiguration.

Recipes A0/A1/A2 all list `clk_main_a0 = 250 MHz`, and every Shell↔CL interface is
synchronous to it. So the F2 design is one of two shapes:

- **(A)** `bsw_top` closes 250 MHz on VU47P → single clock domain, nothing more to do.
- **(B)** it does not → keep `bsw_axil_regs` on `clk_main_a0` and move only the `u_bsw`
  instance to `clk_extra_a1` (125 MHz on recipe A1), with a CDC between them.

**We do not yet know which.** The only hard timing datum is 124.4 MHz on a Virtex-7 `-2`
proxy (`docs/synth_ooc_results.md`) — a far slower fabric than UltraScale+, so it does
not settle the question either way. `synth/ooc/impl_bsw_top_vu47p.tcl` measures the real
part in minutes and prints which path to take. Run it before the multi-hour DCP build.

If (B): the CDC is cheap because of how `bsw_axil_regs` already works — the host writes
CONFIG/QUERY/TARGET and only *then* pulses GO, so the wide payload (480b query + 3072b
target) is quasi-static by the time it is sampled. Only `req_valid`, `req_ready` and
`result_valid` need synchronising. The extra clocks are **not** shell ports: they come
from an `AWS_CLK_GEN` IP instantiated inside the CL, and
`aws_build_dcp_from_cl.py` hard-errors if a `--clock_recipe_*` is passed without
`--aws_clk_gen`.

## Shell interface deltas (verified against the f2 branch)

| | F1 | F2 |
|---|---|---|
| OCL signal names | `sh_ocl_*` / `ocl_sh_*` | `ocl_cl_*` / `cl_ocl_*` |
| OCL sidebands | — | `ocl_cl_awuser[54:0]`, `ocl_cl_aruser[54:0]` (ignored) |
| DDR tie-off | `unused_ddr_a_b_d_template.inc` + `unused_ddr_c_template.inc` | one `unused_ddr_template.inc` |
| BAR1 | `unused_sh_bar1_template.inc` | **gone** |
| OCL tie-off | — | `unused_sh_ocl_template.inc` (must **not** be included — we drive OCL) |
| CL_NAME | `cl_common_defines.vh` (HDK) | no such file — ours, in `cl_bsw_defines.vh` |
| New CL ports | — | `clk_hbm_ref`, `hbm_apb_*_0/1`, `sh_cl_ddr_stat_*`, `PCIE_EP/RP_*` |
| Build script | `aws_build_dcp_from_cl.sh -clock_recipe_a A0` | `aws_build_dcp_from_cl.py -c cl_bsw_top` |
| AFI creation | `aws ec2 create-fpga-image` | `hdk/scripts/create_afi.py` |
| Vivado | 2021.2-era | 2024.1 / 2024.2 / 2025.1 / 2025.2 |
| Smallest instance | f1.2xlarge | f2.6xlarge |

Two traps worth naming, because neither is documented and both are silent:

1. **`unused_ddr_template.inc` consumes a signal it does not declare** —
   `rst_main_n_sync`. AWS's own `cl_axil_reg_access` example never declares it, so it
   leaks in as an implicit 1-bit wire and holds that example's `sh_ddr` stub in reset
   forever. Harmless there (`DDR_PRESENT=0`), but we declare and drive it properly: our
   reset synchroniser output is *named* `rst_main_n_sync` so the tie-off picks up a real
   synchronised reset.
2. **CL outputs no tie-off covers.** `cl_sh_status0/1/2`, `cl_sh_status_vled`, the pcim
   `ax*` qualifier group, `cl_sh_dma_pcis_ruser`, both HBM APB ports and the PCIe EP/RP
   pins are left floating by the example. We drive them all to 0, following
   `CL_TEMPLATE`. (Derived mechanically: every `output` in `cl_ports.vh` minus everything
   the six included tie-offs drive.)

Unrelated cosmetic issue in AWS's own template, noted so it isn't mistaken for ours:
`unused_pcim_template.inc` assigns `19'b0` to `cl_sh_pcim_awuser`/`aruser`, which are
55 bits wide on F2. It zero-extends; harmless.

## What is verified, and how

| Check | Result |
|---|---|
| `scripts/f2/lint_cl_bsw.sh` — elaborates against the REAL `cl_ports.vh` + tie-offs + AWS's `sh_ddr.stub.sv` | **PASS**, 0 warnings in the wrapper |
| `bash scripts/run_sim.sh tb_cl_bsw_ocl_f2` — functional, through the F2 OCL port set | **13 pass / 0 fail**, golden `ACGT/ACGT → score=5` |
| `scripts/f2/stage_cl_project.sh` dry-run against a real f2 checkout | stages 11 files, symlinks repaired, `encrypt.tcl` + `synth_cl_bsw_top.tcl` rewritten |
| Verilator lint of the **staged** flat project (post include-stripping) | 0 errors, 0 warnings in the wrapper |

### Mutation results (a green check proves nothing until it can go red)

| # | Mutation | Caught by | Result |
|---|---|---|---|
| M1 | one OCL signal reverted to its F1 name | `%Warning-IMPLICIT` (zero-warning policy) | RED |
| M2 | `unused_sh_ocl_template.inc` included | structural guard | RED |
| M3 | `rst_main_n_sync` declaration removed | `%Error-PROCASSWIRE` | RED |
| M4 | a tie-off included twice | structural guard | RED |
| M5 | address slice narrowed to `[14:0]` | `%Warning-WIDTHEXPAND` | RED |
| M6 | reset inverted into `bsw_axil_regs` | lint: **missed**; `tb_cl_bsw_ocl_f2`: watchdog TIMEOUT | RED (by tb) |

M2 is the important one. A mutant that drives `cl_ocl_*` from both our slave and a
tie-off lints **100% clean under Verilator even with `-Wall`** — only Vivado sees it.
That is the same blind spot already recorded in this project's notes ("Verilator misses
synthesis bugs"), so M2/M4 are checked structurally rather than by lint, and the lint
script says so in its header instead of overclaiming.

M6 is the honest limit of the structural lint: it cannot see semantics. That is what
`tb_cl_bsw_ocl_f2` is for.

## Not yet done

- **The VU47P timing measurement** — the (A)/(B) decision above. Nothing else should be
  built until this is known.
- Path (B)'s CDC + `AWS_CLK_GEN` instantiation, if the measurement calls for it.
- Everything from the DCP build onward (phases 2–4): needs AWS.

## Strategic note: HBM

Each F2 FPGA carries 16 GB of HBM. The project's standing conclusion is that banded SWA
is only ~6.5% of bwa-mem2 runtime while FM-index seeding is ~30% and memory-bound, and
the seeder was set aside partly on a DDR-bandwidth roofline argument
(`docs/post_seeding_acceleration_research.md`, `project_bwa_mem2_acceleration_strategy`).
HBM changes that arithmetic. Out of scope for bring-up; worth revisiting once silicon
works.
