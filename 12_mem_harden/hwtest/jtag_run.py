#!/usr/bin/env python3
"""jtag_run.py - load images into DDR over JTAG (../jtag_load.tcl) and run one with gios `jal`.

  jtag_run.py [--boot] [--load ADDR HEXFILE]... [--pre CMD]... --jal ADDR [--post CMD]... [--log F]

  --boot   run ../jtag_boot.tcl first (fresh bitstream: caches empty, gios prompt), then load
  --load   CPU address + hex image (gios `file` format), repeatable
  --pre    gios commands typed before the jal (e.g. "sw 0 10020000")
  --jal    address for gios `jal` (omit to only load)
  --post   gios commands after the jal (e.g. "lw 10020000")
PYNQ target 1234-tulA only (jtag_load/boot filter on it); UART via gios_uart.py (refuses the XUPV5).
"""
import argparse, os, subprocess, sys, time
HERE = os.path.dirname(os.path.abspath(__file__))
XSCT = "/tools/Xilinx/SDK/2019.1/bin/xsct"

ap = argparse.ArgumentParser()
ap.add_argument("--boot", action="store_true")
ap.add_argument("--load", nargs=2, action="append", default=[], metavar=("ADDR", "HEXFILE"))
ap.add_argument("--pre", action="append", default=[])
ap.add_argument("--jal")
ap.add_argument("--post", action="append", default=[])
ap.add_argument("--log", default=os.path.join(HERE, "logs", "jtag_run.log"))
ap.add_argument("--timeout", default="20")
a = ap.parse_args()
os.makedirs(os.path.dirname(a.log), exist_ok=True)

def run(cmd):
    print("+", " ".join(cmd), flush=True)
    r = subprocess.run(cmd, cwd=os.path.dirname(HERE), capture_output=True, text=True)
    out = "\n".join(l for l in r.stdout.splitlines() if "initializing" not in l)
    print(out + r.stderr, flush=True)
    with open(a.log, "a") as f: f.write(out + r.stderr + "\n")
    if r.returncode: sys.exit("FAILED: %s (exit %d)" % (cmd[1], r.returncode))
    return out

if a.boot:
    run([XSCT, "jtag_boot.tcl"]); time.sleep(2)
if a.load:
    run([XSCT, "jtag_load.tcl"] + [x for ad, f in a.load for x in (ad, os.path.abspath(f))])
if a.jal or a.pre or a.post:
    cmds = a.pre + (["jal %s" % a.jal] if a.jal else []) + a.post
    r = subprocess.run([sys.executable, os.path.join(HERE, "gios_uart.py"), "--log", a.log,
                        "--timeout", a.timeout] + cmds, capture_output=True, text=True)
    print(r.stdout.replace("\r", ""), r.stderr)
    sys.exit(r.returncode)
