# Annotated walkthrough: the `bsw_top` hierarchy

A read-along commentary on all 1,593 lines of the Smith-Waterman accelerator, for
someone learning hardware design. Line numbers refer to the files as committed.

Read bottom-up — each file only makes sense once you know what the one below it does.

| File | Lines | Role |
|---|---|---|
| `bsw_pkg.sv` | 138 | shared constants and types. No logic |
| `bsw_score_matrix.sv` | 29 | substitution score for one base pair |
| `bsw_pe.sv` | 239 | **one DP cell.** The algorithm lives here |
| `bsw_systolic_array.sv` | 107 | N_PE copies of the PE, wired in a chain |
| `bsw_ctrl_fsm.sv` | 376 | the sequencer, and the request/result interface |
| `bsw_max_tracker.sv` | 559 | recovers the answer from the cell stream |
| `bsw_top.sv` | 145 | glue. No logic |

---

## 1. `bsw_pkg.sv` — the vocabulary

A SystemVerilog **package** is a named scope of constants, types and functions that
other files `import`. It is the analogue of a C header, but part of the language
rather than the preprocessor, so the tools understand it.

### The three types everything is built from (lines 73-75)

```systemverilog
typedef logic signed [SCORE_WIDTH-1:0] score_t;   // 16-bit SIGNED
typedef logic        [BASE_WIDTH-1:0]  base_t;    //  3-bit unsigned
typedef logic        [LEN_WIDTH-1:0]   len_t;     // 16-bit unsigned
```

`base_t` is 3 bits because the alphabet is A, C, G, T, N — five values, and
`ceil(log2(5)) = 3`. Every sequence in the design is 3 bits per base, which is why
`query_i` (160 bases) is 480 wires and `target_i` (1024 bases) is 3,072.

`score_t` being **signed** is load-bearing. DP intermediates go negative before
being clamped, and a signed/unsigned mix-up silently breaks comparisons. `bsw_pe`
carries a dedicated constant just to avoid that trap — see §3.

### Packed structs as interfaces (lines 78-91, 97-105)

```systemverilog
typedef struct packed {
    score_t h0; score_t o_del; score_t e_del; ...
    len_t w; len_t qlen; len_t tlen;
} bsw_config_t;        // 10 fields x 16 bits = 160 bits
```

`packed` means the fields are laid out as one contiguous bit vector. You get named
access *and* bus behaviour, so it can be a module port, registered in one statement,
or compared as a whole. `bsw_result_t` is the same idea at 97 bits (1 + 2x16 + 4x16).

This is also why Vivado's netlist writer scalarizes these ports into ~1,200 separate
signals, and therefore why `synth/postsynth/bsw_top_flat.sv` exists.

### The envelope (lines 29-48)

```systemverilog
parameter int MAX_QLEN = 160;    parameter int MAX_TLEN = 1024;
parameter int BAND_WIDTH = 160;  // == MAX_QLEN: one PE per query base
```

The comment block above these is worth reading in full: it records the measured
maxima over 18 million captured alignments (`qlen<=131`, `tlen<=997`) and notes that
997 is **97.4% of MAX_TLEN**. That is why the `tlen` guard in the FSM is load-bearing
rather than theoretical — one of the three real defects this project found.

---

## 2. `bsw_score_matrix.sv` — the smallest module

29 lines, one `assign`, no state.

```systemverilog
assign s = (q_oob || t_oob || q_is_n || t_is_n) ? W_AMBIG_P
         : (q == t)                              ? W_MATCH_P
         :                                        W_MISMATCH_P;
```

Nested conditionals, evaluated top to bottom: anything ambiguous scores `W_AMBIG`
(-1), equal bases score `W_MATCH` (+1), otherwise `W_MISMATCH` (-4). In hardware this
is a handful of comparators feeding a mux — a few LUTs, no clock.

**Concept: `parameter` on a leaf module.** The three scores are parameters defaulting
to the package values, so a future instance could be specialised without editing the
file. `bsw_pe` does not override them, so every PE uses bwa-mem2's defaults.

This is also the one-line change the demo walkthrough mutates to prove the
verification can fail — `W_MATCH_P + 1` moves 195 of 200 alignments.

