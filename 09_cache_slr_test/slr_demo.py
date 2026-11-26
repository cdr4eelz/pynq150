#!/usr/bin/env python3
"""slr_demo.py -- draw a ScanLineRunner test picture on the board (frame 1) over
the UART, then (with --capture NAME) grab /dev/video2 (retrying while the UVC
dongle is black, nudging it with 'V V' / 'Z' through the UART) and compare it with
the expected image.  Usage: slr_demo.py --addr 0x<BASE> [--capture NAME] [--no-draw]
Expected picture: diagonal-edged triangle of per-row colours (one L span per row),
white rows 0 and 599, magenta row 299, one cyan pixel at (400, 300)."""
import argparse, os, subprocess, sys, time
import numpy as np
from PIL import Image
here = os.path.dirname(os.path.abspath(__file__))
W, H = 800, 600
def spans():
    s = []
    for r in range(H):
        xe = r * (W - 1) // (H - 1)
        c = ((r * 255 // (H - 1)) << 16) | ((255 - r * 255 // (H - 1)) << 8) | 0x80
        s.append((r, 0, xe, c))
    s += [(0, 0, W - 1, 0xFFFFFF), (H - 1, 0, W - 1, 0xFFFFFF), (299, 0, W - 1, 0xFF00FF), (300, 400, 400, 0x00FFFF)]
    return s
def expected():
    o = np.zeros((H, W, 3), np.uint8)
    for r, a, b, c in spans():
        o[r, a:b + 1] = ((c >> 16) & 255, (c >> 8) & 255, c & 255)
    return o
def uart(toks, addr=None):
    cmd = [sys.executable, os.path.join(here, "host_09.py")] + (["--addr", hex(addr)] if addr else []) + toks
    r = subprocess.run(cmd, capture_output=True, text=True)
    return r.returncode, r.stdout
def grab(path, nudge):
    for i, n in enumerate((150, 150, 150, 150, 150, 150)):
        subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-f", "v4l2", "-input_format", "yuyv422",
                        "-video_size", "800x600", "-framerate", "60", "-i", "/dev/video2", "-vf", "select=eq(n\\,%d)" % n,
                        "-vsync", "0", "-frames:v", "1", path], check=True)
        a = np.asarray(Image.open(path).convert("RGB"))
        if a.max() > 0:
            return a, n
        print("  dongle black (try %d), nudging with V V / Z" % i, flush=True)
        uart(["V", "V", "Z"] if i % 2 else ["V", "V"])
    return a, None
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--addr", type=lambda s: int(s, 0))
    ap.add_argument("--capture")
    ap.add_argument("--no-draw", action="store_true")
    a = ap.parse_args()
    if not a.no_draw:
        toks = ["T1", "S1", "C"] + ["L %d %d %d 0x%06X" % s for s in spans()]
        t0 = time.time(); rc, out = uart(toks, a.addr)
        bad = [l for l in out.splitlines() if " BAD " in l]
        print("drew %d spans in %.1f s, UART replies bad: %d" % (len(spans()), time.time() - t0, len(bad)))
        if bad: print("\n".join(bad[:5]))
    if a.capture:
        out = os.path.join(here, "capture", a.capture + ".png")
        im, n = grab(out, True)
        e = expected(); f = lambda x: x.astype(np.float32)
        best = min(((s, np.abs(f(np.roll(im, -s, axis=1)) - f(e)).mean()) for s in range(-40, 41)), key=lambda t: t[1])
        err0 = np.abs(f(im) - f(e)).mean()
        print("%s frame=%s mean|err|=%.1f best_shift=%+d (err %.1f) -> %s" % (a.capture, n, err0, best[0], best[1], out))
main()
