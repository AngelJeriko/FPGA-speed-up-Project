# Baseline Profiling Setup — Reference BWA-MEM2 on a Remote Server

Record of how the **software baseline** for this project was stood up, and the
reasoning behind each choice. The goal of this baseline is to run the *unmodified*
BWA-MEM2 aligner on a realistic human workload, profile it, and **confirm that the
banded Smith-Waterman kernel is the dominant compute cost** — the hotspot this
project accelerates on FPGA (`scalarBandedSWA` / `BandedPairWiseSW` in
`src/bandedSWA.cpp`).

Without this baseline we have no measured proof of *where* the time goes and no
golden reference output to validate the RTL against. Everything here is the
"before" picture.

Date stood up: **2026-06-09**.

---

## 1. Why we're doing this

The accelerator only pays off if banded SWA is actually the bottleneck. The
literature says it's ~40–70% of BWA-MEM2 runtime, but that's *our* claim to
verify on *our* target workload before committing FPGA effort. So we:

1. Build the stock CPU aligner.
2. Run it on real human paired-end reads against a reference sized to the
   machine.
3. Profile with `perf` and read off the hottest functions.
4. Keep the resulting SAM as a golden output for later RTL co-simulation.

---

## 2. Environment

### Local (where the data lives)
- Windows 10 host; data and tooling live in **WSL (Ubuntu)** at
  `/home/kanak/projects/bwa-mem2/`.
- BWA-MEM2 working repo (source + docs) on the Windows Desktop.

### Remote (where the runs happen)
| Property        | Value                                             |
|-----------------|---------------------------------------------------|
| Host            | `ccloud@216.227.218.169`                           |
| OS              | Ubuntu 24.04.3 LTS                                 |
| Cores           | 16                                                 |
| RAM             | 31 GiB (~32 GB)                                    |
| SIMD            | AVX-512 capable (runs `bwa-mem2.avx512bw`)         |
| Free disk       | ~897 GB                                            |
| sudo            | passwordless                                       |

**The 32 GB RAM ceiling is the single most important constraint** — it drives the
reference-genome decision in §4.

### Access
SSH from WSL → remote uses a key pair (ed25519, `~/.ssh/id_ed25519`), installed
once with `ssh-copy-id`. Key auth (not password) was required so long-running
transfers and builds can run **unattended in the background** — a password prompt
has no terminal to answer it when backgrounded.

---

## 3. What was transferred, and why

### The BWA-MEM2 repo
Copied from the local Desktop to `/home/ccloud/BWA-MEM2 repo/bwa-mem2/` with
`scp -r`. This is the source tree we build on the remote (it is *source only* —
no prebuilt binaries came across).

> Note: the folder name contains a space (`BWA-MEM2 repo`). This complicates
> shell quoting; always quote the path. A future cleanup is to rename it
> space-free on the remote.

### The reads (the stress-test input)
**ERR174310** — whole-genome sequencing of sample **NA12878** (Illumina Platinum
Genomes). Paired-end, gzipped:

| File                    | Size  | Role               |
|-------------------------|-------|--------------------|
| `ERR174310_1.fastq.gz`  | 18.5 GB | mate 1 (forward) |
| `ERR174310_2.fastq.gz`  | 17 GB   | mate 2 (reverse) |

~35 GB compressed, ~30× whole-genome coverage = hundreds of millions of read
pairs. This is a deliberately heavy, realistic workload chosen to **stress the
SWA kernel** — the amount of seed-extension (SWA) work scales with read count,
read length, and divergence, *not* with reference size.

Transferred from WSL to `/home/ccloud/reads/` via:

```bash
rsync -av --partial --progress \
  /home/kanak/projects/bwa-mem2/human_fastq_test/ERR174310_1.fastq.gz \
  /home/kanak/projects/bwa-mem2/human_fastq_test/ERR174310_2.fastq.gz \
  ccloud@216.227.218.169:/home/ccloud/reads/
```

`--partial` makes the multi-hour transfer resumable. (Reading directly from the
WSL ext4 filesystem, not via `/mnt/c`, keeps it fast.)

