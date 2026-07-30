"""Analyze a labeled chair-sensor recording: print a per-second activity timeline.

For each second of data (100 samples), computes how much the signal deviated
from its resting baseline — separately for gyro (rotation) and accel (jolts).
"""

import re
import statistics
import sys

LINE_RE = re.compile(
    r"Accel\s+X:(-?\d+)\s+Y:(-?\d+)\s+Z:(-?\d+)\s+"
    r"Gyro\s+X:(-?\d+)\s+Y:(-?\d+)\s+Z:(-?\d+)"
)

path = sys.argv[1] if len(sys.argv) > 1 else "experiment1.txt"
samples = []  # (ax, ay, az, gx, gy, gz)
with open(path, errors="ignore") as f:
    for line in f:
        m = LINE_RE.search(line)
        if m:
            samples.append(tuple(int(g) for g in m.groups()))

print(f"parsed {len(samples)} samples (~{len(samples)//100}s)")

# Baseline = median over the whole recording (robust against motion bursts).
cols = list(zip(*samples))
baseline = [statistics.median(c) for c in cols]
print("baselines  accel:", baseline[:3], " gyro:", baseline[3:])

# Per-second summary: mean & max of |deviation| for accel and gyro combined axes.
print(f"\n{'sec':>4} {'gyro_mean':>10} {'gyro_max':>9} {'acc_mean':>9} {'acc_max':>8}  bar (gyro_mean)")
for s in range(len(samples) // 100):
    chunk = samples[s * 100:(s + 1) * 100]
    gyro_dev = [max(abs(r[j] - baseline[j]) for j in (3, 4, 5)) for r in chunk]
    acc_dev = [max(abs(r[j] - baseline[j]) for j in (0, 1, 2)) for r in chunk]
    gm, gx = statistics.mean(gyro_dev), max(gyro_dev)
    am, ax = statistics.mean(acc_dev), max(acc_dev)
    bar = "#" * min(60, int(gm / 100))
    print(f"{s:>4} {gm:>10.0f} {gx:>9} {am:>9.0f} {ax:>8}  {bar}")
