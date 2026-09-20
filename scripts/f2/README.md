# `scripts/f2/` — AWS F2 build helpers

The F2 sibling of `scripts/f1/`, structured around the same principle: **the FPGA
instance is billed by the hour and is needed only for the final minutes.** Everything
else runs on a cheap non-FPGA build host or on AWS's async ingestion service.

Full step-by-step, with the F2-specific roadblocks: [`docs/f2_build_runbook.md`](../../docs/f2_build_runbook.md).
Why the port looks the way it does: [`docs/f2_bringup.md`](../../docs/f2_bringup.md).

## Where each phase runs

| Phase | Machine | Time | FPGA? | Script |
|-------|---------|------|-------|--------|
| 0. Structural lint of the CL against the real Shell files | this box | seconds | no | `lint_cl_bsw.sh` |
| 1. **Timing decision**: does `bsw_top` close 250 MHz on VU47P? | cheap build host | minutes | no | `../../synth/ooc/impl_bsw_top_vu47p.tcl` |
| 2. Scaffold + synth + P&R + timing gate | cheap build host (FPGA Developer AMI) | hours | no | `stage_cl_project.sh` |
| 3. DCP → AFI bake | AWS ingestion (no instance running) | ~1 hr | no | `hdk/scripts/create_afi.py` |
| 4. Load AGFI + run golden test | `f2.6xlarge` | minutes | **yes** | `run_on_f2.sh` |

Never run phase 2 on an F2 — that pays FPGA rates for CPU synthesis. Don't launch the
F2 until the AFI state is `available`.

## Phase 0 — here, before anything else

```bash
scripts/f2/lint_cl_bsw.sh --kit <path-to-aws-fpga-f2-checkout>
```

Elaborates `rtl/f2/cl_bsw_top.sv` against the **real** `cl_ports.vh` and the **real**
`unused_*_template.inc` tie-offs, which an ordinary Verilator testbench never sees.
Each fault class it catches is proven by a mutant listed in `docs/f2_bringup.md`. It
also carries a structural guard for the one fault Verilator provably cannot see
(multiply-driven `cl_ocl_*`).

Functional cover for the same wrapper:
```bash
bash scripts/run_sim.sh tb_cl_bsw_ocl_f2      # 13/13, golden ACGT/ACGT -> score=5
```

If phase 1 says the kernel needs its own clock, the two-clock build has the same pair:
```bash
scripts/f2/lint_cl_bsw.sh --kit <kit> --cdc   # structure, with an AWS_CLK_GEN stub
bash scripts/run_sim.sh tb_bsw_axil_cdc       # 23/23 vs a same-clock reference
```

## Phase 2 — on the build host

```bash
source $HOME/aws-fpga/hdk_setup.sh            # f2 branch, FPGA Developer AMI
git clone <this-repo> && cd FPGA-speed-up-Project
scripts/f2/stage_cl_project.sh --build
```

Scaffolds the CL from `cl_demo/cl_axil_reg_access`, repairs the example's relative
build-script symlinks, copies the 9 RTL sources + 2 headers, rewrites `encrypt.tcl`,
generates `synth_cl_bsw_top.tcl` with an **explicit ordered** `read_verilog` list
(AWS's stock glob is alphabetical, which does not guarantee the package compiles
first), and launches `aws_build_dcp_from_cl.py -c cl_bsw_top`.

Then, **before making an AFI**, clear the timing gate: require WNS ≥ 0 and 0 failing
endpoints on `clk_main_a0`. A failing DCP loads and runs — and returns wrong answers.
Catch it on the cheap box, not after the AFI bake and the F2 trip.

## Phase 4 — on the f2.6xlarge

```bash
source $HOME/aws-fpga/sdk_setup.sh
scripts/f2/run_on_f2.sh -I agfi-0123456789abcdef
```

Expected: `GOLDEN OK (ACGT/ACGT -> score=5)`. Then terminate the instance.

## Notes

- **`clk_main_a0` is fixed at 250 MHz on F2** and no clock recipe changes it. This is
  the one substantive difference from the F1 port — run phase 1 before phase 2. Both
  outcomes are covered: single-clock by default, or `--clk-gen` to move the kernel to
  `clk_extra_a1` (125 MHz) behind `rtl/bsw_kernel_cdc.sv`.
- Clock recipes require `--aws_clk_gen`: `aws_build_dcp_from_cl.py` hard-errors if a
  `--clock_recipe_*` is passed without it. The single-clock build passes **neither**.
- The CL directory basename, the `-c` argument and the top module name must be
  identical (`cl_bsw_top`). The build script derives the CL name from `$CL_DIR` and
  synth runs `-top ${CL}`. `stage_cl_project.sh` checks all three up front.
- An F1 AFI will not load on F2 — different device (VU47P vs VU9P) and different shell.
- `host/test_bsw.c` is reused verbatim: the F2 SDK still ships `fpga_pci.h` /
  `fpga_mgmt.h` and the same `fpga-load-local-image` CLI, and the test is pure OCL
  peek/poke. It stays under `host/` so the F1 runbook keeps working.
- `--help` on either script lists all options.
