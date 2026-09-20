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
not settle the question either way. `synth/ooc/impl_bsw_top_f2.tcl` measures the real
part in minutes and prints which path to take. Run it before the multi-hour DCP build.

**Both paths are now built and verified**, so the measurement selects a path rather than
starting one. Path (B) is `rtl/bsw_kernel_cdc.sv` — see the next section.

## Path (B): the clock-domain crossing

`bsw_kernel_cdc` is a **drop-in replacement for `bsw_top`**: same ports, same handshake,
plus a second clock/reset pair. `bsw_axil_regs` chooses between them with its
`KERNEL_CDC` parameter, so the single-clock path stays bit-identical to what F1 shipped
and the register file itself does not change shape either way.

It uses a **two-phase (toggle) request/acknowledge handshake with a quasi-static
payload** — the standard structure when the data is wide and the events are rare. The
payload here is 480b of query plus 3072b of target: far too wide for an async FIFO to be
worth it, and it changes once per request.

The payload may cross without synchronisers because it is provably quiet for the whole
window the far side can see it: it is registered one *full cycle* before the request
toggle flips (the `A_SEND` state exists only to create that gap), the toggle then needs
at least two destination edges to clear its synchroniser, and it cannot be rewritten
until the acknowledge has made the return trip. The same argument runs in reverse for
the result. Only the two toggles are genuine asynchronous inputs, and each gets its own
2-flop synchroniser carrying `ASYNC_REG`.

Pending flags (`req_pend_k` / `ack_pend_a`) latch each edge. In steady state neither
side can miss one, but the two domains leave reset at different times, and a toggle that
flips while the far synchroniser is still reset would otherwise be lost and deadlock the
handshake. The flags make that impossible rather than merely unlikely.

Turning it on: `scripts/f2/stage_cl_project.sh --clk-gen`, which defines
`BSW_KERNEL_CDC`, adds `rtl/bsw_kernel_cdc.sv`, installs
`scripts/f2/cl_timing_user_cdc.xdc` and builds with `--aws_clk_gen --clock_recipe_a A1`.
The extra clocks are **not** shell ports — they come from an `AWS_CLK_GEN` IP
instantiated inside the CL, whose AXI-Lite control port we hang off the **SDA**
interface (MgmtPF BAR4), exactly as AWS's own `cl_mem_perf` example does. That leaves
our OCL BAR entirely to `bsw_axil_regs`. Note `aws_build_dcp_from_cl.py` hard-errors if
a `--clock_recipe_*` is passed without `--aws_clk_gen`.

### What the verification does and does not prove

`tb_bsw_axil_cdc` runs the DUT (kernel on a second clock) against a bare `bsw_top` on
the main clock and requires **identical** results — 23/23. The clocks are deliberately
hostile: 10 ns vs 17 ns, asynchronous and **non-harmonic** so the phase relationship
walks across every vector instead of repeating, with `clk_k` phase-offset and `rst_k_n`
released on a different edge from `rst_n`.

That proves the **protocol**: no lost requests, no lost results, no deadlock, no stale
payload, across a walking phase relationship and reset skew. It does **not** model
metastability — that rests on the 2-flop synchronisers, `ASYNC_REG`, and the XDC, none
of which a simulator can check. Worth stating plainly rather than letting 23/23 imply
more than it does.

One honest gap: the payload *hold* registers are not load-bearing for this particular
front end, because `bsw_axil_regs` already holds query/target/config stable across a
request. Removing them would still pass the testbench. They are there for timing margin
across the crossing — the thing the XDC constrains — not for functional correctness
here, and a future front end that streams its payload would need them.

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
| `scripts/f2/lint_cl_bsw.sh --cdc` — same, for the two-clock build (AWS_CLK_GEN stub) | **PASS**, 0 warnings in the wrapper |
| `bash scripts/run_sim.sh tb_bsw_axil_cdc` — kernel on a second, non-harmonic clock | **23 pass / 0 fail** |
| Staged two-clock project (`--clk-gen`) re-linted flat | 0 errors, 0 warnings in the wrapper |
| **Real Vivado synthesis of the whole CL** (`synth/ooc/synth_cl_bsw_f2.tcl`, 2026-09-20) | **PASS — no multiply-driven nets** |

