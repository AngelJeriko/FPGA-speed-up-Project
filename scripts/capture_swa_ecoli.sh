#!/usr/bin/env bash
# End-to-end: patch a bwa-mem2 checkout with the SWA capture hook, build it,
# align the E. coli read set, and verify every captured record replays
# bit-exact through the scalar reference model (host/extend_orchestrator/ksw.h).
#
#   ./scripts/capture_swa_ecoli.sh [BWA_DIR] [OUT_DIR]
#
# Leaves the bwa-mem2 checkout patched; run with --restore to revert it.
# Prereqs: scripts/make_ecoli_dataset.sh has been run (~/ref_ecoli, ~/reads_ecoli).
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
BWA=${1:-"$HOME/BWA-MEM2 repo/bwa-mem2"}
OUT=${2:-"$HOME/cap_swa"}
REF=${REF:-"$HOME/ref_ecoli/ecoli_K12_MG1655.fna"}
R1=${R1:-"$HOME/reads_ecoli/ecoli_R1.fq"}
R2=${R2:-"$HOME/reads_ecoli/ecoli_R2.fq"}

if [ "${1:-}" = "--restore" ]; then
    cd "$BWA"; git checkout -- src/bwamem.cpp; rm -f src/swa_capture.inc
    echo "restored: src/bwamem.cpp, removed src/swa_capture.inc"; exit 0
fi

for f in "$REF" "$R1" "$R2"; do
    [ -f "$f" ] || { echo "missing $f -- run scripts/make_ecoli_dataset.sh first" >&2; exit 1; }
done

mkdir -p "$OUT"
echo "== 1/4 patch =="
"$REPO/host/bwamem2_patch/apply_swa_capture.sh" "$BWA"

echo "== 2/4 build =="
make -C "$BWA" -j"$(nproc)" >/dev/null

echo "== 3/4 capture =="
# -t 1 keeps the record order deterministic and reproducible.
BSW_CAPTURE_OUT="$OUT/ecoli_swa.bin" "$BWA/bwa-mem2" mem -t 1 "$REF" "$R1" "$R2" \
    > "$OUT/ecoli_capture.sam" 2> "$OUT/capture.log"
grep -i bswcap "$OUT/capture.log" || true

echo "== 4/4 verify =="
make -C "$REPO/host/swa_hls" replay_swa >/dev/null
"$REPO/host/swa_hls/replay_swa" "$OUT/ecoli_swa.bin"
