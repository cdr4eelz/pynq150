# 12_mem_harden status (2026-11-27, PST)

Tree: copy of 11_mips_gpu (7a9cecc) + the changes in PLAN.md. Uncommitted. JTAG boot, no Linux.
Final bitstream: build/mem_harden/mem_harden.bit (11:55 PST, adapter head register + CPU floorplan).

## Simulation (with the adapter head register)
- simhz (new in 12: 10's same-line race bench + 10's fb_core on 12's adapter): 3 seeds x 48 tests,
  0 stale; control (12's adapter with the hazard check removed by sed) 13 stale -> race detected.
  SIMHZ_PASS 4/4.
- simsys: TB_PASS (gios boots to "> ", commands OK, 975 chars rx).
- simmix: 20/20 PASSED. simthru: PASSED, disjoint 549 MB/s, same-lines 544 MB/s (unchanged by the
  head register; 11's 1062 disjoint is a tb artifact: its pixf client is unbounded and now wins).
- simprio, worst / mean pixf latency in RC clocks (pixel FIFO covers ~2560):

  | slave latency   | 12 RC                    | 11 RC                    |
  |-----------------|--------------------------|--------------------------|
  | R40/B30         | 31 / 28.3, 291 MB/s      | 31 / 28.5, 284 MB/s      |
  | R20-120/B20-120 | 203 / 107.8, 291 MB/s    | 1832 / 522.8, 223 MB/s   |
  (199 before the head register: +1 axi_clk when the queue is empty.)

## Timing (Erik: floorplan first + adapter register stage, CPU untouched)
| build                                   | clk_fpga_1 50 MHz | clk_fpga_0 100 MHz | WHS    |
|-----------------------------------------|-------------------|--------------------|--------|
| 11 final                                | +0.067            | +1.153             | +0.022 |
| 12 first (Cache mem_en only)            | +0.091            | +0.046             | +0.024 |
| **12 final (head reg + pblock + flow)** | **+1.008**        | **+1.055**         | +0.028 |
pix_unbuf +12.841. All user constraints met. Utilization: 11,485 LUT, 12,717 FF, 42 BRAM, 13 DSP.
Worst 50 MHz path now: D$ data BRAM -> MemBank -> UART ShiftOut (MMIO), 22 levels; the I$-address
paths have more slack. Worst 100 MHz path: adapter hd_tag -> hazard compare -> hd_tag CE.

Floorplan trials (non-project, on 12-first's post-opt checkpoint = old adapter; build/mem_harden_fp):
| variant | pblock | place / over-constraint            | clk_fpga_1 | clk_fpga_0 (old adapter) |
|---------|--------|------------------------------------|------------|--------------------------|
| vA      | none   | ExtraTimingOpt / 0                 | +0.364     | +0.545 |
| vD      | none   | ExtraTimingOpt / 0.5 ns            | +0.650     | +1.086 |
| vE      | none   | ExtraTimingOpt / 0.8 ns            | +0.613     | +0.381 |
| vP1D    | whole CPU+caches in X1Y1 | -             | fails: 66 BRAM > 60 sites | |
| vP2C    | pb2    | ExtraTimingOpt / 0.3 ns            | +0.680     | +0.545 |
| **vP2D**| pb2    | ExtraTimingOpt / 0.5 ns            | **+0.789** | +0.671 |
| vP2E    | pb2    | ExtraTimingOpt / 0.8 ns            | +0.553     | +0.634 |
| vP2X    | pb2    | ExtraPostPlacementOpt / 0.5 ns     | +0.417     | +0.701 |
pb2 = MIPS.core + I$ + D$ in CLOCKREGION_X1Y1, MemBank + COP0 in X1Y1..X1Y2 (constr/pblock_cpu.xdc).
All runs: AggressiveExplore phys_opt / route / post-route phys_opt. vP2D is in build_mem_harden.tcl.

## Board (PYNQ 1234-tulA, /dev/ttyUSB3), final bitstream, logs hwtest/logs/c12_*
| stage                              | result                                         | resync (gs 23:16) |
|------------------------------------|------------------------------------------------|-------------------|
| banner                             | gios [Golt45.3.4]                              | 0                 |
| JTAG loader (fresh boot)           | readback OK, jal -> 00000020 x2, ac408670, dump = hex; 1061 words 453 ms | - |
| icache (UART file load)            | 00000020 x2, same as 11                        | -                 |
| dcache                             | identical to 11 (all checksums)                | -                 |
| pixfeed                            | OK                                             | 0 -> 0            |
| pixfeed_stress                     | identical to 11                                | 0 -> 0            |
| gpu                                | identical to 11                                | 0 -> 0 (11: +1)   |
| gpu_stress 8 rounds                | PASS                                           | 0 -> 0, no fault  |
| gpu_stress 30 rounds               | PASS, pixels OK                                | 0 -> 0 (34 gs)    |
| elip alone (fresh boot)            | PASS 134/134, 0/547 rows                       | 0 -> 0            |
| elipbig                            | PASS 36/36, 0/600 rows                         | 0 -> 0            |
HDMI captures OK: capture/hdmi12b_gpu_stress.png, hdmi12b_elip.png, hdmi12b_elipbig.png.
(The first 12 bitstream's board run, logs b12_*, gave the same results; its elip-after-gpu_stress
miss was the known stale D$ line, not run this time.)

## JTAG loader
- MIPS word i of a 16-byte group sits at ARM offset (3-i)*4, same value (measured with gios sw + xsct mrd).
- 4 KiB: JTAG 0.48 s transfer / 2.3 s end to end vs UART `file` 36.2 s, same checksum.

## Open issues
- CPU caches not coherent with GPU or JTAG writes (cs150 behaviour): load/read only lines not cached.
- simthru disjoint 549 vs 1062 MB/s is a testbench effect (unbounded pixf client).
- simhz reuses 10's tb + fb_core from ../10_rc_50mhz (read-only); 12 depends on 10 being present.