---

## 4. Reference genome choice (the key decision)

### Why NOT the full human genome
On a 32 GB machine the full GRCh38 is infeasible:

- **Index build** needs roughly **28 bytes per reference base** ≈ **~87 GB RAM**
  for the 3.1 Gbp genome — far over 32 GB.
- The on-disk index is **~42 GB**.
- Even just the **alignment** step peaks at **~30 GB and up**.

So the whole genome can't even be *indexed* here, let alone aligned with
headroom.

### What we used instead
**Human chromosomes 1–5 (GRCh38), concatenated** → `hg38_chr1-5.fa`.

- ~1.06 Gb of sequence (~2.12 Gb of index entries incl. reverse complement).
- Indexes to ~5.6 GB on disk.
- Measured index peak RAM **~24.9 GB** (≈78% of 32 GB) — a genuine memory stress
  with enough headroom to avoid OOM.

### The reasoning (two independent knobs)
- **Reference size → RAM footprint + index time.** Pick it as large as the box
  safely allows, to stress memory.
- **Read count → alignment wall-clock time.** Control runtime by subsampling
  reads, *independently* of the reference.

chr1–5 is the sweet spot: big enough to stress 32 GB and to map a large fraction
of genome-wide human reads (so seed extension genuinely fires), small enough to
build and load safely. Scaling lever: add chr6 for more RAM stress; drop to
chr1–3 if a smaller/faster index is wanted.

Downloaded from UCSC and concatenated:

```bash
cd /home/ccloud/ref
for c in chr1 chr2 chr3 chr4 chr5; do
  wget -c https://hgdownload.soe.ucsc.edu/goldenPath/hg38/chromosomes/$c.fa.gz
done
zcat chr1.fa.gz chr2.fa.gz chr3.fa.gz chr4.fa.gz chr5.fa.gz > hg38_chr1-5.fa
```

---

## 5. Build

The remote had **no toolchain**. Installed (passwordless sudo):

```bash
sudo apt-get update
sudo apt-get install -y build-essential zlib1g-dev   # zlib needed for -lz
```

Then built with a **plain `make`** in the repo:

```bash
cd "/home/ccloud/BWA-MEM2 repo/bwa-mem2"
make
```

**Why plain `make` (do NOT pass custom `CXXFLAGS`):** the stock Makefile already
sets `CXXFLAGS += -g -O3 -fpermissive $(ARCH_FLAGS)` (line 93). The `-g` gives us
the debug symbols `perf` needs, and `$(ARCH_FLAGS)` carries the required SIMD
flags. Overriding `CXXFLAGS` on the command line *replaces* that whole line and
strips the arch flags, breaking the SIMD builds. The default target also builds a
**multi-arch dispatcher**: `bwa-mem2.{sse41,sse42,avx,avx2,avx512bw}` plus a
`bwa-mem2` launcher that picks the best variant for the CPU at runtime (it
selected `avx512bw` here).

`ext/safestringlib` (a submodule dependency) was already present in the copied
tree, so no `git submodule update` was needed. If a future fresh `scp` omits it,
the fix is `git submodule update --init --recursive` in the repo.

Build result: `make exit code: 0`, all five variants + dispatcher produced.

---

## 6. Indexing

```bash
/usr/bin/time -v "/home/ccloud/BWA-MEM2 repo/bwa-mem2/bwa-mem2" \
  index /home/ccloud/ref/hg38_chr1-5.fa
```

| Metric              | Value           |
|---------------------|-----------------|
| Wall-clock          | 14 m 53 s       |
| Peak RSS            | ~24.9 GB        |
| Exit code           | 0               |
| Index files on disk | ~5.6 GB total (`.0123`, `.bwt.2bit.64`, `.amb`, `.ann`, `.pac`) |

`/usr/bin/time -v` was used specifically because it reports both wall-clock and
**peak resident memory** — the two numbers we care about for fitting the 32 GB
budget.

---

## 7. Planned alignment + profiling (the actual measurement)

