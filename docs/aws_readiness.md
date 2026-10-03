# FPGA Accelerator: AWS Readiness

**As of 2026-10-03.** A readiness assessment for moving the BWA-MEM2
sequence-alignment accelerator from local simulation onto AWS F2 hardware.

*Written for a non-specialist reader: every technical term is explained in the
glossary at the end. A live, commentable copy is at
<https://claude.ai/code/artifact/5206bfc8-b822-4fc3-a94a-901f4585e790> — this
file is the version of record in the repository.*

## The short answer

**Yes — every check we can run without AWS hardware now passes, and the one
problem that could have blocked us has a measured solution.**

The accelerator computes bit-for-bit identical results to the software it
replaces, verified on 49,468 real alignment cases. It fits on the target chip,
runs fast enough, and the AWS-specific wiring compiles under AMD's real
toolchain. The build scripts are written and rehearsed.

Nothing further can be learned from simulation. The remaining unknowns — how the
design behaves on the actual chip, and whether it survives the full AWS build —
can only be settled by running the build. That is the recommendation.

## What "ready for AWS" has to mean

Renting FPGA hardware costs money, and one step in the AWS build is irreversible
once started. So "ready" is not a feeling — it is four specific things being
true first. All four now are.

| # | The gate | What it has to mean | How we checked it | Result |
| --- | --- | --- | --- | --- |
| 1 | Right answers | The hardware produces exactly what the software produces, not merely something similar | Captured 49,468 real alignment cases from bwa-mem2 and replayed every one | All 49,468 match exactly |
| 2 | Fast enough | The circuit keeps up with the clock speed AWS forces on us | Ran a full place-and-route on an equivalent chip and measured it | 219.2 MHz measured; solution in place for the 250 MHz requirement |
| 3 | Fits the AWS frame | Our logic connects correctly to AWS's fixed surrounding circuitry | Compiled the whole region in AMD's real Vivado toolchain | Passes, and it caught a real bug our faster checks missed |
| 4 | Buildable on budget | We can build, test and deploy without burning rented time on avoidable failures | Wrote and dry-ran the build scripts; put a cheap fail-fast check before the expensive step | Scripts written, rehearsed, documented |

*"Place-and-route" means the tool deciding where each piece of logic physically
sits on the chip and how the wires run between them — the step that determines
real speed.*

## Gate 1: it runs fast enough

**This was the one issue that could have blocked the move, and it is now
resolved by measurement rather than hope.**

### The problem

An FPGA runs on a clock — a steady tick. Every tick, the circuit must finish all
its work and settle. If the clock ticks faster than the circuit can settle, the
chip does not slow down or crash. It reads half-finished values and produces
**wrong answers, silently**. So the circuit's maximum speed has to be known and
respected.

The older AWS F1 board let us choose a slow clock. **The F2 board fixes its main
clock at 250 MHz** and offers no option to change it. That became a hard
requirement rather than a preference.

### The measurement

We ran a full place-and-route on an AMD UltraScale+ chip of the same family and
speed grade as the F2 target, which is the closest stand-in available without an
AWS account.

| What | Result |
| --- | --- |
| Required by F2 | 250 MHz |
| Our core, measured | **219.2 MHz** |
| Shortfall | about 12% |

We could not close that 12% gap. The slowest path is limited by wire routing,
not by logic we could simplify, and the tool's own optimiser reported the
remaining gap as beyond reach.

### The solution

We split the design into **two clock domains**. The outer part that talks to AWS
runs at the required 250 MHz. The compute core runs on a separate, slower clock
at 125 MHz, with a carefully designed handshake passing data between the two.

This is standard, well-understood practice, and the numbers are comfortable:

- The core is measured good to 219.2 MHz and we only ask it for 125 MHz —
  **43% below its proven limit**.
- The cost is about 4,100 extra flip-flops (small storage elements) and half the
  theoretical throughput.
- Both versions — single-clock and two-clock — compile cleanly in AMD's real
  Vivado toolchain.

