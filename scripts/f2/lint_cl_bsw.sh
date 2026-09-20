#!/usr/bin/env bash
#
# lint_cl_bsw.sh — elaborate the REAL F2 CL build path on this box, before paying for
# an AWS build.
#
# rtl/f2/cl_bsw_top.sv takes its port list from the HDK's cl_ports.vh and its tie-offs
# from the HDK's unused_*_template.inc. Those files are exactly what an ordinary
# Verilator testbench never sees — and exactly where an F1->F2 port goes wrong (renamed
# OCL signals, a tie-off that no longer exists, an output nothing drives). This script
# points Verilator at the real HDK files plus two stubs, so those faults surface here in
# seconds instead of hours into aws_build_dcp_from_cl.py.
#
# WHAT THIS CATCHES (each proven RED by a committed mutant — see docs/f2_bringup.md):
#   M1 a stale F1 signal name (ocl_cl_* -> sh_ocl_*)   -> %Warning-IMPLICIT
#   M2 including unused_sh_ocl_template.inc            -> structural guard below
#   M3 dropping the rst_main_n_sync declaration        -> %Error-PROCASSWIRE
#   M4 a tie-off included twice                        -> structural guard below
#   M5 a wrong address-slice width into bsw_axil_regs  -> %Warning-WIDTHEXPAND
#   M7 an undriven CL output port (e.g. tdo)          -> %Warning-UNDRIVEN on cl_ports.vh
#
# WHAT THIS DOES **NOT** CATCH: multiply-driven nets. A mutant that drives cl_ocl_*
# from both our slave and a tie-off lints 100% clean under Verilator even with -Wall;
# only Vivado sees it. That is why M2/M4 are checked structurally rather than by lint.
# Same blind spot the project already recorded ("Verilator misses synthesis bugs").
#
# Needs a checkout of the aws-fpga **f2** branch. A sparse one is enough:
#   git clone --filter=blob:none --no-checkout --depth 1 -b f2 \
#       https://github.com/aws/aws-fpga.git aws-fpga-f2
#   cd aws-fpga-f2 && git sparse-checkout init --cone && git sparse-checkout set \
#       hdk/common/shell_stable/design/interfaces hdk/common/shell_stable/design/sh_ddr
#
# Usage:  scripts/f2/lint_cl_bsw.sh [--kit <path-to-aws-fpga-f2>] [--cdc]
#   --cdc  lint the TWO-CLOCK build instead: defines BSW_KERNEL_CDC, so the wrapper
#          instantiates AWS_CLK_GEN (via a generated stub) and runs bsw_top on
#          clk_extra_a1 behind bsw_kernel_cdc. Structure only - the crossing itself is
#          proven functionally by `bash scripts/run_sim.sh tb_bsw_axil_cdc`.
# Or set AWS_FPGA_F2_DIR. If $HDK_DIR is set (hdk_setup.sh sourced) it is used.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WRAP="$ROOT/rtl/f2/cl_bsw_top.sv"
LOG="${LINT_LOG:-/tmp/cl_bsw_f2_lint.log}"
KIT="${AWS_FPGA_F2_DIR:-}"
CDC=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --kit) KIT="$2"; shift 2;;
    --cdc) CDC=1; shift;;
    -h|--help) sed -n '2,32p' "$0"; exit 0;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done

if [[ -z "$KIT" && -n "${HDK_DIR:-}" ]]; then
  IFDIR="$HDK_DIR/common/shell_stable/design/interfaces"
  DDRDIR="$HDK_DIR/common/shell_stable/design/sh_ddr"
else
  [[ -n "$KIT" ]] || { echo "ERROR: no aws-fpga f2 checkout. Pass --kit <path> or set AWS_FPGA_F2_DIR (see --help)." >&2; exit 1; }
  IFDIR="$KIT/hdk/common/shell_stable/design/interfaces"
  DDRDIR="$KIT/hdk/common/shell_stable/design/sh_ddr"
fi

[[ -f "$IFDIR/cl_ports.vh" ]]     || { echo "ERROR: cl_ports.vh not found under $IFDIR" >&2; exit 1; }
[[ -f "$DDRDIR/sh_ddr.stub.sv" ]] || { echo "ERROR: sh_ddr.stub.sv not found under $DDRDIR" >&2; exit 1; }
grep -q 'ocl_cl_awaddr' "$IFDIR/cl_ports.vh" || {
  echo "ERROR: $IFDIR/cl_ports.vh has no ocl_cl_* signals — that is an F1 (master-branch) HDK, not f2." >&2
  exit 1; }

# ---------------------------------------------------------------------------
# STRUCTURAL GUARD — the multi-driver class Verilator cannot see (see header).
# Only real `include directives count: the wrapper *mentions* the forbidden tie-off
# in a comment explaining why it is deliberately absent.
# ---------------------------------------------------------------------------
INCLUDES="$(grep -E '^[[:space:]]*`include' "$WRAP" || true)"
if grep -q 'unused_sh_ocl_template.inc' <<<"$INCLUDES"; then
  echo "ERROR: $WRAP includes unused_sh_ocl_template.inc." >&2
  echo "       That tie-off drives cl_ocl_* to 0 — the very signals our OCL slave drives." >&2
  echo "       The result is a multiply-driven net that ONLY Vivado will catch. Remove it." >&2
  exit 1
