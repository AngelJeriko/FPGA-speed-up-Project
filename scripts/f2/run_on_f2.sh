#!/usr/bin/env bash
# run_on_f2.sh — Step 8 of docs/f1_build_runbook.md as one command.
#
# RUNS ON: the f2.6xlarge, AFTER `source sdk_setup.sh`. This is the ONLY step that
# needs the FPGA, so keep it short: load the AGFI, (re)build the host, run the
# golden self-check, save the log, tell you the result. Then TERMINATE the instance.
#
# Do NOT launch the F2 until your AFI State.Code == "available" (poll from any box):
#   aws ec2 describe-fpga-images --fpga-image-ids <afi-...> \
#       --query 'FpgaImages[0].State.Code'
#
# Usage:
#   source sdk_setup.sh
#   scripts/f1/run_on_f2.sh -I agfi-0123456789abcdef [options]
#
# Options:
#   -I | --agfi <agfi-...>   Global FPGA image id to load        (REQUIRED)
#   -S | --slot <n>          FPGA slot                           (default: 0)
#   --repo <path>            Repo path                           (default: auto-detected)
#   --no-load                Skip fpga-load-local-image (image already loaded)
#   --rebuild                Force recompiling test_bsw even if the binary exists
#   -h | --help              This help
#
# Exit code mirrors test_bsw: 0 = GOLDEN OK (score=5), non-zero = mismatch/error.
#
# F2 NOTES (vs the F1 script):
#   * The runtime API is UNCHANGED. The F2 SDK still ships fpga_pci.h / fpga_mgmt.h and
#     the fpga-load-local-image / fpga-describe-local-image CLI, so host/test_bsw.c
#     compiles and runs here verbatim — it is pure OCL peek/poke and knows nothing about
#     the shell. It stays under host/ so the F1 runbook keeps working; there is no
#     separate F2 copy to drift out of sync.
#   * The smallest F2 instance is f2.6xlarge (1 FPGA, 24 vCPU). There is no 2xlarge.
#   * An F1 AFI will NOT load here: different device (VU47P vs VU9P) and different shell.
#     You must bake a new AFI from an F2 DCP.
#   * The FPGA runs at clk_main_a0 = 250 MHz, fixed. If the DCP was built with failing
#     timing it will still load and still return wrong answers — clear the timing gate
#     on the build host first (docs/f2_build_runbook.md, Step 5).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/../.." && pwd)"
AGFI=""
SLOT=0
DO_LOAD=1
REBUILD=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    -I|--agfi) AGFI="$2"; shift 2;;
    -S|--slot) SLOT="$2"; shift 2;;
    --repo)    REPO="$2"; shift 2;;
    --no-load) DO_LOAD=0; shift;;
    --rebuild) REBUILD=1; shift;;
    -h|--help) sed -n '2,30p' "$0"; exit 0;;
    *) echo "ERROR: unknown option '$1' (try --help)" >&2; exit 2;;
  esac
done

say(){ printf '\n\033[1;36m==>\033[0m %s\n' "$*"; }
die(){ printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

HOST_DIR="$REPO/host"
[[ -f "$HOST_DIR/test_bsw.c" ]] || die "test_bsw.c not found at $HOST_DIR (pass --repo <path>)."
[[ -n "${SDK_DIR:-}" ]] || die "SDK_DIR not set — run 'source sdk_setup.sh' first."
command -v fpga-load-local-image >/dev/null 2>&1 || die "fpga-load-local-image not on PATH — are you on an F2 with the SDK sourced?"

# ---- load the AFI ----
if [[ "$DO_LOAD" -eq 1 ]]; then
  [[ -n "$AGFI" ]] || die "no AGFI given — pass -I <agfi-...> (or --no-load if already loaded)."
  [[ "$AGFI" == agfi-* ]] || die "'-I' expects the GLOBAL id (agfi-...), not the afi-... id."
  say "Loading $AGFI into slot $SLOT"
  sudo fpga-load-local-image -S "$SLOT" -I "$AGFI"
fi
say "FPGA slot $SLOT status:"
sudo fpga-describe-local-image -S "$SLOT" -H || die "fpga-describe-local-image failed."

# ---- (re)build the host ----
BIN="$HOST_DIR/test_bsw"
if [[ "$REBUILD" -eq 1 || ! -x "$BIN" ]]; then
  say "Compiling test_bsw"
  gcc -I"$SDK_DIR/userspace/include" "$HOST_DIR/test_bsw.c" -o "$BIN" -lfpga_mgmt \
    || die "gcc failed — check that sdk_setup.sh was sourced (fpga_mgmt headers/lib)."
else
  say "Using existing $BIN (pass --rebuild to force)"
fi

# ---- run the golden self-check, tee to a timestamped log ----
LOG="$HOST_DIR/test_bsw_$(date +%Y%m%d_%H%M%S).log"
say "Running: sudo ./test_bsw   (log -> $LOG)"
set +e
sudo "$BIN" | tee "$LOG"
rc=${PIPESTATUS[0]}
set -e

echo
if [[ "$rc" -eq 0 ]]; then
  printf '\033[1;32m==> GOLDEN OK — score=5 on silicon. Log: %s\033[0m\n' "$LOG"
  echo "    Bring back this log (and the Step-6 timing_summary) to close F2 bring-up."
else
  printf '\033[1;31m==> test_bsw FAILED (exit %s). Log: %s\033[0m\n' "$rc" "$LOG"
  echo "    Likely: (a) wrong AGFI loaded (check fpga-describe above);"
  echo "            (b) DCP missed timing at Step 6 (metastable);"
  echo "            (c) BAR/offset mismatch (host<->RTL was cross-checked, so suspect a/b first)."
fi
echo "    Reminder: TERMINATE this f2.6xlarge when done — you only needed it for this run."
exit "$rc"
