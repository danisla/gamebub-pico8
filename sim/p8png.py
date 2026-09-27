#!/usr/bin/env python3
"""Decode a .p8.png cart's ROM (0x8000 bytes): each byte is the low 2 bits of A, R, G, B."""
import sys, zlib, struct

def decode_png(path):
    d = open(path, 'rb').read()
    assert d[:8] == b'\x89PNG\r\n\x1a\n'
    pos, idat, w, h = 8, b'', 0, 0
    while pos < len(d):
        n, t = struct.unpack('>I4s', d[pos:pos + 8])
        c = d[pos + 8:pos + 8 + n]
        if t == b'IHDR':
            w, h, depth, ctype = struct.unpack('>IIBB', c[:10])
            assert depth == 8 and ctype == 6, (depth, ctype)
        elif t == b'IDAT':
            idat += c
        pos += 12 + n
    raw = zlib.decompress(idat)
    stride = w * 4
    rows, prev = [], bytearray(stride)
    for y in range(h):
        f = raw[y * (stride + 1)]
        line = bytearray(raw[y * (stride + 1) + 1:(y + 1) * (stride + 1)])
        for x in range(stride):
            a = line[x - 4] if x >= 4 else 0
            b = prev[x]
            cc = prev[x - 4] if x >= 4 else 0
            if f == 1: line[x] = (line[x] + a) & 255
            elif f == 2: line[x] = (line[x] + b) & 255
            elif f == 3: line[x] = (line[x] + (a + b) // 2) & 255
            elif f == 4:
                p = a + b - cc
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - cc)
                line[x] = (line[x] + (a if pa <= pb and pa <= pc else b if pb <= pc else cc)) & 255
        rows.append(bytes(line))
        prev = line
    return w, h, b''.join(rows)

w, h, px = decode_png(sys.argv[1])
rom = bytearray()
for i in range(0, len(px), 4):
    r, g, b, a = px[i:i + 4]
    rom.append(((a & 3) << 6) | ((r & 3) << 4) | ((g & 3) << 2) | (b & 3))
rom = bytes(rom[:0x8020])
for name, s, e in [("gfx", 0, 0x2000), ("map", 0x2000, 0x3000), ("flags", 0x3000, 0x3100),
                   ("music", 0x3100, 0x3200), ("sfx", 0x3200, 0x4300)]:
    print(f"{name:6s} nonzero {sum(1 for x in rom[s:e] if x)} / {e - s}")
print("code header:", rom[0x4300:0x4308], "version byte @0x8000:", rom[0x8000])
if len(sys.argv) > 2:
    open(sys.argv[2], 'wb').write(rom)
