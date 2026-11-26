# Shared helpers for the pynq150 non-project Vivado flow.

proc pynq150_info {msg} {
    puts "INFO: pynq150: $msg"
}

# Return {wns whs} from the current open design.
proc pynq150_timing_slacks {} {
    set sp [get_timing_paths -setup -max_paths 1 -quiet]
    set hp [get_timing_paths -hold  -max_paths 1 -quiet]
    set wns "NA"
    set whs "NA"
    if {[llength $sp]} {
        set wns [get_property SLACK $sp]
    }
    if {[llength $hp]} {
        set whs [get_property SLACK $hp]
    }
    return [list $wns $whs]
}

# Cap Vivado threads so a build is polite on a shared workstation.
if {[info exists ::env(VIVADO_MAX_THREADS)]} {
    set_param general.maxThreads $::env(VIVADO_MAX_THREADS)
} else {
    set_param general.maxThreads 4
}
