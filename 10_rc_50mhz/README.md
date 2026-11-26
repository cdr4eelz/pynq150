# 10_rc_50mhz

09's cache + ScanLineRunner test with the RequestController and all its clients on a
50 MHz clock (the cs150 CPU clock on the ML505/XUPV5), the DDR/AXI side kept at 100 MHz,
and **no Linux**: the PYNQ-Z2 boots in **JTAG boot mode (boot jumper on JTAG, not SD card)**
and is loaded over JTAG with `jtag_boot.tcl` (`ps7_init` -> `fpga` -> `ps7_post_config`).
No ARM program runs and the SD card is not used. Verified on the PYNQ-Z2 this way.

## Running it (default: JTAG boot, no Linux)

1. Set the PYNQ-Z2 boot-mode jumper to **JTAG** (not SD) and power-cycle. Linux does not boot.
2. Build once: `make overlay` -> `../build/rc_50mhz/rc_50mhz.bit` plus `ps7_init.tcl/.c/.h`.
3. Load over JTAG from UBU24 (hw_server on localhost:3121, cable **1234-tulA** only, never the XUPV5):

       /tools/Xilinx/SDK/2019.1/bin/xsct jtag_boot.tcl

   It runs `rst -system`, sources the Vivado-generated `ps7_init.tcl`, runs `ps7_init`,
   configures the PL with `fpga -file rc_50mhz.bit`, runs `ps7_post_config`, and prints
   FPGA0/1_CLK_CTRL, FPGA_RST_CTRL and LVL_SHFTR_EN. Expected:
   `0x00200500 0x00400500 0x00000000 0x0000000f` (100 MHz, 50 MHz, resets released, shifters on).
