# F1 `cl_bsw_top` Build Runbook

A step-by-step guide to turn the verified `cl_bsw_top` RTL into a running AFI on a
real AWS F1 (VU9P) instance. Each step lists the **action**, **alternatives /
options**, and the **roadblocks** most likely to bite, with fixes.

This entire flow runs on **your** AWS side. Nothing here can be run from the dev
sandbox — it needs a licensed Vivado (via the FPGA Developer AMI), the `aws-fpga`
HDK, an S3 bucket, and an `f1.2xlarge` to load onto.

- **Repo HEAD referenced:** `main` (Track B files: `rtl/f1/cl_bsw_top.sv`,
  `rtl/f1/bsw_axil_regs.sv`, `scripts/cl_bsw_files.f`, `host/f1/test_bsw.c`).
- **Goal of this build:** the smallest thing that runs `bsw_top` on real silicon —
  a control-only (OCL AXI4-Lite) kernel, no DDR4, no PCIe DMA. Success = the host
  prints `GOLDEN OK (ACGT/ACGT -> score=5)`.
- **Expected wall-clock:** DCP build ~several hours; AFI ingestion ~1 hour; load +
  test ~minutes.

---

## Prerequisites (one-time)

| Need | How | Notes / options |
|------|-----|-----------------|
| Build host with Vivado | Launch a `z1d.2xlarge` (or larger) with the **FPGA Developer AMI** from the AWS Marketplace | Don't use a local Vivado 2026.1 — the HDK **pins specific Vivado versions**; the AMI ships a matched, licensed one. Version mismatch = the build script refuses to run. |
| `aws-fpga` HDK | `git clone https://github.com/aws/aws-fpga.git` | Pin a release tag if you want reproducibility. The examples/scripts referenced below come from here. |
| AWS CLI configured | `aws configure` | Needs `ec2:*FpgaImage*` and `s3` permissions. |
| S3 bucket | `aws s3 mb s3://<bucket>` | Two "folders" used: `dcp/` (input tarball) and `logs/` (ingestion logs). |
| An `f1.2xlarge` | Launch when you reach step 7 | Can be the **same** instance only if it's an F1; otherwise use a separate F1 just for loading/running. The build host does **not** need to be an F1. |
| This repo | clone onto the build host | You copy its `rtl/` + `rtl/f1/` into the CL project (step 2). |

---

## Step 1 — Set up the HDK environment

**Action**
```bash
git clone https://github.com/aws/aws-fpga.git $HOME/aws-fpga
cd $HOME/aws-fpga
source hdk_setup.sh          # sets HDK_DIR, CL env vars, checks Vivado
```

**Options**
- `source sdk_setup.sh` too if you'll run the host app on this same (F1) box.
- To pin a version: `git checkout v1.4.xx` before sourcing.

**Roadblocks**
- *"Vivado not found / unsupported version"* → you're not on the FPGA Developer AMI,
  or the wrong Vivado is on `PATH`. Fix the AMI; don't try to force your own Vivado.
- *`hdk_setup.sh` wants to download the shell DCP* → let it; first run pulls a large
  shell checkpoint. Needs internet + disk (~10s of GB free).

---

## Step 2 — Scaffold a CL project from `cl_hello_world`

Our `cl_bsw_top.sv` was written to **mirror the `cl_hello_world` example** (same
Shell port list via `cl_ports.vh`, same `unused_*_template.inc` tie-offs), so
starting from that example makes every Shell interface resolve with no edits.

**Action**
```bash
cp -r $HDK_DIR/cl/examples/cl_hello_world  $HOME/cl_bsw
export CL_DIR=$HOME/cl_bsw

# drop the example's RTL, bring in ours
rm -f $CL_DIR/design/*.sv $CL_DIR/design/*.v
cp <repo>/rtl/*.sv  <repo>/rtl/f1/*.sv  $CL_DIR/design/
```

**Options**
- You can keep `rtl/` and `rtl/f1/` as separate subdirs under `design/` instead of
  flattening — just keep the `+incdir` in step 4 pointed at wherever `bsw_pkg.sv`
  and the `cl_*.vh` includes live.
- Any other Shell example (`cl_dram_dma`, `cl_sde`) also works as a base, but they
  wire up interfaces we tie off — more to strip. `cl_hello_world` is the least work.

**Roadblocks**
- Copying **all** of `rtl/*.sv` pulls in modules `cl_bsw_top` doesn't use
  (chaining, matesw, msort…). That's harmless for *elaboration* as long as the
  **source list in step 4 lists only the 9 files** — Vivado only elaborates what the
  top needs. If you instead point synthesis at "all .sv in design/", it may try to
  elaborate unrelated tops. **Prefer the explicit 9-file list.**

---

## Step 3 — Set the CL identity (IDs) and name

