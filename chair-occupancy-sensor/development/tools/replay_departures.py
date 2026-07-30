"""Event-level backtest of the departure (stand-up) detector.

Replays a labeled session through the EXACT live_plot.py occupancy model
(0.1s steps, trailing-1s window, same state machine) and scores it per
EVENT rather than per second:

  - every stand_up_* phase: did the banner reach FREE within 20s of the
    phase start, and how fast?
  - every seated phase (seated_*, jerk_freeze, partial_rise): any FREE
    reading more than 2.5s into the segment is a FALSE FREE. (The first
    2.5s are excluded because carpet absorbs the sit-down plop and arrival
    detection lags ~2-3s — a known, separate limitation.)

Why gaps get extended: the collection protocol only left ~3s of 'empty'
after each stand-up before cueing the next sit-down — too short to score a
detector whose full latency is 5-12s, and unlike real use where the chair
stays empty for minutes. So every empty segment that directly follows a
stand_up_* is padded to 30s with REAL empty-chair samples looped from the
longest empty segment on the same surface.

Usage:  venv/bin/python tools/replay_departures.py data/<session>.csv [more.csv]
"""

import csv
import statistics
import sys
from collections import deque

# ---- constants (keep in sync with live_plot.py) ----------------------------
CONFIDENCE_MAX = 100.0
CONFIDENCE_DECAY_SECONDS = 90.0
OCCUPIED_WHEN_ABOVE = 5.0
Z_MOTION_THRESHOLD_RAW = 15
RATIO_THRESHOLD = 0.65
BIG_DELTA_RAW = 3000
BIG_DELTA_DEBOUNCE = 3
DEPART_BURST_STD_RAW = 250
DEPART_QUIET_STD_RAW = 16
DEPART_QUIET_FRACTION = 0.65
DEPART_QUIET_WINDOW = 4.0
DEPART_PAIR_WINDOW = 12.0
DEPART_DRAIN_SECONDS = 0.2
LONG_QUIET_WINDOW = 15.0
LONG_QUIET_FRACTION = 0.80
# -----------------------------------------------------------------------------

EXTEND_GAPS_TO = 30.0   # post-stand-up empty padding (seconds)
HIT_WITHIN = 20.0       # stand-up counts as detected if FREE within this
SEATED_GRACE = 2.5      # ignore FREE this early in a seated segment (carpet lag)


def load(path):
    rows = []
    for r in csv.DictReader(open(path)):
        rows.append((float(r["t"]), int(r["phase_idx"]), r["label"],
                     r.get("surface", ""),
                     int(r["gyroX"]), int(r["gyroY"]), int(r["gyroZ"])))
    rows.sort(key=lambda x: x[0])
    return rows


def segments_of(rows):
    segs = []
    s, pi, lab, sur = rows[0][0], rows[0][1], rows[0][2], rows[0][3]
    for r in rows[1:]:
        if r[1] != pi:
            segs.append((s, r[0], lab, sur))
            s, pi, lab, sur = r[0], r[1], r[2], r[3]
    segs.append((s, rows[-1][0] + 0.01, lab, sur))
    return segs


def extend_gaps(rows):
    """Pad each post-stand-up empty segment to EXTEND_GAPS_TO seconds with
    looped real empty-chair samples from the same surface."""
    segs = segments_of(rows)
    pools = {}  # surface -> (duration, [(dt, gx, gy, gz), ...]) longest empty seg
    for s, e, lab, sur in segs:
        if lab != "empty":
            continue
        if sur not in pools or (e - s) > pools[sur][0]:
            pools[sur] = (e - s, [(r[0] - s, r[4], r[5], r[6])
                                  for r in rows if s <= r[0] < e])
    out = []
    shift = 0.0
    for i, (s, e, lab, sur) in enumerate(segs):
        for r in rows:
            if s <= r[0] < e:
                out.append((r[0] + shift, r[1], r[2], r[3], r[4], r[5], r[6]))
        prev_lab = segs[i - 1][2] if i > 0 else ""
        if lab == "empty" and prev_lab.startswith("stand_up") and (e - s) < EXTEND_GAPS_TO:
            pad = EXTEND_GAPS_TO - (e - s)
            plen, pool = pools[sur]
            t_cursor = e + shift
            padded = 0.0
            while padded < pad:
                for dt, gx, gy, gz in pool:
                    if padded + dt > pad:
                        break
                    out.append((t_cursor + dt, -999, "empty", sur, gx, gy, gz))
                t_cursor += min(plen, pad - padded)
                padded += plen
            shift += pad
    out.sort(key=lambda x: x[0])
    return out


