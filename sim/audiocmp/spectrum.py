import sys, numpy as np
def load(p):
    return np.frombuffer(open(p, 'rb').read()[44:], dtype='<i2').astype(np.float64)
a, b = load(sys.argv[1]), load(sys.argv[2])
n = min(len(a), len(b)); W = 4096
name = sys.argv[1].split('/')[-1].split('.')[0]
cs = []; worst = []
for s in range(0, n - W + 1, W):
    x, y = a[s:s+W], b[s:s+W]
    if np.sqrt(np.mean(x*x)) < 50 and np.sqrt(np.mean(y*y)) < 50: continue
    win = np.hanning(W)
    X = np.log10(np.abs(np.fft.rfft(x*win))[:1400] + 1e2)  # up to ~7.5 kHz
    Y = np.log10(np.abs(np.fft.rfft(y*win))[:1400] + 1e2)
    c = np.corrcoef(X, Y)[0, 1]; cs.append(c); worst.append((c, s / 22050))
if cs:
    worst.sort()
    print(f"{name}: {len(cs)} windows, spectral corr mean {np.mean(cs):.3f} min {worst[0][0]:.3f} @ {worst[0][1]:.1f}s")
else:
    print(f"{name}: silent")
