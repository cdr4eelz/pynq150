# 11_mips_gpu: the cs150 MIPS150 system (CPU + I$/D$ + RequestController + GPU + proj150
# PixelFeeder) on the PYNQ-Z2 through 10's rc_axi_fifo_adapter (HP0, fixed base 0x10000000,
# 256 MiB identity window). CPU / caches / GPU / RC on FCLK1 50 MHz, AXI on FCLK0 100 MHz.
# The CPU boots the gios BIOS from ROM and talks on the Pmod UART at 115200 (434 clk/bit).
# Runs without Linux: JTAG boot (jtag_boot.tcl: ps7_init, fpga, ps7_post_config).
#   make sim        simsys + simmix + simthru
#   make simsys     whole system: gios boots from the bios_mem image to "> ", then lw/sw/sb, gs,
#                   gf / hwcolor / hwline with a DDR readback (TB_PASS). SYSARGS=+pf adds two
#                   frames with the PixelFeeder on (slow); SYSARGS=+nogpu skips the GPU part.
#   make simmix     RC + adapter mixed read/write vs hostile slave, 4 seeds x 5 latency sets (from 10)
#   make simthru    same bench, throughput (disjoint / same lines)
#   make simhz      same-line race test on 12's adapter (3 seeds) + check-removed control (must catch it)
#   make simprio    PixelFeeder read latency under write load, 12 RC vs sim/ref 11 RC (sim/prio.log)
#   make sim-pattern / sim-tmds   08's timing + pattern and TMDS checks
#   make overlay    Vivado 2019.1 -> ../build/mem_harden/mem_harden.{bit,hwh} + ps7_init.tcl

VIVADO  ?= /tools/Xilinx/Vivado/2019.1/bin/vivado
VBIN    ?= /tools/Xilinx/Vivado/2019.1/bin
REPO    := ..
VENDOR  := rtl/vendor/rgb2dvi
ADAPTER ?= rtl/rc_axi_fifo_adapter.v
VIVADO_BAT := $(VIVADO) -mode batch -notrace -nojournal

