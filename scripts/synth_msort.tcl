# synth_msort.tcl — Quartus Prime Pro synthesis + fit + timing for the
# alignment-register merge-sorter. Produces ALM/M20K usage and Fmax.
#
# Usage (from repo root, with Quartus on PATH):
#   quartus_sh -t scripts/synth_msort.tcl
#   quartus_sh -t scripts/synth_msort.tcl 1SX280HU2F50E2VG   ;# override device
#
# Default device is a Stratix 10 (the project's primary target; see
# docs/speedup_plan.md). Reports land in build/msort/ and a summary is printed.

load_package flow

set device  [expr {$argc > 0 ? [lindex $argv 0] : "1SM21BHU2F53E1VG"}] ;# Stratix 10 MX (DE10-Pro)
set family  "Stratix 10"
set top     "msort_merge_sorter"
set bdir    "build/msort"

file mkdir $bdir
project_new $top -overwrite -directory $bdir

set_global_assignment -name FAMILY $family
set_global_assignment -name DEVICE $device
set_global_assignment -name TOP_LEVEL_ENTITY $top

# RTL (package first) + constraints. Paths are relative to repo root.
set_global_assignment -name SYSTEMVERILOG_FILE [file normalize rtl/msort_pkg.sv]
set_global_assignment -name SYSTEMVERILOG_FILE [file normalize rtl/msort_merge_sorter.sv]
set_global_assignment -name SDC_FILE           [file normalize scripts/msort.sdc]
set_global_assignment -name SEARCH_PATH        [file normalize rtl]

# Push for performance so the reported Fmax reflects the design, not effort.
set_global_assignment -name OPTIMIZATION_MODE "HIGH PERFORMANCE EFFORT"

# Full compile: analysis & synthesis -> fit -> timing -> assembler.
execute_flow -compile

# ---- Summary -----------------------------------------------------------------
load_package report
project_open $top -current_revision

puts "============================================================"
puts " merge-sorter synthesis summary  (device $device)"
puts "============================================================"

# Resource usage (Fitter resource summary)
if {[catch {
    load_report
    set rpt "Fitter||Fitter Resource Usage Summary"
    foreach key {"Logic utilization" "ALMs needed" "Total RAM Blocks" "M20K blocks" "Total block memory bits" "Total registers"} {
        catch {
            set v [get_report_panel_data -name "Fitter||Resource||Fitter Resource Usage Summary" -row_name $key -col 1]
            puts [format "  %-26s %s" $key $v]
        }
    }
} err]} { puts "  (resource panel parse skipped: $err)" }

# Fmax (Slow 1100mV corner Fmax summary)
if {[catch {
    set panels [get_report_panel_names]
    foreach p $panels {
        if {[string match "*Fmax Summary*" $p]} {
            set rows [get_number_of_rows -name $p]
            for {set r 1} {$r < $rows} {incr r} {
                set fmax [get_report_panel_data -name $p -row $r -col 1]
                set clk  [get_report_panel_data -name $p -row $r -col 3]
                puts [format "  Fmax %-12s %s" $clk $fmax]
            }
        }
    }
} err]} { puts "  (Fmax panel parse skipped: $err — see $bdir timing report)" }

puts "============================================================"
puts " Full reports: $bdir/output_files/  (*.fit.rpt, *.sta.rpt)"
project_close