If we later want more speed, AWS also offers a 187.5 MHz clock, which would give
50% more throughput while still sitting 14% under the measured limit. We are
deliberately not using it for the first build: get it working first, then
optimise.

### One caution worth recording

An earlier measurement on an older, slower stand-in chip suggested only
124.4 MHz. On the correct chip family the same design reached 219.2 MHz — **the
old chip was misleading us by about 76%**. We are relying on the newer number
because it comes from the right chip family, but it is still a stand-in, not the
actual F2 part. See the open risks section.

## Gate 2: it computes the right answer

**The accelerator reproduces the software's output exactly — not approximately —
on 49,468 real cases taken from a live bwa-mem2 run.**

### Why "exactly" is the bar

In genomics, a score that is off by one can change which alignment wins, which
changes where a read is placed, which changes the final biological result.
"Close enough" is not a usable standard. The term for the standard we hold
ourselves to is **bit-exact**: every output bit identical to what the software
produced.

### What we did

We built a small, fully reproducible test genome — the *E. coli* reference
genome (4.64 million bases) with 5,000 simulated read pairs. Then we
instrumented bwa-mem2 to record the inputs and outputs of every single call to
its alignment-extension routine, and replayed all of them through our model.

| Measure | Result |
| --- | --- |
| Alignment calls captured | 49,468 |
| Reproduced exactly | **49,468 (100%)** |
| Effect on bwa-mem2's own output | **none — byte-identical to an uninstrumented run** |

That last row matters: it proves the act of measuring did not disturb the thing
being measured.

### What we found along the way

The function that published descriptions of bwa-mem2 point to — `ksw_extend` —
**is dead code**. Nothing in the program ever calls it. The real work happens in
a different, hand-optimised batch routine.

Had we instrumented the obvious function, we would have produced an empty file
and not understood why. Finding this is part of why we trust the dataset we now
have.

### How we know the tests actually work

A passing test proves nothing until you have seen it fail. So for every
correctness claim, we deliberately introduced small bugs into the design and
confirmed the tests caught them — a practice called **mutation testing**.

This is not theoretical. The same method previously caught a genuine bug in our
own hardware: it opened alignment gaps from the wrong value, which affected one
output field for short reads. The existing tests had missed it because of a
coverage gap. We fixed it, added a test that fails without the fix, and it is in
the version going to AWS.

### One honest caveat

Under deliberately extreme scoring settings that bwa-mem2 never uses by default,
our model disagrees with bwa-mem2 on roughly 7 cases in 350,000 — about 0.002%.
The disagreement is confined to two secondary output fields, and we traced it to
the two programs using a different placeholder value for "no result found". Both
placeholders take the same downstream branch, so it cannot change an alignment.
It is documented and has its own regression test, so we will know if it ever
changes.

## Gate 3: the AWS wiring compiles

**The AWS-specific part of the design compiles cleanly in AMD's real Vivado
toolchain — and doing so caught a genuine bug our faster checks had missed.**

### What has to connect

AWS does not give you a blank chip. They provide a fixed **shell** — their own
circuitry handling the PCIe link to the host computer, the memory controllers
and the clocks. You fill in the **custom logic** region in the middle, and your
design must connect correctly to a fixed list of several hundred signals, every
one of which has to be driven properly.

Getting this wrong is a common way to lose a day: the design simulates perfectly
and then fails to build.

### What we checked

We wrote the F2 version of this wrapper and checked it two ways:

1. **Fast check (seconds):** validated against the real AWS signal list and
   default-connection files from AWS's own F2 toolkit, so we are matching their
   actual interface rather than our understanding of it.
2. **Real check (minutes):** compiled the entire custom logic region in Vivado
   2026.1 — AMD's real toolchain, and a *newer* release than AWS's build flow
   accepts. That is the right direction to be wrong in for a synthesis check,
   but see the toolchain note in the open-items table.

