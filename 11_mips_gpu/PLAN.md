# 11_mips_gpu — plan

The cs150 MIPS150 CPU (with MemBank, BRAMs, MMIO and UART) and the cs150 GPU (GraphicsProcessor,
ScanLineRunner, FrameFiller, LineEngine, ElipseEngine, RectangleEngine) on the PYNQ-Z2. It reuses
10's memory path: the cs150 RequestController and I/D caches on FCLK1 = 50 MHz,
`rc_axi_fifo_adapter` to HP0 on FCLK0 = 100 MHz, the proj150 PixelFeeder and rgb2dvi HDMI at 40 MHz.
Like 10, it runs **without Linux**: the boot jumper is on **JTAG**, not the SD card, and the board is
loaded by `jtag_boot.tcl` (ps7_init, fpga, ps7_post_config).

Sources are copied, never edited in place: `~/cs150-1245` and `~/proj150` are read-only.

## What changes from 10

| 10 | 11 |
|---|---|
| UART test FSM (`fb_core`) drives the RC clients | **MIPS150** drives everything: gios over the Pmod UART (`UARTRVA`, 50 MHz, 434 clk/bit) |
| `frame_drawer` on fill_*, `slr_rc` on bpas_* | **GPU** (cs150 `GPU.v`): GraphicsProcessor on gcmd_*, ScanLineRunner on bpas_* (fill_*/line_* unused, as in Memory150.v) |
| `cache_ex` test harness on the caches | caches are the CPU's I$/D$ (as in Memory150.v) |
| PixelFeeder frame chosen by UART `S` | PixelFeeder frame from CPU MMIO (`PF_FRAME`, pf_vframe/pf_wframe); `irq_pf_frame`, `irq_gp_done` to the CPU |
| 16 MiB window, base set by UART `A` (default 0x10000000) | **256 MiB window, fixed base 0x10000000** (`WIN_AW=28`): CPU DRAM address 0x1xxxxxxx = physical 0x1xxxxxxx, no aliasing |
| no BRAMs | BIOS ROM (gios), ISR RAM (isr7), X5 (bench), X6 (proj7): proj150 `ip/*.tcl` |

## Memory map (unchanged cs150 map, `MemBank.v`)

| CPU address | Device | 11 |
|---|---|---|
| 0x1xxxxxxx | D$ (DDR) | phys 0x10000000 + addr[27:0], i.e. identity |
| 0x2xxxxxxx / 0x3xxxxxxx | I$ (0x3 writes go to D$ and I$) | same DDR |
| 0x4xxxxxxx | BIOS ROM 16 KB, PC_BOOT 0x40000000 | gios.inst.coe |
| 0x5xxxxxxx / 0x6xxxxxxx | X5 / X6 scratch BRAMs (BRAM_XTRA=1) | bench / proj7 |
| 0x8xxxxxxx | MMIO (UART, counters, PF/GP frame/code/status, PRNG, HALT) | MemMapIO.v |
| 0xCxxxxxxx | ISR RAM, vector 0xC0000180 | isr7.coe |

The window fix: in JTAG boot mode nothing else uses DDR, so the PL can have the upper 256 MiB
(0x10000000–0x1FFFFFFF). The BIOS stack at 0x1F000000 and STD_FRAME1..6 (0x10400000 + n*4 MiB) all
land on unique physical addresses, which settles the audit's "window wrap / BIOS stack" issue.
The ARM is halted and its own DDR use (ps7_init only) is below 0x10000000.

## cs150 vs proj150 core settings, and what 11 follows

