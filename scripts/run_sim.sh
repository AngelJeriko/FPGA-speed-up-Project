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
    # tb_bsw_ext checks bsw_top against real-data ksw vectors; bootstrap them
    # from the committed capture (.bin.gz) via the C++ generator if missing.
    if [[ "$TB" == tb_bsw_ext ]]; then
        EO="$ROOT/host/extend_orchestrator"
        VEC_TXT="$EO/vectors/ext_sw_vectors.txt"
        PLUSARGS=("+VEC=$VEC_TXT")
        if [[ ! -f "$VEC_TXT" ]]; then
            echo "Generating $VEC_TXT ..."
            [[ -f "$EO/vectors/ext_vec.bin" ]] || gunzip -kc "$EO/vectors/ext_vec.bin.gz" > "$EO/vectors/ext_vec.bin"
            ( cd "$EO" && g++ -O2 -std=c++17 -o gen_ext_vectors gen_ext_vectors.cpp \
              && ./gen_ext_vectors vectors/ext_vec.bin vectors/ext_sw_vectors.txt )
        fi
    fi
    # tb_bsw_seed_unit checks the per-seed extension+assembly unit (orch_window +
    # bsw_top + orch_assemble) against the HW-model pre-purge alnreg per seed.
    if [[ "$TB" == tb_bsw_seed_unit ]]; then
        RTL_FILES+=("$RTL/orch_window.sv" "$RTL/orch_assemble.sv" "$RTL/bsw_seed_unit.sv")
        EO="$ROOT/host/extend_orchestrator"
        VEC_TXT="$EO/vectors/seedext_vectors.txt"
        PLUSARGS=("+VEC=$VEC_TXT")
        if [[ ! -f "$VEC_TXT" ]]; then
            echo "Generating $VEC_TXT ..."
            [[ -f "$EO/vectors/ext_vec.bin" ]] || gunzip -kc "$EO/vectors/ext_vec.bin.gz" > "$EO/vectors/ext_vec.bin"
            ( cd "$EO" && g++ -O2 -std=c++17 -DHWMODEL -o gen_seedext_vectors gen_seedext_vectors.cpp \
              && ./gen_seedext_vectors vectors/ext_vec.bin vectors/seedext_vectors.txt )
        fi
    fi
    # tb_orch_chain_unit checks the per-chain sequencer (seed-sort + per-seed
    # extension + seedcov + ordered collect) against extend_only's per-chain slice.
    if [[ "$TB" == tb_orch_chain_unit ]]; then
        RTL_FILES+=("$RTL/orch_window.sv" "$RTL/orch_assemble.sv" "$RTL/orch_seedcov.sv" \
                    "$RTL/bsw_seed_unit.sv" "$RTL/orch_chain_unit.sv")
        EO="$ROOT/host/extend_orchestrator"
        VEC_TXT="$EO/vectors/chain_vectors.txt"
        PLUSARGS=("+VEC=$VEC_TXT")
        if [[ ! -f "$VEC_TXT" ]]; then
            echo "Generating $VEC_TXT ..."
            [[ -f "$EO/vectors/ext_vec.bin" ]] || gunzip -kc "$EO/vectors/ext_vec.bin.gz" > "$EO/vectors/ext_vec.bin"
            ( cd "$EO" && g++ -O2 -std=c++17 -DHWMODEL -o gen_chain_vectors gen_chain_vectors.cpp \
              && ./gen_chain_vectors vectors/ext_vec.bin vectors/chain_vectors.txt )
        fi
    fi
    # tb_orch_purge checks the cross-chain redundancy purge (integer-only) against
    # extend_only+purge on a sample of full reads.
    if [[ "$TB" == tb_orch_purge ]]; then
        RTL_FILES+=("$RTL/orch_purge.sv")
        EO="$ROOT/host/extend_orchestrator"
        VEC_TXT="$EO/vectors/purge_vectors.txt"
        PLUSARGS=("+VEC=$VEC_TXT")
        if [[ ! -f "$VEC_TXT" ]]; then
            echo "Generating $VEC_TXT ..."
            [[ -f "$EO/vectors/ext_vec.bin" ]] || gunzip -kc "$EO/vectors/ext_vec.bin.gz" > "$EO/vectors/ext_vec.bin"
            ( cd "$EO" && g++ -O2 -std=c++17 -DHWMODEL -DINTPURGE -o gen_purge_vectors gen_purge_vectors.cpp \
              && ./gen_purge_vectors vectors/ext_vec.bin vectors/purge_vectors.txt )
        fi
    fi
    # tb_orch_read_top: full extend-orchestrator (chains -> post-purge alnregs)
    # vs orchestrate() on a sample of full reads.
    if [[ "$TB" == tb_orch_read_top ]]; then
        RTL_FILES+=("$RTL/orch_window.sv" "$RTL/orch_assemble.sv" "$RTL/orch_seedcov.sv" \
                    "$RTL/bsw_seed_unit.sv" "$RTL/orch_chain_unit.sv" "$RTL/orch_purge.sv" \
                    "$RTL/orch_read_top.sv")
        EO="$ROOT/host/extend_orchestrator"
        VEC_TXT="$EO/vectors/read_vectors.txt"
        PLUSARGS=("+VEC=$VEC_TXT")
        if [[ ! -f "$VEC_TXT" ]]; then
            echo "Generating $VEC_TXT ..."
            [[ -f "$EO/vectors/ext_vec.bin" ]] || gunzip -kc "$EO/vectors/ext_vec.bin.gz" > "$EO/vectors/ext_vec.bin"
            ( cd "$EO" && g++ -O2 -std=c++17 -DHWMODEL -DINTPURGE -o gen_read_vectors gen_read_vectors.cpp \
              && ./gen_read_vectors vectors/ext_vec.bin vectors/read_vectors.txt )
        fi
    fi
    # tb_accel_top: full accelerator (extend-orchestrator + compaction + merge-
    # sorter) vs orchestrate()->compact->v2_dedup end-to-end.
    if [[ "$TB" == tb_accel_top ]]; then
        RTL_FILES+=("$RTL/orch_window.sv" "$RTL/orch_assemble.sv" "$RTL/orch_seedcov.sv" \
                    "$RTL/bsw_seed_unit.sv" "$RTL/orch_chain_unit.sv" "$RTL/orch_purge.sv" \
                    "$RTL/orch_read_top.sv" "$RTL/msort_v2_pkg.sv" "$RTL/msort_v2_top.sv" \
                    "$RTL/accel_top.sv")
        EO="$ROOT/host/extend_orchestrator"
        VEC_TXT="$EO/vectors/accel_vectors.txt"
        PLUSARGS=("+VEC=$VEC_TXT")
        if [[ ! -f "$VEC_TXT" ]]; then
            echo "Generating $VEC_TXT ..."
            [[ -f "$EO/vectors/ext_vec.bin" ]] || gunzip -kc "$EO/vectors/ext_vec.bin.gz" > "$EO/vectors/ext_vec.bin"
            ( cd "$EO" && g++ -O2 -std=c++17 -DHWMODEL -DINTPURGE -o gen_accel_vectors gen_accel_vectors.cpp \
              && ./gen_accel_vectors vectors/ext_vec.bin vectors/accel_vectors.txt )
        fi
    fi
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
              -Wno-WIDTH -Wno-UNOPTFLAT -Wno-TIMESCALEMOD -Wno-DECLFILENAME -Wno-INITIALDLY \
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
