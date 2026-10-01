#!/usr/bin/env python3
"""Compare the frames (frame_NNNN.ppm, dumped every frame) of two simulation
runs of a cart: cmp_frames.py reference_dir test_dir

The runs may show the same frames at different times (a faster run shows a
frame a video frame earlier, or doesn't drop it), so this checks that each
distinct frame of the test run is one of the reference run's, in the same
order, and counts the reference frames the test run didn't show."""
import sys
from pathlib import Path


def distinct(d):
    frames = []
    for p in sorted(d.glob("frame_*.ppm")):
        data = p.read_bytes().split(b"\n", 3)[3]
        if not frames or frames[-1][1] != data:
            frames.append((p.name, data))
    return frames


def main():
    ref, test = distinct(Path(sys.argv[1])), distinct(Path(sys.argv[2]))
    # Positions of each distinct frame (a frame can come back, e.g. a title
    # screen).
    index = {}
    for i, (_, data) in enumerate(ref):
        index.setdefault(data, []).append(i)
    bad = 0
    last = -1
    shown = set()
    for name, data in test:
        positions = index.get(data)
        i = None if positions is None else next((p for p in positions if p >= last), positions[0])
        if i is None:
            # The closest reference frame (by differing pixels), for the report.
            best = min(ref, key=lambda r: sum(r[1][k:k + 3] != data[k:k + 3] for k in range(0, len(data), 3)))
            diff = sum(best[1][k:k + 3] != data[k:k + 3] for k in range(0, len(data), 3))
            print(f"{name}: not in the reference (closest {best[0]}, {diff} pixels differ)")
            bad += 1
        elif i < last:
            print(f"{name}: out of order (reference {ref[i][0]})")
            bad += 1
        else:
            last = i
            shown.add(i)
        if bad >= 10:
            break
    missed = sum(1 for i in range(min(shown, default=0), last + 1) if i not in shown)
    print(f"{len(test)} distinct frames ({len(ref)} in the reference), {bad} not matching, "
          f"{missed} reference frames not shown")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
