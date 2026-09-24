# Vitis HLS project: `ksw_extend_top`

C-simulation, synthesis and **co-simulation** of the banded SWA extension
kernel. Co-sim is the step that matters: it runs the same golden vectors
against the *generated RTL*, not just the C++.

## Your install

`D:\AMD_Vivado\2026.1` has `Vitis` and `Vivado` side by side and **no**
`vitis_hls.bat` -- that is the 2024.1+ unified flow, where HLS is driven
through `vitis-run`. `run_hls.tcl` detects this and uses `open_component`;
it falls back to `open_project`/`open_solution` on the classic flow, so the
same script works either way.

## Running it

From PowerShell, in this directory (`host/swa_hls/hls`):

```powershell
& D:\AMD_Vivado\2026.1\Vitis\bin\vitis-run.bat --mode hls --tcl run_hls.tcl
```

One line, no continuations. If you pass any path *into* Tcl, use forward
slashes -- backslashes get eaten.

Expect roughly: C-sim seconds, synthesis a few minutes, co-sim the slow part
(24 vectors of up to 437 x 131 DP cells against RTL). The script prints a
single `OVERALL: PASS` / `FAIL` block at the end and exits non-zero on failure,
so it is safe to run unattended.

### Stages

```powershell
$env:KSW_STAGE="csim";   & D:\AMD_Vivado\2026.1\Vitis\bin\vitis-run.bat --mode hls --tcl run_hls.tcl
$env:KSW_STAGE="csynth"; & D:\AMD_Vivado\2026.1\Vitis\bin\vitis-run.bat --mode hls --tcl run_hls.tcl
$env:KSW_STAGE="all"     # default
```

Start with `csim` -- it is seconds and catches anything structural before you
pay for synthesis.

### Part and clock

The default part is `xcku5p-ffvb676-2-e`, the UltraScale+ `-2` proxy already
used for the `bsw_top` timing run, because it is known to be installed. The
real F2 target is the VU47P:

```powershell
$env:KSW_PART="xcvu47p-fsvh2892-2-e"
```

Check it is installed first, from the Vivado Tcl console:
`get_parts -quiet xcvu47p*`

The clock defaults to 8.0 ns = **125 MHz**, matching the kernel clock domain
chosen for the F2 build (path B, behind the CDC). Override with `KSW_PERIOD`.

## Files

| file | role |
|---|---|
| `ksw_kernel.cpp` / `.h` | synthesis top, a thin wrapper over `../ksw_hls.h` |
| `tb_ksw_hls.cpp` | testbench, shared by C-sim and co-sim |
| `cosim_vectors.h` | **generated** -- 24 golden records, spread over the (qlen, tlen) envelope |
| `run_hls.tcl` | the run script |

`cosim_vectors.h` is embedded rather than read from a file so co-sim has no
path dependencies. Regenerate or resize it from a capture:

```sh
./replay_swa ~/cap_swa/ecoli_swa.bin --emit-cosim-header hls/cosim_vectors.h --cosim-count 24
```

24 is a deliberate compromise: enough to span short and long queries, few
enough that co-sim finishes. The full 49,468-record check is C-sim, via
`make check` one level up.

## Sanity check without Vitis

The testbench is plain C++ and compiles standalone, so it can be verified
before Vitis ever sees it:

```sh
g++ -O2 -std=c++17 -I.. -I. -o tb tb_ksw_hls.cpp ksw_kernel.cpp && ./tb
```

This currently reports `PASS: 24/24 vectors bit-exact`.

`run_hls.tcl` itself was syntax-checked under `tclsh` with the HLS commands
stubbed, exercising both flow branches, the report parser and the failure path.
What has *not* been verified is the behaviour of the real `open_component` /
`csim_design` / `cosim_design` commands in 2026.1 -- that needs your machine.
