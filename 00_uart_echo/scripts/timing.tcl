# Print and save a timing summary from the post-route checkpoint.
# Usage: timing.tcl post_route.dcp report_file
if {$argc < 2} {
    puts "ERROR: usage: timing.tcl post_route.dcp report_file"
    exit 1
}

source [file join [file dirname [info script]] common.tcl]

set dcp [file normalize [lindex $argv 0]]
set rpt [file normalize [lindex $argv 1]]
file mkdir [file dirname $rpt]

open_checkpoint $dcp
report_timing_summary -file $rpt
lassign [pynq150_timing_slacks] wns whs
puts "INFO: pynq150: timing summary written to $rpt"
puts "INFO: pynq150: WNS=$wns ns  WHS=$whs ns"
if {$wns eq "NA" || $whs eq "NA" || $wns < 0 || $whs < 0} {
    puts "ERROR: pynq150: timing NOT met (WNS=$wns WHS=$whs)"
    exit 1
}
puts "INFO: pynq150: timing met"
