# jtag_boot.tcl - no-Linux bring-up of the 12 overlay (mem_harden) on the PYNQ-Z2 over JTAG.
# Board boot jumper must be on JTAG (power-cycled), so nothing runs on the ARM.
#   xsct jtag_boot.tcl [bitfile] [ps7_init.tcl]
# Steps (all on cable 1234-tulA / xc7z020 only - never the XUPV5):
#   1. rst -system         clean PS + PL state
#   2. ps7_init            MIO, PLLs, DDR controller + training, FCLK0=100 / FCLK1=50 MHz
#   3. fpga -file          configure the PL
#   4. ps7_post_config     enable PS<->PL level shifters, release FCLK_RESETn
# No ARM program is loaded; core 0 stays halted.
set dir  [file dirname [file normalize [info script]]]
set bld  [file normalize [file join $dir .. build mem_harden]]
set bit  [expr {[llength $argv] > 0 ? [lindex $argv 0] : "$bld/mem_harden.bit"}]
set init [expr {[llength $argv] > 1 ? [lindex $argv 1] : "$bld/ps7_init.tcl"}]
set CABLE {*1234-tulA*}

connect -url tcp:localhost:3121
proc pick {pat} {
    targets -set -nocase -filter "jtag_cable_name =~ \"$::CABLE\" && name =~ \"$pat\""
}
pick {APU*}
puts "rst -system"; rst -system; after 1500
pick {*Cortex-A9*#0}
catch {stop}
source $init
puts "ps7_init"; ps7_init
puts "fpga $bit"; fpga -file $bit
pick {*Cortex-A9*#0}
puts "ps7_post_config"; ps7_post_config
# report the clocks that were set up (SLCR FPGA0/1_CLK_CTRL, FPGA_RST_CTRL, LVL_SHFTR_EN)
foreach {n a} {FPGA0_CLK_CTRL 0xF8000170 FPGA1_CLK_CTRL 0xF8000180 FPGA_RST_CTRL 0xF8000240 LVL_SHFTR_EN 0xF8000900} {
    puts [format "%-15s %s" $n [format 0x%08x [mrd -value $a]]]
}
puts "JTAG_BOOT_DONE"
