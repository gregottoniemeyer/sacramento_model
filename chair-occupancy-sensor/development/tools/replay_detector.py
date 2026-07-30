"""Replay a recorded session through the occupancy detector to sanity-check
the thresholds before running live. Prints every state change."""

import re
import statistics
import sys

LINE_RE = re.compile(
    r"Accel\s+X:(-?\d+)\s+Y:(-?\d+)\s+Z:(-?\d+)\s+"
    r"Gyro\s+X:(-?\d+)\s+Y:(-?\d+)\s+Z:(-?\d+)"
)

GYRO_MOTION_STD = 250    # raw counts, matches live_plot.py's 250/131 °/s
ACCEL_MOTION_STD = 2500  # raw counts
SILENCE_TIMEOUT = 30.0   # seconds
SAMPLE_RATE = 100

path = sys.argv[1] if len(sys.argv) > 1 else "experiment1.txt"
samples = []
with open(path, errors="ignore") as f:
    for line in f:
        m = LINE_RE.search(line)
        if m:
            samples.append(tuple(int(g) for g in m.groups()))

occupied = False
last_motion = None
changes = []
for s in range(len(samples) // SAMPLE_RATE):
    t = float(s)
    chunk = samples[s * SAMPLE_RATE:(s + 1) * SAMPLE_RATE]
    cols = list(zip(*chunk))
    accel_act = max(statistics.pstdev(cols[j]) for j in (0, 1, 2))
    gyro_act = max(statistics.pstdev(cols[j]) for j in (3, 4, 5))
    if gyro_act > GYRO_MOTION_STD or accel_act > ACCEL_MOTION_STD:
        last_motion = t
    new_state = occupied
    if last_motion is not None:
        new_state = (t - last_motion) < SILENCE_TIMEOUT
    if new_state != occupied:
        occupied = new_state
        changes.append((t, "OCCUPIED" if occupied else "EMPTY"))

print(f"replayed {len(samples)//SAMPLE_RATE}s of data, state changes:")
for t, state in changes:
    print(f"  t={t:>5.0f}s  ->  {state}")
