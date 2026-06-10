#!/bin/bash
# Profile bwa-mem2 alignment on a 10M-pair subset to locate the hotspot.
set -uo pipefail
LOG=/home/ccloud/perf_run.log
exec > "$LOG" 2>&1

echo "=== PERF RUN START ==="
date

# Allow perf full access (VM-safe). Passwordless sudo.
sudo sysctl -w kernel.perf_event_paranoid=-1
sudo sysctl -w kernel.kptr_restrict=0

BIN="/home/ccloud/BWA-MEM2 repo/bwa-mem2/bwa-mem2"
REF=/home/ccloud/ref/hg38_chr1-5.fa
cd /home/ccloud/reads || { echo "FATAL: reads dir missing"; exit 1; }

# Reuse the 50M calibration subset; take first 10M pairs (40M lines).
head -n 40000000 sub_1.fq > sub10_1.fq
head -n 40000000 sub_2.fq > sub10_2.fq
echo "--- subset line counts (expect 40000000 each) ---"
wc -l sub10_1.fq sub10_2.fq

echo
echo "=== perf record: cpu-clock software event (VM-safe), 99 Hz, call graphs ==="
perf record -e cpu-clock -F 99 -g -o /home/ccloud/perf.data -- \
  "$BIN" mem -t 16 "$REF" sub10_1.fq sub10_2.fq > /home/ccloud/out_10M.sam
echo "perf record exit code: $?"
ls -lh /home/ccloud/perf.data /home/ccloud/out_10M.sam

echo
echo "=== FLAT PROFILE: top symbols by self time (>=0.5%) ==="
perf report -i /home/ccloud/perf.data --stdio --no-children --percent-limit 0.5 2>/dev/null \
  | grep -v '^#' | head -40

echo
echo "=== PERF RUN DONE ==="
date
