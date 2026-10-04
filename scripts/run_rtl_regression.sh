#!/usr/bin/env bash
#
# run_rtl_regression.sh -- run tb_bsw_ext over every vector set we have, not
# just the default one.
#
# WHY THIS EXISTS: `run_sim.sh tb_bsw_ext` runs only ext_sw_vectors.txt, and
# that set does NOT catch the historic gaps-open-from-H defect
# (docs/bsw_gapopen_fix.md). Two sets do: disc_mvsh.txt, the hand-written
# 1-record regression for exactly that bug -- which until now was referenced in
# RTL comments and docs but never actually executed by anything -- and
# rtl_sim150, which catches it organically out of real capture data. Running
# only the default set leaves that coverage on the floor.
#
# Usage:
#   ./scripts/run_rtl_regression.sh            # all sets  (~5 min)
#   ./scripts/run_rtl_regression.sh --quick    # the two highest-value  (~1 min)
#
# Exits non-zero if any set reports a failure.
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
QUICK=0
[ "${1:-}" = "--quick" ] && QUICK=1

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
# One build directory, reused: the RTL does not change between sets, so
# Verilator compiles once and every later set is just a re-run.
export BSW_BUILD_DIR="${BSW_BUILD_DIR:-/tmp/bsw_regress}"

EO="host/extend_orchestrator/vectors"
RV="host/swa_hls/vectors/rtl"

# name | path (.gz is decompressed) | what it is for
SETS=(
  "disc_mvsh|$EO/disc_mvsh.txt|the gap-open regression: gaps must open from M, not H"
  "sim150|$RV/rtl_sim150.txt.gz|150bp high-divergence; catches gap-open organically; max tlen 997"
)
if [ "$QUICK" = 0 ]; then
  SETS+=(
    "golden|$EO/ext_sw_vectors.txt|the committed set, 15,887 real extensions"
    "ecoli|$RV/rtl_ecoli.txt.gz|small reproducible set from the E. coli capture"
    "human|$RV/rtl_human.txt.gz|real ERR174310 reads"
  )
fi

printf '%-10s %8s %9s  %s\n' SET RECORDS RESULT NOTE
printf '%-10s %8s %9s  %s\n' ---------- -------- --------- ----
fail=0
for entry in "${SETS[@]}"; do
    name=${entry%%|*}; rest=${entry#*|}; path=${rest%%|*}; note=${rest##*|}

    # The committed golden set is generated on demand by run_sim.sh; let it.
    if [ "$name" = golden ] && [ ! -f "$path" ]; then
        bash scripts/run_sim.sh tb_bsw_ext >/dev/null 2>&1 || true
    fi
    if [ ! -f "$path" ]; then
        printf '%-10s %8s %9s  %s\n' "$name" - MISSING "$path"; fail=1; continue
    fi

    vec="$path"
    case "$path" in *.gz) vec="$TMP/$name.txt"; zcat "$path" > "$vec";; esac
    n=$(head -1 "$vec")

    out=$(BSW_EXT_VEC="$vec" bash scripts/run_sim.sh tb_bsw_ext 2>&1)
    line=$(printf '%s\n' "$out" | grep -oE '[0-9]+ extensions, [0-9]+ failures')
    if [ -z "$line" ]; then
        printf '%-10s %8s %9s  %s\n' "$name" "$n" BUILDFAIL "no summary line -- see output below"
        printf '%s\n' "$out" | tail -15
        fail=1; continue
    fi
    f=$(printf '%s\n' "$line" | grep -oE '[0-9]+ failures' | grep -oE '[0-9]+')
    if [ "$f" = 0 ]; then
        printf '%-10s %8s %9s  %s\n' "$name" "$n" PASS "$note"
    else
        printf '%-10s %8s %9s  %s\n' "$name" "$n" "FAIL($f)" "$note"
        printf '%s\n' "$out" | grep '^MISMATCH' | head -5
        fail=1
    fi
done

echo
if [ "$fail" = 0 ]; then echo "rtl regression: OK"; else echo "rtl regression: FAILED"; fi
exit $fail
