# 03_axi_ddr_test

UART-driven AXI4 master DDR test for the PYNQ-Z2. A companion to
`02_uart_buffer_test/`. The existing `00_jtag_axi_ddr_test/` folder is left
untouched; `build_uart_axi.tcl` is a derived copy of that BD script with
the custom master added.

The original repo `rtl/pynq150_top.v`, `sim/` and root `Makefile` are
not used by this test.

## What it does

`rtl/uart_axi_ddr_test.v` sequences:

1. Receive a 4-byte little-endian destination address, then 256 data
   bytes, over UART at 115200 8N1 into a local 256 x 8 buffer.
2. Issue a 64-bit AXI4 INCR write burst of those 256 bytes (32 beats,
   `AWSIZE=3`, `AWLEN=31`), split if the transfer would cross a 4 KB
   boundary. Bits [2:0] of the address are ignored (forced 8-byte
   aligned).
3. Read the same 256 bytes back over AXI and compare against the local
   copy on the fly.
4. Report one 16-byte ASCII line and return to step 1:

   ```
   PASS 0x000 0x00\n
   FAIL 0xMMM 0xII\n
   ```

   `MMM` is the mismatch count (hex, 000..100) and `II` is the first
   mismatched byte index. A non-OKAY AXI response also produces FAIL.

The UART PHY is `../01_uart_echo/rtl/uart_rx.v` and `../01_uart_echo/rtl/uart_tx.v` (relative
path, not copied). The master connects to `S_AXI_HP0` (64-bit) through
PS7 + SmartConnect. JTAG-to-AXI 1.2 is kept as a second SmartConnect
slave for debug.

Clock is PS `FCLK_CLK0` at 100 MHz (baud divisor 868). LEDs, driven by
`rtl/uart_axi_top.v`:

| LED | Meaning |
|-----|---------|
| LD0 | Heartbeat (~0.75 Hz on FCLK) |
| LD1 | Toggles on each received UART byte |
| LD2 | FCLK alive / out of reset (no MMCM in this top) |
| LD3 | Last compare result (1 = PASS) |

## Simulation

From this directory:

```
make sim
```

which is:

```
iverilog -g2005 -o sim/tb_uart_axi_ddr.vvp -s tb_uart_axi_ddr \
    rtl/uart_axi_ddr_test.v ../01_uart_echo/rtl/uart_rx.v ../01_uart_echo/rtl/uart_tx.v \
    sim/axi4_slave_mem.v sim/tb_uart_axi_ddr.v
vvp sim/tb_uart_axi_ddr.vvp
```

The testbench includes a 64-bit AXI4 slave memory model with WSTRB,
INCR bursts and occasional ready backpressure. It checks:

- An aligned PASS at `0x16849000` (data lands in the slave memory, UART
  report is `PASS 0x000 0x00`, no TX during the 260-byte host write).
- A 4 KB-crossing PASS at `0x00000F08` (the master must split the burst).
- A FAIL case: `hold_arready` parks the read channel until the write
  lands, the testbench corrupts byte 42, then the DUT report is
  `FAIL 0x001 0x2A`.

## Hardware (not run from this tree)

`make bd` builds `../build/uart_axi_ddr/uart_axi_ddr.bit` (and `.hwh`,
`.ltx`) with Vivado 2019.1. It does **not** program any board. Load the
bitstream with PYNQ, not over JTAG (a JTAG reload under Linux has
frozen the board before).

1. Copy `uart_axi_ddr.bit`, `uart_axi_ddr.hwh` and `holder_uart_axi.py`
   to `/home/xilinx/uart_axi_ddr/` on the board.
2. On the board, in the PYNQ venv, run `holder_uart_axi.py` and read
   the physical address from `addr.txt`. The address is 8-byte (usually
   4 KB) aligned because `pynq.allocate` uses CMA pages.
3. On UBU24, with the Pmod USBUART on Pmod A (typically `/dev/ttyUSB3`):

   ```
   python3 host_uart_axi.py --addr 0x<addr> --port /dev/ttyUSB3
   ```

4. Expect a `PASS 0x000 0x00` line. On the board, `touch check` to
   inspect the buffer after `invalidate()`, then `touch stop` to free
   it. HP ports are not cache-coherent; the holder already flushes
   before the test and invalidates before the CPU inspects the buffer.

Do not use the XUPV5 JTAG cable.
