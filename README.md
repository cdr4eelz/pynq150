# pynq150

A standalone Vivado 2019.1 tree for the **PYNQ-Z2** (`xc7z020clg400-1`).
It is not a fork of proj150. Each numbered folder is a self-contained
mini-project; build and simulate from inside it.

| Folder | What it is |
|--------|------------|
| `00_uart_echo/` | Original PL-only UART echo loop on Pmod A (115200 8N1). |
| `1_uart_buffer_test/` | 256-byte UART buffer: receive 256 bytes, then replay them. No AXI. |
| `2_axi_ddr_test/` | UART-driven 64-bit AXI4 master: write 256 bytes to DDR via HP0, read back, compare, report PASS/FAIL. |
| `jtag_axi_ddr_test/` | JTAG-to-AXI demonstration of HP0 DDR read/write. |

Examples:

```
make -C 00_uart_echo sim
make -C 1_uart_buffer_test sim
make -C 2_axi_ddr_test sim
```

There is no `program` target. Do not program the Arty or the XUPV5.
Vivado outputs go under each folder's `build/` or the repo-root `build/`
(both gitignored).
