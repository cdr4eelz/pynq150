#!/usr/bin/env python3
"""Host-side helper (run on UBU24).

Sends a 4-byte little-endian physical address and 256 data bytes to the
Pmod USBUART (default /dev/ttyUSB3) at 115200 8N1, then prints the DUT
report line (PASS 0x000 0x00 / FAIL 0xMMM 0xII).

Example:
    python3 host_uart_axi.py --addr 0x16849000 --port /dev/ttyUSB3

Does not program the board or use JTAG. Requires the overlay already
loaded and a buffer held by holder_uart_axi.py.
"""
import argparse
import os
import sys
import termios
import time


def open_serial(path, baud=115200):
    fd = os.open(path, os.O_RDWR | os.O_NOCTTY)
    t = termios.tcgetattr(fd)
    iflag, oflag, cflag, lflag, ispeed, ospeed, cc = t
    baud_map = {115200: termios.B115200}
    speed = baud_map[baud]
    iflag = 0
    oflag = 0
    lflag = 0
    cflag = (termios.CS8 | termios.CREAD | termios.CLOCAL)
    cc[termios.VMIN] = 0
    cc[termios.VTIME] = 1  # 0.1 s
    termios.tcsetattr(fd, termios.TCSANOW, [iflag, oflag, cflag, lflag, speed, speed, cc])
    termios.tcflush(fd, termios.TCIOFLUSH)
    return fd


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--addr", required=True, help="physical DDR address (hex, 8-byte aligned)")
    ap.add_argument("--port", default="/dev/ttyUSB3")
    ap.add_argument("--salt", type=int, default=0, help="pattern salt: (i*7+3+salt) & 0xFF")
    args = ap.parse_args()
    addr = int(args.addr, 0)
    if addr & 7:
        print("warning: address is not 8-byte aligned; DUT ignores bits [2:0]", file=sys.stderr)
    payload = bytes([(i * 7 + 3 + args.salt) & 0xFF for i in range(256)])
    frame = addr.to_bytes(4, "little") + payload

    fd = open_serial(args.port)
    try:
        os.write(fd, frame)
        # 260 bytes at 115200 plus AXI plus a 16-byte report: well under 1 s
        deadline = time.time() + 2.0
        buf = b""
        while time.time() < deadline and b"\n" not in buf:
            chunk = os.read(fd, 64)
            if chunk:
                buf += chunk
        sys.stdout.write(buf.decode("ascii", errors="replace"))
        if b"\n" not in buf:
            print("ERROR: no report line from DUT", file=sys.stderr)
            sys.exit(1)
    finally:
        os.close(fd)


if __name__ == "__main__":
    main()
