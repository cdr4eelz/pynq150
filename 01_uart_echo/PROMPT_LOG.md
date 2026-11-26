# PROMPT_LOG — 01_uart_echo

Condensed, AI-readable brief for regenerating this mini-project.

## Goal

A PL-only UART echo loop on the PYNQ-Z2. Each byte received at 115200 8N1
on Pmod A is transmitted back out. A one-byte holding register covers the
case where a new byte finishes while a previous echo is still on the wire.
The Zynq PS is unused; clocking comes from the 125 MHz board oscillator
through `clk_wiz_0`.

## Context

- Repo: `/home/ejr/pynq150`, branch `jtag-axi-ddr-test`.
- These files originally lived at the repo root and were moved into
  `01_uart_echo/` so later tests can sit beside them. The UART PHY
  (`rtl/uart_rx.v`, `rtl/uart_tx.v`) is reused by
  `../02_uart_buffer_test/` and `../03_axi_ddr_test/` via relative paths
  (`../01_uart_echo/rtl/...`). Do not copy the PHY into those folders.
- `../00_jtag_axi_ddr_test/` is a separate JTAG-to-AXI HP0 demo and is not
  part of this echo design.
- Icarus testbench runs the DUT at 10 MHz (still 115200 8N1) so the test
  finishes quickly; the host uses a matching bit period.
- Pmod USBUART on Pmod A, top row; Pmod JP1 = LCL. The board's own
  USB-UART is wired to the PS, not the PL, so this design uses the Pmod.

## Files

| Path | Purpose |
|------|---------|
| `rtl/pynq150_top.v` | Board wrapper: `clk_wiz_0`, BTN0 + unlock reset, heartbeat, LEDs, instantiates `uart_echo`. |
| `rtl/uart_echo.v` | RX-to-TX echo with a one-byte holding register for back-to-back bytes. |
| `rtl/uart_rx.v` | Hand-written 8N1 receiver; samples at the bit midpoint. |
| `rtl/uart_tx.v` | Hand-written 8N1 transmitter; `start` is a one-cycle pulse when `busy` is low. |
| `sim/tb_uart_echo.v` | Icarus TB: short message, corner-case bytes, a back-to-back pair, and `rx_toggle`. |
| `constr/pynq_z2.xdc` | PYNQ-Z2 pins and the 8.00 ns `sysclk` constraint (TUL master XDC). |
| `ip/clk_wiz_0.tcl` | Clocking Wizard 6.0 MMCM: 125 MHz in, 125 MHz out, active-high reset, `locked`. |
| `scripts/*.tcl` | Non-project Vivado flow: `ip`, `synth`, `impl`, `bit`, `timing`, `common`. |
| `Makefile` | `make sim`, `make bit`, `make timing`. No `program` target. |
| `README.md` | Pins, clocking, build, and terminal test instructions. |
| `.gitignore` | Ignores `*.vvp`, `*.vcd`, `.Xil/`, `build/`. |
| `PROMPT_LOG.md` | This file. |

Run from this folder. Outputs go to `build/` (gitignored).

## Design Decisions

- Clock: 125 MHz board oscillator (H16) through `clk_wiz_0`. Baud divisor
  `125_000_000 / 115200 = 1085`. Logic stays in reset while BTN0 is held
  or the MMCM is unlocked (3-flop synchronizer).
- UART: 115200 8N1, no flow control. `uart_echo` will hold one pending
  byte if `tx_busy` is high when `rx_valid` pulses; a second overlapping
  byte would be dropped (see Open Items).
- Pins (TUL PYNQ-Z2 master XDC): `uart_txd` **Y19** (JA pin 2, Pmod RXD),
  `uart_rxd` **Y16** (JA pin 3, Pmod TXD), `sysclk` H16, BTN0 D19.
- LEDs: LD0 heartbeat (~0.93 Hz, `hb_cnt[26]` on 125 MHz); LD1 toggles
  on each received byte (`rx_toggle`); LD2 MMCM locked; LD3 tied low.
- Icarus: DUT at 10 MHz, `CLKS_PER_BIT = CLK_FREQ/BAUD`. The host
  bit-bangs UART with `BIT_NS = 1_000_000_000 / BAUD` in the original
  testbench and checks a short string, `0x00`/`0xFF`/`0xA5`/`0x5A`, and
  a back-to-back `0x11 0x22` pair.
- Build: Vivado 2019.1 non-project Makefile + Tcl. Default tool path
  `/tools/Xilinx/Vivado/2019.1/bin/vivado`. `make bit` refuses to write
  a bitstream if slack is negative unless `TIMING_GATE=0`.

## Protocol

Host <-> DUT, 115200 8N1: each received byte is echoed as soon as the
transmitter is free. There is no framing, address, or block length.
A one-byte hold register absorbs one byte that arrives while TX is busy.

## Test Plan

From this directory (or `make -C 01_uart_echo sim` from the repo root):

```
make sim
```

which is:

```
iverilog -g2005 -o sim/tb_uart_echo.vvp -s tb_uart_echo \
    rtl/uart_rx.v rtl/uart_tx.v rtl/uart_echo.v sim/tb_uart_echo.v
vvp sim/tb_uart_echo.vvp
```

Expect `tb_uart_echo: ALL TESTS PASSED` (short message, corner bytes,
back-to-back pair, `rx_toggle`).

Hardware (optional, not part of the default flow): `make bit` writes
`build/pynq150.bit`. There is no `program` target. Terminal test:
115200 8N1, no flow control, on the Pmod USBUART; typed characters
should echo and LD1 should toggle.

## Open Items

- Observed roughly **1-in-500 byte drop on 1024-byte bursts**. The echo
  path has only a one-byte holding register, so a second byte that
  arrives while a previous echo is still on the wire and the hold
  register is already full is dropped. A TX FIFO (deeper than one byte)
  is the intended fix.
- The README tells the user to set boot jumper **JP4** to JTAG. On the
  PYNQ-Z2 the boot-mode jumper is **JP1** (JTAG is the far-right
  position). JP1 on the Pmod USBUART (LCL) is a different jumper and is
  described correctly. Leave the README typo unless a later change
  specifically fixes it.
- The Zynq PS is unused in this design. A later test
  (`../03_axi_ddr_test/`) brings up PS7 and HP0.
