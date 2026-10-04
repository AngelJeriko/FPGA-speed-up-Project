# How the BSW RTL is verified against bwa-mem2

A complete description of the existing verification path: what is checked, how
sequencing reads become hardware inputs, exactly what is compared, what is
deliberately *not* compared, and the evidence that the checks work.

This describes `tb/tb_bsw_ext.sv`, the scale verification of `bsw_top` — the
hand-written SystemVerilog core that goes to silicon.

---

## 1. The one-paragraph version

`bsw_top` cannot be fed sequencing reads. It is a single-purpose datapath that
accepts **one seed-extension problem** — a query, a target, a starting score and
the scoring parameters — and returns six numbers. So verification works by
recording every extension that real bwa-mem2 performs on real reads, replaying
each one into the RTL, and comparing all six outputs. Current status:
**15,887 extensions from the committed golden set and 34,000 from newer captures,
all passing.**

---

## 2. Why reads cannot be the input

A common expectation is "run the reads through the RTL and diff the output
against bwa-mem2". That is not possible, and the reason is architectural rather
than a limitation of the test harness.

`bsw_top`'s entire interface is:

```systemverilog
bsw_top dut (
    .clk(clk), .rst_n(rst_n), .restart_mode(1'b0),
    .req_valid_i(req_valid), .req_ready_o(req_ready),
    .query_i(query),            // base_t [MAX_QLEN-1:0]  -- 160 bases
    .target_i(target),          // base_t [MAX_TLEN-1:0]  -- 1024 bases
    .cfg_i(cfg),                // bsw_config_t
    .result_valid_o(result_valid), .result_ready_i(result_ready),
    .result_o(result)           // bsw_result_t
);
```

There is no FASTQ parser, no genome index, no chaining, no pairing. Those are
all *upstream* of this core and still run in software. Aligning a read involves
seeding, chaining, and then **many** extensions per read; `bsw_top` accelerates
the innermost of those steps.

So the only meaningful question is: *for every extension problem bwa-mem2
actually solves, does the hardware produce the same answer?* That is what is
tested.

### What one request contains

| Field | Type | Meaning |
| --- | --- | --- |
| `query` | 160 bases, 3 bits each | the read fragment being extended (0=A,1=C,2=G,3=T,4=N) |
| `target` | 1024 bases | the reference window to extend into |
| `cfg.qlen`, `cfg.tlen` | 16-bit | how much of each buffer is valid |
| `cfg.h0` | score | carry-in score from the seed. **With `h0=0` the DP never starts** |
| `cfg.o_del`, `e_del` | score | deletion gap open / extend penalties |
| `cfg.o_ins`, `e_ins` | score | insertion gap open / extend penalties |
| `cfg.zdrop` | score | early-abandon threshold (0 = disabled) |
| `cfg.end_bonus` | score | carried for completeness; unused by the array |
| `cfg.w` | 16-bit | band width; unused — the array computes the full DP |

### What one result contains

| Field | Meaning |
| --- | --- |
| `score` | best local alignment score |
| `qle` / `tle` | query / target length consumed at that best score |
| `gscore` | best score that reaches the **end of the query** |
| `gtle` | target length consumed at `gscore` |
| `max_off` | largest anti-diagonal offset visited |
| `error` | request rejected (`qlen > N_PE` or `tlen > MAX_TLEN`) |

---

## 3. The pipeline, stage by stage

```
FASTQ reads
   |  (1) bwa-mem2, instrumented
   v
BSWCAP01 capture  -- every extension's inputs + bwa-mem2's own outputs
   |  (2) vector generator
   v
text vector file  -- inputs + EXPECTED outputs, one block per extension
   |  (3) tb_bsw_ext
   v
bsw_top (SystemVerilog, under Verilator or XSIM)
   |
   v
compare 6 outputs per extension -> pass/fail count
```

### Stage 1 — capture every extension bwa-mem2 performs

`host/bwamem2_patch/swa_capture.inc`, applied by
`host/bwamem2_patch/apply_swa_capture.sh`.

The hook goes at **six** sites in `mem_chain2aln` — left and right extension,
each split three ways by sequence length (a scalar batch, a 16-bit SIMD batch,
an 8-bit SIMD batch). Anchoring is structural (on the `tprof[PE*][0] += nump;`
accounting lines) rather than by line number, so it survives source edits.

Six sites rather than one because **`ksw_extend` is dead code in bwa-mem2** —
nothing calls it. The real work is Intel's SIMD-batched `BandedPairWiseSW`
operating on arrays of `SeqPair`, and one `SeqPair` is one extension problem.

The hook is dormant unless `BSW_CAPTURE_OUT` is set, which is how we can prove
it non-invasive: the SAM from an instrumented run is **byte-identical** to a
stock run.

### Stage 2 — convert a capture into RTL vectors

Two generators exist, for historical reasons:

| Generator | Input | Used for |
| --- | --- | --- |
| `host/extend_orchestrator/gen_ext_vectors.cpp` | `ext_vec.bin` (older `ext_capture` hook) | the committed `ext_sw_vectors.txt`, 15,887 extensions |
| `host/swa_hls/gen_rtl_vectors_from_cap.cpp` | BSWCAP01 (newer `swa_capture.inc`) | the E. coli and human sets, 34,000 extensions |

