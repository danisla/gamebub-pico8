#!/usr/bin/env python3
"""Compare the cart checksums in a PICO-8 core log with the cart file:
check_cart_log.py cart.p8.png cart.p8.log"""
import re, sys, zlib
data = open(sys.argv[1], 'rb').read()
log = open(sys.argv[2], errors='replace').read()
want = ['%08x' % zlib.crc32(data[i:i + 1024]) for i in range(0, len(data), 1024)]
for n, m in enumerate(re.finditer(r'\[diag\] cart crc32 per KiB, read (\d):\n((?:  .*\n)+)', log)):
    got = m.group(2).split()
    bad = [i for i, (a, b) in enumerate(zip(got, want)) if a != b]
    print(f"read {m.group(1)}: {len(bad)} of {len(want)} KiB blocks differ"
          + (f": offsets {', '.join(hex(i * 1024) for i in bad)}" if bad else ""))
    if len(got) != len(want):
        print(f"  (log has {len(got)} blocks, file has {len(want)})")
for line in re.findall(r'\[diag\] sdram.*', log):
    print(line)
