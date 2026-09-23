# SWA golden vectors (BSWCAP01)

Captured from bwa-mem2 by `host/bwamem2_patch/swa_capture.inc`. Format is
documented at the top of that file; the milestone write-up is
`docs/swa_golden_capture.md`.

- `ecoli_swa_2k.bin.gz` — first 2,000 of the 49,468 records from the default
  E. coli run. Must replay bit-exact. Regenerate the full set with
  `scripts/capture_swa_ecoli.sh`.
- `divergent_*.bin.gz` — the 7 characterised records where `ksw_extend2`
  disagrees with bwa-mem2 on `gtle`/`gscore` under perturbed parameters.
  These must **stay red**; `make check` asserts it.
- `bandclamp_*.bin.gz` — 14 records from tight-gap captures (`-E 20,20` and
  `-O 30,30 -E 12,9`) where the `max_ins`/`max_del` band clamp is load-bearing.
  Default parameters never exercise the division transform in `ksw_hls.h`;
  these do. See `docs/swa_hls_kernel.md`.
