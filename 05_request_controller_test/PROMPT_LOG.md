# PROMPT_LOG — 05_request_controller_test

A condensed, AI-readable brief for regenerating this mini-project.

## Goal

Run the cs150 `RequestController` on the PYNQ-Z2 with minimal (zero)
changes. The PYNQ-Z2 has no MIG, so an adapter takes MIG's place and masters
AXI4 to DDR through PS7 `S_AXI_HP0`. A fake "dcache" client generates
traffic through the RequestController `data_*` port with the exact
`Cache.v` handshake. All other clients are null. A super-simple UART FSM
works like this: one character triggers a pattern write through the dcache
port, then a read-back and compare, then a one-character answer (`P`/`F`).
Arbitration between several clients is left for later tests, before video
output.

Origin, Erik:

- t227u: "Let's have 05 utilize a copy of the RequestController from cs150,
  with minimal mods and wrappers to adapt it to AXI-master control rather
  than MIG... also a fake device to generate read and write traffic
  through (the other available arbitrated devices can be null...). Have a
  super simple state machine take a char from UART then write a test
  pattern through the "dcache" hookup then read through "dcache" hookup
  and send a char on match/mismatch."
- t228u: "Try to have a virtually identical Requestcontroller and use an
  adapter to master the/an AXI bus rather than MIG or FIFOs."

## Context

- Repo: `/home/ejr/pynq150`, branch `jtag-axi-ddr-test` (HEAD `4272a43`
  when this folder was created).
- Builds on `../04_uart_ddr_block_test/`, which supplied the block design,
  pins, top wrapper, holder/host scripts and TB style. 04 is not modified.
- Shared, not copied: `../01_uart_echo/rtl/uart_{rx,tx}.v`,
  `../03_axi_ddr_test/sim/axi4_slave_mem.v`.
- RequestController source: `~/cs150-1245/hardware/src/base_mem/RequestController.v`
  (md5 `96ddedbc194d41b4cf2e8e6d23f1e56f`, 334 lines). It is identical in
  all cs150 copies (priv-shared, shared, ttt, xtra, and
  proj150-*/notes/RequestController_OLD.v).
  - The proj150 copies (md5 `419c73be…`, 366 lines; ddrfix `d04e78ee…`)
    are DDR3-adapted (31-bit cadr, caf backlog, pixf first, rdf_pop fix)
    and were deliberately **not** used.
  - The cs150/proj150 repos are read-only. Nothing in them was modified.
- On ML505, `Memory150.v` connected the RC master port through clock-crossing
  FWFT FIFOs (`mig_caf`, `mig_wdf`, `mig_rdf`) to MIG v3.61 DDR2
  (APPDATA_WIDTH 128, BURST_LEN 4).
- Clock: PS `FCLK_CLK0` at 100 MHz.
- Load with PYNQ `Overlay` only (sudo plus the three profile.d sources),
  never over JTAG.
- Never touch the XUPV5 (`xilinx_tcf/Xilinx/00000000000000`, `ttyUSB2`).
- Board `xilinx@192.168.2.99`. UART is the Pmod USBUART on JA,
  `/dev/ttyUSB3` on UBU24.
- HP0 is not cache-coherent: flush/invalidate in the holder.

## Files

| Path | Purpose |
|------|---------|
| `rtl/RequestController.v` | Verbatim cs150 copy (zero diff). |
| `rtl/rc_axi_adapter.v` | Sits in MIG's place. MIG user-interface semantics on the RC side, AXI4 master (64-bit, INCR4) on the other. Registers only, no FIFOs. |
| `rtl/dcache_tester.v` | Fake dcache. Cache.v WRITE1/WRITE2/FETCH/READ1/READ2 handshake over LINES lines, pattern generator, compare, mismatch count, first bad line. |
| `rtl/rc_ddr_test.v` | UART command FSM, `uart_rx`/`uart_tx`, dcache_tester → RequestController (others null) → rc_axi_adapter, cycle counters. |
| `rtl/rc_test_top.v` | BD module-reference wrapper (from 04's top). LINES 32768, WIN_AW 20, AXI attributes with 1 outstanding. |
| `sim/tb_rc_ddr_test.v` | Icarus TB: UART host model, AXI monitor, DDR layout check, fail injection, idle checks. |
| `constr/pynq_z2_rc_test.xdc` | Same pins as 04. |
| `build_rc_test.tcl` | Vivado 2019.1 BD build (PS7 HP0 64-bit, SmartConnect 2 SI, JTAG-to-AXI, proc_sys_reset). Writes `../build/rc_test/rc_test.{bit,hwh}`. |
| `Makefile` | `make sim` (sim16 + sim64), `make overlay`, `make clean`. No program target. |
| `holder_rc_test.py` | Board side: Overlay, 1 MiB + 8 KiB CMA buffer with 0xEE sentinel, BASE = PHYS + 0x100; `check`/`corrupt`/`stop` control files. |
| `host_rc_test.py` | UBU24 side: send `A`/`W`/`R`/`G`/`T` and check replies, print MB/s. |
| `README.md`, `PROMPT_LOG.md`, `.gitignore` | Documentation and ignore list. |

## Design Decisions

1. **The RequestController is a verbatim copy.** That meant choosing the
   original cs150 file over proj150's DDR3 variant ("virtually
   identical"). All adaptation lives outside it.
2. **The adapter has MIG semantics and no FIFOs** (t228u).
   - The first version had CAF/WDF/RDF sync FIFOs plus an AXI engine. It
     was replaced.
   - `caf_full`/`wdf_full` mean "not ready".
   - `rdf_wren` is a one-cycle pulse per 128-bit beat with `rdf_data`
     valid, like MIG `rd_data_valid`. `rdf_rden` is ignored.
   - With pulses, the original RC's `serviced_reads` counter (it counts
     `rdf_wren`, which proj150 later changed to pops) is exactly right.
