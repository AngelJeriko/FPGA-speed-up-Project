#!/usr/bin/env bash
# Align each diverse subset (and a comparable European baseline) with bwa-mem2 vs
# GRCh38 chr1-5, then compute the Exact-Match Filter (EMF) fire-rate per sample:
#   fire = reads that are exact + unique + full-length + properly paired
#        = primary, mapped, MAPQ==60, CIGAR == /^[0-9]+M$/, NM:i:0, proper-pair flag.
# This is the % of reads the EMF could emit directly and bypass seeding/extension.
# SAM is streamed through awk and never stored (50M-pair SAMs are huge).
set -u

BIN="/home/ccloud/BWA-MEM2 repo/bwa-mem2/bwa-mem2"
REF=/home/ccloud/ref/hg38_chr1-5.fa
THREADS=16
READS=/home/ccloud/reads_diverse
BASE=/home/ccloud/reads                 # full ERR174310 (NA12878, European) lives here
OUT=/home/ccloud/firerate_results
mkdir -p "$OUT"
LOG="$OUT/align_firerate.log"
exec > "$LOG" 2>&1
SUMMARY="$OUT/firerate_summary.tsv"

echo "=== align + fire-rate started: $(date) ==="
echo "BIN=$BIN"
echo "REF=$REF  THREADS=$THREADS"
if [ ! -e "${REF}.bwt.2bit.64" ]; then echo "!! bwa-mem2 index for $REF not found -- aborting"; exit 1; fi

# --- comparable European baseline subset (NA12878 / ERR174310, first 50M pairs) ---
EUR1="$READS/NA12878_European_ERR174310_1.50Mpairs.fq.gz"
EUR2="$READS/NA12878_European_ERR174310_2.50Mpairs.fq.gz"
if [ ! -s "$EUR1" ] && [ -s "$BASE/ERR174310_1.fastq.gz" ]; then
  echo "--- building European baseline subset (50M pairs from ERR174310) $(date) ---"
  zcat "$BASE/ERR174310_1.fastq.gz" | head -n 200000000 | gzip > "$EUR1"
  zcat "$BASE/ERR174310_2.fastq.gz" | head -n 200000000 | gzip > "$EUR2"
  echo "  baseline subset built $(date)"
fi

printf "sample\ttotal_primary\tmapped\tfire\tfire_pct_of_mapped\tfire_pct_of_total\tmapped_pct\n" > "$SUMMARY"

# mawk-safe fire-rate counter (integer bit math; no and()/gawk builtins).
read -r -d '' AWKPROG <<'AWK'
BEGIN{ tot=0; map=0; fire=0 }
/^@/ { next }
{
  flag=$2
  secondary=int(flag/256)%2
  supplementary=int(flag/2048)%2
  if (secondary==1 || supplementary==1) next      # primary alignments only (count each read once)
  tot++
  unmapped=int(flag/4)%2
  if (unmapped==1) next
  map++
  properpair=int(flag/2)%2
  mapq=$5
  cigar=$6
  fullM=(cigar ~ /^[0-9]+M$/)                      # single M op spanning whole read: no clips/indels
  nm=-1
  for(i=12;i<=NF;i++){ if($i ~ /^NM:i:/){ s=$i; sub(/^NM:i:/,"",s); nm=s } }
  if (mapq==60 && fullM && nm==0 && properpair==1) fire++
}
END{
  mp = (tot>0)? 100*map/tot : 0
  fm = (map>0)? 100*fire/map : 0
  ft = (tot>0)? 100*fire/tot : 0
  printf "%d\t%d\t%d\t%.2f\t%.2f\t%.2f\n", tot, map, fire, fm, ft, mp
}
AWK

align_one(){
  r1="$1"
  r2="${r1/_1.50Mpairs/_2.50Mpairs}"
  base=$(basename "$r1"); label="${base%_1.50Mpairs.fq.gz}"
  if [ ! -s "$r2" ]; then echo "!! missing mate for $r1 -- skipping"; return 1; fi
  echo ""
  echo "--- aligning $label  $(date) ---"
  echo "  R1=$r1"
  echo "  R2=$r2"
  stats=$("$BIN" mem -t "$THREADS" "$REF" "$r1" "$r2" 2>>"$OUT/bwa_stderr_${label}.log" | awk "$AWKPROG")
  echo "  result (tot mapped fire fire%map fire%tot map%): $stats"
  printf "%s\t%s\n" "$label" "$stats" >> "$SUMMARY"
}

for r1 in "$READS"/*_1.50Mpairs.fq.gz; do
  [ -e "$r1" ] || { echo "no subsets found in $READS"; break; }
  align_one "$r1"
done

echo ""
echo "=== align + fire-rate complete: $(date) ==="
echo "SUMMARY (fire = exact+unique+full-length+proper-pair reads):"
column -t -s $'\t' "$SUMMARY" 2>/dev/null || cat "$SUMMARY"
