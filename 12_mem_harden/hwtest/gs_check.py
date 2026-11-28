#!/usr/bin/env python3
"""gs_check.py LOG... - PixelFeeder health from gios `gs` replies in hwtest logs.

gs word = {pf_status16, gp_status16}, pf_status = {fault, dormant, frame[5:0], resync[7:0]}:
resync (PixelFeeder restarts after a line-FIFO underrun) = bits 23:16, fault = bit 31 ('*').
Prints first/last resync count and fault per log; exit 1 if any log's count rose or a fault was
seen (--abs: also fail if the count is non-zero at all)."""
import re, sys
absmode = "--abs" in sys.argv
bad = 0
for f in [a for a in sys.argv[1:] if not a.startswith("--")]:
    ws = [int(m, 16) for m in re.findall(r"^([0-9a-f]{8}) PF#", open(f, errors="replace").read(), re.M)]
    if not ws:
        print("%s: no gs replies" % f); continue
    rs = [(w >> 16) & 0xff for w in ws]
    fault = any(w >> 31 for w in ws)
    ok = rs[-1] == rs[0] and not fault and not (absmode and rs[-1])
    bad |= not ok
    print("%s: %d gs, resync %d -> %d (+%d), fault %s  %s" % (f, len(ws), rs[0], rs[-1], rs[-1] - rs[0],
          "YES" if fault else "no", "PASS" if ok else "FAIL"))
sys.exit(1 if bad else 0)
