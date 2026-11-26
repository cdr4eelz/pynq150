# Outputs go to <repo>/build/ddr_jtag_axi (gitignored)
set d [file normalize [file join [file dirname [info script]] .. build ddr_jtag_axi]]
file mkdir $d
create_project ddrjtag $d/proj -part xc7z020clg400-1 -force
set bp [lindex [get_board_parts *pynq-z2*] end]
puts "BOARD_PART: $bp"
set_property board_part $bp [current_project]
create_bd_design ddrjtag
set ps [create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7:5.5 ps7]
apply_bd_automation -rule xilinx.com:bd_rule:processing_system7 -config {make_external "FIXED_IO, DDR" apply_board_preset "1" Master "Disable" Slave "Disable"} $ps
set_property -dict [list CONFIG.PCW_USE_S_AXI_HP0 {1} CONFIG.PCW_S_AXI_HP0_DATA_WIDTH {64} CONFIG.PCW_USE_M_AXI_GP0 {0} CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ {100}] $ps
set ja [create_bd_cell -type ip -vlnv xilinx.com:ip:jtag_axi:1.2 jtag_axi_0]
set_property -dict [list CONFIG.PROTOCOL {0} CONFIG.M_AXI_DATA_WIDTH {32} CONFIG.M_AXI_ADDR_WIDTH {32}] $ja
set sc [create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:1.0 smartconnect_0]
set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {1}] $sc
set rst [create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 rst_0]
connect_bd_net [get_bd_pins ps7/FCLK_CLK0] [get_bd_pins ps7/S_AXI_HP0_ACLK] [get_bd_pins jtag_axi_0/aclk] [get_bd_pins smartconnect_0/aclk] [get_bd_pins rst_0/slowest_sync_clk]
connect_bd_net [get_bd_pins ps7/FCLK_RESET0_N] [get_bd_pins rst_0/ext_reset_in]
connect_bd_net [get_bd_pins rst_0/peripheral_aresetn] [get_bd_pins jtag_axi_0/aresetn] [get_bd_pins smartconnect_0/aresetn]
connect_bd_intf_net [get_bd_intf_pins jtag_axi_0/M_AXI] [get_bd_intf_pins smartconnect_0/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins smartconnect_0/M00_AXI] [get_bd_intf_pins ps7/S_AXI_HP0]
assign_bd_address
foreach s [get_bd_addr_segs -of_objects [get_bd_addr_spaces jtag_axi_0/Data]] { puts "ADDRSEG: $s off=[get_property OFFSET $s] range=[get_property RANGE $s]" }
validate_bd_design
save_bd_design
make_wrapper -files [get_files ddrjtag.bd] -top
add_files -norecurse [glob $d/proj/ddrjtag.srcs/sources_1/bd/ddrjtag/hdl/ddrjtag_wrapper.v]
set_property top ddrjtag_wrapper [current_fileset]
generate_target all [get_files ddrjtag.bd]
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1
puts "IMPL_STATUS: [get_property STATUS [get_runs impl_1]]"
open_run impl_1
report_utilization -file $d/util.rpt
report_timing_summary -file $d/timing.rpt
write_debug_probes -force $d/ddrjtag.ltx
file copy -force [glob $d/proj/ddrjtag.runs/impl_1/ddrjtag_wrapper.bit] $d/ddrjtag.bit
file copy -force [glob $d/proj/ddrjtag.srcs/sources_1/bd/ddrjtag/hw_handoff/ddrjtag.hwh] $d/ddrjtag.hwh
puts "BUILD_DONE"
