#!/usr/bin/env bash
#
# run_sim.sh - Bash sim driver (WSL / Linux / macOS).
# Usage:
#   ./run_sim.sh                 # runs tb_bsw_pe
#   ./run_sim.sh tb_bsw_top
#

set -euo pipefail

TB="${1:-tb_bsw_pe}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RTL="$ROOT/rtl"
TBDIR="$ROOT/tb"

# Select the RTL file list + any plusargs based on the testbench.
PLUSARGS=()
if [[ "$TB" == tb_msort ]]; then
    RTL_FILES=(
        "$RTL/msort_pkg.sv"
        "$RTL/msort_merge_sorter.sv"
    )
    VEC_HEX="$TBDIR/vectors/msort_vectors.hex"
    PLUSARGS=("+VEC=$VEC_HEX")
    # Bootstrap the (git-ignored, 76 MB) vector file from the committed .gz.
    if [[ ! -f "$VEC_HEX" ]]; then
        MS="$ROOT/host/merge_sorter"
        BIN="$MS/vectors/alnreg_vectors.bin"
        echo "Generating $VEC_HEX ..."
        [[ -f "$BIN" ]] || gunzip -kf "$BIN.gz"
        python3 "$MS/gen_rtl_vectors.py" "$BIN" "$VEC_HEX" "${MSORT_PER_N:-4}"
    fi
elif [[ "$TB" == tb_msort_dedup ]]; then
    RTL_FILES=(
        "$RTL/msort_v2_pkg.sv"
        "$RTL/msort_dedup.sv"
    )
    VEC_HEX="$TBDIR/vectors/msort_dedup_vectors.hex"
    PLUSARGS=("+VEC=$VEC_HEX")
    if [[ ! -f "$VEC_HEX" ]]; then
        MS="$ROOT/host/merge_sorter"
        BIN="$MS/vectors/alnreg_v2_vectors.bin"
        echo "Generating $VEC_HEX ..."
        [[ -f "$BIN" ]] || gunzip -kf "$BIN.gz"
        python3 "$MS/gen_v2_rtl_vectors.py" "$BIN" "$VEC_HEX" "${MSORT_PER_N:-2}"
    fi
elif [[ "$TB" == tb_msort_v2 ]]; then
    RTL_FILES=(
        "$RTL/msort_v2_pkg.sv"
        "$RTL/msort_v2_top.sv"
    )
    VEC_HEX="$TBDIR/vectors/msort_v2_vectors.hex"
    PLUSARGS=("+VEC=$VEC_HEX")
    if [[ ! -f "$VEC_HEX" ]]; then
        MS="$ROOT/host/merge_sorter"
        BIN="$MS/vectors/alnreg_v2_vectors.bin"
        echo "Generating $VEC_HEX ..."
        [[ -f "$BIN" ]] || gunzip -kf "$BIN.gz"
        python3 "$MS/gen_v2_top_vectors.py" "$BIN" "$VEC_HEX" "${MSORT_PER_N:-2}"
    fi
else
    RTL_FILES=(
        "$RTL/bsw_pkg.sv"
        "$RTL/bsw_score_matrix.sv"
        "$RTL/bsw_pe.sv"
        "$RTL/bsw_systolic_array.sv"
        "$RTL/bsw_max_tracker.sv"
        "$RTL/bsw_ctrl_fsm.sv"
        "$RTL/bsw_top.sv"
        "$RTL/bsw_axis_adapter.sv"
    )
fi
TB_FILE="$TBDIR/${TB}.sv"

if [[ ! -f "$TB_FILE" ]]; then
    echo "Testbench not found: $TB_FILE" >&2
    exit 1
fi

if command -v verilator >/dev/null 2>&1; then
    echo "Using Verilator..."
    # Build outside the source tree — Verilator's Makefile rejects paths with spaces.
    OBJ="${BSW_BUILD_DIR:-/tmp/bsw}/obj_${TB}"
    rm -rf "$OBJ"
    mkdir -p "$OBJ"
    verilator --binary --timing --top-module "$TB" \
              --timescale 1ns/1ps \
              -Wno-WIDTH -Wno-UNOPTFLAT -Wno-TIMESCALEMOD \
              -I"$RTL" -Mdir "$OBJ" \
              "${RTL_FILES[@]}" "$TB_FILE"
    "$OBJ/V$TB" "${PLUSARGS[@]}"
    exit $?
fi

if command -v iverilog >/dev/null 2>&1; then
    echo "Using Icarus Verilog..."
    OUT="$ROOT/${TB}.vvp"
    iverilog -g2012 -o "$OUT" -I "$RTL" "${RTL_FILES[@]}" "$TB_FILE"
    vvp "$OUT" "${PLUSARGS[@]}"
    exit $?
fi

echo "No simulator found. Install Verilator (apt install verilator) or Icarus." >&2
exit 1
