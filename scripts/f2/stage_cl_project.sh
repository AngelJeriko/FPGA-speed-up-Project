#!/usr/bin/env bash
#
# stage_cl_project.sh — build an AWS **F2** CL project for cl_bsw_top on a cheap
# (non-F2) build host, and optionally launch the DCP build.
#
# Run this on an FPGA Developer AMI instance with the aws-fpga **f2** branch checked
# out and hdk_setup.sh sourced. Do NOT run it on an f2.6xlarge: synthesis is a CPU job
# and the FPGA sits idle at FPGA prices. See docs/f2_build_runbook.md.
#
# What it does:
#   1. Scaffolds $CL_DIR from the HDK's cl_demo/cl_axil_reg_access example — the F2
#      example closest to what we build (OCL AXI-Lite only, no DDR/HBM/DMA).
#   2. Re-points the example's build-script symlinks (they are relative, 6 levels up,
#      and BREAK the moment the CL is copied out of hdk/cl/examples/cl_demo/).
#   3. Drops the example RTL, copies our 9 sources + 2 define headers into design/.
#   4. Strips `include "bsw_pkg.sv"` from the staged copies (see scripts/cl_bsw_files_f2.f).
#   5. Rewrites encrypt.tcl's design-file block and generates synth_cl_bsw_top.tcl with
#      an EXPLICIT ordered read_verilog list instead of AWS's alphabetical glob.
#   6. With --build, runs aws_build_dcp_from_cl.py.
#
# Usage:
#   scripts/f2/stage_cl_project.sh [--build] [--cl-dir <path>] [--repo <path>]
#                                  [--encrypt] [--clk-gen]
#     --build     launch aws_build_dcp_from_cl.py after staging
#     --clk-gen   stage the TWO-CLOCK variant: defines BSW_KERNEL_CDC, adds
#                 rtl/bsw_kernel_cdc.sv, installs scripts/f2/cl_timing_user_cdc.xdc and
#                 builds with --aws_clk_gen --clock_recipe_a A1 (clk_extra_a1 = 125 MHz).
#                 Only needed if bsw_top misses clk_main_a0's fixed 250 MHz.
#     --encrypt   pass -e/--encrypt to the build (source encryption; off by default)

set -euo pipefail

say()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

# The CL name is NOT a free choice: aws_build_dcp_from_cl.py derives it from the
# $CL_DIR basename, requires -c to match, and synth runs with `-top ${CL}`. So the
# directory, the -c argument and the module name in rtl/f2/cl_bsw_top.sv must agree.
CL_NAME="cl_bsw_top"

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CL_DIR="${CL_DIR:-$HOME/$CL_NAME}"
DO_BUILD=0; DO_ENCRYPT=0; DO_CLKGEN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --build)   DO_BUILD=1; shift;;
    --encrypt) DO_ENCRYPT=1; shift;;
    --clk-gen) DO_CLKGEN=1; shift;;
    --cl-dir)  CL_DIR="$2"; shift 2;;
    --repo)    REPO="$2"; shift 2;;
    -h|--help) sed -n '2,28p' "$0"; exit 0;;
    *) die "unknown arg: $1";;
  esac
done

# ---- the exact 9-file source list, in elaboration order (mirrors scripts/cl_bsw_files_f2.f) ----
FILES=(
  rtl/bsw_pkg.sv
  rtl/bsw_score_matrix.sv
  rtl/bsw_pe.sv
  rtl/bsw_systolic_array.sv
  rtl/bsw_max_tracker.sv
  rtl/bsw_ctrl_fsm.sv
  rtl/bsw_top.sv
  rtl/bsw_axil_regs.sv
  rtl/f2/cl_bsw_top.sv
)
HEADERS=( rtl/f2/cl_bsw_defines.vh rtl/f2/cl_id_defines.vh )

# The two-clock build adds exactly one source: the crossing itself. It must be read
# after bsw_top (which it instantiates) and before bsw_axil_regs (which instantiates it).
CDC_SRC=rtl/bsw_kernel_cdc.sv