Both pass. Three low-level warnings remain, and all three come from AWS's own
placeholder memory module, not from our code. A simulation of the complete
wrapper passes all 13 of its tests and returns the correct alignment score.

### Why this step earned its keep

Our fast checker uses Verilator, an excellent open-source simulator. **It did
not notice that one output signal was left unconnected** — floating, driving
nothing. Real synthesis caught it immediately.

We fixed the signal, then strengthened the fast checker so it would catch that
class of bug in future, then deliberately re-broke the signal to confirm the
improved checker now fails. This is the general lesson we keep hitting:
*passing simulation is not the same as being buildable in hardware*, and the
only cure is to run the real tool.

### Size

| Resource | Used | What it is |
| --- | --- | --- |
| LUTs | 63,985 | Lookup tables — the chip's basic logic blocks |
| Flip-flops | 31,308 | Single-bit memory elements |
| DSP blocks | 140 | Dedicated hardware multipliers |
| Block RAM | 0 | On-chip memory blocks |

These are absolute counts measured on a stand-in device. The F2 target chip is
substantially larger, so capacity is not a concern; the figures are here as a
baseline to compare the real build against.

## Gate 4: we can build it without wasting money

**The build is scripted, documented and rehearsed, and the expensive steps are
deliberately last.**

### Where the money goes

Two AWS steps cost real money or real time, and neither is easy to undo:

- **Baking the FPGA image.** AWS takes your compiled design and converts it into
  a deployable image (an *AFI*, Amazon FPGA Image). You submit it and wait; it is
  not interactive.
- **Renting the F2 machine.** The `f2.6xlarge` instance is the cheapest F2 option
  and still the costly part of the loop.

The mistake to avoid is paying for both and then discovering a problem that a
free check would have caught.

### How the plan avoids that

The ordering is deliberate: **everything cheap happens first, and there is a
hard checkpoint before anything expensive.**

1. Compile and place-and-route on a cheap build machine — takes hours, costs
   little. Note the toolchain constraint below: this has to be a Linux machine
   with a Vivado version AWS supports, which in practice means a small EC2
   instance running AWS's FPGA Developer AMI (not an F2 instance).
2. **Checkpoint:** read the timing report. If the design does not meet its clock
   target, stop here. Nothing expensive has been paid yet.
3. Only after that checkpoint passes, submit the image for baking.
4. Only after the image exists, start the F2 machine, run the test, shut it down.
   Minutes, not hours.

### What is already written

- A staging script that sets up the AWS project, copies the design files in the
  correct order, generates the file list and launches the build with the
  two-clock option enabled. Its dry run is clean.
  (`scripts/f2/stage_cl_project.sh --clk-gen`)
- A step-by-step runbook covering the build, the known pitfalls and what each
  failure message means. (`docs/f2_build_runbook.md`)
- A host test program that loads the image onto the FPGA, submits a known
  alignment problem and checks the answer against the expected result. It has
  been round-trip verified in simulation. (`host/test_bsw.c`)

So the first F2 session has one job: run one command and read one number.
Everything else has been done in advance.

## Independent confirmation: a second implementation agrees

**We built the same algorithm a second time, by a completely different route,
and it produces identical results — including when run against the hardware it
generates.**

### What this is

There are two ways to build an FPGA design. Our main design is written by hand
in SystemVerilog, a hardware description language. The other route is
**High-Level Synthesis (HLS)**, where you write ordinary C++ and the tool
generates the hardware for you.

We did the second route as an independent check. If two implementations built
different ways agree bit-for-bit on hundreds of thousands of cases, the
arithmetic is very likely right.

### What passed

| Stage | What it proves | Result |
| --- | --- | --- |
| C simulation | The C++ version matches bwa-mem2 | **PASS** — 72/72 vectors exact |
| Synthesis | The C++ converts to real hardware at the needed speed | **PASS** — 172.6 MHz, vs 125 MHz needed |
| **Co-simulation** | **The generated hardware itself matches bwa-mem2** | **PASS** — 72/72 vectors exact |

