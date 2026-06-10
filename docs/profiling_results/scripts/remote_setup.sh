#!/bin/bash
# Build bwa-mem2, download hg38 chr1-5 reference, and index it.
set -uo pipefail
LOG=/home/ccloud/setup.log
exec > "$LOG" 2>&1

echo "=== START build+index ==="
date
echo "host: $(hostname)  cores: $(nproc)  mem:"
free -h

REPO="/home/ccloud/BWA-MEM2 repo/bwa-mem2"
cd "$REPO" || { echo "FATAL: repo not found at $REPO"; exit 1; }

echo
echo "=== [1/4] building bwa-mem2 (plain make: -g -O3 multi-arch) ==="
make 2>&1 | tail -50
echo "make exit code: ${PIPESTATUS[0]}"
echo "--- resulting binaries ---"
ls -l bwa-mem2 bwa-mem2.sse41 bwa-mem2.sse42 bwa-mem2.avx bwa-mem2.avx2 bwa-mem2.avx512bw 2>/dev/null
if [ ! -x "$REPO/bwa-mem2" ]; then
  echo "FATAL: bwa-mem2 dispatcher not built; stopping before reference steps."
  exit 1
fi

echo
echo "=== [2/4] downloading reference hg38 chr1-5 ==="
mkdir -p /home/ccloud/ref
cd /home/ccloud/ref
for c in chr1 chr2 chr3 chr4 chr5; do
  echo "fetching $c.fa.gz"
  wget -c -q "https://hgdownload.soe.ucsc.edu/goldenPath/hg38/chromosomes/$c.fa.gz" || echo "WARN: wget $c failed"
done
ls -lh chr*.fa.gz

echo
echo "=== [3/4] concatenating into hg38_chr1-5.fa ==="
zcat chr1.fa.gz chr2.fa.gz chr3.fa.gz chr4.fa.gz chr5.fa.gz > hg38_chr1-5.fa
ls -lh hg38_chr1-5.fa

echo
echo "=== [4/4] indexing (watch peak RAM; chr1-5 ~ 25GB est on 32GB box) ==="
/usr/bin/time -v "$REPO/bwa-mem2" index hg38_chr1-5.fa
echo "index exit code: $?"
echo "--- index files ---"
ls -lh /home/ccloud/ref/

echo
echo "=== DONE ==="
date
