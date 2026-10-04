# run_bsw_ext.ps1 -- run tb_bsw_ext under XSIM (Vivado's 4-state simulator).
#
# WHY: Verilator is a 2-state simulator. It cannot model X (unknown)
# propagation, uninitialised registers or reset sequencing, and on this project
# it has already missed two real problems that AMD's tools caught (an undriven
# `tdo`, and 147k multiply-driven nets). Running the same testbench under XSIM
# is a different kind of check, not a repeat of the Verilator one.
#
# Usage, from the repo root:
#   .\sim\xsim\run_bsw_ext.ps1
#   .\sim\xsim\run_bsw_ext.ps1 -Vec C:/work/vectors/rtl_sim150.txt
#   .\sim\xsim\run_bsw_ext.ps1 -VivadoBin D:\AMD_Vivado\2026.1\Vivado\bin
#
# NOTE: this script has NOT been executed -- there is no Vivado on the machine
# it was written on. docs/rtl_xsim_runbook.md lists what to do if a step fails.
param(
  [string]$VivadoBin = "D:\AMD_Vivado\2026.1\Vivado\bin",
  [string]$Vec       = "",
  [string]$Top       = "tb_bsw_ext"
)
$ErrorActionPreference = "Stop"

$repo = (Resolve-Path "$PSScriptRoot\..\..").Path
$work = Join-Path $PSScriptRoot "xsim_work"
New-Item -ItemType Directory -Force -Path $work | Out-Null

# Vectors: default to the committed golden set. Forward slashes -- the path goes
# into Verilog $fopen via a plusarg, and backslashes are escape characters there.
if ($Vec -eq "") {
  $Vec = (Join-Path $repo "host\extend_orchestrator\vectors\ext_sw_vectors.txt")
}
$Vec = $Vec -replace '\\','/'
if (-not (Test-Path $Vec)) { throw "vector file not found: $Vec" }
$n = (Get-Content $Vec -First 1)
Write-Host "vectors : $Vec  ($n extensions)"

Push-Location $work
try {
  Write-Host "`n== 1/3 xvlog (compile) =="
  & "$VivadoBin\xvlog.bat" -sv -f "$repo\sim\xsim\bsw_ext_sources.f"
  if ($LASTEXITCODE -ne 0) { throw "xvlog failed ($LASTEXITCODE)" }

  Write-Host "`n== 2/3 xelab (elaborate) =="
  # --timescale matches run_sim.sh's Verilator setting, so the testbench's
  # watchdog (#2000000000) means the same amount of simulated time.
  # -O0 keeps elaboration fast; raise to -O3 only if runtime is the problem.
  & "$VivadoBin\xelab.bat" $Top -s ${Top}_sim --timescale 1ns/1ps -O0 -relax
  if ($LASTEXITCODE -ne 0) { throw "xelab failed ($LASTEXITCODE)" }

  Write-Host "`n== 3/3 xsim (run) =="
  & "$VivadoBin\xsim.bat" "${Top}_sim" -runall -testplusarg "VEC=$Vec"
  if ($LASTEXITCODE -ne 0) { throw "xsim failed ($LASTEXITCODE)" }
}
finally { Pop-Location }

Write-Host "`nLook for the summary line: '$Top: N extensions, M failures'"
Write-Host "M must be 0. Any 'x' in a reported value is an X-propagation finding"
Write-Host "-- see docs/rtl_xsim_runbook.md, that is what this run exists to catch."
