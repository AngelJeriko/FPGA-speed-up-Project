# The E. coli test set, line by line

A walkthrough of the two scripts that build and use the E. coli golden dataset:
what each step does, why it is there, and which guards exist because something
once went wrong.

- `scripts/make_ecoli_dataset.sh` — builds the reference, reads and index
- `scripts/capture_swa_ecoli.sh` — captures and verifies the golden vectors

Both are deterministic: run them twice and you get byte-identical output.

---

## Part 1 — building the dataset

### Why E. coli and not the human genome (lines 5–15)

Two deliberate choices, documented in the script's own header.

**The genome is tiny.** E. coli K-12 is 4.64 **million** bases against hg38's
3.1 **billion**. The index builds in about 2 seconds instead of hours, and the
whole dataset regenerates in well under a minute. We do not need a big genome —
we need a realistic *stream of seed extensions*, and bacteria produce those
perfectly well. The point of the milestone was vectors a reviewer can reproduce,
and a 40-second setup is reproducible in a way an overnight index build is not.

**Reads are 150 bp.** Not arbitrary: `rtl/bsw_pkg.sv` sets `MAX_QLEN = 160` from
measured maxima over 747,258 real `ksw_extend2` calls on 150 bp short reads.
Simulating longer reads would produce extensions *outside* the envelope the
hardware is proven for, and the vectors would not be usable as a golden set
without re-deriving the bit widths.

```bash
23  PAIRS=5000
24  READLEN=150
25  SEED=42
```

The fixed seed is what makes the FASTQs reproducible byte-for-byte.

### Step 1 — fetch the reference, and check it (lines 50–60)

```bash
53    curl -sSL -o "$REF_DIR/$REF_FA.gz" "$REF_URL"
54    gunzip -kf "$REF_DIR/$REF_FA.gz"
56  BASES=$(grep -v '^>' "$REF_DIR/$REF_FA" | tr -d '\n' | wc -c)
57  [[ "$BASES" -eq "$EXPECT_BASES" ]] || {
58    echo "ERROR: reference is $BASES bases, expected $EXPECT_BASES - truncated download?" >&2
59    exit 1; }
```

Downloads NCBI assembly ASM584v2 (E. coli K-12 substr. MG1655, the reference
strain), then **counts the bases and requires exactly 4,641,652**.

The pipeline on line 56 reads: drop FASTA header lines (`grep -v '^>'`), strip
newlines (`tr -d '\n'`), count what remains (`wc -c`).

That guard is the most important line in the script. A truncated or
partially-written download would otherwise sail straight through and produce a
*wrong golden set* — you would then be verifying hardware against garbage and
have no way to tell. `EXPECT_BASES` is the published length of `NC_000913.3`.

### Step 2 — build the read simulator (lines 62–70)

```bash
67    curl -sSL -o "$TOOL_DIR/wgsim.c" .../wgsim.c
68    curl -sSL -o "$TOOL_DIR/kseq.h"  .../kseq.h
69    ( cd "$TOOL_DIR" && gcc -g -O2 -Wall -o wgsim wgsim.c -lz -lm )
```

`wgsim` is the canonical read simulator, by the same author as bwa. It is not
packaged on this box, so it is built from source — one C file plus one header.

The `kseq.h` fetch on line 68 exists because the first attempt failed: `wgsim.c`
includes it but it is a separate file in that repository.

### Step 3 — simulate the reads (lines 72–79)

```bash
77  "$TOOL_DIR/wgsim" -N "$PAIRS" -1 "$READLEN" -2 "$READLEN" -d 500 -s 50 -S "$SEED" \
78    "$REF_DIR/$REF_FA" "$READ_DIR/ecoli_R1.fq" "$READ_DIR/ecoli_R2.fq" \
79    > "$READ_DIR/wgsim_mutations.txt" 2> "$READ_DIR/wgsim.log"
```

