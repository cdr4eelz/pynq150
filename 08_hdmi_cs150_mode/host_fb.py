#!/usr/bin/env python3
"""Host-side driver for the 08 framebuffer overlay (run on UBU24).

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
  R:x,y      debug probe: "R vvvvvvvv tttttttt dddddddd" where v = the pixel the
             sink took at (x, y) in the last frame (bit31 taken, bit30 valid,
             bit29 sink running, [23:0] RGB), t = pixels taken in the last frame
             (480000 = 0x75300), d = pixf beats still outstanding (2 x accepted
             requests - returned beats). Sent twice, 50 ms apart; the second
             reply is printed.
Exit status 0 only if every reply was as expected.

Does not program the board. The overlay must be loaded and the buffer held by
holder_hdmi_fb.py first; --addr must be the BASE it prints.
"""
import argparse
import os
import sys
import termios
import time

FCLK = 100e6
DRAW = {"C": "C", "B": "B", "H": "H", "G": "G", "X": "X"}


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
    ap.add_argument("tokens", nargs="+")
    ap.add_argument("--dev", default="/dev/ttyUSB3")
    ap.add_argument("--addr", type=lambda s: int(s, 0))
    a = ap.parse_args()
    fd = open_serial(a.dev)
    ok = True
    for tok in a.tokens:
        t0 = time.time()
        c = tok[0]
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
        elif c == "R":
            px, py = (int(v, 0) for v in tok.split(":", 1)[1].split(","))
            cmd = b"R" + px.to_bytes(2, "little") + py.to_bytes(2, "little")
            os.write(fd, cmd)
            read_n(fd, 29, 10.0)
            time.sleep(0.05)
            os.write(fd, cmd)
            exp, n = None, 29
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
