# PROMPT_LOG — 2_axi_ddr_test

Condensed, AI-readable brief for regenerating this mini-project.

## Goal

A UART-driven 64-bit AXI4 master DDR test on the PYNQ-Z2. Sequence:

1. Receive a 4-byte little-endian destination address, then 256 data bytes,
   over UART at 115200 8N1 into a local 256-byte buffer.
2. AXI4 master write burst of those 256 bytes to that physical address in
   DDR through PS7 `S_AXI_HP0` (64-bit) and SmartConnect.
3. AXI4 master read burst of the same 256 bytes.
4. Compare against the local copy (on the fly).
5. Report one 16-byte ASCII line on UART, then return to step 1.

## Context

- Repo: `/home/ejr/pynq150`, branch `jtag-axi-ddr-test` (HEAD `6255d8e`).
- Companion: `../1_uart_buffer_test/` (UART buffer replay, no AXI).
- Do **not** modify `../jtag_axi_ddr_test/`. `build_uart_axi.tcl` /
  `build.tcl` is a derived copy of that JTAG-to-AXI BD script, with the
  custom master added and JTAG-to-AXI kept as a second SmartConnect slave
  for debug.
- UART PHY is reused, not copied: `../rtl/uart_rx.v`, `../rtl/uart_tx.v`.
- Clock is PS `FCLK_CLK0` at 100 MHz (baud divisor `100_000_000/115200 = 868`).
  There is no MMCM in this top; LD2 is "FCLK alive / out of reset".
- Load the bitstream with PYNQ `Overlay` from Linux, **not** over JTAG
  (a JTAG reload under Linux has frozen the board). Never touch the XUPV5
  (`xilinx_tcf/Xilinx/00000000000000`, `ttyUSB2` FTDI `FTELAF9K`).
  The PYNQ TUL cable is `1234-tulA`. Pmod USBUART is `/dev/ttyUSB3`
  (FT232R `AV0KR19T`) on JA.
- HP0 is not cache-coherent: `flush()` after CPU fills, `invalidate()`
  before the CPU inspects PL writes.
- Overlay on the board needs: `source /etc/profile.d/boardname.sh;
  source /etc/profile.d/xrt_setup.sh; source /etc/profile.d/pynq_venv.sh`
  and typically `sudo`.
- Board: `xilinx@192.168.2.99`, password `xilinx`. UBU24 Vivado is
  `/tools/Xilinx/Vivado/2019.1/bin/vivado`.

## Files

| Path | Purpose |
|------|---------|
| `rtl/uart_axi_ddr_test.v` | UART + 64-bit AXI4 master FSM (buffer, write, read, compare, report). |
| `rtl/uart_axi_top.v` | BD module-reference wrapper: FCLK/reset, BTN0, LEDs, AXI4 port attributes. |
| `sim/axi4_slave_mem.v` | Icarus 64 KB AXI4 slave memory: INCR, WSTRB, backpressure, `hold_arready`. |
| `sim/tb_uart_axi_ddr.v` | Icarus TB: aligned PASS, 4 KB-crossing PASS, FAIL-injection. |
| `constr/pynq_z2_uart_axi.xdc` | UART/LED/BTN0 pins (no `sysclk`; clock is FCLK0). |
| `build_uart_axi.tcl` | Vivado 2019.1 project-mode BD + bitstream (canonical build script). |
| `build.tcl` | Same content as `build_uart_axi.tcl` (alias name). |
| `Makefile` | `make sim`; `make bd` runs the Tcl into `../build/uart_axi_ddr/`. No program target. |
| `holder_uart_axi.py` | Board-side: Overlay load, 16 KiB CMA buffer, sentinel, print PHYS/CROSS, check/stop. |
| `host_uart_axi.py` | UBU24 host: send 4-byte LE addr + 256 bytes on `/dev/ttyUSB3`, print the report line. |
| `README.md` | Protocol, sim, and hardware instructions. |
| `.gitignore` | Ignores `*.vvp`, `.Xil/`, `NA/`, `build/`. |
| `PROMPT_LOG.md` | This file. |

