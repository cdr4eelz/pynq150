# PROMPT_LOG — 04_uart_ddr_block_test

Condensed, AI-readable brief for regenerating this mini-project.

## Goal

A bigger, faster DDR test than 03, driven by single UART characters:

1. One character (`W`) makes the PL write a large block (1 MiB) of
   PL-generated data to DDR through PS7 `S_AXI_HP0` at full AXI speed.
   No UART payload.
2. A different character (`R`) makes the PL read the block back at full
   speed, compare every beat in the PL, and answer with one character
   (`P` / `F`).
3. A one-time `A` + 4-byte address sets the base (the holder's CMA buffer);
   `T` returns cycle counts and mismatch info for throughput and debug.

Origin: Erik asked for "bigger UART-to-DDR block transfers", then refined
it (t223u): "take a single uart stimulus then send a large chunk of DDR
writes at full blast. Likewise, a different UART char triggers a read that
does a checksum and reports back success or failure in a single UART
character."

## Context

- Repo: `/home/ejr/pynq150`, branch `jtag-axi-ddr-test` (HEAD `f435daf`
  when this folder was created).
- Builds on `../03_axi_ddr_test/` (block design, pins, top wrapper style).
  03 is not modified. Its sim AXI slave is reused by relative path.
- UART PHY is reused, not copied: `../01_uart_echo/rtl/uart_rx.v`,
  `../01_uart_echo/rtl/uart_tx.v`.
- Clock is PS `FCLK_CLK0` at 100 MHz (baud divisor 868).
- Load with PYNQ `Overlay` from Linux, **not** over JTAG. Never touch the
  XUPV5 (`xilinx_tcf/Xilinx/00000000000000`, `ttyUSB2`). PYNQ TUL cable is
  `1234-tulA`. Pmod USBUART is `/dev/ttyUSB3` (FT232R `AV0KR19T`) on JA.
- HP0 is not cache-coherent: `flush()` after CPU writes, `invalidate()`
  before CPU reads of PL-written data.
- Overlay load needs `sudo` plus `source /etc/profile.d/boardname.sh;
  source /etc/profile.d/xrt_setup.sh; source /etc/profile.d/pynq_venv.sh`.
- Board `xilinx@192.168.2.99` (password `xilinx`). Vivado
  `/tools/Xilinx/Vivado/2019.1/bin/vivado`. Icarus 12.

## Files

| Path | Purpose |
|------|---------|
| `rtl/uart_ddr_block_test.v` | Command FSM + pipelined AXI4 write/read engines, pattern generator, PL compare, stats. |
| `rtl/uart_ddr_block_top.v` | BD module-reference wrapper (from 03's top): FCLK/reset, BTN0, LEDs, AXI4 attributes, `LEN_BYTES` = 1 MiB, 4 outstanding. |
| `sim/tb_uart_ddr_block.v` | Icarus TB with UART host model, AXI protocol monitor, memory checks, FAIL injection. |
| `constr/pynq_z2_ddr_block.xdc` | Same pins as 03 (UART on JA Y19/Y16, LEDs, BTN0). |
| `build_ddr_block.tcl` | Vivado 2019.1 BD build (PS7 HP0 64-bit, SmartConnect 2 SI, JTAG-to-AXI, proc_sys_reset). |
| `Makefile` | `make sim` (16 KiB + 64 KiB runs), `make overlay`. No program target. |
| `holder_ddr_block.py` | Board side: Overlay, CMA buffer LEN + 8 KiB with 0xEE sentinel, prints BASE = PHYS + 0xF08; `check`/`corrupt`/`stop` files. |
| `host_ddr_block.py` | UBU24 side: send `A`/`W`/`R`/`T` on `/dev/ttyUSB3`, check replies, print MB/s. |
| `README.md` | Protocol, sim, build, board steps. |
| `.gitignore` | Same as 03. |
| `PROMPT_LOG.md` | This file. |

Shared (not copied): `../01_uart_echo/rtl/uart_{rx,tx}.v`,
`../03_axi_ddr_test/sim/axi4_slave_mem.v`.
Build outputs (gitignored): `../build/uart_ddr_block/uart_ddr_block.{bit,hwh,ltx}`,
`util.rpt`, `timing.rpt`.

## Design Decisions

- **Single-character commands, no payload.** Data comes from a PL pattern
  generator, so the transfer runs at AXI speed instead of UART speed.
- **Base address via a one-time `A` command** rather than compile-time or
  JTAG-AXI: the CMA physical address changes per allocation, and this keeps
  the host the only tool needed. `W`/`R` reply `N` until `A` is seen, so a
  reset can never blast 1 MiB at physical address 0.
- **Pattern** `lo = i ^ {4{seed}}`, `hi = ~rot16(lo)`: beat index makes each
  address unique (catches aliasing/dropped beats), `~` toggles every bit,
  and the seed increments on each `W` so a stale block fails `R`. Cheap in
  logic and easy to regenerate in numpy.
- **Compare instead of checksum.** The PL regenerates the expected beat and
  compares all 64 bits per beat, which is exact and no more logic than a
  CRC. It also gives a mismatch count and the first bad beat for `T`.
- **Fixed length** `LEN_BYTES` parameter (1 MiB default, multiple of 8).
- **Bursts** max 256 beats and split at 4 KB; length = min(256, beats to
  4 KB, remaining). Independent AW and W engines compute the same split; W
  never starts a burst before its AW has been launched (W may precede the
  AW handshake, which AXI allows). Up to `MAX_OUT` = 4 bursts outstanding
  per side; WVALID continuous across bursts; RREADY always high.
- **Single character replies**: `K`, `D`/`E`, `P`/`F`, `N`, `?`. Only `T`
  sends a line.
- Same BD as 03 (JTAG-to-AXI kept on SmartConnect S01 for debug).

## Protocol

```
'A' a0 a1 a2 a3  -> 'K'          base = {a3,a2,a1,a0} & ~7
'W'              -> 'D' | 'E'    seed += 1; write LEN bytes
'R'              -> 'P' | 'F'    read LEN bytes, compare in PL
'T'              -> "Wwwwwwwww Rrrrrrrrr Mmmmmmmmm Bbbbbbbbb Sss\n"
'W'/'R' before 'A' -> 'N'; other -> '?'
beat i: lo = i ^ {4{seed}}, hi = ~{lo[15:0], lo[31:16]}, data = {hi, lo}
```

## Test Plan

### Simulation

`make sim` runs the TB twice: LEN = 16 KiB (MEM_AW 16) and 64 KiB
(MEM_AW 17), base 0x16849F08. Icarus 12 on UBU24 (2026-11-26):
**ALL TESTS PASSED** in both runs.

1. `W`, `R` before `A` -> `N`, no AXI traffic; `x` -> `?`.
2. `A` 0x16849F08 -> `K`; `W` -> `D`; whole block matches seed 1, guard
   bytes untouched; `R` -> `P`; `T` parsed and matched to the DUT registers.
   16 KiB: 9 bursts, write 2756 / read 2742 cycles; 64 KiB: 33 bursts,
   10988 / 10992 cycles (~596 MB/s; the slave model stalls ~25% of cycles
   and accepts one burst at a time).
3. Two bytes corrupted in the model (beat 1000 and the last beat) -> `R` ->
   `F`, `T` shows `M00000002 B000003E8`.
4. `W` (seed 2) -> `D`, memory matches seed 2, `R` -> `P`.
5. `A` 0x16840003 -> base 0x16840000; `W` `D`, memory/guards OK, `R` `P`.

Monitor: every AW/AR is INCR size 3, aligned, and does not cross 4 KB;
WLAST/RLAST land exactly at AxLEN+1; total beats = LEN/8.

### Hardware (PYNQ-Z2)

Build (`make overlay`, 2026-11-26 09:07 PST): `write_bitstream Complete!`,
`BUILD_DONE`. All timing constraints met: WNS **+1.110 ns**, WHS +0.019 ns,
TNS/THS 0 at 100 MHz. Utilization: 7307 slice LUTs (13.73%), 9300 slice
registers (8.74%), 2.5 BRAM tiles, 0 DSP, 7 bonded IOB. Outputs
`../build/uart_ddr_block/uart_ddr_block.{bit,hwh}` (same basename).
The usual PYNQ-Z2 preset `PSU-1..4` negative DQS-delay critical warnings
appear, as in 03.

On-board run (2026-11-26, ~09:12 PST): **PASS**. Loaded only with PYNQ
`Overlay` under sudo (no JTAG); Linux stayed up throughout. Bit md5 on the
board matched the build. Holder: `PHYS=0x16900000 BASE=0x16900F08
LEN=1048576` (the block crosses many 4 KB pages).

`host_ddr_block.py` on `/dev/ttyUSB3`:

| Step | Result |
|------|--------|
| `--addr 0x16900F08 A W R T` | `K`, `D`, `P`, `W00020029 R0002002C M00000000 B00000000 S01` |
| holder `check` seed 1 | `CPU_CHECK seed=1 beats=131072 mismatches=0 sentinel_bad=0 PASS` |
| holder `corrupt` 1000, then `--expect-fail R T` | `F`, `M00000001 B000003E8` (1 mismatch, first bad beat 1000) |
| `W R T` | `D`, `P`, seed 2; CPU check seed 2 PASS |
| `W R T` x5 | `D`, `P` each time, seeds 3-7, `M00000000` |
| CPU check seed 7, then `R T` | PASS, `P` |

- Throughput from `T`: write 131113 cycles for 131072 beats (41 cycles
  overhead) = **799.7 MB/s**; read 131116-131145 cycles = **799.6-799.7 MB/s**
  (ceiling 800 MB/s at 64 bits x 100 MHz).
- UART command round trip ~10-16 ms, nearly all USB-serial (FT232R)
  latency; the 1 MiB transfer itself is ~1.3 ms.
- Holder then `FREED` the buffer. Afterwards ping, SSH and the ttyUSB1
  console (`xilinx@pynq:~$`) all answered. The XUPV5 was not touched.

## Open Items

- Sim never has more than one burst outstanding (the 03 slave model accepts
  one at a time); the 4-outstanding path is exercised only on hardware,
  where it passed.
- RX-drop note from 01 (1022 of 1024 echoed): likely a rate mismatch in the
  01 echo, not `uart_rx`. The FT232R makes 115200 as 3 MHz / 26 =
  115385 baud; the FPGA TX runs 125 MHz / 1085 = 115207 baud plus ~3 idle
  cycles per byte, about 0.18% slower, so the one-byte holding register in
  `uart_echo.v` overflows about once per ~550 bytes of continuous input.
  Not verified on hardware. 04 is not affected (no streaming).
