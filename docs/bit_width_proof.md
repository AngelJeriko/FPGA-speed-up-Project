# 16-bit Score Width: Overflow / Underflow Proof

This document shows that the `SCORE_WIDTH = 16` choice in
`rtl/bsw_pkg.sv` is sufficient for the configured operating envelope, i.e.
no internal arithmetic in any PE can wrap or saturate.

The envelope below is the **synthesized** configuration (`MAX_QLEN = 160`,
`MAX_TLEN = 1024`, from `rtl/bsw_pkg.sv`) and is **enforced at the host ingress**
by `bsw_fpga::Accelerator::submit()` — see [Enforcement](#enforcement). If you
change `bsw_pkg` or the host envelope constants, update both this proof and the
`static_assert`-guarded constants in `host/bsw_fpga.h` so they cannot drift apart.

## Scope

We prove bounds on every signed-arithmetic node inside `bsw_pe.sv`:

- registered state: `H_curr_reg`, `H_prev_reg`, `E_reg`, `F_out_reg`
- combinational intermediates: `M_term`, `H_max_ME`, `H_max_MEF`, `H_new`,
  `E_open`, `E_ext`, `E_pick`, `E_new`, `F_open`, `F_ext`, `F_pick`,
  `F_new`, `oe_del`, `oe_ins`

`score_t` is `logic signed [15:0]` — representable range
`[ -32768, +32767 ]`.

## Operating envelope (host contract)

The proof assumes the host respects the following contract on
`bsw_config_t`. These bounds are far larger than any realistic seed-extension
workload, and `submit()` rejects any request that violates them.

| Field            | Bound                 | Enforced by                             |
|------------------|-----------------------|-----------------------------------------|
| `h0`             | `0 ≤ h0 ≤ 1024`       | `submit()` (`H0_MAX`); BWA seed scores <100 |
| `qlen`           | `qlen ≤ MAX_QLEN=160` | `submit()` + struct type (= bsw_pkg N_PE) |
| `tlen`           | `tlen ≤ MAX_TLEN=1024`| `submit()` + struct type                |
| match `W_MATCH`  | `+1`                  | package constant (not host-supplied)    |
| mismatch         | `-4`                  | package constant                        |
| ambig (`N`)      | `-1`                  | package constant                        |
| `o_del`, `o_ins` | `0 … 64`              | `submit()` (`GAPO_MAX`)                  |
| `e_del`, `e_ins` | `0 … 8`               | `submit()` (`GAPE_MAX`)                  |

Define `S_max = W_MATCH = 1` and `S_min = W_MISMATCH = -4`.
Define `OE_max = max(o_del+e_del, o_ins+e_ins) ≤ 72`.

> **Why `tlen` does not appear in the score bound.** `H` grows only via the
> diagonal match term `M = H(i-1,j-1) + S`. Along any path, the number of
> match additions is bounded by the number of query positions, so the peak
> score scales with `qlen`, not `tlen`. Raising `MAX_TLEN` from 256 → 1024
> therefore does not change `H_MAX`; only `MAX_QLEN` (128 → 160) does.

## Upper bound on `H`, `E`, `F`

**Claim.** For every cell `(i, j)` computed by any PE,

```
0 ≤ H(i, j), E(i, j), F(i, j) ≤ H_MAX
```

where `H_MAX = h0 + qlen · S_max ≤ 1024 + 160·1 = 1184`.

**Proof (by induction on the anti-diagonal index `i+j`).**

The clamp `max(·, 0)` on `H_new`, `E_new`, `F_new` immediately gives the
lower bound `≥ 0`. We prove the upper bound.

*Base case* (`i = 0` or `j = 0` — boundary cells).
- First row (`i = 0`): the FSM seeds each PE with `init_h_curr_i = eh[j]`
  where `eh[0] = h0` and `eh[j] = max(eh[j-1] - penalty, 0)`. So
  `eh[j] ≤ h0 ≤ H_MAX`. ✓
- First column (`j = 0`): the FSM streams `h_diag = bound_reg` into PE_0,
  where `bound_reg ≤ h0 ≤ H_MAX`. ✓

*Inductive step.* Assume the bound holds for every cell with `i+j < k`.
Consider a cell at anti-diagonal `k`:

- `M_term ≤ H(i-1, j-1) + S_max`. By the stricter inductive form
  `H(i-1, j-1) ≤ h0 + (i-1)·S_max`, so `M_term ≤ h0 + i·S_max ≤ H_MAX`. ✓
- `H_new = max(M_term, E_reg, F_in, 0) ≤ H_MAX` by induction. ✓
- `E_new = max(H_new - OE, E_reg - e, 0) ≤ max(H_new, E_reg) ≤ H_MAX`. ✓
- `F_new` analogous. ✓

Therefore `H, E, F ∈ [0, H_MAX] = [0, 1184]`, which fits in 11 bits
(`2^11 = 2048 > 1184`). The 16-bit `score_t` has **~27× headroom** over the
worst case.

## Bounds on combinational intermediates

Before the clamps, signed subtractions can transiently produce small negative
values. We bound the most extreme intermediate at every node:

| Node              | Lower bound                | Upper bound                |
|-------------------|----------------------------|----------------------------|
| `s_match`         | `S_min = -4`               | `S_max = +1`               |
| `M_term`          | `0` (gated by `H_diag!=0`) | `H_MAX + S_max = 1185`     |
| `H_max_ME`        | `0`                        | `H_MAX = 1184`             |
| `H_max_MEF`       | `0`                        | `H_MAX`                    |
| `H_new`           | `0` (clamp)                | `H_MAX`                    |
| `oe_del`, `oe_ins`| `0`                        | `OE_max = 72`              |
| `E_open`          | `0 - OE_max = -72`         | `H_MAX = 1184`             |
| `E_ext`           | `0 - e_del = -8`           | `H_MAX = 1184`             |
| `E_pick`          | `-8` (max of two ≥ -72)    | `H_MAX`                    |
| `E_new`           | `0` (clamp)                | `H_MAX`                    |
| `F_open/ext/pick` | symmetric                  | symmetric                  |

The most negative intermediate is `-72`; the most positive is `1185`. Both
are well within `[-32768, +32767]`. **No node can overflow or underflow
signed 16-bit.**

## Sensitivity (how much room before this breaks)

The proof rests on `h0 + qlen·S_max ≤ 32767`. Solving for the slack:

```
slack = 32767 - h0 - qlen·S_max
      = 32767 - 1024 - 160
      = 31583
```

The design remains safe under any of these single-parameter scalings:

- `W_MATCH` raised from 1 → ~198 (with current `qlen = 160`, `h0 = 1024`)
- `MAX_QLEN` raised from 160 → ~31000 (with current `W_MATCH = 1`)
- `h0` budget raised from 1024 → ~32600

If you later raise `W_MATCH`, `MAX_QLEN`, or the `h0` budget, re-run the
inequality `h0 + qlen·W_MATCH ≤ 2^(SCORE_WIDTH-1) - 1` to confirm
sufficiency, and bump `SCORE_WIDTH` if it fails.

## Enforcement

The envelope is not merely assumed — it is checked at two layers, so a
misbehaving caller cannot silently drive the PEs past the proven bounds:

1. **Host input validation (primary).** `bsw_fpga::Accelerator::submit()`
   rejects (throws `std::invalid_argument`) any request whose `h0`, gap
   penalties, `qlen`, or `tlen` fall outside the envelope. The numeric bounds
   live in `host/bsw_fpga.h` as named constants (`H0_MAX = 1024`,
   `GAPO_MAX = 64`, `GAPE_MAX = 8`) with a comment tying them to this proof, so
   a future edit to one side is visible against the other.
   `host/loopback_test.cpp::test_input_validation` exercises the accept path
   plus one rejection per bound.

2. **RTL runtime safety net (secondary).** `bsw_pe.sv` contains
   simulation-only `assert` statements (stripped by synthesis via
   `// synthesis translate_off`) that fail loudly if `H`, `E`, or `F` ever
   leaves the `[0, SAFE_BOUND]` window. `SAFE_BOUND = 16384` is set well above
   `H_MAX = 1184` but well below the int16 limit, so any drift (host bypassing
   validation, future config change, RTL bug) is caught at the boundary rather
   than after silent wrap-around. The AXIS adapter additionally rejects
   `qlen > N_PE` at ingress, returning a result with `error = 1`.

These assertions pass on the current test suite (`tb_bsw_pe`, `tb_bsw_top`,
`tb_bsw_ext`, including the max-size 160/1024 vectors).
