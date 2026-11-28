# 12_mem_harden: 11's cs150 MIPS150 + GPU system, hardened (JTAG boot, no Linux)

Same system as 11_mips_gpu (cs150 MIPS150 CPU, write-through I$/D$, RequestController, GPU, proj150
PixelFeeder/ElipseEngine on 10's RC-to-AXI adapter; CPU/RC/GPU 50 MHz FCLK1, AXI 100 MHz FCLK0) with:

1. **PixelFeeder read priority** (from proj150): the RC serves pixf reads first, and the adapter's
   command FIFO `prog_full` (`caf_backlog`) holds back CPU/GPU requests so a pixf request always
   finds room. Goal: no PixelFeeder restarts (gs bits 23:16 stay 00) under GPU + CPU load.
2. **Timing margin** without touching the CPU: the D$/I$ BRAM enables no longer depend on the CPU's
   load decode, the adapter registers its command head before the hazard check (100 MHz), and a CPU +
   cache pblock with a timing-driven implementation flow (constr/) closes 50 MHz with margin.
3. **JTAG DDR loader**: `jtag_load.tcl` writes MIPS images into DDR through the PS (with the cs150
   16-byte word order); `hwtest/jtag_run.py` loads and runs them with gios `jal`.

Board jumper: **JTAG boot** (not SD card). No ARM program; `jtag_boot.tcl` runs ps7_init, loads the
bitstream, runs ps7_post_config. PYNQ cable only (`*1234-tulA*`); never the XUPV5.

    make overlay                          # Vivado 2019.1 -> ../build/mem_harden/mem_harden.bit
    xsct jtag_boot.tcl                    # boot the PYNQ (gios prompt on the Pmod UART, 115200)
    cd hwtest && ./run_stages.sh banner   # also dcache icache pixfeed pixfeed_stress gpu gpu_stress elip elipbig
    python3 hwtest/gs_check.py hwtest/logs/*.log   # PixelFeeder resync count / fault per stage
    python3 hwtest/gios_uart.py gs "pf 1" # any gios commands; refuses the XUPV5 UART
    ./capture_frame.sh capture/x.png      # HDMI capture dongle

    # JTAG load + run (instead of the 115200 UART `file` load)
    xsct jtag_load.tcl 10e00000 hwtest/data4k.hex [ADDR HEX ...]
    hwtest/jtag_run.py [--boot] --load 10030000 hwtest/icache_prog.hex \
        --pre "sw 0 10020000" --jal 10030000 --post "lw 10020000"

    make sim        # simsys (gios boots to "> ") + simmix + simthru
    make simhz      # same-line race test on the adapter (3 seeds) + check-removed control
    make simprio    # PixelFeeder read latency, 12 RC vs 11 RC (sim/ref), into sim/prio.log

Loader notes: images are one 8-hex-digit word per line (gios `file` format). The ARM sees MIPS word i
of each 16-byte group at offset (3-i)*4 with the same value; jtag_load.tcl writes in that order,
read-modify-writes partial groups and reads every group back. The MIPS caches are not snooped: load
into lines the CPU has not touched since boot (`jtag_run.py --boot` reboots first). Use CPU address
0x1xxxxxxx for `jal` (I$ fetch); JTAG writes go to DDR so no 0x3 (I$+D$) alias is needed.

Notes: the CPU caches are not coherent with GPU writes (cs150 behaviour). See PLAN.md and STATUS.md.
