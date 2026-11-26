# 06_request_controller_arb_test: cs150 RequestController (verbatim) driven by a
# fake dcache; the proj150 mig_caf/mig_wdf/mig_rdf FIFOs + an AXI master in
# MIG's place (rtl/rc_axi_fifo_adapter.v). Run from here.
# Reuses ../01_uart_echo/rtl/uart_{rx,tx}.v (not copied). Sim uses the
# Icarus FIFO stand-ins in sim/models/ (copied from proj150); `make overlay`
# builds the real FIFO Generator IPs from ip/*.tcl (copied from proj150).
# No program target.

VIVADO  ?= /tools/Xilinx/Vivado/2019.1/bin/vivado
REPO    := ..

UART_RX := $(REPO)/01_uart_echo/rtl/uart_rx.v
UART_TX := $(REPO)/01_uart_echo/rtl/uart_tx.v
AXI_MEM := sim/axi4_slave_pipe.v
FIFO_MODELS := sim/models/ip_fifos.v sim/models/fifo_async_fwft_model.v

RTL      := rtl/rc_ddr_test.v rtl/RequestController.v rtl/dcache_tester.v \
            rtl/rc_axi_fifo_adapter.v
SIM_TOP  := tb_rc_ddr_test
SIM_SRCS := $(RTL) $(FIFO_MODELS) $(UART_RX) $(UART_TX) $(AXI_MEM) sim/tb_rc_ddr_test.v
# 05's register-only adapter, kept for A/B sim runs (make simref)
REF_SRCS := rtl/rc_ddr_test.v rtl/RequestController.v rtl/dcache_tester.v \
            rtl/rc_axi_adapter.v $(UART_RX) $(UART_TX) $(AXI_MEM) sim/tb_rc_ddr_test.v

VIVADO_BAT := $(VIVADO) -mode batch -notrace -nojournal

.PHONY: all help sim sim16 sim64 simref overlay clean

all: sim

help:
	@echo "06_request_controller_arb_test  (UART char -> fake dcache -> RequestController -> mig_* FIFOs -> AXI4 HP0)"
	@echo "  make sim      Icarus: 16 KiB (512 lines) and 64 KiB (2048 lines) runs"
	@echo "  make simref   same tests on 05's register-only adapter (A/B numbers)"
	@echo "  make overlay  Vivado 2019.1 PS7+SmartConnect bitstream + hwh"
	@echo "                (../build/rc_arb_test/). Does NOT program a board."
	@echo "  make clean    remove sim products"

sim: sim16 sim64

sim16: $(SIM_SRCS)
	iverilog -g2005 -o sim/tb16.vvp -s $(SIM_TOP) -P$(SIM_TOP).LINES=512 -P$(SIM_TOP).WIN_AW=14 -P$(SIM_TOP).MEM_AW=16 $(SIM_SRCS)
	vvp -n sim/tb16.vvp

sim64: $(SIM_SRCS)
	iverilog -g2005 -o sim/tb64.vvp -s $(SIM_TOP) -P$(SIM_TOP).LINES=2048 -P$(SIM_TOP).WIN_AW=16 -P$(SIM_TOP).MEM_AW=17 $(SIM_SRCS)
	vvp -n sim/tb64.vvp

simref:
	iverilog -g2005 -DREF_ADAPTER -o sim/tbref.vvp -s $(SIM_TOP) -P$(SIM_TOP).LINES=2048 -P$(SIM_TOP).WIN_AW=16 -P$(SIM_TOP).MEM_AW=17 $(REF_SRCS)
	vvp -n sim/tbref.vvp

overlay:
	@mkdir -p $(REPO)/build/logs
	$(VIVADO_BAT) -log $(REPO)/build/logs/rc_test.log -source build_rc_test.tcl

clean:
	rm -f sim/*.vvp sim/*.vcd *.jou *.log