| Flag | Meaning |
| --- | --- |
| `-N 5000` | 5,000 read **pairs** |
| `-1 150 -2 150` | 150 bp from each end of the fragment |
| `-d 500 -s 50` | fragment length mean 500, standard deviation 50 |
| `-S 42` | fixed seed |
| (defaults) | error rate 2% (`-e`), mutation rate 0.1% (`-r`) |

The error and mutation rates are left at their defaults deliberately, so the
read profile stays the canonical wgsim one rather than something tuned.

`wgsim` encodes each read's **true origin in its name**, and writes the SNPs and
indels it injected to `wgsim_mutations.txt` (stdout). The capture does not need
that ground truth, but it makes mis-mapping trivial to spot by eye.

### Step 4 — build the index (lines 81–85)

```bash
84    "$BWA" index "$REF_DIR/$REF_FA"
```

bwa-mem2 needs a searchable form of the genome (an FM-index) before it can align
anything. About 2 seconds for 4.6 Mbp. Guarded by an `if` on the output file, so
re-running the script does not rebuild it.

### Step 5 — smoke test (lines 87–94)

```bash
89  "$BWA" mem -t 4 ... > "$READ_DIR/ecoli.sam"
91  awk '!/^@/{n++; if(and($2,4)==0) m++} END{
92         printf "    SAM records : %d\n    mapped      : %d (%.2f%%)\n", n, m, 100*m/n;
93         if (m < 0.95*n) { print "    WARNING: mapped rate below 95% - check the index"; }
94       }' "$READ_DIR/ecoli.sam"
```

Aligns the reads it just made and reports the mapped rate. `$2` is the SAM FLAG
field and bit 4 means "unmapped", so `and($2,4)==0` counts mapped reads.
`!/^@/` skips header lines.

The 95% threshold is a sanity floor: if simulated reads do not map back to the
genome they were simulated *from*, something upstream is broken — wrong
reference, bad index, mismatched files. Far better to learn that here than three
steps later while staring at capture output.

Actual result on this dataset: **100% mapped**.

### What you end up with

```
~/ref_ecoli/ecoli_K12_MG1655.fna        + .0123 .amb .ann .bwt.2bit.64 .pac
~/reads_ecoli/ecoli_R{1,2}.fq           5,000 pairs x 150 bp
~/reads_ecoli/wgsim_mutations.txt       the injected variants (ground truth)
~/reads_ecoli/ecoli.sam                 smoke-test alignment
```

---

## Part 2 — capturing the golden vectors

`scripts/capture_swa_ecoli.sh`. Four steps, plus a restore path.

### Argument handling (lines 14–21)

```bash
14  RESTORE=0
15  if [ "${1:-}" = "--restore" ]; then RESTORE=1; shift; fi
16
17  BWA=${1:-"$HOME/BWA-MEM2 repo/bwa-mem2"}
18  OUT=${2:-"$HOME/cap_swa"}
```

The `shift` on line 15 is a bug fix. Originally `--restore` was parsed *after*
`BWA=${1:-...}`, so the flag was consumed as the directory argument and the
script tried to `cd` into a directory literally named `--`. Flags have to be
parsed and removed before positional defaults are taken.

### Step 1 — patch bwa-mem2 (line 34)

```bash
34  "$REPO/host/bwamem2_patch/apply_swa_capture.sh" "$BWA"
```

Inserts the recording hook into bwa-mem2's source. **Where** is the part that
matters, and it is the thing that nearly went wrong:

The function every published description of bwa-mem2 points at — `ksw_extend` —
is **dead code**. Nothing in the program calls it. The real work happens in
Intel's SIMD-batched `BandedPairWiseSW`, operating on arrays of `SeqPair`.

So the hook goes at **six** sites in `mem_chain2aln`: left and right extension,
each split three ways by sequence length (a scalar batch, a 16-bit SIMD batch,
an 8-bit SIMD batch). They are anchored on structural landmarks — the
`tprof[PE*][0] += nump;` accounting lines — rather than line numbers, so the
patch survives source edits. The script is idempotent.

Hooking the obvious function would have produced an empty file and a confusing
afternoon. See `docs/swa_golden_capture.md`.

