#!/usr/bin/env bash
#
# show_rtl_vs_bwamem2.sh -- print bwa-mem2's outputs and the simulated RTL's
# outputs side by side, for the same extensions, so the agreement is visible as
# numbers rather than as a "0 failures" summary line.
#
#   ./scripts/show_rtl_vs_bwamem2.sh                      # E. coli, 20 rows
#   ./scripts/show_rtl_vs_bwamem2.sh --rows 40
#   ./scripts/show_rtl_vs_bwamem2.sh --capture ~/cap_human/sim150_swa.bin
#
# Left column block  = what bwa-mem2 itself computed, straight from the capture.
# Right column block = what bsw_top produced in simulation.
#
# score/qle/tle must agree exactly. gscore/gtle may differ for two documented
# reasons, and the verdict column names which:
#   sentinel  -- bwa-mem2 leaves gscore at its -1 "query end unreachable"
#                initialiser; the array clamps to 0. Both consumers branch on
#                gscore <= 0, so the two take the same path.
#   band      -- bsw_top computes the FULL unbanded DP and keeps tracking the
#                query end on rows where ksw's band has narrowed past it.
# See docs/rtl_verification.md section 4.
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd); cd "$ROOT"

CAP="$HOME/cap_swa/ecoli_swa.bin"; ROWS=20; COUNT=2000; MINT=400
while [ $# -gt 0 ]; do
  case "$1" in
    --capture) CAP="$2"; shift 2;;
    --rows)    ROWS="$2"; shift 2;;
    --count)   COUNT="$2"; shift 2;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done
[ -f "$CAP" ] || { echo "capture not found: $CAP" >&2
  echo "regenerate with scripts/capture_swa_ecoli.sh (see docs/ecoli_dataset.md)" >&2; exit 1; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
G=host/swa_hls/gen_rtl_vectors_from_cap
[ -x "$G" ] || g++ -O2 -std=c++17 -I host/extend_orchestrator -o "$G" "$G.cpp"

echo "capture : $CAP"
"$G" "$CAP" "$TMP/vec.txt" --count "$COUNT" --min-tlen "$MINT" --emit-raw "$TMP/raw.txt" \
  | grep -E '^emitted|^envelope'

echo "simulating bsw_top on $(head -1 "$TMP/vec.txt") extensions ..."
BSW_BUILD_DIR="${BSW_BUILD_DIR:-/tmp/bsw_sbs}" BSW_EXT_VEC="$TMP/vec.txt" \
  BSW_EXT_DUMP="$TMP/rtl.txt" bash scripts/run_sim.sh tb_bsw_ext 2>&1 | grep 'extensions,'

awk -v rows="$ROWS" '
  FNR==NR { if ($1 ~ /^#/) next; b[$1]=$2" "$3" "$4" "$5" "$6" "$7; nb++; next }
  { if ($1 ~ /^#/) next; r[$1]=$2" "$3" "$4" "$5" "$6" "$7; e[$1]=$8; nr++ }
  END {
    printf "\n%-5s | %-26s | %-26s | %s\n", "", "        bwa-mem2", "   bsw_top (RTL sim)", "verdict"
    printf "%-5s | %6s%5s%5s%5s%5s | %6s%5s%5s%5s%5s | %s\n", \
           "idx","score","qle","tle","gsc","gtle","score","qle","tle","gsc","gtle",""
    printf "%s\n", "------+----------------------------+----------------------------+--------"
    same=0; sent=0; band=0; bad=0; shown=0
    for (i=0; i<nb; i++) {
      split(b[i],B," "); split(r[i],R," ")
      core = (B[1]==R[1] && B[2]==R[2] && B[3]==R[3])
      gs   = (B[4]==R[4] && B[5]==R[5])
      if (!core || e[i]!=0)              { v="MISMATCH"; bad++ }
      else if (gs)                       { v="match";    same++ }
      else if (B[4]<0 && R[4]==0)        { v="sentinel"; sent++ }
      else                               { v="band";     band++ }
      if (shown < rows) {
        printf "%-5d | %6d%5d%5d%5d%5d | %6d%5d%5d%5d%5d | %s\n", i,
               B[1],B[2],B[3],B[4],B[5], R[1],R[2],R[3],R[4],R[5], v
        shown++
      }
    }
    printf "\n%d extensions compared\n", nb
    printf "  identical on all five outputs        : %d (%.2f%%)\n", same, 100*same/nb
    printf "  score/qle/tle identical, gscore      : %d sentinel (-1 vs 0), %d banded-vs-full\n", sent, band
    printf "  genuine mismatches                   : %d\n", bad
    if (bad==0) printf "\nscore/qle/tle: %d/%d EXACT against bwa-mem2\n", nb, nb
    else        printf "\nFAIL: %d genuine mismatches\n", bad
    exit (bad!=0)
  }' "$TMP/raw.txt" "$TMP/rtl.txt"