---

## 3. `bsw_pe.sv` — the algorithm

The most important file. One instance computes one cell of the DP matrix per cycle.

### The recurrence (header comment, lines 14-22)

```
M     = (H_diag != 0) ? H_diag + S : 0
H_new = max(M, E_reg, F_in, 0)
E_new = max(M - (o_del+e_del), E_reg - e_del, 0)   // opens from M
F_new = max(M - (o_ins+e_ins), F_in  - e_ins, 0)   // opens from M
```

Three running values per cell: **H** (best score ending here), **E** (best score
ending in a gap in one sequence), **F** (same for the other). Two gap states rather
than one because of the **affine gap model** — opening a gap costs `o + e`, extending
costs `e`. Biologically motivated: one 5-base deletion is far likelier than five
independent ones.

**The subtle part, and the site of a real bug:** gaps open from **M** (the diagonal
match term), not from `H_new = max(M,E,F)`. bwa-mem2 does this deliberately, to
forbid a gap opening on top of a cell whose own best path is already a gap — no
`100M3I3D20M`. Opening from `H_new` instead over-scores adjacent opposite-type gaps
and inflates `gscore`. That bug shipped in this design once; `disc_mvsh.txt` is the
regression vector that reproduces it.

### Load-time config registers (lines 80-98)

```systemverilog
always_ff @(posedge clk) begin
    if (!rst_n) begin ... end
    else if (load_q_i) begin
        query_base_reg <= query_base_i;
        oe_del_reg     <= o_del_i + e_del_i;   // precomputed
        oe_ins_reg     <= o_ins_i + e_ins_i;
    end
end
```

**Concept: `always_ff`.** Describes a *clocked* block — everything assigned inside
becomes a flip-flop. `@(posedge clk)` is the trigger. `<=` is **non-blocking**
assignment: all right-hand sides are evaluated, *then* all left-hand sides update
together, which is what real flip-flops do. Using `=` (blocking) in a clocked block
creates order-dependent behaviour and is a classic bug.

Two deliberate choices here, both for speed:

1. Each PE keeps its **own copy** of the penalties rather than reading broadcast
   wires every cycle. 160 PEs spread across the die reading one wire is a long,
   high-fanout route; a local register is a short one.
2. `o_del + e_del` is computed **once at load**, not every cycle. That removes one
   adder from the path that runs every clock.

### The DP arithmetic (lines 128-160)

```systemverilog
always_comb begin
    diag_nz   = (h_diag_i != SZERO);
    M_term    = (restart_mode || diag_nz) ? (h_diag_i + s_match) : SZERO;
    H_max_ME  = (M_term  > E_reg) ? M_term : E_reg;
    H_new     = (H_max_ME > f_i)  ? H_max_ME : f_i;
    ...
```

**Concept: `always_comb`.** Pure combinational logic — gates, no storage. It
re-evaluates whenever any input changes. The rule is that every variable assigned
must be assigned on *every* path, or you get an **inferred latch**: accidental
storage, which is a real bug on an FPGA. (Our synthesis check reports
`inferred latches : 0`, which is how we know this file obeys the rule.)

**The signed-zero trap (line 119):**

```systemverilog
localparam score_t SZERO = score_t'(0);
// Unsized '0 is treated as unsigned in comparison context and silently
// breaks the negative-value clamps.
```

Writing `(E_pick > '0)` would compare a signed value against an unsigned literal,
and SystemVerilog's rules make the whole comparison unsigned — so `-5 > 0` becomes
*true*. A typed constant forces the signed comparison. This is the kind of bug that
passes review and fails on data.

**A removed comparator (lines 121-125):** the textbook recurrence clamps
`H_new = max(M,E,F,0)`. The comment proves the clamp is unnecessary: `E_reg` and
`f_i` are both clamped `>= 0` on every update, so `max(M, E) >= 0` already. Dropping
it removes one comparator from the critical path. **Note the form of the argument** —
not "this seems fine" but a stated invariant, with the sim-only assertions at lines
220-236 checking it holds.

### State update (lines 166-201)

