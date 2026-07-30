"""Grid-search the simple model's three constants against the labeled session.

Scoring treats labels differently:
  empty/nearby seconds:  must be EMPTY   (false-occupied is the worst failure)
  seated_* / sit_down:   must be OCCUPIED
  stand_up/bump:         not scored (transitions / expected-brief errors)
"""

import csv
import sys
from collections import defaultdict

rows = list(csv.DictReader(open(sys.argv[1])))
t0 = float(rows[0]["t"])

# Precompute per-second: label set + delta list (so grid search is fast).
sec_deltas = defaultdict(list)
sec_labels = defaultdict(set)
prev = None
for row in rows:
    g = (int(row["gyroX"]), int(row["gyroY"]), int(row["gyroZ"]))
    sec = int(float(row["t"]) - t0)
    sec_labels[sec].add(row["label"])
    if prev is not None:
        sec_deltas[sec].append(max(abs(g[i] - prev[i]) for i in range(3)))
    prev = g

OCC = {"sit_down", "seated_active", "seated_still"}
EMP = {"empty", "nearby"}


def run(delta_t, debounce, hold):
    last_move = None
    per_group = defaultdict(lambda: [0, 0])
    for sec in sorted(sec_deltas):
        events = sum(1 for d in sec_deltas[sec] if d > delta_t)
        if events >= debounce:
            last_move = sec
        occupied = last_move is not None and (sec - last_move) < hold
        labels = sec_labels[sec]
        if len(labels) != 1:
            continue
        label = next(iter(labels))
        if label in OCC:
            per_group["occupied-when-seated"][0] += occupied
            per_group["occupied-when-seated"][1] += 1
        elif label in EMP:
            per_group["empty-when-empty"][0] += (not occupied)
            per_group["empty-when-empty"][1] += 1
    return per_group


print(f"{'delta':>6} {'deb':>4} {'hold':>5} | {'seated OK':>10} {'empty OK':>10} {'combined':>9}")
results = []
for delta_t in [300, 400, 500, 700, 900]:
    for debounce in [2, 3, 5]:
        for hold in [10, 15, 20, 25, 30]:
            g = run(delta_t, debounce, hold)
            so = g["occupied-when-seated"]
            eo = g["empty-when-empty"]
            seated_pct = so[0] / so[1]
            empty_pct = eo[0] / eo[1]
            # False-occupied weighted 2x: an always-occupied display is useless.
            combined = (seated_pct + 2 * empty_pct) / 3
            results.append((combined, delta_t, debounce, hold, seated_pct, empty_pct))

results.sort(reverse=True)
for combined, delta_t, debounce, hold, seated_pct, empty_pct in results[:12]:
    print(f"{delta_t:>6} {debounce:>4} {hold:>5} | {seated_pct:>9.0%} {empty_pct:>9.0%} {combined:>8.0%}")
