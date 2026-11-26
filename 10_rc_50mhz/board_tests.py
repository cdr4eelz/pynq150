#!/usr/bin/env python3
"""board_tests.py --label NAME [--addr 0x10000000] [--hz N] [--no-capture]

Default: JTAG-booted board (jumper on JTAG, no Linux, xsct jtag_boot.tcl), fixed base 0x10000000.

Runs the 09/10 board test set over /dev/ttyUSB3 through host_10.py and prints a
summary: 08 sanity, cache R/W/D/J/M at +12 MiB, E / E x / O hazards (N random
lines, plus 150 on visible frame-1 lines), SLR span drawing with readback, and
HDMI captures (verify_capture.py patterns + slr_demo.py). Logs go to
capture/<label>/. Exit 0 only if everything passed."""
import argparse, json, os, random, re, subprocess, sys
here = os.path.dirname(os.path.abspath(__file__))
def host(toks, addr=None):
    cmd = [sys.executable, os.path.join(here, "host_10.py")] + (["--addr", hex(addr)] if addr is not None else []) + toks
    r = subprocess.run(cmd, capture_output=True, text=True)
    return r.returncode, r.stdout + r.stderr
def lines_bad(out):
    return [l for l in out.splitlines() if re.search(r"\s(BAD)\s+\d", l)]
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--addr", type=lambda s: int(s, 0), default=0x10000000)
    ap.add_argument("--label", required=True)
    ap.add_argument("--hz", type=int, default=1000)
    ap.add_argument("--no-capture", action="store_true")
    a = ap.parse_args()
    d = os.path.join(here, "capture", a.label); os.makedirs(d, exist_ok=True)
    res = {}
    def step(name, toks, addr=None, expect_bad=0):
        rc, out = host(toks, addr)
        open(os.path.join(d, name + ".log"), "w").write(out)
        bad = lines_bad(out)
        ok = (len(bad) == expect_bad) and ("Traceback" not in out)
        res[name] = (ok, len(toks), len(bad))
        print("%-10s %s  tokens=%d bad=%d" % (name, "PASS" if ok else "FAIL", len(toks), len(bad)), flush=True)
        return out
    step("sanity", ["A", "S1", "T1", "C", "F:ff0000", "B", "H", "G", "X", "U", "Q", "Q"], a.addr)
    out = step("cache", ["M c", "R 0xC00000", "R 0xC00000", "W 0xC00000 0x12345678", "R 0xC00000",
                         "W 0xC01000 0xdeadbeef", "R 0xC01000", "R 0xC00000 8", "J 0xC00000", "J 0xC00000 8",
                         "D f 0xC00000 2048 0x11110000", "D v 0xC00000 2048 0x11110000",
                         "D v 0xC00000 2048 0x11110000", "D v 0xC00010 4 0x11110004",
                         "D v 0xC00010 4 0x11110000", "M"], expect_bad=1)   # last D v is a deliberate mismatch
    print("\n".join("    " + l for l in out.splitlines()))
    random.seed(7); t = ["M c", "T2", "S1"]
    for i in range(a.hz):
        ad = 0xC00000 + random.randrange(0, 0x400000 // 32) * 32; dv = random.getrandbits(32)
        t.append(["E 0x%X 0x%X", "E x 0x%X 0x%X", "O 0x%X 0x%X"][i % 3] % (ad, dv))
    for i in range(150):
        ad = 0x400000 + random.randrange(0, 600) * 4096 + random.randrange(0, 100) * 32
        t.append(["E 0x%X", "E x 0x%X", "O 0x%X"][i % 3] % ad)
    t += ["M", "U"]
    out = step("hazard", t)
    st = {}
    for l in out.splitlines():
        m = re.match(r"(E x|E|O) .*-> '([EXO]) (P|F) \w+ \w+ (\w+) (\w+) (\w)'", l)
        if m:
            s = st.setdefault(m.group(1), {"n": 0, "F": 0, "h": 0, "w": [], "r": []})
            s["n"] += 1; s["F"] += m.group(3) == "F"; s["h"] += m.group(6) == "h"
            s["w"].append(int(m.group(4), 16)); s["r"].append(int(m.group(5), 16))
    for k, s in st.items():
        print("    %-4s n=%d F=%d last-h=%d write=%d..%d reread min/avg/max=%d/%.1f/%d cyc" % (
            k, s["n"], s["F"], s["h"], min(s["w"]), max(s["w"]), min(s["r"]), sum(s["r"]) / len(s["r"]), max(s["r"])))
    print("    " + "\n    ".join(out.splitlines()[-2:]))
    # SLR spans + readback
    sp = [(100, 0, 799, 0xFFFF0000, "Y 0xff0000", "L 100 0 799"), (300, 200, 600, 0xFF00FF00, "Y 0x00ff00", "L 300 200 600"),
          (301, 200, 600, 0xFF00FF00, None, "L 301 600 200"), (50, 10, 10, 0xFF0000FF, "Y 0x0000ff", "L 50 10 10"),
          (599, 0, 799, 0xFF0000FF, None, "L 599 0 799"), (0, 0, 799, 0xFFFFFF00, None, "L 0 0 799 0xffff00"),
          (200, 100, 700, 0xFF123456, None, "L 200 100 700 0x123456")]
    toks = ["T1", "C"]
    for r, x0, x1, c, y, l in sp:
        if y: toks.append(y)
        toks.append(l)
    step("slr_draw", toks)
    chk = []
    for r, x0, x1, c, y, l in sp:
        for x, e in [(x0 - 1, 0), (x0, c), (x1, c), (x1 + 1, 0)]:
            if 0 <= x < 800: chk.append((0x400000 + r * 4096 + x * 4, e))
    out = step("slr_read", ["R 0x%X" % ad for ad, e in chk])
    mism = 0
    for (ad, e), l in zip(chk, [l for l in out.splitlines() if "'R " in l]):
        g = int(re.search(r"'R ([0-9A-F]{8})", l).group(1), 16)
        if g != e: mism += 1; print("    MISMATCH 0x%X got %08X exp %08X" % (ad, g, e))
    res["slr_read"] = (res["slr_read"][0] and mism == 0, len(chk), mism)
    print("    SLR readbacks %d, mismatches %d" % (len(chk), mism))
    if not a.no_capture:
        caps = []
        for tok, mode, col in [("G", "gradient", ""), ("H", "checker", ""), ("X", "grid", ""), ("B", "bars", ""),
                               ("F:00ff00", "fill", "00ff00")]:
            host(["T1", "S1", "C", tok], a.addr)
            for attempt in range(3):
                r = subprocess.run([sys.executable, os.path.join(here, "verify_capture.py"), "%s_%s" % (a.label, mode), mode]
                                   + ([col] if col else []), capture_output=True, text=True).stdout
                if "frame=None" not in r: break
                host(["G"]); host(["T1", "C", tok])
            caps.append(r.strip().splitlines()[-1]); print("    " + caps[-1])
        r = subprocess.run([sys.executable, os.path.join(here, "slr_demo.py"), "--addr", hex(a.addr), "--capture",
                            "%s_slr_demo" % a.label], capture_output=True, text=True).stdout
        print("    " + "\n    ".join(r.strip().splitlines()))
    allok = all(v[0] for v in res.values())
    json.dump({k: list(v) for k, v in res.items()}, open(os.path.join(d, "summary.json"), "w"))
    print("ALL_PASS" if allok else "SOME_FAIL")
    sys.exit(0 if allok else 1)
main()