### First real synthesis of the F2 CL (2026-09-20)

Vivado 2026.1, `synth_design -mode out_of_context`, device `xc7v2000t-2` (the local
install has no UltraScale+ families, so the harness fell back — see below).

| | cl_bsw_top (single-clock) |
|---|---|
| LUTs | 63,985 (0 as memory) |
| Registers | 31,308 (all flip-flops, no latches) |
| DSPs | 140 (DSP48E1) |
| Block RAM | **0** |
| CARRY4 | 10,055 |
| MUXF7 / MUXF8 | 720 / 342 |

**It found a real defect**, which is the point of running it: `tdo` — the Virtual-JTAG
output in `cl_ports.vh` — was **undriven**. We don't instantiate `cl_debug_bridge`, and
I enumerated `tdo` in the undriven-outputs analysis but then failed to drive it, unlike
`CL_TEMPLATE` which does `tdo = 'b0`. Vivado caught it as `CRITICAL WARNING
[Synth 8-3848]`. Fixed, along with the lint that should have caught it: `UNDRIVEN` was
simply not enabled there, and Verilator attributes such warnings to `cl_ports.vh` rather
than to our file, so the wrapper-scoped filter would have missed them anyway. Both are
fixed and mutation-checked (M7/M8 below).

**The result that was asked for: no multiply-driven nets.** `[Synth 8-3352]` is escalated to
an ERROR before `synth_design`, so synthesis completing at all *is* the verdict. That
closes the one fault class Verilator provably cannot see (mutation M2), and it is now
closed on real tooling rather than by argument.

### The four critical warnings, resolved

| # | Message | Verdict |
|---|---|---|
| 1 | `[Synth 8-3848]` net `tdo` has no driver | **ours — real, fixed** |
| 2–3 | `[Synth 8-4442]` BlackBox `SH_DDR` has unconnected pin `cl_sh_ddr_axi_awuser` / `aruser` | **AWS's**, benign |
| 4 | `[Project 1-486]` could not resolve black box `sh_ddr` | expected, benign |

2–4 are all the DDR stub. AWS's own `unused_ddr_template.inc` connects 58 of the 60
ports `sh_ddr` declares — it omits `cl_sh_ddr_axi_awuser` and `aruser` (also reported as
`[Synth 8-7023]` "60 connections declared, but only 58 given"). That is an inconsistency
inside the F2 kit, not in our code, and it is harmless with `DDR_PRESENT=0`: they are
inputs to a block that is switched off. `[Project 1-486]` is likewise expected —
`sh_ddr.stub.sv` has an empty body by design, so it cannot resolve and should not.

### The 8,689 warnings, resolved

They collapse to **six distinct causes**, none of them defects. Note the log only prints
the first 100 of each ID, so the log-derived counts cap at 100 while the true totals are
much larger — one line in `bsw_pe` becomes a warning per PE, and there are 160 PEs.

| Cause | What it is |
|---|---|
| `Synth 8-7129` port unconnected / no load (e.g. `qlen_i[15]`) | unused high bits of sized ports; the bulk of the 8,689 |
| `Synth 8-3917` port driven by constant 0 (e.g. `cl_sh_flr_done`) | every tie-off, by definition — a CL that ties off the whole Shell will always produce these |
| `Synth 8-11067` package parameter treated as localparam (18) | `bsw_pkg` style; cosmetic |
| `Synth 8-6014` unused sequential element removed (3) | **consistent with a documented finding** — `cfg_q_reg[end_bonus]` was optimised away, matching `docs/zdrop_characterization.md`: `zdrop`/`end_bonus` are inert in the unbanded engine. Synthesis independently confirmed it |
| `Synth 8-7071` / `8-7023` sh_ddr port count (3) | the AWS template mismatch above |

Reading the rest honestly:

- **`sh_ddr` reported as a black box is correct**, not a problem. AWS's own
  `sh_ddr.stub.sv` has an empty body by design; we only need its port list so the DDR
  tie-off elaborates.
- **0 BRAM, 0 LUT-as-memory.** The whole CL is flops and logic. The register file's
  ~3,840 bits of query/target/config land in flip-flops, which matches the delta from
  `bsw_top` alone (27,370 → 31,308 FF). Fine at this size, and it means none of the
  earlier distributed-RAM traps apply here.
