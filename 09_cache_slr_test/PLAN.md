# 09_cache_slr_test — plan

Planning only (2026-11-26). Do not build, do not touch the PYNQ or the
XUPV5, do not commit, and do not modify `08_hdmi_cs150_mode` or
`~/cs150-1245`. `~/proj150` stays read-only. 09 starts from the finished 08
PixelFeeder framebuffer, applies the held address-conflict patch, and adds
the cs150 ICache, DCache and ScanLineRunner so every RequestController
read/write source used here is exercisable by UART.

08 is still being built and tested, and is not committed. Implementation
should copy 08 once it is stable (or after Erik says to commit it), into
this folder, then work only here.

---

## 1. What 09 is

A PS7 overlay, same path as 08:

```
UART (115200 8N1, Pmod A / /dev/ttyUSB3)
  -> command FSM
       -> ICache  -> RequestController inst_*   (R/W)
       -> DCache  -> RequestController data_*   (R/W)
       -> PixelFeeder (via pixel_feeder_rc)     (read-only, pixf_*)
       -> frame_drawer (08, moved off data_*)   (write-only, fill_*)
       -> ScanLineRunner (via slr_rc)           (write-only, bpas_*)
  -> unmodified cs150 RequestController
  -> rc_axi_fifo_adapter (08 copy + the held patch)
  -> AXI4 HP0 (64-bit, FCLK0 100 MHz, SmartConnect)
HDMI OUT: 800x600@60, 40.000 MHz, positive syncs, PixelFeeder or the 08
test-pattern fallback.
```

GraphicsProcessor / gcmd and LineEngine / line_* stay tied off. The four
live RC clients are ICache, DCache, PixelFeeder and SLR; frame_drawer
stays as the 08 full-frame paint path, moved to the unused fill_* port so
it does not steal the DCache port.

---

## 2. Modules found

### 2.1 ICache and DCache — one module, two instances

There is no separate ICache/DCache Verilog. Both are `Cache` from cs150,
the same way `MemoryDDR.v` does it in proj150.

| Item | Path | Notes |
|------|------|--------|
| **Use this** `Cache.v` | `~/cs150-1245/hardware/src/base_mem/Cache.v` (md5 `186ff7c1…`, 229 lines) | **cs150 original.** `caf_cadr[33:0] = {cmd[2:0], addr[30:0]}` with `addr = {6'b0, byte[27:5], 2'b0}` (byte >> 3, 32-byte lines). Plugs straight into 08's RequestController. |
| `cache.vh` | `~/cs150-1245/hardware/src/base_mem/cache.vh` (md5 `3ab6c703…`) | Included by `Cache.v`. Geometry only; proj150's copy differs in whitespace. |
| Do **not** use | `~/proj150/.../base_mem/Cache.v` (md5 `b88a709d…`) | Ported for the Arty MIG: 31-bit `caf_cadr`, addresses in 16-bit units (byte >> 1), plus stuck-cycle / `DBG_disable` extras. That address unit is wrong for the cs150 RC / 08 adapter. |

CPU-side ports: `clk, rst, addr[31:0], din[31:0], we[3:0], re, stall, dout[31:0], tag_hit, tag_valid, state[2:0]`.

DDR-side ports (match 08 RC inst_* / data_*): `caf_full, wdf_full, rdf_wren, rdf_data[127:0], rdf_rden, caf_cadr[33:0], caf_wren, wdf_mdat[143:0], wdf_wren`.

Geometry (from `cache.vh`): direct-mapped, 256 lines × 32 bytes = 8 KiB, index = `addr[12:5]`, word offset = `addr[4:2]`, tag = `addr[27:13]`. A conflicting line is **8 KiB** away (`addr ^ (1 << 13)`).

**Write-through, not write-back.** This matters for the tests Erik asked for. Every store goes `IDLE → WRITE1 → WRITE2` and issues a masked 32-byte DDR write. `tag_line_in` always sets dirty = 0; there is no evict/writeback state. A write miss does **not** allocate the line (only a read miss fills). A write hit updates the line and still write-throughs. So "dirty evict then re-miss the same line" is not a real behaviour of this Cache; the equivalent hazard is in §6.

