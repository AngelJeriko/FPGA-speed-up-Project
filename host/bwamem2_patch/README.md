# bwa-mem2 instrumentation patch

The golden vectors that verify this project's RTL were captured by temporary
instrumentation added to **bwa-mem2's `src/bwamem.cpp` and `src/bwamem_pair.cpp`**.
That instrumented source lived only on the capture machine and was reverted to a
clean binary afterward (see [`../../docs/bwamem2_instrumentation.md`](../../docs/bwamem2_instrumentation.md)).

This directory is the **assembled, apply-able form of that patch** so the capture
step is reproducible from the repo. It does not modify bwa-mem2 in place — the hooks
are **paste-ready snippets** with explicit anchors, matching how they were originally
applied. (bwa-mem2 evolves; a line-context `.diff` against one commit would rot, so
the snippets are anchored to *existing code landmarks* instead.)

## Provenance & honesty

Two kinds of snippet are indexed here:

- **AUTHORITATIVE (committed source).** Five snippets were committed verbatim as the
  project progressed — they are the exact code that was pasted in. They live next to
  the model they validate (not moved, to keep their Makefile/validator references intact):

  | Snippet | Target file | Env var | Captures / validates |
  |---------|-------------|---------|----------------------|
  | [`../chaining/capture/chain_capture.inc`](../chaining/capture/chain_capture.inc) | `src/bwamem.cpp` | `ALNREG_CHAIN_OUT` | seed stream + pre/post-`mem_chain_flt` chains → `host/chaining/chain.h` |
  | [`../extend_orchestrator/capture/clamp_capture.inc`](../extend_orchestrator/capture/clamp_capture.inc) | `src/bwamem.cpp` | `ALNREG_CLAMP_OUT` | `bns_fetch_seq_v2` contig-clamp → `host/extend_orchestrator/bns_clamp.h` |
  | [`../mate_rescue/capture/matesw_capture.inc`](../mate_rescue/capture/matesw_capture.inc) | `src/bwamem_pair.cpp` | `ALNREG_MATE_OUT` | batched SIMD SW (`kswv`) in/out → `host/mate_rescue/hw.h` |
  | [`../mate_rescue/capture/orch_capture.inc`](../mate_rescue/capture/orch_capture.inc) | `src/bwamem_pair.cpp` | `ALNREG_ORCH_OUT` | `mem_matesw_batch_post` orchestration → `host/mate_rescue/orch.h` |
  | [`../mate_rescue/capture/sel_capture.inc`](../mate_rescue/capture/sel_capture.inc) | `src/bwamem_pair.cpp` | `ALNREG_SEL_OUT` | mate candidate selection → `host/mate_rescue/pe.h` |

- **RECONSTRUCTED (from spec).** The extend-orchestrator capture (instrument #5, the
  one that produced the `host/extend_orchestrator/` golden) was reverted before it was
  committed. [`ext_capture.inc`](ext_capture.inc) in this directory reproduces its
  **documented** behaviour, rebuilt from the byte format in
  [`../extend_orchestrator/README.md`](../extend_orchestrator/README.md) and the anchors
  in the instrumentation doc, in the same idiom as the authoritative snippets. It carries
  an **acceptance test** (regenerate the golden and confirm `30000/30000` bit-exact) —
  run it before trusting a fresh capture.

- **DOCUMENTED-ONLY (not reconstructed here).** The merge-sorter family — histogram
  (`ALNREG_HIST_OUT`, always-on), score-sort vector dumper (`ALNREG_VEC_OUT`), tie-order
  test (`ALNREG_TIE_TEST`), v2 dedup dumper (`ALNREG_V2_OUT`) — is fully described with
  line ranges in [`../../docs/bwamem2_instrumentation.md`](../../docs/bwamem2_instrumentation.md)
  §1–4, and its outputs are committed (`host/merge_sorter/vectors/alnreg_vectors.bin.gz`).
  Those `.gz` vectors are what the sim actually consumes, so re-capture is rarely needed;
  if it is, reconstruct the same way as `ext_capture.inc` from the doc + the format in
  `host/merge_sorter/`.

## Which base bwa-mem2?

The captures were taken against a standard bwa-mem2 build; the pristine
`src/bwamem.cpp` was **116,545 bytes (LF)**. Pin your checkout and record its commit
before applying, e.g.:
```bash
git clone --recursive https://github.com/bwa-mem2/bwa-mem2
cd bwa-mem2 && git rev-parse HEAD > ../bwamem2_base_commit.txt
cp src/bwamem.cpp src/bwamem.cpp.orig        # keep a pristine backup for revert
cp src/bwamem_pair.cpp src/bwamem_pair.cpp.orig
```
The hooks reference stable bwa-mem2 landmarks (`mem_chain`, `mem_chain_flt`,
`mem_chain2aln_across_reads_V2`, `bns_fetch_seq_v2`, `mem_sam_pe_batch_post`); each
snippet header names its anchor lines. Confirm the `⟨BIND⟩`-tagged local names against
your version.

## Apply → build → capture → revert

```bash
# 1. APPLY: open each target file and paste each snippet at the anchors named in its
#    header. bwamem.cpp gets: chain_capture, clamp_capture, ext_capture.
#    bwamem_pair.cpp gets: matesw_capture, orch_capture, sel_capture.

# 2. BUILD (rebuild only the dispatched SIMD variant — see scripts/remote_ext_capture.sh):
make arch=avx512 EXE=bwa-mem2.avx512bw all      # or your CPU's arch

# 3. CAPTURE (arm one or more env vars; unset = zero cost, except the always-on histogram):
ALNREG_EXT_OUT=ext_vec.bin ALNREG_EXT_MAX=30000 \
  ./bwa-mem2 mem -t16 hg38_chr1-5.fa r1.fq r2.fq >/dev/null
#   scripts/remote_ext_capture.sh automates arch-detect → build → 50k-pair subset → capture.

# 4. VALIDATE (example: extend-orchestrator golden):
gzip -c ext_vec.bin > ../extend_orchestrator/vectors/ext_vec.bin.gz
( cd ../extend_orchestrator && make run )        # expect 30000/30000 reads bit-exact

# 5. REVERT to a clean binary when done:
cp src/bwamem.cpp.orig src/bwamem.cpp
cp src/bwamem_pair.cpp.orig src/bwamem_pair.cpp
make -j$(nproc)
```

> Note: instrument #1 (histogram) is **always-on** in the original — even an un-armed
> run writes `alnreg_hist.tsv`. `ext_capture.inc` and the committed snippets are all
> **env-gated** (zero cost when their env var is unset).

See [`../../docs/reproducing.md`](../../docs/reproducing.md) §2.4 for where this fits in
the from-scratch flow, and [`../../docs/bwamem2_instrumentation.md`](../../docs/bwamem2_instrumentation.md)
for the full instrument inventory and overheads.
