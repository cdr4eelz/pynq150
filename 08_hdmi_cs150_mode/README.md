# 08_hdmi_cs150_mode

Two stages in one folder:

1. **Test pattern at the cs150/proj150 video mode** (800x600@60, 40.000 MHz, positive
   syncs). No DDR. `make sim-pattern`, `make overlay-pattern`.
2. **Framebuffer: proj150's `PixelFeeder` + pixel FIFO as a client of the unmodified
   cs150 `RequestController`, feeding the HDMI output from DDR.** A UART state
   machine draws into the frame (clear, fill, bars, checker, gradient, grid).
   `make sim`, `make overlay`. This is the default; the pattern stays as a
   selectable fallback (`V`).

## Stage 2: PixelFeeder framebuffer

```
UART --> command FSM (fb_core) --> frame_drawer --(dcache port)--+
                                                                 v
 PixelFeeder (pixf port) --> RequestController (cs150, md5 96ddedbc..) --> rc_axi_fifo_adapter
   ^   (clk 100 MHz)             mig_caf/wdf/rdf FIFOs                       --> SmartConnect --> PS7 HP0 --> DDR
   |
 pixel_fifo (128b->32b async, 100->40 MHz) --> pf_video_sink --> mux (V) --> rgb2dvi --> HDMI
```

RequestController clients used: **dcache** = `frame_drawer` (write-only use of
the Cache.v handshake), **pixf** = PixelFeeder (read-only). All other ports tied off.
The RequestController is byte-for-byte the 06 copy; the adapter, the mig FIFO tcl and the
Icarus FIFO models are 06's.

### Files copied from proj150 (read-only source `~/proj150`, last commit touching them c363882)

| File | How | Notes |
|---|---|---|
| `rtl/proj150/PixelFeeder.v` | **verbatim** (cmp-identical) | Not the cs150 original: proj150 modified it (see below). Uses SystemVerilog end labels, so Icarus needs `-g2012` and Vivado `file_type SystemVerilog`. |
| `rtl/proj150/gpcommands.vh` | verbatim | `FRAME_BITS` macro |
| `ip/pixel_fifo.tcl` | verbatim | 128-bit write x 512, 32-bit read, FWFT, independent clocks, prog_full 448, prog_empty 1600 |
| `ip/mig_caf.tcl`, `mig_wdf.tcl`, `mig_rdf.tcl` | verbatim (via 06) | |
| `sim/models/ip_fifos.v`, `fifo_async_fwft_model.v` | verbatim (via 06) | includes the pixel_fifo model |

Nothing in PixelFeeder is edited. **`rtl/pixel_feeder_rc.v`** wraps it:

