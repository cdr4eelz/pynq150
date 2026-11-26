# 05_request_controller_test: cs150 RequestController (verbatim) driven by a
# fake dcache; an adapter in MIG's place masters AXI4 on HP0. Run from here.
# Reuses ../01_uart_echo/rtl/uart_{rx,tx}.v and
# ../03_axi_ddr_test/sim/axi4_slave_mem.v (not copied). No program target.

VIVADO  ?= /tools/Xilinx/Vivado/2019.1/bin/vivado
REPO    := ..

UART_RX := $(REPO)/01_uart_echo/rtl/uart_rx.v
UART_TX := $(REPO)/01_uart_echo/rtl/uart_tx.v
AXI_MEM := $(REPO)/03_axi_ddr_test/sim/axi4_slave_mem.v

RTL      := rtl/rc_ddr_test.v rtl/RequestController.v rtl/dcache_tester.v \
            rtl/rc_axi_adapter.v
SIM_TOP  := tb_rc_ddr_test
SIM_SRCS := $(RTL) $(UART_RX) $(UART_TX) $(AXI_MEM) sim/tb_rc_ddr_test.v

VIVADO_BAT := $(VIVADO) -mode batch -notrace -nojournal

.PHONY: all help sim sim16 sim64 overlay clean

all: sim

help:
	@echo "05_request_controller_test  (UART char -> fake dcache -> RequestController -> AXI4 HP0)"
	@echo "  make sim      Icarus: 16 KiB (512 lines) and 64 KiB (2048 lines) runs"
	@echo "  make overlay  Vivado 2019.1 PS7+SmartConnect bitstream + hwh"
	@echo "                (../build/rc_test/). Does NOT program a board."
	@echo "  make clean    remove sim products"

sim: sim16 sim64

sim16: $(SIM_SRCS)
	iverilog -g2005 -o sim/tb16.vvp -s $(SIM_TOP) -P$(SIM_TOP).LINES=512 -P$(SIM_TOP).WIN_AW=14 -P$(SIM_TOP).MEM_AW=16 $(SIM_SRCS)
	vvp -n sim/tb16.vvp

sim64: $(SIM_SRCS)
	iverilog -g2005 -o sim/tb64.vvp -s $(SIM_TOP) -P$(SIM_TOP).LINES=2048 -P$(SIM_TOP).WIN_AW=16 -P$(SIM_TOP).MEM_AW=17 $(SIM_SRCS)
	vvp -n sim/tb64.vvp

overlay:
	@mkdir -p $(REPO)/build/logs
	$(VIVADO_BAT) -log $(REPO)/build/logs/rc_test.log -source build_rc_test.tcl

clean:
	rm -f sim/*.vvp sim/*.vcd *.jou *.log
