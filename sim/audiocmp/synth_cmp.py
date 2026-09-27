import numpy as np, sys
def cases(p):
    d = open(p, 'rb').read(); out = []; i = 0
    while i < len(d):
        j = d.index(b'\n', i); name = d[i:j].decode(); i = j + 1
        out.append((name, np.frombuffer(d[i:i+22050], dtype='<i2').astype(float))); i += 22050
    return out
A, B = cases(sys.argv[1]), cases(sys.argv[2])
W = 4096; win = np.hanning(W); rows = []
for (n, x), (_, y) in zip(A, B):
    rx, ry = np.sqrt(np.mean(x*x)), np.sqrt(np.mean(y*y))
    cs = []
    for s in range(0, len(x) - W + 1, W // 2):
        X = np.log10(np.abs(np.fft.rfft(x[s:s+W]*win))[:1400] + 1e2)
        Y = np.log10(np.abs(np.fft.rfft(y[s:s+W]*win))[:1400] + 1e2)
        cs.append(np.corrcoef(X, Y)[0, 1] if X.std() > 0 and Y.std() > 0 else 1.0)
    rows.append((min(cs), n, rx, ry))
rows.sort()
for c, n, rx, ry in rows[:25]:
    print(f"{n:18s} spec {c:5.2f}  rms ref {rx:6.0f} fixed {ry:6.0f}")
print("median", np.median([r[0] for r in rows]))
