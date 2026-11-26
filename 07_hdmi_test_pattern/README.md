# 07_hdmi_test_pattern

A 640x480 colour-bar test pattern on the PYNQ-Z2 **HDMI OUT** port. No DDR,
no AXI, no UART. It exists to prove the video path (clocks, TMDS encoding,
serializers, pins) before video is merged with the memory subsystem from 05
and 06.

```
PS7 FCLK0 (100 MHz) -> MMCM -> pixel clock 25.156 MHz + serial clock 125.78 MHz (5x)
vga_timing -> test_pattern -> Digilent rgb2dvi
     (3x TMDS_Encoder, 4x OSERDESE2 10:1 master/slave pairs, 4x OBUFDS TMDS_33)
     -> HDMI OUT connector (PL bank 35, no external TMDS driver)
```

The design includes a PS7 (DDR + FIXED_IO only, FCLK0 and its reset exported
to the PL), so the bitstream loads through the PYNQ `Overlay` class. A
PL-only bitstream freezes Linux on this board.

## What you should see

- Eight colour bars, left to right: white, yellow, cyan, green, magenta,
  red, blue, black. They fill the top 360 lines.
- A horizontal grey ramp (black to white) in the bottom 120 lines.
- A 2-pixel mid-grey border around the picture (a monitor with overscan
  may hide it).
- A 32x32 box that bounces around the screen, drawn as the inverse of the
  pixels under it (3 px / 2 px per frame).
- LEDs: LD0 on (MMCM locked), LD1 and LD3 blinking at about 0.75 Hz
  (pixel clock and FCLK0 alive), LD2 on or dim (frame toggle).

## Format and clocking (chosen)

- **640x480 @ 60 Hz** (VESA DMT), negative sync polarity: 800x525 total,
  hsync 96, vsync 2 lines. It is the most widely accepted mode (any monitor
  or capture card) and the lowest TMDS rate (251.6 Mbit/s per lane).
  720p60 was not chosen because of the 371 MHz serial clock on a -1
  speed-grade part and the less certain monitor handling of the fractional
  clock. The timing is parameterized (`vga_timing`) if a later test wants
  720p.
- **Clock source: PS7 `FCLK_CLK0` at 100 MHz** (not the 125 MHz H16
  oscillator), like 03 to 06, so one clock tree and no board-clock pin are
  needed.
- MMCM `MMCME2_ADV`: DIVCLK 4, MULT 40.25 gives VCO 1006.25 MHz; CLKOUT0 /40 =
  25.156 MHz pixel (VESA 25.175, -0.07 %); CLKOUT1 /8 = 125.78 MHz serial
  (5x, DDR so 10 bits per pixel). The frame rate is 59.9 Hz. Vivado derives
  both generated clocks (checked in `timing.rpt`).
- Pixel format into rgb2dvi is `{R, B, G}` (rgb2dvi maps `[23:16]` red,
  `[15:8]` blue, `[7:0]` green, see its VHDL).

## Pins (HDMI OUT, TMDS_33)

| Signal | Pin | Source schematic name |
|--------|-----|-----------------------|
| `hdmi_tx_clk_p` / `_n` | L16 / L17 | IO_L11P/N_T1_SRCC_35 |
| `hdmi_tx_d_p[0]` / `_n[0]` | K17 / K18 | IO_L12P/N_T1_MRCC_35 (blue, HSYNC, VSYNC) |
| `hdmi_tx_d_p[1]` / `_n[1]` | K19 / J19 | IO_L10P/N_T1_AD11P/N_35 (green) |
| `hdmi_tx_d_p[2]` / `_n[2]` | J18 / H18 | IO_L14P/N_T2_AD4P/N_SRCC_35 (red) |

Not used: `hdmi_tx_cec` G15, `hdmi_tx_hpdn` R19, `hdmi_tx_scl` M17,
`hdmi_tx_sda` M18 (left unconstrained and unconnected, as in the AMD/Xilinx
video-series-23 example; the sink is not read, so it works with no EDID).
Also used: BTN0 D19 (extra reset of the MMCM) and LD0 to LD3 R14, P14, N16,
M14, the same as 03 to 06.

Sources, all agree: the TUL PYNQ-Z2 master XDC `PYNQ-Z2_v1.0.xdc` (the
copy in `~ejr/fPROJ/vid_example/pynq-z2_v1.0.xdc`, "##HDMI Tx"),
Xilinx/PYNQ commit a5b7bca (`sdbuild/boot_configs/Pynq-Z2-defconfig/constraints.xdc`),
and the public copies of the TUL master XDC. The Vivado 2019.1 pynq-z2 board
file only lists `hdmi_tx_hpd` (R19) and `hdmi_tx_cec` (G15) as plain pins.
The placed-IO report from the 07 build confirms each pin lands on the
listed package site with TMDS_33.

## Reused code and licences

| What | From | Licence |
|------|------|---------|
| `rtl/vendor/rgb2dvi/*.vhd` (rgb2dvi, TMDS_Encoder, OutputSERDES, ClockGen, SyncAsync, SyncAsyncReset, DVI_Constants) and `rgb2dvi.xdc` | Digilent rgb2dvi v1.4 from `~ejr/fPROJ/vid_example/ip_repo/rgb2dvi/src/` (Xilinx XVES_0023, "Video Series 23: Generate a video output on Pynq-Z2 HDMI out"). Copied **unmodified**, md5 in `MD5SUMS`. | BSD 3-clause (Digilent, header in each file) |
| HDMI pin constraints | TUL PYNQ-Z2 master XDC, via `~ejr/fPROJ/vid_example/pynq-z2_v1.0.xdc` | Board vendor reference file |
| MMCM-plus-rgb2dvi structure (external pixel and 5x clock, `kGenerateSerialClk=false`, active-low reset from lock) | `~ejr/fPROJ/vid_example/minvideo/` block design | n/a (own project) |

