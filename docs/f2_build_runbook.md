# F2 build runbook — from this repo to `score=5` on VU47P silicon

Companion to [`docs/f2_bringup.md`](f2_bringup.md) (what changed and why) and
[`scripts/f2/README.md`](../scripts/f2/README.md) (the helper scripts).

Target: **f2.6xlarge**, AMD Virtex UltraScale+ HBM **VU47P** (`xcvu47p-fsvh2892-2-e`).
Cost discipline: only Step 7 needs an FPGA instance. Everything before it runs on a
cheap CPU box or inside AWS's async AFI service.

---

## Step 0 — get the right kit

```bash
git clone https://github.com/aws/aws-fpga.git -b f2
```

The **`f2` branch is a different HDK**, not a newer F1. Building this repo's CL against
the master branch will fail in confusing ways (its `cl_ports.vh` has no `ocl_cl_*`
signals). `stage_cl_project.sh` and `lint_cl_bsw.sh` both check for this explicitly and
refuse to continue.

Vivado must be **2024.1, 2024.2, 2025.1 or 2025.2** (`supported_vivado_versions.txt`).
The FPGA Developer AMI ships a supported Vivado with the license included.

---

## Step 1 — lint the CL here, for free

```bash
scripts/f2/lint_cl_bsw.sh --kit ~/aws-fpga-f2
bash scripts/run_sim.sh tb_cl_bsw_ocl_f2

# path (B) only - the two-clock build:
scripts/f2/lint_cl_bsw.sh --kit ~/aws-fpga-f2 --cdc
bash scripts/run_sim.sh tb_bsw_axil_cdc
```

Expect `LINT PASSED` and `13 pass, 0 fail` (and `23 pass, 0 fail` for the CDC tb) with
the golden `ACGT/ACGT -> score=5`. All currently pass. This stage costs nothing, so do
not skip it.

**If you have Vivado anywhere — no AWS account, no F2, no VU47P licence needed — add:**

```tcl
set KIT C:/work/aws-fpga-f2
source <repo>/synth/ooc/synth_cl_bsw_f2.tcl          # single-clock
set CDC 1 ; source <repo>/synth/ooc/synth_cl_bsw_f2.tcl   # two-clock
```

That synthesises the whole CL wrapper and counts multiply-driven nets — the one fault
class Verilator provably cannot see, and the one that would otherwise surface hours into
Step 4. Minutes, on hardware you already have.

---

## Step 2 — **the timing decision** (do this before anything expensive)

On the build host, in Vivado:

```tcl
source <repo>/synth/ooc/impl_bsw_top_f2.tcl
```

Minutes, not hours. It places and routes `bsw_top` on the real VU47P at a 4.0 ns
(250 MHz) target and prints the verdict:

- **WNS ≥ 0** → path **(A)**: single clock domain. Continue with Step 3 unchanged.
- **WNS < 0** → path **(B)**: the kernel runs on `clk_extra_a1` at 125 MHz behind the
  clock-domain crossing. **This is already built and verified** — just stage with
  `--clk-gen` at Step 3 and build with the recipe flags it adds. Nothing to implement.
  Background: `rtl/bsw_kernel_cdc.sv` and the "Path (B)" section of `docs/f2_bringup.md`.

> **Why this gate exists.** On F1 we chose the clock (recipe A0 = 125 MHz) to match the
> design. On F2 `clk_main_a0` is **fixed at 250 MHz** and no recipe changes it, so the
> design has to match the clock. Our 124.4 MHz figure is from a Virtex-7 `-2` proxy, a
> much slower fabric; it neither proves nor disproves 250 MHz on VU47P. Measuring costs
> minutes. Guessing wrong costs a multi-hour build plus an AFI bake plus FPGA time.

---

## Step 3 — stage the CL project

```bash
source ~/aws-fpga-f2/hdk_setup.sh
scripts/f2/stage_cl_project.sh                # path (A)
scripts/f2/stage_cl_project.sh --clk-gen      # path (B), if Step 2 said so
```

`--clk-gen` additionally: defines `BSW_KERNEL_CDC` in the staged `cl_bsw_defines.vh`,
inserts `rtl/bsw_kernel_cdc.sv` into the read order (after `bsw_top`, before
`bsw_axil_regs`), installs `scripts/f2/cl_timing_user_cdc.xdc` as the CL's
`cl_timing_user.xdc` (keeping a `.orig` backup), and appends
`--aws_clk_gen --clock_recipe_a A1` to the build. It does **not** stage `aws_clk_gen.sv`:
the HDK's own `synth_cl_header.tcl` already reads it for every CL build, so copying it
would double-declare the module.

> **After the first synthesis on path (B), check the clock names.** The CDC constraints
> match `clk_main_a0` and `clk_extra_a1` by name. The Shell's name is stable; the
> MMCM-generated one may not be. Run `report_clocks` and confirm. An XDC pattern that
> matches nothing **fails silently** — the file prints its match counts and a CRITICAL
> WARNING for exactly this reason, so read them rather than assuming.

This scaffolds `$CL_DIR` (default `$HOME/cl_bsw_top`) from `cl_demo/cl_axil_reg_access`
and rewrites it for our design. Four things it does that are easy to get wrong by hand:

1. **Repairs the build-script symlinks.** The example's `aws_build_dcp_from_cl.py`,
   `build_all.tcl` and `build_level_1_cl.tcl` are *relative* symlinks reaching six levels
   up. They dangle the moment the CL is copied anywhere else — including one directory
   level shallower. The script re-points them at `$HDK_DIR` absolutely.
