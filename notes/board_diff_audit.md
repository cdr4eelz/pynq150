# Board difference audit: XUPV5/ML505 vs Arty A7-100T vs PYNQ-Z2

**Purpose:** Inventory everything that still differs between the three boards before porting the cs150 MIPS CPU to the PYNQ-Z2 as test 10. Pins, LEDs/switches/buttons (except a soft reset), HDMI, and DDR-over-AXI are treated as already proven; this audit looks for everything else.

**Scope (read-only, 2026-11-26):**

- XUPV5 / ML505: `~/cs150-1245` → `~/shared/cs150`, ISE top `hardware/src/ml505top.v` + `ml505top.ucf`. Timing/utilization from the existing ISE run in `hardware/build/ml505top/` (not regenerated).
- Arty A7-100T: `~/proj150`, top `proj150.srcs/sources_1/imports/src/ArtyA7top.v`. Timing/utilization from `build/arty/reports/` (Vivado 2019.1, routed 2026-11-26).
- PYNQ-Z2: `~/pynq150` tests 01–09, with 09 (`09_cache_slr_test`) passing on hardware. Timing/utilization from `~/pynq150/build/cache_slr/timing.rpt` and `util.rpt`.

No files under `~/cs150-1245` or `~/proj150` were modified. This note is the only new file and is left untracked.

Claims are cited to source paths. Anything inferred is marked **(inferred)**.

---

## 1. Device, tools, boot and reset

| Item | XUPV5/ML505 | Arty (proj150) | PYNQ-Z2 | Status on PYNQ | Notes & sources |
|---|---|---|---|---|---|
| FPGA | Virtex-5 LX110T (`xc5vlx110t`), ISE 12.x / 14.x style flow | Artix-7 100T `-1` (`xc7a100tcsg324-1`) | Zynq-7020 `-1` (`xc7z020clg400-1`, 53200 LUT, 140 BRAM36 tiles, 220 DSP) | Proven (01–09 overlays) | Arty util header: `build/arty/reports/post_route_util.rpt`. 09 util: `build/cache_slr/util.rpt`. |
| Tools | ISE: xst/ngdbuild/map/par/bitgen + iMPACT (`hardware/Makefile`, `hardware/cfg/Makefile`) | Vivado **2019.1** non-project Makefile+Tcl (`proj150/README.md`, `scripts/*.tcl`) | Vivado (09: `build_cache_slr.tcl`) + PYNQ Linux `pynq.Overlay` | Proven | Different flow than both ISE and proj150's non-project Makefile; PS block must be in the design. |
| Board clock | 100 MHz `USER_CLK` (UCF LOC AH15, `TIMESPEC TS_100MHZ` 10 ns) | 100 MHz `CLK_100MHz` | Zynq `FCLK_CLK0` at 100 MHz, only after Linux loads the overlay | Proven | `ml505top.ucf` lines 38–39; `ArtyA7top.v` line 14; `build_cache_slr.tcl` `PCW_FPGA0_PERIPHERAL_FREQMHZ {100}` and `connect_bd_net` of `FCLK_CLK0` to `S_AXI_HP0_ACLK`. |
| Boot | Standalone: JTAG iMPACT of `.bit` (`cfg/impact.batch`). FPGA owns the board from power-on once programmed. | Standalone: Vivado `make program`. FPGA owns DDR and UART. | Linux must be up; overlay load instantiates the PL. Every design includes the Zynq PS (`fb_overlay_top.v`). There is no "power on and run" mode. | Needs port (boot/reset sequencing) | Holder script `09_cache_slr_test/holder_hdmi_09.py` loads the bit+hwh and reserves CMA. |
| Hard reset | `FPGA_CPU_RESET_B` (UCF E9, TIG) | `CK_RST_N` (ChipKit reset, active low) | PS `FCLK_RESET0_N` → `proc_sys_reset` `aresetn` | Proven | `ml505top.v` port list; `ArtyA7top.v` line 16; `fb_overlay_top.v` + `build_cache_slr.tcl` lines 95–98. |
| Soft reset button | Center compass PB `GPIO_COMPPB[4]` synchronized into the reset tree (`button_reset` in `ml505top.v` line 393) | Board reset also gates the MMCM (`reset_top_clocks`) | `BTN0` ORed into MMCM reset and the FCLK-domain reset (`fb_overlay_top.v` lines 127, 147) | Proven (keep for 10) | Erik called out a soft reset as the one button that still matters. |
| Reset sequencing | Staged tree on `USER_CLK`: bootstrap → `pll_lock` → `init_done` (MIG calib) → then `rst_cpu_mem` / `rst_cpu_bus` / `rst_cpu_cpu` / `rst_dvi_bus` (`ml505top.v` lines 210–266). CPU comes out last. | MMCM lock releases MIG `sys_rst` immediately; CPU/pix resets are synced separately. CPU is **not** gated on `init_done` (`ArtyA7top.v` lines 96–112, comments). | 09: FCLK domain reset = `BTN0 \| ~aresetn`; pix domain waits for MMCM lock. No "hold the MIPS until BASE is programmed" yet. | Needs port | **Surprise for 10:** the MIPS must stay in reset until the holder publishes `BASE` (and, if AXI stays at 100 MHz, until that clock is up). On 09 the host sends UART `A` after the holder starts; a CPU that boots at overlay-load would see `base_addr=0`. |
| PS block required | No | No | Yes. Loading a bit without the PS freezes Linux. HP0 must be clocked (`S_AXI_HP0_ACLK` = FCLK0 in 09). | Proven | `fb_overlay_top.v` header comments; `build_cache_slr.tcl`. |

---

## 2. Clocks

