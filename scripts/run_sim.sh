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

RTL_FILES=(
    "$RTL/bsw_pkg.sv"
    "$RTL/bsw_score_matrix.sv"
    "$RTL/bsw_pe.sv"
    "$RTL/bsw_systolic_array.sv"
    "$RTL/bsw_max_tracker.sv"
    "$RTL/bsw_ctrl_fsm.sv"
    "$RTL/bsw_top.sv"
)
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
    "$OBJ/V$TB"
    exit $?
fi

if command -v iverilog >/dev/null 2>&1; then
    echo "Using Icarus Verilog..."
    OUT="$ROOT/${TB}.vvp"
    iverilog -g2012 -o "$OUT" -I "$RTL" "${RTL_FILES[@]}" "$TB_FILE"
    vvp "$OUT"
    exit $?
fi

echo "No simulator found. Install Verilator (apt install verilator) or Icarus." >&2
exit 1
