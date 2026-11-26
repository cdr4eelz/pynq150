# 10_rc_50mhz

Derived from `09_cache_slr_test`. This pass only changes the clocks: the
RequestController and its friends (caches, frame_drawer, ScanLineRunner,
PixelFeeder memory side, UART / `fb_core` FSM) run at 50 MHz. The DDR / AXI
side stays at FCLK0 100 MHz. The existing independent-clock `mig_*` FIFOs
cross the two domains.

The second change: 10 runs **without Linux**. The PYNQ-Z2 boots in JTAG boot mode (jumper on
JTAG, not SD card) and is loaded with `jtag_boot.tcl` (ps7_init, fpga, ps7_post_config); the DDR
base is fixed at 0x10000000. See README.md for the flow and the results.

## Clocking

| Clock | Source | Rate | What it drives |
|---|---|---|---|
| `axi_clk` | PS7 FCLK0 | 100 MHz | HP0, SmartConnect, JTAG-to-AXI, adapter AXI side, MMCM input |
| `clk` | PS7 FCLK1 | 50 MHz | RequestController, I/D caches, drawer, SLR, PixelFeeder memory side, UART |
| `pix_clk` / `ser_clk` | MMCM from FCLK0 | 40 / 200 MHz | HDMI (unchanged, still exact 0 ppm) |

FCLK0 stays 100 MHz so the MMCM VCO is still 1000 MHz (×10, CLKIN period
10.000 ns) and the 40.000 MHz pixel clock does not move. Putting the RC on
FCLK1 at 50 MHz is cleaner than dividing FCLK0 in an MMCM or dropping FCLK0
to 50 MHz, which would break that pixel-clock relationship and would also
halve HP0 bandwidth.

The UART baud divisor is `CLK_FREQ/BAUD` in `uart_rx`/`uart_tx`:
50,000,000 / 115,200 = **434**. Actual baud = 50e6/434 = 115,207.37
(+0.0064%, +7.37 baud), the same relative error as the 100 MHz / 868
divisor in 09.

## Adapter change

`rc_axi_fifo_adapter` gains `axi_clk` and `axi_rst`. `mig_caf` and `mig_wdf`
are written on `clk` and read on `axi_clk`; `mig_rdf` is the other way around.
Issue, in-flight tags, and the AXI channels run on `axi_clk`. `idle`, the
sticky error flags and the peak counters are synchronised back to `clk`
(completion counts cross as three +1-per-cycle gray counters, because a write
BRESP, a read RLAST and a dropped bad command can all happen in one AXI
cycle). `clr_err` is toggle-synchronised into `axi_clk`.

## Still from 09 (unchanged behaviour, new clock)

UART commands, 16 MiB window, cache test region at +12 MiB, patch 0001, SLR,
LITTLEWORDIAN=1. `GAP_RESET` is still 128 RC-side cycles; at 50 MHz that is
twice the wall time of 09 (~2.56 µs per line, a full-frame draw around 158 ms).
The host script uses `FCLK = 50e6` so the 'U' cycle count still converts to
milliseconds correctly.

## Next

The other change Erik mentioned, then sim (`make simcore` / `make simhz`) and a
Vivado build into `../build/rc_50mhz/`. No board run and no commit until that
is done.
