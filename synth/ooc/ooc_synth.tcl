# ooc_synth.tcl — generic out-of-context synthesis + Fmax/area probe.
#   vivado -mode batch -source ooc_synth.tcl -tclargs <top> <part> <period_ns> <outdir> <src1> [src2 ...]
# Free Vivado ML Standard: use a supported UltraScale+ proxy part (same LUT6/RAMB36/DSP48E2
# fabric as the F1 xcvu9p). Reports go to <outdir>/<top>_{util,timing,summary}.rpt.

if {$argc < 5} { puts "ERROR: need <top> <part> <period_ns> <outdir> <src...>"; exit 2 }
set top     [lindex $argv 0]
set part    [lindex $argv 1]
set period  [lindex $argv 2]
set outdir  [lindex $argv 3]
set srcs    [lrange $argv 4 end]
file mkdir $outdir

puts "=== OOC synth: top=$top part=$part period=${period}ns ==="
foreach f $srcs {
    puts "  read_verilog -sv $f"
    read_verilog -sv $f
}

# out_of_context: no I/O buffers, keeps the module's internal timing honest.
synth_design -top $top -part $part -mode out_of_context

# constrain the clock so timing paths are reported; all modules name the clock `clk`.
if {[llength [get_ports -quiet clk]] > 0} {
    create_clock -name clk -period $period [get_ports clk]
} else {
    puts "WARN: no port named clk; Fmax will be meaningless"
}

report_utilization       -file $outdir/${top}_util.rpt
report_timing_summary -delay_type max -max_paths 20 -file $outdir/${top}_timing.rpt

# ---- headline numbers ----
set wns 0.0
set tp [get_timing_paths -max_paths 1 -nworst 1 -setup -quiet]
if {[llength $tp] > 0} { set wns [get_property SLACK $tp] }
set fmax "n/a"
if {$wns != ""} { catch { set fmax [format "%.1f" [expr {1000.0/($period - $wns)}]] } }

proc ncells {pat} { return [llength [get_cells -hier -quiet -filter "REF_NAME =~ $pat"]] }
set lut    [ncells LUT*]
set ff     [ncells FD*]
set bram36 [ncells RAMB36*]
set bram18 [ncells RAMB18*]
set uram   [ncells URAM*]
set dsp    [ncells DSP*]

set fh [open $outdir/${top}_summary.rpt w]
foreach line [list \
  "MODULE   : $top" \
  "PART     : $part" \
  "CLK PER  : ${period} ns  (target [format %.1f [expr {1000.0/$period}]] MHz)" \
  "WNS      : $wns ns" \
  "EST FMAX : $fmax MHz" \
  "LUT      : $lut" \
  "FF       : $ff" \
  "RAMB36   : $bram36" \
  "RAMB18   : $bram18" \
  "URAM     : $uram" \
  "DSP      : $dsp" ] {
    puts $line
    puts $fh $line
}
close $fh
puts "=== wrote $outdir/${top}_summary.rpt ==="
