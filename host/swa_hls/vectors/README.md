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