```systemverilog
end else begin
    active_q   <= active_i;      // the pipeline shift ALWAYS happens
    target_q   <= target_i;
    H_prev_reg <= H_curr_reg;
    if (active_i) begin
        H_curr_reg <= H_new; E_reg <= E_new; F_out_reg <= F_new;
    end else begin
        H_curr_reg <= H_curr_reg;  // freeze
        ...
```

Two things move through this array: a **valid bit** (`active`) and the **data**. The
shift happens unconditionally so the wavefront keeps propagating; the DP state only
updates on valid cycles. `H_curr_reg <= H_curr_reg` is an explicit hold — redundant
in a clocked block, but it documents the intent.

`H_prev_reg` is `H_curr_reg` delayed one more cycle. That gives two taps: `h_left_o`
(1 cycle old) and `h_diag_o` (2 cycles old). Why two: in the anti-diagonal schedule,
the neighbour needs *this* cell's value at two different ages — one as its left
neighbour, one as its diagonal. Delaying by a register is cheaper than storing a row.

### Simulation-only assertions (lines 214-237)

```systemverilog
// synthesis translate_off
assert (H_curr_reg >= SZERO) else $error("bsw_pe: H_curr_reg went negative");
assert (H_curr_reg < SAFE_BOUND) else $error("... approaches int16 overflow");
// synthesis translate_on
```

**Concept: pragma-guarded code.** `synthesis translate_off` tells synthesis to skip
to `translate_on`, so this costs zero hardware but runs in simulation. These check
the invariants the optimisations above *rely* on — the dropped clamp assumed
non-negativity, so non-negativity is now asserted on every cycle of every test.

That is the pattern worth taking away: when you remove a safety check for speed,
replace it with an assertion that proves the check was unnecessary.

---

## 4. `bsw_systolic_array.sv` — replication

107 lines, and almost all of it is one `generate` loop.

### The chain wires (lines 58-68)

```systemverilog
logic   [N_PE:0] chain_active;    // note: N_PE+1 entries, not N_PE
score_t [N_PE:0] chain_h_diag;
assign chain_active[0] = active_in;    // index 0 = the array's boundary input
```

`[N_PE:0]` gives one more element than there are PEs: index `j` is the wire *into*
PE_j, so index 0 is the external boundary and index `N_PE` is the drain off the end.
A neat idiom for chains — no special-casing of the first or last element.

### `generate` (lines 70-99)

```systemverilog
genvar j;
generate
    for (j = 0; j < N_PE; j++) begin : g_pe
        bsw_pe u_pe (
            .query_base_i (query_bases_i[j]),
            .active_i     (chain_active[j]),
            .active_o     (chain_active[j+1]),
            ...
```

**Concept: compile-time replication.** This is *not* a loop that runs. `genvar` and
`generate` are elaborated before synthesis: the tool stamps out 160 (or 32) separate
`bsw_pe` instances and wires `chain_active[j]` to `chain_active[j+1]`. The named
block `: g_pe` is why the hierarchy shows `g_pe[0].u_pe`, `g_pe[1].u_pe` and so on —
you saw exactly those names scroll past in the gate-level runs.

The whole systolic structure is these four lines: each PE's output is the next PE's
input. Query bases stay put (one per PE); the target streams in at PE_0 and shifts
right one position per cycle. At cycle `t`, PE_j is working on cell `(t-j, j)` — an
anti-diagonal wavefront sweeping across the matrix.

Why this shape: every PE computes every cycle, from register-to-register with its
immediate neighbour. No shared memory, no long wires, no arbitration. That is what
makes it fast, and it is the entire reason the design exists.

**The limitation, stated honestly in the header (lines 11-12):** `qlen` must be
`<= N_PE`. A longer query needs swath processing with state save/restore. Not
implemented — and instead of computing something wrong, the FSM rejects the request.

---

## 5. `bsw_ctrl_fsm.sv` — the sequencer

376 lines. Holds the request, drives the array, owns the interface.

### State encoding (lines 77-86)

```systemverilog
typedef enum logic [2:0] {
    S_IDLE = 3'd0, S_LOAD = 3'd1, S_RUN = 3'd2,
    S_DRAIN = 3'd3, S_DONE = 3'd4, S_REJECT = 3'd5
} state_e;
state_e state, state_n;
```

