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

# ---------------------------------------------------------------------------
# STALE-NETLIST GUARD.
#
# A failed synthesis leaves the PREVIOUS netlist on disk, and simulating that is
# worse than not simulating at all -- it looks like a verification result for
# sources it was not built from. This bit us for real: an N_PE=8 synthesis died in
# bsw_max_tracker, write_verilog never ran, and this script then re-simulated the
# stale 160-PE netlist and reported its 166,514 instances, exactly as if the
# reduction had silently failed to apply.
#
# synth_and_netlist.tcl deletes the netlist and this marker BEFORE synthesising and
# rewrites them only on success, so a present, newer-than-sources marker means the
# netlist really does correspond to the current RTL.
# ---------------------------------------------------------------------------
$infoPath = Join-Path (Split-Path $netlistPath) "netlist_info.txt"
if (-not (Test-Path $infoPath)) {
  throw ("no netlist_info.txt beside the netlist: $infoPath`n" +
         "That marker is written only by a SUCCESSFUL synthesis, so the netlist on " +
         "disk is stale or was produced before this guard existed.`n" +
         "Re-run STEP 0: vivado -mode batch -source synth/postsynth/synth_and_netlist.tcl")
}
$info = @{}
Get-Content $infoPath | ForEach-Object {
  if ($_ -match '^\s*([^=]+)=(.*)$') { $info[$matches[1].Trim()] = $matches[2].Trim() }
}
Write-Host "netlist built: top=$($info['top']) N_PE=$($info['npe']) part=$($info['part']) at $($info['written'])"

# The netlist must be newer than every source it was built from.
$srcs = @(
  (Join-Path $repo "synth\postsynth\bsw_top_flat.sv")
) + (Get-ChildItem (Join-Path $repo "rtl") -Filter "bsw_*.sv" | ForEach-Object { $_.FullName })
$netTime = (Get-Item $netlistPath).LastWriteTime
$newer = $srcs | Where-Object { (Test-Path $_) -and ((Get-Item $_).LastWriteTime -gt $netTime) }
if ($newer) {
  Write-Host ""
  Write-Host "SOURCES NEWER THAN THE NETLIST:" -ForegroundColor Yellow
  $newer | ForEach-Object { Write-Host "  $_" }
  throw "the netlist predates the RTL above; re-run STEP 0 before simulating it"
}

# N_PE decides the largest qlen the array can accept. A vector with a longer query
# is REJECTED by bsw_ctrl_fsm (error=1), so every record would fail for a reason
# that has nothing to do with synthesis. Check before burning a gate-level run.
$npe = 0
if (-not [int]::TryParse($info['npe'], [ref]$npe)) { $npe = 0 }

# Vector and dump paths go into Verilog $fopen through a plusarg, where a backslash
# is an escape character -- so forward slashes only.
$vecPath = (Join-Path $repo $Vec)
if (-not (Test-Path $vecPath)) { throw "vector file not found: $vecPath" }
$vecFwd = (Resolve-Path $vecPath).Path -replace '\\','/'
$n = (Get-Content $vecFwd -First 1)

if ($npe -gt 0) {
  # Field 2 of each record header is qlen; records are 3 lines each after the count.
  $maxQ = 0; $i = 1
  $vlines = Get-Content $vecPath
  while ($i -lt $vlines.Count) {
    $f = ($vlines[$i] -split '\s+') | Where-Object { $_ -ne '' }
    if ($f.Count -ge 2) { $q = [int]$f[1]; if ($q -gt $maxQ) { $maxQ = $q } }
    $i += 3
  }
  Write-Host "max qlen in vectors: $maxQ   (array accepts qlen <= $npe)"
  if ($maxQ -gt $npe) {
    throw ("these vectors need qlen up to $maxQ but the netlist was built with " +
           "N_PE=$npe, so bsw_ctrl_fsm would REJECT the longer records (error=1) " +
           "and every one would fail for reasons unrelated to synthesis.`n" +
           "Use a filtered set, e.g. " +
           "python scripts/filter_vectors_by_qlen.py <src> <dst> $npe 200")
  }
}

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
  # xsim's exit code is NOT a reliable success signal: when it refused to start over
  # the BASIC licence instance cap it printed ERROR and still exited 0, so the
  # original check passed and this script went on to print success guidance. Capture
  # the output and judge it on content as well.
  $xout = & "$VivadoBin\xsim.bat" "${Top}_ps" -runall -f $optsFile 2>&1
  $xout | ForEach-Object { Write-Host $_ }
  $sw.Stop()
  if ($LASTEXITCODE -ne 0) { throw "xsim failed ($LASTEXITCODE)" }
  if ($xout -match 'does not meet the requirement to run the number of instances') {
    throw ("xsim refused the design: the BASIC simulator licence caps instances at " +
           "50,000. Rebuild the netlist with a smaller N_PE (see " +
           "synth/postsynth/README.md) -- the error line above prints the exact count.")
  }
  if ($xout -match 'Could not obtain the necessary license|Simulation engine failed to start|^ERROR:') {
    throw "xsim reported an error (see output above) despite exit code $LASTEXITCODE"
  }
  if (-not (Test-Path $dumpFwd)) {
    throw "xsim produced no dump file at $dumpFwd -- the run did not reach the testbench"
  }
  $summary = $xout | Select-String -Pattern "${Top}: .* extensions" | Select-Object -First 1
  if (-not $summary) { throw "no summary line from the testbench -- the run did not complete" }
  Write-Host ""
  Write-Host "SUMMARY: $summary"
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
