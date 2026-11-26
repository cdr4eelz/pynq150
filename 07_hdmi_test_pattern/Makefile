# 07_hdmi_test_pattern: 640x480 HDMI colour-bar test pattern from the PYNQ-Z2
# HDMI OUT port. No DDR. Run from here. No program target.
#   make sim        Icarus: timing generator + pattern (testbench self-checks)
#   make sim-tmds   Vivado xsim: Digilent TMDS_Encoder (VHDL): decode + DC balance
#   make overlay    Vivado 2019.1 PS7 + hdmi_pattern_top -> ../build/hdmi_pattern/

VIVADO  ?= /tools/Xilinx/Vivado/2019.1/bin/vivado
VBIN    ?= /tools/Xilinx/Vivado/2019.1/bin
REPO    := ..
VENDOR  := rtl/vendor/rgb2dvi

SIM_SRCS := rtl/vga_timing.v rtl/test_pattern.v sim/tb_hdmi_pattern.v
VIVADO_BAT := $(VIVADO) -mode batch -notrace -nojournal

.PHONY: all help sim sim-tmds overlay clean

all: sim

help:
	@echo "07_hdmi_test_pattern  (640x480 HDMI colour bars, no DDR)"
	@echo "  make sim       Icarus: timing + pattern checks"
	@echo "  make sim-tmds  xsim: Digilent TMDS encoder checks (needs Vivado)"
	@echo "  make overlay   Vivado 2019.1 PS7+HDMI bitstream + hwh"
	@echo "                 (../build/hdmi_pattern/). Does NOT program a board."
	@echo "  make clean     remove sim products"

sim: $(SIM_SRCS)
	iverilog -g2005 -o sim/tb_hdmi.vvp -s tb_hdmi_pattern $(SIM_SRCS)
	vvp -n sim/tb_hdmi.vvp

sim-tmds: sim/tb_tmds_encoder.v $(VENDOR)/DVI_Constants.vhd $(VENDOR)/TMDS_Encoder.vhd
	mkdir -p sim/xsim && cd sim/xsim && \
	  $(VBIN)/xvhdl ../../$(VENDOR)/DVI_Constants.vhd ../../$(VENDOR)/TMDS_Encoder.vhd && \
	  $(VBIN)/xvlog ../tb_tmds_encoder.v && \
	  $(VBIN)/xelab -debug off tb_tmds_encoder -s tb_tmds && \
	  $(VBIN)/xsim tb_tmds -runall

overlay:
	@mkdir -p $(REPO)/build/logs
	$(VIVADO_BAT) -log $(REPO)/build/logs/hdmi_pattern.log -source build_hdmi.tcl

clean:
	rm -rf sim/*.vvp sim/*.vcd sim/xsim *.jou *.log .Xil
