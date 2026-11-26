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
- Last build (2026-11-26, from `00_jtag_axi_ddr_test/build.tcl`): 3,452 LUTs,
  5,172 FFs, 2.5 BRAM, 0 DSP; WNS +3.638 ns, WHS +0.020 ns; timing met.

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

## How to run the 00 test

All host commands below are from the repo root on UBU24 (`~/pynq150`).
Vivado is 2019.1 at `/tools/Xilinx/Vivado/2019.1`. The board is
`xilinx@192.168.2.99` (default SSH and sudo password: `xilinx`).

Load the bitstream through PYNQ's Overlay from Linux, **not** over JTAG.

### Safety

- Use only the TUL / PYNQ JTAG target
  `localhost:3121/xilinx_tcf/Xilinx/1234-tulA` (device `xc7z020_1`).
  `jtag_ddr.tcl` aborts if that target is missing and refuses
  `00000000000000` (the XUPV5). Never open or program the XUPV5.
- Do **not** `program_hw_devices`. Programming the PL over JTAG while
  Linux is running has frozen the board and required a power-cycle.
- Vivado's AXI `-data` lists the last beat first.

### 1. Build the bitstream

```
source /tools/Xilinx/Vivado/2019.1/settings64.sh
vivado -mode batch -nojournal -log build/ddrjtag_build.log \
  -source 00_jtag_axi_ddr_test/build.tcl
```

Outputs (gitignored) are `build/ddr_jtag_axi/ddrjtag.bit`,
`ddrjtag.hwh`, and `ddrjtag.ltx`.

### 2. Copy `ddrjtag.bit`, `ddrjtag.hwh`, and `holder.py` to the board

`sshpass` is not used. Create a temporary `SSH_ASKPASS` helper (default
password `xilinx`), and delete it when finished:

```
ASKPASS=$(mktemp /tmp/ssh_askpass.XXXXXX)
printf '%s\n' '#!/bin/sh' "echo 'xilinx'" > "$ASKPASS"
chmod 700 "$ASKPASS"
export SSH_ASKPASS="$ASKPASS" SSH_ASKPASS_REQUIRE=force
export DISPLAY="${DISPLAY:-:0}"
SSH_OPTS="-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no"

# Remove leftovers from a previous run first. A stale `stop` file will
# make holder.py exit immediately. Non-interactive sudo may need
# `sudo -S` and the default board password.
setsid -w ssh $SSH_OPTS xilinx@192.168.2.99 \
  'mkdir -p ~/ddrjtag && sudo rm -f ~/ddrjtag/check ~/ddrjtag/stop ~/ddrjtag/addr.txt ~/ddrjtag/holder.out'

setsid -w scp $SSH_OPTS \
  build/ddr_jtag_axi/ddrjtag.bit \
  build/ddr_jtag_axi/ddrjtag.hwh \
  00_jtag_axi_ddr_test/holder.py \
  xilinx@192.168.2.99:/home/xilinx/ddrjtag/
```

### 3. Load the overlay and allocate a DDR buffer

On the board:

```
cd ~/ddrjtag && sudo nohup bash -c "source /etc/profile.d/boardname.sh; source /etc/profile.d/xrt_setup.sh; source /etc/profile.d/pynq_venv.sh; exec python3 -u holder.py" > holder.out 2>&1 &
```

From a non-interactive SSH session on UBU24, `sudo -S` plus an inner
`nohup` is needed so sudo can read the default board password and the
process survives the SSH logout:

```
setsid -w ssh $SSH_OPTS xilinx@192.168.2.99 \
  'cd ~/ddrjtag && sudo -S bash -c "nohup bash -c \"source /etc/profile.d/boardname.sh; source /etc/profile.d/xrt_setup.sh; source /etc/profile.d/pynq_venv.sh; exec python3 -u holder.py\" > holder.out 2>&1 &"'
```

Wait until `~/ddrjtag/addr.txt` and `holder.out` show the physical
address, for example:

```
OVERLAY_LOADED PHYS=0x16849000
```

Use the hex value without the `0x` prefix in the next step (`16849000`).

### 4. JTAG write / read / compare

```
source /tools/Xilinx/Vivado/2019.1/settings64.sh
vivado -mode batch -nojournal -log build/ddrjtag_jtag.log \
  -source 00_jtag_axi_ddr_test/jtag_ddr.tcl -tclargs 16849000
```

Expect:

```
USING TARGET: localhost:3121/xilinx_tcf/Xilinx/1234-tulA
JTAG_COMPARE: PASS (256 words)
```

### 5. CPU cross-check and cleanup

```
setsid -w ssh $SSH_OPTS xilinx@192.168.2.99 'sudo touch ~/ddrjtag/check'
```

`holder.out` should report something like:

```
CPU_CHECK first=['0xA5000000', '0xA5000001', '0xA5000002', '0xA5000003'] last=0xA50000FF word256=0xDEADBEEF mismatches=0 PASS
```

Then free the buffer:

```
setsid -w ssh $SSH_OPTS xilinx@192.168.2.99 'sudo touch ~/ddrjtag/stop'
```

`holder.out` should end with `FREED`. Confirm the board still answers
ping and SSH. Delete `$ASKPASS` when done.

## Result (2026-11-26)

PASS at physical `0x16849000` from the `00_jtag_axi_ddr_test/` layout.
JTAG read-back 256/256 words match. CPU check after `invalidate()`:
0 mismatches, word 256 untouched (`0xDEADBEEF`). The overlay was loaded
from Linux; the board stayed up (ping and SSH).