Instantiate both caches with **`LITTLEWORDIAN=1`**, so CPU word 0 of a 32-byte block is the MSB 32 bits, which is pixel 0 in 08's framebuffer layout.

### 2.2 ScanLineRunner

Byte-identical in cs150 and proj150 (md5 `e1adee1d…`):

- `~/cs150-1245/hardware/src/gpu/ScanLineRunner.v`
- `~/proj150/proj150.srcs/sources_1/imports/src/gpu/ScanLineRunner.v` (221 lines)

Copy from proj150 (or cs150; same bytes). It `` `include "../base_util/Const.v" ``, which is also identical in both trees (md5 `bf736552…`). Only `log2` is used, for the multi-client arbiter. With `SLR_COUNT=1`, `log2(0)` is 0 and `live_SLR` is 1 bit; that is fine.

Command interface (one client in 09):

| Port | Width | Role |
|------|-------|------|
| `SLRs_ready` | 1 | High in IDLE; pulse a command when ready |
| `SLRs_valid` | 1 | Hold until ready has been seen (accepted in IDLE) |
| `SLRs_frame` | 32 | Frame select via bits `[27:22]` (or low 6 bits; see `FRAME_BITS`). 09 should pass `{26'b0, frame}` like `pixel_feeder_rc`. |
| `SLRs_color_edge`, `SLRs_color_fill` | 32 | 0x00RRGGBB colours. **Fill is enabled only if `color_fill[31:24] != 0`** (`fill_active = |(color_fill & 32'hFF_000000)`). If the high byte is 0, SLR writes the two edges and jumps to the end (no interior). For a solid span set both colours equal and the fill high byte to `0xFF`. |
| `SLRs_row`, `SLRs_col_start`, `SLRs_col_finish` | 10 | Row and inclusive x range. Start/finish are swapped if needed. |

DDR interface (write-only): `caf_full, caf_wren, caf_addr[30:0], wdf_full, wdf_wren, wdf_data[127:0], wdf_mask[15:0]`.

**Address units already match 08.** SLR builds a cs150-style byte address `{4'h1, frame[5:0], y[9:0], x[9:3], 5'b0}` and then drops the 0x1 nibble:

```
caf_addr = {6'b0, cpu_addr[27:3]}   // byte >> 3, 32-byte chunks
```

That is the same window-relative map PixelFeeder and `frame_drawer` use: frame N at N × 4 MiB, line stride 4096. **Do not** apply the Arty conversion in `MemoryDDR.v` (`bpas_waf_addr = {1'b0, slr_addr[24:0], 2'b00}`), which turns byte>>3 into byte>>1 for the Arty MIG. On the PYNQ the wrapper passes `caf_addr` straight to `bpas_waf_addr`.

**`LITTLEWORDIAN=0` on PYNQ**, not the proj150 default of 1. 08's drawer writes beat 1 = `{pix0, pix1, pix2, pix3}` (MSB = lowest address / pixel 0) and beat 2 = `{pix4..pix7}`. SLR with `LITTLEWORDIAN=0` produces that order; `LITTLEWORDIAN=1` would put pix 4–7 in the first beat. Confirm in sim against the 08 memory-layout check. Do not edit `ScanLineRunner.v`; only the parameter on the instance.

In proj150, GPU writes go through the **bpas_*** RC port; fill_* and line_* are tied off. 09 does the same for SLR.

### 2.3 Already in 08 (copy, do not edit 08)

- Unmodified cs150 `RequestController.v` (md5 `96ddedbc…`, 34-bit `caf_cadr`, **no** `caf_backlog`, priority **inst, data, gcmd, pixf, fill, line, bpas**). This is *not* proj150's RC (md5 `419c73be…`, PixelFeeder first, 31-bit addresses, `caf_backlog`). Keep the cs150 one.
- `rc_axi_fifo_adapter.v` (md5 `0157b44b…`, same as 06). Apply the patch only to 09's copy.
- `pixel_feeder_rc.v`, verbatim `PixelFeeder.v`, `frame_drawer.v`, UART, vga_timing, test_pattern, rgb2dvi, overlay top, FIFOs `mig_caf` / `mig_wdf` / `mig_rdf` / `pixel_fifo`.

### 2.4 IP and sim models to add

| IP / model | Source | Use |
|------------|--------|-----|
| `cache_data_blk_ram.tcl` | `~/proj150/ip/cache_data_blk_ram.tcl` | blk_mem_gen 8.4, SDP, 256 × 256-bit, byte WE, no output regs |
| `cache_tag_blk_ram.tcl` | `~/proj150/ip/cache_tag_blk_ram.tcl` | same, 256 × 21-bit |
| `cache_brams.v` | `~/proj150/sim/icarus/models/cache_brams.v` | Icarus stand-ins, same port names |
| Patch extras | `patches/0001-…` plus `sim/axi4_slave_rand.v` (in the patch, not yet in 08) | Hostile AXI slave for hazard sim |

Two caches: two data BRAMs + two tag BRAMs. Comfortable on the xc7z020.

The held patch is already on disk, unapplied:

- `~/pynq150/patches/0001-rc_axi_fifo_adapter-address-conflict-check.patch`
- `~/pynq150/patches/README-0001.md`

It was made against 06 at d020508. Apply **only** the adapter file onto 09 (`git apply -p2 --directory=09_cache_slr_test --include='*/rtl/rc_axi_fifo_adapter.v'`), after 08's adapter has been copied. 08's copy was byte-identical to 06's when checked. Also copy the patch's `axi4_slave_rand.v` into 09's sim for the negative test. Do not apply it to 08.

---

## 3. Files to copy and files to write

Create the 09 tree by copying 08, then add/change only under 09.

### 3.1 Copy verbatim

```
# from 08 (starting snapshot)
rtl/RequestController.v
rtl/rc_axi_fifo_adapter.v          # then apply the patch to this copy
rtl/pixel_feeder_rc.v
rtl/frame_drawer.v                 # reconnect only, in fb_core
rtl/pf_video_sink.v
rtl/vga_timing.v
rtl/test_pattern.v
rtl/proj150/PixelFeeder.v
rtl/proj150/gpcommands.vh
rtl/vendor/rgb2dvi/…               # unchanged
rtl/fb_overlay_top.v               # likely unchanged
constr/pynq_z2_hdmi_fb.xdc
ip/mig_caf.tcl ip/mig_wdf.tcl ip/mig_rdf.tcl ip/pixel_fifo.tcl
sim/models/…  sim/axi4_slave_pipe.v
01_uart_echo/rtl/uart_{rx,tx}.v    # still referenced, not copied

# from cs150 (Cache) — keep include path working
rtl/cs150/Cache.v                  # from hardware/src/base_mem/Cache.v
rtl/cs150/cache.vh                 # sibling, for `include "cache.vh"

# from proj150 (SLR + Const + cache IP + sim BRAM)
rtl/proj150/gpu/ScanLineRunner.v   # keep ../base_util/ include
rtl/proj150/base_util/Const.v
ip/cache_data_blk_ram.tcl
ip/cache_tag_blk_ram.tcl
sim/models/cache_brams.v
```

Icarus and Vivado need `+incdir+rtl/cs150` (for `cache.vh`) and the SLR file left under `rtl/proj150/gpu/` so `../base_util/Const.v` resolves. Mark `ScanLineRunner.v` SystemVerilog if the named generate-block issue comes up (PixelFeeder already is).

### 3.2 New or rewritten in 09

| File | Role |
|------|------|
| `rtl/slr_rc.v` | Thin wrapper: `ScanLineRunner` with `SLR_COUNT=1`, `LITTLEWORDIAN=0`; packs `{wdf_mask, wdf_data}` into 144-bit `bpas_wdf_mdat`; presents a one-shot command (row, x0, x1, frame, colours) and a `busy`/`done`. No Arty address shift. |
| `rtl/cache_port.v` | CPU-side handshake for one `Cache`: hold `{addr, din, we, re}` until `stall` falls; pulse `done`; report `hit` (read that stayed in IDLE after the capture cycle, or write with `tag_hit`) vs `miss`; count hits, misses, last and total stall cycles. Two instances (I and D). |
| `rtl/fb_core.v` | From 08: move `frame_drawer` to fill_*; hook ICache/DCache/SLR; add the ASCII command parser (§5). Keep every 08 command bitwise identical. |
| `sim/tb_09.v` | From `tb_fb.v`, plus cache / SLR / hazard cases (§6). |
| `sim/axi4_slave_rand.v` | From the patch, for hazard tests. |
| `host_09.py` | From `host_fb.py`, plus the new tokens. |
| `holder_hdmi_09.py` | From `holder_hdmi_fb.py`, 16 MiB CMA, also print `CACHE=BASE+12MiB`. |
| `Makefile`, `build_hdmi_09.tcl` | From 08; add cache IP, new sources, `simmix` / hazard targets. Overlay `../build/hdmi_09/`. |
| `README.md` | Protocol, map, how to run. |

---

## 4. Top-level wiring and memory map

### 4.1 RC clients and priority

08/cs150 RequestController, highest first:

| Priority | Port | 08 today | 09 |
|----------|------|----------|----|
| 1 | inst_* | tied off | **ICache** |
| 2 | data_* | frame_drawer | **DCache** |
| 3 | gcmd_* | tied off | tied off |
| 4 | pixf_* | PixelFeeder | PixelFeeder (unchanged) |
| 5 | fill_* | tied off | **frame_drawer** (08 C/F/B/H/G/X) |
| 6 | line_* | tied off | tied off |
| 7 | bpas_* | tied off | **ScanLineRunner** |

Because the drawer moves *below* PixelFeeder, full-frame paints no longer need a gap to let the feeder in (the 08 `P` gap can stay, default 128). ICache and DCache are *above* PixelFeeder, so a long cache fill can starve HDMI and trip underflow (auto-resync is on). Keep cache bursts short, or accept a resync; status `'U'` still reports it.

`rdf_data` is still the shared `ALLR_rdf_data` bus, as in MemoryDDR / 08.

### 4.2 Memory map (WIN_AW = 24, 16 MiB window at `'A'` / BASE)

Same PixelFeeder layout as 08: byte offset `{frame[5:0], y[9:0], x[9:0], 2'b00}`, 32-bit pixels `0x00RRGGBB`, 4096-byte stride, 32-byte RC/AXI blocks.

| Offset from BASE | Size | Use |
|------------------|------|-----|
| `0x000000` | 4 MiB | Unused in DDR. Frame 0 is PixelFeeder's local pattern and does not read DDR. |
| `0x400000` | 4 MiB | **Frame 1.** Visible 800×600 uses 600 × 4096 = 2,457,600 bytes; the rest of the slot is padding. |
| `0x800000` | 4 MiB | **Frame 2.** |
| `0xC00000` | 4 MiB | **Cache test region.** Not displayed. Conflict pair at `addr` and `addr + 0x2000`. |

08's holder allocates 12 MiB and the 08 testbench rejects AXI outside frames 1–2. 09 should grow the CMA buffer and the holder printout to 16 MiB (`CACHE = BASE + 12 MiB`). UART cache addresses are **window-relative byte addresses** (e.g. `0xC00000`). Bits `[31:28]` are ignored by Cache's CAF path, same as cs150 dropping the 0x1 nibble.

Alternative, if we want to keep a 12 MiB buffer: put cache tests in the invisible tail of frame 1 (`0x400000 + 0x258000` … `0x7FFFFF`, ~1.6 MiB). Prefer the dedicated 4 MiB slot.

---

## 5. UART protocol

115200 8N1. **All 08 commands stay bitwise identical** (binary argument bytes, same replies). New 09 commands use a separate ASCII-argument path so a human can type them, and so they cannot be confused with `'A'`/`'F'`/`'S'`/`'T'`/`'P'` raw bytes.

### 5.1 08 commands (unchanged)

| Command | Args | Reply |
|---------|------|-------|
| `A` a0 a1 a2 a3 | BASE, 4-byte little-endian, `[4:0]` forced 0 | `K` |
| `S` n | show frame n (0 = local pattern, 1 or 2 = DDR) | `K` / `N` / `?` |
| `T` n | draw target frame n (1 or 2) | `K` / `?` |
| `C` | clear target frame to black | `D` (or `N` / `E`) |
| `F` r g b | fill target with `0x00rrggbb` | `D` |
| `B` `H` `G` `X` | bars / checker / gradient / grid | `D` |
| `P` g | gap after each drawer line | `K` |
| `V` | toggle source | `V` or `v` |
| `Q` | toggle auto-resync | `Q` or `q` |
| `Z` | resync PixelFeeder | `K` |
| `U` | status `Us RRRR PPPP Wwwwwwwww\n` | that 23-byte line |
| anything unknown, or a 08 command with a bad arg | | `?` |

Draw replies wait until the drawer is done **and** the adapter is idle, as in 08.

### 5.2 ASCII parser (new commands only)

After a new command letter the FSM enters `ST_ASCII`:

- Leading whitespace is skipped.
- Numbers are decimal (`100`) or hex (`0x64`, `0X64`). No bare `$` / `h` prefix unless Erik prefers one.
- Numbers are separated by space or comma.
- The argument list ends on `\n`, `\r`, or `;`. `\r\n` is one terminator.
- Missing required args, a bad digit, or a value that does not fit 32 bits → reply `?` and drop the rest of the line.
- `N` if BASE has not been set and the command would touch DDR.
- Replies are ASCII, usually one line ending in `\n`. Hex in replies is lowercase without a `0x` prefix, unless noted.

Letters used for new commands avoid 08's command set `{A,S,T,C,F,B,H,G,X,P,V,Q,Z,U}`.

### 5.3 New cache and SLR commands

Addresses are window-relative byte addresses. Word accesses should be 4-byte aligned (`[1:0]=0`); if not, the low bits are forced to 0 and the command still runs (or we can reject with `?` — prefer force-align and mention it in the README).

| Command | Meaning | Reply |
|---------|---------|-------|
| `R <addr>` | DCache read one word | `R <data> h\|m <cyc>\n` (`h` hit, `m` miss, `cyc` stall cycles, hex) |
| `R <addr> <count>` | DCache read `count` words, addr += 4 each | `R <first> … <last>  H=<hits> M=<misses>\n` (keep it short: if count > 8, print first/last only plus the counters) |
| `W <addr> <data>` | DCache write one word, `we=4'hF` | `W h\|m <cyc>\n` |
| `J <addr>` or `J <addr> <count>` | ICache fetch / read range (same shape as `R`) | `J <data> h\|m <cyc>\n` or the range form |
| `D f <addr> <words> <data>` | DCache fill: write `words` words with `data` (e.g. incrementing optional later) | `D P <hits> <misses> <cyc>\n` or `D F` / `E` |
| `D v <addr> <words> <data>` | DCache verify: read and compare | `D P` or `D F <addr> <got> <exp>\n` |
| `E <addr>` | Same-line write-then-re-miss on DCache: store a unique word at `addr` **without** a prior fill (write miss, no allocate), then immediately load `addr` (read miss / FETCH). Does **not** wait for adapter idle between the two. | `E P <data> <cyc_w> <cyc_r>\n` if the load returns the stored word, else `E F <got> <exp> …\n` |
| `E x <addr>` | Replacement test: fill `addr`, write a new value (hit, write-through), read `addr+0x2000` (conflict miss, replaces the line), read `addr` again (re-miss). Checks the cache, not the adapter race. | `E x P …` / `E x F …` |
| `O <addr> <data>` | Coherence: DCache store `data` at `addr` (write-through), then **as soon as DCache `stall` falls** ICache fetch `addr`. Must not wait for AXI/BRESP. | `O P <data> <cyc_d> <cyc_i>\n` / `O F <got> <exp> …\n` |
| `M` | Dump counters | `M IH=<…> IM=<…> IC=<…> DH=<…> DM=<…> DC=<…>\n` (hits, misses, total stall cycles for I and D) |
| `M c` | Dump and clear counters | same line, then zeros |
| `Y <rgb>` or `Y <rgba>` | Sticky SLR colour. 24-bit `0xRRGGBB` is stored as `0xFFRRGGBB` (fill enabled). 32-bit value used as-is (so a 0 high byte makes edge-only spans). | `K` |
| `L <row> <xstart> <xfinish> [color]` | SLR solid span on the current draw target (`T`). Optional `color` overrides sticky `Y` for this span only. Defaults: row 0–599, x 0–799, colour sticky (reset default `0xFF00FF00`). | `D` when SLR is done and the adapter is idle; `N` / `E` / `?` as usual |

`Y` / `L` colour and the 08 `'F'` fill colour are independent (`F` still paints a whole frame through the drawer).

Worked SLR examples (all equivalent for a red span on row 100, x 10–200):

```
Y 0xff0000
L 100 10 200
L 100,10,200
L 0x64 0xa 0xc8 0xffff0000
```

Host helper tokens (in addition to 08's): `R:0xC00000`, `W:0xC00000:0xA5A5A5A5`, `J:0xC00000`, `Df:addr:words:data`, `Dv:…`, `E:addr`, `Ex:addr`, `O:addr:data`, `M`, `Mc`, `Y:ff0000`, `L:100:10:200`.

---

## 6. Sim plan

Icarus, same reduced raster idea as 08 (`64×16` or keep 800×600 for SLR spans and shrink time elsewhere). 100 MHz clk, 40 MHz pix, fast UART. `make sim` must `TB_PASS`.

1. **08 regression.** `'A' S1 C F B H G X T2 … V Z U` and memory/video layout checks, with the drawer now on fill_*. AXI may also touch `0xC00000–0xFFFFFF`; update the out-of-window check.
2. **DCache word / range / fill / verify** in the cache region. First access of a line is a miss; a second read of the same word is a hit; a write then read without a conflict is a hit and returns the new data.
3. **ICache read range** of a region previously filled by DCache (after the write has been allowed to land, i.e. wait for adapter idle) — must match. Then an ICache hit on a second fetch of the same word.
4. **Conflict replacement (`E x`).** After writing A, a read of A+8 KiB must evict A; a later read of A is a miss and still returns the written value.
5. **SLR.** `L` a short span on frame 1; check pixels in the model with the 08 formula `BASE + f*4MiB + y*4096 + (x & ~3)*4 + (3-(x&3))*4`. Also a reversed `xstart > xfinish`, a one-pixel span, and a full-width row. If the colours land in the wrong 16-byte half, flip the SLR `LITTLEWORDIAN` parameter only.
6. **Same-address hazards** (the tests that justify the patch). Use `axi4_slave_rand.v` so a read can sample memory before a previous write's BRESP, which is legal for HP0.

   | Case | Why it is a race |
   |------|------------------|
   | `E <addr>` (DCache write miss, then immediate read miss of the same line) | Cache issues WRITE then FETCH without waiting for BRESP. |
   | `O <addr> <data>` (DCache write-through, immediate ICache fetch) | Two RC clients, write then read of the same line. |
   | SLR (or drawer) write of a line, then DCache or ICache fetch of that line without waiting for idle | Write-only port vs cache read. |

   Run each case three ways:

   - 09 adapter **with the patch** (`HAVE_HZ`): must **PASS**.
   - 08/direction-barrier adapter (no patch): also **PASS**, because the barrier is conservative, but mixed-direction throughput is worse.
   - Adapter with **neither** barrier nor hazard check (a one-define strip, or a tiny copy): must **FAIL** against the random slave. This is the "fails without the patch" result. The live 08 adapter will not fail these tests, and the plan should not pretend it will.

   Throughput (`simthru` from the patch) is worth re-running on 09's patched adapter as a sanity check, not a gate.

7. **Video still works** while a short SLR span and a short cache fill run; underflow is allowed during a long `D f` and should recover with auto-resync.

---

## 7. Build and hardware test plan

Only after 08 is off the board (stop the 08 holder first). Never touch the XUPV5. Only `localhost:3121/xilinx_tcf/Xilinx/1234-tulA`.

1. `make sim` (and the hazard variants) all `TB_PASS`.
2. `make overlay` → `~/pynq150/build/hdmi_09/hdmi_09.{bit,hwh}`. Record WNS/WHS and LUT/FF/BRAM. Expect a few extra BRAMs and LUTs vs 08; timing should still be easy at 100 MHz / 40 MHz.
3. Copy bit, hwh, and `holder_hdmi_09.py` to `/home/xilinx/hdmi_09/`. Load with the usual PYNQ profile scripts. Confirm `OVERLAY_LOADED`, FCLK0 100 MHz, and a 16 MiB `BASE` / `FRAME1` / `FRAME2` / `CACHE` line.
4. `host_09.py --addr 0xBASE A S1 C` — black frame on `/dev/video2` at 800×600 (drop the first black dongle frames).
5. 08 paints: `F:ff0000 B H G X`, capture a frame.
6. SLR: clear, then `L` a few spans (e.g. a red bar on row 100, a cross of a full-width row and a 1-pixel-wide column built from 600 one-pixel spans, or a short run of rows). Capture and, if useful, `dump` a PPM from the holder. Copy a capture to the box for Erik.
7. Cache in the `CACHE` region: `D f` / `D v`, `R`/`W` hit vs miss, `E`, `E x`, `O`. Confirm `P` replies. `M` counters should show misses on first touch and hits on repeats.
8. Visible cache/SLR interaction: DCache or SLR write a solid colour into a rectangle of **frame 1**, `S1`, confirm it on the dongle (optional, nice).
9. `'U'` after a short mixed test: note underflow. A long DCache fill while showing a DDR frame may underflow; that is expected with I/D above PixelFeeder.

Leave 09 uncommitted until Erik says so.

---

## 8. Risks and open questions

### Risks

- **Write-through Cache.** The earlier "dirty evict then re-miss" story assumed write-back. cs150 `Cache.v` never write-backs; the adapter race is "store issues a DDR write, then a later FETCH of that line before BRESP." `E` and `O` are written around that. `E x` still tests replacement.
- **SLR endianness.** proj150 uses `LITTLEWORDIAN=1`; 08's proven pixel order needs `0`. Sim case 5 is the check.
- **ICache/DCache can starve PixelFeeder** (cs150 priority, not proj150's pixf-first). Short tests, auto-resync on.
- **08 is still in flux.** Copy 08 only when it is the tree we want to start from.
- **Patch apply path.** If 08's adapter changes before the copy, `--3way` or copy the 06 patched file, then re-check md5 / a three-way diff.
- **`write_hit_hold = we_hold && tag_hit`** in cs150 Cache (`we_hold` is 4 bits). Live on the XUPV5; leave it alone.
- **Const.v / include layout.** Breaks if SLR is flattened next to PixelFeeder without `base_util/`.

### Open questions for Erik

1. **cs150 `Cache.v` (recommended)** vs proj150's Arty-ported `Cache.v`. The cs150 file matches 08's RC (34-bit, byte>>3). Agreed?
2. **Recasting "dirty evict"** as write-through then same-line re-miss (`E`) plus a replacement test (`E x`). OK, or do you want a write-back change in 09 (that would be editing Cache, which this plan does not do)?
3. **16 MiB CMA + dedicated cache region at BASE+12 MiB** (recommended) vs using the invisible tail of frame 1 and keeping 12 MiB?
4. **Keep `frame_drawer` on fill_*** so 08 full-frame commands stay fast and independent of the caches (recommended), or paint `'C'`/`'F'`/… through DCache?
5. **SLR colour:** sticky `Y` plus optional 4th `L` argument, with fill enabled by default (`0xFFRRGGBB`). Want edge-only spans in the first hardware run, or only solid bars?
6. **ASCII command letters and number syntax** (`0x` / decimal, newline- or semicolon-terminated) as in §5.3 — any changes before implementation?
7. **Start 09 only after 08 is committed**, or copy the live 08 tree when you say to begin?
