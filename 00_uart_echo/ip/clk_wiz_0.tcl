# clk_wiz 6.0 (Vivado 2019.1): 125 MHz PYNQ-Z2 sysclk -> 125 MHz MMCM output.
# Input is the board oscillator on H16 (see constr/pynq_z2.xdc).
create_ip -name clk_wiz -vendor xilinx.com -library ip -version 6.0 -module_name clk_wiz_0
set_property -dict [list \
    CONFIG.PRIM_IN_FREQ {125.000} \
    CONFIG.PRIM_SOURCE {Single_ended_clock_capable_pin} \
    CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {125.000} \
    CONFIG.USE_RESET {true} \
    CONFIG.RESET_TYPE {ACTIVE_HIGH} \
    CONFIG.RESET_PORT {reset} \
    CONFIG.USE_LOCKED {true} \
] [get_ips clk_wiz_0]