**XUPV5 CPU/GPU/RC clock is confirmed 50 MHz.** Not inferred. Evidence:

- `ml505top.v` parameter `CPU_FREQ = 50_000_000` (line 2).
- `PLL_BASE` from 100 MHz: `CLKFBOUT_MULT=24`, `DIVCLK_DIVIDE=4` (VCO 600 MHz), `CLKOUT0_DIVIDE=12` commented `// 50 MHz CPU` (lines 268–280). An unused alternate block also keeps CPU at 50 MHz while raising the MIG to 267 MHz.
- `MIPS150.v`, `MemBank.v`, `UARTRVA.v` / `UART.v` all default `CPU_FREQ` / `ClockFreq` to 50 MHz and pass it into the baud divider.
- ISE `ml505top.par`: `TS_cpu_clk` period requirement 20 ns, slack **+0.045 ns**, actual period 19.955 ns. `ml505top.twr` "Minimum period: 19.955 ns (Maximum frequency: 50.113 MHz)". Destination clock in the report is `cpu_clk_g rising at 20.000 ns`.

The same PLL also makes **40 MHz DVI** (`CLKOUT1_DIVIDE=15`), **200 MHz IDELAY ref** and **200 MHz MIG clk0/clk90**, and **100 MHz MIG clkdiv0**.

**Arty is also 50 MHz CPU / 40 MHz pixel**, from one MMCM (`clk_wiz_0.tcl`: CLKOUT1 50, CLKOUT2 40, CLKOUT3 200, CLKOUT4 100). `ArtyA7top.v` lines 6, 73–86. The MIG UI clock is **81.25 MHz** (325 MHz DDR3 / 4); see `post_route_timing.rpt` Clock Summary (`iserdes_clkdiv` 12.308 ns).

| Item | XUPV5/ML505 | Arty (proj150) | PYNQ-Z2 (09 as built) | Status on PYNQ | Notes & sources |
|---|---|---|---|---|---|
| CPU / GPU / RequestController | Shared **50 MHz** `cpu_clk_g` | Shared **50 MHz** `clk_cpu` | 09 has **no CPU**. RC, caches, SLR, drawer, adapter and HP0 AXI all run on **FCLK0 = 100 MHz** | Needs port | 09 clocks: `fb_overlay_top.v`, `timing.rpt` Clock Summary (`clk_fpga_0` 10 ns). |
| Pixel / video | 40 MHz `dvi_clk_g` (800x600@60) | 40 MHz `clk_pix` | 40 MHz `pix_clk` from MMCM (`CLKFBOUT_MULT_F=10`, `CLKOUT0_DIVIDE_F=25` on 100 MHz FCLK0) | Proven | `ml505top.v` DVI parameters lines 174–187; `fb_overlay_top.v` lines 125–144. |
| HDMI serial / TMDS | Not in the FPGA: Chrontel CH7301 takes 12-bit DDR pixel + `DVI_XCLK_*` (`SDR2DDR.v` uses `ODDR`) | FPGA-side TMDS (proj150 video path) | 200 MHz `ser_clk` (MMCM `/5`) into Digilent `rgb2dvi` | Proven | `fb_overlay_top.v` lines 132–133, 208–219. |
| Memory-controller clock | MIG native, `clk0` = 200 MHz (optional 267 MHz block commented out). User FIFOs cross `cpu_clk_g` ↔ `clk0_g`. | MIG native, `sys_clk_i` 100 MHz, `clk_ref_i` 200 MHz, DRAM 325 MHz, `ui_clk` ≈ 81.25 MHz | No PL MIG. PS DDR3, PL master is AXI HP0 64-bit on FCLK0 100 MHz | Proven (HP0 path) | `Memory150.v` lines 179–182, 221; `proj150/README.md` lines 140–142; `build_cache_slr.tcl`. |
| IDELAY reference | 200 MHz `clk200_g` into MIG / `IDELAYCTRL` (3× IDELAYCTRL in `ml505top.par`) | 200 MHz into MIG (1× IDELAYCTRL in Arty util) | Not needed for HP0 | Not needed | IDELAYCTRL is a MIG-PHY primitive, not a user-visible 10 concern. |
| Extra FCLK outputs | n/a | n/a | Only FCLK0 is enabled in 09 | Open question | Zynq can also provide FCLK1–3. A 50 MHz FCLK1 is an alternative to an extra MMCM output. Not configured today. |

---

## 3. Memory system (DDR, addresses, word order)