4. Test over the Pmod UART (/dev/ttyUSB3) with the fixed DDR base **0x10000000**
   (the scripts' default `--addr`; set in the design by UART `A`):

       python3 board_tests.py --label jtag_nolinux      # full suite + HDMI captures
       python3 host_10.py A T1 S1 C G                   # manual commands
       python3 slr_demo.py --capture NAME

DDR contents are random after power-up, so clear a frame (`C`) before showing it.
Nothing else owns DDR: the whole 512 MiB is ours, the 16 MiB window at 0x10000000 is arbitrary.

**What the ARM side truly needs.** Only the two Vivado-generated scripts:
`ps7_init` (MIO, PLLs, DDR controller + training, FCLK0 = 100 MHz, FCLK1 = 50 MHz) and
`ps7_post_config` (PS<->PL level shifters on, FCLK_RESETn released). No bare-metal app; CPU0
stays halted. A PL-only load (no `ps7_init`) cannot work: no DDR controller and no FCLKs.

**Ethernet PHY clock.** The PYNQ-Z2's only PL oscillator input, the 125 MHz `sysclk` on H16,
comes from the Ethernet PHY and may only run with an Ethernet link plugged in. This design does
not use it (clocks come from the PS FCLKs), so it runs with or without Ethernet.

**Back to Linux** (legacy flow): jumper to **SD**, power-cycle, then use `holder_hdmi_10.py`
on the board (copies in `/home/xilinx/rc_50mhz/`) and pass `--addr BASE` from the holder.

## Clocks

```
FCLK0 100 MHz  -> HP0, SmartConnect, adapter AXI side
               -> MMCM -> pixel 40.000 MHz, serial 200.000 MHz  (unchanged)
FCLK1  50 MHz  -> RequestController, cs150 I/D caches, frame_drawer,
                  ScanLineRunner, PixelFeeder memory side, UART FSM
mig_caf / mig_wdf  wr=FCLK1, rd=FCLK0
mig_rdf            wr=FCLK0, rd=FCLK1
```

FCLK0 stays at 100 MHz so the HDMI MMCM keeps an exact 40 MHz pixel clock and
HP0 keeps its present peak bandwidth. FCLK1 at 50 MHz is the RC / future-CPU
clock. The FIFOs were already independent-clock, so they do the crossing
(the same arrangement as cs150's CPU clock vs MIG `ui_clk`).

## UART

115200 8N1 still, now from a 50 MHz clock. The modules use integer division
`CLKS_PER_BIT = CLK_FREQ / BAUD` = 50,000,000 / 115,200 = **434**.

| | 09 (100 MHz) | 10 (50 MHz) |
|---|---|---|
| `CLKS_PER_BIT` | 868 | 434 |
| Actual baud | 115,207.37 | 115,207.37 |
| Error vs 115200 | +0.0064% (+7.37 baud) | +0.0064% (+7.37 baud) |

The host script's `FCLK` is 50e6, so the 'U' cycle count is reported in
milliseconds of 50 MHz time.

## Linux-overlay run and the FIFO-ready reset gate

The one Linux-overlay run of 10 (SD-card boot, PYNQ holder) failed every cache and hazard read:
reads returned data for an earlier request (e.g. a PixelFeeder colour). In JTAG boot mode the same
design passes everything, **with or without** the reset gate below (an ungated control build was run
on the board in JTAG mode and passed the full suite). So the failure is tied to the Linux load flow,
not to the clock split itself. Most likely cause (unconfirmed, Linux is no longer used): PYNQ sets the
FCLK rates from the .hwh only after downloading the bitstream, so the 50 MHz core briefly ran on
FCLK1's previous rate and was never reset afterwards. In the JTAG flow `ps7_init` sets FCLK0/1 before
the PL is configured and `ps7_post_config` releases FCLK_RESETn after it.

Kept as a defensive measure: `rc_axi_fifo_adapter` has a `ready` output (127 core clocks after
its independent-clock FIFO reset ends) and `fb_core` holds everything except the adapter in reset
until it is 1 (`rst = rst_in | ~a_ready`), so no RequestController command can reach a built-in FIFO
still in reset recovery (where writes are silently ignored). The sim models of mig_caf/wdf/rdf now
emulate 32 write-clock cycles of reset recovery and any dropped write (`RECOVERY_DROP`) fails the sims.

## Commands, memory, sources

Same as 09: 16 MiB window, frames at +4 and +8 MiB, cache region at +12 MiB,
08 binary commands plus the ASCII cache / SLR commands (`R J W D E O M Y L`).
See `rtl/fb_core.v` for the command list and `09_cache_slr_test/README.md` for
the longer hardware-run notes.

## Sim

`make sim` (Icarus; FIFO models with reset recovery on mig_caf/wdf/rdf):

| Target | Result |
|---|---|
| `simcore` (tb_10, 50 MHz core / 100 MHz AXI, every 08 + 09 command, screen + DDR checks) | TB_PASS; frames=474 bad_frames=0, 0 RECOVERY_DROP |
| `simhz` patched adapter, seeds 12345678 / CAFEF00D / 0BADBEEF | 48 tests each, stale=0, TB_PASS |
| `simhz` 08 barrier adapter | 48 tests, stale=0, TB_PASS |
| `simhz` hazard check removed (must catch the race) | stale=18 (E 8, O 10), TB_PASS (race detected) |
| `simmix` RC + adapter vs hostile slave, 4 seeds x 5 latency sets | 20/20 MIXED TEST PASSED |
| `simthru` disjoint lines (R40/B30) | 1.51 RC cyc/line, 1062 MB/s |
| `simthru` same lines | 4.53 RC cyc/line, 353 MB/s (12,244 RAW-hold cycles) |

`simthru` MB/s are 32-byte lines per 50 MHz RC cycle (09's figures were per 100 MHz cycle).
Ungated control (gate removed) also passes simcore with 32 or 100 cycles of recovery: in the
testbench nothing writes to the mig FIFOs that early.

## Hardware results (PYNQ-Z2, JTAG boot, no Linux, base 0x10000000, 2026-11-26)

Build (Vivado 2019.1): WNS +1.471 ns (clk_fpga_0, 100 MHz), +5.808 ns (clk_fpga_1, 50 MHz),
WHS +0.009 ns; 10,710 LUTs (20%), 18 BRAM tiles.

`board_tests.py` ALL_PASS, run twice:
- 08 sanity: all commands; full-frame draw 158.35 ms (gap set in 50 MHz core cycles).
- Caches: miss 34 cycles, hit 1, write 3; R/W, write miss, 8-word ranges, J fetches,
  `D f`/`D v` 2048 words pass; the deliberate `D v` mismatch reports address/got/expected.
- Hazards: ~1,150 E / E x / O runs per pass, 0 stale; re-read avg 52 / 36.6 / 51.7 cycles.
- SLR: 604 spans in 9.9 s, 0 bad replies; 22/22 pixel readbacks match.
- HDMI captures (`capture/`, not committed): gradient, checker, grid, bars, fill, SLR demo all at zero offset.

Board left in JTAG boot mode running 10 with the SLR demo on frame 1.
