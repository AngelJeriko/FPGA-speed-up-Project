#!/usr/bin/env bash
# remote_batched_capture.sh — ONE batched remote session for the two outstanding
# capture validations (mate-rescue + chaining). Back-half timing is already DONE
# (commit 0b2f56b), so this script does NOT re-profile.
#
# Prereqs on the remote (ccloud@216.227.218.169, run via WSL ssh):
#   1. Paste host/mate_rescue/capture/matesw_capture.inc into src/bwamem_pair.cpp  (kernel)
#   2. Paste host/mate_rescue/capture/orch_capture.inc   into src/bwamem_pair.cpp  (orchestration)
#   3. Paste host/chaining/capture/chain_capture.inc     into src/bwamem.cpp       (chaining)
#   (keep src/bwamem.cpp.orig and a fresh src/bwamem_pair.cpp.orig backup first!)
#
# After this script: scp the two .bin back, gzip, run the host validators, then
# REVERT BOTH source files and rebuild a clean binary. See docs/remote_capture_plan.md.
set -euo pipefail
REPO=/home/ccloud/bwa2          # symlink -> "BWA-MEM2 repo/bwa-mem2"
REF=/home/ccloud/ref/hg38_chr1-5.fa
RD=/home/ccloud/reads_diverse
OUT=/home/ccloud/cap_batched
mkdir -p "$OUT"

# --- pick highest SIMD the CPU supports, map to bwa-mem2 arch + EXE name ---
flags=$(grep -m1 '^flags' /proc/cpuinfo)
if   echo "$flags" | grep -qw avx512bw; then ARCH=avx512; EXE=bwa-mem2.avx512bw
elif echo "$flags" | grep -qw avx2;     then ARCH=avx2;   EXE=bwa-mem2.avx2
elif echo "$flags" | grep -qw avx;      then ARCH=avx;    EXE=bwa-mem2.avx
elif echo "$flags" | grep -qw sse4_2;   then ARCH=sse42;  EXE=bwa-mem2.sse42
else                                          ARCH=sse41;  EXE=bwa-mem2.sse41
fi
echo "=== arch=$ARCH  exe=$EXE ==="

# --- rebuild just that variant (picks up BOTH instrumented files) ---
cd "$REPO"
echo "=== building $ARCH (recompiles bwamem.cpp + bwamem_pair.cpp) ==="
make arch=$ARCH EXE=$EXE all 2>&1 | tail -8
echo "=== build OK: $(ls -l $REPO/$EXE | awk '{print $5, $NF}') ==="

# --- small capture input (50k read pairs), same source as the ext capture ---
C1="$OUT/cap_1.fq"; C2="$OUT/cap_2.fq"
set +o pipefail
zcat "$RD/HG00733_PuertoRican_ERR3988823_1.50Mpairs.fq.gz" | head -n 200000 > "$C1"
zcat "$RD/HG00733_PuertoRican_ERR3988823_2.50Mpairs.fq.gz" | head -n 200000 > "$C2"
set -o pipefail
echo "=== capture input: $(wc -l < $C1)/$(wc -l < $C2) lines (=50k pairs) ==="

BIN="$REPO/bwa-mem2"

# --- single paired-end run with BOTH captures armed ---
#   chaining capture fires in mem_chain / mem_chain_flt (always reached);
#   mate-rescue capture fires in mem_sam_pe_batch (PE rescue path) — needs -p/PE.
echo "=== running batched capture (mate-rescue kernel + orchestration + selection + chaining) ==="
ALNREG_MATE_OUT="$OUT/mate_vec.bin"   ALNREG_MATE_MAX=200000 \
ALNREG_ORCH_OUT="$OUT/orch_vec.bin"   ALNREG_ORCH_MAX=100000 \
ALNREG_SEL_OUT="$OUT/sel_vec.bin"     ALNREG_SEL_MAX=200000 \
ALNREG_CHAIN_OUT="$OUT/chain_vec.bin" ALNREG_CHAIN_MAX=30000 \
  "$BIN" mem -t 16 "$REF" "$C1" "$C2" > /dev/null 2> "$OUT/cap.log"

echo "=== capture done ==="
ls -l "$OUT/mate_vec.bin" "$OUT/orch_vec.bin" "$OUT/sel_vec.bin" "$OUT/chain_vec.bin"
echo "--- last 3 log lines ---"; tail -3 "$OUT/cap.log"
echo
echo "NEXT (local): scp all four .bin back, then:"
echo "  host/mate_rescue:  make checkcap  && ./check_capture <mate_vec.bin>   # kswv == hw.h"
echo "  host/mate_rescue:  make checkorch && ./check_orch    <orch_vec.bin>   # orch.h bit-exact"
echo "  host/mate_rescue:  make checksel  && ./check_sel     <sel_vec.bin>    # pe.h selection"
echo "  host/chaining:     make checkcap  && ./check_capture <chain_vec.bin>  # chain.h bit-exact"
echo "THEN revert: cp src/bwamem.cpp.orig src/bwamem.cpp;"
echo "             cp src/bwamem_pair.cpp.orig src/bwamem_pair.cpp; make ... all"
