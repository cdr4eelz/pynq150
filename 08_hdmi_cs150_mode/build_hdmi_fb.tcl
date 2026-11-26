# Build the 08 framebuffer overlay: PS7 block design fb_ps (PS7 + SmartConnect ->
# S_AXI_HP0 64-bit, JTAG-to-AXI as a 2nd master for debug, proc_sys_reset; the
# PL AXI master comes in through the external BD port S_AXI) + fb_overlay_top
# (MMCM 40/200 MHz, fb_core, Digilent rgb2dvi). FIFO IPs are built from the
# unmodified proj150 scripts in ip/ (mig_caf, mig_wdf, mig_rdf, pixel_fifo).
# Outputs (same basename, gitignored) in <repo>/build/hdmi_fb/:
#   hdmi_fb.bit  hdmi_fb.hwh  util.rpt  timing.rpt  clk_util.rpt  cdc.rpt
# Does not program a board.
set root [file normalize [file join [file dirname [info script]]]]
set repo [file normalize [file join $root ..]]
set d    [file normalize [file join $repo build hdmi_fb]]
file mkdir $d

create_project hdmi_fb $d/proj -part xc7z020clg400-1 -force
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
    [file join $repo 01_uart_echo rtl uart_rx.v] \
    [file join $repo 01_uart_echo rtl uart_tx.v] \
    [file join $root rtl RequestController.v] \
    [file join $root rtl rc_axi_fifo_adapter.v] \
    [file join $root rtl proj150 PixelFeeder.v] \
    [file join $root rtl proj150 gpcommands.vh] \
    [file join $root rtl pixel_feeder_rc.v] \
    [file join $root rtl pf_video_sink.v] \
    [file join $root rtl frame_drawer.v] \
    [file join $root rtl vga_timing.v] \
    [file join $root rtl test_pattern.v] \
    [file join $root rtl fb_core.v] \
    [file join $root rtl fb_overlay_top.v]]
# PixelFeeder.v (verbatim proj150) uses named generate-block end labels, a
# SystemVerilog feature; proj150 compiles it the same way. gpcommands.vh is
# found through the include path.
set_property file_type SystemVerilog [get_files PixelFeeder.v]
set_property include_dirs [list [file join $root rtl proj150]] [current_fileset]

# --- FIFO Generator IPs from the unmodified proj150 scripts (they expect
# ::IP_NAME and ::IP_DIR). Clock frequencies inside them are from the Arty
# design and only feed the IPs' out-of-context constraints.
set ip_dir [file join $d ip]
file mkdir $ip_dir
foreach n {mig_caf mig_wdf mig_rdf pixel_fifo} {
    set ::IP_NAME $n
    set ::IP_DIR  $ip_dir
    source [file join $root ip $n.tcl]
    generate_target all [get_ips $n]
}

create_bd_design fb_ps
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

set s [create_bd_intf_port -mode Slave -vlnv xilinx.com:interface:aximm_rtl:1.0 S_AXI]
set_property -dict [list CONFIG.PROTOCOL {AXI4} CONFIG.DATA_WIDTH {64} CONFIG.ADDR_WIDTH {32} \
    CONFIG.ID_WIDTH {1} CONFIG.FREQ_HZ {100000000} CONFIG.READ_WRITE_MODE {READ_WRITE} \
    CONFIG.HAS_BURST {1} CONFIG.HAS_LOCK {1} CONFIG.HAS_PROT {1} CONFIG.HAS_CACHE {1} \
    CONFIG.HAS_QOS {1} CONFIG.HAS_REGION {1} CONFIG.HAS_WSTRB {1} CONFIG.HAS_BRESP {1} CONFIG.HAS_RRESP {1} \
    CONFIG.MAX_BURST_LENGTH {4} CONFIG.NUM_READ_OUTSTANDING {8} CONFIG.NUM_WRITE_OUTSTANDING {8} \
    CONFIG.AWUSER_WIDTH {0} CONFIG.ARUSER_WIDTH {0} CONFIG.WUSER_WIDTH {0} CONFIG.RUSER_WIDTH {0} \
    CONFIG.BUSER_WIDTH {0} CONFIG.SUPPORTS_NARROW_BURST {0}] $s
create_bd_port -dir O -type clk FCLK_CLK0
set_property CONFIG.ASSOCIATED_BUSIF {S_AXI} [get_bd_ports FCLK_CLK0]
create_bd_port -dir O -type rst peripheral_aresetn

connect_bd_net [get_bd_pins ps7/FCLK_CLK0] [get_bd_pins ps7/S_AXI_HP0_ACLK] \
    [get_bd_pins jtag_axi_0/aclk] [get_bd_pins smartconnect_0/aclk] \
    [get_bd_pins rst_0/slowest_sync_clk] [get_bd_ports FCLK_CLK0]
connect_bd_net [get_bd_pins ps7/FCLK_RESET0_N] [get_bd_pins rst_0/ext_reset_in]
connect_bd_net [get_bd_pins rst_0/peripheral_aresetn] [get_bd_pins jtag_axi_0/aresetn] \
    [get_bd_pins smartconnect_0/aresetn] [get_bd_ports peripheral_aresetn]
connect_bd_intf_net [get_bd_intf_ports S_AXI] [get_bd_intf_pins smartconnect_0/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins jtag_axi_0/M_AXI] [get_bd_intf_pins smartconnect_0/S01_AXI]
connect_bd_intf_net [get_bd_intf_pins smartconnect_0/M00_AXI] [get_bd_intf_pins ps7/S_AXI_HP0]
assign_bd_address
validate_bd_design
save_bd_design

make_wrapper -files [get_files fb_ps.bd] -top
add_files -norecurse [glob $d/proj/hdmi_fb.srcs/sources_1/bd/fb_ps/hdl/fb_ps_wrapper.v]
add_files -fileset constrs_1 [list \
    [file join $root constr pynq_z2_hdmi_fb.xdc] \
    [file join $v rgb2dvi.xdc]]
set_property top fb_overlay_top [current_fileset]
update_compile_order -fileset sources_1
generate_target all [get_files fb_ps.bd]
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1
puts "IMPL_STATUS: [get_property STATUS [get_runs impl_1]]"
open_run impl_1
report_utilization       -file $d/util.rpt
report_timing_summary    -file $d/timing.rpt
report_clock_utilization -file $d/clk_util.rpt
report_cdc               -file $d/cdc.rpt
file copy -force [glob $d/proj/hdmi_fb.runs/impl_1/fb_overlay_top.bit] $d/hdmi_fb.bit
file copy -force [glob $d/proj/hdmi_fb.srcs/sources_1/bd/fb_ps/hw_handoff/fb_ps.hwh] $d/hdmi_fb.hwh
puts "BUILD_DONE"
