# 01_uart_echo

The original **PL-only UART echo** mini-project for the **PYNQ-Z2**
(`xc7z020clg400-1`). These files used to live at the repo root; they were
moved here so `02_uart_buffer_test/` and `03_axi_ddr_test/` can sit beside
it. Run `make sim` or `make bit` from this folder. The UART PHY in
`rtl/uart_rx.v` and `rtl/uart_tx.v` is also reused by those later tests.
It is a standalone design, not a fork or copy of proj150.

The first test is a **UART echo loop** on **Pmod A**, plus a heartbeat LED
and an LED that toggles on each received byte. The UART itself still clocks
from the 125 MHz board oscillator through `clk_wiz_0` (baud divisor 1085).
`make overlay` wraps that existing top in a block design with a **dummy
ZYNQ7 PS** (PYNQ-Z2 board preset, DDR + FIXED_IO, no AXI) so the design can
be loaded from Linux with PYNQ's `Overlay` class without taking the PS down.
A PL-only bitstream (`make bit`) has no `.hwh` and has frozen Linux when
loaded. The onboard USB-UART is wired to the PS, not the PL; this test uses
the Pmod USBUART on JA.

## Layout

```
01_uart_echo/
  Makefile              non-project Vivado + Icarus targets
  README.md
  PROMPT_LOG.md         condensed AI-readable brief
  constr/pynq_z2.xdc    pin and clock constraints
  ip/clk_wiz_0.tcl      clk_wiz 6.0 MMCM (125 MHz in, 125 MHz out)
  rtl/pynq150_top.v     board wrapper: clock, reset, LEDs, UART
  rtl/uart_echo.v       RX-to-TX echo with a one-byte hold register
  rtl/uart_rx.v         hand-written 115200 8N1 receiver
  rtl/uart_tx.v         hand-written 115200 8N1 transmitter
  scripts/*.tcl         ip, synth, impl, bit, timing, build_overlay
  sim/tb_uart_echo.v    Icarus testbench for the echo loop
  build/                Vivado outputs (gitignored)
```

## Pin assignments

Taken from the official TUL **PYNQ-Z2 Master XDC** (`PYNQ-Z2v1.0.xdc`), the
file linked as "Master XDC" on the [TUL PYNQ-Z2 product page](https://www.tulembedded.com/FPGA/ProductsPYNQ-Z2.html).
The same map is in Xilinx/PYNQ commit `a5b7bca` (`constraints.xdc`).

| Signal     | Board pin | Package pin | Notes |
|------------|-----------|-------------|--------|
| `sysclk`   | SYSCLK    | H16         | 125 MHz oscillator, LVCMOS33, period 8.00 ns |
| `btn0`     | BTN0      | D19         | Active-high reset (pressed = 1) |
| `led[0]`   | LD0       | R14         | Heartbeat, about 0.93 Hz |
| `led[1]`   | LD1       | P14         | Toggles on every received byte |
| `led[2]`   | LD2       | N16         | MMCM locked |
| `led[3]`   | LD3       | M14         | Unused, tied low |
| `uart_txd` | JA pin 2  | Y19         | `ja[1]` in the master XDC (`Sch=ja_n[1]`) |
| `uart_rxd` | JA pin 3  | Y16         | `ja[2]` in the master XDC (`Sch=ja_p[2]`) |

### Pmod A UART (Digilent Pmod USBUART)

Plug a [Digilent Pmod USBUART](https://digilent.com/reference/pmod/pmodusbuart/reference-manual)
into **Pmod A**, top row (pins 1–6). From the Rev. A reference manual:

| JA pin | Pmod USBUART J1 | This design | Package pin |
|--------|-----------------|-------------|-------------|
| 1      | ~RTS            | unused      | Y18         |
| 2      | RXD (into the Pmod from the FPGA) | `uart_txd` | Y19 |
| 3      | TXD (out of the Pmod to the FPGA) | `uart_rxd` | Y16 |
| 4      | ~CTS            | unused      | Y17         |
| 5      | GND             | —           | —           |
| 6      | VCC             | —           | —           |

Set jumper JP1 on the Pmod to **LCL** (the PYNQ-Z2 is powered on its own; do
not back-power it from the adapter). RTS/CTS are left unconnected; they are
not required for ordinary terminal use.

Some USB-UART adapters swap TX and RX, and Digilent documents more than one
UART pin convention. If the terminal stays silent, swap `uart_txd` / `uart_rxd`
in `constr/pynq_z2.xdc` and rebuild.

## Clocking and reset

`clk_wiz_0` (FIFO-less Clocking Wizard 6.0, generated from
`ip/clk_wiz_0.tcl`) instantiates an MMCM: 125 MHz board clock in, 125 MHz
out, with an active-high reset and a `locked` output. Logic is held in reset
while BTN0 is held or the MMCM is unlocked. The UART baud divisor is
`125_000_000 / 115200 = 1085`.

## Build

Vivado 2019.1, non-project Makefile + Tcl flow. Default tool path:

```
/tools/Xilinx/Vivado/2019.1/bin/vivado
```

Override with `VIVADO=/other/path/vivado` if needed.

```
make help      # list targets
make sim       # Icarus echo-loop test (no Vivado)
make bit       # PL-only bitstream (no PS) -> build/pynq150.bit
make overlay   # dummy PS7 Overlay        -> build/overlay/uart_echo.bit + .hwh
make timing    # print WNS/WHS from the route checkpoint
make clean
```

`make` / `make all` is `bit` plus `timing`. `make bit` refuses to write the
bitstream if setup or hold slack is negative; pass `TIMING_GATE=0` to
override. Use **`make overlay`** to run this test on a PYNQ that is already
booted into Linux.

There is **no `program` target**. Do not program the Arty or the XUPV5.
Do not `program_hw_devices` on the PYNQ while Linux is running; that has
frozen the board. Load the Overlay from Linux instead.

## Load and test (PYNQ Overlay)

On UBU24, from this folder:

```
make overlay
```

Copy `build/overlay/uart_echo.bit` and `build/overlay/uart_echo.hwh` (same
basename) to the board, for example `/home/xilinx/uart_tests/`. SSH as
`xilinx` (default password `xilinx`). Then on the board, with sudo and the
PYNQ environment:

```
source /etc/profile.d/boardname.sh
source /etc/profile.d/xrt_setup.sh
source /etc/profile.d/pynq_venv.sh
python3 -c "from pynq import Overlay; Overlay('/home/xilinx/uart_tests/uart_echo.bit')"
```

Confirm ping and SSH still work after the load. Then on the host, open the
Pmod USBUART at **115200 8N1**, no flow control (usually `/dev/ttyUSB3`):

```
python3 -m serial.tools.miniterm /dev/ttyUSB3 115200
```

Characters should echo back, and LD1 should toggle on each received byte.
A short string should match exactly. A 1024-byte burst may drop about one
or two bytes (the echo path has only a one-byte hold register). BTN0 holds
the design in reset. LD2 is MMCM locked; LD0 is the heartbeat.

The PL-only `make bit` bitstream has no `.hwh` and is not safe to load
while Linux is running.

## Future work

- A minimal Zynq PS block so the design can boot from SD and use the
  onboard USB-UART (PS UART) instead of, or in addition to, the Pmod.
- Any later port of CS150 / MIPS work onto this board.

## Simulation

`make sim` runs `sim/tb_uart_echo.v` under Icarus Verilog 12 (`iverilog`
/`vvp`). The testbench drives the echo module at 10 MHz (still 115200 8N1)
and checks a short message, corner-case bytes, a back-to-back pair, and the
RX-toggle LED.
