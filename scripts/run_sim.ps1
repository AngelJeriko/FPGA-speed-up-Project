#
# run_sim.ps1 - PowerShell sim driver. Auto-picks the first simulator on PATH.
# Usage:
#   .\run_sim.ps1                 # runs tb_bsw_pe
#   .\run_sim.ps1 -Tb tb_bsw_top  # runs tb_bsw_top
#

param(
    [string]$Tb = "tb_bsw_pe"
)

$ErrorActionPreference = "Stop"
$root   = Split-Path -Parent $PSScriptRoot
$rtlDir = Join-Path $root "rtl"
$tbDir  = Join-Path $root "tb"

$rtlFiles = @(
    "$rtlDir\bsw_pkg.sv",
    "$rtlDir\bsw_score_matrix.sv",
    "$rtlDir\bsw_pe.sv",
    "$rtlDir\bsw_systolic_array.sv",
    "$rtlDir\bsw_max_tracker.sv",
    "$rtlDir\bsw_ctrl_fsm.sv",
    "$rtlDir\bsw_top.sv"
)
$tbFile = Join-Path $tbDir "$Tb.sv"

if (-not (Test-Path $tbFile)) {
    Write-Error "Testbench not found: $tbFile"
}

# 1) Verilator
$verilator = Get-Command verilator -ErrorAction SilentlyContinue
if ($verilator) {
    Write-Output "Using Verilator..."
    $obj = Join-Path $root "obj_$Tb"
    if (Test-Path $obj) { Remove-Item -Recurse -Force $obj }
    $vargs = @("--binary", "--timing", "--top-module", $Tb,
               "--timescale", "1ns/1ps",
               "-Wno-WIDTH", "-Wno-UNOPTFLAT", "-Wno-TIMESCALEMOD",
               "-I$rtlDir", "-Mdir", $obj)
    & verilator @vargs @rtlFiles $tbFile
    if ($LASTEXITCODE -ne 0) { Write-Error "Verilator compile failed" }
    & "$obj\V$Tb"
    exit $LASTEXITCODE
}

# 2) Icarus Verilog
$iverilog = Get-Command iverilog -ErrorAction SilentlyContinue
if ($iverilog) {
    Write-Output "Using Icarus Verilog..."
    $out = Join-Path $root "$Tb.vvp"
    & iverilog -g2012 -o $out -I $rtlDir @rtlFiles $tbFile
    if ($LASTEXITCODE -ne 0) { Write-Error "iverilog compile failed" }
    & vvp $out
    exit $LASTEXITCODE
}

# 3) Questa / ModelSim
$vsim = Get-Command vsim -ErrorAction SilentlyContinue
if ($vsim) {
    Write-Output "Using Questa/ModelSim..."
    $work = Join-Path $root "work"
    if (Test-Path $work) { Remove-Item -Recurse -Force $work }
    & vlib $work
    & vlog -sv +incdir+$rtlDir @rtlFiles $tbFile
    if ($LASTEXITCODE -ne 0) { Write-Error "vlog failed" }
    & vsim -c -do "run -all; quit" $Tb
    exit $LASTEXITCODE
}

Write-Error "No simulator found. Install Verilator, Icarus Verilog, or Questa Intel FPGA."
