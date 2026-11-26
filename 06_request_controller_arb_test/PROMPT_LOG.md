# PROMPT_LOG — 06_request_controller_arb_test

A condensed, AI-readable brief for regenerating this mini-project.

## Goal

05 plus FIFOs. Run the unmodified cs150 `RequestController` on the PYNQ-Z2
with the same three FIFOs cs150/proj150 put around the DDR controller
(`mig_caf`, `mig_wdf`, `mig_rdf`) in front of an AXI4 master on PS7
`S_AXI_HP0`, so commands, write data and reads overlap and speed up.
Arbitration between several clients comes in later tests (07+), before video.

Origin, Erik:

- t230u: "Should there still be FIFOs between the controller and the AXI
  master? Will that allow things to speed up and overlap a bit?"
- t231u: "Add the FIFOs. Can they just be the same as the cs150 mig_xyz FIFOs?"
- t234u: "It could actually copy the proj150 FIFOs verbatim since they are
  already ported from cs150 ISE"
- Earlier (05): t227u/t228u, a copy of the cs150 RequestController with
  minimal mods, a fake dcache client, UART char -> write/read/compare ->
  one-char answer; "virtually identical" RC, an adapter to master AXI.

## Context

- Repo `/home/ejr/pynq150`, branch `jtag-axi-ddr-test`; 06 starts as a copy
  of 05 (committed as `7fdea86`). 06 is uncommitted.
- Shared, not copied: `../01_uart_echo/rtl/uart_{rx,tx}.v`.
- `rtl/RequestController.v` is byte-identical to
  `~/cs150-1245/hardware/src/base_mem/RequestController.v`
  (md5 `96ddedbc194d41b4cf2e8e6d23f1e56f`). The proj150 RC variant (31-bit
  cadr, caf_backlog, pixf first, rdf_pop) was NOT used.
- FIFOs copied unchanged from `~/proj150` (formerly `proj150-fresh`, master `e6059bf`, read-only):
  `ip/mig_{caf,wdf,rdf}.tcl` and
  `sim/icarus/models/{ip_fifos,fifo_async_fwft_model}.v` -> `ip/`, `sim/models/`.
  sha256: mig_caf.tcl 38915c37..., mig_wdf.tcl 5fb947fb..., mig_rdf.tcl
  d6c64973..., ip_fifos.v df31f55d..., fifo_async_fwft_model.v 4b31d20e....
- cs150's own FIFOs (`hardware/src/core_ip/base_mem/mig_*`, ISE FIFO
  Generator 9.3, Virtex-5, standard mode, 34/144/128 x 1024, `.ngc`) cannot be
  used in Vivado 2019.1; the proj150 ones are the Vivado port (FIFO Generator
  13.2, builtin, FWFT, 31/144/128 x 512).
- cs150 MIG v3.61 (ML505 DDR2): APPDATA 128, BURST_LEN 4, internal FIFO36_72
  write/read data FIFOs and an address FIFO (ddr2_usr_*).
- Clock: PS `FCLK_CLK0` 100 MHz. Load with PYNQ `Overlay` only (sudo + the
  three profile.d sources), never over JTAG. Never touch the XUPV5. Board
  `xilinx@192.168.2.99`; UART is the Pmod USBUART on JA (`/dev/ttyUSB3`).
- This work did not touch the board or any JTAG target.

## Files

| Path | Purpose |
|------|---------|
| `rtl/RequestController.v` | Verbatim cs150 copy (zero diff). |
| `rtl/rc_axi_fifo_adapter.v` | New. Instantiates `mig_caf`/`mig_wdf`/`mig_rdf`, AXI4 engine (multiple outstanding), MIG-style read delivery. |
| `rtl/rc_axi_adapter.v` | 05's register-only adapter. Kept for reference, not in the build (`make simref`). |
| `rtl/dcache_tester.v` | Fake dcache (Cache.v handshake) plus a streaming read mode through the RC `pixf_*` port. |
| `rtl/rc_ddr_test.v` | UART FSM, dcache -> RC -> adapter; new `B`, `O` commands; write time waits for adapter `idle`. |
| `rtl/rc_test_top.v` | BD module-reference wrapper (unchanged except a comment). |
| `ip/mig_{caf,wdf,rdf}.tcl` | proj150 FIFO Generator scripts, unmodified. |
| `sim/models/*.v` | proj150 Icarus FIFO models, unmodified. |
| `sim/axi4_slave_pipe.v` | Pipelined AXI slave (queues, read/B latency, random stalls). |
| `sim/tb_rc_ddr_test.v` | Icarus TB: UART host, AXI monitor, DDR layout, fail injection, overlap and pulse checks. |
| `build_rc_test.tcl` | Vivado 2019.1 BD build; also creates the FIFO IPs from `ip/*.tcl`. Output `../build/rc_arb_test/rc_test.{bit,hwh}`. |
| `Makefile` | `make sim`, `make simref`, `make overlay`, `make clean`. |
| `holder_rc_test.py`, `host_rc_test.py` | Board and host helpers (host knows `B`, `O`). |
| `README.md`, `PROMPT_LOG.md`, `.gitignore` | Docs. |

## Design Decisions

1. **RC byte-identical; FIFOs verbatim from proj150.** The Arty differences
   are handled in `build_rc_test.tcl`: part from `create_project`;
   `generate_synth_checkpoint 0` on the FIFO IPs (module references cannot
   hold OOC IP); the IP scripts' 152/50 MHz clock metadata ignored (both
   clocks are FCLK0). No file copied from proj150 was edited.
