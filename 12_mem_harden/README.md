# 11_mips_gpu: cs150 MIPS150 + GPU on the PYNQ-Z2 (JTAG boot, no Linux)

The cs150 system (MIPS150 CPU with MemBank/BIOS ROM/MMIO/UART, write-through I$/D$, RequestController,
GPU) plus the proj150 PixelFeeder and ElipseEngine, on 10's RC-to-AXI adapter (HP0, fixed base
0x10000000, 256 MiB identity window). CPU/caches/RC/GPU at 50 MHz (FCLK1), AXI at 100 MHz (FCLK0).
The CPU boots gios from ROM and talks on the Pmod UART (115200). See PLAN.md for design and decisions
(cs150 vs proj150 settings), STATUS.md for results.

Board jumper: **JTAG boot** (not SD card). No ARM program; `jtag_boot.tcl` runs ps7_init, loads the
bitstream, runs ps7_post_config.

    make overlay                          # Vivado 2019.1 -> ../build/mips_gpu/mips_gpu.bit
    xsct jtag_boot.tcl                    # PYNQ only (cable filter *1234-tulA*)
    cd hwtest && ./run_stages.sh banner   # also dcache icache pixfeed pixfeed_stress gpu elip elipbig
    python3 hwtest/gios_uart.py gs "pf 1" # any gios commands; refuses the XUPV5 UART
    ./capture_frame.sh capture/x.png      # HDMI capture dongle

    make sim                              # simsys (gios boots to "> ", commands) + simmix + simthru

Notes: `gs` shows the PixelFeeder resync count in bits [23:16] of its status word. The CPU caches are
not coherent with GPU writes (cs150 behaviour): read pixels the CPU had cached before a draw only
after the lines are evicted.
