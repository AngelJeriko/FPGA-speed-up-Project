# Running the BSW RTL under XSIM

A step-by-step procedure for simulating the hand-written SystemVerilog
(`bsw_top`) under **XSIM**, AMD's simulator, on the Windows machine — and
checking its outputs against real bwa-mem2 data.

**Status: written but not executed.** There is no Vivado on the machine this was
written on, so every command below is derived from the tool documentation and
from the equivalent Verilator invocation in `scripts/run_sim.sh`, not from a
successful run. Section 8 lists what to do when a step fails.

---

## 1. Why bother — we already test this RTL

We do, under Verilator: `tb_bsw_ext` drives real bwa-mem2 extensions into
`bsw_top` and compares all outputs. It passes.

The reason to repeat it under XSIM is that **the two simulators check different
things**:

| | Verilator | XSIM |
|---|---|---|
| Value model | **2-state** (0/1 only) | **4-state** (0/1/X/Z) |
| Uninitialised registers | treated as 0 | **X** until written |
| Reset sequencing errors | usually invisible | surface as X propagation |
| Speed | very fast | 10–100x slower |

A 2-state simulator silently assumes every register starts at 0. Real hardware
does not. If any path in `bsw_top` depends on a register that reset does not
actually clear, Verilator will happily compute the right answer and the FPGA
will not.

This project has been caught by Verilator's blind spots twice already:

- an **undriven `tdo`** output that Verilator passed and real synthesis flagged
  (`[Synth 8-3848]`)
- **147k multiply-driven nets** that Verilator passed clean under `-Wall`

Both were found by running AMD's tools instead of trusting the fast one. XSIM is
the same move applied to simulation.

### What this does *not* do

- It does **not** test the AWS shell, the PCIe link or the memory path. Only
  `bsw_top` and its submodules.
- It does **not** replace the AWS build. Timing, placement and routing are
  unaffected by simulation.
- It does **not** add algorithmic coverage over the Verilator run — the same
  vectors, the same comparisons. The new information is purely 4-state effects.

---

## 2. Prerequisites

| Need | Value on this machine |
|---|---|
| Vivado install | `D:\AMD_Vivado\2026.1\Vivado` |
| XSIM binaries | `D:\AMD_Vivado\2026.1\Vivado\bin\{xvlog,xelab,xsim}.bat` |
| Repo | `C:\work\FPGA-speed-up-Project` (the `C:\Users\kanak` clone was deleted) |
| Licence | The BASIC licence is sufficient — XSIM needs no device data, and this simulates RTL with no target part |

Confirm the three tools exist before starting (one line at a time):

```powershell
Test-Path D:\AMD_Vivado\2026.1\Vivado\bin\xvlog.bat
```
```powershell
Test-Path D:\AMD_Vivado\2026.1\Vivado\bin\xelab.bat
```
```powershell
Test-Path D:\AMD_Vivado\2026.1\Vivado\bin\xsim.bat
```

All three must print `True`.

---

## 3. Choose a vector set — start small

`tb_bsw_ext` reads a text file whose first line is the record count, then three
lines per extension. **Runtime scales linearly with the count**, and XSIM is
much slower than Verilator, so do not start with the full set.

Verilator does 15,887 extensions in **84 seconds**. At 10–100x slower, XSIM will
need roughly **15 minutes to 2 hours** for the same file. So:

```powershell
cd C:\work\FPGA-speed-up-Project
```

Make a 200-extension file first — 1 header line plus 3 lines per record:

```powershell
$src = "host\extend_orchestrator\vectors\ext_sw_vectors.txt"
```
```powershell
Get-Content $src -First 601 | Select-Object -Skip 1 | Set-Content C:\work\vec200_body.txt
```
```powershell
"200" | Set-Content C:\work\vec200.txt
```
```powershell
Get-Content C:\work\vec200_body.txt | Add-Content C:\work\vec200.txt
```

(1 + 3x200 = 601 lines read; the first is the original count, which is replaced.)