CS := rtl/cs150
SYS := rtl/sys_core.v rtl/pixel_feeder_rc.v rtl/pf_video_sink.v rtl/vga_timing.v rtl/proj150/PixelFeeder.v \
       $(CS)/MIPS150.v $(CS)/TunTap.v \
       $(addprefix $(CS)/cpu/,CPUMIPS.v COP0150.v MemBank.v MemMapIO.v StageF.v StageDX.v StageMW.v) \
       $(addprefix $(CS)/base_io/,UART.v UARTRVA.v UAReceive.v UATransmit.v) \
       $(addprefix $(CS)/base_mem/,Cache.v RequestController.v DDRStage.v) \
       $(wildcard $(CS)/innerds/*.v) $(filter-out %/Const.v,$(wildcard $(CS)/base_util/*.v)) \
       $(wildcard $(CS)/gpu/*.v)
SYS_MODELS := sim/models/ip_fifos.v sim/models/fifo_async_fwft_model.v sim/models/cache_brams.v \
       sim/models/brams.v sim/models/uarx_fifo.v
SYSFLAGS := -g2012 -I rtl/proj150 $(addprefix -I $(CS)/,gpu innerds cpu base_io base_util base_mem) -I $(CS)
MIFS := sim/run/bios_mem.mif sim/run/isr_mem.mif sim/run/dmem_blk_ram.mif sim/run/imem_blk_ram.mif
PAT_SRCS := rtl/vga_timing.v rtl/test_pattern.v sim/tb_hdmi_cs150.v

MIX_SRCS = sim/tb_adapter_mixed.v $(RC_SRC) sim/models/ip_fifos.v \
            sim/models/fifo_async_fwft_model.v sim/axi4_slave_rand.v $(ADAPTER)
MIX_P     = -Ptb_adapter_mixed.MODE=$(1) -Ptb_adapter_mixed.N=$(2) -Ptb_adapter_mixed.SEED=$(3) \
            -Ptb_adapter_mixed.RLAT_MIN=$(4) -Ptb_adapter_mixed.RLAT_MAX=$(5) \
            -Ptb_adapter_mixed.BLAT_MIN=$(6) -Ptb_adapter_mixed.BLAT_MAX=$(7)
RC_SRC   ?= $(CS)/base_mem/RequestController.v
MIX_RUN   = iverilog -g2012 -o sim/tbmix.vvp -s tb_adapter_mixed $(call MIX_P,$(1),$(2),$(3),$(4),$(5),$(6),$(7)) $(MIX_SRCS) && \
            vvp -n sim/tbmix.vvp | grep -E "RESULT|TIME|MISMATCH|TIMEOUT|flags|PASSED|FAILED|RECOVERY_DROP" | tee -a sim/mix.log

.PHONY: all help sim simsys simmix _mixrun simthru simprio simhz sim-pattern sim-tmds overlay clean

all: sim
help:
	@sed -n '1,13p' Makefile
sim: simsys simhz simmix simthru

# BRAM images for sim/models/brams.v: the same COE files the IP scripts load (sw/, from proj150)
sim/run/bios_mem.mif:     sw/gios.inst.coe  ; @mkdir -p sim/run && python3 sim/coe2mif.py $< > $@
sim/run/isr_mem.mif:      sw/isr7.coe       ; @mkdir -p sim/run && python3 sim/coe2mif.py $< > $@
sim/run/dmem_blk_ram.mif: sw/bench.inst.coe ; @mkdir -p sim/run && python3 sim/coe2mif.py $< > $@
sim/run/imem_blk_ram.mif: sw/proj7.inst.coe ; @mkdir -p sim/run && python3 sim/coe2mif.py $< > $@

# CPUMIPS/ALUdec print "Untrapped ALU op" for bubbles and data words in flight (sim noise, as in proj150);
# the UART transcript is decoded from the MEMIO Tx lines into sim/sys_uart.txt.
simsys: $(SYS) $(ADAPTER) $(SYS_MODELS) sim/axi4_slave_pipe.v sim/tb_sys.v $(MIFS)
	iverilog $(SYSFLAGS) -o sim/run/tb_sys.vvp -s tb_sys $(SYS) $(ADAPTER) $(SYS_MODELS) sim/axi4_slave_pipe.v sim/tb_sys.v
	cd sim/run && vvp -n tb_sys.vvp $(SYSARGS) | grep -av "Untrapped ALU op\|MEMIO: Rx Shake\|^  aB:" > ../sys.log; true
	@python3 -c "import re;s=open('sim/sys.log','rb').read().decode('latin1');open('sim/sys_uart.txt','w').write(''.join(chr(int(m,16)) for m in re.findall(r'Tx Shake \(0x([0-9a-f]{2})',s)).replace(chr(13),''))"
	@cat sim/sys_uart.txt; grep -a "TB_\|RECOVERY_DROP\|prompt seen\|cpu out of reset" sim/sys.log
	@grep -aq "^TB_PASS" sim/sys.log
	@! grep -aq "RECOVERY_DROP" sim/sys.log

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

simthru:
	@rm -f sim/thru.log
	@$(call MIX_RUN,1,2048,1,40,40,30,30) | tee -a sim/thru.log
	@$(call MIX_RUN,2,2048,1,40,40,30,30) | tee -a sim/thru.log
	@! grep -q "FAILED\|RECOVERY_DROP" sim/thru.log


# 12: PixelFeeder read latency under a back-to-back write flood (MODE 3, pixf at display pace,
# 1 line / 10 RC clk = 160 MB/s), 12's RequestController (pixf first + caf_backlog gate) against
# 11's (sim/ref/RequestController_11.v). Two slave latency sets.
simprio:
	@rm -f sim/prio.log
	@for lat in "40 40 30 30" "20 120 20 120"; do set -- $$lat; \
	  for rc in $(CS)/base_mem/RequestController.v sim/ref/RequestController_11.v; do \
	    echo "== RC $$rc lat R$$1-$$2 B$$3-$$4" | tee -a sim/prio.log; \
	    $(MAKE) --no-print-directory RC_SRC=$$rc _priorun R1=$$1 R2=$$2 B1=$$3 B2=$$4 || exit 1; \
	  done; done
	@! grep -q "FAILED\|RECOVERY_DROP" sim/prio.log
_priorun:
	@iverilog -g2012 -o sim/tbprio.vvp -s tb_adapter_mixed $(call MIX_P,3,3000,1,$(R1),$(R2),$(B1),$(B2)) \
	   -Ptb_adapter_mixed.WIN_AW=20 -Ptb_adapter_mixed.MEM_AW=21 $(MIX_SRCS) && \
	 vvp -n sim/tbprio.vvp | grep -E "PIXF_LAT|TIME|PASSED|FAILED|TIMEOUT|RECOVERY_DROP" | tee -a sim/prio.log

# 12: same-line race test (10's sim/tb_hazard.v + 10's fb_core, read from ../10_rc_50mhz,
# unmodified) against 12's adapter: 3 seeds must PASS (no stale read); the control build,
# 12's adapter with the hazard check removed (sim/run/adapter_nohz.v, generated by sed),
# must detect the race (EXPECT_FAIL=1 -> TB_PASS iff >= 1 stale read).
R10    := $(REPO)/10_rc_50mhz
HZ_CORE := $(addprefix $(R10)/,rtl/fb_core.v rtl/frame_drawer.v rtl/pixel_feeder_rc.v rtl/pf_video_sink.v \
           rtl/proj150/PixelFeeder.v rtl/RequestController.v rtl/vga_timing.v rtl/test_pattern.v \
           rtl/cache_ex.v rtl/slr_rc.v rtl/cs150/Cache.v rtl/proj150/gpu/ScanLineRunner.v)
HZ_MODELS := $(REPO)/01_uart_echo/rtl/uart_rx.v $(REPO)/01_uart_echo/rtl/uart_tx.v \
           $(addprefix $(R10)/sim/models/,ip_fifos.v fifo_async_fwft_model.v cache_brams.v)
HZ_IV  := iverilog -g2012 -I $(R10)/rtl/proj150 -I $(R10)/rtl/proj150/gpu -I $(R10)/rtl/cs150
# $(call HZ_RUN,adapter,seed,expect_fail,label)
HZ_RUN = $(HZ_IV) -o sim/run/tbhz.vvp -s tb_hazard -Ptb_hazard.SEED=$(2) -Ptb_hazard.EXPECT_FAIL=$(3) \
           $(HZ_CORE) $(1) $(HZ_MODELS) $(R10)/sim/axi4_slave_rand.v $(R10)/sim/tb_hazard.v && \
         vvp -n sim/run/tbhz.vvp | sed 's/^/[$(4)] /' | grep -E "HZ_RESULT|TB_|race|ERROR|RECOVERY_DROP" | tee -a sim/hz.log

simhz: $(ADAPTER)
	@mkdir -p sim/run; rm -f sim/hz.log
	@sed -e 's/is_wr \&\& !war_hz/is_wr/' -e 's/is_rd \&\& !raw_hz/is_rd/' $(ADAPTER) > sim/run/adapter_nohz.v
	@! cmp -s $(ADAPTER) sim/run/adapter_nohz.v || (echo "simhz: nohz sed did not apply"; false)
	@$(call HZ_RUN,$(ADAPTER),32\'h12345678,0,12 adapter s1)
	@$(call HZ_RUN,$(ADAPTER),32\'hCAFEF00D,0,12 adapter s2)
	@$(call HZ_RUN,$(ADAPTER),32\'h0BADBEEF,0,12 adapter s3)
	@$(call HZ_RUN,sim/run/adapter_nohz.v,32\'h12345678,1,no check)
	@! grep -q "RECOVERY_DROP" sim/hz.log
	@test $$(grep -c "TB_PASS" sim/hz.log) -eq 4 && echo "SIMHZ_PASS (4/4)" || (echo "SIMHZ_FAIL"; false)

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
	$(VIVADO_BAT) -log $(REPO)/build/logs/mem_harden.log -source build_mem_harden.tcl

clean:
	rm -rf sim/*.vvp sim/*.vcd sim/*.log sim/sys_uart.txt sim/run sim/xsim *.jou *.log .Xil
