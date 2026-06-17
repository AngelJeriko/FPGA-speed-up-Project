# extend_orchestrator — Stage-1 on-chip BSW→sorter pipeline

Goal: run the whole back half of bwa-mem2's mapper between seed extension and the
merge-sorter **on the FPGA**, returning a single consolidated alnreg list to the
CPU. This models `mem_chain2aln_across_reads_V2` (the extension orchestration) so
its output feeds straight into the verified `msort_v2_top` engine — no host round
trip in between.

Stage 1 is **host-fed reference**: the host still fetches each chain's reference
window; the FPGA does seed score-sort → left/right banded SW (via `bsw_top`) →
alnreg assembly + seedcov → cross-chain redundancy purge → merge-sort/dedup.
(Stage 2 would add an on-chip reference-fetch engine; deferred — it's the
memory-bound, HBM-relevant piece.)

## Golden vectors — `vectors/ext_vec.bin.gz`

Captured from a real bwa-mem2 run (hg38 chr1-5 / HG00733, 50k read pairs, first
30k reads with chains) via temporary instrumentation in
`mem_chain2aln_across_reads_V2` (env `ALNREG_EXT_OUT`; see
`scripts/remote_ext_capture.sh` and `docs/bwamem2_instrumentation.md`). The remote
source was reverted to the clean binary afterward.

Binary, native little-endian, record-tagged (records from concurrent threads
interleave; join by `read_id`):

```
type 0 HEADER: i32 type=0; i64 read_id; i32 l_query; i32 n_chains;
               i32 cfg[10] = {a,b,o_del,e_del,o_ins,e_ins,w,zdrop,pen_clip5,pen_clip3};
               u8 query[l_query]
type 1 CHAIN:  i32 type=1; i64 read_id; i32 chain_idx; i32 rid; f32 frac_rep;
               i64 rmax0; i64 rmax1; i32 n_seeds;
               n_seeds*{i64 rbeg; i32 qbeg; i32 len; i32 score};
               i64 ref_len(=rmax1-rmax0); u8 ref[ref_len]
type 2 OUTPUT: i32 type=2; i64 read_id; i32 n_out;
               n_out*{i64 rb; i64 re; i32 qb; i32 qe; i32 score; i32 truesc;
                      i32 w; i32 seedcov; i32 seedlen0; i32 rid}
```

cfg in the captured set = bwa-mem2 defaults `{1,4,6,1,6,1,100,100,5,5}`.

The C++ reference model replays HEADER+CHAIN through the orchestrator and checks
bit-exactness against the type-2 OUTPUT array.

## C++ model (verified)

`ksw.h` (ksw_extend2 verbatim + scoring helpers), `orch.h` (extend_only → purge →
orchestrate), `parse.h` (loader). `make run` → **30,000/30,000 reads bit-exact,
565,446 alnregs**. `make gen` writes the pre-purge golden and reports purge impact
(**55.9% of pre-purge alnregs are purged** → purge is high-impact, done in HW).
`make asm` writes per-alnreg assembly vectors for the RTL.

## RTL (in progress)

The orchestrator is built bottom-up against model-generated vectors:

- **`rtl/orch_assemble.sv`** — alnreg assembly datapath (SW results + seed/cfg →
  rb/re/qb/qe/score/truesc/w). Verified **565,446/565,446** via `tb/tb_orch_assemble.sv`:
  ```sh
  make asm                       # host/extend_orchestrator: regenerate vectors
  cd <repo root>
  verilator --binary --timing --top-module tb_orch_assemble --timescale 1ns/1ps \
    -Wno-WIDTH -Wno-UNOPTFLAT -Wno-TIMESCALEMOD -Wno-DECLFILENAME -Mdir /tmp/obj_asm \
    rtl/orch_assemble.sv tb/tb_orch_assemble.sv
  /tmp/obj_asm/Vtb_orch_assemble +VEC=host/extend_orchestrator/vectors/asm_vectors.txt
  ```
- **`rtl/orch_seedcov.sv`** — seedcov stage: streaming accumulator, sums seed.len
  over chain seeds contained in the alnreg's final [qb,qe)x[rb,re). Verified
  **565,446/565,446** via `tb/tb_orch_seedcov.sv` (`make seedcov` to regenerate):
  ```sh
  verilator --binary --timing --top-module tb_orch_seedcov --timescale 1ns/1ps \
    -Wno-WIDTH -Wno-UNOPTFLAT -Wno-TIMESCALEMOD -Wno-DECLFILENAME -Mdir /tmp/obj_sc \
    rtl/orch_seedcov.sv tb/tb_orch_seedcov.sv
  /tmp/obj_sc/Vtb_orch_seedcov +VEC=host/extend_orchestrator/vectors/seedcov_vectors.txt
  ```
- **`rtl/orch_window.sv`** — window-builder (address generator): streams the source
  indices for the 4 extension windows (Lq/Lr reversed, Rq/Rr forward) so an external
  query/ref block-RAM read fills the bsw_top inputs. Verified **565,446/565,446** via
  `tb/tb_orch_window.sv` (`make window` to regenerate):
  ```sh
  verilator --binary --timing --top-module tb_orch_window --timescale 1ns/1ps \
    -Wno-WIDTH -Wno-UNOPTFLAT -Wno-TIMESCALEMOD -Wno-DECLFILENAME -Mdir /tmp/obj_win \
    rtl/orch_window.sv tb/tb_orch_window.sv
  /tmp/obj_win/Vtb_orch_window +VEC=host/extend_orchestrator/vectors/window_vectors.txt
  ```
- **Next:** `bsw_top` driver (band-doubling; needs the BSW resize), per-read
  accumulator, then the full FSM incl. the HW purge → stream into `msort_v2_top`.

**BSW sizing caveat (integration):** the existing `bsw_top` is `MAX_QLEN=128`,
`MAX_TLEN=256`, `BAND_WIDTH=64`. Real 150 bp extensions need qlen ≤ ~150, target ≤
~800, band ≤ ~150 → `bsw_pkg` params must be raised and the BSW engine re-verified
before it can drive the orchestrator.
