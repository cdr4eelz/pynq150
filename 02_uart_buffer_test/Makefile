# 256-byte UART buffer test. Run from this directory.
# Reuses ../01_uart_echo/rtl/uart_rx.v and ../01_uart_echo/rtl/uart_tx.v (do not copy them).
# There is no program target.

VIVADO  ?= /tools/Xilinx/Vivado/2019.1/bin/vivado
REPO    := ..
PART    := xc7z020clg400-1
TOP     := uart_buffer_top

UART_RX := $(REPO)/01_uart_echo/rtl/uart_rx.v
UART_TX := $(REPO)/01_uart_echo/rtl/uart_tx.v

SIM_TOP  := tb_uart_buffer
SIM_SRCS := rtl/uart_buffer.v $(UART_RX) $(UART_TX) sim/tb_uart_buffer.v
SIM_VVP  := sim/tb_uart_buffer.vvp

BUILD   := build
LOGDIR  := $(BUILD)/logs
BIT     := $(BUILD)/uart_buffer.bit
IP_TCL  := $(REPO)/01_uart_echo/ip/clk_wiz_0.tcl
IP_DIR  := $(BUILD)/ip
IP_SRCS := $(IP_DIR)/sources.f
IP_STAMP:= $(IP_DIR)/clk_wiz_0.stamp
RTL     := rtl/uart_buffer.v rtl/uart_buffer_top.v $(UART_RX) $(UART_TX)
XDC     := constr/pynq_z2.xdc

VIVADO_BAT := $(VIVADO) -mode batch -notrace -nojournal

.PHONY: all help sim bit clean

all: sim

help:
	@echo "02_uart_buffer_test  (PL-only 256-byte UART buffer replay)"
	@echo "  make sim    Icarus test: send 256 bytes, check in-order replay"
	@echo "  make bit    optional Vivado 2019.1 bitstream (does NOT program)"
	@echo "  make clean  remove sim and build products"

sim: $(SIM_VVP)
	vvp $(SIM_VVP)

$(SIM_VVP): $(SIM_SRCS)
	iverilog -g2005 -o $(SIM_VVP) -s $(SIM_TOP) $(SIM_SRCS)

$(IP_STAMP): $(IP_TCL) $(REPO)/01_uart_echo/scripts/ip.tcl
	@mkdir -p $(IP_DIR) $(LOGDIR)
	$(VIVADO_BAT) -log $(LOGDIR)/ip.log -source $(REPO)/01_uart_echo/scripts/ip.tcl \
		-tclargs $(PART) $(abspath $(IP_TCL)) $(abspath $(IP_DIR))
	@test -s $(IP_SRCS)
	@touch $@

bit: $(IP_STAMP) $(RTL) $(XDC)
	@mkdir -p $(BUILD)/synth $(LOGDIR)
	$(VIVADO_BAT) -log $(LOGDIR)/bit.log -source scripts/build_pl.tcl \
		-tclargs $(PART) $(TOP) $(abspath $(BUILD)) $(abspath $(XDC)) \
		$(abspath $(IP_SRCS)) $(abspath $(RTL))

clean:
	rm -rf $(BUILD) .Xil
	rm -f $(SIM_VVP) sim/*.vcd *.jou *.log
