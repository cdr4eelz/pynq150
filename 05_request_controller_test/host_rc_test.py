#!/usr/bin/env python3
"""Host-side driver for 05_request_controller_test (run on UBU24).

Sends single-character commands to the Pmod USBUART (default
/dev/ttyUSB3, 115200 8N1) and prints each reply.

  python3 host_rc_test.py --addr 0x<BASE> A G T
  python3 host_rc_test.py W R T          # base already set

Commands (positional, run in order):
  A  send 'A' + 4-byte LE --addr, expect 'K'
  W  write LINES lines through the dcache port (seed+1), expect 'D'
  R  read + compare through the dcache port, expect 'P' (or 'F')
  G  W then R in one character, expect 'P'
  T  stats line; also prints MB/s and cycles/line at 100 MHz
Exit status is 0 only if every reply was the expected one ('R' expects
'P' unless --expect-fail).

Does not program the board or use JTAG. The overlay must be loaded and the
CMA buffer held by holder_rc_test.py first. Never point --addr at memory
the buffer does not cover: 'W' writes a 1 MiB window at the base.
"""
import argparse
import os
import sys
import termios
import time

FCLK = 100e6
LINES = 32768
LEN = LINES * 32


def open_serial(path):
    fd = os.open(path, os.O_RDWR | os.O_NOCTTY)
    t = termios.tcgetattr(fd)
    cc = t[6]
    cc[termios.VMIN] = 0
    cc[termios.VTIME] = 1
    termios.tcsetattr(fd, termios.TCSANOW,
                      [0, 0, termios.CS8 | termios.CREAD | termios.CLOCAL, 0,
                       termios.B115200, termios.B115200, cc])
    termios.tcflush(fd, termios.TCIOFLUSH)
    return fd


def read_n(fd, n, timeout):
    buf = b""
    deadline = time.time() + timeout
    while len(buf) < n and time.time() < deadline:
        buf += os.read(fd, n - len(buf))
    return buf


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("cmds", nargs="+", choices=list("AWRGT"))
    ap.add_argument("--addr", help="DUT base physical address (hex)")
    ap.add_argument("--port", default="/dev/ttyUSB3")
    ap.add_argument("--expect-fail", action="store_true", help="R should reply F")
    args = ap.parse_args()

    fd = open_serial(args.port)
    ok = True
    try:
        for c in args.cmds:
            if c == "A":
                if not args.addr:
                    sys.exit("A needs --addr")
                addr = int(args.addr, 0)
                os.write(fd, b"A" + addr.to_bytes(4, "little"))
                want = b"K"
            else:
                os.write(fd, c.encode())
                want = {"W": b"D", "R": b"F" if args.expect_fail else b"P",
                        "G": b"P", "T": None}[c]
            t0 = time.time()
            if c == "T":
                line = read_n(fd, 44, 2.0)
                print("T -> %r" % line.decode("ascii", "replace"))
                try:
                    f = line.decode().split()
                    wc, rc = int(f[0][1:], 16), int(f[1][1:], 16)
                    mm, fb, sd = int(f[2][1:], 16), int(f[3][1:], 16), int(f[4][1:], 16)
                    print("   write %d cycles = %.1f MB/s (%.1f cyc/line), read %d cycles = "
                          "%.1f MB/s (%.1f cyc/line), bad lines %d, first bad line %d, seed %d" % (
                              wc, LEN / (wc / FCLK) / 1e6 if wc else 0, wc / LINES,
                              rc, LEN / (rc / FCLK) / 1e6 if rc else 0, rc / LINES, mm, fb, sd))
                except (ValueError, IndexError):
                    print("ERROR: could not parse stats line", file=sys.stderr)
                    ok = False
                continue
            r = read_n(fd, 1, 5.0)
            dt = (time.time() - t0) * 1000
            good = (r == want)
            ok &= good
            print("%s -> %r (%.1f ms round trip)%s" % (c, r.decode("ascii", "replace"),
                                                    dt, "" if good else "  UNEXPECTED, wanted %r" % want.decode()))
    finally:
        os.close(fd)
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
