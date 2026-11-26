source [file join [file dirname [info script]] common.tcl]

# Generate one IP core from a Tcl script and write a Verilog source list.
# Usage: vivado -mode batch -source ip.tcl -tclargs <part> <ip.tcl> <out_dir>
if {$argc < 3} {
    puts "ERROR: usage: ip.tcl part ip_tcl out_dir"
    exit 1
}

set part    [lindex $argv 0]
set ip_tcl  [file normalize [lindex $argv 1]]
set out_dir [file normalize [lindex $argv 2]]

file mkdir $out_dir
set proj_dir [file join $out_dir ipwork]

puts "INFO: pynq150: generating IP from $ip_tcl for part $part"
create_project -force ipwork $proj_dir -part $part
set_property target_language Verilog [current_project]

source $ip_tcl

set ips [get_ips]
if {[llength $ips] == 0} {
    error "No IP created by $ip_tcl"
}

generate_target {synthesis instantiation_template} $ips

set src_f [file join $out_dir sources.f]
set fh [open $src_f w]
set n 0
foreach ip $ips {
    foreach f [get_files -compile_order sources -used_in synthesis -of_objects $ip] {
        set ext [string tolower [file extension $f]]
        if {$ext eq ".v" || $ext eq ".sv" || $ext eq ".vh" || $ext eq ".svh"} {
            # Skip stubs and sim netlists if they sneak in.
            set bn [file tail $f]
            if {[string match "*_stub.*" $bn] || [string match "*_sim_netlist.*" $bn]} {
                continue
            }
            puts $fh [file normalize $f]
            incr n
        }
    }
}
close $fh

if {$n == 0} {
    error "IP generate_target produced no synthesis Verilog (see sources.f empty)"
}

puts "INFO: pynq150: wrote $n synthesis source(s) to $src_f"
close_project
