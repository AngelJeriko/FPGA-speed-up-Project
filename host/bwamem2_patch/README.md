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

- **RECONSTRUCTED (verified against source).** The extend-orchestrator capture
  (instrument #5, which produced the `host/extend_orchestrator/` golden) was reverted
  before it was committed. [`ext_capture.inc`](ext_capture.inc) reproduces its
  **documented** behaviour, rebuilt from the byte format in
  [`../extend_orchestrator/README.md`](../extend_orchestrator/README.md) and the doc
  anchors. It was then checked against the local bwa-mem2 checkout **@ commit `97978f9`**:
  the format is byte-exact vs the reader `host/extend_orchestrator/parse.h`, and the
  anchors + local names are the real ones at that commit (line refs are in the file).
  The checkout also surfaced a structural fact the spec alone didn't: the cross-chain
  purge (`mem_sort_dedup_patch`) runs in the **caller**, not inside `mem_chain2aln`, so
  this snippet has **two sites in `src/bwamem.cpp`** — HEADER+CHAIN inside
  `mem_chain2aln_across_reads_V2` (~:2108/:2172), and the post-purge OUTPUT in the
  caller's purge loop (~:1155), joined by a thread-local read_id. The one thing static
  review cannot prove — the value bindings + the two-site join — is exactly what the
  **acceptance test** (regenerate the golden, confirm `30000/30000` bit-exact) validates.
  Run it before trusting a fresh capture.

- **DOCUMENTED-ONLY (not reconstructed here).** The merge-sorter family — histogram
  (`ALNREG_HIST_OUT`, always-on), score-sort vector dumper (`ALNREG_VEC_OUT`), tie-order
  test (`ALNREG_TIE_TEST`), v2 dedup dumper (`ALNREG_V2_OUT`) — is fully described with
  line ranges in [`../../docs/bwamem2_instrumentation.md`](../../docs/bwamem2_instrumentation.md)
  §1–4, and its outputs are committed (`host/merge_sorter/vectors/alnreg_vectors.bin.gz`).
  Those `.gz` vectors are what the sim actually consumes, so re-capture is rarely needed;
  if it is, reconstruct the same way as `ext_capture.inc` from the doc + the format in
  `host/merge_sorter/`.

## Which base bwa-mem2?

**Reference commit: `97978f9`** (`bwa-mem2` master, "Badges for usegalaxy.org and
usegalaxy.eu (#279)"). The `ext_capture.inc` anchors and local names were resolved
against this exact commit; the pristine `src/bwamem.cpp` there is **116,545 bytes (LF)**.
The other snippets reference the same stable landmarks (`mem_chain`, `mem_chain_flt`,
`mem_chain2aln_across_reads_V2`, `bns_fetch_seq_v2`, `mem_sam_pe_batch_post`).

Pin your checkout and keep pristine backups before applying:
```bash
git clone --recursive https://github.com/bwa-mem2/bwa-mem2
cd bwa-mem2 && git checkout 97978f9         # or record whatever commit you use
git rev-parse HEAD > ../bwamem2_base_commit.txt
cp src/bwamem.cpp src/bwamem.cpp.orig        # revert target
cp src/bwamem_pair.cpp src/bwamem_pair.cpp.orig
```
If you use a different commit, re-confirm the anchor line numbers and the local names
(the `ext_capture.inc` header lists them per hook).

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
