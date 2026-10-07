# run_postsynth_bsw.ps1 -- STEP 2: simulate the SYNTHESIZED NETLIST in XSIM.
#
# This is the closest functional proxy for the FPGA that can be reached without a
# board. What it simulates is not the SystemVerilog any more -- it is the Verilog
# netlist that Vivado synthesis actually produced: LUT6, FDRE, CARRY8, DSP48E2
# primitives. If that reproduces bwa-mem2's score/qle/tle, the whole class of
# "simulates fine, builds into different hardware" is ruled out.
#
# PREREQUISITE -- run STEP 0 first, which writes the netlist:
#   vivado -mode batch -source synth/postsynth/synth_and_netlist.tcl
#
# Usage, from the repo root:
#   .\sim\xsim\run_postsynth_bsw.ps1
#   .\sim\xsim\run_postsynth_bsw.ps1 -Vec sim/xsim/vectors/vec_ecoli_20.txt
#   .\sim\xsim\run_postsynth_bsw.ps1 -VivadoBin D:\AMD_Vivado\2026.1\Vivado\bin
#
# START SMALL. Gate-level simulation is orders of magnitude slower than Verilator
# (which does 10,000 extensions in ~7.5 min). Run vec_ecoli_5 first to confirm the
# flow works end to end, then 20, then 200. Do NOT start with the full 10,000 set:
# that is days of wall-clock and it answers nothing extra, because netlist-vs-RTL
# divergence is structural and shows up on almost any vector.
#
# NOTE: as written this has not been executed -- there is no Vivado on the machine
# it was authored on. Expect to fix something. docs/rtl_xsim_runbook.md covers the
# behavioral-sim failure modes, most of which apply here too.

param(
  [string]$VivadoBin = "D:\AMD_Vivado\2026.1\Vivado\bin",
  [string]$Vec       = "sim/xsim/vectors/vec_ecoli_5.txt",
  [string]$Netlist   = "synth/postsynth/out/bsw_top_flat_funcsim.v",
  [string]$Top       = "tb_bsw_ext_flat",
  [string]$Dump      = ""
)
$ErrorActionPreference = "Stop"

$repo = (Resolve-Path "$PSScriptRoot\..\..").Path
$work = Join-Path $PSScriptRoot "xsim_postsynth_work"
New-Item -ItemType Directory -Force -Path $work | Out-Null

$netlistPath = Join-Path $repo $Netlist
if (-not (Test-Path $netlistPath)) {
  throw "netlist not found: $netlistPath`nRun STEP 0 first: vivado -mode batch -source synth/postsynth/synth_and_netlist.tcl"
}

# Vector and dump paths go into Verilog $fopen through a plusarg, where a backslash
# is an escape character -- so forward slashes only.
$vecPath = (Join-Path $repo $Vec)
if (-not (Test-Path $vecPath)) { throw "vector file not found: $vecPath" }
$vecFwd = (Resolve-Path $vecPath).Path -replace '\\','/'
$n = (Get-Content $vecFwd -First 1)

if ($Dump -eq "") { $Dump = "postsynth_$([System.IO.Path]::GetFileNameWithoutExtension($Vec)).txt" }
$dumpFwd = (Join-Path $work $Dump) -replace '\\','/'

Write-Host "netlist : $netlistPath ($([math]::Round((Get-Item $netlistPath).Length/1MB,1)) MB)"
Write-Host "vectors : $vecFwd  ($n extensions)"
Write-Host "dump    : $dumpFwd"

