# 02_uart_buffer_test constraints for the PYNQ-Z2 (xc7z020clg400-1).
#
# Pin assignments are taken from the official TUL PYNQ-Z2 Master XDC,
# PYNQ-Z2v1.0.xdc (also the file linked as "Master XDC" on
# https://www.tulembedded.com/FPGA/ProductsPYNQ-Z2.html). The same
# assignments appear in Xilinx/PYNQ (commit a5b7bca,
# sdbuild/boot_configs/Pynq-Z2-defconfig/constraints.xdc). Only the
# pins used by this design are uncommented and renamed to match
# uart_buffer_top.

## Clock signal 125 MHz
set_property -dict { PACKAGE_PIN H16 IOSTANDARD LVCMOS33 } [get_ports { sysclk }]
# IO_L13P_T2_MRCC_35 Sch=sysclk
create_clock -add -name sys_clk_pin -period 8.00 -waveform {0 4} [get_ports { sysclk }]

## Buttons (BTN0 is the active-high reset)
set_property -dict { PACKAGE_PIN D19 IOSTANDARD LVCMOS33 } [get_ports { btn0 }]
# IO_L4P_T0_35 Sch=btn[0]

## LEDs
set_property -dict { PACKAGE_PIN R14 IOSTANDARD LVCMOS33 } [get_ports { led[0] }]
# IO_L6N_T0_VREF_34 Sch=led[0]  -- heartbeat
set_property -dict { PACKAGE_PIN P14 IOSTANDARD LVCMOS33 } [get_ports { led[1] }]
# IO_L6P_T0_34 Sch=led[1]       -- toggles on each received UART byte
set_property -dict { PACKAGE_PIN N16 IOSTANDARD LVCMOS33 } [get_ports { led[2] }]
# IO_L21N_T3_DQS_AD14N_35 Sch=led[2]  -- MMCM locked
set_property -dict { PACKAGE_PIN M14 IOSTANDARD LVCMOS33 } [get_ports { led[3] }]
# IO_L23P_T3_35 Sch=led[3]      -- high during buffer replay (TX phase)

## Pmod A (JA) — Digilent Pmod USBUART on the top row (pins 1-6)
#
# Pmod USBUART J1 (reference manual, Rev. A):
#   pin 1 ~RTS  unused
#   pin 2 RXD   data from the FPGA (host) into the Pmod   -> FPGA uart_txd
#   pin 3 TXD   data from the Pmod to the FPGA (host)     -> FPGA uart_rxd
#   pin 4 ~CTS  unused
#   pin 5 GND
#   pin 6 VCC
#
# Board pins from the master XDC:
#   ja[0] Y18 Sch=ja_p[1]  -> JA pin 1
#   ja[1] Y19 Sch=ja_n[1]  -> JA pin 2
#   ja[2] Y16 Sch=ja_p[2]  -> JA pin 3
#   ja[3] Y17 Sch=ja_n[2]  -> JA pin 4
set_property -dict { PACKAGE_PIN Y19 IOSTANDARD LVCMOS33 } [get_ports { uart_txd }]
# JA pin 2, Pmod USBUART RXD
set_property -dict { PACKAGE_PIN Y16 IOSTANDARD LVCMOS33 } [get_ports { uart_rxd }]
# JA pin 3, Pmod USBUART TXD

# False paths on the unsynchronized button and the UART input (they are
# synchronized in RTL). The generated MMCM clock is implied by the IP.
set_false_path -from [get_ports btn0]
set_false_path -from [get_ports uart_rxd]

set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]
