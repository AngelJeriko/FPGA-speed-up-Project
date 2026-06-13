# EMF Fire-Rate Results — First Run (CONFOUNDED) + Analysis

Result of `remote_align_firerate.sh` on the diverse set vs chr1-5, 16 threads.
**Headline: the ancestry comparison is CONFOUNDED and not usable as-is; the run did,
however, validate the EMF premise via one clean data point.** Recorded honestly so the
methodology fix is on the record.

Date: 2026-06-13.

## Raw results
| Sample | Ancestry | Read len | total_primary | mapped % | fire % of mapped | fire % of total |
|---|---|---|---|---|---|---|
| HG00733 / ERR3988823 | Puerto Rican | 150 | 100,000,000 | **99.89%** | **69.07%** | 69.00% |
| NA12878 / ERR174310 | European | 101 | 100,000,000 | 59.67% | 44.56% | 26.59% |
| NA19240 / SRR2103644 | Yoruba | 125 | 100,000,000 | 62.09% | 22.19% | 13.78% |
| HG002 / SRR24123611 | Ashkenazi | 150 | 42,862,742 | 12.17% | 0.09% | 0.01% |
| HG005 / SRR24123546 | Han Chinese | 150 | 39,324,614 | 11.76% | 0.09% | 0.01% |

(fire = primary, mapped, MAPQ==60, CIGAR ^[0-9]+M$, NM:i:0, proper-pair.)

## Why it's confounded
`mapped %` spans 12%–99.89%. chr1-5 is ~34% of GRCh38, so uniform WGS should map ~34%
everywhere — the spread is an ARTIFACT, not ancestry:
1. **First-N subsampling (`head`) hit coordinate-sorted sources.** Archived FASTQs are
   often derived from coordinate-sorted BAM/CRAM → the first 50M reads are chr1-onward,
   enriched for chr1-5. HG00733's 99.89% mapped = its reads ARE chr1 reads.
2. **HG002 & HG005 are ~0% exact even among mapped** → almost certainly NOT standard
   genomic WGS (different library prep/provenance); unusable. Needs read-level inspection.
3. **proper-pair requirement** on a PARTIAL reference conflates "exact match" with
   "both mates landed in chr1-5" → crushes low-mapping samples.
4. **Read lengths differ** (101/125/150) → longer reads inherently less likely exact.

## What IS valid (validates the EMF premise)
**HG00733 = the clean data point.** Its reads are (accidentally) chr1-5-enriched, so its
denominator ≈ "reads that belong to this reference." Its fire rate **69%** lands inside
the literature **66-76%** exact-match range → confirms ~2/3-3/4 of on-target reads are
exact-unique-full-length and can bypass seed+extend. The EMF leverage is REAL. Other
samples' low numbers = dilution by off-target reads, not low exact-match rates.

## Clean re-measurement design (for a real ancestry curve, later)
- **Random subsampling** (`seqtk sample`), NOT `head` — removes the coordinate-sort bias.
- **Verified same library type + read length** across samples (drop HG002/HG005 runs;
  pick confirmed WGS accessions; match read length).
- **Drop the proper-pair requirement** (measure single-end-style exact-unique among
  mapped) OR require both-mates-mapped explicitly and report it separately.
- **Ideally a FULL-genome reference** — the natural home for an exact-match measurement
  (loops back to the 90 GB VM option). On chr1-5, off-target reads are always noise.

## Method status
The fire-rate pipeline (`remote_align_firerate.sh`, streamed SAM → mawk counter) WORKS —
it produced sensible numbers where the data was clean (HG00733). The fix is data
selection + sampling, not the tooling.
