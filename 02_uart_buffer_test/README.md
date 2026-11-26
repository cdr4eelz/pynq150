# 02_uart_buffer_test

PL-only 256-byte UART buffer test for the PYNQ-Z2. It is a standalone
folder; the original `rtl/pynq150_top.v`, `sim/tb_uart_echo.v` and root
`Makefile` are left unchanged.

## What it does

A small state machine (`rtl/uart_buffer.v`):

1. Receives 256 bytes at 115200 8N1 into a 256 x 8 distributed-RAM buffer.
2. After the 256th byte, reads the buffer out in order and transmits it.
3. Returns to receiving for the next 256-byte block.

No AXI, no PS, no DDR. TX does not start until all 256 bytes have arrived.
The UART PHY is the existing `../01_uart_echo/rtl/uart_rx.v` and `../01_uart_echo/rtl/uart_tx.v`
(referenced by relative path, not copied).

`uart_buffer_top.v` is the board wrapper: 125 MHz `sysclk` through the
repo's `clk_wiz_0` MMCM (divisor `125_000_000 / 115200 = 1085`), BTN0
reset, Pmod A UART. LEDs:

| LED | Meaning |
|-----|---------|
| LD0 | Heartbeat (~0.93 Hz) |
| LD1 | Toggles on each received byte |
| LD2 | MMCM locked |
| LD3 | High during the TX replay phase |

## Simulation

From this directory, on UBU24 (Icarus 12):

```
make sim
```

which is:

```
iverilog -g2005 -o sim/tb_uart_buffer.vvp -s tb_uart_buffer \
    rtl/uart_buffer.v ../01_uart_echo/rtl/uart_rx.v ../01_uart_echo/rtl/uart_tx.v sim/tb_uart_buffer.v
vvp sim/tb_uart_buffer.vvp
```

The testbench runs the DUT at 10 MHz (still 115200 8N1), sends two 256-byte
frames with pattern `(i*7 + 3 + salt) & 0xFF`, checks that TX stays idle
until the last RX byte, and checks that the replay is in order.

## Optional bitstream

`make bit` builds a bitstream with Vivado 2019.1 into `build/uart_buffer.bit`
using `../01_uart_echo/ip/clk_wiz_0.tcl` and `../01_uart_echo/scripts/ip.tcl`. It does **not**
program any board. There is no `program` target.

Pmod USBUART wiring is the same as the root README (JA pin 2 = FPGA TX,
JA pin 3 = FPGA RX, Pmod JP1 = LCL).
