#!/usr/bin/env python3
"""verify_capture.py name mode [rrggbb]  -- grab /dev/video2 (retry while the UVC
dongle outputs black), save capture/fb/<name>.png, compare with the pattern the
drawer should have produced and print the best horizontal shift and mean error.
mode: fill|clear|bars|checker|gradient|grid"""
import subprocess, sys, os
import numpy as np
from PIL import Image
W, H = 800, 600
here = os.path.dirname(os.path.abspath(__file__))
def expected(mode, col=(0, 0, 0)):
    x = np.arange(W)[None, :].repeat(H, 0); y = np.arange(H)[:, None].repeat(W, 1)
    o = np.zeros((H, W, 3), np.uint8)
    if mode in ("fill", "clear"):
        o[:] = col
    elif mode == "bars":
        cols = [(255,255,255),(255,255,0),(0,255,255),(0,255,0),(255,0,255),(255,0,0),(0,0,255),(0,0,0)]
        for i, c in enumerate(cols): o[:, i*W//8:(i+1)*W//8] = c
    elif mode == "checker":
        o[:] = 255; o[((x >> 5) ^ (y >> 5)) & 1 == 1] = (0x20, 0x20, 0x20)
    elif mode == "gradient":
        gx = (x * (262143 // (W-1))) >> 10; gy = (y * (262143 // (H-1))) >> 10
        o = np.stack([gx, gy, 255-gx], -1).astype(np.uint8)
    elif mode == "grid":
        g = (x % 64 == 0) | (y % 64 == 0); o[g] = 255
        o[(x == W//2-1) | (x == W//2) | (y == H//2-1) | (y == H//2)] = (0, 255, 0)
        o[(x <= 1) | (x >= W-2) | (y <= 1) | (y >= H-2)] = (255, 0, 0)
    return o
def grab(path):
    for n in (150, 150, 150, 150, 150, 150):
        subprocess.run(["ffmpeg","-hide_banner","-loglevel","error","-y","-f","v4l2","-input_format","yuyv422",
                        "-video_size","800x600","-framerate","60","-i","/dev/video2","-vf","select=eq(n\\,%d)" % n,
                        "-vsync","0","-frames:v","1",path], check=True)
        a = np.asarray(Image.open(path).convert("RGB"))
        if a.max() > 0: return a, n
        print("  dongle black at frame %d, retrying" % n, flush=True)
    return a, None
name, mode = sys.argv[1], sys.argv[2]
col = tuple(int(sys.argv[3][i:i+2], 16) for i in (0, 2, 4)) if len(sys.argv) > 3 else (0, 0, 0)
out = os.path.join(here, "capture", "fb", name + ".png")
a, n = grab(out)
e = expected(mode, col)
f = lambda im: im.astype(np.float32)
best = None
for s in range(-40, 41):
    err = np.abs(f(np.roll(a, -s, axis=1)) - f(e)).mean()
    if best is None or err < best[1]: best = (s, err)
err0 = np.abs(f(a) - f(e)).mean()
print("%s: %s frame=%s mean|err|=%.1f best_shift=%+d (err %.1f)  -> %s" % (
    name, mode, n, err0, best[0], best[1], os.path.abspath(out)))
