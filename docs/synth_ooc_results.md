# OOC synthesis results — baseline (before synth-prep conversions)

Proxy part: **xc7v2000tfhg1761-2** (Virtex-7, -2 speed). 7-series proxy — RELATIVE numbers,
not absolute F1/VU9P. Clock target 3.0 ns (333 MHz); `Fmax = 1000/(3.0 − WNS)`.
Run on local Vivado (kanak), 2026-07-28. F1 needs ~250 MHz — everything below is far under.

| module | Fmax (MHz) | WNS (ns) | LUT | FF | BRAM (RAMB36) | DSP | verdict |
|--------|-----------:|---------:|----:|---:|--------------:|----:|---------|
| chain_store     | **89.1** | −8.22 | 134,467 | 66,147 | 10 | 0 | slow + LUT-bloated |
| bsw_max_tracker | **3.5**  | −280.9 | 21,611 | 6,574 | 0 | 2 | BEFORE (160-deep serial max-reduction) |
| matesw_dedup    | _pending_ | | | | | | (synth was still running) |

### Conversions applied (re-measure to fill "after")
- **bsw_max_tracker** ✅ serial 160-deep max-reduction → balanced log₂-depth tree.
  Bit-exact verified: tb_bsw_top 26/0, tb_bsw_ext 15887/0, tb_matesw_top 4000/0;
  mutation-tested (freeze reduction → tb_bsw_top T5 zdrop FAIL). **AFTER Fmax: _pending re-synth_.**

## Readout

**bsw_max_tracker = the worst, by far (3.5 MHz).** A ~283 ns combinational path — the
160-wide `row_*_pipe` scan feeding the zdrop 32×32 multiply + 164 adders, all in one
cycle (Vivado even warns "Not enough pipeline registers after wide multiplier"). This
**flips the static ranking**: the sweep put chain_store #1, but *measured* Fmax says
bsw_max_tracker is the more urgent fix. → convert its scan to an indexed/registered read
+ pipeline the multiplier.

**chain_store = 89 MHz, LUT-bloated (134K).** Instructive BRAM story:
- Registered-read arrays DID infer Block RAM: `in_qbeg/in_len/in_rid/in_isalt/in_score`
  → 10 RAMB36. Good — those are already correct.
- Combinational-read arrays fell to **Distributed RAM (RAM64M, LUT-based)**: `c_pos,
  c_lr/lq/ll, in_rbeg, c_rid/fq/isalt/n/head, p_rbeg/qbeg/len, c_tail, p_score` →
  3,968 RAM64M primitives. That is the 134K-LUT bloat AND the 89 MHz ceiling (the
  512-wide `c_pos` predecessor scan). → the #1 sweep item; convert `c_pos` to a
  sequential binary-search over registered-read BRAM.

**Takeaway:** measurement confirms both modules are nowhere near an F1 clock, and gives us
hard before-numbers. Order of attack by measured pain: **bsw_max_tracker → chain_store →
matesw_dedup**.

## After-conversion numbers go here
(re-run the same OOC synth on each converted module; record delta)
