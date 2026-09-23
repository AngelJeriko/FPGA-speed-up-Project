#!/usr/bin/env bash
#
# make_ecoli_dataset.sh - build the small E. coli test set used for the HLS milestone.
#
# WHY E. COLI AND NOT hg38: the ksw_extend capture only needs a realistic stream of seed
# extensions, not a big genome. E. coli K-12 is 4.64 Mbp against hg38's 3.1 Gbp, so the
# index builds in ~2 s instead of hours and the whole dataset regenerates from scratch in
# well under a minute. That makes the golden vectors something a reviewer can reproduce,
# which is the point of the milestone.
#
# WHY 150 bp READS: it matches the hardware envelope the BSW core is sized for. bsw_pkg
# sets MAX_QLEN=160 from measured maxima over 747,258 real ksw_extend2 calls on 150 bp
# short reads (see docs/bit_width_proof.md). Simulating longer reads would produce
# extensions outside the envelope the kernel is proven for, and the vectors would not be
# usable as a golden set without re-deriving the widths.
#
# Deterministic: wgsim runs with a fixed seed, so two runs give byte-identical FASTQs.
#
# Usage: scripts/make_ecoli_dataset.sh [--pairs N] [--outdir-ref DIR] [--outdir-reads DIR]

set -euo pipefail

PAIRS=5000
READLEN=150
SEED=42
REF_DIR="${HOME}/ref_ecoli"
READ_DIR="${HOME}/reads_ecoli"
TOOL_DIR="${HOME}/tools"
BWA="${BWA:-${HOME}/BWA-MEM2 repo/bwa-mem2/bwa-mem2}"

# NCBI RefSeq assembly ASM584v2 = E. coli K-12 substr. MG1655, the reference strain.
REF_URL="https://ftp.ncbi.nlm.nih.gov/genomes/all/GCF/000/005/845/GCF_000005845.2_ASM584v2/GCF_000005845.2_ASM584v2_genomic.fna.gz"
REF_FA="ecoli_K12_MG1655.fna"
EXPECT_BASES=4641652     # known length of NC_000913.3; guards against a truncated download

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pairs)        PAIRS="$2"; shift 2;;
    --outdir-ref)   REF_DIR="$2"; shift 2;;
    --outdir-reads) READ_DIR="$2"; shift 2;;
    -h|--help)      sed -n '2,20p' "$0"; exit 0;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done

say(){ printf '\033[1;36m==>\033[0m %s\n' "$*"; }

mkdir -p "$REF_DIR" "$READ_DIR" "$TOOL_DIR"

# ---- 1. reference ------------------------------------------------------------
if [[ ! -f "$REF_DIR/$REF_FA" ]]; then
  say "Fetching E. coli K-12 MG1655 reference"
  curl -sSL -o "$REF_DIR/$REF_FA.gz" "$REF_URL"
  gunzip -kf "$REF_DIR/$REF_FA.gz"
fi
BASES=$(grep -v '^>' "$REF_DIR/$REF_FA" | tr -d '\n' | wc -c)
[[ "$BASES" -eq "$EXPECT_BASES" ]] || {
  echo "ERROR: reference is $BASES bases, expected $EXPECT_BASES - truncated download?" >&2
  exit 1; }
say "Reference OK: $BASES bases"

# ---- 2. read simulator -------------------------------------------------------
# wgsim is the canonical simulator (same author as bwa). Built from source because it is
# not packaged here; it is one C file plus kseq.h.
if [[ ! -x "$TOOL_DIR/wgsim" ]]; then
  say "Building wgsim from source"
  curl -sSL -o "$TOOL_DIR/wgsim.c" https://raw.githubusercontent.com/lh3/wgsim/master/wgsim.c
  curl -sSL -o "$TOOL_DIR/kseq.h"  https://raw.githubusercontent.com/lh3/wgsim/master/kseq.h
  ( cd "$TOOL_DIR" && gcc -g -O2 -Wall -o wgsim wgsim.c -lz -lm )
fi

# ---- 3. simulate reads -------------------------------------------------------
# Defaults kept for error (-e 0.02) and mutation (-r 0.001) rates so the profile stays the
# canonical wgsim one. -S fixes the seed so the FASTQs are reproducible byte-for-byte.
# wgsim encodes each read's TRUE origin in its name, which makes mis-mapping easy to spot.
say "Simulating $PAIRS read pairs (${READLEN} bp, seed $SEED)"
"$TOOL_DIR/wgsim" -N "$PAIRS" -1 "$READLEN" -2 "$READLEN" -d 500 -s 50 -S "$SEED" \
  "$REF_DIR/$REF_FA" "$READ_DIR/ecoli_R1.fq" "$READ_DIR/ecoli_R2.fq" \
  > "$READ_DIR/wgsim_mutations.txt" 2> "$READ_DIR/wgsim.log"

# ---- 4. index ----------------------------------------------------------------
if [[ ! -f "$REF_DIR/$REF_FA.bwt.2bit.64" ]]; then
  say "Building bwa-mem2 index (~2 s for 4.6 Mbp)"
  "$BWA" index "$REF_DIR/$REF_FA" > "$REF_DIR/index.log" 2>&1
fi

# ---- 5. smoke test -----------------------------------------------------------
say "Smoke test: aligning the simulated reads"
"$BWA" mem -t 4 "$REF_DIR/$REF_FA" "$READ_DIR/ecoli_R1.fq" "$READ_DIR/ecoli_R2.fq" \
  > "$READ_DIR/ecoli.sam" 2> "$READ_DIR/bwamem2.log"
awk '!/^@/{n++; if(and($2,4)==0) m++} END{
       printf "    SAM records : %d\n    mapped      : %d (%.2f%%)\n", n, m, 100*m/n;
       if (m < 0.95*n) { print "    WARNING: mapped rate below 95% - check the index"; }
     }' "$READ_DIR/ecoli.sam"

say "Done."
echo "    reference : $REF_DIR/$REF_FA"
echo "    reads     : $READ_DIR/ecoli_R{1,2}.fq"
echo "    truth     : $READ_DIR/wgsim_mutations.txt  (wgsim's injected SNPs/indels)"
