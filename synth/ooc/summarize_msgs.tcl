# summarize_msgs.tcl - histogram the WARNING / CRITICAL WARNING messages from a Vivado run.
#
#   Tcl Console:  source .../synth/ooc/summarize_msgs.tcl
#   or:           set LOG C:/path/to/vivado.log ; source .../synth/ooc/summarize_msgs.tcl
#
# WHY: a synthesis run that ends "0 errors, 4 critical warnings and 8689 warnings" tells
# you nothing actionable. Vivado has no Tcl API to enumerate messages, and 8689 lines is
# not something anyone reads. But the message IDs collapse: thousands of warnings are
# usually a handful of distinct causes multiplied by instance count (this design has 160
# PEs, so one sloppy line in bsw_pe becomes 160 warnings).
#
# This parses the log, groups by message ID, and prints one example of each - so the
# question becomes "are these 6 causes acceptable?" instead of "are these 8689 lines?".
#
# CRITICAL WARNINGs are printed in full and first: they are few and they are the ones
# that actually bite. Known-benign here is exactly one - Project 1-486, the unresolved
# sh_ddr black box, which is expected because AWS ships that stub with an empty body.

if {![info exists ::LOG]} {
    set cand [list vivado.log [file join [pwd] vivado.log]]
    set ::LOG ""
    foreach c $cand { if {[file exists $c]} { set ::LOG $c ; break } }
    if {$::LOG eq ""} {
        puts "ERROR: no vivado.log found in [pwd]."
        puts "       set LOG C:/path/to/vivado.log   then re-source this script."
        return
    }
}
if {![file exists $::LOG]} { puts "ERROR: no such file: $::LOG" ; return }

set fh [open $::LOG r]
set txt [read $fh]
close $fh

array set cnt {}
array set eg  {}
set crits {}

foreach line [split $txt "\n"] {
    set sev ""
    if {[string match "CRITICAL WARNING:*" $line]} { set sev CRIT }
    if {[string match "WARNING:*" $line]}          { set sev WARN }
    if {$sev eq ""} { continue }
    if {$sev eq "CRIT"} { lappend crits $line }
    set id "(unlabelled)"
    if {[regexp {\[([A-Za-z_]+ [0-9]+-[0-9]+)\]} $line -> m]} { set id $m }
    set key "$sev|$id"
    incr cnt($key)
    if {![info exists eg($key)]} { set eg($key) [string trim $line] }
}

puts ""
puts "#############################################################"
puts "### Message summary for [file tail $::LOG]"
puts "#############################################################"

puts ""
puts "--- CRITICAL WARNINGS ([llength $crits]) - read every one ---"
if {[llength $crits] == 0} {
    puts "    (none)"
} else {
    set i 0
    foreach c $crits {
        incr i
        puts "  $i. [string trim $c]"
    }
}

# Sort warning IDs by count, descending.
set rows {}
foreach key [array names cnt] {
    if {![string match "WARN|*" $key]} { continue }
    lappend rows [list $cnt($key) [string range $key 5 end] $eg($key)]
}
set rows [lsort -integer -decreasing -index 0 $rows]

set total 0
foreach r $rows { incr total [lindex $r 0] }

puts ""
puts "--- WARNINGS grouped by message ID ($total total, [llength $rows] distinct causes) ---"
foreach r $rows {
    lassign $r n id example
    puts ""
    puts [format "  %6d x  %s" $n $id]
    if {[string length $example] > 160} { set example "[string range $example 0 157]..." }
    puts "           e.g. $example"
}
puts ""
puts "#############################################################"
puts "### [llength $rows] distinct warning causes, not $total problems."
puts "### Paste this summary back - it is small enough to actually act on."
puts "#############################################################"
