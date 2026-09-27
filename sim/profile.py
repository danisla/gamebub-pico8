#!/usr/bin/env python3
"""Aggregate a PC sample profile (profile.txt) by function: profile.py profile.txt pico8.elf [n]"""
import subprocess, sys, collections
samples = [(int(a, 16), int(b)) for a, b in (l.split() for l in open(sys.argv[1]))]
elf = sys.argv[2]
top = int(sys.argv[3]) if len(sys.argv) > 3 else 30
addr2line = sys.argv[4] if len(sys.argv) > 4 else "riscv32-none-elf-addr2line"
out = subprocess.run([addr2line, "-f", "-C", "-e", elf] + [hex(pc) for pc, _ in samples],
                     capture_output=True, text=True).stdout.splitlines()
funcs = collections.Counter()
lines = collections.Counter()
for i, (pc, n) in enumerate(samples):
    fn, loc = out[2 * i], out[2 * i + 1]
    funcs[fn] += n
    lines[fn + " " + loc.split("/")[-1]] += n
total = sum(n for _, n in samples)
print(f"{total} samples")
for fn, n in funcs.most_common(top):
    print(f"{100 * n / total:5.1f}%  {fn[:100]}")
print("\ntop lines:")
for l, n in lines.most_common(15):
    print(f"{100 * n / total:5.1f}%  {l[:110]}")
