# Build a PYNQ Overlay for the UART echo test: a dummy PS7 block design
# (board preset, DDR + FIXED_IO, no AXI) instantiated beside the existing
# pynq150_top. clk_wiz cannot live inside a BD module reference, so the
# UART top is kept as regular RTL. Does not program a board.
#
# Outputs (same basename):
#   <01_uart_echo>/build/overlay/uart_echo.bit
#   <01_uart_echo>/build/overlay/uart_echo.hwh
set root [file normalize [file join [file dirname [info script]] ..]]
set d    [file normalize [file join $root build overlay]]
file mkdir $d

create_project uart_echo $d/proj -part xc7z020clg400-1 -force
set bp [lindex [get_board_parts *pynq-z2*] end]
puts "BOARD_PART: $bp"
set_property board_part $bp [current_project]
set_property target_language Verilog [current_project]

source [file join $root ip clk_wiz_0.tcl]
generate_target {synthesis instantiation_template} [get_ips clk_wiz_0]
set_property generate_synth_checkpoint 0 [get_files clk_wiz_0.xci]

add_files -norecurse [list \
    [file join $root rtl uart_rx.v] \
    [file join $root rtl uart_tx.v] \
    [file join $root rtl uart_echo.v] \
    [file join $root rtl pynq150_top.v] \
    [file join $root rtl uart_echo_overlay_top.v]]

create_bd_design uart_echo_ps
set ps [create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7:5.5 ps7]
apply_bd_automation -rule xilinx.com:bd_rule:processing_system7 \
    -config {make_external "FIXED_IO, DDR" apply_board_preset "1" Master "Disable" Slave "Disable"} $ps
# Dummy PS: no GP or HP AXI. FCLK is left unused; the UART keeps sysclk.
set_property -dict [list CONFIG.PCW_USE_M_AXI_GP0 {0}] $ps
validate_bd_design
save_bd_design

make_wrapper -files [get_files uart_echo_ps.bd] -top
add_files -norecurse [glob $d/proj/uart_echo.srcs/sources_1/bd/uart_echo_ps/hdl/uart_echo_ps_wrapper.v]
add_files -fileset constrs_1 [file join $root constr pynq_z2.xdc]
set_property top uart_echo_overlay_top [current_fileset]
update_compile_order -fileset sources_1
generate_target all [get_files uart_echo_ps.bd]
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1
puts "IMPL_STATUS: [get_property STATUS [get_runs impl_1]]"
open_run impl_1
report_utilization    -file [file join $d util.rpt]
report_timing_summary -file [file join $d timing.rpt]
file copy -force [glob $d/proj/uart_echo.runs/impl_1/uart_echo_overlay_top.bit] [file join $d uart_echo.bit]
file copy -force [glob $d/proj/uart_echo.srcs/sources_1/bd/uart_echo_ps/hw_handoff/uart_echo_ps.hwh] [file join $d uart_echo.hwh]
puts "BUILD_DONE"
