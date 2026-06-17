#!/usr/bin/env bash
# Rebuild the dispatched arch variant with the ext-capture instrumentation,
# then run a small bwa-mem2 alignment with ALNREG_EXT_OUT set to capture
# mem_chain2aln golden vectors. Stops on build error.
set -euo pipefail
REPO=/home/ccloud/bwa2          # symlink -> "BWA-MEM2 repo/bwa-mem2"
REF=/home/ccloud/ref/hg38_chr1-5.fa
RD=/home/ccloud/reads_diverse
OUT=/home/ccloud/ext_capture
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

# --- rebuild just that variant ---
cd "$REPO"
echo "=== building (this recompiles objects for $ARCH) ==="
make arch=$ARCH EXE=$EXE all 2>&1 | tail -8
echo "=== build OK: $(ls -l $REPO/$EXE | awk '{print $5, $NF}') ==="

# --- make a small capture input (50k read pairs) ---
# (zcat gets SIGPIPE when head closes early -> disable pipefail for this step)
C1="$OUT/cap_1.fq"; C2="$OUT/cap_2.fq"
set +o pipefail
zcat "$RD/HG00733_PuertoRican_ERR3988823_1.50Mpairs.fq.gz" | head -n 200000 > "$C1"
zcat "$RD/HG00733_PuertoRican_ERR3988823_2.50Mpairs.fq.gz" | head -n 200000 > "$C2"
set -o pipefail
echo "=== capture input: $(wc -l < $C1) / $(wc -l < $C2) lines (=50k pairs) ==="

# --- run capture (dispatcher execs the rebuilt $EXE) ---
BIN="$REPO/bwa-mem2"
echo "=== running capture ==="
ALNREG_EXT_OUT="$OUT/ext_vec.bin" ALNREG_EXT_MAX=30000 \
  "$BIN" mem -t 16 "$REF" "$C1" "$C2" > /dev/null 2> "$OUT/cap.log"
echo "=== capture done ==="
ls -l "$OUT/ext_vec.bin"
echo "--- last 3 log lines ---"; tail -3 "$OUT/cap.log"
