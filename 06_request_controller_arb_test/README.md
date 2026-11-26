# 06_request_controller_arb_test

The cs150 **RequestController**, used unmodified, on the PYNQ-Z2, with the
**proj150 `mig_caf` / `mig_wdf` / `mig_rdf` FIFOs** between it and an AXI4
master on PS7 `S_AXI_HP0`. It is a copy of 05 plus those FIFOs, so commands,
write data and reads overlap on AXI instead of running one at a time.
A fake **dcache** client drives the RequestController `data_*` port with
the exact `Cache.v` handshake. Single UART characters trigger a 1 MiB
pattern write through that port, then a read-back and compare in the PL,
answered with one character (`P`/`F`). A second read mode (`B`) streams
reads back to back through the RequestController's read-only `pixf_*` port.

```
UART -> rc_ddr_test FSM -> dcache_tester (Cache.v handshake; pixf port for streaming reads)
          -> RequestController (cs150, verbatim; other clients null)
          -> rc_axi_fifo_adapter:
               mig_caf (31b) + mig_wdf (144b) -> AXI engine (AW/W/B, AR) -> mig_rdf (128b) -> RC
          -> AXI4 64-bit -> SmartConnect -> HP0 -> DDR
```

**Status:** sim and hardware both PASS (2026-11-26). Nothing is committed.

## RequestController source

`rtl/RequestController.v` is a byte-identical copy of
`~/cs150-1245/hardware/src/base_mem/RequestController.v`
(md5 `96ddedbc194d41b4cf2e8e6d23f1e56f`, 334 lines). It is the same file
in every cs150 copy. The proj150 DDR3 variants were **not** used.

Diff versus the original: none.

## FIFOs (copied unchanged from proj150)

The FIFOs are the proj150 (Arty A7) FIFO Generator 13.2 IPs, which were
ported from cs150's ISE CoreGen `mig_caf/wdf/rdf`. Copied byte-for-byte from
`~/proj150` (formerly `proj150-fresh`, master `e6059bf`; read-only):

| 06 file | proj150 file |
|---------|--------------|
| `ip/mig_caf.tcl`, `ip/mig_wdf.tcl`, `ip/mig_rdf.tcl` | `ip/mig_{caf,wdf,rdf}.tcl` |
| `sim/models/ip_fifos.v`, `sim/models/fifo_async_fwft_model.v` | `sim/icarus/models/` (Icarus stand-ins) |

| FIFO | width x depth | notes |
|------|---------------|-------|
| `mig_caf` | 31 x 512 `{cmd[2:0], addr[27:0]}` | `prog_full` at 24 (`caf_backlog`) |
| `mig_wdf` | 144 x 512 `{mask[15:0], data[127:0]}` | |
| `mig_rdf` | 128 x 512 | `prog_full` at 400 (read credit) |

All three: independent clocks, builtin FIFO36/18, first-word-fall-through
with a valid flag, async reset, `Use_Dout_Reset` off. (cs150's originals
were ISE FIFO Generator 9.3, Virtex-5, standard-mode FIFOs 34/144/128 x 1024;
the `.ngc` netlists cannot be used in Vivado.)

Arty-specific things handled in `build_rc_test.tcl`, not by editing the
files: the part comes from `create_project` (xc7z020; the scripts name no
part); the FIFOs are built with `generate_synth_checkpoint 0` because a BD
module reference may not contain OOC IP; their 152/50 MHz
`READ/WRITE_CLK.FREQ_HZ` only affect the IP's own OOC constraints (here both
clocks are FCLK0, 100 MHz).

## Adapter (`rtl/rc_axi_fifo_adapter.v`)

It sits where `Memory150.v` had the three FIFOs and MIG. The older
register-only adapter from 05 is kept as `rtl/rc_axi_adapter.v` for
reference; it is no longer in the build (`make simref` can still run it).