**Concept: enum-typed state.** The underlying storage is 3 bits, but the type system
prevents assigning a meaningless value, and waveforms show `S_RUN` instead of `3'd2`.
The `state` / `state_n` pair is the standard two-process FSM: one `always_comb` block
computes the next state, one `always_ff` registers it. Keeping them separate makes
the combinational logic easy to read and guarantees exactly one register.

Synthesis re-encoded these as **one-hot** (you saw it in the log: `S_IDLE` became
`100000`). One-hot uses more flip-flops but decodes with a single bit test, which is
usually faster. The tool chose that on its own.

### The accept condition (lines 103-105)

```systemverilog
wire accept_req = req_valid_i &&
                  ((state == S_IDLE) ||
                   (state == S_DONE && result_ready_i));
```

A request is taken when idle **or** when finishing one and the host is simultaneously
collecting the result. That second clause removes a dead cycle between back-to-back
alignments. Paired with `req_ready_o` (line 328, the same condition), it forms a
proper valid/ready handshake the host can drive every cycle.

### The guard that was missing (lines 107-117)

```systemverilog
wire req_oversize = (cfg_i.qlen > len_t'(N_PE)) ||
                    (cfg_i.tlen > len_t'(MAX_TLEN));
```

The `tlen` term is the fix for one of the project's three real defects. The target
read at line 193 indexes with `tgt_ra_idx[$clog2(MAX_TLEN)-1:0]` — a **truncation to
10 bits**. Without this guard an oversize `tlen` would silently *wrap* and return a
confident wrong answer with `error=0`. Found by measuring real data against the
limit: 997 against 1024.

Note the lesson in that: the bug was not in logic anyone wrote wrongly. It was a
missing check on an assumption nobody had tested.

### Two timing fixes worth studying

These are the most instructive passages in the whole project, because each records
a measured problem, a diagnosis and a result.

**(a) The 160-deep chain, lines 250-280.** The first row of the DP matrix needs
`eh[j] = max(eh[j-1] - e_ins, 0)` — each value depends on the previous one. Written
literally, that is a 160-deep chain of subtract-and-clamp in *one* combinational
path. Out-of-context synthesis measured it at **~409 ns, system Fmax 2.4 MHz**. It
was the critical path of the entire design.

The fix is mathematical, not structural:

```systemverilog
eh_pen[j]  = 32'(cfg_q.o_ins) + j * 32'(cfg_q.e_ins);
eh_init[j] = (32'(cfg_q.h0) > eh_pen[j]) ? score_t'(...) : score_t'(0);
```

Because every subtracted term is non-negative, the unclamped sequence is
monotonically non-increasing — and a saturating running-max-with-zero over a
non-increasing sequence equals the pointwise clamp. So
`eh[j] = max(h0 - o_ins - j*e_ins, 0)`, **bit-exact**, and every lane is now
independent: one multiply, one subtract, one clamp, all in parallel.

A 170x timing improvement from recognising an algebraic identity. Also note the
widening to 32 bits so `o_ins + j*e_ins` cannot overflow for `j < 160`.

**(b) Register the mux, lines 168-194.** `sa_target_o` used to be a combinational
1024-way mux (`target_q[t_idx]`) feeding **straight into** PE_0's DP recurrence. The
mux took ~3.9 ns, the recurrence ~5.2 ns, and because they were in series that was
one ~9.3 ns path — real post-route result **WNS -1.367 ns, Fmax 106.8 MHz**.

The fix inserts a register between them and reads **one index ahead**:

```systemverilog
S_RUN: tgt_ra_idx = (t_idx < cfg_q.tlen - 1) ? (t_idx + 1) : t_idx;
...
tgt_r <= target_q[tgt_ra_idx[$clog2(MAX_TLEN)-1:0]];
```

Now the mux feeds a flop and the flop feeds the recurrence: two separate sub-8 ns
paths instead of one 9.3 ns path. Latency is unchanged, because reading one index
early means `tgt_r` delivers `target_q[t_idx]` on exactly the cycle the array wants
it. The otherwise-idle `S_LOAD` cycle primes the pipeline.