# ---- sanity: HDK sourced? is it actually the f2 branch? repo intact? ----
[[ -n "${HDK_DIR:-}" ]] || die "HDK_DIR not set — run 'source hdk_setup.sh' from an aws-fpga f2 checkout."
IFDIR="$HDK_DIR/common/shell_stable/design/interfaces"
[[ -f "$IFDIR/cl_ports.vh" ]] || die "no cl_ports.vh under $IFDIR — incomplete HDK?"
grep -q 'ocl_cl_awaddr' "$IFDIR/cl_ports.vh" \
  || die "cl_ports.vh has no ocl_cl_* signals: this is an F1 (master-branch) HDK, not f2.
        Check out the 'f2' branch of aws/aws-fpga and re-source hdk_setup.sh."
[[ -f "$IFDIR/unused_ddr_template.inc" ]] || die "unused_ddr_template.inc missing — not an f2 HDK."

if [[ $DO_CLKGEN -eq 1 ]]; then
  NEW_FILES=()
  for f in "${FILES[@]}"; do
    [[ "$f" == "rtl/f1/bsw_axil_regs.sv" || "$f" == "rtl/bsw_axil_regs.sv" ]] && NEW_FILES+=( "$CDC_SRC" )
    NEW_FILES+=( "$f" )
  done
  FILES=( "${NEW_FILES[@]}" )
fi

for f in "${FILES[@]}" "${HEADERS[@]}"; do
  [[ -f "$REPO/$f" ]] || die "missing source: $REPO/$f"
done

# Guard the naming contract before anything expensive happens.
grep -qE '^module[[:space:]]+'"$CL_NAME"'\b' "$REPO/rtl/f2/cl_bsw_top.sv" \
  || die "rtl/f2/cl_bsw_top.sv does not declare 'module $CL_NAME' — synth uses -top \${CL}."
[[ "$(basename "$CL_DIR")" == "$CL_NAME" ]] \
  || die "CL_DIR basename must be '$CL_NAME' (got '$(basename "$CL_DIR")').
        aws_build_dcp_from_cl.py derives the CL name from it and rejects a mismatch."

EXAMPLE="$HDK_DIR/cl/examples/cl_demo/cl_axil_reg_access"
[[ -d "$EXAMPLE" ]] || die "cl_demo/cl_axil_reg_access not found under \$HDK_DIR/cl/examples."

say "Repo:    $REPO"
say "HDK:     $HDK_DIR"
say "CL_DIR:  $CL_DIR   (CL name: $CL_NAME)"

# ---- Step 1: scaffold ----
if [[ ! -d "$CL_DIR" ]]; then
  say "Scaffolding CL project from cl_demo/cl_axil_reg_access"
  cp -a "$EXAMPLE" "$CL_DIR"        # -a, not -r: preserve the build-script symlinks
else
  warn "CL_DIR already exists — reusing it (design/ + build scripts are refreshed)."
fi
export CL_DIR
DESIGN="$CL_DIR/design"
BSCRIPTS="$CL_DIR/build/scripts"
mkdir -p "$DESIGN"

# ---- Step 2: repair the relative build-script symlinks ----
# In the HDK these point 6 levels up from hdk/cl/examples/cl_demo/<cl>/build/scripts.
# Copying the CL anywhere else (including one level shallower) leaves them dangling.
say "Re-pointing build-script symlinks at \$HDK_DIR (absolute)"
for l in aws_build_dcp_from_cl.py build_all.tcl build_level_1_cl.tcl; do
  src="$HDK_DIR/common/shell_stable/build/scripts/$l"
  [[ -f "$src" ]] || die "expected HDK build script missing: $src"
  ln -sfn "$src" "$BSCRIPTS/$l"
done

# ---- Step 3: design sources ----
say "Removing the example's RTL (keeping its build/ + constraints)"
rm -f "$DESIGN"/cl_axil_reg_access.sv "$DESIGN"/cl_axil_reg_access_defines.vh

say "Copying ${#FILES[@]} RTL sources + ${#HEADERS[@]} headers into design/"
for f in "${FILES[@]}" "${HEADERS[@]}"; do
  cp -f "$REPO/$f" "$DESIGN/$(basename "$f")"
done

# ---- Step 3b: two-clock build -> define BSW_KERNEL_CDC + swap in CDC constraints ----
if [[ $DO_CLKGEN -eq 1 ]]; then
  DEF="$DESIGN/cl_bsw_defines.vh"
  say "Two-clock build: defining BSW_KERNEL_CDC in $(basename "$DEF")"
  # Insert before the closing `endif so the guard still wraps everything.
  python3 - "$DEF" <<'PYDEF'
