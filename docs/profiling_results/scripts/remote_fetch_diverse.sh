#!/usr/bin/env bash
# Fetch 5 diverse human WGS samples, subsampled to the first 50M read pairs each,
# to test bwa-mem2 across ancestries / read lengths / platforms.
# Streams from ENA and stops early (head closes the pipe) so full files are never
# downloaded. URLs are resolved at runtime via the ENA filereport API.
# PARALLEL across samples + RESUMABLE: each mate is written to <out>.part then
# atomically renamed; an existing complete <out> is skipped on restart.
set -u

OUT=/home/ccloud/reads_diverse
mkdir -p "$OUT"
MAINLOG="$OUT/fetch_diverse.log"
exec > "$MAINLOG" 2>&1

PAIRS=50000000
LINES=$((PAIRS * 4))

echo "=== diverse fetch (parallel, resumable) started: $(date) ==="
df -h /home/ccloud
free=$(df -BG --output=avail /home/ccloud | tail -1 | tr -dc '0-9')
echo "free GB on /home/ccloud: ${free:-unknown}"
if [ "${free:-0}" -lt 40 ]; then
  echo "!! insufficient disk (<40 GB free) -- aborting before download"
  exit 1
fi

# label : ENA/SRA run accession   (ancestry / platform / approx read length)
SAMPLES="
HG002_Ashkenazi:SRR24123611
HG005_HanChinese:SRR24123546
HG005_HanChinese_2x250:SRR2831462
HG00733_PuertoRican:ERR3988823
NA19240_Yoruba:SRR2103644
"

fetch_one () {
  label="$1"; acc="$2"
  slog="$OUT/fetch_${label}_${acc}.log"
  {
    echo "[$label/$acc] resolving URLs $(date)"
    row=$(curl -s "https://www.ebi.ac.uk/ena/portal/api/filereport?accession=${acc}&result=read_run&fields=fastq_ftp&format=tsv" | awk 'NR==2')
    if [ -z "$row" ]; then echo "[$label/$acc] !! no filereport row -- skipping"; exit 1; fi
    u1=$(echo "$row" | tr '\t;' '\n' | grep '_1.fastq.gz' | head -1)
    u2=$(echo "$row" | tr '\t;' '\n' | grep '_2.fastq.gz' | head -1)
    if [ -z "$u1" ] || [ -z "$u2" ]; then echo "[$label/$acc] !! no paired _1/_2 ($row) -- skipping"; exit 1; fi
    echo "[$label/$acc] R1: $u1"
    echo "[$label/$acc] R2: $u2"
    i=1
    for u in "$u1" "$u2"; do
      out="$OUT/${label}_${acc}_${i}.50Mpairs.fq.gz"
      if [ -s "$out" ]; then echo "[$label/$acc] mate $i already complete -- skip"; i=$((i + 1)); continue; fi
      echo "[$label/$acc] downloading mate $i -> $out  $(date)"
      curl -s "https://${u}" | zcat 2>/dev/null | head -n "$LINES" | gzip > "$out.part"
      mv "$out.part" "$out"
      n=$(zcat "$out" | wc -l); n=$((n / 4))
      echo "[$label/$acc] mate $i done: $(ls -lh "$out" | awk '{print $5}') reads=$n  $(date)"
      i=$((i + 1))
    done
    echo "[$label/$acc] COMPLETE $(date)"
  } >> "$slog" 2>&1
}

pids=""
for entry in $SAMPLES; do
  label="${entry%%:*}"; acc="${entry##*:}"
  fetch_one "$label" "$acc" &
  pids="$pids $!"
  echo "launched $label ($acc) pid $! -> log $OUT/fetch_${label}_${acc}.log"
done

wait $pids
echo ""
echo "=== diverse fetch complete: $(date) ==="
ls -lh "$OUT"
