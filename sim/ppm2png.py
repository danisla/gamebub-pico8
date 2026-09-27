#!/usr/bin/env python3
"""Convert a P6 PPM to PNG (stdlib only), optionally scaled: ppm2png.py in.ppm out.png [scale]"""
import struct, sys, zlib

def main():
    src, dst = sys.argv[1], sys.argv[2]
    scale = int(sys.argv[3]) if len(sys.argv) > 3 else 1
    data = open(src, "rb").read()
    parts = data.split(b"\n", 3)
    w, h = map(int, parts[1].split())
    pix = parts[3]
    rows = []
    for y in range(h):
        row = pix[y * w * 3:(y + 1) * w * 3]
        row = b"".join(row[x * 3:x * 3 + 3] * scale for x in range(w))
        rows.extend([b"\x00" + row] * scale)
    def chunk(t, d):
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)
    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w * scale, h * scale, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(b"".join(rows))) + chunk(b"IEND", b"")
    open(dst, "wb").write(png)

main()
