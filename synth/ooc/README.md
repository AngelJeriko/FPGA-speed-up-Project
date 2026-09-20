# OOC synthesis harness — measure synth-prep on your local Vivado

Goal: run **out-of-context** synthesis on individual RTL modules on your **local Vivado
ML Standard**, targeting a free UltraScale+ proxy part (same LUT6/RAMB36/DSP48E2 fabric
as the F1 `xcvu9p`), to get per-module **Fmax + BRAM inference + LUT/FF/DSP area**. That
tells us which combinational-read memories actually hurt, and lets us measure each fix.

We (this VM) write the scripts; **you** run them locally and paste back the summaries.

## One-time
1. `git pull` this repo on your machine (brings `synth/ooc/` + all `rtl/`).
2. Open a shell where `vivado` is on PATH:
   - Linux/Mac/WSL: `source /path/to/Vivado/<ver>/settings64.sh`
   - Windows: use the "Vivado <ver> Tcl Shell" or add `...\Vivado\<ver>\bin` to PATH.

## Run the priority targets
Linux/Mac/WSL:
```
cd synth/ooc
./run_ooc.sh                      # top-3: chain_store, bsw_max_tracker, matesw_dedup
```
Windows (or any OS), one module at a time — call the driver directly:
```
vivado -mode batch -source ooc_synth.tcl -tclargs chain_store xcku5p-ffvb676-2-e 3.0 reports ../../rtl/chain_store.sv
vivado -mode batch -source ooc_synth.tcl -tclargs bsw_max_tracker xcku5p-ffvb676-2-e 3.0 reports ../../rtl/bsw_pkg.sv ../../rtl/bsw_max_tracker.sv
vivado -mode batch -source ooc_synth.tcl -tclargs matesw_dedup xcku5p-ffvb676-2-e 3.0 reports ../../rtl/matesw_dedup.sv
```

## Share back
Paste the contents of `synth/ooc/reports/*_summary.rpt` (11 lines each: WNS, EST FMAX,
LUT, FF, RAMB36/18, URAM, DSP). If a module's Fmax is bad, also paste its
`*_timing.rpt` top path so I can see the exact critical path.

## Notes
- **Part availability:** if Vivado says `xcku5p-ffvb676-2-e` isn't installed, set
  `PART=<another free US+ part>` (e.g. `xcku3p-ffva676-2-e`, or a Zynq US+
  `xczu7ev-ffvc1156-2-e`) — whatever your free device list includes. `-2` speed grade
  keeps it comparable to the F1 device.
- **Fmax math:** `EST FMAX = 1000 / (PERIOD_ns − WNS_ns)`. Negative WNS ⇒ below target
  (expected on the un-converted modules — that's the baseline we're measuring against).
- These are **relative** per-module numbers on a proxy part, not the absolute F1 result.
  Absolute F1 numbers + the AFI come later on the AWS FPGA Developer AMI.
- Baseline first (modules as-is), then I apply the registered-BRAM conversions and you
  re-run the same command → the delta is the win. Target order:
  `docs/synthesizability_worklist.md`.

---

## F2 scripts (current target) — both run without AWS, an F2, or any new licence

| Script | Question it answers | Needs |
|---|---|---|
| `impl_bsw_top_f2.tcl` | Does `bsw_top` close **250 MHz**? (F2's `clk_main_a0` is fixed there) | a device; VU47P if you have it, else an UltraScale+ `-2` proxy |
| `synth_cl_bsw_f2.tcl` | Does the whole CL wrapper **synthesise clean** — in particular, is anything **multiply driven**? | any device + an `aws-fpga` **f2** checkout (plain git clone) |

### ⚠️ Your existing numbers fell back a whole fabric generation

This README asks for an UltraScale+ proxy, but every committed report — including
`bsw_top_impl_timing.rpt` and the 124.4 MHz figure — says `Device: 7v2000t`. The
candidate list in `ooc_console.tcl` tries `xcku5p` and `xczu7ev` first and **fell
through to Virtex-7**, which means those families are not installed in that Vivado.

That matters now. Virtex-7 `-2` is a generation older than VU47P `-2`, and
systematically pessimistic, so 124.4 MHz neither proves nor disproves 250 MHz on F2.
A KU5P or ZU7EV at `-2` is the *same* UltraScale+ fabric at the *same* speed grade, so
its Fmax actually predicts the F2 result. Check with:

```tcl
get_parts -quiet xcku5p*
get_parts -quiet xczu7ev*
```

If those come back empty, it is usually a device-family **install** choice rather than a
licence one — re-run the Vivado installer and pick "Add Design Tools or Devices". That
one step is what turns `impl_bsw_top_f2.tcl` from a rough hint into a real answer.

### Synthesising the CL wrapper

`synth_cl_bsw_f2.tcl` closes a gap nothing else can. `scripts/f2/lint_cl_bsw.sh` proves
the wrapper *elaborates* against the real Shell files, but a **multiply-driven net**
lints 100% clean under Verilator even with `-Wall` — we proved that with a mutant rather
than assuming it. Vivado catches it. Run this before any paid AWS build:

First get the kit (a plain git clone, no AWS account, ~7 MB). **PowerShell — one line
at a time**, because `\` continues a line in bash but *not* in PowerShell, where a
pasted bash block is read as a repo named `\` and the clone silently never happens:

```powershell
mkdir C:\work -Force
cd C:\work
git clone --filter=blob:none --no-checkout --depth 1 -b f2 https://github.com/aws/aws-fpga.git aws-fpga-f2
cd aws-fpga-f2
git sparse-checkout init --cone
git sparse-checkout set hdk/common/shell_stable/design/interfaces hdk/common/shell_stable/design/sh_ddr
git checkout
```

bash equivalent:

```bash
git clone --filter=blob:none --no-checkout --depth 1 -b f2 \
    https://github.com/aws/aws-fpga.git aws-fpga-f2
cd aws-fpga-f2 && git sparse-checkout init --cone && git sparse-checkout set \
    hdk/common/shell_stable/design/interfaces hdk/common/shell_stable/design/sh_ddr
git checkout
```

Then, in the Vivado Tcl Console (forward slashes, even on Windows):

```tcl
set KIT C:/work/aws-fpga-f2
source .../synth/ooc/synth_cl_bsw_f2.tcl
set CDC 1 ; source .../synth/ooc/synth_cl_bsw_f2.tcl   ; # the two-clock build too
```

### Checking these scripts without Vivado

`dryrun_tcl.tcl` stubs the Vivado command set and sources a script under plain `tclsh`,
so control-flow bugs surface here instead of on your machine:

```bash
tclsh synth/ooc/dryrun_tcl.tcl ~/aws-fpga-f2 synth/ooc/synth_cl_bsw_f2.tcl     # single-clock
tclsh synth/ooc/dryrun_tcl.tcl ~/aws-fpga-f2 synth/ooc/synth_cl_bsw_f2.tcl 1   # two-clock
tclsh synth/ooc/dryrun_tcl.tcl ~/aws-fpga-f2 synth/ooc/impl_bsw_top_f2.tcl     # timing
```

It simulates the interesting case by default — `xcvu47p` **absent**, so the proxy
fallback has to work — and `set WNS <n>` first to exercise the verdict branches. It
verifies that the script reaches the Vivado calls with the arguments you meant; it does
not verify the Vivado commands themselves.