### Calibrate, then scale
Don't guess the read count — measure once and extrapolate. Run a bounded subset
under `/usr/bin/time -v`:

```bash
BIN="/home/ccloud/BWA-MEM2 repo/bwa-mem2/bwa-mem2"
REF=/home/ccloud/ref/hg38_chr1-5.fa
# 50M read pairs, all 16 cores
/usr/bin/time -v "$BIN" mem -t 16 "$REF" sub_1.fq.gz sub_2.fq.gz > out_50M.sam
```

Runtime scales ~linearly with reads, so:
`safe_pairs ≈ 50M × (2 h ÷ measured_50M_time)`. That sets the read budget that
fits the **2-hour** target on 16 cores. (Subset built with
`zcat … | head -<N*4> | gzip`.)

### Profile
```bash
perf record -g "$BIN" mem -t 16 "$REF" sub_1.fq.gz sub_2.fq.gz > out.sam
perf report
```

**Expected outcome (the hypothesis to confirm):** the banded SWA kernel dominates
the profile — specifically `BandedPairWiseSW::getScores16` / `getScores8` and the
`smithWaterman*` SIMD routines in `src/bandedSWA.cpp`. That is the function family
this project reimplements as a systolic array on FPGA. The scalar reference for
the RTL is `BandedPairWiseSW::scalarBandedSWA` in the same file.

---

## 8. Reproducibility

The build + reference + index steps were captured in a single script run on the
remote (`/home/ccloud/remote_setup.sh`, logged to `/home/ccloud/setup.log`):

1. `cd` into repo, `make` (with the binary-exists guard).
2. `wget` chr1–5, `zcat` concatenate.
3. `bwa-mem2 index` under `/usr/bin/time -v`.

Re-running it from scratch on a comparable box reproduces the baseline, assuming
`build-essential` + `zlib1g-dev` are installed first.

---

## 9. Results

### Calibration (50M pairs, chr1-5, 16 threads)
| Metric | Value |
|--------|-------|
| Reads aligned | 100M reads = 50M pairs (exact) |
| Wall-clock (`mem`) | 28m47s (1727 s) |
| Throughput | ~28,950 pairs/s (~57,900 reads/s) |
| Parallel efficiency | ~98% across 16 cores |
| Peak RAM (alignment) | ~13.9 GB |
| Read length | ~101 bp |

So a **2-hour budget ≈ 208M pairs** here; the full ERR174310 set (~475M pairs)
would take ~4.5 h. Note: **alignment peak RAM (13.9 GB) is far below the index
build (24.9 GB)** — on this box alignment is compute-bound, not memory-bound.

### Profile (10M pairs, `perf` cpu-clock, 536K samples)
Top self-time symbols:

| Function | Self % | Phase |
|----------|--------|-------|
| `FMI_search::backwardExt` | 16.3% | FM-index seeding |
| `ks_introsort_mem_ars` | 11.4% | sort (PE post-proc) |
| `ks_introsort_mem_ars2` | 9.5% | sort (PE post-proc) |
| `kswv::kswv512_u8` | 9.4% | mate-rescue SW |
| `FMI_search::getSMEMsOnePosOneThread` | 8.8% | FM-index seeding |
| `mem_chain2aln_across_reads_V2` | 6.1% | chaining/extension |
| `bns_get_seq` | 4.6% | reference fetch |
| `BandedPairWiseSW::smithWaterman512_*` (+wrappers) | **~6.5% total** | **banded SWA (FPGA target)** |

Grouped by phase (self-time): **FM-index seeding ~30%**, **sort + PE
post-processing ~22%**, **mate-rescue SW ~11%**, **banded SWA ~6.5%**.

**Reproducibility confirmed:** the profile was re-run 3× on the same 10M-pair
subset. Run-to-run variance is **< 0.3 percentage points** on every top symbol and
the ranking is fixed (`backwardExt` ~15.9%, `ks_introsort_mem_ars` ~11.2%, etc.).
The finding is robust, not a single-run artifact. Raw comparison:
`~/repro_compare.txt` (local), `/home/ccloud/repro.log` (remote).

