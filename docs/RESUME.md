# RESUME — where this project stands and how to pick it up

**Paused 2026-10-07 · `main` at `158df79`, clean and pushed.**

Everything achievable without AWS is done, **including post-synthesis gate-level
verification**. The next substantive step is the AWS build. One optional local item
remains (widening the gate-level array).

This file is the short map. `docs/project_status.md` is the long one for a newcomer,
and `synth/postsynth/README.md` is the fullest account of the most recent work.

---

## Where verification stands

| Layer | What was checked | Result |
|---|---|---|
| C reference models | human + E. coli captures | **18,156,029 extensions bit-exact** |
| RTL, Verilator | `bsw_top` vs captured bwa-mem2 outputs | **169,468 extensions, 0 failures** |
| HLS kernel | csim + csynth + cosim, Vitis HLS 2026.1 | **PASS**, 72 vectors / 4 configs |
| **Synthesized netlist, XSIM** | funcsim netlist vs RTL, 4-state, `glbl` GSR, at **N_PE=16 and 32** | **200/200 identical, every field, both widths** |
| Power-on state | randomized register init, 10 seeds | **PASS**, and proven able to fail |
| Timing | real P&R on KU5P-2 (same fabric/speed grade as VU47P) | **219.2 MHz** -> path (B) |

### What the netlist result means

The thing simulated was not the SystemVerilog — it was the Verilog netlist Vivado
synthesis actually produced (`LUT1`–`LUT6`, `CARRY8`, `FDRE`, `FDSE`, `MUXF7/F8`
from `unisims_ver`), elaborated with `glbl` so Global Set/Reset is modelled, in a
**4-state** simulator, judged by the same testbench code that judges the RTL.

On those 200 real E. coli extensions that establishes **no synthesis-vs-simulation
mismatch**, **no X propagation**, and **no reliance on zero-initialisation** — none
of which a Verilator run can establish at any vector count, because Verilator
compiles SystemVerilog to C++ and is 2-state.

It does **not** establish the full **160-PE** width (16 and 32 were run; 32 is the
most a BASIC XSIM licence allows), **timing** (no SDF, no post-implementation
netlist), or the real **VU47P** (a KU5P proxy was used). Nor anything about the AWS
shell or silicon.

---

## Picking it up again

### On the Linux box (this repo's home)

```sh
./scripts/run_rtl_regression.sh --quick   # ~1 min, 2 vector sets
./scripts/run_rtl_regression.sh           # ~5 min, 5 sets
./scripts/run_xinit_check.sh              # randomized power-on state, 10 seeds
make -C host/swa_hls check                # C models + exhaustive division proof + fuzzer
```

### On the Windows box (`C:\work\FPGA-speed-up-Project`, Vivado 2026.1)

```powershell
git pull
.\postsynth.ps1
```

That single command synthesizes `bsw_top_flat` at `N_PE=16`, writes the funcsim
netlist, simulates it in XSIM against 200 real extensions, and compares the result
with the committed Verilator baseline. Roughly 5–10 minutes. Useful switches:

| Switch | Effect |
|---|---|
| `-SkipSynth` | re-simulate the existing netlist only |
| `-KillStray` | stop leftover `xsimk`/`xelab` processes (they survive closing the terminal and lock the simulator executable) |
| `-Clean` | wipe the simulation work directory first |
| `-Npe 32` | wider array; baselines are committed for 16, 32 and 64 |

**Run PowerShell one line at a time.** Long lines get re-split and fail
confusingly; `postsynth.ps1` exists so there is only one short line to type.

---

## The two things left

**1. ~~Widen the gate-level array~~ — DONE, and the ceiling is reached.**

`N_PE=32` passed on 2026-10-07: 30,524 leaf cells, 200/200 identical, and it newly
covered the `DSP48E2` path (15 DSPs at 32 PEs, **0** at 16). Measured scaling
(`cells ~= 5,724 + 775*N_PE`, instances ~= 1.35x cells) puts `N_PE=40` at 99% of
XSIM's 50,000-instance cap and 48/64 over it. **32 is the practical local ceiling.**
Nothing further is worth attempting on a BASIC licence.

**2. The AWS build — the only substantive item left.** Full 160-PE gate-level simulation and post-implementation
timing simulation both need a full Vivado licence, which the **FPGA Developer AMI**
ships. That is not extra infrastructure: the F2 build has to run there regardless,
because the AWS HDK supports Vivado 2024.1–2025.2 and the local install is 2026.1.
See `docs/f2_build_runbook.md` and `docs/aws_readiness.md`.

---

## Three real defects this verification work found

None came from reading code. All three came from widening the data or the tooling.

1. **No `tlen > MAX_TLEN` guard** in `bsw_ctrl_fsm.sv`. The target index was
   truncated to 10 bits, so an oversize request **silently wrapped** and returned a
   confident wrong answer with `error=0`. Found by measuring `tlen=997` against the
   1024 limit.
2. **The gap-open regression was never executed.** `disc_mvsh.txt` worked, but no
   script ran it, and the committed golden set does not contain that bug — so
   nothing in CI would have caught a regression. Fixed by
   `scripts/run_rtl_regression.sh`.
3. **`bsw_max_tracker` had no guard on `N_PE`.** Below `2**MIDLEV` (= 16) its
   `MIDNODES` becomes 0, a zero-element array. **Verilator compiled that and
   reported 200/200 PASS** on a configuration Vivado rejects outright. An
   elaboration guard now fails it loudly in both tools. This one is the clearest
   illustration of why the post-synthesis layer exists at all.

---

## Tooling traps worth knowing before you resume

Each of these produced a wrong or confusing result at least once. The full list with
evidence is in `synth/postsynth/README.md`.

- `write_verilog -mode funcsim` **scalarizes aggregate ports**: `base_t [1023:0]
  target_i` becomes 1024 ports named `\target_i[1023]`. No testbench can bind to
  that, which is why `synth/postsynth/bsw_top_flat.sv` (flat vector ports) exists.
- **A failed synthesis leaves the previous netlist on disk**, and simulating it looks
  like a genuine result. Now guarded by `out/netlist_info.txt` plus an mtime check.
- **`xsim` exits 0 even when it refuses to run.** Judge its output, not its code.
- **`cmd.exe` treats `=` as a token delimiter**, so `-testplusarg VEC=C:/x` arrives as
  three tokens. Plusargs go through an options file and `-f`.
- **A time-based testbench watchdog is unreachable at gate level**: `#2000000000` is
  2x10^8 clock cycles. One run hung for **10 hours**. The flat testbench counts cycles.
- **`tb/tb_bsw_ext_flat.sv` is generated** by `scripts/gen_tb_bsw_ext_flat.py`. Never
  hand-edit it; its comparison logic must stay byte-identical to `tb_bsw_ext`, which
  is what makes an RTL-vs-netlist agreement attributable to synthesis.
- **Set `BSW_BUILD_DIR` per simulation.** Two concurrent runs clash over
  `/tmp/bsw/obj_tb_bsw_ext` and *both* silently produce no output.