3. **One command at a time.**
   - Write: latch the command and beat 0, wait for beat 1, then AW, 4 W
     beats, B.
   - Read: AR, then 4 R beats → 2 pulses.
   - Ready is deasserted while busy. This gives read-after-write ordering
     and safety with no read data buffering. The client is always waiting
     in READ1/READ2 when data arrives, which the TB checks.
   - Throughput is deliberately not a goal here; 04 covers that.
4. **Address mapping.**
   - `addr` is in 8-byte units with `addr[1:0]` forced to 0 → one aligned
     32-byte INCR4 burst.
   - Byte = `base + {addr[WIN_AW-4:2], 5'b0}` inside a 2^WIN_AW window, so
     the PL cannot escape the CMA buffer.
   - Write beat 0 → +0..15 and beat 1 → +16..31. `data[63:0]` is the low
     AXI beat. `WSTRB = ~mask`.
5. **dcache_tester copies Cache.v exactly.**
   - `cadr = {cmd, 6'b0, line, 2'b0}`
   - Write beats: line[255:128], then line[127:0], mask 0
   - The read line is `{first, second}`.
   - The DDR layout therefore keeps the original beat order (bytes 0..15 =
     words 4..7).
6. **Null clients.** inst/gcmd/pixf/fill/line/bpas have their valid and wren
   inputs tied to 0, so their paths are optimized away. `data_stall` = busy.
7. **Sticky error flags.** `axi_err` (non-OKAY response) and `bad_cmd`
   (unknown cmd, data without a cmd, cmd inside a write pair) make `W`
   return `E`. On a read they give `F`.

## Protocol

UART 115200 8N1.

- `A`+4 LE bytes → `K` (base, [4:0] forced 0)
- `W` → `D`/`E` (seed++, write 32768 lines)
- `R` → `P`/`F` (read and compare)
- `G` → `P`/`F` (W then R)
- `T` → 44 bytes `Wxxxxxxxx Rxxxxxxxx Mxxxxxxxx Bxxxxxxxx Sxx\n`
- `W`/`R`/`G` before `A` → `N`; anything else → `?`

Pattern: word k of line i is `v = {i[28:0], k[2:0]} ^ {4{seed}}`, and
`~v` for odd k.

## Test Plan

1. **Sim** (`make sim`, Icarus 12) with `axi4_slave_mem`, in two runs:
   - sim16: 512 lines, 16 KiB window.
   - sim64: 2048 lines, 64 KiB window.
   - Checks: N/? replies; A/W/R/T; DDR byte layout; AXI burst rules; read
     pulses taken by the dcache; corrupt → F with M=2 B=100; G; an
     unaligned second base; RC and adapter return to idle.
   - Result: both runs ALL TESTS PASSED. sim16: write 4820 cycles and
     read 5032 cycles for 512 lines (about 9.4 and 9.8 cycles per line;
     the slave model adds latency).
2. **Build** (`make overlay`, Vivado 2019.1, about 6 min):
   - All constraints met: WNS 0.888 ns, WHS 0.015 ns at 100 MHz.
   - Utilization (including PS7, SmartConnect and JTAG-to-AXI): 6755 LUT
     (12.7%), 9281 FF (8.7%), 2.5 BRAM, 0 DSP.
3. **Hardware** (PYNQ-Z2, Overlay, 2026-11-26): PASS. BASE 0x16900100.
   - `A W R T` → `K D P`, T `W00157FD8 R001830CB M0 B0 S01`.
     - Write: 1,408,984 cycles = 74.4 MB/s, 43 cycles per line.
     - Read: 1,585,355 cycles = 66.1 MB/s, 48 cycles per line.
     - One command at a time, so HP0 latency dominates.
   - CPU check, seed 1: 32768 lines, 0 bad, sentinels intact.
   - CPU corrupt of line 100 → `R` = `F`, T `M00000001 B00000064`.
   - `G` ×4 → `P`, then `R` → `P` (seed 5). CPU check of seed 5: PASS.
   - Afterwards the holder freed its buffer; ping, SSH and the ttyUSB1
     console were all fine.

## Open Items

- Arbitration between clients is untested: only `data_*` is live. That
  comes next, with several fake clients and priorities.
- Masked/partial writes (`mask != 0`) are not exercised, because Cache.v
  always writes full lines.
- Beat order: the first MIG beat of a line holds line[255:128], at the
  lower DDR address (a "big-wordian" line layout inherited from Cache.v).
  Future video and pixel clients must agree with it.
- `rdf_rden` is unused. The original RC is correct only with pulse-style
  read data (MIG semantics). A FIFO adapter would need proj150's `rdf_pop`
  change.
- One command at a time is slow compared with 04's pipelined engine.
  Pipelining would need read data buffering or outstanding-read tracking.
- `caf_cadr[30:WIN_AW-3]` (the high address bits) are ignored by design
  (window wrap).
