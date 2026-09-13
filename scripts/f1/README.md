# `scripts/f1/` — AWS F1 build helpers

Two scripts that make the F1 bring-up mechanical, structured around one principle:
**the f1.2xlarge is billed per hour and is needed for only the final minutes.**
Everything else runs on a cheap non-F1 build host or on AWS's async ingestion
service. See `docs/f1_build_runbook.md` for the full step-by-step and roadblocks.

## Where each phase runs (and what it costs)

| Phase | Machine | Time | FPGA? | Script |
|-------|---------|------|-------|--------|
| A. Scaffold + synth + P&R + timing gate | cheap build host (`z1d`/`c5`, FPGA Developer AMI) | hours | no | `stage_cl_project.sh` |
| B. DCP → AFI bake | AWS ingestion (no instance running) | ~1 hr | no | — (`aws ec2 create-fpga-image`, then poll) |
| C. Load AGFI + run golden test | `f1.2xlarge` | minutes | **yes** | `run_on_f1.sh` |

Never run Phase A on an F1 — that pays FPGA rates for CPU synthesis. Don't launch
the F1 until the AFI `State.Code` is `available`.

## Phase A — on the build host

```bash
source $HOME/aws-fpga/hdk_setup.sh          # FPGA Developer AMI; sets HDK_DIR + Vivado
git clone <this-repo> && cd FPGA-speed-up-Project
scripts/f1/stage_cl_project.sh --build --patch-encrypt
```
Scaffolds `cl_bsw` from `cl_hello_world`, copies the exact 9 RTL files (in
elaboration order) into `design/`, generates the source filelist, best-effort
wires it into `encrypt.tcl` (backup + diff; prints manual steps if it can't match
your HDK version), and launches `aws_build_dcp_from_cl.sh -clock_recipe_a A0`.

Then, **before making an AFI**, clear the timing gate (Step 6): open
`$CL_DIR/build/reports/*.timing_summary` and require **WNS ≥ 0** and **0 failing
endpoints** on `clk_main_a0`. A failing DCP loads but is metastable — catch it here,
on the cheap box, not after the AFI bake and F1 trip.

Upload the tarball, create the AFI, then **stop/terminate the build host** — the
bake is server-side.

## Phase C — on the f1.2xlarge

```bash
source $HOME/aws-fpga/sdk_setup.sh
scripts/f1/run_on_f1.sh -I agfi-0123456789abcdef
```
Loads the AGFI, (re)compiles `test_bsw`, runs the ACGT/ACGT golden self-check,
tees the output to a timestamped log, and reports PASS/FAIL. Expected:
`GOLDEN OK (ACGT/ACGT -> score=5)`. Then terminate the instance.

## Notes
- `⚠️ Verify the clock recipe` on your HDK version: `A0` must be `clk_main_a0 = 125 MHz`
  (`$HDK_DIR/docs/clock_recipes.md`). Building the wrong recipe wastes a multi-hour build.
- Both scripts auto-detect the repo from their own location; override with `--repo`.
- `--help` on either script lists all options.
