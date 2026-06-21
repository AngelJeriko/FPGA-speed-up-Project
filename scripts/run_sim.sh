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
elif [[ "$TB" == tb_matesw_dedup ]]; then
    RTL_FILES=(
        "$RTL/matesw_dedup.sv"
    )
    MR="$ROOT/host/mate_rescue"
    VEC_TXT="$MR/vectors/dedup_vectors.txt"
    PLUSARGS=("+VEC=$VEC_TXT")
    if [[ ! -f "$VEC_TXT" ]]; then
        echo "Generating $VEC_TXT ..."
        mkdir -p "$MR/vectors"
        ( cd "$MR" && g++ -O2 -std=c++17 -msse4.2 -DMR_DEDUP_INT -o gen_dedup_vectors gen_dedup_vectors.cpp ksw_ref.cpp \
          && ./gen_dedup_vectors vectors/dedup_vectors.txt 6000 )
    fi
elif [[ "$TB" == tb_chain_store ]]; then
    RTL_FILES=(
        "$RTL/chain_store.sv"
    )
    CH="$ROOT/host/chaining"
    VEC_TXT="$CH/vectors/chainstore_vectors.txt"
    PLUSARGS=("+VEC=$VEC_TXT")
    if [[ ! -f "$VEC_TXT" ]]; then
        echo "Generating $VEC_TXT ..."
        mkdir -p "$CH/vectors"
        ( cd "$CH" && g++ -O2 -std=c++17 -o gen_chainstore_vectors gen_chainstore_vectors.cpp \
          && ./gen_chainstore_vectors vectors/chainstore_vectors.txt 4000 )
    fi
elif [[ "$TB" == tb_chain_weight ]]; then
    RTL_FILES=(
        "$RTL/chain_weight.sv"
    )
    CH="$ROOT/host/chaining"
    VEC_TXT="$CH/vectors/chainweight_vectors.txt"
    PLUSARGS=("+VEC=$VEC_TXT")
    if [[ ! -f "$VEC_TXT" ]]; then
        echo "Generating $VEC_TXT ..."
        mkdir -p "$CH/vectors"
        ( cd "$CH" && g++ -O2 -std=c++17 -o gen_chain_weight_vectors gen_chain_weight_vectors.cpp \
          && ./gen_chain_weight_vectors vectors/chainweight_vectors.txt 4000 )
    fi
elif [[ "$TB" == tb_chain_introsort ]]; then
    RTL_FILES=(
        "$RTL/chain_introsort.sv"
    )
    CH="$ROOT/host/chaining"
    VEC_TXT="$CH/vectors/chainintro_vectors.txt"
    PLUSARGS=("+VEC=$VEC_TXT")
    if [[ ! -f "$VEC_TXT" ]]; then
        echo "Generating $VEC_TXT ..."
        mkdir -p "$CH/vectors"
        ( cd "$CH" && g++ -O2 -std=c++17 -o gen_chain_introsort_vectors gen_chain_introsort_vectors.cpp \
          && ./gen_chain_introsort_vectors vectors/chainintro_vectors.txt 4000 )
    fi
elif [[ "$TB" == tb_chain_flt ]]; then
    RTL_FILES=(
        "$RTL/chain_flt.sv"
    )
    CH="$ROOT/host/chaining"
    VEC_TXT="$CH/vectors/chainflt_vectors.txt"
    PLUSARGS=("+VEC=$VEC_TXT")
    if [[ ! -f "$VEC_TXT" ]]; then
        echo "Generating $VEC_TXT ..."
        mkdir -p "$CH/vectors"
        ( cd "$CH" && g++ -O2 -std=c++17 -o gen_chain_flt_vectors gen_chain_flt_vectors.cpp \
          && ./gen_chain_flt_vectors vectors/chainflt_vectors.txt 4000 )
    fi
