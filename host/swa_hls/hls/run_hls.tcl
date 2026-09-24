# ---------------------------------------------------------------------------
# run_hls.tcl -- C-sim, synthesis and co-simulation of the banded SWA
#                extension kernel (ksw_extend_top).
#
# 2024.1+ unified flow (no standalone vitis_hls executable):
#   & D:/AMD_Vivado/2026.1/Vitis/bin/vitis-run.bat --mode hls --tcl run_hls.tcl
#
# Classic flow, if a vitis_hls executable exists:
#   vitis_hls -f run_hls.tcl
#
# This script detects which command set is available and uses it, so the same
# file works either way. Run it from inside this directory; use FORWARD slashes
# in any path you pass to Tcl (backslashes get eaten).
#
# Overrides, via environment variables:
#   KSW_PART    target part      (default: the KU5P UltraScale+ proxy)
#   KSW_PERIOD  clock period ns  (default: 8.0 = 125 MHz, the CDC kernel domain)
#   KSW_STAGE   csim | csynth | cosim | all   (default: all)
# ---------------------------------------------------------------------------

# The real F2 target is xcvu47p-fsvh2892-2-e. The default here is the
# UltraScale+ -2 proxy already used for the bsw_top timing run, because it is
# known to be installed; set KSW_PART to the VU47P once that device is present.
set PART   {xcku5p-ffvb676-2-e}
set PERIOD 8.0
set TOP    ksw_extend_top
set COMP   ksw_extend
set STAGE  all

if {[info exists ::env(KSW_PART)]}   { set PART   $::env(KSW_PART) }
if {[info exists ::env(KSW_PERIOD)]} { set PERIOD $::env(KSW_PERIOD) }
if {[info exists ::env(KSW_STAGE)]}  { set STAGE  $::env(KSW_STAGE) }

set CFLAGS "-I. -I.."

puts "=========================================================="
puts " ksw_extend_top : HLS run"
puts "   part   : $PART"
puts "   period : $PERIOD ns"
puts "   stage  : $STAGE"
puts "=========================================================="

set unified [llength [info commands open_component]]
if {$unified} {
    puts "flow: unified (open_component)"
    open_component -reset $COMP -flow_target vivado
    set_part $PART
    create_clock -period $PERIOD -name default
    set_top $TOP
    add_files     ksw_kernel.cpp -cflags $CFLAGS
    add_files -tb tb_ksw_hls.cpp -cflags $CFLAGS
} else {
    puts "flow: classic (open_project/open_solution)"
    open_project -reset $COMP
    set_top $TOP
    add_files     ksw_kernel.cpp -cflags $CFLAGS
    add_files -tb tb_ksw_hls.cpp -cflags $CFLAGS
    open_solution -reset sol1 -flow_target vivado
    set_part $PART
    create_clock -period $PERIOD -name default
}

set csim_ok   "skipped"
set csynth_ok "skipped"
set cosim_ok  "skipped"

# ---- C simulation: the kernel compiled as C++, against the golden vectors ----
if {$STAGE eq "all" || $STAGE eq "csim"} {
    puts "\n---- csim_design ----"
    if {[catch {csim_design} msg]} {
        set csim_ok "FAIL"
        puts "csim FAILED: $msg"
    } else {
        set csim_ok "PASS"
    }
}

# ---- synthesis: C++ to RTL ----
if {($STAGE eq "all" || $STAGE eq "csynth" || $STAGE eq "cosim") && $csim_ok ne "FAIL"} {
    puts "\n---- csynth_design ----"
    if {[catch {csynth_design} msg]} {
        set csynth_ok "FAIL"
        puts "csynth FAILED: $msg"
    } else {
        set csynth_ok "PASS"
    }
}

# ---- co-simulation: the SAME testbench against the generated RTL ----
# This is the step that proves the hardware, not just the C++, is bit-exact.
# -trace_level none keeps it fast; switch to all if a waveform is needed.
if {($STAGE eq "all" || $STAGE eq "cosim") && $csynth_ok eq "PASS"} {
    puts "\n---- cosim_design (this is the slow one) ----"
    if {[catch {cosim_design -rtl verilog -trace_level none} msg]} {
        set cosim_ok "FAIL"
        puts "cosim FAILED: $msg"
    } else {
        set cosim_ok "PASS"
    }
}

# ---- pull the numbers out of the synthesis report ----
set rpt ""
foreach cand [list \
        [file join $COMP hls syn report ${TOP}_csynth.rpt] \
        [file join $COMP sol1 syn report ${TOP}_csynth.rpt]] {
    if {[file exists $cand]} { set rpt $cand; break }
}
if {$rpt eq ""} {
    set hits [glob -nocomplain [file join $COMP * syn report ${TOP}_csynth.rpt]]
    if {[llength $hits]} { set rpt [lindex $hits 0] }
}

puts "\n=========================================================="
puts " RESULT"
puts "   csim   : $csim_ok"
puts "   csynth : $csynth_ok"
puts "   cosim  : $cosim_ok"
if {$rpt ne ""} {
    puts "   report : $rpt"
    set fh [open $rpt r]
    set txt [read $fh]
    close $fh
    foreach line [split $txt "\n"] {
        set keep 0
        # section headers and the resource totals row
        if {[string match "*Latency*" $line] || [string match "*Total*" $line] ||
            [string match "*LUT*" $line]     || [string match "*FF*" $line]} { set keep 1 }
        # a table row carrying actual numbers (the latency figures live here)
        if {[regexp {^\s*\|[^|]*\d+[^|]*\|} $line]} { set keep 1 }
        # separator rows are noise
        if {[regexp {^\s*\+[-+]*\+\s*$} $line]} { set keep 0 }
        if {$keep} { puts "   | [string trim $line]" }
    }
} else {
    puts "   report : not found"
}

set overall "PASS"
foreach s [list $csim_ok $csynth_ok $cosim_ok] {
    if {$s eq "FAIL"} { set overall "FAIL" }
}
puts "   OVERALL: $overall"
puts "=========================================================="

if {$overall eq "FAIL"} { exit 1 }
exit 0
