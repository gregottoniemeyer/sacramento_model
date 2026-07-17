"""Check whether a seated person's weight measurably tilts the chair:
compare the steady accel (gravity) vector between empty and seated-still.

Features chosen to be invariant to the chair swiveling (sensor Z is close
to the swivel axis): the Z component, and the magnitude of the XY component.
"""

import re
import statistics
import sys

LINE_RE = re.compile(
    r"Accel\s+X:(-?\d+)\s+Y:(-?\d+)\s+Z:(-?\d+)\s+"
    r"Gyro\s+X:(-?\d+)\s+Y:(-?\d+)\s+Z:(-?\d+)"
)


def load(path):
    samples = []
    with open(path, errors="ignore") as f:
        for line in f:
            m = LINE_RE.search(line)
            if m:
                samples.append(tuple(int(g) for g in m.groups()))
    return samples


def features_per_2s(samples):
    """Per-2-second means: (accZ, |accXY|) — swivel-invariant tilt features."""
    out = []
    for s in range(len(samples) // 200):
        chunk = samples[s * 200:(s + 1) * 200]
        ax = statistics.mean(r[0] for r in chunk)
        ay = statistics.mean(r[1] for r in chunk)
        az = statistics.mean(r[2] for r in chunk)
        out.append((az, (ax * ax + ay * ay) ** 0.5))
    return out


a = features_per_2s(load(sys.argv[1]))
b = features_per_2s(load(sys.argv[2]))[5:-3]  # trim sit-down burst & keyboard reach

za = [z for z, _ in a]; xya = [x for _, x in a]
zb = [z for z, _ in b]; xyb = [x for _, x in b]

print("EMPTY   (per-2s):  accZ  median=%.0f  range=[%.0f, %.0f]   |accXY| median=%.0f  range=[%.0f, %.0f]"
      % (statistics.median(za), min(za), max(za), statistics.median(xya), min(xya), max(xya)))
print("SEATED  (per-2s):  accZ  median=%.0f  range=[%.0f, %.0f]   |accXY| median=%.0f  range=[%.0f, %.0f]"
      % (statistics.median(zb), min(zb), max(zb), statistics.median(xyb), min(xyb), max(xyb)))

dz = statistics.median(zb) - statistics.median(za)
dxy = statistics.median(xyb) - statistics.median(xya)
print(f"\nShift when seated:  accZ {dz:+.0f} counts   |accXY| {dxy:+.0f} counts")
print(f"Tilt angle change: ~{abs(dxy) / 16384 * 57.3:.2f} degrees" )