- **Do not compare these LUTs to the 71,320 in `bsw_top_impl_util.rpt`.** That figure is
  post-place-and-route with `Explore` directives and a 3.0 ns clock constraint; this run
  is synthesis-only with **no clock constraint at all**, so nothing was timing-driven.
  Different question, different answer — a ±10% gap between the two says nothing.
- **Timing from this run is meaningless** and the script says so. `impl_bsw_top_f2.tcl`
  is what answers the 250 MHz question.
- **Device fell back to Virtex-7.** `xcku5p` and `xczu7ev` are not installed in that
  Vivado (`get_parts -quiet xcku5p*` returned nothing), confirming why every earlier
  report says `Device: 7v2000t`. Irrelevant for a multi-driver check, which is
  device-independent; decisive for the timing run, which still needs the UltraScale+
  families installed.

At ~64K LUTs the CL is a few percent of an F1-class VU9P (~1.18M LUTs) and smaller
still relative to VU47P, so fit inside the CL region is not a concern.
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
| M7 | `tdo` driver removed (reproduces the real defect) | `%Warning-UNDRIVEN` on `cl_ports.vh` | RED |
| M8 | a PCIe output driver removed | same gate | RED |

M7/M8 were added *after* real synthesis found the `tdo` bug the lint had missed. The
gate fails on any undriven signal declared in `cl_ports.vh`, with exactly two
allowlisted: `cl_sh_dma_pcis_bid` and `..._rid`, which AWS's own tie-off drives as
`[5:0]` of a 16-bit port.

M2 is the important one. A mutant that drives `cl_ocl_*` from both our slave and a
tie-off lints **100% clean under Verilator even with `-Wall`** — only Vivado sees it.
That is the same blind spot already recorded in this project's notes ("Verilator misses
synthesis bugs"), so M2/M4 are checked structurally rather than by lint, and the lint
script says so in its header instead of overclaiming.

M6 is the honest limit of the structural lint: it cannot see semantics. That is what
`tb_cl_bsw_ocl_f2` is for.

### Mutation results for the crossing (`tb_bsw_axil_cdc`)

| # | Mutation | Result |
|---|---|---|
| C-B | kernel never acknowledges (`ack_tgl_k` frozen) | **RED** — watchdog TIMEOUT, so the acknowledge path is load-bearing |
| C-C | result never captured in the K domain | **RED** — 0 pass / 23 fail, so the result crossing is load-bearing |
| C-E | K side stops waiting for `bsw_top`'s `req_ready` | **GREEN — equivalent mutant** |

C-E deserves the honesty rather than a quiet omission. It passes because
`bsw_ctrl_fsm` drives `req_ready_o = (state == S_IDLE) || …`, and the K side only ever
issues a request when the kernel *is* idle — so ready is already high on the cycle we
assert valid, and the transfer completes either way. Waiting for it is correct defensive
coding that this configuration cannot distinguish from not waiting. A mutation testing
it properly would need a kernel that can stall its own request channel, which `bsw_top`
never does.

Two further mutations were considered and rejected as untestable rather than run:
removing a synchroniser flop, and removing the `A_SEND` separation cycle. Both are
**timing-margin** properties — a functional simulator will happily pass either. They are
covered by `ASYNC_REG` and the XDC, not by simulation, and claiming a green testbench
covers them would be wrong.

## Not yet done

- **The VU47P timing measurement** — the (A)/(B) decision above. It now *selects* a path
  instead of starting one, but nothing should be built until it is known.
- Everything from the DCP build onward (phases 2–4): needs AWS.
- On path (B) specifically: confirm the clock object names in `cl_timing_user.xdc`
  against `report_clocks` on the first synthesis. A non-matching XDC pattern fails
  silently, which would leave the crossing unconstrained.

## Strategic note: HBM

Each F2 FPGA carries 16 GB of HBM. The project's standing conclusion is that banded SWA
is only ~6.5% of bwa-mem2 runtime while FM-index seeding is ~30% and memory-bound, and
the seeder was set aside partly on a DDR-bandwidth roofline argument
(`docs/post_seeding_acceleration_research.md`, `project_bwa_mem2_acceleration_strategy`).
HBM changes that arithmetic. Out of scope for bring-up; worth revisiting once silicon
works.