Sanity-check it:

```powershell
Get-Content C:\work\vec200.txt -First 1
```

Must print `200`.

### Vector sets available

| Set | Where | Records | Notes |
|---|---|---|---|
| Committed golden | `host/extend_orchestrator/vectors/ext_sw_vectors.txt` | 15,887 | Generated if absent by `run_sim.sh` |
| E. coli / human captures | generated — see §7 | any | Newer data; catches a bug the committed set misses |

---

## 4. The run, step by step

The repo carries a source list and a driver script so the file order cannot
drift from what `run_sim.sh` uses.

### Easiest: the script

```powershell
cd C:\work\FPGA-speed-up-Project
```
```powershell
.\sim\xsim\run_bsw_ext.ps1 -Vec C:/work/vec200.txt
```

If PowerShell refuses to run it (execution policy), either run the three
commands manually below, or allow scripts for this session only:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
```

### Or the three commands by hand

Work from a scratch directory, because XSIM writes `xsim.dir/`, `*.log`,
`*.pb` and `*.jou` into wherever it is run:

```powershell
mkdir C:\work\xsim_work -Force
```
```powershell
cd C:\work\xsim_work
```

**Step 1 — compile.** `-sv` enables SystemVerilog; `-f` takes the committed
source list, which avoids a very long command line (long lines have repeatedly
been mangled by this terminal):

```powershell
& D:\AMD_Vivado\2026.1\Vivado\bin\xvlog.bat -sv -f C:\work\FPGA-speed-up-Project\sim\xsim\bsw_ext_sources.f
```

Expect one `INFO: [VRFC 10-311] analyzing module ...` line per module and no
`ERROR`. `bsw_pkg` must be the first thing compiled — it is a package and
everything else imports its types.

**Step 2 — elaborate.** Builds the simulation snapshot:

```powershell
& D:\AMD_Vivado\2026.1\Vivado\bin\xelab.bat tb_bsw_ext -s tb_bsw_ext_sim --timescale 1ns/1ps -O0 -relax
```

- `-s tb_bsw_ext_sim` names the snapshot that step 3 runs.
- `--timescale 1ns/1ps` matches `run_sim.sh`, so the testbench's watchdog
  (`#2000000000`, i.e. 2 s of simulated time) means the same thing.
- `-O0` keeps elaboration quick. Only try `-O3` if *run* time is the bottleneck;
  it makes elaboration slower.
- `-relax` loosens some strictness Vivado applies that Verilator does not.

**Step 3 — run.** `-runall` runs to `$finish`; `-testplusarg` supplies the
plusarg the testbench reads with `$value$plusargs("VEC=%s", path)`:

```powershell
& D:\AMD_Vivado\2026.1\Vivado\bin\xsim.bat tb_bsw_ext_sim -runall -testplusarg VEC=C:/work/vec200.txt
```