**This is the single most transferable idea in the file.** When a path is too slow,
you do not always need less logic — often you need a register in the middle of the
logic you already have. The cost is latency, and here even that was avoided.

### Result override (lines 361-374)

```systemverilog
always_comb begin
    if (oversize_q) begin
        result_o = '0; result_o.error = 1'b1;
    end else begin
        result_o = result_i; result_o.error = 1'b0;
    end
end
```

This is why the tracker's result routes *through* the FSM rather than straight to the
port. A rejected request never ran the tracker, so `result_i` holds stale data from
the previous alignment. Forcing all-zeros plus `error=1` makes rejection
unambiguous — and it is exactly the behaviour we observed when feeding unfiltered
vectors to a 32-element array.

---

## 6. `bsw_max_tracker.sv` — recovering the answer

559 lines, the hardest file. The array produces cells along **anti-diagonals**, but
the answer is defined in terms of **rows**. This module reconciles the two.

### The cycle-to-cell mapping (lines 69-98)

```systemverilog
row_of_pe[k] = cyc - len_t'(1) - len_t'(k);
```

The whole module rests on this one line. The cell visible at PE_k during cycle `cyc`
belongs to row `cyc - 1 - k`. The `-1` is the PE's own register latency. Get this
wrong and everything downstream is subtly misaligned — which is why the header
spends 25 lines deriving it.

### A pipelined reduction tree (lines 100-248)

Every cycle, up to 160 cells appear simultaneously and the largest is needed. A
balanced tree of 16-bit comparators does it in `log2(160) = 8` levels.

The problem was physical, not logical: 160 PEs spread across the die funnelling into
one comparator tree measured **-14.5 ns, 77% of it routing**. The logic was fine; the
wires were the cost.

The fix splits the tree across a register (lines 164-248): stage 1 reduces the leaves
to `MIDNODES` partial maxima — those registers place *near their PE clusters*, so the
long wires become short ones — and stage 2 combines the partials.

```systemverilog
if (s1_h[lev][2*m] >= s1_h[lev][2*m+1]) begin ... // LEFT wins ties
```

**The tie-break is `>=`, deliberately.** Left operand wins, so the lowest PE index
wins, matching what a serial scan with strict `>` would produce. Bit-exactness
depends on details like this, and the comment says so.

`MIDLEV` (line 136) is where the tree splits, overridable with
`+define+MIDLEV_LVL=n` so the split point can be swept against real timing results.
The comment notes it is **latency-neutral for any value** — always exactly 2
registers deep — so sweeping it cannot break correctness.

Lines 140-162 are the `N_PE >= 2**MIDLEV` guard added after Verilator accepted
`N_PE=8` and reported 200/200 PASS on a design Vivado refuses to build.

### Two different maxima, and why (lines 256-277 and 456-478)

The module tracks the maximum **twice**:

- `glob_max` — accumulated per-cycle from the reduction tree. Gets the right *value*
  fast, feeds `max_off` and the z-drop test.
- `rmax_score` / `rmax_i` / `rmax_j` — accumulated per *row*, from the row pipeline.

Why both: `glob_max`'s tie-break falls out of tree geometry, but ksw's reported
`qle`/`tle` need *its* tie-break — a row's maximum replaces the running maximum only
on a **strict** improvement, recording that row's rightmost maximal column. The value
agrees either way; the argmax does not. So the value comes from the fast path and the
reported position from the faithful one.

This is a recurring theme in bit-exact hardware: **matching the answer is easy,
matching the tie-break is the work.**

### The row pipeline (lines 279-338)

```systemverilog
if (cell_valid_i[k] &&
    (restart_mode ? (h_cells_i[k] >  row_m_pipe[k-1])
                  : (h_cells_i[k] >= row_m_pipe[k-1]))) begin
```

An `N_PE`-stage pipeline flowing in lockstep with the wavefront: stage k holds the
running `(max, argmax)` for the row PE_k is currently producing. When the wave reaches
stage `qlen-1`, that row is complete.

Note `restart_mode` selecting `>` versus `>=`: extension mode wants the **rightmost**
column at the row max, local-SW mode the **leftmost**, because `ksw_u8` reports the
minimum query index. One comparison operator, two different reference behaviours.

