# bsw_pe gap-open basis fix (M vs H)

## Summary

`rtl/bsw_pe.sv` — the single DP cell shared by the extension array (`bsw_top`) and
mate-rescue (`restart_mode`) — opened new affine gaps from `H_new = max(M, E, F)`:

```systemverilog
E_open = H_new - oe_del_reg;   // BEFORE (wrong)
F_open = H_new - oe_ins_reg;
```

bwa-mem2's `scalarBandedSWA` (`src/bandedSWA.cpp:190,195`) opens them from **M**,
the diagonal match term (`M = H(i-1,j-1)?H(i-1,j-1)+s:0`):

```c
t = M - oe_del; ...   // E(i+1,j) = max(M - oe_del, E - e_del, 0)
t = M - oe_ins; ...   // F(i,j+1) = max(M - oe_ins, F - e_ins, 0)
```

Line 184 states the intent explicitly: *"separating H and M to disallow a cigar
like 100M3I3D20M"* — a new gap must **not** open on top of a cell whose own best
path is a gap. Opening from `H_new` permits (and over-scores) adjacent
opposite-type gaps (an insertion immediately followed by a deletion, or vice versa).

Fix (`rtl/bsw_pe.sv`):

```systemverilog
E_open = M_term - oe_del_reg;   // AFTER (matches bwa)
F_open = M_term - oe_ins_reg;
```

`M_term` already equals the C++ `M` exactly (extension: `diag!=0 ? diag+s : 0`;
restart: `diag+s`). `H_new` is still computed and drives the H output; only the
gap-open basis changed.

## Severity / when it bites

`H_new >= M` always, so the two agree unless a gap is the winning path *into* the
cell. Concretely the E-gap diverges only when **F** wins into the cell (opening a
deletion right after an insertion), symmetrically for F. For short-read parameters
(o=6, e=1) this never moved the global-max **score** in 24M randomized trials — the
max cell sits on a match-rich diagonal — but it **does** move `gscore` (the
score reaching the end of the query), which bwa-mem2 consumes in the `gscore>0`
alnreg-assembly branch to decide query-end/global extension and clipping. So the
practical effect is on end-to-end/clipped alignments, not the local-alignment score.

Because it never perturbed `score/qle/tle` on the captured corpus, the existing
bit-exact goldens (13/13, 30000/30000) never flagged it — a coverage gap, not a
false pass. This is the "a green test proves nothing until it can go red" lesson:
the vectors proved the corner wasn't *hit*, not that the recurrence was *right*.

## Regression proof (RED -> GREEN)

Discriminating vector: `host/extend_orchestrator/vectors/disc_mvsh.txt`
(qlen=16, tlen=26, h0=25, o=6/e=1; correct `gscore=5`, buggy H-open `gscore=6`).
Mined + golden-scored by the faithful twin `gen_bsw_mvsh.cpp`, which reproduces
real bwa on 15886/15887 real extensions (the 1 diff is an unrelated gscore band
corner; `score/qle/tle` match on all 15887).

Run through the real `bsw_top` via `tb_bsw_ext`:

| RTL | real 15887 baseline | `disc_mvsh` |
|-----|---------------------|-------------|
| before fix (H-open) | ALL PASS | **FAIL** `gsc 6/5` |
| after fix (M-open)  | ALL PASS | **PASS** `gsc 5/5` |

Reproduce:
```bash
# build the twin, re-mine + re-score the vector (optional; committed already)
cd host/extend_orchestrator && g++ -O2 -std=c++17 -o gen_bsw_mvsh gen_bsw_mvsh.cpp
./gen_bsw_mvsh validate vectors/ext_sw_vectors.txt        # -> MODEL==BWA (score/qle/tle)

# run the regression vector through the real bsw_top
cd ../.. && bash scripts/run_sim.sh tb_bsw_ext            # builds Vtb_bsw_ext + baseline
/tmp/bsw/obj_tb_bsw_ext/Vtb_bsw_ext +VEC=host/extend_orchestrator/vectors/disc_mvsh.txt
#   fixed RTL -> "1 extensions, 0 failures ... ALL PASS"
```
