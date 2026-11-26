# 04_uart_ddr_block_test

Full-speed DDR block test on the PYNQ-Z2, triggered by single UART
characters. The PL generates the data itself (no UART payload), writes a
1 MiB block to DDR through PS7 `S_AXI_HP0` at full AXI speed, reads it back
at full speed, checks every beat in the PL, and answers with one character.

Builds on `../03_axi_ddr_test/` (same PS7 + SmartConnect + JTAG-to-AXI
block design, same pins, same 100 MHz FCLK0). The UART PHY is reused from
`../01_uart_echo/rtl/` and the sim AXI slave from `../03_axi_ddr_test/sim/`.

## Protocol (Pmod USBUART on JA, `/dev/ttyUSB3`, 115200 8N1)

| Host sends | DUT does | Reply |
|------------|----------|-------|
| `A` + 4 bytes LE | set base address, bits [2:0] forced to 0 | `K` |
| `W` | seed = seed + 1, write `LEN` bytes of the pattern | `D` done, `E` if any BRESP was not OKAY |
| `R` | read `LEN` bytes, compare each beat with the pattern for the current seed | `P` pass, `F` fail (mismatch or RRESP error) |
| `T` | stats | 44-byte line `Wwwwwwwww Rrrrrrrrr Mmmmmmmmm Bbbbbbbbb Sss\n` |
| anything else | nothing | `?` |

- `W` and `R` reply `N` until an address has been set with `A`, so a reset
  never writes physical address 0.
- `T` fields (hex): last write cycles, last read cycles (at 100 MHz),
  mismatching beats in the last read, first bad beat index, current seed.
- Characters that arrive while a `W` or `R` is running are ignored.
- `LEN` is `LEN_BYTES` in `rtl/uart_ddr_block_top.v`, 1 MiB by default.

Pattern for 64-bit beat `i` from the base:
`lo = i ^ {4{seed}}`, `hi = ~{lo[15:0], lo[31:16]}`, beat = `{hi, lo}`
(little-endian in memory). The beat index makes every address unique; the
seed changes on every `W`, so a stale block from an earlier write fails `R`.

## AXI behaviour

- INCR bursts of 8-byte beats, at most 256 beats (2 KiB), split so no burst
  crosses a 4 KB boundary.
- Up to 4 bursts outstanding on each side. WVALID stays high across bursts
  (the next burst starts on the last beat of the previous one) and RREADY
  is always high, so the master never throttles the interconnect.
- Expected ceiling: 64 bits x 100 MHz = 800 MB/s, about 1.3 ms per 1 MiB.
  The UART command round trip (~0.1 ms per character) is small next to it.
  `T` reports the measured cycles.

## Simulation

```
make sim        # sim16 (16 KiB) and sim64 (64 KiB) against axi4_slave_mem
```

Covers: `W`/`R` refused before `A`, unknown character, write at a 4 KB-
unaligned base (0x16849F08, every burst split), whole-block memory check
plus untouched guard bytes, read `P`, `T` line parsed and matched to the
registers, two corrupted bytes then `R` -> `F` with `M=2 B=1000`, rewrite
(seed 2) -> `P`, and an `A` with [2:0] set being masked. A protocol monitor
checks AWLEN/ARLEN vs WLAST/RLAST counts and that no burst crosses 4 KB.

## Build (does not program a board)

```
make overlay
# -> ../build/uart_ddr_block/uart_ddr_block.{bit,hwh,ltx}, util.rpt, timing.rpt
```

## Running on the board

Load with PYNQ `Overlay` from Linux, never over JTAG (a JTAG load under
Linux has frozen the board). Never touch the XUPV5.

1. Copy `uart_ddr_block.bit`, `uart_ddr_block.hwh` and `holder_ddr_block.py`
   to `/home/xilinx/uart_ddr_block/` on `xilinx@192.168.2.99`.
2. On the board:
   ```
   sudo bash -c 'source /etc/profile.d/boardname.sh; source /etc/profile.d/xrt_setup.sh; \
     source /etc/profile.d/pynq_venv.sh; cd /home/xilinx/uart_ddr_block; python3 holder_ddr_block.py'
   ```
   It prints `PHYS=... BASE=...` (BASE = PHYS + 0xF08, buffer is LEN + 8 KiB
   filled with 0xEE).
3. On UBU24:
   ```
   python3 host_ddr_block.py --addr 0x<BASE> A W R T
   ```
   Expect `K`, `D`, `P`, and a stats line with `M00000000`.
4. CPU cross-check: `echo 1 > /home/xilinx/uart_ddr_block/check` (the seed
   from `S` in the stats line) -> `CPU_CHECK ... mismatches=0 sentinel_bad=0 PASS`.
5. Hardware FAIL injection: `echo 1000 > /home/xilinx/uart_ddr_block/corrupt`,
   then `python3 host_ddr_block.py --expect-fail R T` -> `F`, `M00000001 B000003E8`.
   `python3 host_ddr_block.py W R` repairs it.
6. `touch /home/xilinx/uart_ddr_block/stop` frees the buffer. Check ping/SSH.

## Hardware results (PYNQ-Z2, 2026-11-26)

PASS, loaded with PYNQ `Overlay` only (Linux stayed up). Base 0x16900F08:
`A W R T` -> `K D P`, `T` = `W00020029 R0002002C M00000000 B00000000 S01`.
CPU check of all 131072 beats: 0 mismatches, sentinels intact. CPU corrupt
of beat 1000 -> `R` = `F`, `T` shows `M00000001 B000003E8`. `W R` then
passed for seeds 2-7. Write and read both ran at ~799.7 MB/s (131113 cycles
for 131072 beats). UART round trip per command ~10-16 ms (USB-serial
latency). Details in PROMPT_LOG.md.

## LEDs

LD0 heartbeat, LD1 toggles per received byte, LD2 out of reset, LD3 last
`R` result (1 = PASS).
