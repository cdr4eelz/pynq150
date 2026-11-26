# pynq150 — PYNQ-Z2 PL-only UART echo, Vivado 2019.1 non-project flow.
# Written fresh for this project. There is no program target: do not flash
# any board from this tree (the Arty and XUPV5 are off-limits).

PART    := xc7z020clg400-1
TOP     := pynq150_top
VIVADO  ?= /tools/Xilinx/Vivado/2019.1/bin/vivado

BUILD   := build
LOGDIR  := $(BUILD)/logs
BIT     := $(BUILD)/pynq150.bit

# TIMING_GATE=0 writes the bitstream even if slack is negative.
TIMING_GATE ?= 1

RTL := rtl/uart_rx.v rtl/uart_tx.v rtl/uart_echo.v rtl/pynq150_top.v
XDC := constr/pynq_z2.xdc

IP_TCL   := ip/clk_wiz_0.tcl
IP_DIR   := $(BUILD)/ip
IP_SRCS  := $(IP_DIR)/sources.f
IP_STAMP := $(IP_DIR)/clk_wiz_0.stamp

SYNTH_DCP := $(BUILD)/synth/post_synth.dcp
IMPL_DCP  := $(BUILD)/impl/post_route.dcp
TIMING_RPT := $(BUILD)/impl/timing_summary.rpt

VIVADO_BAT := $(VIVADO) -mode batch -notrace -nojournal

SIM_TOP  := tb_uart_echo
SIM_SRCS := rtl/uart_rx.v rtl/uart_tx.v rtl/uart_echo.v sim/tb_uart_echo.v
SIM_VVP  := sim/tb_uart_echo.vvp

.PHONY: all help ip synth impl bit timing sim clean

# Default: bitstream plus a printed timing summary.
all: bit timing

help:
	@echo "pynq150  PYNQ-Z2 (xc7z020clg400-1) PL-only UART echo"
	@echo
	@echo "Targets:"
	@echo "  make          same as 'make all'"
	@echo "  make all      bitstream + timing summary"
	@echo "  make ip       generate clk_wiz_0 (125 MHz MMCM)"
	@echo "  make synth    synthesis  -> $(SYNTH_DCP)"
	@echo "  make impl     place/route -> $(IMPL_DCP)"
	@echo "  make bit      write $(BIT) (refuses if timing fails)"
	@echo "  make timing   print WNS/WHS from the route checkpoint"
	@echo "  make sim      Icarus Verilog test of the UART echo loop"
	@echo "  make clean    remove build/ and sim products"
	@echo
	@echo "Options:"
	@echo "  VIVADO=/path/to/vivado   default: $(VIVADO)"
	@echo "  TIMING_GATE=0            write a bitstream even with negative slack"
	@echo
	@echo "There is no 'program' target. Do not program the Arty or XUPV5."

ip: $(IP_STAMP)

$(IP_STAMP): $(IP_TCL) scripts/ip.tcl
	@mkdir -p $(IP_DIR) $(LOGDIR)
	$(VIVADO_BAT) -log $(LOGDIR)/ip.log -source scripts/ip.tcl \
		-tclargs $(PART) $(abspath $(IP_TCL)) $(abspath $(IP_DIR))
	@test -s $(IP_SRCS)
	@touch $@

synth: $(SYNTH_DCP)

$(SYNTH_DCP): $(IP_STAMP) $(RTL) $(XDC) scripts/synth.tcl
	@mkdir -p $(BUILD)/synth $(LOGDIR)
	$(VIVADO_BAT) -log $(LOGDIR)/synth.log -source scripts/synth.tcl \
		-tclargs $(PART) $(TOP) $(abspath $(BUILD)/synth) \
		$(abspath $(XDC)) $(abspath $(IP_SRCS)) $(abspath $(RTL))

impl: $(IMPL_DCP)

$(IMPL_DCP): $(SYNTH_DCP) scripts/impl.tcl scripts/common.tcl
	@mkdir -p $(BUILD)/impl $(LOGDIR)
	$(VIVADO_BAT) -log $(LOGDIR)/impl.log -source scripts/impl.tcl \
		-tclargs $(abspath $(SYNTH_DCP)) $(abspath $(BUILD)/impl)

bit: $(BIT)

$(BIT): $(IMPL_DCP) scripts/bit.tcl scripts/common.tcl
	@mkdir -p $(LOGDIR)
	$(VIVADO_BAT) -log $(LOGDIR)/bit.log -source scripts/bit.tcl \
		-tclargs $(abspath $(IMPL_DCP)) $(abspath $(BIT)) $(TIMING_GATE)

timing: $(IMPL_DCP) scripts/timing.tcl scripts/common.tcl
	@mkdir -p $(LOGDIR)
	$(VIVADO_BAT) -log $(LOGDIR)/timing.log -source scripts/timing.tcl \
		-tclargs $(abspath $(IMPL_DCP)) $(abspath $(TIMING_RPT))

sim: $(SIM_VVP)
	vvp $(SIM_VVP)

$(SIM_VVP): $(SIM_SRCS)
	iverilog -g2005 -o $(SIM_VVP) -s $(SIM_TOP) $(SIM_SRCS)

clean:
	rm -rf $(BUILD) .Xil
	rm -f $(SIM_VVP) sim/*.vcd *.jou *.log *webtalk* usage_statistics_* vivado*.backup.log
