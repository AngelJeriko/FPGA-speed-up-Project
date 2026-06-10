#!/bin/bash
# Build a 50M read-pair subset and run a timed calibration alignment.
set -uo pipefail
LOG=/home/ccloud/cal.log
exec > "$LOG" 2>&1

echo "=== CALIBRATION START ==="
date
BIN="/home/ccloud/BWA-MEM2 repo/bwa-mem2/bwa-mem2"
REF=/home/ccloud/ref/hg38_chr1-5.fa
cd /home/ccloud/reads || { echo "FATAL: reads dir missing"; exit 1; }

N=50000000          # read pairs
L=$((N * 4))        # FASTQ lines per mate
echo "building ${N}-pair subset (${L} lines per mate, uncompressed)"
zcat ERR174310_1.fastq.gz | head -n "$L" > sub_1.fq &
zcat ERR174310_2.fastq.gz | head -n "$L" > sub_2.fq &
wait

echo "--- subset line counts (expect ${L} each) ---"
wc -l sub_1.fq sub_2.fq
ls -lh sub_1.fq sub_2.fq

echo
echo "=== ALIGN: 50M pairs, -t 16, SAM discarded (timing only) ==="
/usr/bin/time -v "$BIN" mem -t 16 "$REF" sub_1.fq sub_2.fq > /dev/null
echo "align exit code: $?"

echo "=== CALIBRATION DONE ==="
date
