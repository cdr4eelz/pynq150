# 05_request_controller_test

The cs150 **RequestController**, used unmodified, on the PYNQ-Z2. A small
adapter takes MIG's place and masters AXI4 to DDR via PS7 `S_AXI_HP0`.
A fake **dcache** client drives the RequestController `data_*` port with
the exact `Cache.v` handshake. Single UART characters trigger a 1 MiB
pattern write through that port, then a read-back and compare in the PL,
answered with one character (`P`/`F`).

```
UART -> rc_ddr_test FSM -> dcache_tester (Cache.v handshake)
          -> RequestController (cs150, verbatim; other clients null)
          -> rc_axi_adapter (MIG user-interface semantics, no FIFOs)
          -> AXI4 64-bit -> SmartConnect -> HP0 -> DDR
```

## RequestController source

`rtl/RequestController.v` is a byte-identical copy of
`~/cs150-1245/hardware/src/base_mem/RequestController.v`
(md5 `96ddedbc194d41b4cf2e8e6d23f1e56f`, 334 lines). It is the same file
in every cs150 copy. The proj150 DDR3 variants were **not** used.

Diff versus the original: none.

## Adapter (`rtl/rc_axi_adapter.v`)

It connects to the RequestController master port exactly where the ML505
MIG v3.61 user interface did (via the `mig_caf`/`mig_wdf`/`mig_rdf` FIFOs in
`Memory150.v`). Here everything runs on one clock (FCLK0, 100 MHz), so there
are no clock-crossing FIFOs and no FIFOs at all, only registers:

| RC port | Adapter behaviour (MIG equivalent) |
|---------|------------------------------------|
| `caf_full`, `wdf_full` | "not ready" (`app_af_afull`, `app_wdf_afull`): low when idle or between the two write beats, high while a command is on AXI. |
| `caf_wren`, `caf_cadr = {cmd[2:0], addr[30:0]}` | One command. `000` = write, `001` = read; others set sticky `bad_cmd`. |
| `wdf_wren`, `wdf_mdat = {mask[15:0], data[127:0]}` | Two 128-bit beats per write. Mask is active-high "don't write", so `WSTRB = ~mask`. |
| `rdf_wren`, `rdf_data` | One-cycle pulse per 128-bit beat, two per read (`rd_data_valid`, `rd_data_fifo_out`). No backpressure, like MIG. |
| `rdf_rden` | Ignored. MIG had none, and the waiting client always holds it high. |

- Each command is one AXI INCR burst of 4 × 64 bits (32 bytes). `addr` is in
  8-byte units with `addr[1:0]` forced to 0, so a burst is 32-byte aligned
  and never crosses 4 KB.
- Byte address = `base + {addr[WIN_AW-4:2], 5'b0}`. It wraps inside a
  2^`WIN_AW` (1 MiB) window, so the PL cannot write outside the holder's
  CMA buffer.
- Write beat 0 lands at bytes +0..15 and beat 1 at +16..31. Inside a beat,
  `data[63:0]` is the lower AXI beat.
- Commands run one at a time. A write waits for BRESP before the next
  command is accepted, so a read after a write is always ordered.

Because read data arrives as pulses (as with MIG), the original
RequestController's `serviced_reads` counter (it counts `rdf_wren`) is
exact. No edits are needed.

## Fake dcache (`rtl/dcache_tester.v`)

States WRITE1/WRITE2/FETCH/READ1/READ2 with the same signals as cs150
`Cache.v`:

- `cadr = {cmd, 6'b0, line[22:0], 2'b0}`
- Write `mdat = {16'h0, line[255:128]}`, then `{16'h0, line[127:0]}`
- Read line = `{first beat, second beat}`

Word `k` of line `i` is `v = {i, k[2:0]} ^ {4{seed}}`, inverted when `k`
is odd. In DDR, bytes 0..15 of a line hold words 4..7 and bytes 16..31
hold words 0..3, each little-endian. This is the same beat order the
original cache used.

## UART protocol (115200 8N1, Pmod JA, `/dev/ttyUSB3`)

| Send | Reply | Meaning |
|------|-------|---------|
| `A` a0 a1 a2 a3 | `K` | Base address, little-endian; bits [4:0] forced 0. |
| `W` | `D` / `E` | seed += 1, write 32768 lines (1 MiB) through the dcache port. `E` = AXI error or adapter protocol error. |
| `R` | `P` / `F` | Read all lines through the dcache port and compare in the PL. |
| `G` | `P` / `F` | `W` then `R`. |
| `T` | 44 bytes | `Wxxxxxxxx Rxxxxxxxx Mxxxxxxxx Bxxxxxxxx Sxx\n`: write/read cycles, mismatching lines, first bad line, seed (hex). |
| `W`/`R`/`G` before `A` | `N` | |
| other | `?` | |

LEDs: LD0 heartbeat, LD1 RX toggle, LD2 out of reset, LD3 last result passed.
BTN0 is reset.

## Simulation

```
make sim        # sim16 (512 lines, 16 KiB window) and sim64 (2048 lines, 64 KiB window)
```

The testbench uses Icarus with `../03_axi_ddr_test/sim/axi4_slave_mem.v`.
An AXI monitor checks len, alignment, the window, WSTRB, 4 KB crossings and
WLAST/RLAST, and checks that every read pulse is taken by the waiting
dcache. Tests: `N`/`?` before `A`; `A`, `W` with a DDR byte-layout check,
`R`→`P`, and `T`; corrupted memory → `F` with `T` showing `M=2 B=100`; `G`;
a second, unaligned base address; and RequestController/adapter back to idle.

## Build

```
make overlay    # -> ../build/rc_test/rc_test.{bit,hwh}, util.rpt, timing.rpt
```

The block design matches 04: PS7 HP0 64-bit, SmartConnect with 2 slave
interfaces (this design plus JTAG-to-AXI), FCLK0 at 100 MHz. There is no
program target. Load only through the PYNQ Overlay.

## Run on the PYNQ-Z2

```
# board: copy rc_test.bit, rc_test.hwh, holder_rc_test.py to /home/xilinx/rc_test/
sudo bash -c 'source /etc/profile.d/boardname.sh; source /etc/profile.d/xrt_setup.sh;
  source /etc/profile.d/pynq_venv.sh; cd /home/xilinx/rc_test;
  python3 holder_rc_test.py > holder.log 2>&1 &'
grep BASE /home/xilinx/rc_test/holder.log
# host (UBU24):
python3 host_rc_test.py --addr 0x<BASE> A W R T
echo <seed> > /home/xilinx/rc_test/check     # board: CPU-side check, see holder.log
echo 100 > /home/xilinx/rc_test/corrupt      # board: flip a bit in line 100
python3 host_rc_test.py --expect-fail R T    # expect F, M00000001 B00000064
python3 host_rc_test.py G G G
touch /home/xilinx/rc_test/stop
```

## Results

- **Sim:** sim16 and sim64 both ALL TESTS PASSED.
- **Build:** WNS +0.888 ns, WHS +0.015 ns. 6755 LUT, 9281 FF, 2.5 BRAM.
- **PYNQ-Z2 (2026-11-26):** PASS.
  - `W` 1 MiB in 14.1 ms (74.4 MB/s); `R` in 15.9 ms (66.1 MB/s). One
    32-byte command is in flight at a time, about 43–48 cycles per line.
  - CPU check: PASS.
  - Corrupt line 100 → `F` with `M00000001 B00000064`.
  - `G` repeated → `P`.