**Action** — edit `$CL_DIR/design/cl_id_defines.vh`:
- Set `CL_SH_ID0` and `CL_SH_ID1` to your chosen vendor/device/subsystem IDs
  (any values you'll recognize; they end up in the AFI metadata).
- Confirm `CL_NAME` (in the build scripts / `cl_common_defines.vh`) is
  `cl_bsw_top`.

**Roadblocks**
- Leaving the example's default IDs is *allowed* but makes AFIs hard to tell apart.
- `cl_sh_id0/id1` are **driven** in `cl_bsw_top.sv` from these defines — if you
  rename the macros, update the wrapper.

---

## Step 4 — Point synthesis at the exact 9-file source list

This is **the #1 way to lose a multi-hour build** — a missing module fails
elaboration hours in. The authoritative list is **`scripts/cl_bsw_files.f`**:

```
rtl/bsw_pkg.sv            ← package, MUST be first / on +incdir
rtl/bsw_score_matrix.sv
rtl/bsw_pe.sv
rtl/bsw_systolic_array.sv
rtl/bsw_max_tracker.sv
rtl/bsw_ctrl_fsm.sv
rtl/bsw_top.sv
rtl/f1/bsw_axil_regs.sv
rtl/f1/cl_bsw_top.sv
```
`+incdir` : `rtl  rtl/f1` (prepend `design/` if you flattened into `$CL_DIR/design`).

**Action** — put these (in order) into whatever the CL build enumerates. Depending
on HDK version that's one of:
- the `read_verilog`/`read_systemverilog` list in
  `$CL_DIR/build/scripts/create_dcp_from_cl.tcl`, **or**
- the source `set` list in `$CL_DIR/build/scripts/encrypt.tcl`, **or**
- a `$CL_DIR/build/scripts/*.f` filelist the project references.

**Options**
- Read as SystemVerilog explicitly (`read_verilog -sv` / `read_systemverilog`) — the
  files use SV features (packages, `import`, structs).
- If your HDK uses `encrypt.tcl`, you generally **don't** need to encrypt for a
  private build; just ensure the file set matches.

**Roadblocks**
- *Do NOT use the old `scripts/file_list.f`* — it targets plain `bsw_top`, omits
  both `rtl/f1/*.sv`, and pulls in the unused `bsw_axis_adapter`.
- *`bsw_pkg` not found / "package bsw_pkg not defined"* → `bsw_pkg.sv` isn't first,
  or `+incdir` doesn't cover `rtl/`. Each file does `` `include "bsw_pkg.sv" `` and
  imports the package.
- *"module bsw_axis_adapter not found"* → you're using the wrong filelist; the
  bring-up path does not use it.
- *Duplicate-module / multiple-top errors* → synthesis is scooping extra `.sv`; go
  back to the explicit 9-file list.

---

## Step 5 — Pick the clock recipe (⚠️ verify the frequency)

The Shell main clock is **`clk_main_a0`**, and the kernel is **single-clock** — the
whole design runs on `clk_main_a0`; the only sequential element outside it is the
2-FF reset synchroniser. **No CDC constraints needed.**

**Target frequency: 125 MHz.** In the standard HDK recipe table
(`$HDK_DIR/docs/clock_recipes.md`):

| Recipe | `clk_main_a0` |
|--------|---------------|
| **A0** | **125 MHz**  ← this is the 125 MHz baseline |
| A1 | 250 MHz |
| A2 | 15.625 MHz |

(Values per `aws-fpga/hdk/docs/clock_recipes.csv`, F1 tag v1.4.25 — verify on your HDK version.)

**Action**
```bash
cd $CL_DIR/build/scripts
./aws_build_dcp_from_cl.sh -clock_recipe_a A0     # 125 MHz clk_main_a0
```

> ⚠️ **VERIFY BEFORE BUILDING.** Older notes in this repo said `-clock_recipe_a A1`
> for 125 MHz. **Open `$HDK_DIR/docs/clock_recipes.md` on your HDK version and
> confirm which recipe gives `clk_main_a0 = 125 MHz`.** If you build the wrong
> recipe (e.g. A1 = 250 MHz), the design will miss timing badly (it closes
> ~115–124 MHz today) and you'll have burned a multi-hour build. Pick the recipe
> whose `clk_main_a0` is 125, whatever it's named on your HDK.

**Options**
- Add `-foreground` to watch the run live instead of detaching.
- `-strategy TIMING` / `-strategy CONGESTION` (HDK-version-dependent) can help if the
  default just misses. Try `TIMING` first if you fail the gate at step 6.
- **Escape hatch if 125 won't close:** generate a slower CL clock from a recipe and
  run the kernel on it — but that reintroduces a CDC at the OCL boundary and extra
  work. Not needed per current data; keep in reserve.

**Roadblocks**
- Build detaches by default and logs to `$CL_DIR/build/scripts/*.log` — tail it.
- Out-of-memory / very long P&R → use a larger build instance (more RAM).

---

## Step 6 — ⚠️ TIMING GATE (check BEFORE making the AFI)

The build produces its own post-route timing summary in `$CL_DIR/build/reports/`.

**Action** — open the post-route `*.timing_summary` and require, **on `clk_main_a0`**:
- **WNS ≥ 0**
- **0 failing endpoints**

**Why this gate matters:** an AFI built from a failing DCP will *load* but be
**metastable** — `test_bsw` may return garbage or hang intermittently, and you'll
have spent the ~1 hr ingestion to find out. Catch it here.

**Options / if it fails**
- Re-run step 5 with `-strategy TIMING`.
- Read the worst path. If it's the **`u_bsw/u_tracker/pr_i…` reduction** (routing /
  congestion-bound), that family already closes 125 MHz standalone on the slow proxy
  (124.4) — on real VU9P it should pass; a strategy change usually gets it there.
