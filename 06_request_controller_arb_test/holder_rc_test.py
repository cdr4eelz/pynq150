#!/usr/bin/env python3
"""Board-side helper for 06_request_controller_arb_test (run on the PYNQ with
sudo and the three PYNQ profile scripts).

Loads rc_test.bit (+ .hwh) with pynq.Overlay, allocates a CMA buffer of
WIN + 8 KiB (WIN = 1 MiB, the PL address window), fills it with a 0xEE
sentinel, flushes, and prints PHYS and BASE = PHYS + 0x100 (32-byte aligned,
not page aligned). Send BASE to the DUT with host_rc_test.py --addr.

Command files in BASE_DIR:
  check    contents = seed. Invalidate and verify all LINES 32-byte lines in
           the DDR layout the dcache path produces (see README), plus the
           sentinel outside the block.
  corrupt  contents = line index. Flip byte 5 of that line from the CPU and
           flush, so the next 'R' must answer 'F'.
  stop     free the buffer and exit.

Do not program the PL over JTAG while Linux is running.
"""
import os
import time

import numpy as np
from pynq import Overlay, allocate

BASE_DIR = "/home/xilinx/rc_arb_test"
LINES = 32768              # must match LINES in rtl/rc_test_top.v
LEN = LINES * 32
OFF = 0x100
PAD = 8 * 1024
SENTINEL = 0xEE


def expected_words(seed):
    """uint32 words as they sit in DDR, shape (LINES, 8)."""
    i = np.arange(LINES, dtype=np.uint64)[:, None]
    k = np.arange(8, dtype=np.uint64)[None, :]
    v = (((i << np.uint64(3)) | k) ^ np.uint64(seed * 0x01010101)) & np.uint64(0xFFFFFFFF)
    w = np.where((k & np.uint64(1)) == 1, (~v) & np.uint64(0xFFFFFFFF), v).astype(np.uint32)
    # The dcache sends line words 4..7 first; they land at the lower 16 bytes.
    return w[:, [4, 5, 6, 7, 0, 1, 2, 3]]


def main():
    ol = Overlay(os.path.join(BASE_DIR, "rc_test.bit"))  # noqa: F841
    buf = allocate(shape=(LEN + PAD,), dtype="u1")
    buf[:] = SENTINEL
    buf.flush()
    pa = int(buf.device_address)
    line = "PHYS=0x%08X BASE=0x%08X LINES=%d LEN=%d SENTINEL=0x%02X" % (
        pa, pa + OFF, LINES, LEN, SENTINEL)
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
            got = arr[OFF:OFF + LEN].view("<u4").reshape(LINES, 8)
            bad = np.nonzero(np.any(got != expected_words(seed), axis=1))[0]
            outside = np.concatenate([arr[:OFF], arr[OFF + LEN:]])
            sbad = int(np.count_nonzero(outside != SENTINEL))
            print("CPU_CHECK seed=%d lines=%d bad_lines=%d%s sentinel_bad=%d %s" % (
                seed, LINES, len(bad), (" first=%d" % bad[0]) if len(bad) else "",
                sbad, "PASS" if (len(bad) == 0 and sbad == 0) else "FAIL"), flush=True)
        if os.path.exists(corrupt):
            ln = int(open(corrupt).read().strip() or "100", 0)
            os.remove(corrupt)
            buf.invalidate()
            buf[OFF + ln * 32 + 5] ^= 0x10
            buf.flush()
            print("CPU_CORRUPT line=%d byte=5 xor=0x10" % ln, flush=True)
        time.sleep(0.5)
    buf.freebuffer()
    print("FREED", flush=True)


if __name__ == "__main__":
    main()
