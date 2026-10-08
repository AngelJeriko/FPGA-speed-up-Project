# Demonstration: proving the synthesized hardware matches bwa-mem2

A script for showing, live, that the FPGA logic produces the same alignment scores
as the software it replaces — and that the check is capable of failing.

Runs on the Windows box with Vivado (`C:\work\FPGA-speed-up-Project`).
**Total: about 12 minutes**, of which ~6 is waiting. Timings measured, not estimated.

---

## 0. What is being demonstrated, and why it is not obvious

Say this part out loud before touching the keyboard, because the result means
nothing without it.

bwa-mem2 aligns DNA reads. The inner loop is a dynamic-programming alignment called
Smith-Waterman, and this project reimplements that loop as digital hardware. The
obvious question is "does the hardware compute the same answers as the software?",
and the project has answered it for **18 million** alignments.

But there is a second, sneakier question. Those 18 million checks were run under
**Verilator**, which translates the hardware description into C++ and runs it as a
program. That is fast and is why millions of cases were possible. It also means
**Verilator never sees the hardware**. It cannot tell you whether the chip-building
tool (Vivado) turns your description into the circuit you meant. Three ways that
goes wrong in practice:

- The description uses something no real chip can implement, and the tool rejects it.
- Worse: the tool *accepts* it and silently builds **different** logic.
- The description depends on a register starting at zero. In a simulator it does.
  On a real chip it starts as whatever the bitstream left there.

This is not hypothetical here. Verilator once passed a configuration of this design
that Vivado refuses to build at all, and reported "200 of 200 correct" on it
(`synth/postsynth/README.md`, the `N_PE=8` story).

**So this demonstration takes the actual circuit Vivado builds — the netlist, a list
of real FPGA primitives: lookup tables, carry chains, flip-flops, DSP multipliers —
and runs real E. coli sequencing data through it in a simulator that models unknown
values properly. Then it compares the result, field by field, against what bwa-mem2
itself produced.**

### Where the test data comes from

Worth a sentence, because "real data" is doing load-bearing work:

1. `scripts/make_ecoli_dataset.sh` downloads the *E. coli* K-12 reference genome
   (4,641,652 bases) and simulates 5,000 read pairs of 150 bp from it.
2. `scripts/capture_swa_ecoli.sh` patches bwa-mem2 to record every call to its
   alignment kernel, runs the alignment, and captures **49,468 of them** — the exact
   inputs and bwa-mem2's exact outputs.
3. Those become test vectors. The expected `score`, `qle` and `tle` in them are
   **bwa-mem2's own numbers**, not something this project invented.

The demo uses 200 of them. (Why only 200: gate-level simulation is roughly a
thousand times slower than Verilator. 200 is enough because a netlist-vs-description
difference is *structural* — it shows up on almost any input. The statistical
confidence came from the 18 million.)

---

## 1. Setup, before the audience arrives (~3 min)

Build the netlist in advance so the live portion is shorter.

```powershell
git pull
.\postsynth.ps1 -Npe 32 -KillStray
```

Confirm it ends with `RESULT: the synthesized netlist matches the RTL on every
field.` If it does not, stop and fix it before demoing.

**Why `-Npe 32`:** the array is built from 160 identical processing elements, one per
base of the query. The free Vivado simulator licence refuses any design over 50,000
instances, and the full 160-element netlist has 166,514. A 32-element build is
30,524 cells and fits. It is the widest that does — measured, not guessed
(`synth/postsynth/README.md` has the scaling table).

Be upfront about this when asked. It is a real limitation, and 32 PEs still exercises
every *kind* of logic in the design, including the DSP multipliers that a 16-element
build does not contain at all.

---

## 2. Show that the inputs are real (~1 min, no waiting)

```powershell
Get-Content sim\xsim\vectors\vec_ecoli_qlen32.txt -First 4
```

```
200
0 2 3 148 5 6 1 6 1 100 148 0 0 145 2 0
1 0
0 0 3
```

Read it out: 200 test cases. The first is a query of length 2 against a target of
length 3, starting score 148, gap-open 6, gap-extend 1. **bwa-mem2 returned score
148, query-end 0, target-end 0.** Then the two sequences themselves, as base codes.

```powershell
Get-Content sim\xsim\reference\verilator_ecoli_qlen32.txt -First 4
```

That is the same 200 run through the hardware *description*. The demo is about to run
them through the hardware *circuit* and compare.

---

## 3. The live run (~4 min)

```powershell
.\postsynth.ps1 -Npe 32 -KillStray -SkipSynth
```

`-SkipSynth` reuses the netlist from setup. `-KillStray` kills any leftover simulator
process — they survive closing a terminal and lock their own executable.

Narrate the four stages as they scroll:

| Stage | What to say | Time |
|---|---|---|
| `xvlog` SystemVerilog | compiling the testbench and type definitions | ~10 s |
| `xvlog` netlist | compiling the **circuit** — note it names `bsw_pe_0 … bsw_pe_30`, the 31 processing elements, each now a pile of primitives | ~20 s |
| `xelab` | linking it against AMD's own primitive models: `LUT6`, `CARRY8`, `FDRE`, `DSP48E2`. **These are the vendor's models of their own silicon.** Also pulls in `glbl`, which models the chip's global reset at power-on | ~60 s |
| `xsim` | the actual run, 200 alignments through the gate-level circuit | ~136 s |