Build outputs (gitignored, under the repo `build/`): 
`../build/uart_axi_ddr/uart_axi_ddr.bit`, `.hwh`, `.ltx`, `util.rpt`, `timing.rpt`.

## Design Decisions

- Protocol: 4-byte little-endian address (raw binary, not hex text), then
  256 data bytes. First UART byte becomes `addr[7:0]`:
  `addr_shift <= {rx_data, addr_shift[31:8]}`.
- Address bits `[2:0]` are masked to 0 (forced 8-byte aligned). No other
  range check; the valid window is the HP0 DDR map (`0x00000000–0x1FFFFFFF`,
  512 MB on the PYNQ-Z2). Out-of-range should come back as an AXI decode
  error and is treated as FAIL (`axi_err`).
- 64-bit AXI4, `AWSIZE/ARSIZE=3`, `BURST=INCR`, 256 bytes = 32 beats
  (`AWLEN=31`) when the transfer does not cross a 4 KB boundary.
- 4 KB-safe: `beats_to_bdry = (4096 - addr[11:0]) >> 3`, burst length is
  `min(beats_to_bdry, beats_left)`. A 9-bit compare of 512 beats was
  signed/truncated to 0 in Icarus; the length is computed on a 10-bit wire
  (`cmd_burst`) instead of a 9-bit function return.
- WSTRB is all ones. `AWCACHE/ARCACHE=0011`. One outstanding transaction.
- Compare is on the fly during the read burst; 9-bit mismatch count
  (0..256) and first-bad index. Blocking temps in the beat so the first
  mismatch in a beat wins.
- Report (always 16 bytes):
  - `PASS 0x000 0x00\n`
  - `FAIL 0xMMM 0xII\n`
  where `MMM` is the hex mismatch count (`000..100`) and `II` is the first
  bad index. A non-OKAY AXI response also produces FAIL (count may be 0).
- Local buffer: 256x8 distributed RAM, packed little-endian into 64-bit
  beats (`byte0` in `WDATA[7:0]`).
- LEDs: LD0 heartbeat (~0.75 Hz on 100 MHz, `hb_cnt[26]`); LD1 toggles on
  each RX byte; LD2 `~rst` (FCLK alive); LD3 last result (1 = PASS).
- Pins: `uart_txd` Y19 (JA pin 2), `uart_rxd` Y16 (JA pin 3), BTN0 D19,
  LEDs R14/P14/N16/M14.
- BD: PS7 5.5, pynq-z2 board preset, HP0 64-bit, FCLK0 100 MHz,
  `proc_sys_reset`, SmartConnect `NUM_SI=2` (S00 = `uart_axi_top` 64-bit
  master, S01 = JTAG-to-AXI 1.2 32-bit), M00 = HP0. `uart_axi_top` is a
  module reference. BTN0 is OR'd with `~rst_n`.
- Holder allocates 16 KiB (`dtype=u1`), fills `0xEE`, flushes, prints
  `PHYS` and `CROSS = PHYS + 0xF80` (0x1000-0x80, 8-byte aligned; 0xF80+0x100
  crosses 4 KB). On `check`, invalidate and report both windows plus
  sentinel integrity outside them.

## Protocol

Host -> DUT (115200 8N1):

```
addr[7:0], addr[15:8], addr[23:16], addr[31:24], data[0] .. data[255]
```

DUT -> host, after write + read + compare:

```
PASS 0x000 0x00\n
FAIL 0xMMM 0xII\n
```

## Test Plan

### Simulation

From this directory: `make sim`

```
iverilog -g2005 -o sim/tb_uart_axi_ddr.vvp -s tb_uart_axi_ddr \
    rtl/uart_axi_ddr_test.v ../rtl/uart_rx.v ../rtl/uart_tx.v \
    sim/axi4_slave_mem.v sim/tb_uart_axi_ddr.v
vvp sim/tb_uart_axi_ddr.vvp
```