| Setting | cs150 (ML505/XUPV5, `ml505top.v`, `Memory150.v`) | proj150 (Arty, `ArtyA7top.v`, `MemoryDDR.v`) | 11 |
|---|---|---|---|
| CPU / GPU / RC clock | 50 MHz (`CPU_FREQ`, PLL CLKOUT0 /12) | 50 MHz (clk_wiz CLKOUT1) | **50 MHz** (FCLK1), same as both |
| Pixel clock | 40 MHz, Chrontel DVI | 40 MHz, VGA | 40 MHz, rgb2dvi HDMI (from 08) |
| Memory clock | MIG 200 MHz, async FIFOs | MIG ui_clk 81.25 MHz, async FIFOs | HP0 AXI 100 MHz, async FIFOs (from 10) |
| MIPS150 params | CPU_FREQ 50e6, PC_BOOT 0x40000000, CPU_CORE "MIPS" | identical | identical; the sim uses CPU_FREQ = 16*115200 so a UART bit is 16 clocks |
| MemBank | BRAM_XTRA=1, `UARTRVA` ClockFreq=CPU_FREQ | identical file | identical (cs150 file) |
| BRAM images | bios_mem = gios, isr = isr7, X5 = bench, X6 = proj7 (core_ip .coe) | identical images (sw/MANIFEST, imported from cs150) | identical (copied from proj150 `sw/`) |
| BRAM IP | CoreGen .xco | Vivado `ip/*.tcl` | proj150 `ip/*.tcl` (7-series) |
| UART RX FIFO | CoreGen `uarx_fifo` | `ip/uarx_fifo.tcl` (16 Ki x 8 builtin) | proj150 tcl |
| Reset bring-up | staged: PLL lock -> MIG init_done -> rst_cpu_mem, then rst_cpu_bus, then rst_cpu_cpu last; centre button resets | one `rst_cpu` for everything after MMCM lock + MIG init_done; CK_RST_N | **staged like cs150**: FCLK resets + adapter `ready` -> rst_bus (RC, caches, GPU, PF) -> ~256 cycles later rst_cpu (MIPS150). BTN0 = soft reset of the whole 50 MHz domain |
| Stall switch | DIP0 toggles a stall (COLT45_STALLDIP) | SW1 stall (SW_STALL_EN) | none (tied 0); stall = I$ / D$ stalls only |
| RequestController | cs150 (8-byte units, no caf_backlog) | modified: 16-bit units + `caf_backlog` (prog_full) priority for pixf, count beats on pop | **cs150** (proven in 09/10, matches cs150 Cache.v units). proj150's two behaviour fixes are a possible backport if gios `swfill` underflows the display |
| Cache.v | cs150 (8-byte units) | proj150 port (16-bit units) | **cs150** (09/10) |
| PixelFeeder | cs150 | proj150 (DDR-fix, underrun handling) | **proj150** via 10's `pixel_feeder_rc` wrapper (units + resync), now driven by CPU MMIO |
| ElipseEngine | cs150 file | proj150 "working midpoint engine from the ISE branch" (#4) | **proj150** (hwelip finishes on the Arty) |
| Rest of GPU, CPU, MMIO, UART | — | byte-identical to cs150 | cs150 files |
| Video timing | VESA 800x600@60 (1056x628) | same | same (vga_timing from 08) |

## Clocks and resets

FCLK0 100 MHz: HP0, adapter AXI side, MMCM -> 40 MHz pixel / 200 MHz serial. FCLK1 50 MHz: everything
else. Reset order (50 MHz domain): `rst_in` = BTN0 | FCLK_RESET1_N low; `rst_bus` = rst_in | !adapter
ready; `rst_cpu` = rst_bus delayed 256 cycles. The base is a constant, so there is nothing to wait for
from software before the CPU runs.

## Loading software

- gios is in the BIOS ROM, so the board boots to the gios prompt `> ` on /dev/ttyUSB3 after jtag_boot.
- gios `file ADDR HEX` over the UART (proj150 `hwtest/gios_uart.py --file`), then `jal ADDR`.
- Optional fast path: xsct `mwr`/`dow` into physical 0x10000000+ over JTAG. ARM writes land
  word-swapped within each 16-byte beat (audit §3), so a loader must pre-swap; not needed for gios.
- BRAM images are fixed at build time; an `updatemem` / MMI path (proj150 `make patch`) can come later.

## Tests

Sim (Icarus):
1. `simsys`: full core (CPU + BRAMs + caches + RC + adapter + GPU + PixelFeeder) against the AXI
   slave model, UART at 16 clocks/bit: gios prints `[Golt45.3...]` and `> `; then a few commands
   (`help`, `lw`/`sw` through D$, `gs`).
2. 10's adapter sims simmix/simthru carried over (the adapter is byte-identical to 10). simhz is not
   carried over: it drives 10's UART command FSM, which 11 retires; it passed on 10 with this adapter.

Board (JTAG boot, no Linux), reusing proj150 `hwtest/run_stages.sh` stages via `gios_uart.py` on
/dev/ttyUSB3: banner, dcache, icache, pixfeed, pixfeed_stress, gpu, elip, elipbig, plus HDMI captures
of the GPU frames and `jal 60000000` (proj7 from X6).

## Open decisions (defaults used unless Erik says otherwise)

1. **256 MiB window at 0x10000000** (identity map) instead of 16 MiB. Default: yes.
2. **cs150 RequestController** rather than proj150's (which needs proj150's address units). Default:
   cs150; backport `caf_backlog` only if `pixfeed_stress` underflows.
3. **Retire 10's UART test FSM** (the Pmod belongs to the MIPS). Default: retired; 10 stays the test bench.
4. **Staged resets like cs150**, BTN0 as the soft reset. Default: yes.
5. **BRAM images as both trees ship them** (gios in BIOS ROM). Default: yes.
6. **Timing**: if the 50 MHz domain misses, add a pipeline stage on the worst MemBank/UART path rather
   than lowering the clock (audit §10). Expect WNS of a few tenths of a ns up to ~1 ns.

## Status (2026-11-26, uncommitted)

Implemented as planned, with the defaults above. Changes found necessary along the way:

- **PF_FRAME survives resync.** In 08-10 the shown frame lived outside PixelFeeder; in 11 it is the
  CPU's MMIO write *inside* PixelFeeder, and the auto-resync on underflow reset it to frame 0 (seen on
  the board: `gs` showed PF#00 after a GPU fill). `pixel_feeder_rc` now keeps the CPU's last
  PF_FRAME write and replays it for 64 clocks after the feeder leaves reset (PixelFeeder's own reset
  is `cpu_rst_g | wr_rst_busy`, which outlasts the external reset). The sim pixel_fifo model now
  holds wr/rd_rst_busy for 16 clocks after reset, like the real FIFO.
- **Resync counter in gs.** The unused low byte of pf_status counts resyncs (saturating), so gios `gs`
  shows it as bits [23:16] of the status word (e.g. `4105011f` = 5 resyncs).
- **Timing.** The default implementation strategy missed by 0.30 ns on FCLK1 (cs150's single-cycle
  D$-hit loop, 21 levels, ~70% routing). `Performance_ExplorePostRoutePhysOpt` closes it without RTL
  changes; build_mips_gpu.tcl uses it.

Results: see README.md.

Still open:
- Occasional PixelFeeder underflows under heavy GPU fill traffic (5 resyncs over the full stage run
  plus extra full-screen draws; recovered each time, frame kept). Decision 2's fallback applies:
  backport proj150's `caf_backlog` pixf priority into the RequestController.
- FCLK1 slack is thin (+0.067 ns). If later changes break it, pipeline the D$-hit loop.
- I$/D$ are not coherent with GPU writes (cs150 behaviour): a CPU `lw` of a pixel cached before a
  GPU draw returns the old value until the line is evicted. This made one `elip` stage run fail when
  run right after `gpu`; the same stage passes on its own.
