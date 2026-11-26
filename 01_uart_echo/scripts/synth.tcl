source [file join [file dirname [info script]] common.tcl]

# Synthesize the design (non-project).
# Usage: synth.tcl part top out_dir xdc sources.f rtl0 [rtl1 ...]
if {$argc < 6} {
    puts "ERROR: usage: synth.tcl part top out_dir xdc sources.f rtl..."
    exit 1
}

set part    [lindex $argv 0]
set top     [lindex $argv 1]
set out_dir [file normalize [lindex $argv 2]]
set xdc     [file normalize [lindex $argv 3]]
set src_f   [file normalize [lindex $argv 4]]
set rtl     [lrange $argv 5 end]

file mkdir $out_dir

set vs [list]
foreach v $rtl {
    lappend vs [file normalize $v]
}
set fh [open $src_f r]
while {[gets $fh line] >= 0} {
    set line [string trim $line]
    if {$line eq "" || [string match "#*" $line]} {
        continue
    }
    lappend vs $line
}
close $fh

puts "INFO: pynq150: synth_design top=$top part=$part"
create_project -in_memory -part $part
set_property target_language Verilog [current_project]

foreach v $vs {
    puts "INFO: pynq150: read_verilog $v"
    read_verilog $v
}
read_xdc $xdc

synth_design -top $top -part $part
write_checkpoint -force [file join $out_dir post_synth.dcp]
report_utilization    -file [file join $out_dir util_synth.rpt]
report_timing_summary -file [file join $out_dir timing_synth.rpt]
puts "INFO: pynq150: wrote [file join $out_dir post_synth.dcp]"
