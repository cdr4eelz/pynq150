# PROMPT_LOG — 07_hdmi_test_pattern

A condensed, AI-readable brief for regenerating this mini-project.

## Goal

A standalone HDMI video test pattern on the PYNQ-Z2 HDMI OUT port. It does
not use DDR (Erik, t235u: "07 will ignore DDR and will be a simple HDMI
video test pattern."). It proves the PL video path before video is merged
with the 05 and 06 memory subsystem.

Origin, Erik:

- t227u: "I'm tempted to get Video output up but let's put that off one or
  two more test cases."
- t235u: "Let's start on 07 while 06 tests run. 07 will ignore DDR and will be
  a simple HDMI video test pattern."
- t236u: "There should be sample projects for pynq HDMI out... Likely already
  buried in ~ejr home dir"
- t237u: "There should be ample video on pynq examples out there too, if needed."

## Context

- Repo `/home/ejr/pynq150`, branch `jtag-axi-ddr-test`. Nothing in this
  folder is committed. 06 is being worked on elsewhere and was not touched.
- Samples found in `~ejr/fPROJ/vid_example/`: `pynq-z2_v1.0.xdc` (TUL master
  XDC), `ip_repo/rgb2dvi/src` (Digilent rgb2dvi 1.4, BSD 3-clause),
  `XVES_0023` (Xilinx video series 23), `minvideo` (PS7 + MMCM + v_tc +
  rgb2dvi block design, with .bit and .hwh from Vivado 2024.2),
  `v24/proj/proj_1` (VTPG + rgb2dvi). `fPROJ/project_HDMI` is a similar
  project. No PYNQ-Z2 HDMI sources were in the PYNQ GitHub repo
  (the board folder is no longer there); the pin list was cross-checked with
  Xilinx/PYNQ commit a5b7bca and public copies of the TUL master XDC.
- Only PS7 designs load safely: a PL-only bitstream freezes Linux. 07
  copies the 01 `build_overlay.tcl` shape (PS7 BD with DDR + FIXED_IO, a
  Verilog overlay top instantiating the PS wrapper), but exports FCLK_CLK0 and
  FCLK_RESET0_N as BD ports for the PL.
- Never touch the XUPV5. Only one agent drives a board at a time.

## Decisions

1. **640x480 @ 60 Hz, 25.156 MHz pixel clock** (MMCM from FCLK0:
   100/4*40.25 = 1006.25 MHz VCO, /40 pixel, /8 serial = 5x). Most
   compatible and slowest TMDS rate.
2. **Reuse Digilent rgb2dvi unmodified** (BSD, proven on this board in the
   sample) instead of writing an encoder and serializer. The sample used
   `kGenerateSerialClk=false`, so 07 supplies its own MMCM (PixelClk and
   SerialClk via BUFG), with rgb2dvi's reset as active-low `aRst_n = locked`.
3. **Own Verilog**: `vga_timing`, `test_pattern` (bars, ramp, border,
   bouncing inverse box), `hdmi_pattern_top` (MMCM, reset sync, LEDs).
4. **rgb2dvi pixel order is `{R, B, G}`** (verified in rgb2dvi.vhd lines
   215-217). The pattern drives it that way.
5. **TMDS encoder is VHDL**, so it is simulated with Vivado xsim
   (`make sim-tmds`); the timing generator and pattern use Icarus.
6. HPD, CEC and DDC pins are not used (no EDID read). Add them in a later
   test if a monitor needs HPD.

## Files

| Path | Purpose |
|------|---------|
| `rtl/vendor/rgb2dvi/` | Unmodified Digilent rgb2dvi VHDL + `rgb2dvi.xdc`, `MD5SUMS`, `SOURCE.txt`. |
| `rtl/vga_timing.v` | Parameterized timing generator (default 640x480, negative syncs), registered outputs, frame tick. |
| `rtl/test_pattern.v` | Colour bars / ramp / border / bouncing box, 1 clock latency. |
| `rtl/hdmi_pattern_top.v` | MMCM + BUFGs, reset sync, timing, pattern, rgb2dvi, LEDs. |
| `rtl/hdmi_overlay_top.v` | Overlay top: PS wrapper (`hdmi_ps_wrapper`) + `hdmi_pattern_top`. |
| `constr/pynq_z2_hdmi.xdc` | HDMI TMDS_33 pins, BTN0, LEDs, config voltage. |
| `build_hdmi.tcl` | Vivado 2019.1 build, writes `../build/hdmi_pattern/hdmi_pattern.{bit,hwh}`. |
| `sim/tb_hdmi_pattern.v` | Icarus self-checking TB (timing + pattern). |
| `sim/tb_tmds_encoder.v` | xsim self-checking TB (TMDS decode and DC balance). |
| `holder_hdmi.py` | Board side: load Overlay, print FCLK0, wait for `stop`. |
| `Makefile` | `sim`, `sim-tmds`, `overlay`, `clean`. No program target. |

## Results

Sim PASS (both). Build: WNS +7.401, WHS +0.040, 306 LUT, 288 FF.

Hardware PASS on 2026-11-26. HDMI OUT into an UltraSemi USB3 Video dongle
on UBU24 (`/dev/video2`, 345f:2130). 640x480 YUYV 4:2:2 @ 60 fps. Bars,
ramp, 2-pixel border and a moving 32x32 inverse box all present and in
the right colour order. Pre-load capture was solid black. Overlay left
running (holder_hdmi.py). Frames in `capture/` (gitignored). Dongle
quirks: first opened frame often black, 1-2 px 4:2:2 bleed, primaries a
few LSBs off, mid-grey reads 129 not 128. Not committed.