2. **Enforces the naming contract.** `aws_build_dcp_from_cl.py` derives the CL name from
   the `$CL_DIR` basename, rejects a mismatched `-c`, and synth runs `-top ${CL}`. So the
   directory basename, the `-c` argument and the module name must all be `cl_bsw_top`.
   The script verifies all three before doing any work.
3. **Replaces AWS's `glob` with an explicit ordered `read_verilog` list.** The stock
   `synth_<CL>.tcl` reads `[glob ${src_post_enc_dir}/*.{s,}v]` — alphabetical order,
   which does not guarantee `bsw_pkg.sv` compiles before the modules that import it.
4. **Strips `` `include "bsw_pkg.sv" `` from the staged copies.** Under Verilator those
   includes are harmless (one compilation unit, `BSW_PKG_SV` guard). Vivado may compile
   each file as its own unit, where the guard does not carry across files and the package
   would be declared once per includer. Compiling the package once, first, and letting
   `import bsw_pkg::*` resolve it is correct under both models.

Sanity-check the result before building:

```bash
ls $CL_DIR/design                                   # 9 .sv + 2 .vh
sed -n '/Developer would replace/,/End of section/p' $CL_DIR/build/scripts/encrypt.tcl
grep read_verilog $CL_DIR/build/scripts/synth_cl_bsw_top.tcl
```

---

## Step 4 — build the DCP

```bash
cd $CL_DIR/build/scripts
./aws_build_dcp_from_cl.py -c cl_bsw_top            # path (A): NO clock recipe flags
# path (B): ./aws_build_dcp_from_cl.py -c cl_bsw_top --aws_clk_gen --clock_recipe_a A1
```

(The staging script prints the exact command for whichever path you staged.)

Hours. Run it under `tmux`/`nohup`.

> **Roadblock:** passing any `--clock_recipe_*` without `--aws_clk_gen` is a hard error
> ("The aws_clk_gen IP is required for setting custom clock recipes"). And the recipe is
> ignored anyway unless the CL actually instantiates the AWS_CLK_GEN IP. For the
> single-clock build, pass **neither**.

---

## Step 5 — the timing gate (the fail-fast before you spend money)

```bash
grep -A6 'Design Timing Summary' $CL_DIR/build/reports/*timing_summary*
```

Require **WNS ≥ 0** and **0 failing endpoints** on `clk_main_a0` — and on path (B),
on `clk_extra_a1` too, plus confirmation that the CDC constraints were applied (the
match counts printed by `cl_timing_user.xdc` during synthesis). A DCP that fails
timing still bakes, still loads and still runs — it just returns wrong answers
intermittently. This is the last checkpoint that costs nothing.

If it fails by a small margin, re-run Step 4 with stronger directives
(`--place_direct`, `--phy_opt_direct`, `--route_direct`) before touching RTL.

---

## Step 6 — bake the AFI

```bash
aws s3 mb s3://<your-bucket>
$AWS_FPGA_REPO_DIR/hdk/scripts/create_afi.py ...    # --help for the exact arguments
```

Server-side and takes roughly an hour, so **stop or terminate the build host now** —
nothing local is needed while it bakes. Poll until `State.Code` is `available`:

```bash
aws ec2 describe-fpga-images --fpga-image-ids afi-... \
  --query 'FpgaImages[0].State.Code'
```

Note the **`agfi-...`** id (global), not the `afi-...` id — the loader wants the former.

---

## Step 7 — run it on the FPGA

Launch an **f2.6xlarge** (the smallest F2; there is no 2xlarge), then:

```bash
source ~/aws-fpga-f2/sdk_setup.sh
scripts/f2/run_on_f2.sh -I agfi-0123456789abcdef
```

Expected:

```
GOLDEN OK (ACGT/ACGT -> score=5)
```

Then **terminate the instance**. The runtime API is unchanged from F1 — the F2 SDK still
ships `fpga_pci.h`/`fpga_mgmt.h` and `fpga-load-local-image` — so `host/test_bsw.c`
is reused verbatim.

---

## Roadblocks, collected

| Symptom | Cause |
|---|---|
| `cl_ports.vh` has no `ocl_cl_*` | master-branch (F1) HDK; check out `f2` |
| `does not match CL_DIR env variable` | `-c` ≠ `$CL_DIR` basename ≠ module name; all three must be `cl_bsw_top` |
| `aws_build_dcp_from_cl.py: No such file` after moving the CL | the example's relative symlinks dangled; re-run the staging script |
| `The aws_clk_gen IP is required for setting custom clock recipes` | dropped a `--clock_recipe_*` without `--aws_clk_gen` |
| clock recipe silently ignored | no AWS_CLK_GEN IP instantiated in the CL — stage with `--clk-gen` |
| CDC paths show as unconstrained / fail timing | clock object names in `cl_timing_user.xdc` did not match; run `report_clocks` |
| `cl_sda_*` multiply driven on path (B) | `unused_cl_sda_template.inc` and AWS_CLK_GEN both driving SDA; the wrapper already excludes the tie-off under `BSW_KERNEL_CDC` |
| package `bsw_pkg` declared more than once | per-file compilation units + the `include`; the staging script strips it |
| multiply-driven `cl_ocl_*` at synth | `unused_sh_ocl_template.inc` got included; Verilator cannot see this — `lint_cl_bsw.sh` guards it structurally |
| `sh_ddr` held in reset / `rst_main_n_sync` undeclared | the DDR tie-off consumes a signal it does not declare; our wrapper declares and drives it |
| AFI loads but results are wrong | Step 5 timing gate was skipped |
| F1 AFI will not load | different device and shell; rebuild for F2 |
