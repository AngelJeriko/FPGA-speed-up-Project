#!/usr/bin/env bash
# run_xinit_check.sh -- does the design depend on power-on register values?
#
# WHY THIS EXISTS
# ---------------------------------------------------------------------------
# A normal Verilator run silently initialises every register to zero. Real silicon
# does not: a flop comes up as whatever the bitstream loaded. So a design that reads
# a register before writing it can pass every Verilator test and still misbehave on
# an FPGA. XSIM's 4-state engine is the proper tool for this, but XSIM's BASIC
# licence tier refuses a design over 50,000 instances and the gate-level netlist has
# 166,514 -- so this is the available substitute.
#
# `--x-initial unique --x-assign unique` plus the RUNTIME plusarg
# `+verilator+rand+reset+2` fills uninitialised state with random values instead of
# zeros. Each seed is one roll of the dice, so the check runs many.
#
# THE RUNTIME PLUSARG IS LOAD-BEARING. With the compile-time switches alone, the
# reset value defaults to zeros and the test is INERT: it was verified inert by
# removing bsw_ctrl_fsm's state-register reset entirely and still seeing 5/5 seeds
# pass. With +verilator+rand+reset+2 that same mutant hangs on seed 1. If this check
# is ever changed, re-confirm it can still go red the same way.
#
# A pass means no seed tried found a dependency -- not a proof of absence. It is
# probabilistic: the FSM mutant above was caught by only 1 of 3 seeds.
#
#   ./scripts/run_xinit_check.sh [vector-file] [seed...]
set -euo pipefail
cd "$(dirname "$0")/.."

VEC="${1:-sim/xsim/vectors/vec_ecoli_200.txt}"
shift || true
SEEDS=("$@")
if [[ ${#SEEDS[@]} -eq 0 ]]; then
    SEEDS=(1 2 3 7 42 1234 12345 31337 99991 65535)
fi

OBJ="${BSW_BUILD_DIR:-/tmp/bsw_xinit}/obj"
rm -rf "$OBJ"; mkdir -p "$OBJ"

echo "building with randomized register init ..."
verilator --binary --timing --top-module tb_bsw_ext_flat \
  --timescale 1ns/1ps --unroll-count 4096 --unroll-stmts 200000 \
  -Wno-WIDTH -Wno-UNOPTFLAT -Wno-TIMESCALEMOD -Wno-DECLFILENAME -Wno-INITIALDLY -Wno-PINMISSING \
  --x-initial unique --x-assign unique \
  -Irtl -Mdir "$OBJ" \
  rtl/bsw_pkg.sv rtl/bsw_score_matrix.sv rtl/bsw_pe.sv rtl/bsw_systolic_array.sv \
  rtl/bsw_max_tracker.sv rtl/bsw_ctrl_fsm.sv rtl/bsw_top.sv \
  synth/postsynth/bsw_top_flat.sv tb/tb_bsw_ext_flat.sv > "$OBJ/build.log" 2>&1

echo "vectors: $VEC ($(head -1 "$VEC") extensions)"
echo
fails=0
for seed in "${SEEDS[@]}"; do
    printf "  seed %-8s : " "$seed"
    # A hang is a finding too: an unreset FSM state can park the design forever, so
    # a timeout counts as a failure rather than being silently skipped.
    if out=$(timeout 600 "$OBJ/Vtb_bsw_ext_flat" \
                +verilator+rand+reset+2 "+verilator+seed+$seed" "+VEC=$VEC" 2>&1); then
        line=$(printf '%s\n' "$out" | grep -E 'extensions,' || true)
        if [[ -z "$line" ]]; then
            echo "NO SUMMARY LINE -- treating as failure"; fails=$((fails+1))
        elif printf '%s\n' "$line" | grep -q 'ALL PASS'; then
            echo "$line"
        else
            echo "$line"; fails=$((fails+1))
        fi
    else
        echo "TIMEOUT or CRASH -- treating as failure"; fails=$((fails+1))
    fi
done

echo
if [[ $fails -eq 0 ]]; then
    echo "PASS: ${#SEEDS[@]} seeds, no dependency on power-on register values found."
    echo "      (probabilistic -- absence of a finding is not proof of absence)"
else
    echo "FAIL: $fails of ${#SEEDS[@]} seeds found a problem."
fi
exit $(( fails > 0 ? 1 : 0 ))