| Item | XUPV5/ML505 | Arty (proj150) | PYNQ-Z2 | Status on PYNQ | Notes & sources |
|---|---|---|---|---|---|
| DRAM ownership & size | FPGA owns **256 MB** DDR2-667 class, 64-bit, MIG v3.61 native. Geometry: `ROW_WIDTH=13`, `COL_WIDTH=10`, `BANK_WIDTH=2`, `DQ_WIDTH=64` → 2^(13+10+2)×8 = 256 MB, starting at CPU byte address 0 in the cache window. | FPGA owns **256 MB** DDR3, 16-bit, native UI 128-bit | Linux owns 512 MB. PL only gets a **holder-reserved CMA window** (16 MiB in 09). Physical `BASE` **varies** (09 board run used `BASE=0x16900000`). | Needs port (map / window) | `mig_v3_61.v` `CORE_GENERATION_INFO`; `holder_hdmi_09.py`; `09_cache_slr_test/README.md`. |
| Controller interface | Native MIG: `app_af_cmd/addr` (31-bit addr in **8-byte** units), 128-bit `app_wdf` / `rd_data`, command FIFO shared by reads and writes, **strict issue order** (no read/write reordering). | Native MIG, 16-bit units (byte >> 1). Same FIFO fabric, but `Cache.v` in proj150 was rewritten for those units and must **not** be used on PYNQ. | AXI4 on HP0, 64-bit, independent AR/AW. `rc_axi_fifo_adapter` restores same-line ordering (patch 0001, address-conflict check). | Proven | Adapter: `09_cache_slr_test/rtl/rc_axi_fifo_adapter.v`. Cache choice: `09_cache_slr_test/PLAN.md` §Cache.v. |
| Address packing (RC `caf_cadr`) | cs150 `Cache.v`: `f_addr = {6'b0, addr[27:5], 2'b0}` (`cache.vh` `IDX_ADDR_DRAM 27:5`). 8-byte units, 32-byte line aligned. | proj150 `Cache.v`: byte address >> 1, 31-bit `caf_cadr`, plus a forced 0 on the MIG rank bit (`MigUiAdapter.v` comments). | 09 uses **cs150** `Cache.v` (not the Arty port). Adapter: `base_addr + {addr[WIN_AW-4:2], 5'b0}` with `WIN_AW=24` (16 MiB). Addresses **wrap** in the window. | Proven for 09 clients; Needs port for the MIPS map | `hardware/src/base_mem/Cache.v` line 206; `fb_core.v` `WIN_AW=24`; adapter lines 61–64, 189–190. |
| `LITTLEWORDIAN` | `Memory150.v` default **1**: word 0 of a 32-byte block is the MS 32 bits of beat 1 (pixel 0). Not byte endianness. | Same default 1 in `MemoryDDR.v`. | Caches instantiated with **1**. SLR plan first said 0, but as-built 09 uses the order that matches the drawer/PixelFeeder (README: `LITTLEWORDIAN=1`; parent report: SLR needed 1). | Proven | `Memory150.v` line 18; `09_cache_slr_test/README.md` Memory section. MIPS `ByteAccess4` is still **big-endian bytes** (`innerds/ByteAccess4.v`: "Endianess option UNIMPLEMENTED (always BIG)"). |
| 16-byte word swap vs ARM | n/a (no ARM view of this DRAM) | n/a | HP0/ARM sees each 16-byte beat **word-reversed** vs the LITTLEWORDIAN/RC view. Holder `words_to_rgb()` does "reverse every group of 4 words" (`holder_hdmi_09.py` lines 41–46). | Proven (display dumps); Needs port (ARM program load) | If test 10 writes a MIPS binary into the CMA buffer from Linux, it must apply this swap (or load through the MIPS dcache / BIOS UART, which already stores in CPU order). |
| Frame layout | PixelFeeder: `head_addr = {4'h1, framebits, y[9:0], x[9:0], 2'b00}` (`PixelFeeder.v` line 187). Software: `STD_FRAME1=0x10400000`, `STD_FRAME2=0x10800000`, stride `1<<22` = 4 MiB (`software/common/graphics.h`). | Same macros / same PixelFeeder formula (proj150 copy). | 09: FRAME1 = BASE+4 MiB, FRAME2 = BASE+8 MiB, cache-test = BASE+12 MiB. Window wrap of a CPU address `0x1Fxxxxxx` → offset `0xFxxxxx`. | Proven for frames 1–2 | `FRAME_BITS` accepts either a frame number or a `0x1nxxxxxx` pointer (`PixelFeeder.v` line 209). |
| ZBT SRAM | Controller is **compiled and instantiated** (`cross/SRAM.v`, `` `define SRAM_ENABLE `` in `ml505top.v`), pads in the UCF, clock feedback `SRAM_CLK_FB`. User-side `sram_addr` / `sram_data_*` are **not driven** by the CPU or GPU; `GPIO_LED[7]` and `BUS_ERROR_1` only report `sram_locked`. | Not present | Not present | Not needed | Fall-13 leftover. Consumes some V5 I/O and logic; nothing in the MIPS map talks to it. |
| VGA capture port | Pins in the top and UCF (`VGA_RED/GREEN/BLUE`, `VGA_DATA_CLK`, `HSOUT/VSOUT`). `cross/VGA.v` exists but is **not instantiated** in `ml505top.v`. | Not present | Not present | Not needed | Unused inputs on the XUPV5 bitstream. |

**16 MiB window vs the 256 MB software map — the main surprise for test 10.**

The adapter keeps only the low `WIN_AW` bits of the RC byte address, so a 16 MiB window *aliases* the CPU's 256 MB data space:

| CPU address (from `graphics.h` / `bios.ld`) | Low 24 bits | Lands in 09 window | Collision risk |
|---|---|---|---|
| `0x10000000` stash / `STD_FRAME0X` / typical `file` target | `0x000000` | BASE+0 | Overlaps "frame 0" |
| `0x10400000` `STD_FRAME1` | `0x400000` | BASE+4 MiB | Matches 09 frame 1 — OK |
| `0x10800000` `STD_FRAME2` | `0x800000` | BASE+8 MiB | Matches 09 frame 2 — OK |
| `0x10C00000` `STD_FRAME3` | `0xC00000` | BASE+12 MiB | **This is 09's cache-test region** |
| `0x11000000` `STD_FRAME4` | `0x000000` (wrap) | BASE+0 | **Aliases frame 0 / stash / loaded programs** |
| `0x1F000000` BIOS `_sp` (`software/link/bios.ld`) | `0xF00000` | BASE+15 MiB | Fits, top 1 MiB, grows down toward +12 MiB |

gios defaults to `STD_FRAME1` (`gios.c`), so a gios-only bring-up can stay inside 16 MiB. `draw.c` and `bench.c` use frames 3–6 and will wrap or collide unless the window grows or the constants change. Linux is unlikely to give the PL a full 256 MB CMA **(inferred)**.

---

## 4. CPU memory map, BRAMs, MMIO

Decode is in `hardware/src/cpu/MemBank.v` (nibbles of `IMEM_ADDR`/`DMEM_ADDR`[31:28]). `PC_BOOT=32'h4000_0000`, `PC_ISR=32'hC000_0180` (`MIPS150.v`, `CPUMIPS.v`). `BRAM_XTRA=1` enables the 0x5/0x6 scratch BRAMs.

| Item | XUPV5/ML505 | Arty (proj150) | PYNQ-Z2 | Status on PYNQ | Notes & sources |
|---|---|---|---|---|---|
| `0x4xxxxxxx` BIOS BRAM, 16 KB, data-side read-only | `bios_mem` CoreGen, 4096×32, init `bios_mem.coe` (`core_ip/brams/bios_mem/bios_mem.xco`). BMM: `[0x40000000:0x40003FFF]` (`hardware/cfg/mem.bmm`). | Same IP via `ip/bios_mem.tcl`; `make patch-bios` / `updatemem` | Not in 09 | Needs port | Current images: `software/bios150v3/bios150v3.inst.bin` is 3744 bytes; `software/gios/gios.inst.bin` is 10096 bytes — both fit. gios is linked `LDSTYLE := bios` (`software/gios/Makefile`) and can run *from* BIOS BRAM (Arty `make patch-bios` does this). |
| `0x5xxxxxxx` / `0x6xxxxxxx` scratch dmem/imem, 16 KB each | `dmem_blk_ram`, `imem_blk_ram` (same 4096×32 TDP). BMM `[0x50000000:0x50003FFF]`, `[0x60000000:0x60003FFF]`. | Same; `make patch-dmem` / `patch-imem` | Not in 09 | Needs port | Used by some unit/scratch tests (`link/dmem.ld`, `as_scratchpair.ld`). Not required to boot BIOS+gios. |
| `0xCxxxxxxx` ISR BRAM, 16 KB | `isr_mem.xco` + `isr_mem.coe`. Vector `0xC0000180`. | Same; `make patch-isr` with `isr7.coe` | Not in 09 | Needs port | Needed once COP0 / `irq_pf_frame` / `irq_gp_done` are live. |
| `0x1xxxxxxx` dcache, `0x2/0x3xxxxxxx` icache | Same physical DDR; tag is `addr[27:13]` so bits[31:28] do not distinguish aliases (`cache.vh`). BIOS writes instructions through the dcache (often to `0x10000000` / `0x30000000`) then fetches via the icache. Caches are write-through, no coherence / no software invalidate in the RTL. | Same | 09 already instantiated both caches as RC clients and proved write-then-refetch with the adapter patch | Proven (caches); Needs port (CPU clients) | 09 README: write-miss does not allocate; I-cache stays stale after D-cache writes. BIOS runs from 0x4, so a first `jal 0x10000000` is safe if those lines were never fetched. Reloading the same line needs a bounce address or a flush policy — **open if gios/apps retouch I-stream**. |
| `0x8xxxxxxx` MMIO | `MemMapIO.v`: UART TX/RX ready+data at `0x80000000..0C`, cycle/inst counters `10..18`, `PF_FRAME` `50`, `GP_FRAME` `54`, `GP_CODE` `58`, GPU status `5C`, PRNG `80`, HALT `84`. | Same (`port-mmio-uart` in proj150 README) | 09 command parser is a *test FSM*, not this map | Needs port | GPU MMIO is how gios launches the GraphicsProcessor and switches PixelFeeder frames. |
| I/D caches | cs150 `Cache.v`, 8 KiB direct-mapped, 32-byte lines, tag-compare is combinational into the data RAM | proj150 port of the same geometry but different CAF units | 09 uses cs150 `Cache.v` + regenerated `cache_*_blk_ram.tcl` | Proven | Geometry: `cache.vh`. |

---

## 5. Peripherals (everything beyond pins / HDMI / DDR)

| Item | XUPV5/ML505 | Arty (proj150) | PYNQ-Z2 | Status on PYNQ | Notes & sources |
|---|---|---|---|---|---|
| UART hardware | Board RS-232, `FPGA_SERIAL_RX/TX` (UCF AG15/AG20) | Built-in USB-serial | Board USB-serial is the **Linux console**. 09 uses **Pmod USBUART on JA**, host `ttyUSB3` | Proven as a cable; Needs port as the MIPS UART | `ml505top.ucf` "SERIAL IO"; `constr/pynq_z2_hdmi_fb.xdc` Pmod A. |
| UART baud | 115200 8N1, `SymbolEdgeTime = ClockFreq / BaudRate` with `ClockFreq=CPU_FREQ=50e6` (`UATransmit.v` / `UAReceive.v`, `UARTRVA` inst in `MemBank.v` line 223) | Same, `CPU_FREQ=50e6` (`ArtyA7top.v`); host `gios_uart.py` opens 115200 | 09 test UART: `CLK_FREQ=100_000_000`, `BAUD=115200` (`fb_core.v` lines 62–63, 132–134) | Needs port | If the MIPS UART is moved to 50 MHz, the divider must use 50 MHz, not 09's 100 MHz. 50e6/115200 ≈ 434. |
| RX FIFO | CoreGen `uarx_fifo` in `UARTRVA.v` | `ip/uarx_fifo.tcl` | 09 has its own `uart_rx`/`uart_tx`, not `uarx_fifo` | Needs port (bring the cs150 UART stack) | |
| Chrontel DVI + I²C | `DVI.v` / `DVIInitial.v` program the CH7301 over `IIC_SCL_VIDEO` / `IIC_SDA_VIDEO` at start of day. 12-bit DDR `DVI_D` + `DVI_XCLK_*`. | No CH7301; FPGA TMDS | No CH7301. `rgb2dvi` generates TMDS. PYNQ HDMI I²C/CEC/HPD pins exist and are unused in 09 (XDC comment). | Not needed | Any leftover CH7301 I²C init code must not be instantiated. |
| Video IRQs | `irq_pf_frame`, `irq_gp_done` into the CPU (`ml505top.v` Memory150/MIPS150 hookup) | Same | 09 does not hook these to a CPU | Needs port | |
| PS/2 keyboard/mouse | Pins **commented out** in `ml505top.ucf` ("PS/2"); not in the top port list | Not used | Not used | Not needed | Unless a later app wants a Pmod keyboard. |
| AC97 / audio / piezo | Commented only, under `# AUDIO` in `ml505top.ucf` (lines 162–174). Not in the top. | Not used | Not used | Not needed | |
| Character LCD, SystemACE / CompactFlash, Ethernet PHY, main I²C | Present on the XUPV5 board (see `tool/resources/master_xupv5-lx110t.ucf`) but **not hooked** in `ml505top.v` / the live UCF | Not used | Not used | Not needed | `TunTap.v` / `tuntap.vh` is a **simulation** include, not an Ethernet MAC. |
| GPIO DIP / LEDs / rotary / compass PBs | Used: DIP stall (`COLT45_STALLDIP`), center PB = soft reset, LEDs show pll/init/stall/SRAM lock (`ml505top.v` 393–398) | `SWITCH[1]` optional CPU stall (`SW_STALL_EN`) | 09: LEDs for MMCM lock / UART activity / PixelFeeder running; `BTN0` reset | Not needed (except soft reset) | Matches Erik's "none are critical" except the reset button. |
| ChipScope | Cores exist under `core_ip/scopes/*.xco`. Instantiated only if `COLT45_SCOPE=1` (`CPUMIPS.v` lines 7, 272–291). Default is **0**. | `mark_debug` leftovers commented in `ArtyA7top.v` | 09 timing report shows a `dbg_hub` TCK (Vivado ILA hub default) — not a functional ChipScope | Not needed | Do not bring `cs_icon_*` / `cs_ila_*` into the Zynq build. |

---

## 6. Video / GPU clients

| Item | XUPV5/ML505 | Arty (proj150) | PYNQ-Z2 (09) | Status on PYNQ | Notes & sources |
|---|---|---|---|---|---|
| Timing | 800×600@60, 40 MHz, parameters in `ml505top.v` 174–187 | Same | Same; `vga_timing.v` + MMCM 40.000 MHz | Proven | |
| PixelFeeder | RC read client, CDC via `pixel_fifo` into DVI clock | Same | Same, into `pf_video_sink` + `rgb2dvi` | Proven | `Memory150.v` client list; `pixel_feeder_rc.v`. |
| ScanLineRunner (bypass port) | Present as "Bypass/SLR" write client in `Memory150.v` | Present; default `LITTLEWORDIAN=1` | 09 UART `L`/`Y` commands, as-built word order matches the feeder | Proven | |
| FrameFiller, LineEngine, EllipseEngine, GraphicsProcessor | Instantiated in `Memory150.v` (fill + line write ports, GP read port) and programmed via MMIO `GP_CODE` / `GP_FRAME` | Same (hwtest `elip_check.py`, `gios_uart.py`) | 09 has a **UART frame_drawer** on the fill port, **not** the cs150 GraphicsProcessor | Needs port | This is the remaining GPU work for 10 if gios graphics is in scope. 09's drawer should probably stay out of the way (or be muxed) once GP owns the fill port. |
| RequestController | Unmodified cs150 core, 50 MHz, 7 clients as above | Unmodified except the Arty CAF-unit clients | Unmodified cs150 core, 100 MHz, 5 clients (I$, D$, PF, drawer, SLR) | Proven | Do not swap in a different RC. |

---

## 7. Software toolchain and loader

| Item | XUPV5/ML505 | Arty (proj150) | PYNQ-Z2 | Status on PYNQ | Notes & sources |
|---|---|---|---|---|---|
| Toolchain | `mips-linux-gnu-*` or `mips64-linux-gnu-*` (`software/makefile.mips`) | Same tree / `sw/` images imported (`make sw-import`) | Same compiler can be used on UBU24; nothing in 09 builds MIPS code into the bit | Needs port (images + a load path) | |
| BRAM init at bitstream time | CoreGen `.coe` baked in; `data2mem` + `mem.bmm` preprocessed in `hardware/Makefile`; ngdbuild `-bm` (`cfg/Makefile`). | `updatemem` via `make patch` / `patch-bios` etc. (`proj150/README.md`, `scripts/mmi.tcl`, `scripts/coe.tcl`) | No BMM/MMI flow in 09 | Needs port | Recommend a Vivado `updatemem`/MMI path like proj150, so BIOS/gios can be swapped without a full synth. |
| Runtime load into DDR | BIOS `bios150v3`: banner `[COLT45.2]`, commands `file <hexaddr> <declen>` (then `len/4` ASCII 8-hex-digit words), `jal <addr>`, `lw/sw/lhu/sh/lbu/sb`, `dump`, `cp` (`software/bios150v3/bios150v3.c`). Host talks 115200 over the board UART. | Same protocol: `hwtest/gios_uart.py --file ADDR HEXFILE`, `run_stages.sh` examples (`file 10100000`, `jal 10030000`, `jal 60000000`). | 09 UART is a different character protocol (`R/W/J/L/...`). No BIOS. | Needs port | Best first loader for 10: put `bios150v3` in `bios_mem`, connect the Pmod UART to `UARTRVA`, reuse `gios_uart.py`. The ARM CMA path is a later shortcut and must apply the 16-byte word swap. |
| gios | Linked as BIOS (`LDSTYLE := bios`, origin `0x40000000`) **or** loaded into DDR with `file`/`jal`. Stack is still `_sp = 0x1F000000`. | `gios.inst.coe` is the default `patch-bios` image (`README.md` table). | Not present | Needs port | 10096-byte image fits in the 16 KB BIOS ROM, so a "gios in BRAM, UART already live" bring-up is possible without a DDR load. Frames 1–2 still need the window/BASE to be correct. |

---

## 8. IP, primitives, leftover CoreGen

| Item | XUPV5/ML505 | Arty (proj150) | PYNQ-Z2 (09) | Status on PYNQ | Notes & sources |
|---|---|---|---|---|---|
| MIG + IDELAYCTRL + ODDR (memory PHY) | `hardware/src/base_mem/mig_v3_61/`, PLL_BASE, IBUFG/BUFG×7, 3 IDELAYCTRL, many IODELAY (`ml505top.par`) | `boards/arty/ip/mig_arty_a7_100.{tcl,prj}`, `clk_wiz_0`, 1 IDELAYCTRL, 2 MMCM + 1 PLL (MIG) | None in the PL. PS DDR PHY is in the PS. | Not needed | |
| Clock primitives (user) | `PLL_BASE` + 7× `BUFG` in `ml505top.v` | `clk_wiz_0` (MMCM) | `MMCME2_ADV` + 3× `BUFG` for pix/ser/fb (`fb_overlay_top.v`) | Proven; may add one 50 MHz input | 09 MMCM still has free CLKOUT2+ — a `/20` = 50 MHz output from the existing 1000 MHz VCO is the smallest add. |
| RC FIFOs | `mig_caf`, `mig_wdf`, `mig_rdf` (async-capable; wr on `cpu_clk_g`, rd on `clk0_g`) | Same Tcl in `ip/` | Same Tcl; **both clocks tied to FCLK0** in the 09 adapter inst | Proven; Needs port if clocks split | `Memory150.v` line 221 already documents the 50↔200 crossing. 09 adapter currently uses `.wr_clk(clk), .rd_clk(clk)` (`rc_axi_fifo_adapter.v`). |
| Cache / pixel / UART BRAMs | CoreGen `.xco` under `core_ip/` | Regenerated `ip/*.tcl` | `ip/cache_*_blk_ram.tcl`, `pixel_fifo.tcl`, `mig_{caf,wdf,rdf}.tcl` | Proven for those; Needs port for bios/dmem/imem/isr/uarx | Copy the proj150 Tcl, not the V5 `.xco`. |
| `mul_u` / `mul_s` / `div_u` / `div_s` / `sqt_t` / `reg_32` | `.xco` exists under `core_ip/ops/`. **Not referenced** in `ml505top.prj` and not instantiated in `cpu/` or `innerds/`. | Not used | Not used | Not needed | Software multiply/divide lives in C (`common/mutmath.c`, `divmath.c`). |
| `IMG_MEM`, `SRAM_*_FIFO` | Under `core_ip/cross/`; SRAM path only | Not used | Not used | Not needed | |
| ChipScope ICON/ILA/VIO | `.xco` present; gated off | n/a | n/a | Not needed | |
| rgb2dvi | n/a | Used on Arty video | `rtl/vendor/rgb2dvi` | Proven | |
| Zynq PS / SmartConnect / JTAG-AXI | n/a | n/a | In the 09 BD (`build_cache_slr.tcl`) | Proven | Must stay. JTAG-AXI can remain as a debug master. |

Xilinx primitives actually in the live XUPV5 top + video path: `PLL_BASE`, `IBUFG`, `BUFG`, MIG-internal `IDELAYCTRL`/`IODELAY`/`IDDR`/`ODDR`, and `ODDR` in `base_vid/SDR2DDR.v` for the CH7301 clock/data. No standalone user `DCM`. BRAMs and DSP48Es are inferred or CoreGen-wrapped (12 DSP48E on V5, see §10).

---

## 9. Clock domains and CDC

| Crossing | XUPV5/ML505 | Arty | PYNQ-Z2 (09) | Status on PYNQ | Notes & sources |
|---|---|---|---|---|---|
| CPU/RC ↔ DRAM user clock | Async `mig_*` FIFOs, 50 MHz ↔ 200 MHz `clk0` | Async FIFOs, 50 MHz ↔ ~81 MHz `ui_clk` | None today (single 100 MHz). Erik's plan reintroduces 50 ↔ 100 (or runs both at 50). | Needs port if split | FIFOs are already independent-clock IP. |
| CPU/RC ↔ pixel | `pixel_fifo` + reset synchronizers `reset_*_clkCPU` / `reset_*_clkDVI`. UCF `TS_TO_ASYNC_CPU/DVI` 10 ns DATAPATHONLY (`ml505top.ucf` lines 14–17). | Same idea, 50 ↔ 40 | `set_false_path` / max-delay style constraints between FCLK0 and `pix_clk` (`pynq_z2_hdmi_fb.xdc` comments at lines 43–48) | Proven | Keep this CDC; do not time 50 MHz and 40 MHz as synchronous even though they share a parent MMCM/FCLK. |
| UART pins | TIG on RX/TX | IOB registers (proj150 README notes a leftover IOB stage) | `set_false_path -from uart_rxd` | Proven | Sample in the UART clock domain (50 MHz once the MIPS UART moves). |
| Reset into other domains | Explicit 8-bit shifter per domain (`ml505top.v` 249–266) | `sync_signal` helpers in `ArtyA7top.v` | 2-FF async assert / sync deassert in `fb_overlay_top.v` | Needs port (add a CPU-reset stage after BASE) | |

---

## 10. Timing and resources — is 50 MHz "too far"?

### Measured reports

| Build | Clock of interest | WNS | Critical path | LUTs | BRAM tiles | DSPs | Source |
|---|---|---|---|---|---|---|---|
| cs150 `ml505top` (V5 LX110T) | `cpu_clk` 50 MHz (20 ns) | **+0.045 ns** (actual 19.955 ns) | Design min period is this CPU clock. DVI 40 MHz had +3.535 ns in `ml505top.par`. | 9178 / 69120 (13%) | 36 RAMB36 + 8 RAMB36SDP + a few RAMB18/FIFOs (~25% of 148) | 12 / 64 | `hardware/build/ml505top/{ml505top.par,ml505top.twr,ml505top_map.mrp}` |
| proj150 Arty (7a100t `-1`) | `clk_cpu_50MHz` 50 MHz | **+0.629 ns** (this *is* the design WNS) | `dcache` data RAM → `uartrva/rx_fifo` RDEN, **18.746 ns** data path, 20 logic levels (`post_route_timing.rpt` Slack 0.629 ns) | 9940 / 63400 (15.7%) | 39.5 / 135 (29.3%) | 13 / 240 | `build/arty/reports/post_route_{timing,util}.rpt` |
| pynq150 09 (7z020 `-1`) | `clk_fpga_0` 100 MHz | **+0.103 ns** | dcache **tag BRAM → tag compare → data BRAM DI**, 8.879 ns data path, 8 logic levels (`timing.rpt` lines 206–215) | 10589 / 53200 (19.9%) | 18 / 140 (12.9%) | 11 / 220 | `build/cache_slr/{timing,util}.rpt` |
| 09 pixel | `pix_unbuf` 40 MHz | +13.783 ns | not limiting | (included above) | | | same |

### Expectation at 50 MHz on the PYNQ (test 10)

- **The 09 dcache tag path is not the problem at 50 MHz.** 8.879 ns in a 20 ns period leaves on the order of **+10 ns** of slack on that path (minus a small change in uncertainty). That matches the earlier verbal estimate.
- **The MIPS + MemBank + UART path will take over.** On a 7-series `-1` (Arty) that path is already 18.746 ns with only **+0.629 ns** slack at 50 MHz. The Zynq-7020 is the same speed grade. **(inferred)** expect WNS in the few-tenths-of-a-nanosecond to ~1 ns range, not 10 ns, once the CPU is in.
- That is still **expected to close**, and is *looser* than the V5 build (+0.045 ns) that already ran at 50 MHz. It is not "pushing timing too far," but it is not fat either. A 75–100 MHz CPU clock would be the aggressive option; 50 MHz is the conservative one that both existing full-CPU builds use.
- If 10 fails timing, the first knob is a pipeline register on a long MemBank/UART path (Arty's 20-level path), not a clock drop below 50 MHz.
- **HP0 at 100 MHz vs 50 MHz:** 800×600×32bpp@60 is ~115 MB/s. Even half of 09's mixed-traffic sim rate is plenty. Running AXI at 50 MHz (same clock as RC, no async FIFO split) is the simpler CDC and is bandwidth-safe **(inferred)**. Keeping AXI at 100 MHz is a performance nicety, not a requirement.

### Resource fit (inferred from the two 7-series reports)

09 already has the PS, SmartConnect, rgb2dvi, caches, RC, SLR, PixelFeeder and FIFOs (10.6k LUT, 18 BRAM, 11 DSP). Adding MIPS + MemBank + four 16 KB BRAMs (bios/dmem/imem/isr ≈ 16 RAMB36, or 16 RAMB18 for bios as in the proj150 README) + the rest of the GPU (FrameFiller / LineEngine / Ellipse / GraphicsProcessor) should land near the Arty full-chip totals (~10k LUT *plus* the Zynq interconnect already in 09, ~35–40 BRAM tiles). Against 53200 LUT / 140 BRAM / 220 DSP that is roughly **25–40% LUT, ~25–30% BRAM, <10% DSP** — comfortable. The LX110T is larger, but the design never used most of it (13% LUT on V5).

---

## Plan for 10

Ordered steps, assuming 09 stays the parent tree and the RequestController / adapter / PixelFeeder / SLR are left alone.

1. **Clocking.** Keep FCLK0 at 100 MHz (HP0, SmartConnect, existing BD). From the existing 09 MMCM (VCO 1000 MHz) add `CLKOUT2 / 20 = 50 MHz`, or enable Zynq FCLK1 at 50 MHz. Run **CPU, GPU (GraphicsProcessor and engines), RequestController, MemBank, and the MIPS UART** on that 50 MHz clock. Pixel stays 40 MHz, serial 200 MHz. Decide AXI clock (recommendation: **start with the adapter and HP0 still on 100 MHz**, and make `mig_caf`/`mig_wdf`/`mig_rdf` use independent clocks the way `Memory150.v` already does; fall back to 50 MHz AXI if CDC or timing is ugly).
2. **Reset / BASE.** Hold `rst_cpu` asserted until (a) MMCM lock, (b) the holder has written `BASE` into `base_addr` (keep UART `A`, and/or add an ARM-visible AXI register), and (c) a host or BTN0 release. Reuse BTN0 as the soft CPU reset. Do not let the MIPS fetch with `base_addr=0`.
3. **MemBank + BRAMs + MMIO.** Instantiate `MIPS150` / `MemBank` / `MemMapIO` / `UARTRVA` from cs150 (or the proj150 copies if they are byte-identical for these files). Add `bios_mem`, `dmem_blk_ram`, `imem_blk_ram`, `isr_mem`, `uarx_fifo` as 7-series IP (proj150 Tcl). Connect dcache/icache already in 09 as the CPU cache ports. Hook `irq_pf_frame` / `irq_gp_done`.
4. **UART.** Move the Pmod from the 09 command FSM to the MIPS `UARTRVA`, with `ClockFreq=50_000_000`, 115200 8N1. Keep a bring-up mux or a one-build fallback to 09 commands if useful, but BIOS is the target interface. Reuse `proj150/hwtest/gios_uart.py`.
5. **BIOS image.** Bake `bios150v3.inst.coe` into `bios_mem`. Add an `updatemem`/MMI path (copy proj150's) so gios can be patched into BIOS BRAM without a resynth.
6. **Board bring-up, no GPU yet.** Overlay load → holder reserves 16 MiB, programs `BASE`, releases CPU → `[COLT45.2]` on `ttyUSB3` → `lw`/`sw` in the window → `file 10000000 …` / `jal` a tiny echo or `dumpmem` program. Confirm baud, BASE aliasing (`0x10400000` vs BASE+4 MiB), and I-cache fetch after a D-cache store (adapter patch).
7. **gios.** Either `patch-bios` gios into BRAM and let it run from `0x40000000`, or `file`/`jal` into `0x10000000`. Stick to `STD_FRAME1/2` on the 16 MiB window. Do not run `draw`/`bench` frame 3–6 until the window or the constants change.
8. **GraphicsProcessor.** Move 09's UART drawer off the fill port (or retire it), instantiate the cs150/proj150 GPU (FrameFiller, LineEngine, Ellipse, GP) as RC clients on the 50 MHz clock, and drive them from gios MMIO. Reuse Arty `elip_check.py` / gios graphics commands.
9. **Optional later:** ARM-side program load into CMA (with the 16-byte word swap); larger CMA window; AXI-mode MIG on the Arty using this same adapter (left as a follow-on, as discussed).

---

## Open questions for Erik

1. **16 MiB vs frames 3+ / BIOS stack.** Is a gios-only map (frames 1–2, stack at `0x1F000000` → BASE+15 MiB) enough for 10, or should we try to grow the CMA window (24 or 32 MiB would give `STD_FRAME3` a unique slot and more stack clearance)? Changing `WIN_AW` and `graphics.h` is the other knob.
2. **AXI clock: 100 MHz with async FIFOs, or 50 MHz shared with the CPU?** Recommendation is 100 MHz first, fall back to 50. Either is fine for 800×600.
3. **50 MHz source: extra MMCM output, or Zynq FCLK1?** MMCM CLKOUT2 is the smaller BD change; FCLK1 is cleaner if we want Linux to set the frequency later.
4. **Loader of record for 10.1:** BIOS UART (`file`/`jal`) only, or also an ARM memcpy into CMA (must swap words)?
5. **09 UART command FSM:** retire it once the MIPS is on the Pmod, or keep a mux for cache/SLR character tests?
6. **Full GPU in 10, or a 10a (CPU+BIOS+UART) then 11 (GP)?** The GraphicsProcessor is the only major RC client not yet proven on the PYNQ.
7. **I-cache stale lines** after rewriting a previously fetched address: do you want a software flush convention, or just "don't do that" as on the XUPV5?
8. **Scratch BRAMs (0x5/0x6) and ISR BRAM:** instantiate all four in 10 for map compatibility, or BIOS-only until an ISR demo?
9. **Timing risk acceptance:** proceed at 50 MHz with the Arty +0.629 ns path as the expected limiter, and only add a pipeline register if the first 10 build misses.

---

## Source index

- XUPV5 top, clocks, reset, pins: `~/cs150-1245/hardware/src/ml505top.v`, `ml505top.ucf`
- Memory, RC, caches: `~/cs150-1245/hardware/src/Memory150.v`, `base_mem/{Cache.v,cache.vh,RequestController.v,mig_v3_61/mig_v3_61.v}`
- CPU map / UART / MMIO: `~/cs150-1245/hardware/src/{MIPS150.v,cpu/MemBank.v,cpu/MemMapIO.v,cpu/CPUMIPS.v,base_io/UART*.v,base_io/UARTRVA.v}`
- Video: `~/cs150-1245/hardware/src/{base_vid/DVI.v,base_vid/DVIInitial.v,gpu/PixelFeeder.v}`
- Software: `~/cs150-1245/software/{bios150v3/bios150v3.c,gios/Makefile,gios/gios.c,link/bios.ld,common/graphics.h,makefile.mips}`
- ISE reports: `~/cs150-1245/hardware/build/ml505top/{ml505top.twr,ml505top.par,ml505top_map.mrp}`
- Arty top / clocks / memory: `~/proj150/proj150.srcs/sources_1/imports/src/{ArtyA7top.v,MemoryDDR.v,base_mem/Cache.v}`, `~/proj150/boards/arty/ip/clk_wiz_0.tcl`, `~/proj150/README.md`, `~/proj150/hwtest/gios_uart.py`
- Arty reports: `~/proj150/build/arty/reports/post_route_{timing,util}.rpt`
- PYNQ 09: `~/pynq150/09_cache_slr_test/{rtl/fb_overlay_top.v,rtl/fb_core.v,rtl/rc_axi_fifo_adapter.v,constr/pynq_z2_hdmi_fb.xdc,holder_hdmi_09.py,README.md,PLAN.md,build_cache_slr.tcl}`
- PYNQ 09 reports: `~/pynq150/build/cache_slr/{timing.rpt,util.rpt}`
