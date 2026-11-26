# UART-to-AXI DDR test. Run from this directory.
# Reuses ../00_uart_echo/rtl/uart_rx.v and ../00_uart_echo/rtl/uart_tx.v (do not copy them).
# Does not modify ../jtag_axi_ddr_test/. There is no program target.

VIVADO  ?= /tools/Xilinx/Vivado/2019.1/bin/vivado
REPO    := ..

UART_RX := $(REPO)/00_uart_echo/rtl/uart_rx.v
UART_TX := $(REPO)/00_uart_echo/rtl/uart_tx.v

SIM_TOP  := tb_uart_axi_ddr
SIM_SRCS := rtl/uart_axi_ddr_test.v $(UART_RX) $(UART_TX) \
            sim/axi4_slave_mem.v sim/tb_uart_axi_ddr.v
SIM_VVP  := sim/tb_uart_axi_ddr.vvp

VIVADO_BAT := $(VIVADO) -mode batch -notrace -nojournal

.PHONY: all help sim bd clean

all: sim

help:
	@echo "2_axi_ddr_test  (UART -> AXI4 HP0 DDR write/read/compare)"
	@echo "  make sim    Icarus test with an AXI4 slave memory model"
	@echo "  make bd     optional Vivado 2019.1 PS7+SmartConnect bitstream"
	@echo "              (../build/uart_axi_ddr/). Does NOT program a board."
	@echo "  make clean  remove sim products"

sim: $(SIM_VVP)
	vvp $(SIM_VVP)

$(SIM_VVP): $(SIM_SRCS)
	iverilog -g2005 -o $(SIM_VVP) -s $(SIM_TOP) $(SIM_SRCS)

bd:
	@mkdir -p $(REPO)/build/logs
	$(VIVADO_BAT) -log $(REPO)/build/logs/uart_axi_bd.log \
		-source build_uart_axi.tcl

clean:
	rm -f $(SIM_VVP) sim/*.vcd *.jou *.log
