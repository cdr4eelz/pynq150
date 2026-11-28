# 12 timing (impl_1 STEPS.PLACE_DESIGN.TCL.PRE): placement over-constraint. Adds setup uncertainty on
# the 50 MHz CPU clock while placing and physically optimizing, so the placer/phys_opt work the
# cs150 load -> forward -> branch -> next-PC -> I$ address path harder than its real slack asks;
# impl_physopt_post.tcl removes it again before routing (sign-off uses the real constraints).
set_clock_uncertainty -setup 0.5 [get_clocks clk_fpga_1]
