#!/bin/bash
# ~2-hour phase-timing run: align 200M pairs to chr1-5, capture per-section timing
# via perf (flat) + /usr/bin/time -v + bwa-mem2's own end-of-run timers.
set -uo pipefail
LOG=/home/ccloud/test2hr.log
exec > "$LOG" 2>&1

echo "=== 2-HOUR PHASE-TIMING TEST START ==="
date
echo "--- memory/disk before ---"
free -h
df -h /home | tail -1

BIN="/home/ccloud/BWA-MEM2 repo/bwa-mem2/bwa-mem2"
REF=/home/ccloud/ref/hg38_chr1-5.fa
cd /home/ccloud/reads || { echo "FATAL: reads dir missing"; exit 1; }

PAIRS=200000000
LINES=$((PAIRS * 4))
echo
echo "=== building ${PAIRS}-pair subset (${LINES} lines/mate, plain fastq) ==="
date
zcat ERR174310_1.fastq.gz | head -n "$LINES" > big_1.fq &
zcat ERR174310_2.fastq.gz | head -n "$LINES" > big_2.fq &
wait
echo "--- subset line counts (expect ${LINES} each) ---"
wc -l big_1.fq big_2.fq
du -h big_1.fq big_2.fq
date

sudo sysctl -w kernel.perf_event_paranoid=-1 >/dev/null

echo
echo "=== ALIGN: ${PAIRS} pairs, -t 16, under perf(flat)+time -v (SAM discarded) ==="
date
# perf wraps time wraps bwa-mem2 so time -v reports bwa-mem2's own peak RAM,
# while perf samples the whole tree (bwa-mem2 dominates).
perf record -e cpu-clock -F 99 -o /home/ccloud/perf_2hr.data -- \
  /usr/bin/time -v "$BIN" mem -t 16 "$REF" big_1.fq big_2.fq > /dev/null
echo "pipeline exit code: $?"
date

echo
echo "=== FLAT PROFILE at scale: top 35 self-time symbols (>=0.3%) ==="
perf report -i /home/ccloud/perf_2hr.data --stdio --no-children -g none --percent-limit 0.3 2>/dev/null \
  | grep -v '^#' | head -35

echo
echo "=== reclaiming disk (removing 200M-pair subset) ==="
rm -f big_1.fq big_2.fq
df -h /home | tail -1

echo
echo "=== 2-HOUR PHASE-TIMING TEST DONE ==="
date
