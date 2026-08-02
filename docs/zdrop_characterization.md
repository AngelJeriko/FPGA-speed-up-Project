# zdrop coverage gap — characterized (2026-08-02)

**Question:** the zdrop early-exit in `bsw_max_tracker` was flagged as a coverage gap —
"output-neutral on the corpus," i.e. never observed to change a result, hence never verified
red/green. Is that a testing oversight (a real untested risk) or something deeper?

**Answer: it's architectural, not an oversight. `zdrop` is dormant in this engine at the
production config, and that is exactly why the corpus can't distinguish it.** Evidence below.

## What `zdrop` does
Ported verbatim from bwa-mem2 `ksw_extend2`: when a target row's max (`mm`) has dropped
below the running global max by more than `zdrop`, *after correcting for the index drift*
(the part explainable by a plain gap), abort the extension early:

```
if (max - mm - |(i-max_i) - (mj-max_j)| * e  >  zdrop)  break;
```

## Why it never fires here (production `zdrop=100`)
`bsw_top` computes the **full rectangle (UNBANDED, w=BIG)**. In an unbanded DP there is
*always* a straight target-deletion path back to the peak column, costing `o_del + e_del·di`.
That path makes the drift-corrected drop `max - mm - drift ≈ o_del = 6` for the row max —
**a floor of ~6, far below `zdrop=100`.** So the break condition essentially never holds.
`zdrop` is fundamentally a *banded*-alignment safeguard (in banded ksw the deletion escape
can fall outside the band, letting the score crater); with no band, it's inert.

## Empirical evidence (`host/extend_orchestrator/zdrop_probe.cpp`)
Runs `hw_extend2` (the model `bsw_top` is bit-exact to) with zdrop ON vs OFF:

| population | result |
|---|---|
| 200,000 random (ql≤160, tl≤400), **zdrop=100 vs 0** | **0 cases differ** in any field (score/qle/tle/gscore/gtle) |
| adversarial (match prefix + in-query divergence), sweep zdrop | largest firing **zdrop≈47**, and it changes **only `gtle`**, and only when **`gscore=0`** |

`tb_bsw_ext` deliberately treats `gtle` as **don't-care when `gscore≤0`** (it's unused
downstream in that branch). So even the one reachable effect lands entirely in a don't-care.
**score / qle / tle / gscore are never affected by zdrop in this architecture.**

## Conclusion
- The corpus output-neutrality of zdrop is **expected and correct**, not a missing test.
- `zdrop=100` is **not a latent correctness risk** for bsw_top — it cannot change any
  result-bearing output.
- The RTL zdrop path (`zdrop_break_o` + FSM early-exit) is a faithful port kept for
  parity/future use; it is exercised only at non-production tiny zdrop and only on the
  don't-care `gtle`.
- **If banding is ever added** (dynamic beg/end shrink), zdrop becomes live and MUST be
  re-verified with directed vectors at that point — re-run `zdrop_probe` against the banded
  model; it will start reporting firing cases in result-bearing fields.

This closes the gap in the way that matters: the behaviour is now *characterized with
reproducible evidence*, not an unknown.