Output format, identical for both — whitespace-separated text:

```
<count>
per extension:
  side qlen tlen h0 end_bonus o_del e_del o_ins e_ins zdrop
     exp_score exp_qle exp_tle exp_gscore exp_gtle exp_maxoff
  q[0] q[1] ... q[qlen-1]
  t[0] t[1] ... t[tlen-1]
```

Text rather than binary deliberately: `$fopen`/`$fscanf` are portable across
every simulator, so the same file works under Verilator and XSIM with no
tooling.

**Eligibility.** A captured record is only a valid RTL vector if:

- `qlen <= MAX_QLEN` (160) and `tlen <= MAX_TLEN` (1024), or `bsw_top` rejects
  it by design and the comparison is meaningless.
- `w == 100`. `bsw_top` computes the **full unbanded** DP; it agrees with
  bwa-mem2's banded kernel only while `2w+1 >= qlen`. At `w=100` with
  `qlen <= 160`, `2*100+1 = 201` covers the whole query, so banding is a no-op.
  Narrow-band captures (`-w 12`, `-w 30`) are excluded — they would diverge for
  reasons that are not RTL bugs.

### Stage 3 — drive the RTL

`tb/tb_bsw_ext.sv`. Clock is `always #5 clk = ~clk` — a 10 ns period. Per
extension:

1. `do_reset()` once at startup: hold `rst_n` low 5 clocks, release.
2. `$fscanf` the 16 header integers, then `qlen` query bases, then `tlen`
   target bases.
3. Pad both buffers with base 4 (`N`) — `query = '{default: base_t'(4)}` —
   so unused lanes hold a defined sentinel rather than stale data.
4. Pack `cfg` from the captured parameters.
5. `submit_and_wait()`: wait for `req_ready`, raise `req_valid` for one clock,
   then wait for `result_valid`.
6. Compare.

The vector file path comes from `+VEC=<path>`:

```systemverilog
if (!$value$plusargs("VEC=%s", path))
    path = "host/extend_orchestrator/vectors/ext_sw_vectors.txt";
```

A watchdog `#2000000000` (2 s of simulated time) fires `[FATAL] timeout` if the
DUT ever fails to produce a result, so a hang is reported rather than hanging
the run.

---

## 4. Exactly what is compared — and what is not

This is the part most worth reading carefully. The three outputs that matter
most are compared strictly; two are compared against a different model; one is
informational.

```systemverilog
if (result.error !== 1'b0 ||
    $signed(result.score)  !== e_score  ||
    result.qle             !== e_qle    ||
    result.tle             !== e_tle    ||
    $signed(result.gscore) !== e_gscore ||
    (e_gscore > 0 && result.gtle !== e_gtle)) begin
```

| Output | Compared? | Source of the expected value |
| --- | --- | --- |
| `error` | **strict** — must be 0 | — |
| `score` | **strict** | **bwa-mem2 itself** |
| `qle` | **strict** | **bwa-mem2 itself** |
| `tle` | **strict** | **bwa-mem2 itself** |
| `gscore` | strict | the full-DP array model (`hw.h`) |
| `gtle` | strict **only when `gscore > 0`** | the full-DP array model |
| `max_off` | **counted, never failed** | — |

### Why `gscore`/`gtle` come from a different model

`bsw_top` computes the full unbanded DP, so it updates `gscore`/`gtle` on
**every row**. ksw stops once its band narrows past the query end. Both are
correct for their own algorithm, and they can legitimately differ.

Measured on one real record (`qlen=2, tlen=52, h0=52`):

| | score | qle | tle | gtle | gscore |
| --- | --- | --- | --- | --- | --- |
| ksw, banded `w=100` | 52 | 0 | 0 | 2 | 44 |
| `hw_extend2`, full-DP array | 52 | 0 | 0 | **5** | **45** |
| **`bsw_top` (RTL)** | 52 | 0 | 0 | **5** | **45** |

The RTL matches the array model exactly — it is right by its own
specification. So expected `gscore`/`gtle` are computed with `hw_extend2`.
`gen_ext_vectors.cpp` states this directly: *"expected outputs come from the
full-rectangle ARRAY model, not ksw — that is what bsw_top reproduces
bit-exactly."*

Feeding ksw's raw values instead produced 865 mismatches in 12,000 vectors:
864 the `-1` vs `0` sentinel (below) and 1 the case above.

### The `gscore` sentinel

When no cell reaches the end of the query, ksw leaves `gscore` at its `-1`
initialiser; the array clamps to `0`. Both consumers branch on `gscore <= 0` —
bwa-mem2's `bwamem.cpp` and our own `host/extend_orchestrator/orch.h:149/168`:

```c
if (r.gscore <= 0 || r.gscore <= A.score - o.pen_clip5) {
```

