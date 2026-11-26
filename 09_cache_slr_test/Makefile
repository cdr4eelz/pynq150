# 09_cache_slr_test: 08's 800x600 PixelFeeder framebuffer plus the cs150
# instruction and data caches and the ScanLineRunner as RequestController
# clients, all driven by UART commands; rc_axi_fifo_adapter carries patch 0001
# (address-conflict check instead of the direction barrier). No program target.
#   make sim        Icarus: everything below (simcore + simhz)
#   make simcore    full core, reduced 64x16 raster, every 08 + 09 UART command,
#                   screen and DDR checks, self-checking (TB_PASS)
#   make simhz      same-line race tests (E / O / E x) on the hostile AXI slave:
#                   patched adapter (3 seeds, must pass), 08 barrier adapter
#                   (must pass), adapter with the hazard check removed (must FAIL
#                   -> TB_PASS means the race was detected)
#   make sim-pattern / sim-tmds   08's timing + pattern and TMDS checks
#   make overlay    Vivado 2019.1 overlay -> ../build/cache_slr/cache_slr.{bit,hwh}

VIVADO  ?= /tools/Xilinx/Vivado/2019.1/bin/vivado
VBIN    ?= /tools/Xilinx/Vivado/2019.1/bin
REPO    := ..
VENDOR  := rtl/vendor/rgb2dvi
IVFLAGS := -g2012 -I rtl/proj150 -I rtl/proj150/gpu -I rtl/cs150

UART := $(REPO)/01_uart_echo/rtl/uart_rx.v $(REPO)/01_uart_echo/rtl/uart_tx.v
CORE := rtl/fb_core.v rtl/frame_drawer.v rtl/pixel_feeder_rc.v rtl/pf_video_sink.v \
        rtl/proj150/PixelFeeder.v rtl/RequestController.v \
        rtl/vga_timing.v rtl/test_pattern.v rtl/cache_ex.v rtl/slr_rc.v \
        rtl/cs150/Cache.v rtl/proj150/gpu/ScanLineRunner.v
MODELS := $(UART) sim/models/ip_fifos.v sim/models/fifo_async_fwft_model.v sim/models/cache_brams.v
ADAPTER ?= rtl/rc_axi_fifo_adapter.v
PAT_SRCS := rtl/vga_timing.v rtl/test_pattern.v sim/tb_hdmi_cs150.v
VIVADO_BAT := $(VIVADO) -mode batch -notrace -nojournal

# $(call HZ_RUN,adapter,seed,expect_fail,label)
HZ_RUN = iverilog $(IVFLAGS) -o sim/tbhz.vvp -s tb_hazard -Ptb_hazard.SEED=$(2) \
           -Ptb_hazard.EXPECT_FAIL=$(3) $(CORE) $(1) $(MODELS) sim/axi4_slave_rand.v sim/tb_hazard.v && \
         vvp -n sim/tbhz.vvp | sed 's/^/[$(4)] /' | grep -E "HZ_RESULT|TB_|race|ERROR" | tee -a sim/hz.log

.PHONY: all help sim simcore simhz sim-pattern sim-tmds overlay clean

all: sim

help:
	@sed -n '1,14p' Makefile

sim: simcore simhz

simcore: $(CORE) $(ADAPTER) $(MODELS) sim/axi4_slave_pipe.v sim/tb_09.v
	iverilog $(IVFLAGS) -o sim/tb_09.vvp -s tb_09 $(CORE) $(ADAPTER) $(MODELS) sim/axi4_slave_pipe.v sim/tb_09.v
	vvp -n sim/tb_09.vvp | grep -v "^  aB:\|^LAST:" | tee sim/core.log
	@grep -q "^TB_PASS" sim/core.log

sim/adapter_nohz.v: rtl/rc_axi_fifo_adapter.v
	sed -e 's/wire wr_ok = is_wr && !war_hz && /wire wr_ok = is_wr \&\& /' \
	    -e 's/wire rd_ok = is_rd && !raw_hz && /wire rd_ok = is_rd \&\& /' $< > $@
	@! grep -q '!war_hz\|!raw_hz' $@

simhz: $(CORE) $(MODELS) sim/axi4_slave_rand.v sim/tb_hazard.v sim/adapter_nohz.v sim/ref/rc_axi_fifo_adapter_barrier.v
	@rm -f sim/hz.log
	$(call HZ_RUN,rtl/rc_axi_fifo_adapter.v,32\'h12345678,0,patched s1)
	$(call HZ_RUN,rtl/rc_axi_fifo_adapter.v,32\'hCAFEF00D,0,patched s2)
	$(call HZ_RUN,rtl/rc_axi_fifo_adapter.v,32\'h0BADBEEF,0,patched s3)
	$(call HZ_RUN,sim/ref/rc_axi_fifo_adapter_barrier.v,32\'h12345678,0,barrier)
	$(call HZ_RUN,sim/adapter_nohz.v,32\'h12345678,1,no check)
	@test $$(grep -c "TB_PASS" sim/hz.log) -eq 5 && echo "SIMHZ_PASS (5/5)" || (echo "SIMHZ_FAIL"; false)

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
	$(VIVADO_BAT) -log $(REPO)/build/logs/cache_slr.log -source build_cache_slr.tcl

clean:
	rm -rf sim/*.vvp sim/*.vcd sim/*.log sim/adapter_nohz.v sim/xsim *.jou *.log .Xil