- If the worst path is elsewhere and structural, bring the `*.timing_summary` worst
  path back to the team before iterating.

**Roadblocks**
- Don't confuse the Shell's own clocks with `clk_main_a0` in the report — filter to
  the intra-clock table for `clk_main_a0`.

---

## Step 7 — Create the AFI (DCP → S3 → AGFI)

**Action**
```bash
# the build drops a tarball here:
ls $CL_DIR/build/checkpoints/to_aws/*.Developer_CL.tar

aws s3 cp $CL_DIR/build/checkpoints/to_aws/<name>.Developer_CL.tar s3://<bucket>/dcp/
aws ec2 create-fpga-image \
    --input-storage-location Bucket=<bucket>,Key=dcp/<name>.Developer_CL.tar \
    --logs-storage-location  Bucket=<bucket>,Key=logs/ \
    --name cl_bsw_top --description "bsw_top OCL bring-up"
# note the returned FpgaImageId (afi-...) and FpgaImageGlobalId (agfi-...)

# poll until ready (~1 hr):
aws ec2 describe-fpga-images --fpga-image-ids <afi-...> \
    --query 'FpgaImages[0].State.Code'      # -> "available"
```

**Options**
- A `logs/` object appears if ingestion **fails** — read it for the reason.
- Tag the image (`--tag-specification`) so you can find the AGFI later.

**Roadblocks**
- *State = `failed`* → almost always a DCP/timing/shell-version issue; read the S3
  log. Rebuild after fixing.
- *Bucket permission denied* → the AWS FPGA ingestion service needs read on your
  bucket; apply the bucket policy from the HDK's AFI docs.
- Save the **AGFI** (`agfi-...`) — that's what you load in step 8, not the AFI id.

---

## Step 8 — Load onto F1 and run the host test

On an **`f1.2xlarge`** (with `source sdk_setup.sh` done):

**Action**
```bash
sudo fpga-load-local-image -S 0 -I <agfi-...>
sudo fpga-describe-local-image -S 0            # confirm "loaded" + your AGFI

cd <repo>/host/f1
gcc -I$SDK_DIR/userspace/include test_bsw.c -o test_bsw -lfpga_mgmt
sudo ./test_bsw
# expect:  GOLDEN OK (ACGT/ACGT -> score=5)
```

**What the host does** (matches the register map in `bsw_axil_regs.sv`): writes
CONFIG + QUERY + TARGET over the OCL BAR, pokes CONTROL bit0 (go), polls STATUS
until `done`, reads the RESULT words, checks `score == 5`.

**Options**
- `-S 0` is FPGA slot 0 (the only slot on `f1.2xlarge`).
- To re-run after a reload, just re-run `./test_bsw`; no reload needed between runs.

**Roadblocks**
- *`fpga-load-local-image` "AGFI not available in this region"* → the AFI is
  region-scoped; build/ingest in the same region as the F1.
- *score ≠ 5 or hang* → (a) you loaded a different AGFI (check
  `fpga-describe-local-image`); (b) the DCP failed timing (step 6) → metastable;
  (c) BAR/offset mismatch — but the host↔RTL contract was statically cross-checked,
  so suspect (a)/(b) first.
- *`fpga_pci` permission errors* → run under `sudo`.

---

## What to bring back

1. The **post-route `clk_main_a0` WNS + failing-endpoint count** from step 6 — the
   definitive VU9P timing number for the `bsw_top` core (esp. the tracker `pr_i`
   family).
2. The **`test_bsw` output** from step 8 — the on-silicon functional proof.

Together these close the F1 bring-up: a working `score=5` AFI, plus confirmation of
whether the current timing gap was proxy congestion (expected) or real.
