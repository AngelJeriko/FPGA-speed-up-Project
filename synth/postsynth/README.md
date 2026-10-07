# Post-synthesis verification — the closest thing to the board, without the board

## The problem this answers

Every bit-exactness claim about `bsw_top` currently rests on **Verilator**, which
compiles SystemVerilog to C++. That makes it fast and makes 10,000-extension runs
practical, but it means Verilator **structurally cannot** see the failure mode of
"code that simulates but that the FPGA cannot run":

- constructs a synthesizer rejects outright
- worse: constructs a synthesizer *accepts* and turns into **different hardware**
  (inferred latches, multi-driven nets, combinational loops)
- reliance on simulator zero-initialisation — on real silicon a flop comes up as
  whatever the bitstream loaded
- X (unknown) propagation and reset sequencing — Verilator is 2-state, there is no X

This has already bitten this project: a real synthesis run threw ~147k
multi-driven-net warnings on RTL that Verilator passed clean
(see `feedback_verilator_misses_synthesis_bugs`).

## Two different questions

| Question | Right tool | Status |
|---|---|---|
| Is the algorithm bit-exact vs bwa-mem2? | Verilator, 10,000 E. coli extensions | **done** (`docs/rtl_verification.md`) |
| Does the hardware synthesis *actually builds* behave like that RTL? | post-synthesis netlist sim | this directory |

Running *more* vectors through Verilator buys **zero** additional confidence on the
second question. They are independent axes.

## The fidelity ladder

| Step | What it simulates | Catches | Cost |
|---|---|---|---|
| 0. `synth_design` | nothing — it *builds* | non-synthesizable code, latches, multi-driven nets | minutes |
| 1. XSIM behavioral | the same RTL, 4-state | X-prop, reset bugs, zero-init reliance | minutes–hours |
| 2. XSIM post-synth funcsim | the **netlist** (LUTs, flops, DSPs) | synthesis-vs-simulation mismatch | slow |
| 3. XSIM post-impl + SDF | netlist + real delays | timing-dependent behaviour | impractical here |
| 4. real F2 silicon | — | everything | AWS cost |

**Step 0 is most of the value for the least effort.** Synthesis is the *authority*
on what is buildable; a clean run largely answers the concern before any simulation.

Step 3 is deliberately skipped: it needs the real `xcvu47p`, which is not installed
locally (`get_parts xcvu47p*` → 0, BASIC licence), and gate-level sim with SDF is
slow enough to be useless at this scale.

## Throughput — plan for this

| Simulator | ~cost for 10,000 extensions |
|---|---|
| Verilator | ~7.5 min (measured, 45 ms each) |
| XSIM behavioral | hours |
| XSIM post-synth gate-level | days |

So do **not** run all 10,000 post-synth. `sim/xsim/vectors/` holds curated subsets
(5 / 20 / 200 extensions, taken from `rtl_ecoli.txt.gz`, **all verified passing
under Verilator** so a failure there is the netlist's fault and not the file's).

That is not a compromise. Gate-level sim asks a *structural* question — does the
netlist match the RTL — not a statistical one, and a netlist mismatch shows up on
almost any vector. The statistical confidence already came from Verilator.

Worth adding by hand: `host/extend_orchestrator/vectors/disc_mvsh.txt` — one
extension, the historic gap-open regression, the highest-value single vector here.

## Running it

From the repo root on the machine with Vivado:

```
vivado -mode batch -source synth/postsynth/synth_and_netlist.tcl
```

Optionally force a part: `... -source synth/postsynth/synth_and_netlist.tcl -tclargs xcku5p-ffvb676-2-e`

This prints the environment, the part inventory, red flags (inferred latches,
multi-driven nets), a warning histogram grouped by message ID, **and the funcsim
netlist's module header** — which settles how `bsw_top`'s packed-struct ports
(`bsw_config_t cfg_i`, `base_t [1023:0] target_i`, `bsw_result_t result_o`)
flattened, since the step-2 testbench wiring depends on it.

