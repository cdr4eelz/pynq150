# Non-project synth+impl+bit for uart_buffer_top.
# Usage: build_pl.tcl part top out_dir xdc sources.f rtl0 [rtl1 ...]
# Does not program a board.
if {$argc < 6} {
    puts "ERROR: usage: build_pl.tcl part top out_dir xdc sources.f rtl..."
    exit 1
}
set part    [lindex $argv 0]
set top     [lindex $argv 1]
set out_dir [file normalize [lindex $argv 2]]
set xdc     [file normalize [lindex $argv 3]]
set src_f   [file normalize [lindex $argv 4]]
set rtl     [lrange $argv 5 end]

file mkdir [file join $out_dir synth]
file mkdir [file join $out_dir impl]

set vs [list]
foreach v $rtl { lappend vs [file normalize $v] }
set fh [open $src_f r]
while {[gets $fh line] >= 0} {
    set line [string trim $line]
    if {$line eq "" || [string match "#*" $line]} { continue }
    lappend vs $line
}
close $fh

create_project -in_memory -part $part
set_property target_language Verilog [current_project]
foreach v $vs {
    puts "INFO: read_verilog $v"
    read_verilog $v
}
read_xdc $xdc
synth_design -top $top -part $part
write_checkpoint -force [file join $out_dir synth post_synth.dcp]
opt_design
place_design
route_design
write_checkpoint -force [file join $out_dir impl post_route.dcp]
report_utilization    -file [file join $out_dir impl util.rpt]
report_timing_summary -file [file join $out_dir impl timing.rpt]
write_bitstream -force [file join $out_dir uart_buffer.bit]
puts "INFO: wrote [file join $out_dir uart_buffer.bit]"
