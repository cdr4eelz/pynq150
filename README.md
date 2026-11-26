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

Examples:

```
make -C 01_uart_echo sim
make -C 01_uart_echo overlay
make -C 02_uart_buffer_test sim
make -C 02_uart_buffer_test overlay
make -C 03_axi_ddr_test sim
```

There is no `program` target. Do not program the Arty or the XUPV5.
Vivado outputs go under each folder's `build/` or the repo-root `build/`
(both gitignored).