def replay(rows):
    """Exact live_plot.py model. Returns [(t, confidence, occupied)]."""
    win = deque()
    deltas = deque()
    quiet_hist = deque()
    ri = 0
    prev_g = None
    st = dict(last_move=None, burst_at=None, departed_at=None,
              depart_base=0.0, conf=0.0)
    trace = []
    sim = rows[0][0]
    while sim <= rows[-1][0]:
        while ri < len(rows) and rows[ri][0] <= sim:
            t, pi, lab, sur, gx, gy, gz = rows[ri]
            win.append((t, gx, gy, gz))
            if prev_g is not None:
                deltas.append((t, max(abs(gx - prev_g[0]), abs(gy - prev_g[1]),
                                      abs(gz - prev_g[2]))))
            prev_g = (gx, gy, gz)
            ri += 1
        while win and win[0][0] < sim - 1.0:
            win.popleft()
        while deltas and deltas[0][0] < sim - 1.0:
            deltas.popleft()

        motion = False
        smax = None
        if len(win) >= 5:
            sx = statistics.pstdev([w[1] for w in win])
            sy = statistics.pstdev([w[2] for w in win])
            sz = statistics.pstdev([w[3] for w in win])
            smax = max(sx, sy, sz)
            ratio = (sz > Z_MOTION_THRESHOLD_RAW
                     and sz / (sx + sy + 1) > RATIO_THRESHOLD)
            big = sum(1 for _, d in deltas if d > BIG_DELTA_RAW) >= BIG_DELTA_DEBOUNCE
            motion = ratio or big

        if motion:
            st["last_move"] = sim
            st["departed_at"] = None

        if smax is not None:
            quiet_hist.append((sim, smax < DEPART_QUIET_STD_RAW))
            cutoff = sim - max(DEPART_QUIET_WINDOW, LONG_QUIET_WINDOW)
            while quiet_hist and quiet_hist[0][0] < cutoff:
                quiet_hist.popleft()
            if smax > DEPART_BURST_STD_RAW:
                st["burst_at"] = sim
            if st["departed_at"] is None:
                short = [q for t, q in quiet_hist if t >= sim - DEPART_QUIET_WINDOW]
                frac_short = sum(short) / len(short) if short else 0.0
                frac_long = sum(q for _, q in quiet_hist) / len(quiet_hist)
                paired = (st["burst_at"] is not None
                          and sim - st["burst_at"] <= DEPART_PAIR_WINDOW)
                warmed_up = sim - quiet_hist[0][0] >= LONG_QUIET_WINDOW - 1.0
                if ((paired and frac_short >= DEPART_QUIET_FRACTION)
                        or (warmed_up and frac_long >= LONG_QUIET_FRACTION
                            and st["conf"] > 0)):
                    st["departed_at"] = sim
                    st["depart_base"] = st["conf"]
                    st["burst_at"] = None

        last, dep = st["last_move"], st["departed_at"]
        if last is None:
            conf = 0.0
        elif dep is not None:
            conf = max(0.0, st["depart_base"] * (1.0 - (sim - dep) / DEPART_DRAIN_SECONDS))
        else:
            conf = CONFIDENCE_MAX * max(0.0, 1.0 - (sim - last) / CONFIDENCE_DECAY_SECONDS)
        st["conf"] = conf
        trace.append((sim, conf, conf > OCCUPIED_WHEN_ABOVE))
        sim += 0.1
    return trace


def score(path):
    rows = extend_gaps(load(path))
    segs = segments_of(rows)
    trace = replay(rows)
    t0 = rows[0][0]

    def sl(a, b):
        return [p for p in trace if a <= p[0] < b]

    print(f"===== {path.split('/')[-1]} (post-stand-up gaps extended to "
          f"{EXTEND_GAPS_TO:.0f}s) =====")
    hits, misses, lats = 0, 0, []
    for s, e, lab, sur in segs:
        if not lab.startswith("stand_up"):
            continue
        free = next((p[0] - s for p in sl(s, s + HIT_WITHIN) if not p[2]), None)
        if free is None:
            misses += 1
            print(f"  MISS       {sur:>10} {lab:>16} t={s - t0:.0f}s")
        else:
            hits += 1
            lats.append(free)

    false_free = 0
    for s, e, lab, sur in segs:
        if not (lab.startswith("seated") or lab in ("jerk_freeze", "partial_rise")):
            continue
        frees = [p for p in sl(s + SEATED_GRACE, e) if not p[2]]
        if frees:
            false_free += 1
            print(f"  FALSE-FREE {sur:>10} {lab:>16} t={s - t0:.0f}s "
                  f"first at +{frees[0][0] - s:.1f}s ({len(frees)} samples)")

    med = statistics.median(lats) if lats else float("nan")
    p90 = sorted(lats)[int(0.9 * (len(lats) - 1))] if lats else float("nan")
    mx = max(lats) if lats else float("nan")
    print(f"  stand-ups FREE'd: {hits}/{hits + misses}   "
          f"latency median {med:.1f}s  p90 {p90:.1f}s  max {mx:.1f}s   "
          f"false-frees: {false_free}\n")


if __name__ == "__main__":
    for f in sys.argv[1:]:
        score(f)
