#!/usr/bin/env python3
"""Board-side helper for 04_uart_ddr_block_test (run on the PYNQ, sudo +
the three PYNQ profile scripts).

Loads uart_ddr_block.bit (+ .hwh) with pynq.Overlay, allocates a CMA buffer
of LEN + 8 KiB, fills it with a 0xEE sentinel, flushes, and prints the
physical address and the suggested DUT base (PHYS + 0xF08, so every burst
boundary is 4 KB-unaligned and the block crosses many 4 KB pages).

Then it polls for command files in BASE_DIR:
  check    contents = seed (decimal or 0x hex). Invalidate, verify the
           whole block against the PL pattern for that seed, and the
           sentinel bytes before/after the block.
  corrupt  contents = beat index. Flip one byte of that beat from the CPU
           and flush, so the next 'R' must report 'F' (hardware FAIL
           injection). Prints the beat index.
  stop     free the buffer and exit.

Do not program the PL over JTAG while Linux is running.
"""
import os
import time

import numpy as np
from pynq import Overlay, allocate

BASE_DIR = "/home/xilinx/uart_ddr_block"
LEN = 1024 * 1024          # must match LEN_BYTES in rtl/uart_ddr_block_top.v
OFF = 0xF08                # DUT base offset inside the buffer
PAD = 8 * 1024
SENTINEL = 0xEE


def pattern(seed, beats):
    idx = np.arange(beats, dtype=np.uint64)
    lo = (idx ^ np.uint64(seed * 0x01010101)) & np.uint64(0xFFFFFFFF)
    rot = ((lo << np.uint64(16)) | (lo >> np.uint64(16))) & np.uint64(0xFFFFFFFF)
    hi = (~rot) & np.uint64(0xFFFFFFFF)
    return (hi << np.uint64(32)) | lo


def main():
    ol = Overlay(os.path.join(BASE_DIR, "uart_ddr_block.bit"))  # noqa: F841
    buf = allocate(shape=(LEN + PAD,), dtype="u1")
    buf[:] = SENTINEL
    buf.flush()
    pa = int(buf.device_address)
    line = "PHYS=0x%08X BASE=0x%08X LEN=%d SENTINEL=0x%02X" % (pa, pa + OFF, LEN, SENTINEL)
    open(os.path.join(BASE_DIR, "addr.txt"), "w").write(line + "\n")
    print("OVERLAY_LOADED " + line, flush=True)

    check = os.path.join(BASE_DIR, "check")
    corrupt = os.path.join(BASE_DIR, "corrupt")
    stop = os.path.join(BASE_DIR, "stop")
    while not os.path.exists(stop):
        if os.path.exists(check):
            seed = int(open(check).read().strip() or "1", 0)
            os.remove(check)
            buf.invalidate()
            arr = np.asarray(buf)
            words = arr[OFF:OFF + LEN].view("<u8")
            exp = pattern(seed, LEN // 8)
            bad = np.nonzero(words != exp)[0]
            outside = np.concatenate([arr[:OFF], arr[OFF + LEN:]])
            sbad = int(np.count_nonzero(outside != SENTINEL))
            print("CPU_CHECK seed=%d beats=%d mismatches=%d%s sentinel_bad=%d %s" % (
                seed, LEN // 8, len(bad),
                (" first=%d" % bad[0]) if len(bad) else "",
                sbad, "PASS" if (len(bad) == 0 and sbad == 0) else "FAIL"), flush=True)
        if os.path.exists(corrupt):
            beat = int(open(corrupt).read().strip() or "1000", 0)
            os.remove(corrupt)
            buf.invalidate()
            buf[OFF + beat * 8 + 3] ^= 0x10
            buf.flush()
            print("CPU_CORRUPT beat=%d byte=3 xor=0x10" % beat, flush=True)
        time.sleep(0.5)
    buf.freebuffer()
    print("FREED", flush=True)


if __name__ == "__main__":
    main()
