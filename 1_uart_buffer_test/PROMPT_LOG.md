# PROMPT_LOG — 1_uart_buffer_test

Condensed, AI-readable brief for regenerating this mini-project.

## Goal

A PL-only 256-byte UART buffer test on the PYNQ-Z2. Receive 256 bytes at
115200 8N1 into a local buffer, then replay them in order on the UART
transmitter. No AXI, no PS, no DDR. After the replay, return to receiving
the next 256-byte block. TX must not start until all 256 bytes have been
accepted.

## Context

- Repo: `/home/ejr/pynq150`, branch `jtag-axi-ddr-test` (HEAD `6255d8e`).
- Companion project: `../2_axi_ddr_test/` (UART + AXI4 master to HP0 DDR).
- The original root `rtl/pynq150_top.v`, `rtl/uart_echo.v`, `sim/tb_uart_echo.v`,
  `Makefile` and `README.md` are left unchanged. This folder is standalone.
- UART PHY is reused, not copied: `../rtl/uart_rx.v`, `../rtl/uart_tx.v`.
- Board clock: 125 MHz `sysclk` (H16) through the repo `clk_wiz_0` MMCM
  (`../ip/clk_wiz_0.tcl`). Baud divisor `125_000_000 / 115200 = 1085`.
- Icarus testbench runs the DUT at 10 MHz (still 115200 8N1) so the test
  finishes quickly, matching the root `tb_uart_echo.v` approach.
- Pmod USBUART on Pmod A, top row; Pmod JP1 = LCL.

## Files

| Path | Purpose |
|------|---------|
| `rtl/uart_buffer.v` | FSM: ST_RX stores 256 bytes in a 256x8 distributed-RAM array, then ST_TX plays them back via `uart_tx`. |
| `rtl/uart_buffer_top.v` | Board wrapper: `clk_wiz_0`, BTN0 + unlock reset, heartbeat, LEDs, instantiates `uart_buffer`. |
| `sim/tb_uart_buffer.v` | Icarus TB: two 256-byte frames, pattern `(i*7+3+salt)&0xFF`, no TX before the 256th `rx_valid`, in-order replay. |
| `constr/pynq_z2.xdc` | Same PYNQ-Z2 pins as the root XDC; LD3 is TX-phase instead of unused. |
| `Makefile` | `make sim` (Icarus); optional `make bit` via `scripts/build_pl.tcl`. No program target. |
| `scripts/build_pl.tcl` | Optional non-project Vivado synth/impl/bit into `build/`. Does not program a board. |
| `README.md` | How to simulate and optionally build. |
| `.gitignore` | Ignores `*.vvp`, `*.vcd`, `.Xil/`, `build/`. |
| `PROMPT_LOG.md` | This file. |

Reused (not in this folder): `../rtl/uart_rx.v`, `../rtl/uart_tx.v`,
`../ip/clk_wiz_0.tcl`, `../scripts/ip.tcl`.

## Design Decisions

- Two-state FSM: `ST_RX` then `ST_TX`, then back to `ST_RX`.
- 256x8 `buf_mem` is a register array, expected to infer distributed RAM.
- `tx_start` is a one-cycle pulse when `!tx_busy`, same convention as `uart_echo`.
- LEDs: LD0 heartbeat (~0.93 Hz on 125 MHz, `hb_cnt[26]`); LD1 toggles on
  each received byte; LD2 MMCM locked; LD3 high during the TX replay phase.
- Pins (from TUL PYNQ-Z2 master XDC): `uart_txd` Y19 (JA pin 2),
  `uart_rxd` Y16 (JA pin 3), BTN0 D19, LEDs R14/P14/N16/M14.
- The Icarus host bit period is the DUT period (`CLK_NS * (CLK_FREQ/BAUD)`).
  `recv_byte` returns after sampling the stop bit (no extra half-bit wait)
  so back-to-back DUT bytes are not overshot. The receiver is forked so a
  start bit that begins during the host's last stop bit is not missed.
  Early-TX is only an error if it happens before the 256th `rx_valid`.

## Protocol

Host -> DUT: 256 data bytes, 115200 8N1, no address, no header.
DUT -> host: the same 256 bytes, in order, only after the 256th byte is
accepted. Then the FSM is ready for another 256-byte block.

## Test Plan

From this directory: `make sim`

```
iverilog -g2005 -o sim/tb_uart_buffer.vvp -s tb_uart_buffer \
    rtl/uart_buffer.v ../rtl/uart_rx.v ../rtl/uart_tx.v sim/tb_uart_buffer.v
vvp sim/tb_uart_buffer.vvp
```

Icarus 12 on UBU24 (2026-11-26): **ALL TESTS PASSED**

- Frame salt=0: no TX during the 256-byte write; 256 bytes replayed in order.
- Frame salt=11: same, confirming the FSM returns to RX.
- `rx_toggle` flipped.

Optional hardware: `make bit` writes `build/uart_buffer.bit`. There is no
`program` target; this test has not been run on the board from this folder.

## Open Items

- No on-board run of this PL-only design yet (the hardware effort is on
  `2_axi_ddr_test`).
- Optional bitstream has not been built.
