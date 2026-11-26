# 08_hdmi_cs150_mode: HDMI out at the cs150/proj150 video mode (800x600@60,
# 40 MHz) on the PYNQ-Z2, fed by the proj150 PixelFeeder from a DDR framebuffer
# through the unmodified cs150 RequestController (06's memory path); the 08
# test pattern stays as a selectable fallback. Run from here. No program target.
#   make sim           Icarus: framebuffer core (UART -> drawer -> RC -> AXI model,
#                      PixelFeeder -> sink), reduced 64x16 raster, self-checking
#   make sim-pattern   Icarus: 800x600 timing generator + test pattern
#   make sim-tmds      Vivado xsim: Digilent TMDS_Encoder (VHDL)
#   make overlay       Vivado 2019.1 framebuffer overlay -> ../build/hdmi_fb/
#   make overlay-pattern  the earlier pattern-only overlay -> ../build/hdmi_cs150/

VIVADO  ?= /tools/Xilinx/Vivado/2019.1/bin/vivado
VBIN    ?= /tools/Xilinx/Vivado/2019.1/bin
REPO    := ..
VENDOR  := rtl/vendor/rgb2dvi

UART := $(REPO)/01_uart_echo/rtl/uart_rx.v $(REPO)/01_uart_echo/rtl/uart_tx.v
FB_RTL := rtl/fb_core.v rtl/frame_drawer.v rtl/pixel_feeder_rc.v rtl/pf_video_sink.v \
          rtl/proj150/PixelFeeder.v rtl/RequestController.v rtl/rc_axi_fifo_adapter.v \
          rtl/vga_timing.v rtl/test_pattern.v
FB_SIM := $(FB_RTL) $(UART) sim/models/ip_fifos.v sim/models/fifo_async_fwft_model.v \
          sim/axi4_slave_pipe.v sim/tb_fb.v
PAT_SRCS := rtl/vga_timing.v rtl/test_pattern.v sim/tb_hdmi_cs150.v
VIVADO_BAT := $(VIVADO) -mode batch -notrace -nojournal

.PHONY: all help sim sim-pattern sim-tmds overlay overlay-pattern clean

all: sim

help:
	@echo "08_hdmi_cs150_mode  (800x600@60 HDMI: PixelFeeder framebuffer via cs150 RequestController)"
	@echo "  make sim              Icarus: framebuffer core, self-checking"
	@echo "  make sim-pattern      Icarus: timing + pattern checks"
	@echo "  make sim-tmds         xsim: Digilent TMDS encoder checks (needs Vivado)"
	@echo "  make overlay          Vivado 2019.1 framebuffer overlay (../build/hdmi_fb/)"
	@echo "  make overlay-pattern  pattern-only overlay (../build/hdmi_cs150/)"
	@echo "  Neither overlay target programs a board."

sim: $(FB_SIM)
	iverilog -g2012 -I rtl/proj150 -o sim/tb_fb.vvp -s tb_fb $(FB_SIM)
	vvp -n sim/tb_fb.vvp | grep -a -v "^  aB:\|^LAST:"

sim-pattern: $(PAT_SRCS)
	iverilog -g2005 -o sim/tb_hdmi_cs150.vvp -s tb_hdmi_cs150 $(PAT_SRCS)
	vvp -n sim/tb_hdmi_cs150.vvp

sim-tmds: sim/tb_tmds_encoder.v $(VENDOR)/DVI_Constants.vhd $(VENDOR)/TMDS_Encoder.vhd
	mkdir -p sim/xsim && cd sim/xsim && \
	  $(VBIN)/xvhdl ../../$(VENDOR)/DVI_Constants.vhd ../../$(VENDOR)/TMDS_Encoder.vhd && \
	  $(VBIN)/xvlog ../tb_tmds_encoder.v && \
	  $(VBIN)/xelab -debug off tb_tmds_encoder -s tb_tmds && \
	  $(VBIN)/xsim tb_tmds -runall

overlay:
	@mkdir -p $(REPO)/build/logs
	$(VIVADO_BAT) -log $(REPO)/build/logs/hdmi_fb.log -source build_hdmi_fb.tcl

overlay-pattern:
	@mkdir -p $(REPO)/build/logs
	$(VIVADO_BAT) -log $(REPO)/build/logs/hdmi_cs150.log -source build_hdmi_cs150.tcl

clean:
	rm -rf sim/*.vvp sim/*.vcd sim/xsim *.jou *.log .Xil
