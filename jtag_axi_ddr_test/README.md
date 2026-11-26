# JTAG-to-AXI DDR test (PYNQ-Z2, HP0)

Quick demo that a PL-side AXI master can read and write PS DDR through the
Zynq S_AXI_HP0 port. Vivado's JTAG to AXI Master is the master, so the
transfers are driven from Vivado hardware-manager Tcl.

## Design (block design `ddrjtag`, built entirely by `build.tcl`)

- ZYNQ7 Processing System 5.5 with the pynq-z2 board preset, S_AXI_HP0 at 64 bits,
  M_AXI_GP0 off, FCLK_CLK0 = 100 MHz
- JTAG to AXI Master 1.2 (AXI4, 32-bit data/address)
  -> AXI SmartConnect 1.0 (1 SI / 1 MI, width conversion) -> S_AXI_HP0
- Processor System Reset on FCLK_RESET0_N; everything clocked by FCLK_CLK0
- Address map: HP0_DDR_LOWOCM at 0x0000_0000, 512 MB
- No custom RTL or XDC: DDR and FIXED_IO come from the board preset.
- Last build: 3,452 LUTs, 5,172 FFs, 2.5 BRAM, 0 DSP; WNS +3.638 ns.

## Files

- `build.tcl`: creates the project, BD, wrapper, bitstream; writes
  `ddrjtag.bit`, `ddrjtag.hwh`, `ddrjtag.ltx` to `build/ddr_jtag_axi/`.
- `holder.py`: runs on the board. Loads the overlay with PYNQ, allocates a
  1024-word CMA buffer (pre-filled 0xDEADBEEF), prints its physical address,
  and checks the pattern from the CPU side when `check` is touched; touch
  `stop` to free the buffer and exit.
- `jtag_ddr.tcl`: opens only the TUL (PYNQ) JTAG target, refuses the XUPV5
  (`00000000000000`), does NOT program the device, loads the `.ltx`, writes
  256 words `0xA5000000 + i` in one INCR burst, reads them back, compares.

## Rebuild and run

1. On UBU24, from the repo root:
   `vivado -mode batch -nojournal -log build/ddrjtag_build.log -source jtag_axi_ddr_test/build.tcl`
2. Copy `build/ddr_jtag_axi/ddrjtag.bit`, `ddrjtag.hwh` and
   `jtag_axi_ddr_test/holder.py` to `/home/xilinx/ddrjtag/` on the board
   (xilinx@192.168.2.99).
3. On the board (PYNQ env needs boardname, XRT and venv sourced):
   `cd ~/ddrjtag && sudo nohup bash -c "source /etc/profile.d/boardname.sh; source /etc/profile.d/xrt_setup.sh; source /etc/profile.d/pynq_venv.sh; exec python3 -u holder.py" > holder.out 2>&1 &`
   then read the physical address from `addr.txt`.
4. On UBU24: `vivado -mode batch -source jtag_axi_ddr_test/jtag_ddr.tcl -tclargs <hexaddr>`
   (hex without 0x, e.g. `16849000`). Expect `JTAG_COMPARE: PASS (256 words)`.
5. On the board: `touch ~/ddrjtag/check` (CPU check in holder.out), then
   `touch ~/ddrjtag/stop` to free the buffer.

Load the bitstream through PYNQ, not over JTAG: programming the PL over JTAG
while Linux runs has frozen the board before. Note Vivado's `-data` lists
the last beat first.

## Result (2026-11-26)

PASS at physical 0x16849000: JTAG read-back 256/256 words match, CPU check
after `invalidate()` 0 mismatches, word 256 untouched (0xDEADBEEF).
