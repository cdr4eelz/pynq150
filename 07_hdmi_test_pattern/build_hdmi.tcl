# Build the 07 HDMI test-pattern overlay: PS7 block design (DDR + FIXED_IO,
# FCLK_CLK0 100 MHz and FCLK_RESET0_N exported) beside hdmi_pattern_top
# (MMCM, timing, pattern, Digilent rgb2dvi). No DDR traffic, no AXI.
# Pattern follows ../01_uart_echo/scripts/build_overlay.tcl.
# Outputs (same basename, gitignored) in <repo>/build/hdmi_pattern/:
#   hdmi_pattern.bit  hdmi_pattern.hwh  util.rpt  timing.rpt
# Does not program a board.
set root [file normalize [file join [file dirname [info script]]]]
set repo [file normalize [file join $root ..]]
set d    [file normalize [file join $repo build hdmi_pattern]]
file mkdir $d

create_project hdmi_pattern $d/proj -part xc7z020clg400-1 -force
set bp [lindex [get_board_parts *pynq-z2*] end]
puts "BOARD_PART: $bp"
set_property board_part $bp [current_project]
set_property target_language Verilog [current_project]

set v [file join $root rtl vendor rgb2dvi]
add_files -norecurse [list \
    [file join $v DVI_Constants.vhd] \
    [file join $v SyncAsync.vhd] \
    [file join $v SyncAsyncReset.vhd] \
    [file join $v ClockGen.vhd] \
    [file join $v OutputSERDES.vhd] \
    [file join $v TMDS_Encoder.vhd] \
    [file join $v rgb2dvi.vhd] \
    [file join $root rtl vga_timing.v] \
    [file join $root rtl test_pattern.v] \
    [file join $root rtl hdmi_pattern_top.v] \
    [file join $root rtl hdmi_overlay_top.v]]

create_bd_design hdmi_ps
set ps [create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7:5.5 ps7]
apply_bd_automation -rule xilinx.com:bd_rule:processing_system7 \
    -config {make_external "FIXED_IO, DDR" apply_board_preset "1" Master "Disable" Slave "Disable"} $ps
set_property -dict [list \
    CONFIG.PCW_USE_M_AXI_GP0 {0} \
    CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ {100}] $ps
create_bd_port -dir O -type clk FCLK_CLK0
create_bd_port -dir O -type rst FCLK_RESET0_N
connect_bd_net [get_bd_pins ps7/FCLK_CLK0]     [get_bd_ports FCLK_CLK0]
connect_bd_net [get_bd_pins ps7/FCLK_RESET0_N] [get_bd_ports FCLK_RESET0_N]
validate_bd_design
save_bd_design

make_wrapper -files [get_files hdmi_ps.bd] -top
add_files -norecurse [glob $d/proj/hdmi_pattern.srcs/sources_1/bd/hdmi_ps/hdl/hdmi_ps_wrapper.v]
add_files -fileset constrs_1 [list \
    [file join $root constr pynq_z2_hdmi.xdc] \
    [file join $v rgb2dvi.xdc]]
set_property top hdmi_overlay_top [current_fileset]
update_compile_order -fileset sources_1
generate_target all [get_files hdmi_ps.bd]
launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1
puts "IMPL_STATUS: [get_property STATUS [get_runs impl_1]]"
open_run impl_1
report_utilization    -file $d/util.rpt
report_timing_summary -file $d/timing.rpt
report_clock_utilization -file $d/clk_util.rpt
file copy -force [glob $d/proj/hdmi_pattern.runs/impl_1/hdmi_overlay_top.bit] $d/hdmi_pattern.bit
file copy -force [glob $d/proj/hdmi_pattern.srcs/sources_1/bd/hdmi_ps/hw_handoff/hdmi_ps.hwh] $d/hdmi_pattern.hwh
puts "BUILD_DONE"
