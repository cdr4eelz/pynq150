# 02_uart_buffer_test

256-byte UART buffer test for the PYNQ-Z2. It is a standalone folder;
`01_uart_echo/` is left unchanged and its UART PHY is reused by relative
path. `make overlay` wraps the existing top in a block design with a
dummy ZYNQ7 PS (PYNQ-Z2 board preset, DDR + FIXED_IO, no AXI) so the
design can be loaded from Linux with PYNQ's `Overlay` class without
taking the PS down. A PL-only bitstream (`make bit`) has no `.hwh` and
has frozen Linux when loaded.

## What it does

A small state machine (`rtl/uart_buffer.v`):

1. Receives 256 bytes at 115200 8N1 into a 256 x 8 distributed-RAM buffer.
2. After the 256th byte, reads the buffer out in order and transmits it.
3. Returns to receiving for the next 256-byte block.

No AXI from the UART logic (the dummy PS exposes DDR/FIXED_IO only, with
M_AXI_GP0 disabled). TX does not start until all 256 bytes have arrived.
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

## Optional PL-only bitstream

`make bit` builds a PL-only bitstream with Vivado 2019.1 into
`build/uart_buffer.bit` using `../01_uart_echo/ip/clk_wiz_0.tcl` and
`../01_uart_echo/scripts/ip.tcl`. It does **not** program any board and has
no `.hwh`. There is no `program` target.

## Load and test (PYNQ Overlay)

`make overlay` builds `build/overlay/uart_buffer.bit` and
`build/overlay/uart_buffer.hwh` (same basename): dummy PS7 plus the
existing `uart_buffer_top`. UART clocking and pinout are unchanged.

Copy both files to the board, for example `/home/xilinx/uart_tests/`.
SSH as `xilinx` (default password `xilinx`). Then on the board, with sudo
and the PYNQ environment:

```
source /etc/profile.d/boardname.sh
source /etc/profile.d/xrt_setup.sh
source /etc/profile.d/pynq_venv.sh
python3 -c "from pynq import Overlay; Overlay('/home/xilinx/uart_tests/uart_buffer.bit')"
```

Confirm ping and SSH still work after the load. Then on the host, open the
Pmod USBUART at **115200 8N1**, no flow control (usually `/dev/ttyUSB3`).
Send 256 bytes; the FPGA stays silent until the 256th byte, then replays
them in order. The Icarus pattern is `(i*7 + 3 + salt) & 0xFF` (salts 0
and 11). Do not `program_hw_devices` while Linux is running.

Pmod USBUART wiring is the same as the 01 README (JA pin 2 = FPGA TX,
JA pin 3 = FPGA RX, Pmod JP1 = LCL).
