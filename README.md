# pynq150

A standalone Vivado 2019.1 tree for the **PYNQ-Z2** (`xc7z020clg400-1`).
It is not a fork of proj150. Each numbered folder is a self-contained
mini-project; build and simulate from inside it.

| Folder | What it is |
|--------|------------|
| `00_jtag_axi_ddr_test/` | JTAG-to-AXI demonstration of HP0 DDR read/write. |
| `01_uart_echo/` | UART echo loop on Pmod A (115200 8N1). `make overlay` adds a dummy PS7 so it loads from Linux. |
| `02_uart_buffer_test/` | 256-byte UART buffer replay. `make overlay` adds a dummy PS7 so it loads from Linux. |
| `03_axi_ddr_test/` | UART-driven 64-bit AXI4 master: write 256 bytes to DDR via HP0, read back, compare, report PASS/FAIL. |
| `04_uart_ddr_block_test/` | Single UART characters trigger a full-speed PL-generated 1 MiB DDR write (`W`) and read+compare (`R` -> `P`/`F`) over HP0. |
| `05_request_controller_test/` | Verbatim cs150 `RequestController` with a fake dcache client; `rc_axi_adapter` replaces MIG and masters AXI4 on HP0. UART `G` writes and reads 1 MiB through the dcache port -> `P`/`F`. |
| `06_request_controller_arb_test/` | 05 plus the proj150 `mig_caf`/`mig_wdf`/`mig_rdf` FIFOs between the unmodified `RequestController` and the AXI master (`rc_axi_fifo_adapter`): up to 8 writes and 8 reads in flight, plus a streaming-read mode (`B`). Hardware PASS: write 609 MB/s, streaming read 528 MB/s, dcache-port read 54 MB/s. |
| `07_hdmi_test_pattern/` | 640x480@60 HDMI colour-bar test pattern on the HDMI OUT port (Digilent rgb2dvi, own MMCM and timing). No DDR. `make overlay` builds a PS7 overlay. Sim and build only, not yet run on hardware. |

Examples:

```
make -C 01_uart_echo sim
make -C 01_uart_echo overlay
make -C 02_uart_buffer_test sim
make -C 02_uart_buffer_test overlay
make -C 03_axi_ddr_test sim
make -C 04_uart_ddr_block_test sim
make -C 04_uart_ddr_block_test overlay
make -C 05_request_controller_test sim
make -C 05_request_controller_test overlay
make -C 07_hdmi_test_pattern sim
make -C 07_hdmi_test_pattern sim-tmds
make -C 07_hdmi_test_pattern overlay
```

There is no `program` target. Do not program the Arty or the XUPV5.
Vivado outputs go under each folder's `build/` or the repo-root `build/`
(both gitignored).