2. **Width mismatch:** proj150's `mig_caf` is 31 bits `{cmd-3, addr-28}`; the
   cs150 RC drives 34. The adapter stores `{cadr[33:31], cadr[27:0]}`.
3. **FWFT vs the unmodified RC.** proj150 changed the RC to count pops
   (`rdf_pop`) because FWFT `valid` stays high. Here the adapter outputs
   `rdf_wren = mig_rdf.valid & rdf_rden`, a one-cycle pulse per popped beat,
   i.e. what MIG delivered. A beat waits in the FIFO until its client raises
   `rden`. The TB asserts no pulse occurs without `rden`.
4. **AXI engine.** One caf head at a time. Writes: AW (up to 8 in flight),
   W from `mig_wdf` only for AWs that handshaked, `bready` always 1. Reads:
   AR (up to 8), `rready` always 1, pairs -> `mig_rdf`. No AR while
   `mig_rdf.prog_full` (400/512).
5. **Read/write ordering.** AXI does not order read vs write; MIG did. A
   command of the other direction waits for the current direction to drain
   (BRESP / RLAST). Keeps read-after-write correct; mixed traffic does not
   overlap yet (possible improvement: address-conflict check).
6. **`idle` and write completion.** The tester finishes when the last write
   is in the FIFO, long before it is in DDR, so the write time and the `D`
   reply wait for `idle` (accepted commands == completed). `idle` counts at
   the FIFO input because an entry can still be crossing the async FIFO.
7. **Streaming reads.** The RC keeps only one outstanding read per
   inst/data/gcmd client (`*_req_num` overwritten on each fetch), so a
   dcache cannot pipeline reads. The tester's `B` mode reads through the RC's
   `pixf` read-only port (untracked, receives everything not claimed by
   inst/data/gcmd), requests back to back, compares as lines arrive. Default
   is off, so `R`/`G` behave as in 05.
8. **Sim slave.** `axi4_slave_pipe.v` has queues and latency; the 03
   `axi4_slave_mem.v` handles one transaction at a time and would hide the
   overlap. 40-cycle read and 30-cycle B latency reproduce 05's hardware
   timing in `make simref` (39/48 cycles per line vs 43/48 measured).
9. **Limits.** MAX_WR_OUT = MAX_RD_OUT = 8 (Zynq HP ports accept about 8),
   parameters of the adapter, 4-bit counters (<= 15).
10. **Sticky error flags.** `axi_err` (non-OKAY) and `bad_cmd` (unknown cmd,
    `mig_rdf` overflow). `W` returns `E`; reads give `F`.

## Protocol

UART 115200 8N1.

- `A`+4 LE bytes -> `K` (base, [4:0] forced 0)
- `W` -> `D`/`E` (seed++, write 32768 lines, reply after the last BRESP)
- `R` -> `P`/`F` (read and compare; streaming if `B` is on)
- `G` -> `P`/`F` (W then R)
- `B` -> `B` (streaming now on) / `b` (off)
- `O` -> `Oxx yy\n` peak writes / reads in flight (hex)
- `T` -> 44 bytes `Wxxxxxxxx Rxxxxxxxx Mxxxxxxxx Bxxxxxxxx Sxx\n`
- `W`/`R`/`G` before `A` -> `N`; anything else -> `?`

Pattern: word k of line i is `v = {i[28:0], k[2:0]} ^ {4{seed}}`, `~v` for
odd k.

## Test Plan and Results

1. **Sim** (`make sim`, Icarus): sim16 and sim64 ALL TESTS PASSED. 2048
   lines: write 5.4 cycles/line (588 MB/s), dcache read 53.6 (59 MB/s),
   streaming read 5.9 (537 MB/s), peak 8 W / 8 R in flight. `make simref`
   (05 adapter, same slave): 39.2 / 47.8 / 46.3 cycles per line.
2. **Build** (`make overlay`, Vivado 2019.1, 6 min): WNS +1.134 ns, WHS
   +0.025 ns; 6942 LUT, 9344 FF, 7 BRAM tiles, 0 DSP.
3. **Hardware** (PYNQ-Z2, Overlay, 2026-11-26 ~10:30 AM PT): PASS.
   BASE 0x16900100.
   - `A W R T` → `K D P`, T `W0002A022 R001DC5D1 M0 B0 S01`.
     Write 172066 cycles = 609.4 MB/s (5.3 cyc/line); dcache read
     1951185 cycles = 53.7 MB/s (59.5 cyc/line). `O` after W = `O08 00`,
     after dcache R = `O00 01`.
   - CPU check seed 1: PASS. Corrupt line 100 → `R`=`F`, T `M1 B64`.
   - `G` ×3 → `P` (seeds 2-4). `B`, streaming `R` → `P`, 198570 cycles =
     528.1 MB/s (6.1 cyc/line), `O00 08`. Streaming corrupt → `F` `M1 B64`.
     `G` (streaming) → `P` seed 5, 529.1 MB/s, `O08 08`. `B` off, `G` →
     `P` seed 6, dcache 53.7 MB/s. CPU check seed 6: PASS. Holder freed.
   - vs 05 hardware 74.4 / 66.1 MB/s; vs sim 588 / 59 / 537 MB/s.
   - Limits left in place: direction barrier, 8 outstanding, async FIFOs
     on one clock. A faster AXI clock is a later optimization.

## Open Items

- Commit when Erik asks (separate commits per logical change).
- Arbitration with several fake clients; later: address-conflict check,
  common-clock FIFO, faster AXI clock on FCLK1.
