"""Replay a labeled session through the confidence-decay model and score it.

Model (must match live_plot.py):
  person-like motion (ratio test OR big-delta test) -> confidence = 100
  no motion -> confidence decays linearly to 0 over CONFIDENCE_DECAY_SECONDS
  occupied = confidence > OCCUPIED_WHEN_ABOVE

Works with both the v1 CSV (no surface column) and the v2 two-surface CSV.
Scores per surface where available. Usage:
  venv/bin/python replay_simple.py labeled_session_<ts>.csv
"""

import csv
import statistics
import sys
from collections import defaultdict

# ---- constants (keep in sync with live_plot.py) ----------------------------
CONFIDENCE_MAX = 100.0
CONFIDENCE_DECAY_SECONDS = 90.0  # slow fallback decay (presence is sticky)
OCCUPIED_WHEN_ABOVE = 5.0
Z_MOTION_THRESHOLD_RAW = 15
RATIO_THRESHOLD = 0.65
BIG_DELTA_RAW = 3000
BIG_DELTA_DEBOUNCE = 3
DEPART_BURST_STD_RAW = 250   # any-axis 1s std above this = possible departure jolt
DEPART_QUIET_STD_RAW = 16    # all axes below this = empty-chair-grade silence
DEPART_WINDOW_SECONDS = 5    # silence must arrive within this many s of the burst
DEPART_DRAIN_SECONDS = 2.0   # confidence drains to 0 this fast once confirmed
# -----------------------------------------------------------------------------

# Prefix-matched so this works on both the original session (sit_down,
# seated_active, seated_still, stand_up) and the follow-up stand-up session
# (sit_down_normal/slow/quick, stand_up_normal/slow/quick, jerk_freeze,
# partial_rise — all seated states except stand_up_*, which is a transition).
OCCUPIED_PREFIXES = ("sit_down", "seated", "jerk_freeze", "partial_rise")
FREE_LABELS = {"empty", "nearby", "walk_close", "walk_far", "walk_fast",
               "walk_behind", "stand_near", "stomp_near", "drop_near", "bump"}
SKIP_PREFIXES = ("stand_up",)  # transition phase, not scored


def classify(label):
    if any(label.startswith(p) for p in SKIP_PREFIXES):
        return "skip"
    if any(label.startswith(p) for p in OCCUPIED_PREFIXES):
        return "occupied"
    if label in FREE_LABELS:
        return "free"
    return "skip"

rows = list(csv.DictReader(open(sys.argv[1])))
t0 = float(rows[0]["t"])
has_surface = "surface" in rows[0]

seconds = defaultdict(lambda: {"gx": [], "gy": [], "gz": [], "deltas": [],
                               "labels": set(), "surface": ""})
prev = None
for r in rows:
    g = (int(r["gyroX"]), int(r["gyroY"]), int(r["gyroZ"]))
    sec = int(float(r["t"]) - t0)
    d = seconds[sec]
    d["labels"].add(r["label"])
    d["surface"] = r.get("surface", "")
    d["gx"].append(g[0]); d["gy"].append(g[1]); d["gz"].append(g[2])
    if prev is not None:
        d["deltas"].append(max(abs(g[i] - prev[i]) for i in range(3)))
    prev = g

# Run the confidence model over seconds.
last_motion = None
burst_at = None
departed_at = None
depart_base = 0.0
prev_conf = 0.0
stats = defaultdict(lambda: [0, 0])       # (surface, label) -> [correct, total]
trigger_counts = defaultdict(lambda: [0, 0])  # fresh triggers per (surface, label)
smax_by_sec = {}
for sec in sorted(seconds):
    d = seconds[sec]
    motion = False
    smax = 999.0
    if len(d["gz"]) >= 5:
        sx = statistics.pstdev(d["gx"])
        sy = statistics.pstdev(d["gy"])
        sz = statistics.pstdev(d["gz"])
        smax = max(sx, sy, sz)
        ratio_test = (sz > Z_MOTION_THRESHOLD_RAW
                      and sz / (sx + sy + 1) > RATIO_THRESHOLD)
        big_test = sum(1 for x in d["deltas"] if x > BIG_DELTA_RAW) >= BIG_DELTA_DEBOUNCE
        motion = ratio_test or big_test
    smax_by_sec[sec] = smax
    if motion:
        last_motion = sec
        departed_at = None  # person still here — cancel any drain
    # Departure: burst then >= 2 consecutive empty-chair-grade quiet seconds
    # soon after -> drain confidence to 0 over DEPART_DRAIN_SECONDS.
    if smax > DEPART_BURST_STD_RAW:
        burst_at = sec
    elif (burst_at is not None and sec - burst_at >= 2
          and sec - burst_at <= DEPART_WINDOW_SECONDS
          and smax_by_sec.get(sec - 1, 999) < DEPART_QUIET_STD_RAW
          and smax < DEPART_QUIET_STD_RAW):
        departed_at = sec
        depart_base = prev_conf
        burst_at = None
    if last_motion is None:
        conf = 0.0
    elif departed_at is not None:
        conf = max(0.0, depart_base * (1.0 - (sec - departed_at) / DEPART_DRAIN_SECONDS))
    else:
        conf = CONFIDENCE_MAX * max(0.0, 1.0 - (sec - last_motion) / CONFIDENCE_DECAY_SECONDS)
    prev_conf = conf
    occupied = conf > OCCUPIED_WHEN_ABOVE

    if len(d["labels"]) != 1:
        continue
    label = next(iter(d["labels"]))
    key = (d["surface"], label)
    trigger_counts[key][0] += motion
    trigger_counts[key][1] += 1
    kind = classify(label)
    if kind == "occupied":
        stats[key][0] += occupied
        stats[key][1] += 1
    elif kind == "free":
        stats[key][0] += (not occupied)
        stats[key][1] += 1

print(f"model: zfloor {Z_MOTION_THRESHOLD_RAW}, ratio {RATIO_THRESHOLD}, "
      f"bigΔ {BIG_DELTA_RAW}/{BIG_DELTA_DEBOUNCE}, decay {CONFIDENCE_DECAY_SECONDS:.0f}s, "
      f"cutoff {OCCUPIED_WHEN_ABOVE:.0f}\n")

surfaces = sorted({s for s, _ in stats})
for surface in surfaces:
    print(f"=== surface: {surface or '(none)'} ===")
    print(f"{'label':>15} {'occupancy-correct':>18} {'fresh triggers':>15}")
    labels = sorted({l for s, l in stats if s == surface})
    for label in labels:
        c, n = stats[(surface, label)]
        tc, tn = trigger_counts[(surface, label)]
        flag = ""
        if label in FREE_LABELS and tc:
            flag = "  <-- false triggers"
        print(f"{label:>15} {c:>8}/{n:<8} {tc:>7}/{tn:<7}{flag}")
    print()