so `0` and `-1` take the identical path and `gtle` is never read. The convention
is recorded at `gen_bsw_mvsh.cpp:100` ("RTL/golden convention: gscore clamped
>=0") and `check_fulldp.cpp` already states the difference "never change[s] the
assembly branch". The generators therefore clamp, and the testbench gates
`gtle` on `gscore > 0`.

### Why `max_off` is informational

From the testbench header: *"the orchestrator never uses it (the band is fixed
at `w=100`, no band-doubling), so a divergent `max_off` is harmless."* The array
tracks the anti-diagonal offset over the full rectangle; ksw tracks it inside
its band. Differences are counted and printed so a change is visible, but do not
fail the run.

### The honest summary of the correctness claim

> `bsw_top` is bit-exact with bwa-mem2 on `score`, `qle` and `tle`
> unconditionally, within the input envelope and at `w=100`. On `gscore` and
> `gtle` it is bit-exact with the full-DP array model, which differs from
> bwa-mem2 only in ways that provably cannot change the downstream branch.

A residual theoretical risk: a `±1` `gscore` difference could flip
`gscore <= score - pen_clip` if a value sat exactly on that boundary. Not
observed in 34,000 records, but it is not impossible, and it is the one place
the "bit-exact" claim needs its qualifier.

---

## 5. Results

| Vector set | Source | Extensions | Max `tlen` | Result |
| --- | --- | --- | --- | --- |
| `ext_sw_vectors.txt` | older `ext_capture`, HG00733 | 15,887 | — | **0 failures** |
| `rtl_ecoli` | E. coli capture | 10,000 | 437 | **0 failures** |
| `rtl_human` | 200k real ERR174310 pairs | 12,000 | 783 | **0 failures** |
| `rtl_sim150` | 150 bp high-divergence | 12,000 | **997** | **0 failures** |

The `rtl_sim150` set includes both records in its entire 2.7M-record capture
with `tlen >= 900`, so it is the only set that exercises `bsw_top` within 27
bases of its `MAX_TLEN = 1024` limit.

Runtime under Verilator: ~84 s for 15,887 extensions, so roughly **5 ms per
extension**, dominated by simulating a 160-PE systolic array over `tlen` rows.

---

## 6. How to run it

The committed golden set:

```sh
bash scripts/run_sim.sh tb_bsw_ext
```

Any other vector set, via the `BSW_EXT_VEC` override:

```sh
zcat host/swa_hls/vectors/rtl/rtl_sim150.txt.gz > /tmp/v.txt
BSW_EXT_VEC=/tmp/v.txt bash scripts/run_sim.sh tb_bsw_ext
```

Generating a fresh set from a capture:

```sh
cd host/swa_hls
g++ -O2 -std=c++17 -I../extend_orchestrator -o gen_rtl_vectors_from_cap gen_rtl_vectors_from_cap.cpp
./gen_rtl_vectors_from_cap ~/cap_human/sim150_swa.bin out.txt --count 12000 --min-tlen 900
```

`--min-tlen T` includes **every** record with `tlen >= T` and fills the
remainder by even spread over the `(qlen, tlen)` envelope, which is how the rare
near-limit records get in despite being 2 in 2.7 million.

Under XSIM instead of Verilator: see `docs/rtl_xsim_runbook.md`.

---

## 7. Evidence that the checks actually work

A passing testbench proves nothing until it has been shown to fail. Mutating
`rtl/bsw_pe.sv`:

| Mutant | ecoli | human | sim150 | committed |
| --- | --- | --- | --- | --- |
| none (baseline) | 0 | 0 | 0 | 0 |
| **gaps open from `H_new` instead of `M_term`** | 0 | 0 | **1** | **0** |
| drop the gap-extension penalty (`E_ext = E_reg`) | 113 | 2420 | 1432 | 3342 |

Row 3 confirms every set detects a gross arithmetic error, so rows 1–2 measure
coverage rather than a broken harness.

Row 2 is the real defect fixed in `docs/bsw_gapopen_fix.md`: gaps must open from
`M` (the diagonal), not from `H = max(M,E,F)`, or adjacent opposite-type gaps
are over-scored and `gscore` inflates. Its own write-up records that *"existing
goldens missed it (coverage gap)"*, which is why `disc_mvsh.txt` was hand-written
as a dedicated regression. **The 150 bp high-divergence set now catches it
organically, and the committed golden set still does not** — which is the
argument for keeping these newer vectors.

---

## 8. Limits of this verification

- **It tests `bsw_top` only.** Not the AWS shell, PCIe, the register interface,
  the memory path, or anything upstream of extension.
- **Simulation, not silicon.** Nothing here speaks to timing, placement or
  routing.
- **Verilator is 2-state.** It cannot see X propagation or uninitialised-register
  bugs. `docs/rtl_xsim_runbook.md` covers closing that gap under XSIM.
- **Two routes are unexercised by any real dataset.** Every capture so far
  reports `scalar = 0` and `max band_try = 0`: no pair was long enough to fall
  out of the SIMD lanes, and the band-widening retry never fired at the default
  `w = 100`.
- **The envelope is sampled, not exhaustive.** 34,000 of 18.2 million available
  records. The near-limit `tlen` region is covered by exactly two records,
  because that is all the data contains.
