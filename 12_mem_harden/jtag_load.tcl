# jtag_load.tcl - write MIPS program/data images into the PYNQ-Z2 DDR over JTAG (no Linux, no ARM
# program), so the cs150 MIPS can run them (gios `jal ADDR`). 12_mem_harden.
#
#   xsct jtag_load.tcl ADDR HEXFILE [ADDR HEXFILE ...]
#
# ADDR    CPU address (hex, with or without 0x), word aligned: any DDR alias 0x1/0x2/0x3xxxxxxx.
#         The adapter window is identity at 0x10000000 (WIN_AW=28), so the physical byte address is
#         0x10000000 | (ADDR & 0x0FFFFFFF).
# HEXFILE one 32-bit word per line, 8 hex digits, big-endian MIPS word values (gios `file` /
#         gios_uart.py --file format; lines starting with @ and blank lines are ignored).
#
# Word order: the cs150 caches/RC (LITTLEWORDIAN=1) and the ARM/HP0 view disagree on word order
# inside each 16-byte beat: MIPS word i of a 16-byte group sits at ARM offset (3-i)*4, with the
# same 32-bit value (measured on the board: gios sw at +0 reads back at +0xC through xsct). So
# CPU address A is written at ARM address (A & ~0xF) | (0xC - (A & 0xC)). Partial 16-byte groups
# are completed with the words already in DDR (read-modify-write), so nothing next to the image
# is clobbered. Every group is read back and compared.
#
# Caches: the MIPS I$/D$ are not snooped. Load into lines the CPU has not touched since reset (or
# re-run jtag_boot.tcl first, then load, then jal). Target: the PYNQ cable 1234-tulA only.
set ::CABLE "*1234-tulA*"
if {[llength $argv] < 2 || [llength $argv] % 2} {
    puts "usage: xsct jtag_load.tcl ADDR HEXFILE [ADDR HEXFILE ...]"; exit 2
}
connect -url tcp:localhost:3121
targets -set -nocase -filter "jtag_cable_name =~ \"$::CABLE\" && name =~ \"APU*\""
set tgt [lindex [targets -target-properties] 0]
if {![string match -nocase "*1234-tul*" [dict get $tgt jtag_cable_name]]} { puts "ERROR: not the PYNQ cable"; exit 1 }

proc phys {a} { return [expr {0x10000000 | ($a & 0x0FFFFFFF)}] }
proc armaddr {p} { return [expr {($p & ~0xF) | (0xC - ($p & 0xC))}] }

set total 0
set t0 [clock milliseconds]
foreach {astr file} $argv {
    set a [expr {"0x[string map {0x ""} $astr]"}]
    if {$a & 3} { puts "ERROR: $astr not word aligned"; exit 1 }
    set words {}
    set fh [open $file r]
    foreach l [split [read $fh] "\n"] {
        set l [string trim $l]
        if {$l eq "" || [string index $l 0] eq "@"} continue
        lappend words [expr {"0x$l"}]
    }
    close $fh
    # word map: physical CPU-order address -> value
    set m [dict create]
    set p [phys $a]
    foreach w $words { dict set m $p $w; incr p 4 }
    set first [expr {[phys $a] & ~0xF}]
    set last  [expr {($p - 1) & ~0xF}]
    set bad 0
    for {set g $first} {$g <= $last} {incr g 16} {
        set vals {}
        set need_rmw 0
        for {set i 0} {$i < 4} {incr i} { if {![dict exists $m [expr {$g + 4*$i}]]} { set need_rmw 1 } }
        if {$need_rmw} { set old [mrd -force -value $g 4] }
        # ARM offsets 0,4,8,C hold MIPS words 3,2,1,0
        for {set k 0} {$k < 4} {incr k} {
            set cpu [expr {$g + 4*(3 - $k)}]
            if {[dict exists $m $cpu]} { lappend vals [dict get $m $cpu] } else { lappend vals [lindex $old $k] }
        }
        mwr -force $g $vals 4
        set rb [mrd -force -value $g 4]
        for {set k 0} {$k < 4} {incr k} {
            if {([lindex $rb $k] & 0xFFFFFFFF) != ([lindex $vals $k] & 0xFFFFFFFF)} { incr bad }
        }
    }
    set n [llength $words]
    incr total $n
    puts [format "LOADED %s: %d words (%d bytes) at CPU 0x%08x (phys 0x%08x), readback %s" \
          $file $n [expr {4*$n}] $a [phys $a] [expr {$bad ? "MISMATCH ($bad words)" : "OK"}]]
    if {$bad} { exit 1 }
}
puts [format "JTAG_LOAD_DONE %d words in %d ms" $total [expr {[clock milliseconds] - $t0}]]
