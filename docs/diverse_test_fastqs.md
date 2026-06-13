# Diverse Human FASTQ Test Set + EMF Fire-Rate Measurement

Purpose: test bwa-mem2 — and quantify the planned **Exact-Match Filter (EMF)** —
across **ancestry, read length, and platform**. The EMF exact-match fire-rate
scales with a sample's divergence from GRCh38, so spreading ancestries is the
actual experiment: African ancestry carries the most variation vs the reference
(⇒ lowest expected fire-rate), European the least (⇒ highest). The resulting
fire-rate-vs-ancestry curve tells us how robust the EMF's payoff is, which decides
whether leading the accelerator with the filter is justified.

Context: profiling showed FM-index **seeding ~31%** dominates bwa-mem2 runtime while
banded SWA is only ~6.5% (see `baseline_profiling_setup.md`). The accelerator plan
front-ends seeding with an EMF that emits alignments directly for reads matching the
reference exactly + uniquely, bypassing seeding/chaining/extension entirely.

---

## 1. The samples

Fetched 2026-06-12 to `ccloud@216.227.218.169:/home/ccloud/reads_diverse/` via
`scripts/remote_fetch_diverse.sh` — first **50M read pairs per sample** (streamed
from ENA; `head` closes the pipe so full multi-GB files are never downloaded).
Run URLs are resolved at runtime via the ENA filereport API. Downloads run **in
parallel across all samples** and are **resumable** (each mate is written to a
`.part` file then atomically renamed; an already-complete mate is skipped on
restart), since ENA per-connection throughput is low (~0.6–1 MB/s). The European baseline
(NA12878/ERR174310) is subsampled on-box by `remote_align_firerate.sh` from the
already-present full file, so all points are at comparable depth.

| Sample | Ancestry (1000G pop) | Run accession | Platform | ~Read len | Truth set |
|---|---|---|---|---|---|
| NA12878 / HG001 | European (CEU) | ERR174310 (subset) | HiSeq 2000 | 2×101 | GIAB |
| HG002 / NA24385 | Ashkenazi Jewish | SRR24123611 | HiSeq 2500 | ~2×150 | GIAB |
| HG005 / NA24631 | Han Chinese (E. Asian) | SRR24123546 | HiSeq 2500 | ~2×150 | GIAB |
| HG005 (length axis) | Han Chinese | SRR2831462 | HiSeq 2500 | ~2×250 | GIAB |
| HG00733 | Puerto Rican (admixed Amer.) | ERR3988823 | NovaSeq 6000 | ~2×150 | 1000G/HGSVC |
| NA19240 | Yoruba (African) | SRR2103644 | HiSeq 2500 | ~2×150 | 1000G/HGSVC |

**Caveats**
- Read lengths inferred from ENA `base_count/read_count`; ENA's per-read vs
  per-pair counting is inconsistent → confirm with `zcat file | head` after download.
- Some accessions have <50M pairs (e.g. SRR2831462 ~21–42M; SRR24123611 ~10–21M);
  `head` caps gracefully, so those subsets are simply smaller.
- Reference is GRCh38 chr1–5, so ~84% of WGS reads have no locus there and stay
  unmapped — fine for a fire-rate measured *among mapped reads*, and for throughput;
  wasteful only in that we stream reads that can't map.

### Fetched results (confirmed 2026-06-13)

| Sample | Ancestry | Read pairs | Read len | PE-clean? |
|---|---|---|---|---|
| HG002 / SRR24123611 | Ashkenazi | 21.4M | 150 bp | ✅ |
| HG005 / SRR24123546 | Han Chinese | 19.7M | 150 bp | ✅ |
| HG005 2×250 / SRR2831462 | Han Chinese | **42.5M R1 / 39.5M R2** | 250 bp | ❌ unequal mates |
| HG00733 / ERR3988823 | Puerto Rican | 50.0M | 150 bp | ✅ |
| NA19240 / SRR2103644 | Yoruba | 50.0M | **125 bp** | ✅ |
| NA12878 / ERR174310 (baseline, built at align time) | European | 50M | 101 bp | ✅ |

**SRR2831462 (2×250) is excluded from the paired-end fire-rate run** — its ENA
`_1`/`_2` files have different read counts (42.5M vs 39.5M), so they are not a clean
equal-length pair (a known SRA split quirk). bwa-mem2 PE mode needs equal, in-order
mates. The dedicated 250 bp read-length data point can be recovered later via a
cleaner 2×250 GIAB accession or a single-end run with an SE-adjusted fire criterion
(drop the proper-pair requirement). The four clean diverse samples + the European
baseline still give the full ancestry curve (read lengths 101–150 bp).

---

## 2. Fire-rate measurement (`scripts/remote_align_firerate.sh`)

Aligns each subset (plus the European baseline) with the unmodified bwa-mem2 against
`/home/ccloud/ref/hg38_chr1-5.fa`, 16 threads, and computes the EMF fire-rate by
streaming the SAM through an awk counter — **the SAM is never written to disk**
(a 50M-pair SAM is hundreds of GB).

### What counts as a "fire" (the conservative bit-exact contract)
A read is counted as EMF-eligible only when it is provably what bwa-mem2 already
emitted for a trivially-placeable read — so the filter could emit it directly and be
bit-identical:

| Condition | SAM test | Meaning |
|---|---|---|
| primary only | not flag 0x100 / 0x800 | count each read once |
| mapped | not flag 0x4 | has a locus in chr1–5 |
| unique | `MAPQ == 60` | bwa-mem2's max → no competing alignment |
| full-length | `CIGAR ~ /^[0-9]+M$/` | one match op, no soft-clips/indels |
| exact | `NM:i:0` | zero edit distance (no mismatches) |
| proper pair | flag 0x2 | mate placed consistently (PE contract) |

The awk uses integer bit math (`int(flag/256)%2`, …) so it runs under **mawk**
(Ubuntu default), not just gawk.

### Outputs (`/home/ccloud/firerate_results/`)
- `firerate_summary.tsv` — one row per sample:
  `sample, total_primary, mapped, fire, fire_pct_of_mapped, fire_pct_of_total, mapped_pct`
- `align_firerate.log` — run log with per-sample timing
- `bwa_stderr_<label>.log` — bwa-mem2 progress/stderr per sample

**Headline metric:** `fire_pct_of_mapped` — of reads that actually have a locus in
the reference, what fraction the EMF can bypass. Expected to decline from European →
Ashkenazi → admixed American → East Asian → African as divergence rises, and to
decline with longer reads (more chance of ≥1 mismatch per read).

### Run
```bash
cd /home/ccloud && nohup bash remote_align_firerate.sh >/dev/null 2>&1 &
# watch: tail -f /home/ccloud/firerate_results/align_firerate.log
```
Sequential (one sample at a time, 16 threads each). ~50M pairs ≈ ~30 min/sample on
this box; smaller subsets faster. Index peak RSS ~14 GB (fits the 31 GB box).

---

## 3. Why this feeds the build

Step 1 of the EMF engine scope is "measure the real exact-unique fire-rate" — this
set turns that single number into a curve across ancestry and read length, which:
1. sets the realistic speedup the EMF buys (is it ~40% or ~70% of mapped reads?),
2. shows whether the payoff is ancestry-robust or collapses on divergent samples,
3. yields the golden records (exact-unique reads) the future RTL testbench checks
   against bit-for-bit.

Cross-refs (repo): `baseline_profiling_setup.md`, `speedup_plan.md`,
`profiling_results/`.
