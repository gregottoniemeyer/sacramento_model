"""Pre-flight check: is every chair mounted at an angle the model can read?

WHY THIS EXISTS
The occupancy model's swivel gate is hard-coded to the sensor's Z axis. See
occupancy_model.py: the ratio test is `std_z / (std_x + std_y + 1)`, and the
yaw integral sums gyroZ. Both assume the sensor's Z axis points along the
chair's axis of rotation, which is true only if the module is mounted flat.

That assumption fails silently, and it has already bitten once. Scoring the
7-chair dataset on 2026-07-29 showed chairs 1 and 6 detecting ZERO sit-downs.
The cause was not a bad board: gravity sat on sensor-Y for those two (56.8 and
88.6 degrees off vertical) while it sat within ~6 degrees of Z for the other
five. The gate was measuring rotation about a horizontal axis and fired on
0.0% of seated windows. Projecting the gyro onto measured gravity instead
recovered them completely (0.0% -> 76.4% and 0.0% -> 95.4%).

There is no error, no warning and no BAD PACKET when this happens. The chair
simply never registers anyone sitting in it. So a remount is a silent way to
break a chair, and Greg may re-tape chairs after 2026-07-31.

Run this BEFORE a validation collection, and after ANY chair is remounted.
Two minutes here can save a 27-minute run that only measures a mounting fault.

WHAT IT MEASURES
Each packet carries the window-mean accelerometer reading, so gravity's
direction in sensor coordinates is already in the data and needs no extra
firmware. With the chair empty and still, that mean vector IS gravity. The
angle between it and the sensor's +Z axis is the number that matters.

Usage:
  venv/bin/python tools/check_mounts.py            # 30s off the live log
  venv/bin/python tools/check_mounts.py --seconds 60
  venv/bin/python tools/check_mounts.py --file data/some_dataset.csv
"""

import argparse
import math
import sys
import time
from collections import defaultdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import receiver_parse as rp  # noqa: E402

LOG = Path.home() / "motion_log.txt"

# Angle of gravity away from the sensor's +Z axis. The bands come from measured
# behaviour on 2026-07-29, not from theory: five chairs within ~6 degrees all
# detected normally, and the two at 56.8 and 88.6 degrees detected nothing at
# all. WARN is set well below the first known failure so a drifting mount is
# caught while it still works.
OK_DEG = 20.0
WARN_DEG = 40.0


def classify(deg):
    if deg < OK_DEG:
        return "OK", "swivel gate reads the right axis"
    if deg < WARN_DEG:
        return "WARN", "tilted; gate still fires but with reduced margin"
    return "FAIL", "gate is measuring a horizontal axis, sit-downs will be missed"


def collect_live(seconds):
    """Mean accelerometer vector per chair, from the live capture."""
    acc = defaultdict(lambda: [0.0, 0.0, 0.0, 0])
    deadline = time.time() + seconds
    print(f"reading {LOG} for {seconds:.0f}s ...")
    print("Keep every chair EMPTY and STILL while this runs.\n")
    for line in rp.follow(LOG):
        pkt = rp.parse(line)
        if pkt and pkt.get("fmt") in ("sum", "raw"):
            a = acc[pkt["chair"]]
            a[0] += pkt["accX"]
            a[1] += pkt["accY"]
            a[2] += pkt["accZ"]
            a[3] += 1
        if time.time() > deadline:
            break
    return acc


def collect_file(path):
    acc = defaultdict(lambda: [0.0, 0.0, 0.0, 0])
    import csv
    with open(path, newline="") as f:
        for row in csv.DictReader(f):
            try:
                c = int(row["chair"])
                a = acc[c]
                a[0] += float(row["accX"])
                a[1] += float(row["accY"])
                a[2] += float(row["accZ"])
                a[3] += 1
            except (KeyError, ValueError, TypeError):
                continue
    return acc


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seconds", type=float, default=30.0)
    ap.add_argument("--file", default="")
    args = ap.parse_args()

    acc = collect_file(args.file) if args.file else collect_live(args.seconds)
    if not acc:
        print("No packets seen. Is the serial capture running into "
              f"{LOG}? See README.md step 2.")
        return 1

    print(f"{'chair':>5}  {'gravity (g)':>22}  {'off +Z':>7}  {'n':>6}  verdict")
    print("-" * 78)
    worst = "OK"
    for c in sorted(acc):
        sx, sy, sz, n = acc[c]
        if n == 0:
            continue
        # 16384 raw = 1 g at the MPU-6050's default +/-2g scale (NOTES.md).
        x, y, z = sx / n / 16384.0, sy / n / 16384.0, sz / n / 16384.0
        mag = math.sqrt(x * x + y * y + z * z)
        if mag < 0.5:
            print(f"{c:>5}  {'|g| = %.2f' % mag:>22}  {'-':>7}  {n:>6}  "
                  "SUSPECT: not 1 g, sensor or mount is wrong")
            worst = "FAIL"
            continue
        deg = math.degrees(math.acos(max(-1.0, min(1.0, abs(z) / mag))))
        verdict, why = classify(deg)
        if verdict == "FAIL" or (verdict == "WARN" and worst == "OK"):
            worst = verdict
        vec = "%+.2f %+.2f %+.2f" % (x, y, z)
        print(f"{c:>5}  {vec:>22}  {deg:>6.1f}  {n:>6}  {verdict}: {why}")

    print()
    if worst == "OK":
        print("All chairs are mounted flat enough for the Z-axis swivel gate.")
        print("Safe to run the validation collection.")
    else:
        print("At least one chair is mounted at an angle the model cannot read.")
        print("Either remount it flat, or project the gyro onto measured")
        print("gravity before running anything that is meant to be trusted.")
        print("The accelerometer means needed for that are already in the")
        print("packet, so it is a tools-side change with no reflash.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
