# 09_cache_slr_test

The 08 PYNQ-Z2 framebuffer overlay (cs150 RequestController -> AXI HP0, 800x600
HDMI from the cs150 PixelFeeder), plus three more RequestController clients you
can drive over the UART:

- the **cs150 instruction and data caches** (`Cache.v`, write-through,
  direct-mapped 256 x 32 B) on `inst_*` / `data_*`
- the **proj150 ScanLineRunner** (horizontal spans, "simple drawing") on `bpas_*`
- the 08 full-frame `frame_drawer`, moved from `data_*` to `fill_*`

Together with the PixelFeeder on `pixf_*`, that is every read and write source
the RequestController arbitrates (no `gcmd`/`line` clients). The adapter
carries **patch 0001** (per-line address-conflict check instead of the
read/write direction barrier). Only this directory's copy is patched; 08 still
uses the barrier. See `PLAN.md` for the design reasoning.

```
UART -> fb_core FSM -> cache_ex (2x cs150 Cache) -> inst_*, data_*
                    -> frame_drawer              -> fill_*
                    -> slr_rc (ScanLineRunner)   -> bpas_*
       PixelFeeder (pixel_feeder_rc)             -> pixf_*
RequestController (cs150, unmodified) -> rc_axi_fifo_adapter (+0001) -> HP0
```

## Memory (16 MiB CMA window, BASE from the holder)

| Offset | Use |
|---|---|
| +0 MiB | unused (frame 0 = PixelFeeder built-in pattern) |
| +4 MiB | frame 1 |
| +8 MiB | frame 2 |
| +12 MiB | cache test region (not displayed) |

Cache addresses are byte offsets from BASE (window-relative, 0 .. 0xFFFFFF).
With `LITTLEWORDIAN=1`, word w of a 32-byte cache block is pixel w, in the same
view the drawer, the SLR and the PixelFeeder use. So `R 0x403028` reads frame 1,
row 3, pixel 10. In DDR the 16-byte halves are word-reversed, as in 08, so the
ARM view of an address differs from the cache view (see 08 README, DDR layout).

## UART commands (115200 8N1)

All 08 binary commands (`A S T C F B H G X P V Q Z U`) are unchanged. New ASCII
commands take decimal or `0x` hex numbers separated by spaces or commas,
ended by `\n`, `\r` or `;`. Each reply is one line.
The full reference is the header of `rtl/fb_core.v`.

| Command | Does | Reply |
|---|---|---|
| `R addr [n]` | D-cache read | `R dddddddd h\|m cycles` / `R first last H= M=` |
| `J addr [n]` | I-cache read | same, with `J` |
| `W addr data` | D-cache write (write-through, no allocate on miss) | `W h\|m cycles` |
| `D f addr n data` | fill n words, word i = data+i | `D P hits misses` |
| `D v addr n data` | verify | `D P hits misses` / `D F addr got exp` |
| `E addr [data]` | write, then same-line re-miss (RAW hazard) | `E P\|F got exp cw cr h\|m` |
| `E x addr [data]` | fill, write hit, 8 KiB conflict evict, re-miss | `X ...` |
| `O addr [data]` | D write, then immediate I fetch of the same line | `O ...` |
| `M` / `M c` | hit/miss/stall-cycle counters (c clears them) | `M IH= IM= IC= DH= DM= DC=` |
| `Y color` | sticky SLR colour (<= 24 bit -> fill on) | `K` |
| `L row x0 x1 [color]` | ScanLineRunner span on the draw target (`T`) | `D` |

Errors: `?` syntax/range, `N` no `A` yet, `E` AXI error. In E/X/O replies the
last field must be `m`, which shows the read really came back from DDR.

Limitation: send one ASCII command per line and wait for its reply. Characters
that arrive while a reply is being sent are dropped.

## Sources