`rtl/vga_timing.v`, `rtl/test_pattern.v`, `rtl/hdmi_pattern_top.v`,
`rtl/hdmi_overlay_top.v`, the testbenches and the build script are new.
The originals under `~ejr/fPROJ` were not modified. Nothing in cs150 or
proj150 was touched.

## Simulation

```
make sim        # Icarus: vga_timing + test_pattern
make sim-tmds   # Vivado xsim: Digilent TMDS_Encoder (VHDL, so not Icarus)
```

- `sim/tb_hdmi_pattern.v` runs three frames and checks: hsync period 800
  and width 96, vsync period 420000 clocks and width 2 lines, DE exactly
  640x480 per frame with 640 on every line, the colour of every pixel
  (bars, ramp, border, inverse box), black blanking, the x/80 arithmetic for
  every x, and that the box moves and covers 1024 pixels.
- `sim/tb_tmds_encoder.v` drives the encoder with ramps, random data and
  worst-case constants, decodes each 10-bit word per the DVI spec and
  compares it with the input, checks the four control tokens, and checks
  that the running disparity stays within +-10 during each video run.
- The OSERDES/MMCM top is not simulated; it follows the proven example.

## Build

```
make overlay    # -> ../build/hdmi_pattern/hdmi_pattern.{bit,hwh}, util.rpt, timing.rpt
```

Vivado 2019.1, non-project-style script `build_hdmi.tcl`. bit and hwh share
the basename `hdmi_pattern`. No program target: load only through the PYNQ
Overlay, never over JTAG. Never touch the XUPV5.

## Run on the PYNQ-Z2

Needs an HDMI monitor (or capture device) plugged into the **HDMI OUT**
port (labelled HDMI OUT, not HDMI IN).

```
# host (UBU24):
B=~/pynq150/build/hdmi_pattern; S=~/pynq150/07_hdmi_test_pattern
# copy to the board (password xilinx):
ssh xilinx@192.168.2.99 mkdir -p /home/xilinx/hdmi_pattern
scp $B/hdmi_pattern.bit $B/hdmi_pattern.hwh $S/holder_hdmi.py xilinx@192.168.2.99:/home/xilinx/hdmi_pattern/
# board (as xilinx, sudo password xilinx):
sudo bash -c 'source /etc/profile.d/boardname.sh; source /etc/profile.d/xrt_setup.sh;
  source /etc/profile.d/pynq_venv.sh; cd /home/xilinx/hdmi_pattern;
  python3 holder_hdmi.py > holder.log 2>&1 &'
cat /home/xilinx/hdmi_pattern/holder.log      # OVERLAY_LOADED, FCLK0 100 MHz
touch /home/xilinx/hdmi_pattern/stop          # end the holder (the picture stays)
```

The bitstream stays configured after the holder exits. If the board's Linux
console is also on that monitor, loading this overlay does not change it
(the PYNQ base HDMI is a separate overlay and is replaced). If the monitor
shows nothing but LD0 is on, try BTN0 (re-lock) or another monitor input.

## Results

- **Sim:** `make sim` TB_PASS, `make sim-tmds` TB_PASS (32617 data words, 4145
  control words, disparity within -8..+8).
- **Build (Vivado 2019.1):** WNS +7.401 ns, WHS +0.040 ns, WPWS +3.000 ns;
  no unconstrained or failing endpoints. 306 LUT, 288 FF, 0 BRAM, 8 OSERDESE2,
  4 OBUFDS, 4 BUFG, 1 MMCME2.
- **PYNQ-Z2 (2026-11-26):** PASS, captured on UBU24 through an HDMI-to-USB
  dongle. Overlay left running (`holder_hdmi.py`, FCLK0 100.000 MHz).
  - Device: `/dev/video2`, UVC "USB3 Video: USB3 Video"
    (lsusb `345f:2130` UltraSemi). No DV-timings ioctl; the dongle does not
    report the source mode, only the format you ask it to capture.
  - Native capture at 640x480 YUYV 4:2:2 @ 60 fps matches the FPGA mode.
    Asking for 1920x1080 makes the dongle scale the same picture up.
  - Before the overlay: solid black (no stale image). After load: eight
    colour bars in the correct order (white, yellow, cyan, green, magenta,
    red, blue, black) over the top 360 lines, a left-to-right grey ramp in
    the bottom 120 lines, a 2-pixel grey border, and a 32x32 inverse box.
  - The box moves: about 36 px right and 24 px down in 1.4 s, which is
    3 px and 2 px per frame at 60 Hz. Frames about a second apart, and a
    short 5 fps sequence, are under `capture/` (gitignored).
  - Capture anomalies (dongle, not the FPGA): first frame after opening
    the device is often black, so discard a few; YUYV 4:2:2 chroma bleed
    of 1-2 pixels at bar edges; primaries a few LSBs off (cyan 10,255,255
    and red 244,0,0 rather than exact 0/255); mid-grey border reads as 129
    (and 162 at the four corners) rather than 128. Colour order is not
    swapped.

Key saved frames:

- `/home/ejr/pynq150/07_hdmi_test_pattern/capture/before_nosignal_640x480.png`
- `/home/ejr/pynq150/07_hdmi_test_pattern/capture/frame_t0.png`
- `/home/ejr/pynq150/07_hdmi_test_pattern/capture/frame_t1.png` (about 1.4 s later)
- `/home/ejr/pynq150/07_hdmi_test_pattern/capture/frames_t0_t1_diff.png`
- `/home/ejr/pynq150/07_hdmi_test_pattern/capture/frame_later.png`