| RC port | Adapter behaviour |
|---------|-------------------|
| `caf_wren`, `caf_cadr[33:0]` | Written to `mig_caf` as `{cmd, addr[27:0]}`; `caf_cadr[30:28]` is dropped (`cadr` addresses are 8-byte units; the window wraps anyway). |
| `caf_full`, `wdf_full` | `mig_caf.full`, `mig_wdf.full`. |
| `wdf_wren`, `wdf_mdat` | Written to `mig_wdf`. |
| `rdf_data` | `mig_rdf.dout`. |
| `rdf_wren` | `mig_rdf.valid & rdf_rden`: a one-cycle pulse exactly when a beat is popped (see below). |
| `rdf_rden` | `mig_rdf.rd_en`. A beat stays in the FIFO until its client raises `rden`. |
| `caf_backlog` | `mig_caf.prog_full` is left unconnected; cs150's RC has no such input. |

**Why `rdf_wren` is a pop pulse.** The cs150 RC counts every cycle
`rdf_wren` is high as one serviced read. cs150's standard-mode FIFOs produced
one `valid` pulse per read-enable. The proj150 FIFOs are FWFT: `valid` stays
high while a beat sits in the FIFO, which is why proj150 had to change the RC
(`rdf_pop = rdf_wren && rdf_rden`). Here the same gating is done in the
adapter, so the RC stays byte-identical.

AXI side (single ID, every burst is INCR 4 x 64 bit = one 32-byte block,
base + `{addr[WIN_AW-4:2], 5'b0}` inside a 2^`WIN_AW` window):

- Commands leave `mig_caf` in order: `000` = write (AW), `001` = read (AR),
  anything else sets sticky `bad_cmd` and is dropped.
- Up to `MAX_WR_OUT` (8) writes and `MAX_RD_OUT` (8) reads in flight. AW, W
  and B, and AR and R, are independent channels, so they overlap. Zynq HP
  ports accept at most about 8 outstanding of each.
- W beats come from `mig_wdf` (two entries per burst, two 64-bit beats per
  entry, lower first, `WSTRB = ~mask`) and start only for AWs that already
  handshaked.
- R: `rready` is always 1 (MIG has no back-pressure). Beat pairs are written
  to `mig_rdf`. No AR is issued while `mig_rdf.prog_full` (400 of 512) is
  high, so it cannot overflow (an overflow would set `bad_cmd`).
- **Ordering:** MIG runs commands in order; AXI does not order reads against
  writes. A command of the other direction therefore waits until all
  in-flight commands of the current direction have completed (B / RLAST).
  Same-direction streams overlap fully; read/write mixes do not overlap yet.
- `idle` = every command accepted from the RC has completed. The tester's
  write time, and the `D` reply, wait for it: with the FIFOs the tester
  finishes long before the data is in DDR.

## Fake dcache (`rtl/dcache_tester.v`)

States WRITE1/WRITE2/FETCH/READ1/READ2 with the same signals as cs150
`Cache.v`:

- `cadr = {cmd, 6'b0, line[22:0], 2'b0}`
- Write `mdat = {16'h0, line[255:128]}`, then `{16'h0, line[127:0]}`
- Read line = `{first beat, second beat}`

Writes wait only for the FIFO full flags, so they stream. Reads through the
dcache port still wait for each line: the RC tracks **one** outstanding read
per inst/data/gcmd client (`data_req_num` is overwritten at each fetch), so a
single dcache cannot pipeline reads. In streaming mode (`B`) the tester
instead reads through the RC's `pixf_*` port, which the RC does not track:
requests go out back to back, lines come back in order, and each is compared
as it arrives.

Word `k` of line `i` is `v = {i, k[2:0]} ^ {4{seed}}`, inverted when `k`
is odd. In DDR, bytes 0..15 of a line hold words 4..7 and bytes 16..31
hold words 0..3, each little-endian. This is the same beat order the
original cache used.

## UART protocol (115200 8N1, Pmod JA, `/dev/ttyUSB3`)

