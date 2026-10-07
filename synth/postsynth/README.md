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

## A note on part choice

`xcvu47p` is usually absent from a stock install. For steps 0–2 a proxy is nearly
as good: whether code is synthesizable, and whether the netlist matches the RTL,
are language-and-inference questions, not device questions. Only resource mapping
and timing are device-specific, and neither is claimed here. Timing lives in
`synth/ooc/impl_bsw_top_f2.tcl`.
