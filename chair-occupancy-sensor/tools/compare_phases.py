"""Compare per-second activity distributions between two labeled recordings
(empty chair vs sitting still) to find a discriminating threshold."""

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


def per_second_stats(samples):
    """Per-second max-across-axes std-dev, separately for accel and gyro."""
    out = []
    for s in range(len(samples) // 100):
        chunk = samples[s * 100:(s + 1) * 100]
        cols = list(zip(*chunk))
        acc = max(statistics.pstdev(cols[j]) for j in (0, 1, 2))
        gyr = max(statistics.pstdev(cols[j]) for j in (3, 4, 5))
        out.append((acc, gyr))
    return out


def describe(name, vals):
    q = statistics.quantiles(vals, n=20)
    print(f"  {name}: min={min(vals):.0f}  median={statistics.median(vals):.0f}  "
          f"p75={q[14]:.0f}  p90={q[17]:.0f}  p95={q[18]:.0f}  max={max(vals):.0f}")


a = per_second_stats(load(sys.argv[1]))
b_all = per_second_stats(load(sys.argv[2]))
# Trim first 10s of B (sit-down burst) and last 5s (reaching for keyboard).
b = b_all[10:-5]

print(f"PHASE A - empty ({len(a)}s):")
describe("gyro std", [g for _, g in a])
describe("accel std", [ac for ac, _ in a])

print(f"\nPHASE B - sitting still, edges trimmed ({len(b)}s):")
describe("gyro std", [g for _, g in b])
describe("accel std", [ac for ac, _ in b])

print("\nPer-second gyro std, phase B timeline (first 90s):")
for i, (ac, g) in enumerate(b_all[:90]):
    bar = "#" * min(60, int(g / 10))
    print(f"  {i:>3} {g:>7.0f} {bar}")
