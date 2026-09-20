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
# Usage:  scripts/f2/lint_cl_bsw.sh [--kit <path-to-aws-fpga-f2>]
# Or set AWS_FPGA_F2_DIR. If $HDK_DIR is set (hdk_setup.sh sourced) it is used.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WRAP="$ROOT/rtl/f2/cl_bsw_top.sv"
LOG="${LINT_LOG:-/tmp/cl_bsw_f2_lint.log}"
KIT="${AWS_FPGA_F2_DIR:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --kit) KIT="$2"; shift 2;;
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
  > "$LOG" 2>&1 || true

# Verilator exits 0 under -Wno-fatal even with findings, so judge by content.
rc=0
if grep -qE '^%Error' "$LOG"; then
  echo "LINT FAILED — errors:"; grep -E '^%Error' "$LOG" | sed 's/^/  /'; rc=1
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
echo "LINT PASSED — cl_bsw_top elaborates against the real F2 Shell port list and tie-offs."
echo "  ($pre pre-existing warning(s) elsewhere in the bsw core; none in the F2 wrapper.)"
