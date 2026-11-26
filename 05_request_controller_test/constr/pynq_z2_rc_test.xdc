# pynq150 05_request_controller_test constraints for the PYNQ-Z2 (same pins as 03/04).
# Clock comes from PS7 FCLK_CLK0 (100 MHz) in the block design; there is
# no board-oscillator port in this top. Pin assignments match the TUL
# PYNQ-Z2 Master XDC (same as constr/pynq_z2.xdc).

## Buttons (BTN0 is an extra active-high reset, OR'd with PS reset)
set_property -dict { PACKAGE_PIN D19 IOSTANDARD LVCMOS33 } [get_ports { btn0 }]

## LEDs
set_property -dict { PACKAGE_PIN R14 IOSTANDARD LVCMOS33 } [get_ports { led[0] }]
# LD0 heartbeat on FCLK
set_property -dict { PACKAGE_PIN P14 IOSTANDARD LVCMOS33 } [get_ports { led[1] }]
# LD1 toggles on each received UART byte
set_property -dict { PACKAGE_PIN N16 IOSTANDARD LVCMOS33 } [get_ports { led[2] }]
# LD2 out-of-reset / FCLK alive
set_property -dict { PACKAGE_PIN M14 IOSTANDARD LVCMOS33 } [get_ports { led[3] }]
# LD3 last R result (1 = PASS)

## Pmod A (JA) — Digilent Pmod USBUART on the top row (pins 1-6)
set_property -dict { PACKAGE_PIN Y19 IOSTANDARD LVCMOS33 } [get_ports { uart_txd }]
set_property -dict { PACKAGE_PIN Y16 IOSTANDARD LVCMOS33 } [get_ports { uart_rxd }]

set_false_path -from [get_ports btn0]
set_false_path -from [get_ports uart_rxd]

set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]
