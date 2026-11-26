#!/usr/bin/env python3
"""Board-side helper for the 09 cache + SLR overlay (run on the PYNQ with sudo
and the three PYNQ profile scripts, see README).

Loads cache_slr.bit (+ .hwh) with pynq.Overlay, allocates a 16 MiB CMA buffer,
zeroes it (black frames), flushes, and prints

  PHYS   physical address of the buffer
  BASE   = PHYS; send it to the PL with host_09.py --addr (UART 'A')
  FRAME1 = BASE + 4 MiB   (RequestController frame 1, shown with 'S' 1)
  FRAME2 = BASE + 8 MiB   (frame 2)
  CACHE  = BASE + 12 MiB  (cache test region, not displayed)

The drawer, SLR and PixelFeeder touch BASE + 4 MiB ... BASE + 12 MiB (PixelFeeder
frame 0 is its built-in pattern and never reads DDR); the caches can touch any
address in the 16 MiB window. The line in addr.txt has the
same values.

Command files in BASE_DIR:
  dump   contents = frame number (1 or 2): invalidate, decode the frame in the
         DDR layout the PL uses (see README) and write frame<N>.ppm (800x600).
  stop   free the buffer and exit (the bitstream stays loaded).
"""
import os
import time

import numpy as np
from pynq import Overlay, allocate

BASE_DIR = "/home/xilinx/cache_slr"
MIB = 1 << 20
LEN = 16 * MIB
W, H, STRIDE = 800, 600, 4096


def frame_rgb(arr_u4, f):
    """uint32 words of the buffer -> (H, W, 3) uint8 for frame f."""
    off = (f * 4 * MIB) // 4
    rows = arr_u4[off:off + H * STRIDE // 4].reshape(H, STRIDE // 4)[:, :W]
    # The cs150-style line puts pixel 0 of each 16-byte group in the highest
    # 32-bit word: reverse every group of 4 words.
    px = rows.reshape(H, W // 4, 4)[:, :, ::-1].reshape(H, W)
    rgb = np.empty((H, W, 3), dtype=np.uint8)
    rgb[:, :, 0] = (px >> 16) & 0xFF
    rgb[:, :, 1] = (px >> 8) & 0xFF
    rgb[:, :, 2] = px & 0xFF
    return rgb


def main():
    ol = Overlay(os.path.join(BASE_DIR, "cache_slr.bit"))  # noqa: F841
    buf = allocate(shape=(LEN // 4,), dtype="u4")
    buf[:] = 0
    buf.flush()
    pa = int(buf.device_address)
    line = "PHYS=0x%08X BASE=0x%08X FRAME1=0x%08X FRAME2=0x%08X CACHE=0x%08X LEN=0x%X" % (
        pa, pa, pa + 4 * MIB, pa + 8 * MIB, pa + 12 * MIB, LEN)
    open(os.path.join(BASE_DIR, "addr.txt"), "w").write(line + "\n")
    print("OVERLAY_LOADED " + line, flush=True)

    dump = os.path.join(BASE_DIR, "dump")
    stop = os.path.join(BASE_DIR, "stop")
    if os.path.exists(stop):
        os.remove(stop)
    while not os.path.exists(stop):
        if os.path.exists(dump):
            f = int(open(dump).read().strip() or "1", 0)
            os.remove(dump)
            buf.invalidate()
            rgb = frame_rgb(np.asarray(buf), f)
            out = os.path.join(BASE_DIR, "frame%d.ppm" % f)
            with open(out, "wb") as fh:
                fh.write(b"P6\n%d %d\n255\n" % (W, H))
                fh.write(rgb.tobytes())
            print("DUMPED frame=%d %s" % (f, out), flush=True)
        time.sleep(0.3)
    buf.freebuffer()
    print("STOP_SEEN FREED", flush=True)


if __name__ == "__main__":
    main()
