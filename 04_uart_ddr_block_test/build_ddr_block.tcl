# Build the 04 UART-triggered DDR block test overlay (PS7 + SmartConnect +
# custom master). Derived from ../03_axi_ddr_test/build_uart_axi.tcl (not
# modified). JTAG-to-AXI is kept as a second SmartConnect slave for debug.
# Outputs go to <repo>/build/uart_ddr_block (gitignored): uart_ddr_block.bit
# and uart_ddr_block.hwh share a basename for PYNQ Overlay.
# Does not program a board.
set repo [file normalize [file join [file dirname [info script]] ..]]
set d    [file normalize [file join $repo build uart_ddr_block]]
file mkdir $d

create_project uart_ddr_block $d/proj -part xc7z020clg400-1 -force
set bp [lindex [get_board_parts *pynq-z2*] end]
puts "BOARD_PART: $bp"
set_property board_part $bp [current_project]

add_files -norecurse [list \
    [file join $repo 01_uart_echo rtl uart_rx.v] \
    [file join $repo 01_uart_echo rtl uart_tx.v] \
    [file join $repo 04_uart_ddr_block_test rtl uart_ddr_block_test.v] \
    [file join $repo 04_uart_ddr_block_test rtl uart_ddr_block_top.v]]
update_compile_order -fileset sources_1

create_bd_design uart_ddr_block

set ps [create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7:5.5 ps7]
apply_bd_automation -rule xilinx.com:bd_rule:processing_system7 \
    -config {make_external "FIXED_IO, DDR" apply_board_preset "1" Master "Disable" Slave "Disable"} $ps
set_property -dict [list \
    CONFIG.PCW_USE_S_AXI_HP0 {1} \
    CONFIG.PCW_S_AXI_HP0_DATA_WIDTH {64} \
    CONFIG.PCW_USE_M_AXI_GP0 {0} \
    CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ {100}] $ps

set ja [create_bd_cell -type ip -vlnv xilinx.com:ip:jtag_axi:1.2 jtag_axi_0]
set_property -dict [list CONFIG.PROTOCOL {0} CONFIG.M_AXI_DATA_WIDTH {32} CONFIG.M_AXI_ADDR_WIDTH {32}] $ja

set sc [create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:1.0 smartconnect_0]
set_property -dict [list CONFIG.NUM_SI {2} CONFIG.NUM_MI {1}] $sc

set rst [create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 rst_0]

create_bd_cell -type module -reference uart_ddr_block_top uart_ddr_block_top_0

connect_bd_net [get_bd_pins ps7/FCLK_CLK0] \
    [get_bd_pins ps7/S_AXI_HP0_ACLK] \
    [get_bd_pins jtag_axi_0/aclk] \
    [get_bd_pins smartconnect_0/aclk] \
    [get_bd_pins rst_0/slowest_sync_clk] \
    [get_bd_pins uart_ddr_block_top_0/clk]

connect_bd_net [get_bd_pins ps7/FCLK_RESET0_N] [get_bd_pins rst_0/ext_reset_in]
connect_bd_net [get_bd_pins rst_0/peripheral_aresetn] \
    [get_bd_pins jtag_axi_0/aresetn] \
    [get_bd_pins smartconnect_0/aresetn] \
    [get_bd_pins uart_ddr_block_top_0/rst_n]

connect_bd_intf_net [get_bd_intf_pins uart_ddr_block_top_0/M_AXI] [get_bd_intf_pins smartconnect_0/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins jtag_axi_0/M_AXI]     [get_bd_intf_pins smartconnect_0/S01_AXI]
connect_bd_intf_net [get_bd_intf_pins smartconnect_0/M00_AXI] [get_bd_intf_pins ps7/S_AXI_HP0]

create_bd_port -dir I btn0
create_bd_port -dir I uart_rxd
create_bd_port -dir O uart_txd
create_bd_port -dir O -from 3 -to 0 led
connect_bd_net [get_bd_ports btn0]     [get_bd_pins uart_ddr_block_top_0/btn0]
connect_bd_net [get_bd_ports uart_rxd] [get_bd_pins uart_ddr_block_top_0/uart_rxd]
connect_bd_net [get_bd_ports uart_txd] [get_bd_pins uart_ddr_block_top_0/uart_txd]
connect_bd_net [get_bd_ports led]      [get_bd_pins uart_ddr_block_top_0/led]

assign_bd_address
validate_bd_design
save_bd_design

make_wrapper -files [get_files uart_ddr_block.bd] -top
add_files -norecurse [glob $d/proj/uart_ddr_block.srcs/sources_1/bd/uart_ddr_block/hdl/uart_ddr_block_wrapper.v]
add_files -fileset constrs_1 [file join $repo 04_uart_ddr_block_test constr pynq_z2_ddr_block.xdc]
set_property top uart_ddr_block_wrapper [current_fileset]
generate_target all [get_files uart_ddr_block.bd]
launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1
puts "IMPL_STATUS: [get_property STATUS [get_runs impl_1]]"
open_run impl_1
report_utilization    -file $d/util.rpt
report_timing_summary -file $d/timing.rpt
write_debug_probes -force $d/uart_ddr_block.ltx
file copy -force [glob $d/proj/uart_ddr_block.runs/impl_1/uart_ddr_block_wrapper.bit] $d/uart_ddr_block.bit
file copy -force [glob $d/proj/uart_ddr_block.srcs/sources_1/bd/uart_ddr_block/hw_handoff/uart_ddr_block.hwh] $d/uart_ddr_block.hwh
puts "BUILD_DONE"
