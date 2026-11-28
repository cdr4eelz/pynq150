#!/usr/bin/env python3
# coe2mif.py IN.coe > OUT.mif : CoreGen .coe (radix 16) -> one 32-char binary word per line
# for sim/models/brams.v ($readmemb), as proj150 sim/ise/scripts/build-sw.sh does.
import sys, re
t = open(sys.argv[1]).read()
v = t.split("memory_initialization_vector", 1)[1].split("=", 1)[1]
for w in re.findall(r"[0-9a-fA-F]+", v.split(";")[0]):
    print(format(int(w, 16), "032b"))
