# 11_mips_gpu status (uncommitted). Times PST, 2026-11-26.

## Done
- Tree built from 10 + cs150 sources (rtl/cs150, proj150 ElipseEngine) + proj150 BRAM/uarx IP tcl + sw/*.coe.
- rtl/sys_core.v (MIPS150 + I$/D$ + cs150 RC + GPU + PixelFeeder + 10 adapter, WIN_AW=28, BASE 0x10000000,
  staged resets), rtl/mips_gpu_top.v, build_mips_gpu.tcl, Makefile (simsys/simmix/simthru), sim/tb_sys.v.
- Sim: simsys TB_PASS (gios banner [Golt45.3.4], prompt, lw/sw/sb, gs, gf/hwcolor/hwline + DDR readback).
  +pf run TB_PASS (PixelFeeder 3+ frames, no underflow). simmix 20/20, simthru 1062/353 MB/s (= 10).
- Fix: pixel_feeder_rc replays the CPU's PF_FRAME after an underflow resync (board showed PF#00 after
  GPU fill); resync count in pf_status[7:0] (gs bits 23:16). Sim pixel_fifo model: 16-clk rst_busy.
- Build (final, impl_1 with Performance_ExplorePostRoutePhysOpt, 16:25): WNS +0.067 ns (FCLK1 50 MHz),
  FCLK0 +1.153, pix +14.292; WHS +0.022; 11,466 LUTs (21.6%), 12,661 FF, 42 BRAM tiles, 13 DSP.
  (First build, default strategy: WNS -0.304 on FCLK1, D$-hit loop. impl_2 = same RTL as first build
  re-implemented with the new strategy: +0.324; used only for the elip board run before the fix.)
- Board (JTAG boot, 1234-tulA, final bit): banner [Golt45.3.4] at boot; dcache/icache/pixfeed/
  pixfeed_stress/gpu all as expected (checksums = image XOR d2e8c4ab / ac408670); elipbig PASS;
  elip FAIL 2/134 when run after gpu (stale D$ lines, GPU not coherent) -> rerun alone PASS 134/134,
  0/547 rows. HDMI captures OK (capture/hdmi_gpu_v1.png, hdmi_elip_final.png, hdmi_gpu_final.png).
  Resync count reached 05 over the session (underflows under heavy GPU fill; frame kept each time).

- simsys final (16:50): TB_PASS, 975 chars; PF_FRAME kept across a forced resync, no follow-on underflow.

## In progress
- Nothing running from this task. Board left on the final bitstream showing GPU frame 2.

## Open
- caf_backlog backport for the occasional underflows; thin FCLK1 slack; D$/GPU non-coherence (cs150).