Co-simulation is the one that counts. It takes the hardware the tool actually
generated, simulates it signal by signal, feeds it the same test inputs, and
compares the outputs. It is the difference between *"the C++ is correct"* and
*"the circuit is correct"*.

The test vectors span four different scoring configurations, so they exercise
code paths that bwa-mem2's default settings never reach. We also ran 3.5 million
randomly generated test cases against the reference, with zero disagreements.

### What it tells us about which design to ship

The comparison is informative, and it confirms the hand-written design is the
right one for hardware:

| | HLS version | Hand-written core |
| --- | --- | --- |
| Size (LUTs) | 7,719 | 63,985 |
| Time per alignment | 17,183 clock ticks | about 417 clock ticks |
| Overall efficiency | — | **roughly 5x better** |

The HLS version is about 8x smaller but roughly 41x slower, because the C++
describes a step-by-step calculation and the tool faithfully built a
step-by-step machine. The hand-written core computes 160 cells of the alignment
grid every clock tick instead of one.

So the HLS kernel is not what goes to AWS. Its value is that it independently
confirms the arithmetic, it is readable by people who do not read hardware
languages, and producing it proved the full AMD toolchain works end to end on
our machine.

## What we have *not* proven

**Being ready to start does not mean nothing can go wrong. These are the open
items, and most of them are open precisely because only the AWS build can close
them.**

| Open item | Why we think it is manageable | What actually settles it |
| --- | --- | --- |
| Timing was measured on a **stand-in chip**, not the real F2 part | Same chip family and speed grade; we are asking for 125 MHz against a measured 219 MHz, so 43% of margin absorbs a worse result | Step 1 of the AWS build |
| The **full build has never run** — our logic has never been placed alongside AWS's shell | Our region compiles alone, and connects to AWS's real signal list | Step 1 of the AWS build |
| The **image has never been baked** — AWS can reject designs for rule violations | We followed AWS's own project template and scripts | Step 3 of the AWS build |
| **No real silicon run.** Host-to-FPGA communication and the register interface are verified only in simulation | Simulation of the full wrapper passes all 13 tests with the correct result | Step 4 of the AWS build |
| **The memory path is not used yet.** This build uses only the simple control interface, not the chip's high-bandwidth memory | Intentional: this first build tests correctness, not speed | A later build, once correctness is confirmed |
| ~~**The test data is small and clean** — 5,000 simulated *E. coli* read pairs~~ **CLOSED 2026-10-03** | Re-captured on human data: 18,156,029 records across 200,000 real ERR174310 pairs and a 150 bp high-divergence simulated set, all bit-exact. It also found a real defect — see below | Done |
| **Toolchain version mismatch.** AWS's F2 kit supports Vivado 2024.1, 2024.2, 2025.1 and 2025.2. Our local install is **2026.1**, outside that range | It does not affect any result in this report — the local timing and synthesis work is not AWS-dependent. It only affects where the AWS build runs | Running step 1 on an EC2 instance with AWS's FPGA Developer AMI, which ships a supported Vivado and its licence |

### Update 2026-10-03: the dataset item is closed, and it found a bug

Re-capturing on human data closed the "small and clean dataset" item above, and
produced two results worth recording.

**Bit-exactness holds at scale.** 15,437,657 extension calls from 200,000 real
ERR174310 read pairs against hg38 chr1–5, plus 2,718,372 from a deliberately
messy 150 bp simulated set — **18,156,029 records, zero mismatches**, on all
three models. That is 367x the original *E. coli* evidence, on real reads.

**The input envelope is sound but tight.** The hardware accepts targets up to
1,024 bases. *E. coli* only ever produced 437, which made the limit look
generous. Real human reads reached 783, and the 150 bp high-divergence set
reached **997 — 27 bases from the limit**. The sizing is correct for the
intended workload, and it has far less margin than the earlier data implied.