| Send | Reply | Meaning |
|------|-------|---------|
| `A` a0 a1 a2 a3 | `K` | Base address, little-endian; bits [4:0] forced 0. |
| `W` | `D` / `E` | seed += 1, write 32768 lines (1 MiB) through the dcache port. `E` = AXI error or adapter protocol error. The write time covers the time until the last BRESP. |
| `R` | `P` / `F` | Read all lines (dcache port, one at a time; or `pixf` streaming after `B`) and compare in the PL. |
| `G` | `P` / `F` | `W` then `R`. |
| `B` | `B` / `b` | Toggle streaming reads: `B` = now on, `b` = now off (off after reset, as in 05). |
| `O` | 7 bytes | `Oxx yy\n`: peak AXI writes / reads in flight since the last W/G/R start (hex). |
| `T` | 44 bytes | `Wxxxxxxxx Rxxxxxxxx Mxxxxxxxx Bxxxxxxxx Sxx\n`: write/read cycles, mismatching lines, first bad line, seed (hex). |
| `W`/`R`/`G` before `A` | `N` | |
| other | `?` | |

LEDs: LD0 heartbeat, LD1 RX toggle, LD2 out of reset, LD3 last result passed.
BTN0 is reset.

## Simulation

```
make sim        # sim16 (512 lines, 16 KiB window) and sim64 (2048 lines, 64 KiB window)
make simref     # the same tests on 05's register-only adapter (A/B numbers)
```

Icarus, with the proj150 FIFO stand-ins (`sim/models/`, pointer synchronizers
modelled) and `sim/axi4_slave_pipe.v`: a pipelined AXI slave with a queue of
16 AW/AR, 40-cycle read latency, 30-cycle write-response latency and random
25% ready stalls (like the 05-era slave but able to overlap, which the
03 model cannot). An AXI monitor checks len, alignment, the window, WSTRB,
4 KB crossings and WLAST/RLAST, and checks that every `rdf_wren` pulse is a
pop (`rden` high) taken by the waiting client. Tests: `N`/`?` before `A`;
`W` with a DDR byte-layout check, `R`, `T`; corrupted memory -> `F`
(`M=2 B=100`); `G`; an unaligned second base; adapter and FIFOs back to
idle; then `B` streaming reads (compare, corrupt -> `F`, repaired by `G`),
overlap assertions (more than one AW and AR in flight), `b` and `G` again.

Simulated results, 2048 lines (64 KiB), same slave and 100 MHz:

| | 05 adapter (`simref`) | 06 FIFO adapter |
|---|---|---|
| write | 39.2 cycles/line, 81 MB/s | 5.4 cycles/line, 588 MB/s |
| read, dcache port | 47.8 cycles/line, 66 MB/s | 53.6 cycles/line, 59 MB/s |
| read, streaming (`B`) | 46.3 cycles/line, 69 MB/s | 5.9 cycles/line, 537 MB/s |
| peak in flight (W / R) | 1 / 1 | 8 / 8 |

