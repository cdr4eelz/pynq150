# PROMPT_LOG — 08_hdmi_cs150_mode

A condensed, AI-readable brief for regenerating this mini-project.

## Goal

An HDMI video test pattern at the same video specs as proj150 and cs150.
Erik, t246u: "Bring master up to date. Let's start work on 08 now. Can we
generate a video test pattern at the same video specs as proj150 and cs150?"
Builds directly on 07 (committed 516cd4e).

## Context

- Repo `/home/ejr/pynq150`, branch `jtag-axi-ddr-test`. 08 is uncommitted.
- cs150 (`~/cs150-1245`, ISE, XUPV5 DVI via CH7301) and proj150 (`~/proj150`)
  were read only. Both use VESA 800x600@60, 40.000 MHz, 1056x628 total,
  H porches 40/128/88, V porches 1/4/23, positive syncs, 24-bit RGB. Sources
  and line numbers are in README.md. Active size in cs150 `PixelCounter` is
  total minus porches (Width/Height are totals).
- XUPV5 not touched. PYNQ only. Only one agent drives the board.

## Decisions

- Copy 07 and keep the vendored Digilent rgb2dvi unmodified.
- Clock is exact from FCLK0: VCO 1000 MHz, /25 pixel (40 MHz), /5 serial
  (200 MHz). 0 ppm. 400 Mbit/s per lane is far below the -1 OSERDES limit, so
  the mode did not need changing.
- Positive syncs, as in both repos and VESA nominal. The CH7301 sync-control
  comment in cs150 `DVIInitial.v:142-143` is ambiguous; noted in README.
- Parameterized `test_pattern.v` (H_ACT, V_ACT, BAR_H, BOX, steps and the bar
  and ramp multiplier/shift constants) rather than hard-coding 800x600.
  Bar index `(x*41)>>12`, ramp `(x*327)>>10`, verified for every x in the TB.
- Pattern scaled: 8 bars x 100 px over 450 lines, ramp 150 lines, 2-px
  border, 40x40 inverse box at 4/3 px per frame.

## Work log

1. Read cs150 and proj150 sources, cited in README.
2. Copied 07 to `08_hdmi_cs150_mode`, renamed modules and files, retargeted
   timing, MMCM and pattern, rewrote the testbench for 800x600 positive syncs.
3. `make sim` TB_PASS, `make sim-tmds` TB_PASS, `make overlay` built
   (WNS +7.401 ns on clk_fpga_0, +17.687 ns on the 40 MHz pixel clock).
4. Hardware: stopped the 07 holder, copied to `/home/xilinx/hdmi_cs150/`,
   loaded under sudo with the three profile scripts, FCLK0 100.000 MHz.
   Captured 800x600 YUYV@60 from `/dev/video2`. Overlay left running.

## Next

- Use this timing (and `PixelCounter`/`VGAFramer` values) when video is merged
  with the 05/06 memory subsystem (framebuffer over AXI DDR).

---

# Stage 2: PixelFeeder framebuffer (2026-11-26)

User (verbatim): "We're not done with 08 yet. Copy PixelFeeder and its FIFO from proj150 but have it feed the HDMI output. This should add PixelFeeder functionality as another consistent client of the RequestController. Pick a memory location for it to feed a frame from continuously, then have the UART state machine write various things to the frame. Perhaps a "fill/clear" that fills it with a single color... and some other chars that write some other patterns."

## Decisions

- RequestController, adapter, mig FIFOs, UART from 06/01 unchanged. PixelFeeder.v, gpcommands.vh, pixel_fifo.tcl copied verbatim
  from proj150 (it differs from cs150's: 16-bit address units, prog_full flow control, local frame 0); a wrapper
  (`pixel_feeder_rc.v`) shifts the address `>>2` and adds a resync sequencer. No edits to the copied files.
- Frames at BASE + N x 4 MiB (proj150 layout), 4096 B stride, inside a 12 MiB holder buffer; frame 1 displayed, 2 for double buffering.
- The drawer uses the dcache port (write-only); PixelFeeder is pixf. Underflow detection in the sink + sticky flag + auto-resync (Q toggles).
- Default write gap 128 clocks (measured: gaps <= 64 starve PixelFeeder for longer than its FIFO covers).
- Test pattern kept as fallback (`V`). `R` probe added to separate pixel-stream errors from capture-dongle artifacts.

## Work log

1. `make sim` (64x16 raster, pipelined AXI model): TB_PASS, then probe command added (also in the TB).
2. `make overlay`: WNS +1.477 ns, 7682 LUT, 10088 FF, 9 BRAM, 11 DSP.
3. Hardware: stopped the pattern holder, loaded `hdmi_fb`, ran clear, fills, bars, checker, gradient, grid, gap sweep, auto-resync off,
   double buffer; captured 800x600 frames from /dev/video2.
4. Early captures looked shifted by 16-22 px. A bug found on the way: the probe's reply buffer was one array too small (fixed, sim now
   checks all 29 characters). The probe showed the pixel stream exact; re-captures with the dongle awake show shift 0.
   Dongle goes black until a source change (`V V` / `Z`); `verify_capture.py` retries.
5. Left running: bars on frame 1 via PixelFeeder. Temporary SSH_ASKPASS script deleted. Nothing committed.