### `gscore` and the `-1` sentinel (lines 431-454)

```systemverilog
gscore_r <= '1;     // -1 sentinel (C++ initialises gscore=-1)
...
if ($signed(row_tail_h_last_q) >= $signed(gscore_r)) begin
```

`'1` is all-ones, which as a signed value is -1 — matching the C reference's
initialisation. The explicit `$signed()` casts force signed comparison, the same trap
`SZERO` guards against in the PE.

The `>=` has a comment explaining it took a bug to find: ties must go to the **later**
row, because rows graduate in increasing order and strict `>` kept the earlier one,
giving a wrong `gtle`.

### Another register-in-the-middle fix (lines 385-429)

Selecting the finished row from the pipeline is a 160-wide mux driven by `qlen-1`.
Feeding it straight into the z-drop arithmetic put
`cfg_q.qlen -> tail_idx -> 160:1 mux -> zdrop carry chain -> zdrop_break` in one
cycle: **WNS -12.5 ns**.

The fix registers the selected tail, and *also* snapshots `glob_max` at the same
instant (`glob_max_s`). That second part is the careful bit — the arithmetic must see
the *same pair* of values it saw before, just one cycle later. Every consumer reads
the `_q`/`_s` copies, so the whole post-row update shifts uniformly by one cycle, and
the FSM's drain margin (`qlen + 7`) absorbs it.

### Folding a multiply to a constant (lines 495-518)

```systemverilog
if (z_di > z_dj) z_drift = (z_di - z_dj) * W_E_DEL;
else             z_drift = (z_dj - z_di) * W_E_INS;
```

The z-drop test needs gap drift times the gap-extend penalty. Using the runtime
`e_del_i` port means a real multiplier — **two DSP48E1s, 4.0 ns**, dominating the
path. But bwa-mem2 fixes `e_del = e_ins = 1`, so using the compile-time constants
collapses the multiply to identity.

Honest about the trade: bit-exact while the penalties are 1, and still *correct* (a
real multiply) if scoring is ever un-fixed, because the constants come from the
package rather than being hard-coded as `1`.

### Final latch (lines 535-557)

```systemverilog
end else if (done_i) begin
    result_q.score   <= rmax_score;
    result_q.qle     <= rmax_j + len_t'(1);
    result_q.tle     <= rmax_i + len_t'(1);
    result_q.gscore  <= gscore_r;
    result_q.gtle    <= max_ie_r + len_t'(1);
    result_q.max_off <= glob_max_off;
```

The `+1`s convert zero-based indices to the C reference's lengths-consumed
convention. `score`, `qle` and `tle` all come from `rmax_*` so they are mutually
consistent — one source, not a mix.

---

## Concepts index

| Concept | Where to see it |
|---|---|
| `always_ff` / non-blocking `<=` | `bsw_pe` 84-98, 166-201 |
| `always_comb` / inferred latches | `bsw_pe` 128-160 |
| signed vs unsigned comparison traps | `bsw_pe` 117-119; `bsw_max_tracker` 448 |
| `genvar` / `generate` replication | `bsw_systolic_array` 70-99 |
| chain wires sized `[N:0]` | `bsw_systolic_array` 58-68 |
| `typedef enum` FSM state | `bsw_ctrl_fsm` 77-86 |
| two-process FSM | `bsw_ctrl_fsm` 197-229 |
| valid/ready handshake + backpressure | `bsw_ctrl_fsm` 103-105, 328-329 |
| packed struct as a port | `bsw_pkg` 78-91; used everywhere |
| pipelining to break a critical path | `bsw_ctrl_fsm` 168-194; `bsw_max_tracker` 164-248, 385-429 |
| replacing a serial chain with a closed form | `bsw_ctrl_fsm` 250-280 |
| constant folding to remove a DSP | `bsw_max_tracker` 495-518 |
| tie-break semantics for bit-exactness | `bsw_max_tracker` 180-181, 320-326, 445-447 |
| sim-only assertions behind a pragma | `bsw_pe` 214-237 |
| guarding a parameter envelope | `bsw_ctrl_fsm` 107-117; `bsw_max_tracker` 140-162 |
