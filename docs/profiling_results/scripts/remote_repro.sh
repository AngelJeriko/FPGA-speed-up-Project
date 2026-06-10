#!/bin/bash
# Reproducibility test: run the same 10M-pair alignment under perf N times and
# print the top self-time symbols each iteration, to confirm the hotspots are stable.
set -uo pipefail
LOG=/home/ccloud/repro.log
exec > "$LOG" 2>&1

echo "=== REPRODUCIBILITY TEST START ==="
date
BIN="/home/ccloud/BWA-MEM2 repo/bwa-mem2/bwa-mem2"
REF=/home/ccloud/ref/hg38_chr1-5.fa
cd /home/ccloud/reads || { echo "FATAL: reads dir missing"; exit 1; }

# Ensure the 10M-pair subset exists (reuse from earlier perf run if present)
if [ ! -s sub10_1.fq ] || [ ! -s sub10_2.fq ]; then
  echo "rebuilding 10M subset"
  head -n 40000000 sub_1.fq > sub10_1.fq
  head -n 40000000 sub_2.fq > sub10_2.fq
fi

sudo sysctl -w kernel.perf_event_paranoid=-1 >/dev/null

for i in 1 2 3; do
  echo
  echo "########## ITERATION $i ##########"
  date
  perf record -e cpu-clock -F 99 -g -o /home/ccloud/perf_$i.data -- \
    "$BIN" mem -t 16 "$REF" sub10_1.fq sub10_2.fq > /dev/null 2> /home/ccloud/aln_$i.log
  echo "--- iter $i: top 15 symbols by SELF time (>=0.5%) ---"
  perf report -i /home/ccloud/perf_$i.data --stdio --no-children -g none --percent-limit 0.5 2>/dev/null \
    | grep -v '^#' | head -15
done

echo
echo "=== REPRODUCIBILITY TEST DONE ==="
date
