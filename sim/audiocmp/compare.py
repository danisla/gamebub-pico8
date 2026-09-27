import struct, sys, math
def load(p):
    d = open(p, 'rb').read()[44:]
    return struct.unpack('<%dh' % (len(d) // 2), d)
a, b = load(sys.argv[1]), load(sys.argv[2])
n = min(len(a), len(b))
W = 22050
print(f"{sys.argv[1].split('/')[-1].split('.')[0]}: {n/W:.1f}s")
tot_err = tot_sig = 0
for s in range(0, n - W + 1, W):
    x, y = a[s:s+W], b[s:s+W]
    rx = math.sqrt(sum(v*v for v in x) / W); ry = math.sqrt(sum(v*v for v in y) / W)
    mx, my = sum(x)/W, sum(y)/W
    cov = sum((p-mx)*(q-my) for p, q in zip(x, y))
    vx = sum((p-mx)**2 for p in x); vy = sum((q-my)**2 for q in y)
    corr = cov / math.sqrt(vx*vy) if vx and vy else float('nan')
    err = sum((p-q)**2 for p, q in zip(x, y)); tot_err += err; tot_sig += sum(p*p for p in x)
    print(f"  t={s/W:4.0f}s  rms ref {rx:6.0f} fixed {ry:6.0f}  corr {corr:5.2f}")
if tot_sig: print(f"  SNR (ref vs fixed): {10*math.log10(tot_sig/max(tot_err,1)):.1f} dB")