**Use forward slashes in the vector path.** It is handed to Verilog `$fopen`,
where `\` is an escape character — `C:\work\...` will fail to open.

---

## 5. What a good run looks like

```
tb_bsw_ext: 200 extensions, 0 failures, N max_off diffs (informational) -> ALL PASS
```

`max_off` differences are expected and informational — the testbench counts but
does not fail on them, because the array tracks the anti-diagonal offset over
the full rectangle while ksw tracks it inside its band.

Then scale up: re-run with the full `ext_sw_vectors.txt`, and budget an hour.

## 6. What a *finding* looks like

This is the point of the exercise. Watch for:

**X in a reported value.** The mismatch line prints with `%0d`, so an X-valued
result shows as `x` or a nonsense number:

```
MISMATCH[7] side=0 qlen=40 tlen=80 | score x/37 qle 0/12 ...
```

An X means some register feeding that output was **never initialised and reset
does not clear it**. Verilator cannot see this. It is a real hardware bug: on
silicon that register powers up arbitrarily.

**Failures that Verilator does not reproduce.** Run the identical vector file
under Verilator on the Linux box:

```sh
BSW_EXT_VEC=<same file> bash scripts/run_sim.sh tb_bsw_ext
```

Verilator passes and XSIM fails on the same vectors ⇒ a 4-state issue, which is
exactly what we are hunting. Both fail ⇒ an ordinary logic bug, and the
Verilator loop is the faster place to debug it.

**What to do with a finding:** capture the failing record index, extract that one
extension into its own vector file, and re-run with a waveform:

```powershell
& D:\AMD_Vivado\2026.1\Vivado\bin\xelab.bat tb_bsw_ext -s dbg --timescale 1ns/1ps -debug typical
```
```powershell
& D:\AMD_Vivado\2026.1\Vivado\bin\xsim.bat dbg -testplusarg VEC=C:/work/one.txt -gui
```

`-debug typical` is required for waveform access and makes the run slower, so
only use it on a single record.

---

## 7. Using the newer capture data

The committed golden set predates the current capture hook. Vectors from the
E. coli and human captures catch a bug it misses — the historic
gaps-open-from-H defect (`docs/bsw_gapopen_fix.md`) is caught by the 150 bp
human stress set and **not** by `ext_sw_vectors.txt`.

Those are generated on the Linux box, because they come from multi-GB captures:

```sh
cd host/swa_hls
g++ -O2 -std=c++17 -I../extend_orchestrator -o gen_rtl_vectors_from_cap gen_rtl_vectors_from_cap.cpp
./gen_rtl_vectors_from_cap ~/cap_human/sim150_swa.bin out.txt --count 12000 --min-tlen 900
```

Copy `out.txt` to the Windows box and pass it with `-Vec`. Read
`gen_rtl_vectors_from_cap.cpp`'s header before trusting the numbers: `score`,
`qle` and `tle` come from bwa-mem2, but `gscore`/`gtle` are recomputed with the
full-DP array model, because `bsw_top` computes the full unbanded DP and
legitimately differs from ksw's banded result on those two outputs.

---

## 8. When a step fails

| Symptom | Cause | Fix |
|---|---|---|
| `xvlog` not recognised | Wrong path, or no `.bat` | Use the full path with `.bat`; confirm with `Test-Path` |
| `ERROR: [VRFC 10-xxxx] cannot find <type>` | `bsw_pkg.sv` compiled late | Keep the order in `bsw_ext_sources.f`; package first |
| `ERROR: [VRFC 10-2063] module not found` | A source file missing from the list | Compare against `run_sim.sh`'s `RTL_FILES` for `tb_bsw_ext` |
| `FATAL: cannot open <path>` from the testbench | Backslashes in the vector path, or a relative path | Forward slashes, absolute path |
| Testbench reports count 0, exits instantly | First line of the vector file is not the record count | `Get-Content <vec> -First 1` must be an integer |
| `[FATAL] tb_bsw_ext timeout` | Watchdog hit | Wrong `--timescale` on `xelab`, or a genuine hang. Re-check the flag first |
| Run seems hung | Normal — XSIM is slow and silent | Start with 200 records. A 15,887-record run can take an hour |
| Unrecognised `-testplusarg` | Version syntax difference | Try `--testplusarg`, or `-testplusarg "VEC=..."` quoted |
| Elaboration very slow | `-O3` or `-debug` | Use `-O0` and no `-debug` unless debugging one record |

## 9. Honest limits of this procedure

- **Unverified.** No step has been executed. Flag names are from the tool docs
  and the Verilator equivalents; if 2026.1 renamed one, the error will name it.
- **4-state coverage is not a proof.** XSIM shows X propagation *that the
  testbench's stimulus reaches*. A register only exercised by an untested path
  stays invisible. It is strictly better than 2-state, not complete.
- **Reset is only as realistic as the testbench.** `tb_bsw_ext` holds reset for
  5 clocks and releases. That is not a power-up model, so some
  genuine initialisation problems can still hide.
- **The real decider is still the AWS build.** This finds a class of bug early
  and cheaply; it does not substitute for hardware.
