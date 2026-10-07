# postsynth.ps1 -- run the whole post-synthesis check with one short command.
#
#   .\postsynth.ps1
#
# Exists because the individual commands are long enough to be awkward to copy and
# retype. Everything it does is also documented in synth/postsynth/README.md.
#
# Steps:
#   0. synthesize bsw_top_flat at N_PE=16 and write the funcsim netlist
#   1. print the compact summary
#   2. simulate that netlist in XSIM against 200 real E. coli extensions
#   3. compare the netlist's outputs against the committed Verilator reference
#
# N_PE=16 is the smallest LEGAL array (bsw_max_tracker needs N_PE >= 2**MIDLEV = 16)
# and the smallest likely to fit XSIM's BASIC licence cap of 50,000 instances. The
# 160-PE netlist has 166,514 and is refused.

param(
  [string]$VivadoBin = "D:\AMD_Vivado\2026.1\Vivado\bin",
  [int]$Npe          = 16,
  [string]$Part      = "xcku5p-ffvb676-2-e",
  [switch]$SkipSynth,
  # Passed through: stop leftover simulator processes that hold a lock on
  # xsimk.exe, and/or wipe the simulation work directory first.
  [switch]$KillStray,
  [switch]$Clean
)
$ErrorActionPreference = "Stop"
$repo = $PSScriptRoot
Set-Location $repo

$vivado = Join-Path $VivadoBin "vivado.bat"
if (-not (Test-Path $vivado)) {
  throw "vivado.bat not found at $vivado`nPass the right path: .\postsynth.ps1 -VivadoBin <dir>"
}

$vec = "sim/xsim/vectors/vec_ecoli_qlen$Npe.txt"
if (-not (Test-Path (Join-Path $repo $vec))) {
  throw ("no vector set for N_PE=$Npe at $vec`n" +
         "Generate one: python scripts/filter_vectors_by_qlen.py <src> $vec $Npe 200")
}

if (-not $SkipSynth) {
  Write-Host "`n################ STEP 0: synthesize at N_PE=$Npe ################" -ForegroundColor Cyan
  & $vivado -mode batch -source synth/postsynth/synth_and_netlist.tcl -tclargs $Part bsw_top_flat $Npe
  if ($LASTEXITCODE -ne 0) { throw "vivado failed ($LASTEXITCODE)" }
}

$summary = Join-Path $repo "synth\postsynth\out\step0_summary.txt"
if (-not (Test-Path $summary)) {
  throw ("no step0_summary.txt -- synthesis did not succeed.`n" +
         "The full console output is in vivado.log in this directory.")
}
Write-Host "`n################ STEP 0 SUMMARY ################" -ForegroundColor Cyan
Get-Content $summary

Write-Host "`n################ STEP 2: simulate the netlist ################" -ForegroundColor Cyan
$step2 = @{ VivadoBin = $VivadoBin; Vec = $vec }
if ($KillStray) { $step2['KillStray'] = $true }
if ($Clean)     { $step2['Clean']     = $true }
& (Join-Path $repo "sim\xsim\run_postsynth_bsw.ps1") @step2

$dump = "sim/xsim/xsim_postsynth_work/postsynth_vec_ecoli_qlen$Npe.txt"
$ref  = "sim/xsim/reference/verilator_ecoli_qlen$Npe.txt"
Write-Host "`n################ STEP 3: netlist vs RTL ################" -ForegroundColor Cyan
if (-not (Test-Path (Join-Path $repo $dump))) {
  throw "no dump at $dump -- the simulation did not reach the testbench"
}
& python scripts/compare_dumps.py $ref $dump
$cmp = $LASTEXITCODE

Write-Host ""
if ($cmp -eq 0) {
  Write-Host "RESULT: the synthesized netlist matches the RTL on every field." -ForegroundColor Green
} else {
  Write-Host "RESULT: differences found -- see the comparison above." -ForegroundColor Yellow
}
exit $cmp
