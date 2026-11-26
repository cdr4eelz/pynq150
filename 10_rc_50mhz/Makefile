# 10_rc_50mhz: 09's cache + SLR test with the RequestController, caches,
# frame_drawer, ScanLineRunner, PixelFeeder memory side and UART on FCLK1
# at 50 MHz. HP0 and the adapter AXI side stay on FCLK0 at 100 MHz; the
# existing independent-clock mig_* FIFOs cross the two domains.
# UART divisor is CLK_FREQ/BAUD = 50_000_000/115200 = 434.
# Runs without Linux: JTAG boot (jtag_boot.tcl: ps7_init, fpga, ps7_post_config), fixed DDR base.
#   make sim        Icarus: simcore + simhz + simmix + simthru (sim FIFOs model reset recovery: writes in the
#                   first 32 wr_clk cycles after reset are dropped -> any RECOVERY_DROP fails the run)
#   make simcore    full core, reduced 64x16 raster, every 08 + 09 UART command,
#                   screen and DDR checks, self-checking (TB_PASS)
#   make simhz      same-line race tests (E / O / E x) on the hostile AXI slave:
#                   patched adapter (3 seeds, must pass), 08 barrier adapter
#                   (must pass), adapter with the hazard check removed (must FAIL
#                   -> TB_PASS means the race was detected)
#   make simmix     RC + adapter mixed read/write vs hostile slave, 4 seeds x 5 latency sets
#   make simthru    same bench, throughput (disjoint / same lines)
#   make sim-pattern / sim-tmds   08's timing + pattern and TMDS checks
#   make overlay    Vivado 2019.1 overlay -> ../build/rc_50mhz/rc_50mhz.{bit,hwh}
#                   plus ps7_init.tcl for jtag_boot.tcl

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
         vvp -n sim/tbhz.vvp | sed 's/^/[$(4)] /' | grep -E "HZ_RESULT|TB_|race|ERROR|RECOVERY_DROP" | tee -a sim/hz.log

.PHONY: all help sim simcore simhz simmix simthru _mixrun sim-pattern sim-tmds overlay clean

all: sim

help:
	@sed -n '1,14p' Makefile

sim: simcore simhz simmix simthru

simcore: $(CORE) $(ADAPTER) $(MODELS) sim/axi4_slave_pipe.v sim/tb_09.v
	iverilog $(IVFLAGS) -o sim/tb_09.vvp -s tb_10 $(CORE) $(ADAPTER) $(MODELS) sim/axi4_slave_pipe.v sim/tb_09.v
	vvp -n sim/tb_09.vvp | grep -v "^  aB:\|^LAST:" | tee sim/core.log
	@grep -q "^TB_PASS" sim/core.log
	@! grep -q "RECOVERY_DROP" sim/core.log

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
	@! grep -q "RECOVERY_DROP" sim/hz.log
	@test $$(grep -c "TB_PASS" sim/hz.log) -eq 5 && echo "SIMHZ_PASS (5/5)" || (echo "SIMHZ_FAIL"; false)

# Mixed read/write test (RequestController + two clients + adapter + hostile slave
# sim/axi4_slave_rand.v), data checked against a command-order reference memory.
HZ       ?= -DHAVE_HZ
MIX_SRCS := sim/tb_adapter_mixed.v rtl/RequestController.v sim/models/ip_fifos.v \
            sim/models/fifo_async_fwft_model.v sim/axi4_slave_rand.v $(ADAPTER)
MIX_P     = -Ptb_adapter_mixed.MODE=$(1) -Ptb_adapter_mixed.N=$(2) -Ptb_adapter_mixed.SEED=$(3) \
            -Ptb_adapter_mixed.RLAT_MIN=$(4) -Ptb_adapter_mixed.RLAT_MAX=$(5) \
            -Ptb_adapter_mixed.BLAT_MIN=$(6) -Ptb_adapter_mixed.BLAT_MAX=$(7)
MIX_RUN   = iverilog -g2012 $(HZ) -o sim/tbmix.vvp -s tb_adapter_mixed $(call MIX_P,$(1),$(2),$(3),$(4),$(5),$(6),$(7)) $(MIX_SRCS) && \
            vvp -n sim/tbmix.vvp | grep -E "RESULT|TIME|MISMATCH|TIMEOUT|flags|PASSED|FAILED|RECOVERY_DROP" | tee -a sim/mix.log

simmix: $(MIX_SRCS)
	@rm -f sim/mix.log
	@set -e; for seed in 1 2 3 4; do \
	  for lat in "4 60 2 60" "40 40 30 30" "1 8 40 100" "30 90 1 6" "1 1 1 1"; do \
	    $(MAKE) --no-print-directory _mixrun SEED=$$seed LAT="$$lat"; \
	  done; \
	done
	@if grep -q "FAILED\|RECOVERY_DROP" sim/mix.log; then echo "simmix: FAILED"; exit 1; \
	 else echo "simmix: ALL MIXED RUNS PASSED ($$(grep -c PASSED sim/mix.log) runs)"; fi

_mixrun:
	@$(call MIX_RUN,0,3000,$(SEED),$(word 1,$(LAT)),$(word 2,$(LAT)),$(word 3,$(LAT)),$(word 4,$(LAT)))

# throughput: data-port writes + pixf streaming reads, slave latency R40/B30.
# mode 1 = disjoint lines, 2 = same lines.
simthru:
	@rm -f sim/thru.log
	@$(call MIX_RUN,1,2048,1,40,40,30,30) | tee -a sim/thru.log
	@$(call MIX_RUN,2,2048,1,40,40,30,30) | tee -a sim/thru.log
	@! grep -q "FAILED\|RECOVERY_DROP" sim/thru.log

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
	$(VIVADO_BAT) -log $(REPO)/build/logs/rc_50mhz.log -source build_rc_50mhz.tcl

clean:
	rm -rf sim/*.vvp sim/*.vcd sim/*.log sim/adapter_nohz.v sim/xsim *.jou *.log .Xil
