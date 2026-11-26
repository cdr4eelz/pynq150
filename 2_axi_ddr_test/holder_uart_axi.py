#!/usr/bin/env python3
"""Board-side helper (run on the PYNQ as xilinx).

Loads the UART-AXI overlay, allocates a 16 KiB CMA buffer (enough for an
aligned 256-byte transfer and a 4 KB-crossing transfer at offset 0xF80),
fills it with a sentinel, flushes, prints the physical address, and
waits. Touch `check` to invalidate and report CPU-side contents; touch
`stop` to free the buffer.

This script is not run as part of `make sim`. Load the bitstream through
PYNQ, not over JTAG.
"""
import os
import time
from pynq import Overlay, allocate

BASE = "/home/xilinx/uart_axi_ddr"
SENTINEL = 0xEE
BUF_BYTES = 16 * 1024
# 4 KB-crossing offset: 0x1000 - 0x80 = 0xF80, 8-byte aligned,
# 0xF80 + 0x100 = 0x1080 crosses the 4 KB boundary.
CROSS_OFF = 0xF80

ol = Overlay(os.path.join(BASE, "uart_axi_ddr.bit"))
buf = allocate(shape=(BUF_BYTES,), dtype="u1")
buf[:] = SENTINEL
buf.flush()
pa = int(buf.device_address)
open(os.path.join(BASE, "addr.txt"), "w").write(
    "PHYS=0x%08X CROSS=0x%08X BYTES=%d SENTINEL=0x%02X\n" % (
        pa, pa + CROSS_OFF, BUF_BYTES, SENTINEL))
print("OVERLAY_LOADED PHYS=0x%08X CROSS=0x%08X BYTES=%d" % (
    pa, pa + CROSS_OFF, BUF_BYTES), flush=True)

done = os.path.join(BASE, "check")
stop = os.path.join(BASE, "stop")
# check file may contain "aligned" or "cross"; default reports both windows
while not os.path.exists(stop):
    if os.path.exists(done):
        which = open(done).read().strip() or "both"
        os.remove(done)
        buf.invalidate()
        data = [int(x) for x in buf]
        def window(off, label):
            blk = data[off:off+256]
            before = data[off-1] if off > 0 else None
            after = data[off+256]
            print("CPU_%s off=0x%X first=%s last=0x%02X before=0x%02X after=0x%02X" % (
                label, off,
                ["0x%02X" % v for v in blk[:8]],
                blk[-1],
                before if before is not None else SENTINEL,
                after), flush=True)
        if which in ("aligned", "both", ""):
            window(0, "ALIGNED")
        if which in ("cross", "both", ""):
            window(CROSS_OFF, "CROSS")
        # sentinel intact outside the two 256-byte windows
        bad = []
        for i, v in enumerate(data):
            in_a = 0 <= i < 256
            in_c = CROSS_OFF <= i < CROSS_OFF + 256
            if not in_a and not in_c and v != SENTINEL:
                bad.append(i)
        print("CPU_SENTINEL mismatches_outside=%d %s" % (
            len(bad), "PASS" if not bad else "FAIL first=%d" % bad[0]),
            flush=True)
    time.sleep(0.5)
buf.freebuffer()
print("FREED", flush=True)
