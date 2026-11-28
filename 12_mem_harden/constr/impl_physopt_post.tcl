# 12 timing (impl_1 STEPS.PHYS_OPT_DESIGN.TCL.POST): one more fanout pass under the over-constraint,
# then restore clk_fpga_1's real uncertainty before route_design (see impl_place_pre.tcl).
phys_opt_design -directive AggressiveFanoutOpt
set_clock_uncertainty -setup 0 [get_clocks clk_fpga_1]