Output lands in `out/` (gitignored — the netlist is large and machine-specific).

Step 1, independently:

```
.\sim\xsim\run_bsw_ext.ps1 -Vec sim/xsim/vectors/vec_ecoli_20.txt
```

## STEP 0 on the flat top — run 2026-10-06, Vivado 2026.1, xcku5p-ffvb676-2-e

**Clean, and the wrapper works.**

```
errors            : 0
critical warnings : 0
inferred latches  : 0
multi-driven nets : 0
black boxes       : 0
```

Resources are **identical** to the bare `bsw_top` run — 89,752 LUT / 27,265 FF /
140 DSP48E2 / 0 BRAM / 0 URAM — which is the expected result and a useful check:
`bsw_top_flat` is continuous assignments only, so it must cost zero logic. Same four
warning causes at the same counts (100 / 18 / 3 / 1).

The netlist port header is what this run existed to produce:

```
module bsw_top_flat
   (clk, rst_n, restart_mode, req_valid_i, req_ready_o,
    query_flat_i, target_flat_i, cfg_flat_i,
    result_valid_o, result_ready_i, result_flat_o);
```

Eleven ports, all intact — against roughly 1,200 scalarized ports when `bsw_top`
was synthesized directly. `tb_bsw_ext_flat` can bind to this, so **step 2 is
unblocked**.

### A false alarm in this script, since fixed

The first flat run's summary reported `multi-driven mentions in log : 7` while the
netlist query said `multi-driven nets : 0`. The query was right. `vivado -mode
batch` **echoes the sourced script into the log**, so a plain grep counted this
file's own comments and `puts` strings containing the phrase as findings. The
counter now requires a `WARNING:`/`ERROR:` prefix, which echoed script text never
has. Worth remembering generally: grepping a Vivado batch log for a phrase will
match the script that produced it.

## STEP 2 is licence-blocked on this install — and what replaces it

The gate-level run got all the way through `xvlog` and `xelab`: the 41 MB netlist
compiled, elaborated against the real primitive models (`CARRY8`, `LUT1`-`LUT6`,
`FDRE`, `FDSE`, `MUXF7/F8`, `DSP48E2`), and the snapshot built. Then:

```
ERROR: The current Vivado Simulator license tier you have, BASIC, does not meet the
requirement to run the number of instances in this design. Number of instances in
this design, 166514, exceed maximum allowed 50000.
```

**That ceiling is on design size, not run length, so running fewer vectors cannot
help.** The 160-PE netlist is 3.3x over the limit.

### What the instance budget allows

Scaling from the measured 160-PE synthesis (array 80,180 / FSM 27,587 / tracker
15,307 cells; 123,383 cells -> 166,514 instances, ratio ~1.35):

| N_PE | approx cells | approx instances | fits BASIC? |
|---|---|---|---|
| 8 | 32,361 | ~43,700 | **yes** (87% of cap) |
| 16 | 37,135 | ~50,100 | marginal / no |
| 32 | 46,684 | ~63,000 | no |
| 160 | 123,383 | 166,514 | no |

The FSM dominates the floor: it latches `target[1024]` (3,072 flops) and does not
shrink with `N_PE`. So `N_PE=8` is the only configuration with real headroom.

### The reduced-array route, validated in RTL

`N_PE` in `bsw_top_flat` is driven by a **define**, so both tools shrink the array
from one switch (a `-G`/`-generic` parameter override only reaches the TOP module,
which here is the testbench, so it cannot reach the wrapper):

```
vivado -mode batch -source synth/postsynth/synth_and_netlist.tcl -tclargs xcku5p-ffvb676-2-e bsw_top_flat 8
BSW_NPE=8 ./scripts/run_sim.sh tb_bsw_ext_flat      # the RTL side
```