| File | From |
|---|---|
| `rtl/RequestController.v`, `pixel_feeder_rc.v`, `frame_drawer.v`, `pf_video_sink.v`, `vga_timing.v`, `test_pattern.v`, `fb_overlay_top.v`, `rtl/proj150/PixelFeeder.v`, `gpcommands.vh`, `rtl/vendor/rgb2dvi`, `constr/`, `ip/mig_*.tcl`, `ip/pixel_fifo.tcl`, `sim/models/ip_fifos.v`, `fifo_async_fwft_model.v`, `sim/axi4_slave_pipe.v`, `sim/tb_hdmi_cs150.v`, `sim/tb_tmds_encoder.v` | 08, verbatim |
| `rtl/rc_axi_fifo_adapter.v` | 08 + `patches/0001` (adapter file only) |
| `sim/ref/rc_axi_fifo_adapter_barrier.v` | 08 adapter, unpatched (reference) |
| `sim/axi4_slave_rand.v`, `sim/tb_adapter_mixed.v` | from `patches/0001` |
| `rtl/cs150/Cache.v`, `cache.vh` | `~/cs150-1245/hardware/src/base_mem/` |
| `rtl/proj150/gpu/ScanLineRunner.v`, `rtl/proj150/base_util/Const.v`, `ip/cache_*_blk_ram.tcl`, `sim/models/cache_brams.v` | `~/proj150` |
| `rtl/fb_core.v` | 08's, with new RC/client wiring, ASCII parser and FSM |
| `rtl/cache_ex.v`, `rtl/slr_rc.v`, `sim/tb_09.v`, `sim/tb_hazard.v` | new |
| `build_cache_slr.tcl`, `holder_hdmi_09.py`, `host_09.py`, `Makefile` | adapted from 08 |

## Simulate (Icarus 12)

```
make sim       # simcore + simhz
make simcore   # tb_09: full 08 regression + every 09 command -> sim/core.log, TB_PASS
make simhz     # tb_hazard: E/O/E x x16 vs a random-latency AXI slave -> sim/hz.log
               #   patched adapter, 3 seeds:           0 stale  (TB_PASS)
               #   08 barrier adapter:                 0 stale  (TB_PASS)
               #   patch with the hazard check removed: stale reads (EXPECT_FAIL)
```

## Build

`make overlay` runs `build_cache_slr.tcl` and writes outputs to `../build/cache_slr/`
(`cache_slr.bit`, `.hwh`, `util.rpt`, `timing.rpt`, ...). It uses `-jobs 4`.

## Hardware run

1. Copy `cache_slr.bit`, `cache_slr.hwh` and `holder_hdmi_09.py` to `/home/xilinx/cache_slr/` on the PYNQ.
   Run the holder as in 08. It prints `BASE ... CACHE=`.
2. Run `./host_09.py --addr BASE A T1 S1 ...` with the tokens below, in this order:
   - 08 sanity: `A T1 F:ff0000 S1 U`.
   - Caches: `"R 0xC00000" "R 0xC00000" "W 0xC00000 0x12345678" "R 0xC00000"`,
     `"D f 0xC00000 2048 0x11110000" "D v 0xC00000 2048 0x11110000"`, `"J 0xC00000 8"`, `M`.
   - Hazards: repeat `"E 0xC10000"`, `"E x 0xC20000"`, `"O 0xC30000"` on new lines.
     Every reply must be `P` with last field `m`.
   - SLR: `C "Y 0xff0000" "L 100 0 799" "L 300 200 600 0x00ff00" "R 0x464000" "R 0x52C640"`
     (expect `FFFF0000` and `FF00FF00`).
     Check the HDMI picture too.

## Hardware results (PYNQ-Z2, 2026-11-26)

`cache_slr.bit` md5 e5cb55fe9515c2e242146c353c0238d2; holder printed
`BASE=0x16900000 CACHE=0x17500000 LEN=0x1000000`. PixelFeeder was showing frame 1 for all tests.

- 08 sanity (A S1 T1 C F B H G X U): all replies correct; full-frame draw 0x78CC4B cycles = 79.2 ms.
- Caches: read miss 61 cycles (0x3D), hit 1, write 3 (hit or miss); write miss does not allocate
  (R after W-miss returns the new data as a miss); D f/D v 2048 words pass, D v mismatch reports addr/got/exp.
  An I-cache line stays stale after D-cache writes (no coherence, as in cs150); this is how `J` shows old data.
- Hazards (E, E x, O): 900 on fresh and repeated lines + 1150 random (including 150 on lines the PixelFeeder
  was displaying): all `P`, last field `m`. Re-fetch latency after the write: E 97..166 (avg 103),
  E x 60..165 (avg 68), O 97..181 (avg 103) cycles; write 3 cycles.
- SLR: 604 L spans over the UART (9.8 s), 29 boundary readbacks via `R` all match; HDMI capture of
  `slr_demo.py` matches the expected picture (shift 0, err 4.9).
- Dongle: `verify_capture.py` captures of checker, gradient, grid, red fill, bars all shift 0
  (errors as in 08). One bars attempt stayed black for 6 retries even with `V V` / `Z`; redrawing worked.
- Files: `capture/09_slr_demo.png`, `capture/fb/09_*.png` (gitignored); `slr_demo.py`, `capture_frame.sh`,
  `verify_capture.py` (from 08).
