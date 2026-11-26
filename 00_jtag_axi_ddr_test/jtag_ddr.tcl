# usage: vivado -mode batch -source jtag_ddr.tcl -tclargs <hexaddr>
set addr [lindex $argv 0]
set ltx [file normalize [file join [file dirname [info script]] .. build ddr_jtag_axi ddrjtag.ltx]]
set N 256
open_hw
connect_hw_server -url localhost:3121
set tgts [get_hw_targets]
puts "TARGETS: $tgts"
set t [lsearch -inline -glob $tgts {*1234-tul*}]
if {$t eq ""} { puts "ERROR: no TUL target found; aborting"; exit 1 }
if {[string match {*00000000000000*} $t]} { puts "ERROR: refusing XUPV5"; exit 1 }
puts "USING TARGET: $t"
current_hw_target $t
open_hw_target
set d [lsearch -inline -glob [get_hw_devices] {xc7z020*}]
if {$d eq ""} { puts "ERROR: no xc7z020 on TUL target"; close_hw_target; exit 1 }
current_hw_device $d
# NO program_hw_devices: PL was loaded by PYNQ Overlay from Linux
set_property PROBES.FILE $ltx $d
refresh_hw_device $d
set axi [get_hw_axis]
puts "HW_AXIS: $axi"
if {$axi eq ""} { puts "ERROR: no hw_axi found"; close_hw_target; exit 1 }
reset_hw_axi $axi
# word i at addr+4i = 0xA5000000+i ; Vivado -data lists the LAST beat first (MSW left)
set words {}
for {set i [expr {$N-1}]} {$i >= 0} {incr i -1} { lappend words [format %08X [expr {0xA5000000 + $i}]] }
set wdata [join $words _]
create_hw_axi_txn wr [get_hw_axis $axi] -type write -address $addr -len $N -size 32 -burst INCR -data $wdata -force
run_hw_axi [get_hw_axi_txns wr]
create_hw_axi_txn rd [get_hw_axis $axi] -type read -address $addr -len $N -size 32 -burst INCR -force
run_hw_axi [get_hw_axi_txns rd]
set rdata [get_property DATA [get_hw_axi_txns rd]]
set r [string map {_ ""} $rdata]
set w [string map {_ ""} $wdata]
puts "READ_HEAD: [string range $r 0 31] ... READ_TAIL: [string range $r end-31 end]"
puts "WRITE_HEAD: [string range $w 0 31] ... WRITE_TAIL: [string range $w end-31 end]"
if {[string equal -nocase $r $w]} { puts "JTAG_COMPARE: PASS ($N words)" } else {
  set nbad 0
  for {set i 0} {$i < $N} {incr i} { if {![string equal -nocase [string range $r [expr 8*$i] [expr 8*$i+7]] [string range $w [expr 8*$i] [expr 8*$i+7]]]} {incr nbad} }
  puts "JTAG_COMPARE: FAIL ($nbad of $N words differ)"
}
close_hw_target
disconnect_hw_server
exit 0
