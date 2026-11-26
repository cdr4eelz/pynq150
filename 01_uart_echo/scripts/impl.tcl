# Place and route from a post-synth checkpoint.
# Usage: impl.tcl post_synth.dcp out_dir
if {$argc < 2} {
    puts "ERROR: usage: impl.tcl post_synth.dcp out_dir"
    exit 1
}

source [file join [file dirname [info script]] common.tcl]

set dcp     [file normalize [lindex $argv 0]]
set out_dir [file normalize [lindex $argv 1]]
file mkdir $out_dir

puts "INFO: pynq150: open_checkpoint $dcp"
open_checkpoint $dcp

opt_design
place_design
phys_opt_design
route_design

write_checkpoint -force [file join $out_dir post_route.dcp]
report_utilization    -file [file join $out_dir util.rpt]
report_timing_summary -file [file join $out_dir timing.rpt]
report_drc            -file [file join $out_dir drc.rpt]
report_clocks         -file [file join $out_dir clocks.rpt]

lassign [pynq150_timing_slacks] wns whs
puts "INFO: pynq150: post-route WNS=$wns WHS=$whs"
puts "INFO: pynq150: wrote [file join $out_dir post_route.dcp]"
