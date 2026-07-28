#!/usr/bin/env bash
# run_ooc.sh — drive OOC synthesis for the priority modules on your LOCAL Vivado.
# Prereq: `source /path/to/Vivado/<ver>/settings64.sh` so `vivado` is on PATH.
# Usage:  ./run_ooc.sh [module ...]      (no args = the top-3 priority targets)
# Env:    PART=<part>  PERIOD=<ns>  to override defaults.
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$(cd ../.. && pwd)"
RTL="$ROOT/rtl"
OUT="$ROOT/synth/ooc/reports"
mkdir -p "$OUT"

# Free ML Standard proxy: Kintex UltraScale+, -2 speed grade (mirrors F1 xcvu9p -2).
# If your Vivado reports this part unavailable, swap to another free US+ part it lists,
# e.g. xcku3p-ffva676-2-e  or a Zynq US+ like xczu7ev-ffvc1156-2-e.
PART="${PART:-xcku5p-ffvb676-2-e}"
PERIOD="${PERIOD:-3.0}"          # 3 ns = 333 MHz target; Fmax = 1000/(PERIOD - WNS)

# module -> source files (space separated, repo-relative to rtl/)
declare -A SRC=(
  [chain_store]="chain_store.sv"
  [bsw_max_tracker]="bsw_pkg.sv bsw_max_tracker.sv"
  [matesw_dedup]="matesw_dedup.sv"
)

mods=("$@"); [ ${#mods[@]} -eq 0 ] && mods=(chain_store bsw_max_tracker matesw_dedup)

for m in "${mods[@]}"; do
  files="${SRC[$m]:-}"
  if [ -z "$files" ]; then echo "unknown module: $m (known: ${!SRC[*]})"; continue; fi
  paths=""; for f in $files; do paths="$paths $RTL/$f"; done
  echo "############ $m ($PART) ############"
  vivado -mode batch -nojournal -log "$OUT/${m}_vivado.log" \
    -source ooc_synth.tcl -tclargs "$m" "$PART" "$PERIOD" "$OUT" $paths
  echo "---- $m summary ----"; cat "$OUT/${m}_summary.rpt"; echo
done

echo "All reports in: $OUT"
echo "Share back: reports/*_summary.rpt (+ *_timing.rpt for the worst paths)."