Push-Location $work
try {
  # 1. The package and the testbench are SystemVerilog. Compile them separately
  #    from the netlist, which is plain Verilog -- mixing -sv onto a funcsim
  #    netlist is a common source of spurious errors.
  Write-Host "`n== 1/4 xvlog: package + testbench (SystemVerilog) =="
  & "$VivadoBin\xvlog.bat" -sv -i "$repo\rtl" "$repo\rtl\bsw_pkg.sv" "$repo\tb\$Top.sv"
  if ($LASTEXITCODE -ne 0) { throw "xvlog (SV) failed ($LASTEXITCODE)" }

  # 2. The netlist. NOTE: rtl/*.sv is deliberately NOT compiled here. Compiling
  #    both the RTL and the netlist would define bsw_top_flat twice and the
  #    elaborator would silently bind whichever it saw last -- which could mean
  #    "passing" a post-synthesis run that never touched the netlist.
  Write-Host "`n== 2/4 xvlog: funcsim netlist (Verilog) =="
  & "$VivadoBin\xvlog.bat" $netlistPath
  if ($LASTEXITCODE -ne 0) { throw "xvlog (netlist) failed ($LASTEXITCODE)" }

  # 3. glbl supplies GSR/GTS, which a funcsim netlist's primitives expect. The
  #    unisims_ver / secureip libraries supply the primitive models themselves.
  Write-Host "`n== 3/4 xelab (elaborate netlist + glbl) =="
  & "$VivadoBin\xelab.bat" $Top glbl -s "${Top}_ps" --timescale 1ns/1ps -O0 -relax -L unisims_ver -L unisim -L secureip
  if ($LASTEXITCODE -ne 0) { throw "xelab failed ($LASTEXITCODE)" }

  # Pass the plusargs through an OPTIONS FILE, not on the command line.
  #
  # WHY: xsim.bat is a batch wrapper, and cmd.exe treats "=" as a token delimiter
  # when it parses a batch file's arguments. So `-testplusarg VEC=C:/path` arrives
  # as THREE tokens -- `-testplusarg`, `VEC`, and a bare `C:/path` -- and xsim
  # rejects it with:
  #     Expected a switch but found C
  # Quoting does not reliably survive the PowerShell -> cmd -> exe hop. xsim's own
  # documented `-f` switch reads options from a file, which cmd never tokenizes, so
  # paths with drive letters and "=" pass through intact.
  # Only the plusargs go in the file -- those are the tokens containing "=".
  # -runall stays on the command line, where it is safe (no "=" to tokenize on) and
  # where it does not depend on the options file accepting run-control switches.
  $optsFile = Join-Path $work "xsim_opts.txt"
  @(
    "-testplusarg VEC=$vecFwd"
    "-testplusarg DUMP=$dumpFwd"
  ) | Set-Content -Path $optsFile -Encoding ASCII
  Write-Host "`nxsim options file:"
  Get-Content $optsFile | ForEach-Object { Write-Host "  $_" }

  Write-Host "`n== 4/4 xsim (run) -- gate level, be patient =="
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  & "$VivadoBin\xsim.bat" "${Top}_ps" -runall -f $optsFile
  if ($LASTEXITCODE -ne 0) { throw "xsim failed ($LASTEXITCODE)" }
  $sw.Stop()
  Write-Host "`nsim wall-clock: $([math]::Round($sw.Elapsed.TotalSeconds,1)) s for $n extensions"
}
finally { Pop-Location }

Write-Host "`n--------------------------------------------------------------"
Write-Host "Summary line to check: '${Top}: N extensions, M failures'  -- M must be 0."
Write-Host ""
Write-Host "Then compare the netlist's own outputs against the Verilator reference,"
Write-Host "which is the actual point of this run:"
Write-Host ""
$ref = "sim/xsim/reference/verilator_$([System.IO.Path]::GetFileNameWithoutExtension($Vec) -replace '^vec_','').txt"
Write-Host "  python scripts/compare_dumps.py $ref sim/xsim/xsim_postsynth_work/$Dump"
Write-Host ""
Write-Host "Any 'x' in a reported value is an X-propagation finding -- a real result,"
Write-Host "and exactly the kind Verilator is structurally unable to produce."
Write-Host "--------------------------------------------------------------"