Vectors must then satisfy `qlen <= N_PE`, because `bsw_ctrl_fsm` correctly
**rejects** a longer query (`error=1`, all outputs zeroed) rather than computing a
wrong answer. `scripts/filter_vectors_by_qlen.py` builds the subsets;
`sim/xsim/vectors/vec_ecoli_qlen8.txt` holds 200 real E. coli extensions with
`qlen` 1..8 (there are 498 such in the 10,000, since a seed's left-extension near a
read's start is short).

Verified on this box:

| Check | Result |
|---|---|
| `N_PE=8`, `qlen<=8` vectors | **200/200, 0 failures** |
| `N_PE=8`, unfiltered vectors | rejected with `err=1`, outputs zeroed — never a wrong answer |
| `N_PE=160` default unchanged | 200/200 |

So the filter is load-bearing, and the reduction is safe rather than papering over
anything.

### Randomized register init — the available substitute for 4-state

`scripts/run_xinit_check.sh` fills uninitialised registers with random values
instead of Verilator's silent zeros, which is the closest local approximation of the
power-on hazard XSIM's 4-state engine would have exposed. **10/10 seeds pass** on
200 real extensions.

That claim is only worth something because the check was shown to go red, and
getting there corrected a mistake: with the compile-time switches
(`--x-initial unique --x-assign unique`) **alone** the test is INERT — deleting
`bsw_ctrl_fsm`'s state-register reset entirely still gave 5/5 passes. The runtime
plusarg `+verilator+rand+reset+2` is load-bearing; with it, that same mutant **hangs
on seed 1**. It is also probabilistic: only 1 of 3 seeds caught it.

An earlier mutant (removing the `pr_i`/`pr_j` reset in `bsw_max_tracker`) passed all
seeds even with randomization on. That one is *equivalent*, not uncovered — those
registers are fully written before ever being read.

### Where full-design gate-level belongs

On the **FPGA Developer AMI** on EC2, which ships a full Vivado/XSIM licence. That
is not extra infrastructure: the F2 build has to happen there anyway, because the
AWS HDK supports Vivado 2024.1-2025.2 and this box has 2026.1.

## Known trip-ups, already fixed

These cost a Vivado run each; recorded so they are not rediscovered.

**Include paths.** An include directive resolves relative to the **including file's
own directory**. `rtl/*.sv` can include `bsw_pkg.sv` because it sits beside them;
`synth/postsynth/bsw_top_flat.sv` cannot, and Vivado 2026.1 failed with
`[Synth 8-9263] cannot open include file 'bsw_pkg.sv'`. Verilator hid it, because
`run_sim.sh` passes `-I rtl`. The wrapper therefore has **no include directive** --
every flow compiles `rtl/bsw_pkg.sv` ahead of it, so `import bsw_pkg::*` resolves
from the compilation unit. The Tcl also sets `include_dirs` on the fileset as
belt-and-braces for any future wrapper outside `rtl/`.

Note the two tools differ here: Verilator does **not** search the including file's
directory unless told (`-I`), while Vivado does. So "it compiles under Verilator"
says nothing about Vivado's include resolution, and vice versa.

**`// Verilator ...` as the first words of a comment** is parsed as a Verilator
pragma: `Unknown verilator comment`. Detection is case-insensitive and ignores
leading whitespace, so `//     verilator ...` trips it too. This bit twice. Reword so
the word is not comment-initial.

**`xsim` plusargs on Windows.** `xsim.bat` is a batch wrapper and **cmd.exe treats
`=` as a token delimiter**, so `-testplusarg VEC=C:/path` arrives as three tokens
(`-testplusarg`, `VEC`, `C:/path`) and xsim reports `Expected a switch but found C`.
Quoting does not reliably survive the PowerShell -> cmd -> exe hop. Both runners now
write the plusargs to an options file and pass `-f <file>`, which cmd never
tokenizes. `-runall` stays on the command line, having no `=`.

**The funcsim netlist exceeds xvlog's line counter.** `WARNING: [VRFC 10-10065] line
number 1048576 exceeds maximum value 1048575` -- the netlist is over a million lines.
Cosmetic; it only affects line numbers in later diagnostics for that file.

**`get_license_features` does not exist in 2026.1.** Not needed -- Vivado prints the
licence in its own startup banner (`[Common 17-3922]`).

## Part inventory on the development box (2026.1, BASIC licence)

| Family | Parts | |
|---|---|---|
| `xcvu47p` (the real F2 device) | **0** | not installed |
| `xcvu9p` | 0 | not installed |
| `xcku5p` | **36** | **installed — the proxy in use** |
| `xczu7` | 0 | not installed |
| `xc7v` / `xc7k` / `xc7a` | 203 / 212 / 210 | installed |

So `xcku5p-ffvb676-2-e` is the automatic choice: Kintex UltraScale+, the **same
fabric generation and the same `-2` speed grade** as the VU47P. For steps 0–2 that
is the right proxy, since synthesizability and netlist equivalence are
language-and-inference questions. Only resource mapping and timing are
device-specific, and neither is claimed here.

## Output: paste one file, not the console

This run prints tens of thousands of lines -- the DSP inference tables are hundreds
long, and the per-instance area table has a row for each of 160 PEs. No terminal
scrollback holds that, and copying it out of a console is a waste of effort.

So the script writes **`out/step0_summary.txt`**: part, top module, available parts,
red flags, resource counts, every warning cause with one example, and the netlist's
port header. Under a page. That is the file to share.

Nothing is ever lost either way: `vivado -mode batch` writes the complete console
output to `vivado.log` in the directory you ran it from. To find anything in it:

```
Select-String "synthesizing on|CRITICAL|^ERROR" vivado.log
```

## STEP 0 results — run 2026-10-06, Vivado 2026.1

**Verdict: clean. No evidence of the failure class this directory exists to find.**

```
Synthesis finished with 0 errors, 0 critical warnings and 141 warnings
338 Infos, 121 Warnings, 0 Critical Warnings and 0 Errors
inferred latches : 0
black boxes      : none
multi-driven nets: none reported
```

The ~147k multi-driven-net warnings seen on an earlier design did **not** recur.
Total warnings collapse to **4 distinct causes**, all benign:

| Count | ID | Cause | Assessment |
|---|---|---|---|
| 100+ | Synth 8-7129 | `qlen_i[15]` in `bsw_max_tracker` unconnected / no load | Expected. `len_t` is 16 bits; `qlen <= 160` needs 8. Unused upper bits. (Vivado caps this message at 100, so the true count is higher.) |
| 18 | Synth 8-11067 | `parameter` in package `bsw_pkg` treated as `localparam` | Stylistic. Package parameters are not overridable; no behavioural effect. |
| 3 | Synth 8-6014 | `cfg_q_reg[end_bonus]` removed — unused sequential element | **Real, and already known.** See below. |
| 1 | Timing 38-242 | `HD.CLK_SRC` not set on clock port in OOC mode | Expected in out-of-context. Blocks clock-skew estimation only; timing lives in `synth/ooc/impl_bsw_top_f2.tcl`. |

### Resource usage (from synth_design's own Report Cell Usage — authoritative)

| | |
|---|---|
| LUT (1–6) | 89,752 |
| FF (FDRE 27,146 + FDSE 119) | 27,265 |
| DSP48E2 | 140 |
| CARRY8 | 5,158 |
| MUXF7 / MUXF8 | 720 / 348 |
| BRAM / URAM | **0 / 0** |
| total cells | 123,383 |

By hierarchy: `u_array` 80,180 · `u_fsm` 27,587 · `u_tracker` 15,307.

> The script's own red-flag line initially mis-reported these as `LUT 0` and
> `DSP 1260`. Two Vivado traps: `PRIMITIVE_TYPE =~ LUT.*` matches nothing (the real
> spelling is `LUT.values.LUT6`), and Unisim transformation splits each `DSP48E2`
> into 9 sub-cells, so 140 DSPs count as 1260. Fixed to match on `REF_NAME`.

### The one finding worth recording: `end_bonus` is dead inside `bsw_top`

Synthesis removed `cfg_q_reg[end_bonus]` because nothing in `bsw_top`'s hierarchy
reads it. Verified by inspection: the field is *written* by `bsw_seed_unit.sv:165`
(real values — `pen_clip5` / `pen_clip3`) and by the testbench, but never consumed.

This is **not** a correctness defect. bwa-mem2 applies `end_bonus` in the *caller*
(`mem_chain2aln`), not inside the SW kernel, so the array is right to ignore it —
and `tb_bsw_ext.sv:100` already says so (`not used by the array; carried for
completeness`). All 10,000 E. coli and 15,887 golden vectors pass bit-exact with it
carried-but-unused.

It is still worth knowing that `bsw_seed_unit` populates a config field the core
discards. That is a trap for anyone who later assumes setting it does something.

## STEP 2 — what the netlist header forced

The step-0 run answered the open question, in the awkward direction:

```
module bsw_top
   (clk, rst_n, restart_mode, req_valid_i, req_ready_o,
    \query_i[159] , \query_i[158] , \query_i[157] , ...
```

`write_verilog -mode funcsim` **scalarizes aggregate ports**. `base_t [159:0]
query_i` became 160 separate ports, and `target_i` 1024 more — roughly 1,200 ports
where the RTL had three, with escaped bracket names. `tb_bsw_ext`'s
`.query_i(query)` cannot bind to that; no port named `query_i` exists.

So step 2 goes through **`bsw_top_flat`** (in this directory): a wrapper exposing
plain 1-D vectors (`query_flat_i [479:0]`, `target_flat_i [3071:0]`,
`cfg_flat_i [159:0]`, `result_flat_o [96:0]`), which the writer preserves. It is
continuous assignments only — no logic, no state.

`tb/tb_bsw_ext_flat.sv` drives it, and is **generated** from `tb_bsw_ext.sv` by
`scripts/gen_tb_bsw_ext_flat.py` so the pass/fail logic cannot drift between the
two. That identity is the point: when the RTL and netlist runs agree, the agreement
is about synthesis, not about two harnesses that happen to be wired alike.

### Wrapper verified transparent before anything trusts it

| Check | Result |
|---|---|
| `tb_bsw_ext` (direct `bsw_top`), 200 E. coli | 200/200, 0 failures |
| `tb_bsw_ext_flat` (via wrapper), 200 E. coli | 200/200, 0 failures — identical |
| `tb_bsw_ext_flat`, full 10,000 E. coli | **10,000/10,000, 0 failures** |
| wrapper deliberately corrupted (3-bit rotate on `target`) | **5 of 20 go red** |

The last row matters most: a green wrapper proves nothing until shown it can go red.

### Running step 2

```
vivado -mode batch -source synth/postsynth/synth_and_netlist.tcl
```
then
```
.\sim\xsim\run_postsynth_bsw.ps1 -Vec sim/xsim/vectors/vec_ecoli_5.txt
```
then compare against the committed Verilator reference:
```
python scripts/compare_dumps.py sim/xsim/reference/verilator_ecoli_5.txt sim/xsim/xsim_postsynth_work/postsynth_vec_ecoli_5.txt
```

Start at 5 vectors, then 20, then 200. `scripts/compare_dumps.py` reports X values
separately from value mismatches — an X is the more serious finding, and the one
Verilator is structurally unable to produce. It is negative-tested: it goes red and
exits 1 on an injected value change, on an injected `x`, and warns on a short run.

`sim/xsim/reference/verilator_ecoli_{5,20,200}.txt` are the committed RTL baselines,
produced on this repo's Verilator 5.020.

## A note on part choice

`xcvu47p` is usually absent from a stock install. For steps 0–2 a proxy is nearly
as good: whether code is synthesizable, and whether the netlist matches the RTL,
are language-and-inference questions, not device questions. Only resource mapping
and timing are device-specific, and neither is claimed here. Timing lives in
`synth/ooc/impl_bsw_top_f2.tcl`.
