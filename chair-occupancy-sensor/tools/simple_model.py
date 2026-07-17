"""Simplest-possible occupancy metric analysis.

Metric per sample: max over the 3 gyro axes of |sample - previous sample|.
One subtraction, no baseline, no windows. This script shows how well that
single number separates the labeled phases.
"""

import csv
import statistics
import sys
from collections import defaultdict

path = sys.argv[1]

by_label = defaultdict(list)  # label -> list of per-sample deltas
prev = None
with open(path) as f:
    for row in csv.DictReader(f):
        g = (int(row["gyroX"]), int(row["gyroY"]), int(row["gyroZ"]))
        if prev is not None:
            delta = max(abs(g[i] - prev[i]) for i in range(3))
            by_label[row["label"]].append(delta)
        prev = g

print(f"{'label':>14} {'n':>6} {'median':>7} {'p90':>6} {'p99':>7} {'max':>7}")
for label in ["empty", "nearby", "seated_still", "seated_active",
              "sit_down", "stand_up", "bump"]:
    d = by_label[label]
    d_sorted = sorted(d)
    p90 = d_sorted[int(len(d) * 0.90)]
    p99 = d_sorted[int(len(d) * 0.99)]
    print(f"{label:>14} {len(d):>6} {statistics.median(d):>7.0f} {p90:>6} {p99:>7} {max(d):>7}")

# How often does each label exceed candidate thresholds?
print("\nFraction of samples exceeding threshold:")
thresholds = [100, 200, 300, 500, 800, 1200]
print(f"{'label':>14} " + " ".join(f"{t:>7}" for t in thresholds))
for label in ["empty", "nearby", "seated_still", "seated_active",
              "sit_down", "stand_up", "bump"]:
    d = by_label[label]
    fracs = [sum(1 for x in d if x > t) / len(d) for t in thresholds]
    print(f"{label:>14} " + " ".join(f"{f:>7.4f}" for f in fracs))
