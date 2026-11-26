# pynq150 08_hdmi_cs150_mode constraints (same pins as 07) for the PYNQ-Z2.
# HDMI OUT pins are from the TUL PYNQ-Z2 master XDC (PYNQ-Z2_v1.0.xdc), the
# "##HDMI Tx" block, cross-checked against
#   ~ejr/fPROJ/vid_example/pynq-z2_v1.0.xdc  (copy of the TUL master XDC, used by Xilinx XVES_0023)
#   Xilinx/PYNQ commit a5b7bca, sdbuild/boot_configs/Pynq-Z2-defconfig/constraints.xdc
# HDMI OUT is wired straight to bank 35 PL pins (no external TMDS driver),
# so TMDS_33 OBUFDS is used. Bank 35 VCCO is 3.3 V.

## HDMI TX (TMDS_33). Data 0 = blue/HSYNC/VSYNC, 1 = green, 2 = red.
set_property -dict { PACKAGE_PIN L17 IOSTANDARD TMDS_33 } [get_ports { hdmi_tx_clk_n }]
set_property -dict { PACKAGE_PIN L16 IOSTANDARD TMDS_33 } [get_ports { hdmi_tx_clk_p }]
set_property -dict { PACKAGE_PIN K18 IOSTANDARD TMDS_33 } [get_ports { hdmi_tx_d_n[0] }]
set_property -dict { PACKAGE_PIN K17 IOSTANDARD TMDS_33 } [get_ports { hdmi_tx_d_p[0] }]
set_property -dict { PACKAGE_PIN J19 IOSTANDARD TMDS_33 } [get_ports { hdmi_tx_d_n[1] }]
set_property -dict { PACKAGE_PIN K19 IOSTANDARD TMDS_33 } [get_ports { hdmi_tx_d_p[1] }]
set_property -dict { PACKAGE_PIN H18 IOSTANDARD TMDS_33 } [get_ports { hdmi_tx_d_n[2] }]
set_property -dict { PACKAGE_PIN J18 IOSTANDARD TMDS_33 } [get_ports { hdmi_tx_d_p[2] }]
# Not used (left unconstrained/unconnected, as in XVES_0023 and the PS7 base
# overlay flow): hdmi_tx_cec G15, hdmi_tx_hpdn R19, hdmi_tx_scl M17, hdmi_tx_sda M18.

## Buttons (BTN0 = extra active-high reset of the MMCM)
set_property -dict { PACKAGE_PIN D19 IOSTANDARD LVCMOS33 } [get_ports { btn0 }]

## LEDs (same pins as 03..05)
set_property -dict { PACKAGE_PIN R14 IOSTANDARD LVCMOS33 } [get_ports { led[0] }]
# LD0 MMCM locked
set_property -dict { PACKAGE_PIN P14 IOSTANDARD LVCMOS33 } [get_ports { led[1] }]
# LD1 pixel clock alive (1.2 Hz blink)
set_property -dict { PACKAGE_PIN N16 IOSTANDARD LVCMOS33 } [get_ports { led[2] }]
# LD2 frame toggle
set_property -dict { PACKAGE_PIN M14 IOSTANDARD LVCMOS33 } [get_ports { led[3] }]
# LD3 FCLK0 alive (1.2 Hz blink)

set_false_path -from [get_ports btn0]
set_false_path -to   [get_ports { led[*] }]

set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]