import sys
p = sys.argv[1]
s = open(p).read()
marker = "`endif // CL_BSW_DEFINES"
add = ("// GENERATED by scripts/f2/stage_cl_project.sh --clk-gen:\n"
       "// run bsw_top on AWS_CLK_GEN clk_extra_a1 (125 MHz) behind bsw_kernel_cdc.\n"
       "`define BSW_KERNEL_CDC\n\n")
assert marker in s, "cl_bsw_defines.vh has no `endif marker"
open(p, "w").write(s.replace(marker, add + marker, 1))
print("  BSW_KERNEL_CDC defined")
PYDEF

  XDC_SRC="$REPO/scripts/f2/cl_timing_user_cdc.xdc"
  XDC_DST="$CL_DIR/build/constraints/cl_timing_user.xdc"
  [[ -f "$XDC_SRC" ]] || die "missing $XDC_SRC"
  [[ -f "$XDC_DST" && ! -f "$XDC_DST.orig" ]] && cp -f "$XDC_DST" "$XDC_DST.orig"
  say "Installing CDC timing constraints (backup: cl_timing_user.xdc.orig)"
  cp -f "$XDC_SRC" "$XDC_DST"
  warn "Verify the clock OBJECT names in $XDC_DST after the first synth (report_clocks)."
  warn "An XDC pattern that matches nothing fails SILENTLY - the crossing would be unconstrained."
fi

# ---- Step 4: strip the package include from the staged copies ----
# Rationale in scripts/cl_bsw_files_f2.f: Vivado may use per-file compilation units,
# where the BSW_PKG_SV guard does not carry across files and the package would be
# declared once per includer. `import bsw_pkg::*` resolves without the include.
say "Stripping \`include \"bsw_pkg.sv\" from staged copies (Vivado compiles the package once)"
stripped=0
for f in "${FILES[@]}"; do
  d="$DESIGN/$(basename "$f")"
  if grep -q '`include "bsw_pkg.sv"' "$d"; then
    sed -i 's|^\(`include "bsw_pkg.sv"\)|// [staged] \1  -- package read explicitly first by synth_'"$CL_NAME"'.tcl|' "$d"
    stripped=$((stripped+1))
  fi
done
say "  stripped in $stripped file(s)"

# ---- Step 5: encrypt.tcl — replace the developer section ----
ENCRYPT_TCL="$BSCRIPTS/encrypt.tcl"
[[ -f "$ENCRYPT_TCL" ]] || die "encrypt.tcl not found at $ENCRYPT_TCL"
cp -f "$ENCRYPT_TCL" "$ENCRYPT_TCL.orig"
say "Rewriting the developer section of encrypt.tcl (backup: encrypt.tcl.orig)"
{
  awk '/#---- Developer would replace this section with design files ----/{exit} {print}' "$ENCRYPT_TCL.orig"
  echo '#---- Developer would replace this section with design files ----'
  echo '## GENERATED by scripts/f2/stage_cl_project.sh — do not hand-edit; re-run the script.'
  echo 'set UNUSED_TEMPLATES_DIR $HDK_SHELL_DESIGN_DIR/interfaces'
  echo ''
  echo '# Shell tie-offs. NOTE: unused_sh_ocl_template.inc is deliberately NOT copied —'
  echo '# it drives cl_ocl_*, which our OCL slave drives. Including it multiply-drives them.'
  for inc in unused_flr_template.inc unused_ddr_template.inc unused_cl_sda_template.inc \
             unused_apppf_irq_template.inc unused_dma_pcis_template.inc unused_pcim_template.inc; do
    printf 'file copy -force $UNUSED_TEMPLATES_DIR/%-34s $src_post_enc_dir\n' "$inc"
  done
  echo ''
  echo '# CL headers and RTL'
  for f in "${HEADERS[@]}" "${FILES[@]}"; do
    printf 'file copy -force $CL_DIR/design/%-28s $src_post_enc_dir\n' "$(basename "$f")"
  done
  echo ''
  awk 'f{print} /#---- End of section replaced by Developer ---/{if(!f){print; f=1}}' "$ENCRYPT_TCL.orig"
} > "$ENCRYPT_TCL.new"
mv -f "$ENCRYPT_TCL.new" "$ENCRYPT_TCL"
grep -q 'cl_bsw_top.sv' "$ENCRYPT_TCL" || die "encrypt.tcl rewrite failed — inspect $ENCRYPT_TCL.orig"