**That question exposed a defect.** Asking "what happens if a target exceeds
1,024?" revealed that nothing checked it. The hardware rejected over-long
*queries* but not over-long *targets*, and the target index is truncated to
10 bits — so an oversize request would have silently wrapped around and
returned a confident wrong answer with no error flag. We reproduced exactly
that: the unfixed design answers an impossible request with `score=2` and
`error=0`.

It is fixed, with two tests that fail without the fix, and the full hardware
test suite re-run clean. Finding this before the AWS build rather than after is
the clearest argument that the readiness review was worth doing.

### A strategic caveat that belongs in the record

Our own profiling found that the alignment-extension kernel we are accelerating
accounts for roughly **6.5% of bwa-mem2's total runtime** on short reads. Even a
perfect accelerator for it therefore yields a modest end-to-end speedup on that
workload.

This figure is lower than published literature, which puts the same kernel at
25–47% for other workloads, so our number is likely a short-read outlier. But it
means the honest framing of this project is **a correctness-first bring-up of a
hardware alignment engine**, not a claim of large end-to-end acceleration. The
dominant cost in bwa-mem2 is the seeding stage, which is a separate and harder
problem.

None of this changes the readiness question. It changes how the result should be
described once it works.

## What happens next

Four steps, each with a decision point. The first two cost almost nothing.

1. **Build the design against the AWS shell.** On a cheap EC2 build instance
   running AWS's FPGA Developer AMI, run the staging script with the two-clock
   option and let AWS's build script place and route the whole thing. Takes a
   few hours, unattended. (Our local Vivado 2026.1 cannot do this step — see the
   toolchain constraint below.)
   - *Decision point:* did it build at all?
2. **Read the timing report.** Confirm the compute core meets 125 MHz and the
   interface meets 250 MHz on the real F2 chip.
   - *Decision point:* **this is the fail-fast gate.** If timing misses, stop and
     fix it. Nothing has been paid.
3. **Submit the image for baking.** AWS converts the build into a deployable
   FPGA image and returns an identifier.
   - *Decision point:* did AWS accept it? A rejection names the rule that was
     broken.
4. **Run it on an `f2.6xlarge`.** Load the image, run the host test program,
   confirm it returns the expected alignment score, shut the machine down.
   - *Decision point:* correct answer on real silicon. **This is first light.**

### After that

Once step 4 passes, the project moves from "does it work" to "how fast can it
go". That means connecting the chip's high-bandwidth memory, feeding it real
volumes of data, and measuring actual throughput against the software baseline.
There is also a reserve option to raise the compute clock from 125 MHz to
187.5 MHz for 50% more throughput, which we are holding back until correctness
is confirmed.

If step 2 fails, the fallback is already identified: the slowest path is limited
by wire routing in one specific reduction circuit, and the next thing to try is
restructuring that circuit rather than the design as a whole.

## Glossary

Alphabetical. Every term used above.

