# 12_mem_harden plan

Base: 11_mips_gpu (commit 7a9cecc); its PLAN.md has the system design and the cs150-vs-proj150
choices. 12 changes only the memory path, timing and tooling. JTAG boot (no SD card, no Linux).

## 1. PixelFeeder read priority (proj150 port)
Problem in 11: the RC served inst > data > gcmd > pixf, and every client could fill the adapter's
command FIFO (mig_caf). Under GPU fills + CPU traffic a pixf line read waited behind long write runs;
the PixelFeeder line FIFO underran and restarted (gs resync count 0 -> 5 over 11's board stages).
Change (as proj150 RequestController/top): pixf first in the RC priority chain; the adapter's
mig_caf `prog_full` (>= 24 entries) is exported as `caf_backlog`, and while it is high only pixf may
issue (`gate_full = ff_full || (caf_backlog && sel_caf_wren)`), so a pixf request always has room.
Checks: `make simprio` (pixf latency under a write stream + hostile slave, 12 RC vs 11 RC),
simmix/simthru (no data errors), board gpu_stress + pixfeed_stress with gs_check.py (resync +0).

## 2. Timing margin (target 50 MHz WNS >= +0.5 ns; 11: +0.067)
11's worst path ended at the D$ tag/data BRAM enables: D$ BRAM DOB -> MemShift -> forward -> ALU ->
DMEM_ADDR -> write mask -> dcache_re -> BRAM ENARDEN. Cache.v enabled its BRAMs only when needed
(`(ns == IDLE) || data_we || re`). The BRAM read result is only used in IDLE / for the hit compare,
the CPU holds its address through a stall, and refills write through data_we, so the BRAMs can be
always enabled (`mem_en = 1`): the enable leaves the critical path; addresses still come from the CPU.
If MMIO decode paths (Random32 seed load) are then worst, register them (one-cycle delay is harmless).

### 2b. Timing closure without CPU changes (Erik: floorplan first, plus the adapter stage)
The first 12 build reached only +0.09 ns at 50 MHz (new worst path: D$ data -> MemShift -> forward ->
BranchCMP -> next-PC -> I$ BRAM address, the 3-stage pipeline's load -> branch forward) and +0.05 ns at
100 MHz (adapter caf DO -> hazard compare -> tag CE). The CPU is left alone (no load-use branch stall).
- 100 MHz: rc_axi_fifo_adapter registers mig_caf's head (hd_v/cmd/tag/blk) before the hazard check
  and AW/AR issue. Same check against the live in-flight tags; +1 axi_clk only when the queue was
  empty. Checked with simhz (10's same-line race bench on 12's adapter + a check-removed control),
  simmix, simthru, simprio, simsys.
- 50 MHz: pblocks (constr/pblock_cpu.xdc) put MIPS.core + I$ + D$ in clock region X1Y1 and MemBank +
  COP0 in X1Y1..X1Y2; ExtraTimingOpt placement under a 0.5 ns clk_fpga_1 over-constraint (removed
  before route), AggressiveExplore phys_opt/route/post-route phys_opt. Chosen from non-project trials
  on the post-opt checkpoint (build/mem_harden_fp, see STATUS.md).

## 3. JTAG DDR loader
`jtag_load.tcl ADDR HEX ...`: xsct on the APU target of cable 1234-tulA, `mwr -force` per 16-byte
group in ARM order (MIPS word i at offset (3-i)*4, measured with gios sw + xsct mrd), partial groups
read-modify-written, readback compare. `hwtest/jtag_run.py` = optional jtag_boot, load, gios `jal`.
Verified against the UART `file` load (same checksum / same program result).

## Commit split (proposed)
1. Copy 11_mips_gpu -> 12_mem_harden unchanged (scaffold)
2. RC pixf priority + caf_backlog (RequestController, adapter port, sys_core, tb_adapter_mixed MODE 3,
   sim/ref/RequestController_11.v, Makefile simprio)
3. Cache BRAM enable timing fix (Cache.v mem_en) + build_mem_harden.tcl rename / jtag_boot default
4. Adapter command head register (rc_axi_fifo_adapter.v) + Makefile simhz
5. CPU floorplan + timing-driven impl flow (constr/pblock_cpu.xdc, constr/impl_place_pre.tcl,
   constr/impl_physopt_post.tcl, build_mem_harden.tcl strategy block)
6. JTAG loader (jtag_load.tcl, hwtest/jtag_run.py)
7. gpu_stress stage + gs_check.py
8. 12 docs (README, PLAN, STATUS, Makefile header)
