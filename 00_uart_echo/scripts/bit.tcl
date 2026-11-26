# Write a bitstream from the post-route checkpoint.
# Usage: bit.tcl post_route.dcp bitfile timing_gate(0|1)
if {$argc < 3} {
    puts "ERROR: usage: bit.tcl post_route.dcp bitfile timing_gate"
    exit 1
}

source [file join [file dirname [info script]] common.tcl]

set dcp  [file normalize [lindex $argv 0]]
set bit  [file normalize [lindex $argv 1]]
set gate [lindex $argv 2]

puts "INFO: pynq150: open_checkpoint $dcp"
open_checkpoint $dcp

lassign [pynq150_timing_slacks] wns whs
puts "INFO: pynq150: pre-bit WNS=$wns WHS=$whs"

if {$gate} {
    if {$wns eq "NA" || $whs eq "NA"} {
        error "Timing slacks unavailable (WNS=$wns WHS=$whs); refusing to write bitstream"
    }
    if {$wns < 0 || $whs < 0} {
        error "Timing not met: WNS=$wns WHS=$whs (override with TIMING_GATE=0)"
    }
}

file mkdir [file dirname $bit]
write_bitstream -force $bit
puts "INFO: pynq150: wrote $bit"