# ---- Step 6: synth tcl — rename + explicit ordered read_verilog ----
OLD_SYNTH="$BSCRIPTS/synth_cl_axil_reg_access.tcl"
NEW_SYNTH="$BSCRIPTS/synth_$CL_NAME.tcl"
[[ -f "$OLD_SYNTH" || -f "$NEW_SYNTH" ]] || die "no synth tcl found in $BSCRIPTS"
if [[ -f "$OLD_SYNTH" ]]; then
  say "Renaming synth_cl_axil_reg_access.tcl -> synth_$CL_NAME.tcl"
  mv -f "$OLD_SYNTH" "$NEW_SYNTH"
fi
say "Replacing the alphabetical glob with an explicit ordered read_verilog list"
python3 - "$NEW_SYNTH" "$CL_NAME" "${FILES[@]}" <<'PY'
import sys, os
path, cl_name = sys.argv[1], sys.argv[2]
files = [os.path.basename(f) for f in sys.argv[3:]]
src = open(path).read()
glob_line = 'read_verilog -sv [glob ${src_post_enc_dir}/*.{s,}v]'
if glob_line not in src:
    sys.exit("synth tcl does not contain the expected glob line - HDK layout changed; "
             "edit %s by hand (read the package first)." % path)
ordered = "\n".join('read_verilog -sv ${src_post_enc_dir}/%s' % f for f in files)
src = src.replace(glob_line,
    "# GENERATED by scripts/f2/stage_cl_project.sh: explicit dependency order.\n"
    "# bsw_pkg.sv MUST be read first; the stock glob is alphabetical and does not\n"
    "# guarantee that. Order mirrors scripts/cl_bsw_files_f2.f.\n" + ordered)
# We instantiate neither the debug bridge nor the ILA, so do not pull in their IP.
for ip in ("cl_debug_bridge", "ila_axil"):
    src = src.replace("read_ip ${HDK_IP_SRC_DIR}/%s/%s.xci" % (ip, ip),
                      "# (not instantiated by %s) read_ip ${HDK_IP_SRC_DIR}/%s/%s.xci" % (cl_name, ip, ip))
open(path, "w").write(src)
print("  synth tcl patched: %d ordered reads" % len(files))
PY

say "Staging complete."
echo
echo "  CL_DIR      : $CL_DIR"
echo "  design/     : $(ls "$DESIGN" | wc -l) files"
echo "  build script: $BSCRIPTS/aws_build_dcp_from_cl.py"
echo

BUILD_ARGS=( -c "$CL_NAME" )
[[ $DO_ENCRYPT -eq 1 ]] && BUILD_ARGS+=( --encrypt )
if [[ $DO_CLKGEN -eq 1 ]]; then
  # Extra clocks come from an AWS_CLK_GEN IP instantiated IN the CL; the build script
  # hard-errors if a clock recipe is passed without --aws_clk_gen. A1 gives
  # clk_extra_a1 = 125 MHz. clk_main_a0 is fixed at 250 MHz either way.
  BUILD_ARGS+=( --aws_clk_gen --clock_recipe_a A1 )
  say "--clk-gen: recipe A1 gives clk_extra_a1 = 125 MHz; clk_main_a0 stays 250 MHz."
  warn "Only use this if synth/ooc/impl_bsw_top_f2.tcl showed bsw_top MISSING 250 MHz."
  warn "The single-clock build is simpler and needs no recipe flags at all."
fi

if [[ $DO_BUILD -eq 1 ]]; then
  say "Launching: aws_build_dcp_from_cl.py ${BUILD_ARGS[*]}"
  cd "$BSCRIPTS"
  ./aws_build_dcp_from_cl.py "${BUILD_ARGS[@]}"
  echo
  say "Build finished. NEXT: clear the timing gate BEFORE creating an AFI —"
  echo "    grep -A4 'Design Timing Summary' $CL_DIR/build/reports/*timing_summary*"
  echo "  Require WNS >= 0 and 0 failing endpoints on clk_main_a0 (250 MHz)."
else
  say "Not building (--build not given). To build:"
  echo "    cd $BSCRIPTS && ./aws_build_dcp_from_cl.py ${BUILD_ARGS[*]}"
fi
