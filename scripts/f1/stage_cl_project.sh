#!/usr/bin/env bash
# ========================================================================
# SUPERSEDED — F1 / VU9P bring-up path. The project's target moved to AWS F2 /
# Virtex UltraScale+ HBM VU47P on 2026-09-20. Live equivalent:
# scripts/f2/stage_cl_project.sh. Kept deliberately: it is a verified
# reference implementation (rungs A/B1/B2 complete, tb_cl_bsw_ocl 13/13
# score=5) and the record of the 2.4 -> 125 MHz timing campaign. It will NOT
# be re-tested against hardware, so treat it as frozen. NOTE that
# bsw_axil_regs.sv and test_bsw.c are NOT part of this path — they are shell-
# agnostic, shared with F2, and now live at rtl/bsw_axil_regs.sv and
# host/test_bsw.c.
# ========================================================================
# stage_cl_project.sh — turn Steps 2–5 of docs/f1_build_runbook.md into one command.
#
# RUNS ON: the (cheap, non-F1) build host, AFTER `source hdk_setup.sh`.
# GOAL:    do every deterministic thing (scaffold the CL project, drop in the
#          exact 9 RTL files in order, generate the source filelist) so no manual
#          fumbling happens on the paid clock — then optionally launch the build.
#
# It does NOT need an FPGA. Never run this on an f1.2xlarge (you'd pay FPGA rates
# for CPU synthesis). Use a z1d.2xlarge / c5.4xlarge with the FPGA Developer AMI.
#
# Usage:
#   source hdk_setup.sh                 # sets HDK_DIR + Vivado (required first)
#   scripts/f1/stage_cl_project.sh [options]
#
# Options:
#   --repo   <path>   Path to this repo         (default: auto-detected from script location)
#   --cl-dir <path>   CL project dir to create  (default: $HOME/cl_bsw)
#   --clock  <recipe> Clock recipe for the build (default: A0 = 125 MHz clk_main_a0)
#   --build           After staging, launch aws_build_dcp_from_cl.sh (detached, as HDK default)
#   --foreground      With --build, pass -foreground so you watch it live
#   --patch-encrypt   Best-effort auto-wire the filelist into encrypt.tcl (backs up + shows diff;
#                     aborts the patch and prints manual steps if it can't match confidently)
#   -h | --help       This help
#
# Safe to re-run: re-copies RTL and regenerates the filelist. It will NOT clobber
# an existing CL project's non-design files.
set -euo pipefail

# ---- locate repo from this script's own path (scripts/f1/ -> repo root) ----
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/../.." && pwd)"
CL_DIR="${CL_DIR:-$HOME/cl_bsw}"
CLOCK="A0"
DO_BUILD=0
FOREGROUND=0
PATCH_ENCRYPT=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)         REPO="$2"; shift 2;;
    --cl-dir)       CL_DIR="$2"; shift 2;;
    --clock)        CLOCK="$2"; shift 2;;
    --build)        DO_BUILD=1; shift;;
    --foreground)   FOREGROUND=1; shift;;
    --patch-encrypt) PATCH_ENCRYPT=1; shift;;
    -h|--help)      sed -n '2,40p' "$0"; exit 0;;
    *) echo "ERROR: unknown option '$1' (try --help)" >&2; exit 2;;
  esac
done

