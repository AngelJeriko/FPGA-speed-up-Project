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

The C++ reference model (next) replays HEADER+CHAIN through the orchestrator and
checks bit-exactness against the type-2 OUTPUT array.
