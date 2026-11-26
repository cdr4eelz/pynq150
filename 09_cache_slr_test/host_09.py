#!/usr/bin/env python3
"""Host-side driver for the 09 cache + SLR overlay (run on UBU24).

Sends the single-character UART commands to the Pmod USBUART (default
/dev/ttyUSB3, 115200 8N1) and checks each reply.

  python3 host_fb.py --addr 0x<BASE> A S1 C       # set base, show frame 1, clear
  python3 host_fb.py F:ff8000 B H G X U

Tokens (run in order):
  A          'A' + 4-byte LE --addr                  -> K
  S<n>       show frame n (0 = PixelFeeder pattern, 1, 2)  -> K
  T<n>       draw target frame n (1, 2)              -> K
  P<n>       gap cycles after each line write (0..255)     -> K
  C          clear to black                          -> D
  F:rrggbb   fill with colour                        -> D
  B H G X    bars / checkerboard / gradient / grid   -> D
  V          toggle source (V = PixelFeeder, v = test pattern)
  Q          toggle auto-resync (Q = on, q = off)
  Z          resync PixelFeeder now                  -> K
  U          status line "Us RRRR PPPP Wwwwwwwww" (s = underflow since the last
             U, RRRR resyncs, PPPP PixelFeeder pf_status, W = cycles of the last
             draw); clears the underflow flag
09 ASCII commands: any token starting with R J W D E O M Y L is sent as one
line (add quotes when it has spaces) and the reply line is printed:
  "R 0xC00000"  "R 0xC00000 8"  "J 0xC00000"  "W 0xC00000 0x12345678"
  "D f 0xC00000 64 0x11110000"  "D v 0xC00000 64 0x11110000"
  "E 0xC00100"  "E x 0xC00200"  "O 0xC00300 0xCAFEF00D"  M  "M c"
  "Y 0xff0000"  "L 100 10 200"  "L 300 0 799 0x0000ff"
A line reply is BAD if it is "?", "N", "E", or a D / E / X / O line with F.
Exit status 0 only if every reply was as expected.

Does not program the board. The overlay must be loaded and the buffer held by
holder_hdmi_09.py first; --addr must be the BASE it prints.
"""
import argparse
import os
import sys
import termios
import time

FCLK = 100e6
DRAW = {"C": "C", "B": "B", "H": "H", "G": "G", "X": "X"}
ASCII = "RJWDEOMYL"


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


def read_line(fd, timeout):
    buf = b""
    deadline = time.time() + timeout
    while not buf.endswith(b"\n") and time.time() < deadline:
        buf += os.read(fd, 1)
    return buf


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("tokens", nargs="+")
    ap.add_argument("--dev", default="/dev/ttyUSB3")
    ap.add_argument("--addr", type=lambda s: int(s, 0))
    a = ap.parse_args()
    fd = open_serial(a.dev)
    ok = True
    for tok in a.tokens:
        t0 = time.time()
        c = tok[0]
        if c in ASCII:
            os.write(fd, tok.encode() + b"\n")
            r = read_line(fd, 30.0)
            dt = time.time() - t0
            txt = r.decode(errors="replace").strip()
            good = r.endswith(b"\n") and txt not in ("?", "N", "E") and not (
                txt[:1] in "DEXO" and txt[2:3] == "F")
            ok &= good
            print("%-28s -> %-44r %s %.3f s" % (tok, txt, "ok " if good else "BAD", dt), flush=True)
            continue
        if c == "A":
            if a.addr is None:
                sys.exit("A needs --addr")
            os.write(fd, b"A" + a.addr.to_bytes(4, "little"))
            exp, n = b"K", 1
        elif c in "STP":
            os.write(fd, c.encode() + bytes([int(tok[1:], 0)]))
            exp, n = b"K", 1
        elif c == "F":
            rgb = bytes.fromhex(tok.split(":", 1)[1])
            os.write(fd, b"F" + rgb)
            exp, n = b"D", 1
        elif c in DRAW:
            os.write(fd, c.encode())
            exp, n = b"D", 1
        elif c == "V":
            os.write(fd, b"V")
            exp, n = None, 1
        elif c == "Q":
            os.write(fd, b"Q")
            exp, n = None, 1
        elif c == "Z":
            os.write(fd, b"Z")
            exp, n = b"K", 1
        elif c == "U":
            os.write(fd, b"U")
            exp, n = None, 23
        else:
            sys.exit("unknown token %r" % tok)
        r = read_n(fd, n, 10.0)
        dt = time.time() - t0
        good = (r == exp) if exp is not None else (len(r) == n)
        ok &= good
        txt = r.decode(errors="replace").strip()
        extra = ""
        if c == "U" and len(r) == n:
            cyc = int(txt.split("W")[1], 16)
            extra = "  (last draw %.2f ms, %.0f MB/s for a 800x600x4 frame)" % (
                cyc / FCLK * 1e3, 800 * 600 * 4 / (cyc / FCLK) / 1e6 if cyc else 0)
        print("%-10s -> %-24r %s %.3f s%s" % (tok, txt, "ok " if good else "BAD", dt, extra),
              flush=True)
    os.close(fd)
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