**Confirmed at production scale (2-hour run):** a 200M-pair run (11M perf samples,
~42% of the full dataset, wall-clock 1:59:44, peak RAM 14.15 GB) reproduces the
breakdown within ~1 pp on every symbol: seeding ~33%, sort/dedup ~23%, mate-rescue
SW ~12%, chaining ~11%, **banded SWA ~6.3%**. The hotspot ranking is invariant
across a 20× read-volume scale-up. Logs: `/home/ccloud/test2hr.log`,
`/home/ccloud/flat_2hr.txt` (local copy `~/flat_2hr.txt`).

### ⚠ Key finding — banded SWA is NOT the bottleneck on this workload
The kernel this project accelerates is only **~6.5%** of CPU self-time. By
Amdahl's law, offloading it alone caps end-to-end speedup at **~1.07× (≈7%)**;
offloading *all* Smith-Waterman (banded + mate-rescue ≈ 17%) caps at ~1.2×.

**Why (and why it's expected):** the "SWA = 40–70%" figure is for the *original*
scalar bwa-mem. bwa-mem2's whole contribution was SIMD-vectorizing SWA; once that
is done (AVX-512 here), the bottleneck shifts to **FM-index seeding**
(`backwardExt`) and **paired-end sort/mate-rescue**. This matches the literature
— the bwa-mem2 successor *BWA-MEME* targets the FM-index, not SWA.

**Caveats:** one config (101 bp reads, chr1-5, AVX-512). SWA fraction grows with
longer reads (150/250 bp) and may shift with a full-genome reference. Solid for
short-read human WGS on a SIMD CPU; not the last word for all configs.

### Artifacts on the remote
- Golden SAM sample: `/home/ccloud/out_10M.sam` (10M pairs, 5.6 GB)
- Profile data: `/home/ccloud/perf.data` (48 MB), flat report `/home/ccloud/flat.txt`
- Logs: `setup.log`, `cal.log`, `perf_run.log`

## 10. Next steps / open questions
The ~6.5% result challenges the project premise and should be resolved before
committing significant RTL effort. Options:

1. **Re-profile with longer reads** (150/250 bp) — the single biggest lever on the
   SWA fraction. Confirms whether the premise holds for a different read length.
2. **Re-profile against a larger/full reference** (needs a bigger-RAM box) — checks
   the genome-size effect on the seeding-vs-SWA balance.
3. **Reconsider the acceleration target** — on this workload the FM-index seeding
   (~30%) and PE sort/mate-rescue (~22%) are the real hotspots. An FPGA SMEM/seed
   engine or a combined SW engine (banded + mate-rescue, ~17%) would have larger
   payoff than banded SWA alone.
4. **Reframe the project goal** — if the aim is a learning exercise / a kernel that
   matters in a *different* pipeline (e.g. original bwa-mem, long reads, or a less
   SIMD-capable host), the banded SWA accelerator is still valid; just scope the
   expected end-to-end speedup honestly.

A full 2-hour / ~208M-pair run (for a complete golden SAM and longer stress) is
ready to launch but was **not** run automatically — it adds no new hotspot
information.

---

## Appendix — key decisions & rationale

| Decision                         | Why                                                        |
|----------------------------------|------------------------------------------------------------|
| SSH keys over password           | Enables unattended background transfers/builds             |
| chr1–5, not full genome          | Full genome can't index in 32 GB (~87 GB build RAM)        |
| chr1–5, not a tiny genome        | Big enough to map human reads + stress RAM (~25 GB peak)   |
| Reads = full ERR174310 (~30×)    | Heavy realistic SWA workload; reads (not ref) drive runtime |
| Plain `make`, no `CXXFLAGS`      | Default flags already include `-g -O3` + SIMD arch flags   |
| `/usr/bin/time -v` everywhere    | Captures wall-clock *and* peak RAM in one shot             |
| Calibrate before full run        | Linear scaling lets a 50M-pair run size the 2-hour budget  |
| `perf record -g`                 | Confirms `bandedSWA.cpp` is the hotspot before RTL work     |