### Step 2 — build (line 37)

```bash
37  make -C "$BWA" -j"$(nproc)" >/dev/null
```

### Step 3 — capture (lines 39–43)

```bash
41  BSW_CAPTURE_OUT="$OUT/ecoli_swa.bin" "$BWA/bwa-mem2" mem -t 1 "$REF" "$R1" "$R2" \
42      > "$OUT/ecoli_capture.sam" 2> "$OUT/capture.log"
```

Two details worth understanding:

**`BSW_CAPTURE_OUT`** — the hook is dormant unless this environment variable is
set. No variable, no file, no behavioural change. That is what lets us claim the
instrumentation is non-invasive and then *prove* it: the SAM from the
instrumented run is **byte-identical** to a stock run.

**`-t 1`** — single-threaded. The hook is mutex-guarded so it is thread-safe
either way, but one thread makes the record *order* deterministic, so the
capture file is reproducible rather than merely correct.

Each record holds one extension's complete inputs — query, target, `h0`, band
width, scoring parameters — and bwa-mem2's own six outputs (`score`, `qle`,
`tle`, `gtle`, `gscore`, `max_off`). Format is documented at the top of
`host/bwamem2_patch/swa_capture.inc`.

### Step 4 — verify (lines 45–47)

```bash
47  "$REPO/host/swa_hls/replay_swa" "$OUT/ecoli_swa.bin"
```

Replays every record through the C model and diffs all six outputs. This is
where **49,468 / 49,468 bit-exact** comes from.

### Restoring the checkout (lines 23–26)

```bash
23  if [ "$RESTORE" = 1 ]; then
24      cd "$BWA"; git checkout -- src/bwamem.cpp; rm -f src/swa_capture.inc
```

Always run this when finished. Leaving bwa-mem2 patched means the next person to
build it gets instrumented binaries without knowing.

```sh
./scripts/capture_swa_ecoli.sh --restore
```

---

## Part 3 — how the human-genome runs differed

The human captures used the same hook, the same verifier and the same four
steps. Three things changed:

| | E. coli | Human |
| --- | --- | --- |
| Reference | 4.64 Mbp, built by the script | hg38 chr1–5, 1.06 Gbp, already indexed on this box |
| Reads | 5,000 simulated pairs, 150 bp | 200,000 **real** ERR174310 pairs (101 bp), plus 60,000 simulated at 150 bp |
| Records | 49,468 | 15,437,657 + 2,718,372 |

For the simulated human set the canonical rates were deliberately abandoned:

```sh
wgsim -N 60000 -1 150 -2 150 -r 0.01 -R 0.3 -X 0.5 -S 42 ...
```

`-r 0.01` raises the mutation rate 10x, `-R 0.3` doubles the indel fraction and
`-X 0.5` lengthens indels. That was the whole point: **more indels mean wider
reference windows**, which is what pushed `tlen` from E. coli's 437 to 997 — 27
bases from the hardware's 1,024 limit — and exposed a missing bounds check that
would have returned confident wrong answers on silicon.

The real reads are 101 bp and therefore cannot stress `qlen` at all; the
simulated 150 bp set exists to cover that.

The human runs are **not** scripted the way E. coli is, because they depend on
datasets that live on this machine rather than at a URL anyone can fetch. Their
regeneration commands are recorded in `docs/swa_golden_capture.md` instead.

---

## Reproducing the whole thing

```sh
./scripts/make_ecoli_dataset.sh       # ~40 s cold, mostly the download
./scripts/capture_swa_ecoli.sh        # patch, build, align, verify
./scripts/capture_swa_ecoli.sh --restore
```

Options: `--pairs N`, `--outdir-ref DIR`, `--outdir-reads DIR` on the first;
`BWA_DIR` and `OUT_DIR` positionally, or `REF`/`R1`/`R2` by environment, on the
second.

Related: `docs/swa_golden_capture.md` (what the capture found),
`docs/rtl_verification.md` (how these vectors reach the RTL),
`docs/reproducing.md` (the from-scratch index for the whole project).