Point at the `DSP48E2` line when it appears. At 32 elements the design uses 15 DSP
hard multipliers; at 16 it uses none. Hard arithmetic blocks are exactly where a
build-vs-description difference would hide, and this run covers them.

### The result

```
tb_bsw_ext_flat: 200 extensions, 0 failures, 0 max_off diffs -> ALL PASS

compared  : 200 rows
PASS: all 200 rows identical across every field.

RESULT: the synthesized netlist matches the RTL on every field.
```

Two separate statements, and it is worth separating them:

- **`0 failures`** — the circuit's `score`, `qle` and `tle` match **bwa-mem2's**
  recorded outputs. The hardware agrees with the software.
- **`200 rows identical across every field`** — the circuit also matches the
  description it was built from, on all seven outputs. Nothing was lost in
  translation to gates.

Also note what is *absent*: no `X VALUES` section. This simulator represents
"unknown" as a real value and propagates it. Every output came out definite, so
nothing in the design depends on a register happening to start at zero.

---

## 4. Prove the check can fail (~4 min) — do not skip this

A test that only ever passes is indistinguishable from a test that cannot fail. This
is the most persuasive part of the demo.

Break the hardware by one character: make a base match worth **+2** instead of **+1**.

```powershell
notepad rtl\bsw_score_matrix.sv
```

Find this line (about line 26):

```systemverilog
             : (q == t)                              ? W_MATCH_P
```

and change it to:

```systemverilog
             : (q == t)                              ? (W_MATCH_P + score_t'(1))
```

Save. Then re-run **with** synthesis, because the circuit has to be rebuilt:

```powershell
.\postsynth.ps1 -Npe 32 -KillStray
```

Expected (verified on this repo):

```
--- MISMATCHES (195 of 200 rows) ---
    per field: score=177, qle=26, tle=26, gscore=195, gtle=1, max_off=1

RESULT: differences found -- see the comparison above.
```

**195 of 200 alignments wrong.** A one-character change to the scoring rule, and the
check names the field and the row.

If instead you had dropped `-KillStray`/re-synthesis and the old netlist were still
on disk, the script would **refuse to run** rather than quietly verify the wrong
file — worth mentioning, since that mistake already happened once during development
and briefly looked like a real result.

### Restore — do not leave this in the tree

```powershell
git checkout -- rtl\bsw_score_matrix.sv
```
```powershell
git status --porcelain rtl
```

Empty output means clean. Optionally re-run to show green again.

---

## 5. State the limits (~1 min)

Credibility comes from saying this unprompted.

**Established**, on these 200 real alignments:

- the circuit Vivado builds behaves exactly as the description does
- it reproduces bwa-mem2's own `score`/`qle`/`tle`
- no dependence on power-on register values; no unknown values propagate
- no inferred latches, no multi-driven nets, no black boxes in synthesis

**Not established:**

- **The full 160-element array.** 32 was run — the licence ceiling. Same logic
  replicated, but full-width integration is unverified at gate level.
- **Timing.** This checks *what* the circuit computes, not *how fast*. No delay
  annotation, no post-placement netlist. Timing is measured separately:
  `synth/ooc/impl_bsw_top_f2.tcl`, which put the design at 219 MHz on this fabric.
- **The real device.** This ran on a Kintex UltraScale+ `xcku5p` — same fabric
  generation and speed grade as the target VU47P, but not the same chip. The VU47P
  is not installed locally.
- **Silicon, and the AWS shell.** Untouched by this demo.

Both remaining gate-level gaps — full width, and timing simulation — need a full
Vivado licence, which the AWS FPGA Developer AMI includes. That is where the FPGA
build has to happen regardless, since AWS supports Vivado 2024.1–2025.2 and this box
runs 2026.1.

---

## Quick reference

| | |
|---|---|
| Setup (build netlist) | `.\postsynth.ps1 -Npe 32 -KillStray` |
| Live run (reuse netlist) | `.\postsynth.ps1 -Npe 32 -KillStray -SkipSynth` |
| Break it | edit `rtl\bsw_score_matrix.sv` line ~26, then re-run **without** `-SkipSynth` |
| Restore | `git checkout -- rtl\bsw_score_matrix.sv` |
| Result file (committable) | `synth\postsynth\out\postsynth_result.txt` |
| Full technical account | `synth/postsynth/README.md` |
| What is compared against what | `docs/rtl_verification.md` |
| Where the data came from | `docs/ecoli_dataset.md` |

### If something goes wrong

| Symptom | Cause | Fix |
|---|---|---|
| `Unable to remove previous simulation file ... Access is denied` | a previous simulator process is still alive | add `-KillStray` |
| `does not meet the requirement to run the number of instances` | design over the 50,000-instance licence cap | use a smaller `-Npe`; the error prints the exact count |
| refuses with `the netlist predates the RTL` | you edited RTL but reused the old netlist | drop `-SkipSynth` |
| refuses with `these vectors need qlen up to N` | vector set wider than the array | use `vec_ecoli_qlen<N_PE>.txt` |
| run exceeds ~30 min | stalled | `Ctrl+C`; the testbench watchdog should name the extension it stopped on |