- **Address units.** proj150's PixelFeeder (modified from cs150 for the Arty DDR3 MIG UI) drives a
  28-bit `raf_addr` in 16-bit units, `{1'b0, head_addr[27:1]}`, with
  `head_addr = {frame[5:0], y[9:0], x[9:0], 2'b00}`. The cs150 RequestController
  takes a 31-bit address in 8-byte units (cs150's own PixelFeeder drives `head_addr[27:3]`).
  Every request is 32-byte aligned, so the wrapper uses `{5'd0, raf_addr28[27:2]}` (exact).
- **Resync.** PixelFeeder streams pixels with no frame marker, so after any underflow the
  stream and raster are out of step for good. On `resync` or MMCM unlock the wrapper
  holds PixelFeeder (and the pixel FIFO) in reset for >=256 clocks AND until every
  issued pixf read has returned, so no stale beat lands in the fresh FIFO. The
  feeder reset itself is asserted 16 clocks after the sink is stopped, so the reset does not
  look like an underflow.
- `pf_vframe = 1`, `pf_wframe = frame` selects the frame; the change takes effect at the next frame end.

`rtl/pf_video_sink.v`: free-running `vga_timing` raster; starts pulling one pixel per DE clock
at active (0,0) when `video_valid` is high (same idea as proj150's VGAFramer). If valid is
low on an active pixel while running: `running` drops, the pixel is black, an underflow
toggle goes to the clk domain (sticky flag + auto-resync).

### Frame base and address mapping

- The holder (`holder_hdmi_fb.py`) allocates a **12 MiB** zeroed CMA buffer and prints
  `OVERLAY_LOADED PHYS=BASE=0x........ FRAME1=BASE+0x400000 FRAME2=BASE+0x800000 LEN=0xC00000`.
  The host sends BASE with `A` (`[4:0]` forced 0). Last run: BASE = `0x16900000`,
  FRAME1 = `0x16D00000`, FRAME2 = `0x17100000`.
- RequestController byte address = `{frame[5:0], y[9:0], x[9:0], 2'b00}`: **frame N at N x 4 MiB,
  4096-byte line stride, 4 bytes per pixel `0x00RRGGBB`** (only 3200 of each 4096 bytes used).
  This is proj150's layout (cs150's frame 1 is CPU 0x1040_0000 = also N x 4 MiB inside
  its 0x1000_0000 DDR window). Adapter: AXI address = BASE + `{caf_cadr[WIN_AW-4:2], 5'b0}`,
  WIN_AW = 24 (16 MiB window), so frames 1 and 2 fit (frame 0 = PixelFeeder's local pattern, no DDR reads).
- **Pixel order in memory:** the cs150 line buffer puts pixel k at `line[255-32k -: 32]`; the adapter
  stores beats lower-first, so inside every 16-byte group the four 32-bit words are
  reversed (pixel 0 at bytes 12..15). `frame_drawer` writes it that way; the holder's `dump` decodes it.

### UART protocol (115200 8N1, Pmod USBUART on JA, `/dev/ttyUSB3`)

| Command | Meaning | Reply |
|---|---|---|
| `A` a0 a1 a2 a3 | set BASE (little endian) | `K` |
| `S` n | display frame n: 0 = PixelFeeder local pattern, 1, 2 = DDR (1, 2 need `A`) | `K` / `N` / `?` |
| `T` n | draw target frame (1 or 2; default 1) | `K` / `?` |
| `C` | clear target to black | `D` |
| `F` r g b | fill target with a colour | `D` |
| `B` | 8 colour bars (white yellow cyan green magenta red blue black) | `D` |
| `H` | checkerboard, 32 px squares | `D` |
| `G` | gradient `{x, y, ~x}` | `D` |
| `X` | grid: 64 px white lines, green crosshair, red 2 px border | `D` |
| `P` g | gap: idle clocks after each 32-byte write (default 128) | `K` |
| `V` | toggle source | `V` = PixelFeeder now, `v` = test pattern now |
| `Q` | toggle auto-resync | `Q` on / `q` off |
| `Z` | force a PixelFeeder resync | `K` |
| `U` | status line `Us RRRR PPPP Wwwwwwwww\n` (23 chars); then clears the underflow flag. s = underflow since last U, RRRR = resyncs, PPPP = pf_status (`{video_fault, !active, frame[5:0], 8'b0}`), W = clocks of the last draw | |
| `R` x0 x1 y0 y1 | debug probe (little-endian 16-bit x, y), 29 chars `R vvvvvvvv tttttttt dddddddd\n`: v = pixel the sink took at (x,y) in the last frame (bit31 taken, bit30 valid, bit29 running, [23:0] RGB), t = pixels taken last frame (0x75300 = 480000), d = pixf beats outstanding (2 x accepted requests - returned) | |

Draw commands reply `N` before `A`, `E` on AXI error. `D` is sent only after the adapter is idle (all write
responses back), so a following `S` shows the finished frame. Other characters reply `?`.
Host: `host_fb.py --addr 0x<BASE> A S1 C F:ff0000 B H G X U R:100,300 ...`.

### Arbitration, tearing, underflow

- RequestController priority: dcache (drawer) **above** pixf. The adapter has a direction barrier
  (no reads in flight while writes are, and the reverse) and does not overlap read and write
  streams, so while the drawer writes, PixelFeeder reads are starved.
- The pixel FIFO holds 448-512 entries x 4 pixels = about 2000 pixels (~50 us at 40 MHz); one
  line is 800 pixels. A drawer line is 25 x 32-byte writes; with gap 16 each 32-byte write
  cost 19 clocks -> a frame draw is 11.4 ms and starves the feeder for longer than the FIFO
  covers, so **every full-frame draw underflowed once at gap <= 64** (measured sweep below).
  Auto-resync recovers it (feeder and sink restart at pixel (0,0), one black/local frame flashes).
- **Gap sweep** (800x600 fill, 3 draws each, hardware): gap 0: 3.17 ms (606 MB/s), 8: 6.60 ms, 16: 11.40 ms,
  24: 16.2 ms, 32: 21.0, 40: 25.8, 48: 30.6, 64: 40.2 ms: all underflow. **gap 96 (59.4 ms, 32 MB/s),
  128 (78.6 ms, 24 MB/s) and 255 (155 ms): no underflow.** Default is therefore **128**.
- **Tearing:** the drawer writes the frame being displayed, so a draw into the shown frame shows as a
  partially updated picture for ~80 ms. Draw into frame 2 (`T2`) and flip with `S2` for tear-free updates
  (tested: frame 1 stays intact while frame 2 is drawn).
- **Underflow flag:** `U` s=1 and the resync count rise; `Q` turns auto-resync off to see the failure:
  with gap 0 and `Q`, the picture stays slipped (capture `12_...slipped.png`: the frame is cyclically
  wrapped); `Z` recovers.

### Verification

- `make sim` (Icarus `-g2012`, 64x16 raster, pipelined AXI model with random stalls): **TB_PASS.**
  Checks all draw modes on screen and in memory (including the reversed word order), AXI addresses stay
  inside frames 1..2, double buffering, `U`, `V`, gap 0, forced `Z`, an injected underflow
  (auto resync and recovery) and the `R` probe; 114 frames, 0 bad frames, 0 bad hsync periods.
- `make overlay` (Vivado 2019.1): WNS **+1.477 ns** (clk_fpga_0), WHS +0.008 ns, pulse-width slack +2.845 ns,
  0 failing endpoints; `pix_unbuf` (40 MHz) WNS > +14 ns. 7682 LUT, 10088 FF, 9 BRAM tiles, 11 DSP, 8 OSERDESE2, 1 MMCM.
  A jtag_axi + dbg_hub are in the BD. CDC report: 2 "Critical" CDC-1 (PixelFeeder's own single-flop
  `video_active`/`video_fault` status crossings, unused here) and 1 CDC-10 (reset into the FIFO's
  own synchronizer; false path). `u_mmcm` clock crossings use `set_max_delay -datapath_only 10`.
- **Hardware (PYNQ-Z2, 2026-11-26):** see Results at the end; frames in `capture/fb/`.
- Not modified: `RequestController.v` (md5 96ddedbc194d41b4cf2e8e6d23f1e56f).

### Capture dongle caveat (/dev/video2)

The UVC dongle (345f:2130) shows black for a variable time (sometimes indefinitely) after being opened
or after the picture source changes, and only wakes after a source change (`V` twice), a
`Z` or similar. `capture_frame.sh` / `verify_capture.py` retry and compare the capture with the
expected pattern and report the best horizontal shift. Early captures in this stage showed the picture
cyclically shifted by 16 to 22 pixels; the `R` probe proved the sink output was exact at those moments
(e.g. bars edge at x=100, checker edge at x=32, grid line at x=64, 480000 pixels per frame), and
re-captures with the dongle awake show **shift 0** for every pattern. Those shifted captures are in
`capture/old_stage_dongle_shift/` and are treated as a dongle artifact (cause inside the dongle not identified).

---

## Stage 1: pattern only (unchanged)

The 07 HDMI colour-bar test pattern, retargeted to the **video mode that cs150
and proj150 use: VESA 800x600 @ 60 Hz**, 40.000 MHz pixel clock, positive
syncs, 24-bit RGB. No DDR, no AXI. The point is that a later PYNQ framebuffer
design can reuse the exact cs150/proj150 timing (`PixelCounter` / `VGAFramer`
parameters) and be checked against this known-good picture.

```
PS7 FCLK0 (100 MHz) -> MMCM (VCO 1000 MHz) -> pixel clock 40.000 MHz (/25)
                                           -> serial clock 200.000 MHz (/5, 5x)
vga_timing -> test_pattern -> Digilent rgb2dvi
     (3x TMDS_Encoder, 4x OSERDESE2 10:1 master/slave pairs, 4x OBUFDS TMDS_33)
     -> HDMI OUT connector (PL bank 35)
```

The design has a PS7 (DDR + FIXED_IO, FCLK0 and its reset exported to the PL),
so it loads through the PYNQ `Overlay` class. A PL-only bitstream freezes Linux.

## The cs150 / proj150 mode (sources)

Resolution 800x600, **40.000 MHz** pixel clock, 60 Hz refresh (VESA DMT
800x600@60: 40.000 MHz / (1056 x 628) = 60.317 Hz).

| | Active | Front porch | Sync pulse | Back porch | Total | Sync |
|---|---|---|---|---|---|---|
| Horizontal | 800 | 40 | 128 | 88 | 1056 | positive |
| Vertical | 600 | 1 | 4 | 23 | 628 | positive |

Colour: 24-bit RGB (8:8:8). In cs150 the CH7301 DVI transmitter is fed 12-bit
DDR, which carries the 24 bits.

cs150 (`~/cs150-1245`, read only):

- `hardware/src/ml505top.v:174-178` resolution table (640x480, 800x600,
  1024x768 ... entries); `ml505top.v:186-187` instantiates the **800x600**
  entry as the active one.
- `ml505top.v:268-302` `PLL_BASE` produces the 40 MHz pixel clock.
- `base_vid/PixelCounter.v:75-76` derives the active size as
  `Width/Height` (which are TOTAL sizes) minus front, pulse and back porch.
  `PixelCounter.v:167-189` makes hsync and vsync high during their pulse
  (positive).
- `base_vid/DVIData.v:157-167, 211-217` 24-bit RGB, 12-bit DDR to the CH7301;
  `DVIData.v:223-238` PixelCounter hookup.
- `gpu/PixelFeeder.v:9, 188-189, 311` hard-codes 800x600.

proj150 (`~/proj150`, read only), which keeps the same mode:

- `proj150.srcs/sources_1/imports/src/base_vid/VGAFramer.v:36-48` parameters
  and `:133-173` the sync compares; `base_vid/VGATestPattern.v:32-41` the same
  parameters. Positive syncs (`H_POL = V_POL = 1`).
- `ArtyA7top.v:74-90` and `boards/arty/ip/clk_wiz_0.tcl` (CLKOUT2): 40 MHz pixel
  clock.
- Differences from cs150: proj150 describes the porches with explicit
  parameters instead of cs150's total-size form (no CH7301 timing setup is
  involved). The vertical porches were corrected in
  commit 79c2869, and `README.md` (~lines 170-178) queues a further
  `VGAFramer` fix. Mode values themselves are unchanged from cs150.

**Sync polarity note.** The numbers say positive/positive, which is also the
VESA nominal for 800x600. `base_vid/DVIInitial.v:142-143` has a comment about
the CH7301 sync control ("Apos in = neg out" style wording) that suggests the
chip may invert on its way out; that is ambiguous for the DVI connector and is
not something a direct-TMDS design inherits. 08 uses positive syncs, and a DVI
sink at 800x600 locks on either polarity (confirmed by the capture dongle).

## Clocking

`MMCME2_ADV`, `DIVCLK_DIVIDE=1`, `CLKFBOUT_MULT_F=10.000` (VCO = 100 x 10 =
1000 MHz, inside the 600-1200 MHz range), `CLKOUT0_DIVIDE_F=25.000`
(40.000 MHz), `CLKOUT1_DIVIDE=5` (200.000 MHz). **Both clocks are exact from
FCLK0: 0 ppm error.** TMDS runs at 400 Mbit/s per lane, well below the
~1250 Mbit/s OSERDES limit of a -1 xc7z020, so nothing had to be changed about
the mode. (07 needed a fractional 40.25 multiplier to approximate
25.175 MHz; 08 does not.)

## What changed from 07

- `vga_timing.v`: defaults are now 800x600 positive-sync (the module was
  already parameterized).
- `test_pattern.v`: now parameterized. Bar index is `(x*41)>>12` (equals
  `x/100` for x = 0..799) and the ramp is `(x*327)>>10` (0..255). Bars occupy
  the top 450 lines (`BAR_H`), a grey ramp the bottom 150, a 2-px mid-grey
  border, and a 40x40 inverse box that bounces at 4 px/3 px per frame.
- `hdmi_cs150_top.v`: MMCM settings above; the timing and pattern instances
  carry the explicit mode parameters.
- `sim/tb_hdmi_cs150.v`: 800x600 / 1056x628, positive-sync monitors, exhaustive
  check of the bar and ramp arithmetic for every x.
- Renamed throughout (`hdmi_cs150_*`, BD `hdmi_cs150_ps`, build dir
  `../build/hdmi_cs150`, board dir `/home/xilinx/hdmi_cs150`).

Reused unmodified: Digilent `rgb2dvi` v1.4 in `rtl/vendor/rgb2dvi/` (BSD
3-clause, see `SOURCE.txt` and `MD5SUMS`; same files as 07).

## Files

- (stage 1) `rtl/vga_timing.v`, `rtl/test_pattern.v`, `rtl/hdmi_cs150_top.v`,
  `rtl/hdmi_cs150_overlay_top.v` (PS wrapper + top), `rtl/vendor/rgb2dvi/`
- `constr/pynq_z2_hdmi_cs150.xdc` (same pins as 07: clock L16/L17, data0
  K17/K18, data1 K19/J19, data2 J18/H18, BTN0 D19, LEDs R14 P14 N16 M14)
- `build_hdmi_cs150.tcl`, `holder_hdmi_cs150.py`, `Makefile`
- `sim/tb_hdmi_cs150.v`, `sim/tb_tmds_encoder.v`

LEDs: LD0 MMCM locked, LD1 pixel-clock blink (~1.2 Hz), LD2 frame toggle
(~30 Hz, looks dim), LD3 FCLK0 blink.

## Make targets

```
make sim            # stage 2: framebuffer (Icarus -g2012)
make overlay        # stage 2: -> ../build/hdmi_fb/hdmi_fb.{bit,hwh}
make sim-pattern    # stage 1: timing + pattern
make overlay-pattern  # stage 1 -> ../build/hdmi_cs150/hdmi_cs150.{bit,hwh}
make sim-tmds       # Vivado xsim: TMDS encoder (unchanged from 07)
```

## On the board

```
# host (UBU24):
B=~/pynq150/build/hdmi_cs150; S=~/pynq150/08_hdmi_cs150_mode
ssh xilinx@192.168.2.99 mkdir -p /home/xilinx/hdmi_cs150
scp $B/hdmi_cs150.bit $B/hdmi_cs150.hwh $S/holder_hdmi_cs150.py xilinx@192.168.2.99:/home/xilinx/hdmi_cs150/
# board (sudo password xilinx). Stop any other holder first, e.g.
#   touch /home/xilinx/hdmi_pattern/stop
sudo bash -c 'source /etc/profile.d/boardname.sh; source /etc/profile.d/xrt_setup.sh;
  source /etc/profile.d/pynq_venv.sh; cd /home/xilinx/hdmi_cs150;
  setsid nohup python3 holder_hdmi_cs150.py > holder.log 2>&1 < /dev/null &'
cat /home/xilinx/hdmi_cs150/holder.log      # OVERLAY_LOADED, FCLK0 100 MHz
touch /home/xilinx/hdmi_cs150/stop          # end the holder (the picture stays)
```

Capture on UBU24 (`/dev/video2`, UVC "USB3 Video", 345f:2130; discard the first
frames, they are black):

```
ffmpeg -f v4l2 -input_format yuyv422 -video_size 800x600 -framerate 60 -i /dev/video2 \
  -vf 'select=eq(n\,30)+eq(n\,60)' -vsync 0 -frames:v 2 capture/f_%d.png
```

## Results

- **Sim:** `make sim` TB_PASS (hsync period 1056 and width 128, vsync period
  1056x628 and width 4 lines, exactly 800x600 DE per frame, bars, ramp and
  border match, box moves every frame, 3 frames). `make sim-tmds` TB_PASS
  (32617 data words, 4145 control words, disparity within -8..+8).
- **Build (Vivado 2019.1):** `clk_fpga_0` WNS +7.401 ns, WHS +0.040 ns;
  `pix_unbuf` (25.000 ns, 40 MHz) WNS +17.687 ns, WHS +0.122 ns; `ser_unbuf`
  (5.000 ns) WPWS +2.845 ns; no failing endpoints. 300 LUT, 287 FF, 0 BRAM,
  2 DSP, 8 OSERDESE2, 4 OBUFDS, 4 BUFG, 1 MMCME2. The clock report shows
  25.000 ns and 5.000 ns periods.
- **PYNQ-Z2 (2026-11-26):** PASS. The 07 holder was stopped first
  (`STOP_SEEN`), 08 loaded via `holder_hdmi_cs150.py`: `OVERLAY_LOADED`,
  FCLK0 100.000 MHz. Overlay left running.
  - The dongle (`/dev/video2`) lists YUYV and MJPG at 640x480, 720x480,
    720x576, **800x600**, 1024x768, 1280x720, ... at 60/50/30/20/10 fps. It has
    no DV-timings ioctl and does not report the source mode, so a 800x600
    capture is "native" only by the size asked for; the picture was
    pixel-for-pixel 800x600 sized as expected (no scaling artefacts).
  - 800x600 YUYV @ 60: eight bars in order white, yellow, cyan, green,
    magenta, red, blue, black, 100 px wide, 450 lines high; ramp across the
    bottom 150 lines; 2-px border; 40x40 inverse box in different places in
    different frames. Same dongle quirks as 07 (first frame black, a few LSBs
    of colour error, 1-2 px chroma bleed).
  - A pre-load "no-signal" frame was not taken: the 07 picture was still on
    the connector, and the dongle's first frame is black regardless.

Key saved frames (`capture/`, gitignored):

- `/home/ejr/pynq150/08_hdmi_cs150_mode/capture/cs150_800x600_yuyv_b.png` (best)
- `/home/ejr/pynq150/08_hdmi_cs150_mode/capture/cs150_800x600_yuyv_a.png`
- `/home/ejr/pynq150/08_hdmi_cs150_mode/capture/cs150_800x600_mjpg.png`
- `/home/ejr/pynq150/08_hdmi_cs150_mode/capture/warmup_black_800x600.png`
  (first frame, black)

---

## What a TV or phone photo should show

Plug a monitor or TV into the PYNQ-Z2 **HDMI OUT** port, or take a photo or
video of that screen. The picture is 800x600 (a 4:3 frame; a 16:9 set will
letterbox it or stretch it). Colours are full-range RGB; a TV may crush the
brightest whites and the darkest blacks a little. None of this needs the USB
capture dongle.

After the framebuffer overlay is loaded, send commands from UBU24 with
`python3 host_fb.py --addr 0x<BASE> ...` (BASE is printed by the holder).
The board is left running with colour bars on frame 1.

### Fallback test pattern (`V`, reply `v`)

The stage-1 pattern, generated in the pixel clock with no DDR. Top 450 lines:
eight vertical bars, left to right **white, yellow, cyan, green, magenta, red,
blue, black**, each 100 px wide. Bottom 150 lines: a left-to-right grey ramp
(black on the left, white on the right). A 2-pixel mid-grey border around the
active area, and a 40x40 inverse-colour box that bounces a few pixels per
frame (so a video shows it moving; a still photo just shows it somewhere
inside the bars or the ramp). Send `V` again (reply `V`) to return to the
PixelFeeder framebuffer.

### Frame 0, PixelFeeder local pattern (`S0`)

No DDR reads. A pale-grey (`#F0F0F0`) border along the top line, the bottom
line, and the leftmost 8 pixels of every line; a bright green (`#22FF22`)
strip 4 pixels wide on the far right of every line. Inside that, a colour
ramp: red increases left to right, green top to bottom, blue is the XOR of
those two, so the field looks mottled rather than a smooth RGB fade. After
`S0`, send `S1` to go back to the DDR frame.

### Clear and fills (shown frame, after `A S1`)

The whole 800x600 area is one flat colour, edge to edge, with no border or
OSD.

| Command | What you should see |
|---|---|
| `C` | Black, the screen looks off but the monitor is still in 800x600 (it should not show "no signal"). |
| `F:ff0000` | Solid red. |
| `F:00ff00` | Solid green. |
| `F:0000ff` | Solid blue. |
| `F:ff8000` | Solid orange. |
| `F:rrggbb` | Solid colour with that red, green and blue (each byte is hex). |

### Colour bars (`B`)

Eight vertical bars, left to right: **white, yellow, cyan, green, magenta,
red, blue, black**. Each is 100 px wide (one eighth of 800) and runs the full
800x600 height — unlike the fallback pattern, there is no ramp and no moving
box. The white/yellow edge is at x=100, yellow/cyan at 200, and so on, ending
with a black bar from x=700 to 799.

### Checkerboard (`H`)

A 32x32 pixel checker, white (`#FFFFFF`) and dark grey (`#202020`), starting
with white in the top-left square. 25 squares across, 18.75 down, so the
bottom row is a 24-pixel-tall strip of the same pattern. There is no separate
border.

### Gradient (`G`)

A smooth wash over the whole frame: **red increases left to right**, **green
increases top to bottom**, **blue decreases left to right** (it is the inverse
of red). Corners, if you point at them:

- top-left: blue (no red, no green)
- top-right: red (no green, no blue)
- bottom-left: cyan / aqua (green + blue)
- bottom-right: yellow (red + green)

The mid-point is a muted grey-green.

### Grid (`X`)

Black background. White 1-pixel lines every 64 pixels (at x or y = 0, 64,
128, …, 768), so a 13-by-10 lattice. A **green** 2-pixel crosshair at the
centre (columns 399–400 and rows 299–300). A **red** 2-pixel border on all
four edges (the two outermost rows and columns). Where they meet, the red
border wins over the green crosshair, and the green crosshair wins over the
white grid.

### Underflow slip and resync

With the default gap of 128 the picture stays locked while you draw. To see a
failure: `Q` (auto-resync off, reply `q`) then `P0` and a full-frame draw
such as `G`. The PixelFeeder runs out of pixels mid-frame. From then on the
stream is out of step with the raster: the same pattern is still there, but
**wrapped or torn** — a horizontal and/or vertical cyclic shift, often
looking like the picture has been cut and the right or bottom piece moved to
the left or top, sometimes as if the frame were folded into quadrants. It
stays that way, frame after frame, until you send `Z` (or turn auto-resync
back on with `Q` and wait for another underflow).

`Z` (and auto-resync after an underflow) blanks the picture briefly and may
flash one frame of the frame-0 local pattern, then the correct DDR frame
comes back, aligned. `U` reports a sticky underflow flag (`U1` …) until the
next `U` clears it, and the resync count in that line goes up.

### Frame flip (`T2` / `S2`)

`T2 X` draws the grid into frame 2 while frame 1 is still on the screen, so
you should still see whatever was last drawn on frame 1 (for example the
gradient). Then `S2` switches the display to frame 2 and the grid appears
all at once, with no half-updated frame. `S1` switches back to frame 1, which
is unchanged. Drawing into the frame that is currently shown (`T1` while
`S1`) will instead tear: for about 80 ms you may catch a photo of the new
pattern overwriting the old one from the top down.


```
# host (UBU24), board 192.168.2.99 (xilinx/xilinx; never the XUPV5):
B=~/pynq150/build/hdmi_fb; S=~/pynq150/08_hdmi_cs150_mode
ssh xilinx@192.168.2.99 mkdir -p /home/xilinx/hdmi_fb
scp $B/hdmi_fb.bit $B/hdmi_fb.hwh $S/holder_hdmi_fb.py xilinx@192.168.2.99:/home/xilinx/hdmi_fb/
# board: stop any other holder first (touch .../stop), then
sudo bash -c 'source /etc/profile.d/boardname.sh; source /etc/profile.d/xrt_setup.sh;
  source /etc/profile.d/pynq_venv.sh; cd /home/xilinx/hdmi_fb;
  setsid nohup python3 holder_hdmi_fb.py > holder.log 2>&1 < /dev/null &'
cat /home/xilinx/hdmi_fb/holder.log          # OVERLAY_LOADED PHYS=... BASE=...
# host:
python3 host_fb.py --addr 0x<BASE> A S1 C F:ff0000 B H G X U
echo 1 > /home/xilinx/hdmi_fb/dump           # holder writes frame1.ppm from DDR (decodes the word order)
touch /home/xilinx/hdmi_fb/stop              # free the buffer (the picture stays)
python3 verify_capture.py 08_bars bars       # capture + compare (retries while the dongle is black)
```

## Stage 2 results (2026-11-26, America/Los_Angeles)

- Overlay `hdmi_fb.bit` md5 2baa344a51aa5a42210ba738b398a013 loaded; holder left running; frames in `capture/fb/`.
- Probe at the sink (grid/bars/checker): every edge sampled is where the drawer put it (e.g. bars x=99 white, x=100 yellow;
  checker x=31 dark, x=32 white; grid line only at x=64; border x=0/799 red); `t` = 0x75300 (480000) pixels every frame; pending beats 0.
- Captures verified against the expected patterns (`verify_capture.py`): shift 0 for bars (err 2.1), checker (8.0), gradient (9.7),
  grid (0.4), fills (0 to 3.7; limited-range dongle colour), clear (0.0). Errors are the dongle's YUV conversion.
- DDR contents (holder `dump`, previous build with the same drawer): frame 1 (gradient) and frame 2 (grid) 0 bad pixels of 480000.
- Underflow: none with gap >= 96; every full draw at gap <= 64 underflows once and auto-resync recovers it.
