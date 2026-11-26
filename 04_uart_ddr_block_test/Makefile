# 04_uart_ddr_block_test: single-character UART triggers for full-speed
# PL-generated DDR block write / read-compare over HP0. Run from here.
# Reuses ../01_uart_echo/rtl/uart_{rx,tx}.v and
# ../03_axi_ddr_test/sim/axi4_slave_mem.v (not copied). No program target.

VIVADO  ?= /tools/Xilinx/Vivado/2019.1/bin/vivado
REPO    := ..

UART_RX := $(REPO)/01_uart_echo/rtl/uart_rx.v
UART_TX := $(REPO)/01_uart_echo/rtl/uart_tx.v
AXI_MEM := $(REPO)/03_axi_ddr_test/sim/axi4_slave_mem.v

SIM_TOP  := tb_uart_ddr_block
SIM_SRCS := rtl/uart_ddr_block_test.v $(UART_RX) $(UART_TX) $(AXI_MEM) \
            sim/tb_uart_ddr_block.v

VIVADO_BAT := $(VIVADO) -mode batch -notrace -nojournal

.PHONY: all help sim sim16 sim64 overlay clean

all: sim

help:
	@echo "04_uart_ddr_block_test  (UART char -> full-speed AXI4 HP0 DDR block W / R+compare)"
	@echo "  make sim      Icarus: 16 KiB and 64 KiB blocks against an AXI4 slave model"
	@echo "  make overlay  Vivado 2019.1 PS7+SmartConnect bitstream + hwh"
	@echo "                (../build/uart_ddr_block/). Does NOT program a board."
	@echo "  make clean    remove sim products"

sim: sim16 sim64

sim16: $(SIM_SRCS)
	iverilog -g2005 -o sim/tb16.vvp -s $(SIM_TOP) -P$(SIM_TOP).LEN=16384 -P$(SIM_TOP).MEM_AW=16 $(SIM_SRCS)
	vvp -n sim/tb16.vvp

sim64: $(SIM_SRCS)
	iverilog -g2005 -o sim/tb64.vvp -s $(SIM_TOP) -P$(SIM_TOP).LEN=65536 -P$(SIM_TOP).MEM_AW=17 $(SIM_SRCS)
	vvp -n sim/tb64.vvp

overlay:
	@mkdir -p $(REPO)/build/logs
	$(VIVADO_BAT) -log $(REPO)/build/logs/uart_ddr_block.log \
		-source build_ddr_block.tcl

clean:
	rm -f sim/*.vvp sim/*.vcd *.jou *.log