fi
dupes="$(grep -oE 'unused_[a-z_]+_template\.inc' <<<"$INCLUDES" | sort | uniq -d)"
if [[ -n "$dupes" ]]; then
  echo "ERROR: tie-off include listed more than once in $WRAP:" >&2
  echo "$dupes" | sed 's/^/       /' >&2
  exit 1
fi

EXTRA_SRC=()
VDEF=()
if [[ $CDC -eq 1 ]]; then
  VDEF+=( +define+BSW_KERNEL_CDC )
  EXTRA_SRC+=( "$ROOT/rtl/bsw_kernel_cdc.sv" "$ROOT/tb/f2/aws_clk_gen_stub.sv" )
  echo "MODE           : two-clock (BSW_KERNEL_CDC) - bsw_top on clk_extra_a1"
else
  echo "MODE           : single-clock (bsw_top on clk_main_a0 @ 250 MHz)"
fi
echo "HDK interfaces : $IFDIR"
echo "sh_ddr stub    : $DDRDIR/sh_ddr.stub.sv"
echo

# --unroll-count/--unroll-stmts: the per-PE loops (N_PE=160) blow both of Verilator's
#   default unroll budgets, and an un-unrolled loop with a delayed array assignment is
#   unsupported (BLKLOOPINIT). Same values scripts/run_sim.sh uses for the testbenches.
# WIDTH warnings are deliberately LEFT ON: the bsw core carries 12 pre-existing ones,
#   but rtl/f2/cl_bsw_top.sv carries ZERO, so they can be policed per-file below.
verilator --lint-only -sv --top-module cl_bsw_top \
  --unroll-count 4096 --unroll-stmts 200000 \
  -Wno-fatal \
  -Wno-UNOPTFLAT -Wno-DECLFILENAME -Wno-INITIALDLY -Wno-PINMISSING -Wno-PINCONNECTEMPTY \
  -Wwarn-UNDRIVEN \
  ${VDEF[@]+"${VDEF[@]}"} \
  +incdir+"$ROOT/rtl" +incdir+"$ROOT/rtl/f2" +incdir+"$IFDIR" \
  "$ROOT/rtl/bsw_pkg.sv" \
  "$ROOT/rtl/bsw_score_matrix.sv" \
  "$ROOT/rtl/bsw_pe.sv" \
  "$ROOT/rtl/bsw_systolic_array.sv" \
  "$ROOT/rtl/bsw_max_tracker.sv" \
  "$ROOT/rtl/bsw_ctrl_fsm.sv" \
  "$ROOT/rtl/bsw_top.sv" \
  "$ROOT/rtl/bsw_axil_regs.sv" \
  "$ROOT/rtl/f2/cl_bsw_top.sv" \
  "$ROOT/tb/f2/axi_register_slice_light_stub.sv" \
  "$DDRDIR/sh_ddr.stub.sv" \
  ${EXTRA_SRC[@]+"${EXTRA_SRC[@]}"} \
  > "$LOG" 2>&1 || true

# Verilator exits 0 under -Wno-fatal even with findings, so judge by content.
rc=0
if grep -qE '^%Error' "$LOG"; then
  echo "LINT FAILED — errors:"; grep -E '^%Error' "$LOG" | sed 's/^/  /'; rc=1
fi
# UNDRIVEN on the CL's OWN PORTS. Every output in cl_ports.vh is the CL's
# responsibility; leaving one floating is a real defect that reaches silicon. Verilator
# reports these against cl_ports.vh rather than our file, so the scoped check below
# would never see them - which is exactly how an undriven `tdo` survived the lint and
# was found later by real Vivado synthesis as CRITICAL WARNING [Synth 8-3848].
#
# Two are allowlisted because AWS's OWN tie-off templates drive them only partially:
# unused_dma_pcis_template.inc assigns cl_sh_dma_pcis_{b,r}id[5:0] while cl_ports.vh
# declares them 16 bits wide. Not ours to fix, and benign with the interface tied off.
UNDRIVEN_ALLOW='cl_sh_dma_pcis_bid|cl_sh_dma_pcis_rid'
undriven="$(grep -E '^%Warning-UNDRIVEN' "$LOG" | grep 'cl_ports.vh' \
            | grep -vE "$UNDRIVEN_ALLOW" || true)"
if [[ -n "$undriven" ]]; then
  echo "LINT FAILED - undriven CL output port(s). Every output in cl_ports.vh must be driven:"
  echo "$undriven" | sed 's/^/  /'
  rc=1
fi

# Zero-warning policy SCOPED TO OUR WRAPPER: it is warning-clean when correct, so any
# warning pointing into it is a fault (this is what catches M1 and M5).
if grep -E '^%Warning' "$LOG" | grep -q 'rtl/f2/cl_bsw_top.sv'; then
  echo "LINT FAILED — warnings in rtl/f2/cl_bsw_top.sv (it is warning-clean when correct):"
  grep -E '^%Warning' "$LOG" | grep 'rtl/f2/cl_bsw_top.sv' | sed 's/^/  /'
  rc=1
fi
[[ $rc -ne 0 ]] && { echo; echo "Full log: $LOG"; exit 1; }

pre=$(grep -cE '^%Warning' "$LOG" || true)
mode_note="single-clock"; [[ $CDC -eq 1 ]] && mode_note="two-clock/CDC"
echo "LINT PASSED ($mode_note) - cl_bsw_top elaborates against the real F2 Shell files."
echo "  ($pre pre-existing warning(s) elsewhere in the bsw core; none in the F2 wrapper.)"