elif [[ "$TB" == tb_chain_flt_top ]]; then
    RTL_FILES=(
        "$RTL/chain_weight.sv"
        "$RTL/chain_introsort.sv"
        "$RTL/chain_flt.sv"
        "$RTL/chain_flt_top.sv"
    )
    CH="$ROOT/host/chaining"
    VEC_TXT="$CH/vectors/chainflttop_vectors.txt"
    PLUSARGS=("+VEC=$VEC_TXT")
    if [[ ! -f "$VEC_TXT" ]]; then
        echo "Generating $VEC_TXT ..."
        mkdir -p "$CH/vectors"
        ( cd "$CH" && g++ -O2 -std=c++17 -o gen_chain_flt_top_vectors gen_chain_flt_top_vectors.cpp \
          && ./gen_chain_flt_top_vectors vectors/chainflttop_vectors.txt 4000 )
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
    # tb_matesw_top: mate-rescue engine (2-pass local SW on the BSW core in restart
    # mode) vs hw_align2 (== upstream ksw_align2).
    if [[ "$TB" == tb_matesw_top ]]; then
        RTL_FILES+=("$RTL/matesw_top.sv")
        MR="$ROOT/host/mate_rescue"
        VEC_TXT="$MR/vectors/matesw_vectors.txt"
        PLUSARGS=("+VEC=$VEC_TXT")
        if [[ ! -f "$VEC_TXT" ]]; then
            echo "Generating $VEC_TXT ..."
            mkdir -p "$MR/vectors"
            ( cd "$MR" && g++ -O2 -std=c++17 -msse4.2 -o gen_matesw_vectors gen_matesw_vectors.cpp ksw_ref.cpp \
              && ./gen_matesw_vectors vectors/matesw_vectors.txt 4000 )
        fi
    fi
    # tb_matesw_orient_unit: per-orientation mate-rescue unit (matesw_top + the
    # mem_matesw kswr->alnreg transform) vs hw_align2 + orch.h transform.
    if [[ "$TB" == tb_matesw_orient_unit ]]; then
        RTL_FILES+=("$RTL/matesw_top.sv" "$RTL/matesw_orient_unit.sv")
        MR="$ROOT/host/mate_rescue"
        VEC_TXT="$MR/vectors/orient_vectors.txt"
        PLUSARGS=("+VEC=$VEC_TXT")
        if [[ ! -f "$VEC_TXT" ]]; then
            echo "Generating $VEC_TXT ..."
            mkdir -p "$MR/vectors"
            ( cd "$MR" && g++ -O2 -std=c++17 -msse4.2 -o gen_orient_vectors gen_orient_vectors.cpp ksw_ref.cpp \
              && ./gen_orient_vectors vectors/orient_vectors.txt 4000 )
        fi
    fi
    # tb_matesw_orch_top: full mate-rescue orchestration (skip + per-orientation
    # matesw_orient_unit + insertion + matesw_dedup) vs orch.h::matesw_orchestrate.
    if [[ "$TB" == tb_matesw_orch_top ]]; then
        RTL_FILES+=("$RTL/matesw_top.sv" "$RTL/matesw_orient_unit.sv" \
                    "$RTL/matesw_dedup.sv" "$RTL/matesw_orch_top.sv")
        MR="$ROOT/host/mate_rescue"
        VEC_TXT="$MR/vectors/orchrtl_vectors.txt"
        PLUSARGS=("+VEC=$VEC_TXT")
        if [[ ! -f "$VEC_TXT" ]]; then
            echo "Generating $VEC_TXT ..."
            mkdir -p "$MR/vectors"
            ( cd "$MR" && g++ -O2 -std=c++17 -msse4.2 -DMR_DEDUP_INT -o gen_orchrtl_vectors gen_orchrtl_vectors.cpp ksw_ref.cpp \
              && ./gen_orchrtl_vectors vectors/orchrtl_vectors.txt 3000 )
        fi
    fi
    # tb_matesw_pe_top: paired-end candidate loop (matesw_orch_top per candidate,
    # threading the shared ma) vs matesw_orchestrate looped.
    if [[ "$TB" == tb_matesw_pe_top ]]; then
        RTL_FILES+=("$RTL/matesw_top.sv" "$RTL/matesw_orient_unit.sv" \
                    "$RTL/matesw_dedup.sv" "$RTL/matesw_orch_top.sv" "$RTL/matesw_pe_top.sv")
        MR="$ROOT/host/mate_rescue"
        VEC_TXT="$MR/vectors/petop_vectors.txt"
        PLUSARGS=("+VEC=$VEC_TXT")
        if [[ ! -f "$VEC_TXT" ]]; then
            echo "Generating $VEC_TXT ..."
            mkdir -p "$MR/vectors"
            ( cd "$MR" && g++ -O2 -std=c++17 -msse4.2 -DMR_DEDUP_INT -o gen_petop_vectors gen_petop_vectors.cpp ksw_ref.cpp \
              && ./gen_petop_vectors vectors/petop_vectors.txt 2000 )
        fi
    fi
    # tb_matesw_pe_sel_top: on-chip candidate selection + rescue loop (the b[i]
    # selection of mem_sam_pe_batch) vs matesw_pe_select (pe.h).
    if [[ "$TB" == tb_matesw_pe_sel_top ]]; then
        RTL_FILES+=("$RTL/matesw_top.sv" "$RTL/matesw_orient_unit.sv" \
                    "$RTL/matesw_dedup.sv" "$RTL/matesw_orch_top.sv" "$RTL/matesw_pe_top.sv" \
                    "$RTL/matesw_pe_sel_top.sv")
        MR="$ROOT/host/mate_rescue"
        VEC_TXT="$MR/vectors/pesel_vectors.txt"
        PLUSARGS=("+VEC=$VEC_TXT")
        if [[ ! -f "$VEC_TXT" ]]; then
            echo "Generating $VEC_TXT ..."
            mkdir -p "$MR/vectors"
            ( cd "$MR" && g++ -O2 -std=c++17 -msse4.2 -DMR_DEDUP_INT -o gen_pesel_vectors gen_pesel_vectors.cpp ksw_ref.cpp \
              && ./gen_pesel_vectors vectors/pesel_vectors.txt 2000 )
        fi
    fi
    # tb_accel_pe_top: the accel->mate-rescue on-chip handoff. Reuses the accel
    # vectors; checks the captured ma == accel's sorted/deduped output a[R].
    if [[ "$TB" == tb_accel_pe_top ]]; then
        RTL_FILES+=("$RTL/orch_window.sv" "$RTL/orch_assemble.sv" "$RTL/orch_seedcov.sv" \
                    "$RTL/bsw_seed_unit.sv" "$RTL/orch_chain_unit.sv" "$RTL/orch_purge.sv" \
                    "$RTL/orch_read_top.sv" "$RTL/msort_v2_pkg.sv" "$RTL/msort_v2_top.sv" \
                    "$RTL/accel_top.sv" "$RTL/matesw_top.sv" "$RTL/matesw_orient_unit.sv" \
                    "$RTL/matesw_dedup.sv" "$RTL/matesw_orch_top.sv" "$RTL/matesw_pe_top.sv" \
                    "$RTL/accel_pe_top.sv")
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
    # tb_accel_pe2_top: two-run fold — candidate source (run i) + ma (run !i) both
    # captured from accel; checks the two-target capture routing. Reuses accel vectors.
    if [[ "$TB" == tb_accel_pe2_top ]]; then
        RTL_FILES+=("$RTL/orch_window.sv" "$RTL/orch_assemble.sv" "$RTL/orch_seedcov.sv" \
                    "$RTL/bsw_seed_unit.sv" "$RTL/orch_chain_unit.sv" "$RTL/orch_purge.sv" \
                    "$RTL/orch_read_top.sv" "$RTL/msort_v2_pkg.sv" "$RTL/msort_v2_top.sv" \
                    "$RTL/accel_top.sv" "$RTL/matesw_top.sv" "$RTL/matesw_orient_unit.sv" \
                    "$RTL/matesw_dedup.sv" "$RTL/matesw_orch_top.sv" "$RTL/matesw_pe_top.sv" \
                    "$RTL/matesw_pe_sel_top.sv" "$RTL/accel_pe2_top.sv")
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
    # tb_accel_pe2_loop: FULL closed-loop — two accel runs (source + ma) -> on-chip
    # selection + rescue, checked vs gen_pe2_vectors (accel pipeline ∘ pe.h).
    if [[ "$TB" == tb_accel_pe2_loop ]]; then
        RTL_FILES+=("$RTL/orch_window.sv" "$RTL/orch_assemble.sv" "$RTL/orch_seedcov.sv" \
                    "$RTL/bsw_seed_unit.sv" "$RTL/orch_chain_unit.sv" "$RTL/orch_purge.sv" \
                    "$RTL/orch_read_top.sv" "$RTL/msort_v2_pkg.sv" "$RTL/msort_v2_top.sv" \
                    "$RTL/accel_top.sv" "$RTL/matesw_top.sv" "$RTL/matesw_orient_unit.sv" \
                    "$RTL/matesw_dedup.sv" "$RTL/matesw_orch_top.sv" "$RTL/matesw_pe_top.sv" \
                    "$RTL/matesw_pe_sel_top.sv" "$RTL/accel_pe2_top.sv")
        EO="$ROOT/host/extend_orchestrator"; MR="$ROOT/host/mate_rescue"
        VEC_TXT="$MR/vectors/pe2_vectors.txt"
        PLUSARGS=("+VEC=$VEC_TXT")
        if [[ ! -f "$VEC_TXT" ]]; then
            echo "Generating $VEC_TXT ..."
            if [[ ! -f "$EO/vectors/accel_vectors.txt" ]]; then
                [[ -f "$EO/vectors/ext_vec.bin" ]] || gunzip -kc "$EO/vectors/ext_vec.bin.gz" > "$EO/vectors/ext_vec.bin"
                ( cd "$EO" && g++ -O2 -std=c++17 -DHWMODEL -DINTPURGE -o gen_accel_vectors gen_accel_vectors.cpp \
                  && ./gen_accel_vectors vectors/ext_vec.bin vectors/accel_vectors.txt )
            fi
            mkdir -p "$MR/vectors"
            ( cd "$MR" && g++ -O2 -std=c++17 -msse4.2 -DMR_DEDUP_INT -o gen_pe2_vectors gen_pe2_vectors.cpp ksw_ref.cpp \
              && ./gen_pe2_vectors ../extend_orchestrator/vectors/accel_vectors.txt vectors/pe2_vectors.txt 300 )
        fi
    fi
    # tb_accel_pe_pair_top: BOTH-directions sequencer — full pair (a[0]'+a[1]') vs
    # gen_pe2pair_vectors (pe.h twice with original sources).
    if [[ "$TB" == tb_accel_pe_pair_top ]]; then
        RTL_FILES+=("$RTL/orch_window.sv" "$RTL/orch_assemble.sv" "$RTL/orch_seedcov.sv" \
                    "$RTL/bsw_seed_unit.sv" "$RTL/orch_chain_unit.sv" "$RTL/orch_purge.sv" \
                    "$RTL/orch_read_top.sv" "$RTL/msort_v2_pkg.sv" "$RTL/msort_v2_top.sv" \
                    "$RTL/accel_top.sv" "$RTL/matesw_top.sv" "$RTL/matesw_orient_unit.sv" \
                    "$RTL/matesw_dedup.sv" "$RTL/matesw_orch_top.sv" "$RTL/matesw_pe_top.sv" \
                    "$RTL/matesw_pe_sel_top.sv" "$RTL/accel_pe2_top.sv" "$RTL/accel_pe_pair_top.sv")
        EO="$ROOT/host/extend_orchestrator"; MR="$ROOT/host/mate_rescue"
        VEC_TXT="$MR/vectors/pe2pair_vectors.txt"
        PLUSARGS=("+VEC=$VEC_TXT")
        if [[ ! -f "$VEC_TXT" ]]; then
            echo "Generating $VEC_TXT ..."
            if [[ ! -f "$EO/vectors/accel_vectors.txt" ]]; then
                [[ -f "$EO/vectors/ext_vec.bin" ]] || gunzip -kc "$EO/vectors/ext_vec.bin.gz" > "$EO/vectors/ext_vec.bin"
                ( cd "$EO" && g++ -O2 -std=c++17 -DHWMODEL -DINTPURGE -o gen_accel_vectors gen_accel_vectors.cpp \
                  && ./gen_accel_vectors vectors/ext_vec.bin vectors/accel_vectors.txt )
            fi
            mkdir -p "$MR/vectors"
            ( cd "$MR" && g++ -O2 -std=c++17 -msse4.2 -DMR_DEDUP_INT -o gen_pe2pair_vectors gen_pe2pair_vectors.cpp ksw_ref.cpp \
              && ./gen_pe2pair_vectors ../extend_orchestrator/vectors/accel_vectors.txt vectors/pe2pair_vectors.txt 300 )
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