| Term | Plain meaning |
| --- | --- |
| **AFI** (Amazon FPGA Image) | The deployable package AWS makes from your compiled design. You submit a build and AWS returns an image ID you can load onto an FPGA. |
| **Alignment** | Working out where a short piece of DNA came from in a reference genome, allowing for differences. |
| **AXI-Lite** | A simple, slow, standard way for a host computer to read and write a handful of control registers on a chip. Fine for commands, not for bulk data. |
| **Bit-exact** | Every output bit identical to the reference software's. Not "approximately equal" — the same number, always. |
| **bwa-mem2** | The widely used DNA sequence alignment program we are accelerating. Our hardware must match it exactly. |
| **Block RAM** | Small dedicated memory blocks built into the FPGA, used for buffers and lookup tables. |
| **Clock / MHz** | The steady tick that drives the circuit. 250 MHz means 250 million ticks per second. Every tick, the logic must finish and settle. |
| **Clock domain crossing (CDC)** | Safely passing data between two parts of a chip running on different clocks. Needs a careful handshake, or data gets corrupted. |
| **Co-simulation** | Simulating the *generated hardware* signal by signal and checking its outputs. Stronger than testing the source code, because it tests what was actually built. |
| **Custom logic (CL)** | The region of the AWS FPGA you fill in with your own design, surrounded by AWS's fixed shell. |
| **DSP block** | A dedicated hardware multiplier built into the FPGA. Faster and smaller than building a multiplier from general logic. |
| ***E. coli*** | A bacterium with a small, well-known genome (4.64 million bases), making it a convenient small-scale test case. |
| **Flip-flop (FF)** | A circuit element that stores one bit. The basic unit of memory inside the logic fabric. |
| **Fmax** | The highest clock speed at which a circuit is guaranteed to work correctly. |
| **FPGA** | A chip whose internal circuitry you configure yourself. Slower per operation than a CPU, but it can do thousands of operations simultaneously. |
| **Golden vectors** | Recorded inputs and known-correct outputs captured from the real software, used as the yardstick for the hardware. |
| **HBM** (High-Bandwidth Memory) | Fast memory stacked next to the chip. Needed for feeding data at volume; not used in this first build. |
| **HLS** (High-Level Synthesis) | A tool that turns C++ into hardware, instead of writing a hardware description language by hand. |
| **LUT** (Lookup Table) | The FPGA's basic logic building block. Roughly, a tiny configurable truth table. Counting LUTs is how you measure design size. |
| **Mutation testing** | Deliberately introducing bugs to confirm your tests catch them. A test that has never failed has not been shown to work. |
| **PCIe** | The high-speed connection between the host computer and the FPGA card. |
| **Place-and-route** | The tool deciding where each piece of logic physically sits on the chip and how wires run between them. This step determines real speed. |
| **Read / read pair** | A short fragment of DNA produced by a sequencing machine, typically 150 letters. Pairs come from the two ends of the same longer fragment. |
| **Seeding** | The first stage of alignment — finding candidate locations quickly. Dominates bwa-mem2's runtime, and is a separate problem from ours. |
| **Shell** | AWS's fixed circuitry around your design: PCIe, memory controllers, clocks. You cannot change it; you must connect to it correctly. |
| **SIMD** | A CPU feature doing the same operation on several values at once. bwa-mem2 uses it heavily, which is why its real alignment code is harder to find than the textbook version. |
| **Speed grade** | A manufacturing quality rating. A faster-graded chip of the same model runs at higher clock speeds. |
| **SystemVerilog** | The hardware description language our main design is written in. You describe circuits, not instructions. |
| **Timing closure** | Getting a design to meet its required clock speed after place-and-route. The usual hard part of FPGA work. |
| **Verilator** | A fast open-source simulator. Excellent for checking behaviour; cannot see some problems that only real synthesis catches. |
| **Vivado** | AMD's official FPGA toolchain. The tool AWS uses, so what it says is what counts. |
| **VU47P** | The AMD Virtex UltraScale+ FPGA inside an AWS F2 instance — our target chip. |

## Supporting detail in this repository

| Claim | Where the evidence lives |
| --- | --- |
| Golden capture, 49,468 bit-exact | `docs/swa_golden_capture.md`, `host/bwamem2_patch/swa_capture.inc` |
| Reproduce the dataset and capture | `scripts/make_ecoli_dataset.sh`, `scripts/capture_swa_ecoli.sh` |
| HLS kernel, C-sim and co-sim | `docs/swa_hls_kernel.md`, `host/swa_hls/`, `host/swa_hls/hls/` |
| Timing measurement scripts | `synth/ooc/impl_bsw_top_f2.tcl`, `docs/synth_ooc_results.md` |
| AWS build procedure | `docs/f2_build_runbook.md`, `docs/f2_bringup.md`, `scripts/f2/` |
| The gap-open bug and its fix | `docs/bsw_gapopen_fix.md` |
| Profiling that found the 6.5% figure | `docs/project_status.md` |