Icarus 12 on UBU24 (2026-11-26): **ALL TESTS PASSED**

1. Aligned PASS at `0x16849000`, pattern `(i*7+3)&0xFF`. Data lands in the
   slave memory (bytes before/after remain `0xCC`). UART report
   `PASS 0x000 0x00`. No TX during the 260-byte host write.
2. 4 KB-crossing PASS at `0x00000F08` (salt=11), same report; burst is split.
3. FAIL injection at `0x1684A000`: `hold_arready` until the write lands,
   corrupt byte 42 to `0x5A`, then report `FAIL 0x001 0x2A`.

### Hardware (PYNQ-Z2)

Build (does not program):

```
cd 2_axi_ddr_test
make bd
# -> ../build/uart_axi_ddr/uart_axi_ddr.{bit,hwh,ltx} and util/timing reports
```

On the board, copy `uart_axi_ddr.bit`, `uart_axi_ddr.hwh`, and
`holder_uart_axi.py` to `/home/xilinx/uart_axi_ddr/`. Load with PYNQ
`Overlay` (sudo + the three profile scripts above), not JTAG. Holder
prints the physical address. From UBU24:

```
python3 host_uart_axi.py --addr 0x<PHYS> --port /dev/ttyUSB3
python3 host_uart_axi.py --addr 0x<PHYS+0xF80> --port /dev/ttyUSB3 --salt 11
```

Then `touch /home/xilinx/uart_axi_ddr/check` (CPU invalidate + dump) and
`touch stop` to free the buffer. Confirm ping/SSH afterwards.

**Hardware results (2026-11-26, America/Los_Angeles):**

- Build: Vivado 2019.1 `write_bitstream Complete!` `BUILD_DONE` at 03:22.
  Bitstream `../build/uart_axi_ddr/uart_axi_ddr.bit` (same basename `.hwh`,
  plus `.ltx`, `util.rpt`, `timing.rpt`).
- Timing: all constraints met. WNS **+0.946 ns**, WHS **+0.022 ns**,
  TNS/THS 0. Clock `clk_fpga_0` 100 MHz.
- Utilization: 6982 slice LUTs (13.12%), 8653 slice registers (8.13%),
  2.5 BRAM tiles, 0 DSP, 7 bonded IOB.
- Loaded with PYNQ `Overlay` over SSH to `xilinx@192.168.2.99` (sudo +
  boardname/xrt_setup/pynq_venv). **Not** programmed over JTAG. Holder
  allocated 16 KiB at **PHYS=0x1684C000**, CROSS=**0x1684CF80**.
- Aligned UART test (`host_uart_axi.py --addr 0x1684C000 --salt 0` on
  `/dev/ttyUSB3`): exact response `PASS 0x000 0x00`.
  CPU after `invalidate()`: first `03 0A 11 18 1F 26 2D 34`, last `0xFC`
  (matches `(i*7+3)&0xFF`); bytes before/after `0xEE`; sentinel outside
  `mismatches_outside=0 PASS`.
- 4 KB-crossing UART test (`--addr 0x1684CF80 --salt 11`): exact response
  `PASS 0x000 0x00`.
  CPU: first `0E 15 1C 23 2A 31 38 3F`, last `0x07` (matches
  `(i*7+3+11)&0xFF`); before/after `0xEE`; aligned window still intact;
  sentinel `mismatches_outside=0 PASS`.
- Holder then `FREED` the buffer. Board still answers ping and SSH.
  Temporary SSH_ASKPASS script was deleted. The XUPV5 was not touched.
- Hardware FAIL-injection was skipped (no easy in-system corruption).
  The Icarus FAIL-injection case already reports `FAIL 0x001 0x2A`.

## Open Items

- No hardware FAIL-injection (skipped as not easy without a backdoor).
- `jtag_axi_ddr_test/` is unchanged; JTAG-to-AXI remains available on the
  same SmartConnect for debug but was not used by this UART test.
- The board's own clock is wrong (it reported 2022-10-25).