say(){ printf '\n\033[1;36m==>\033[0m %s\n' "$*"; }
warn(){ printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die(){ printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

# ---- the exact 9-file source list, in elaboration order (mirrors scripts/cl_bsw_files.f) ----
FILES=(
  rtl/bsw_pkg.sv
  rtl/bsw_score_matrix.sv
  rtl/bsw_pe.sv
  rtl/bsw_systolic_array.sv
  rtl/bsw_max_tracker.sv
  rtl/bsw_ctrl_fsm.sv
  rtl/bsw_top.sv
  rtl/bsw_axil_regs.sv
  rtl/f1/cl_bsw_top.sv
)

# ---- sanity: HDK sourced? repo intact? ----
[[ -n "${HDK_DIR:-}" ]] || die "HDK_DIR not set — run 'source hdk_setup.sh' first (FPGA Developer AMI)."
[[ -d "$REPO/rtl" ]]    || die "repo not found at '$REPO' (pass --repo <path>)."
for f in "${FILES[@]}"; do
  [[ -f "$REPO/$f" ]] || die "missing source: $REPO/$f"
done
HELLO="$HDK_DIR/cl/examples/cl_hello_world"
[[ -d "$HELLO" ]] || die "cl_hello_world example not found under \$HDK_DIR/cl/examples — is the HDK complete?"

say "Repo:      $REPO"
say "CL_DIR:    $CL_DIR"
say "Clock:     $CLOCK"

# ---- Step 2: scaffold the CL project from cl_hello_world ----
if [[ ! -d "$CL_DIR" ]]; then
  say "Scaffolding CL project from cl_hello_world"
  cp -r "$HELLO" "$CL_DIR"
else
  warn "CL_DIR already exists — reusing it (only design/ + filelist will be refreshed)."
fi
export CL_DIR
DESIGN="$CL_DIR/design"
mkdir -p "$DESIGN"

# ---- drop the example RTL modules, bring in ours ----
# Keep the example's *.vh (Shell defines: cl_id_defines.vh, cl_ports.vh, unused_*_template.inc,
# etc.) — cl_bsw_top.sv relies on them. Only remove the example's RTL *modules*.
say "Removing example RTL modules (cl_hello_world.sv), keeping Shell *.vh/.inc"
rm -f "$DESIGN"/cl_hello_world*.sv "$DESIGN"/cl_hello_world*.v 2>/dev/null || true

say "Copying the 9 RTL files into design/ (flattened)"
for f in "${FILES[@]}"; do
  cp "$REPO/$f" "$DESIGN/"
done

# ---- generate the Vivado filelist (design/-relative, +incdir on design/) ----
FLIST="$DESIGN/cl_bsw_files.f"
say "Generating $FLIST"
{
  echo "# cl_bsw_files.f — GENERATED by scripts/f1/stage_cl_project.sh"
  echo "# Ordered SystemVerilog source list for cl_bsw_top. Read AS SystemVerilog."
  echo "# +incdir must cover this directory so \`include \"bsw_pkg.sv\"\` resolves."
  echo "-sv"
  echo "+incdir+$DESIGN"
  for f in "${FILES[@]}"; do
    echo "$DESIGN/$(basename "$f")"
  done
} > "$FLIST"
echo "----- $FLIST -----"
cat "$FLIST"
echo "------------------"

# ---- Step 3 reminder: CL identity ----
if [[ -f "$DESIGN/cl_id_defines.vh" ]]; then
  say "CL identity: edit $DESIGN/cl_id_defines.vh (CL_SH_ID0/ID1) if you want a recognizable AFI id."
fi

# ---- Step 4: wire the filelist into the build's source enumeration ----
ENCRYPT="$CL_DIR/build/scripts/encrypt.tcl"
patch_ok=0
if [[ "$PATCH_ENCRYPT" -eq 1 && -f "$ENCRYPT" ]]; then
  say "Attempting best-effort patch of encrypt.tcl"
  cp "$ENCRYPT" "$ENCRYPT.bak.$(date +%s)"
  # cl_hello_world encrypt.tcl copies each design file into $TARGET_DIR via
  # 'file copy -force $CL_DIR/design/<f> $TARGET_DIR'. Replace the example RTL
  # module copies with our 9 files; leave every *.vh/.inc copy untouched.
  if grep -qE 'file copy -force .*design/cl_hello_world.*\.(sv|v)[[:space:]]' "$ENCRYPT"; then
    # delete example module copy lines
    sed -i -E '/file copy -force .*design\/cl_hello_world.*\.(sv|v)[[:space:]]/d' "$ENCRYPT"
    # build the insertion block
    INS=""
    for f in "${FILES[@]}"; do
      INS+="file copy -force \$CL_DIR/design/$(basename "$f") \$TARGET_DIR\n"
    done
    # insert our block right after the last existing design *.vh copy line
    LASTVH="$(grep -nE 'file copy -force .*design/.*\.(vh|inc)[[:space:]]' "$ENCRYPT" | tail -1 | cut -d: -f1 || true)"
    if [[ -n "$LASTVH" ]]; then
      sed -i "${LASTVH}r /dev/stdin" "$ENCRYPT" <<< "$(printf "$INS")"
      patch_ok=1
    else
      warn "Couldn't find a design *.vh copy line to anchor to — leaving encrypt.tcl and printing manual steps."
    fi
  else
    warn "encrypt.tcl doesn't match the expected cl_hello_world 'file copy' pattern (HDK version differs)."
  fi
  if [[ "$patch_ok" -eq 1 ]]; then
    say "Patched. Review the diff:"
    diff -u "$(ls -t "$ENCRYPT".bak.* | head -1)" "$ENCRYPT" || true
  fi
fi

if [[ "$patch_ok" -ne 1 ]]; then
  cat <<EOF

  ────────────────────────────────────────────────────────────────────────────
  MANUAL STEP (HDK-version-specific — 1 minute):
  Point the CL build's source enumeration at the 9 files in $DESIGN.
  Depending on your HDK version, edit ONE of:

    • $CL_DIR/build/scripts/encrypt.tcl
        → in the 'file copy -force \$CL_DIR/design/... \$TARGET_DIR' block,
          remove the cl_hello_world.sv line and add one line per file below.
    • $CL_DIR/build/scripts/create_dcp_from_cl.tcl
        → its read_verilog/read_systemverilog list.

  The files, IN THIS ORDER (bsw_pkg.sv MUST be first):
$(for f in "${FILES[@]}"; do echo "      \$CL_DIR/design/$(basename "$f")"; done)

  A ready filelist is also at: $FLIST
  ────────────────────────────────────────────────────────────────────────────
EOF
fi

# ---- Step 5: launch the build (optional) ----
BUILD_SCRIPTS="$CL_DIR/build/scripts"
if [[ "$DO_BUILD" -eq 1 ]]; then
  [[ -x "$BUILD_SCRIPTS/aws_build_dcp_from_cl.sh" ]] || die "aws_build_dcp_from_cl.sh not found/executable in $BUILD_SCRIPTS"
  warn "VERIFY the clock recipe: open \$HDK_DIR/docs/clock_recipes.md and confirm '$CLOCK' => clk_main_a0 = 125 MHz."
  say "Launching build: aws_build_dcp_from_cl.sh -clock_recipe_a $CLOCK"
  ( cd "$BUILD_SCRIPTS"
    if [[ "$FOREGROUND" -eq 1 ]]; then
      ./aws_build_dcp_from_cl.sh -clock_recipe_a "$CLOCK" -foreground
    else
      ./aws_build_dcp_from_cl.sh -clock_recipe_a "$CLOCK"
    fi )
  cat <<EOF

  Build launched. NEXT:
   1. Tail the log:  tail -f $BUILD_SCRIPTS/*.log
   2. TIMING GATE (Step 6): open $CL_DIR/build/reports/*.timing_summary and
      require WNS >= 0 and 0 failing endpoints ON clk_main_a0 BEFORE making an AFI.
      (A failing DCP loads but is metastable — do not spend the AFI bake / F1 trip on it.)
   3. Tarball lands at: $CL_DIR/build/checkpoints/to_aws/*.Developer_CL.tar
      -> upload to S3 + create-fpga-image (runbook Step 7). Then STOP this build host.
EOF
else
  cat <<EOF

  Staging complete. To build (Step 5), after wiring the filelist:
      cd $BUILD_SCRIPTS
      ./aws_build_dcp_from_cl.sh -clock_recipe_a $CLOCK      # VERIFY $CLOCK = 125 MHz first
  or re-run this script with --build (and --patch-encrypt to auto-wire the filelist).
EOF
fi
