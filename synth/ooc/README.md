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