The sim slave's latency was chosen so the 05 numbers land near the measured
hardware (74 / 66 MB/s); the 06 numbers are limited by 8 outstanding x 4
beats per 40-cycle latency (not by the 4 beats/cycle bus). The dcache-port
read is slightly slower than 05 because the FIFOs add a few cycles per
single-line round trip. Hardware matches this pattern: writes and streaming
reads are a little faster than this slave model, dcache-port reads a little
slower (real HP0 single-outstanding latency is above the model's 40 cycles).

## Build

```
make overlay    # -> ../build/rc_arb_test/rc_test.{bit,hwh}, util.rpt, timing.rpt
```

The block design matches 05: PS7 HP0 64-bit, SmartConnect with 2 slave
interfaces (this design plus JTAG-to-AXI), FCLK0 at 100 MHz. The three FIFO
IPs are created from `ip/*.tcl` inside the same project (about 6 min total).
There is no program target. Load only through the PYNQ Overlay.

## Run on the PYNQ-Z2

```
# board: copy rc_test.bit, rc_test.hwh, holder_rc_test.py to /home/xilinx/rc_arb_test/
sudo bash -c 'source /etc/profile.d/boardname.sh; source /etc/profile.d/xrt_setup.sh;
  source /etc/profile.d/pynq_venv.sh; cd /home/xilinx/rc_arb_test;
  python3 holder_rc_test.py > holder.log 2>&1 &'
grep BASE /home/xilinx/rc_arb_test/holder.log
# host (UBU24):
python3 host_rc_test.py --addr 0x<BASE> A W R T
echo <seed> > /home/xilinx/rc_arb_test/check     # board: CPU-side check, see holder.log
echo 100 > /home/xilinx/rc_arb_test/corrupt      # board: flip a bit in line 100
python3 host_rc_test.py --expect-fail R T    # expect F, M00000001 B00000064
python3 host_rc_test.py G G G
touch /home/xilinx/rc_arb_test/stop
```

## Results

- **Sim:** sim16 and sim64 ALL TESTS PASSED (06 adapter); `make simref` also
  passes the same tests.
- **Build** (Vivado 2019.1): WNS +1.134 ns, WHS +0.025 ns, no failing
  endpoints. 6942 LUT (13.1%), 9344 FF (8.8%), 7 BRAM tiles (4 FIFO36E1 and
  1 FIFO18E1 from the three FIFOs; 05 had 2.5), 0 DSP. Includes PS7,
  SmartConnect and JTAG-to-AXI. 05 was 6755 LUT / 9281 FF.
- **PYNQ-Z2 (2026-11-26, ~10:30 AM PT):** PASS. BASE 0x16900100.
  - `A W R T` → `K D P`, T `W0002A022 R001DC5D1 M0 B0 S01`.
    - Write: 172,066 cycles = 609.4 MB/s, 5.3 cycles per line (05 was
      74.4 MB/s / 43 cycles; sim 588 MB/s / 5.4). About 8.2× 05, 76% of
      the 800 MB/s HP0 peak.
    - Dcache-port read: 1,951,185 cycles = 53.7 MB/s, 59.5 cycles per
      line (05 was 66.1 MB/s / 48 cycles; sim 59 MB/s / 53.6). Slightly
      slower than 05, as expected: one outstanding read plus FIFO latency.
    - `O` after `W`: `O08 00` (8 writes in flight). After dcache `R`:
      `O00 01`.
  - CPU check, seed 1: 32768 lines, 0 bad, sentinels intact.
  - CPU corrupt of line 100 → `R` = `F`, T `M00000001 B00000064`.
  - `G` ×3 → `P` (seeds 2, 3, 4).
  - `B` (streaming on), `R T O` → `P`, T `R000307AA` = 528.1 MB/s,
    6.1 cycles per line (sim 537 MB/s / 5.9). `O` = `O00 08`.
  - Streaming corrupt of line 100 → `F`, T `M00000001 B00000064`.
  - `G` (write + streaming read) → `P`, seed 5, 529.1 MB/s, `O` = `O08 08`.
  - `B` off, `G` → `P`, seed 6, dcache read 53.7 MB/s again.
  - CPU check, seed 6: PASS. Holder then freed; ping and SSH stayed up.
  - Write time was exactly 172066 cycles on every `W`/`G`.

## Open items

- Arbitration between clients is untested: only `data_*` (and `pixf_*` for
  streaming reads) are live. That comes next, with several fake clients.
- Read/write direction barrier, 8 outstanding, and the async FIFOs (both
  clocks on FCLK0) are left as they are; Erik wants those optimizations
  later. A faster AXI clock on FCLK1 can use the same dual-clock FIFOs
  once the controller side keeps the bus fed.
- The RC keeps one outstanding read per cache client, so only the `pixf`
  read-only client (and several different clients together) can have more
  than one read in flight.
- `mig_caf.prog_full` (`caf_backlog`) is not used: cs150's RC has no input
  for it.
- Masked/partial writes (`mask != 0`) are not exercised, because Cache.v
  always writes full lines.
- `caf_cadr[30:28]` (high address bits) are not stored in `mig_caf`.
