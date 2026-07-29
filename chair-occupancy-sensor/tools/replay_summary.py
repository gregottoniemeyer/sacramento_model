"""Backtest the battery-saving summary firmware BEFORE flashing it to anything.

The battery redesign stops radioing every 100Hz sample and instead computes
the occupancy model's input statistics on the sender, transmitting them a few
times a second. The obvious worry is that this quietly degrades detection.
This tool answers that from the labeled recordings already in data/, so the
question is settled offline rather than discovered in the gallery.

What it simulates, faithfully:
  - The sender keeps sampling the MPU-6050 at 100Hz and maintains a trailing
    1.0s window, exactly the window live_plot.py uses today.
  - Every TX period it computes per-axis gyro std-dev over that window plus a
    count of consecutive-sample gyro jumps above BIG_DELTA_RAW, and sends only
    those numbers.
  - The dashboard's state machine then steps ONCE PER PACKET instead of on a
    100ms tick, because packets are now the only thing that arrives.

Note what does NOT change: the statistics themselves are computed over the
same 1.0s window at the same 100Hz resolution, so every tuned threshold in
live_plot.py keeps its meaning. The only thing the radio reduction costs is
how often the state machine is re-evaluated. That is the effect this measures.

Scoring is identical to tools/replay_departures.py (same gap extension, same
event definitions) so the numbers are directly comparable to the 100Hz
baseline that file prints.

Usage:
  venv/bin/python tools/replay_summary.py data/*.csv
  venv/bin/python tools/replay_summary.py --tx-hz 2,4,5,10 data/<session>.csv
"""

import argparse
import random
import statistics
import sys
from collections import deque
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from replay_departures import (  # noqa: E402  (path set above)
    CONFIDENCE_MAX,
    CONFIDENCE_DECAY_SECONDS,
    OCCUPIED_WHEN_ABOVE,
    Z_MOTION_THRESHOLD_RAW,
    RATIO_THRESHOLD,
    BIG_DELTA_RAW,
    BIG_DELTA_DEBOUNCE,
    DEPART_BURST_STD_RAW,
    DEPART_QUIET_STD_RAW,
    DEPART_QUIET_FRACTION,
    DEPART_QUIET_WINDOW,
    DEPART_PAIR_WINDOW,
    DEPART_DRAIN_SECONDS,
    LONG_QUIET_WINDOW,
    LONG_QUIET_FRACTION,
    EXTEND_GAPS_TO,
    HIT_WITHIN,
    SEATED_GRACE,
    load,
    segments_of,
    extend_gaps,
    replay as replay_100hz,
)

# The window the sender accumulates over before computing statistics. Kept at
# 1.0s deliberately: it is what every threshold in live_plot.py was tuned
# against, so holding it fixed means the radio change is the ONLY variable.
SENDER_WINDOW = 1.0

# The firmware's std-dev fields are uint16 raw counts. A genuinely violent
# jolt can exceed that, and it would wrap to a small number -- which would
# read as QUIET and could falsely release a chair. The firmware saturates
# instead, so the simulation must saturate identically or it will be
# measuring a system nobody is going to flash.
STD_FIELD_MAX = 65535


def summarize(rows, tx_hz, drop=0.0, seed=1):
    """Produce the packet stream the RECEIVER would actually see.

    Returns [(t, sx, sy, sz, big_count)] -- one entry per radio packet that
    survived the link.

    `drop` simulates ESP-NOW packet loss. This matters far more at a low
    transmit rate than it did at 100Hz: losing 20% of 100 packets a second is
    invisible, while losing 20% of 5 packets a second directly thins the only
    thing driving the state machine. A transmit rate is only safe if it still
    scores clean with realistic loss, so the rate is chosen with margin here
    rather than at the knee.
    """
    rng = random.Random(seed)
    period = 1.0 / tx_hz
    win = deque()
    deltas = deque()
    packets = []
    ri = 0
    prev_g = None
    # First transmission happens one full window in, since before that the
    # sender has nothing meaningful to summarize.
    next_tx = rows[0][0] + SENDER_WINDOW

    while next_tx <= rows[-1][0]:
        while ri < len(rows) and rows[ri][0] <= next_tx:
            t, _pi, _lab, _sur, gx, gy, gz = rows[ri]
            win.append((t, gx, gy, gz))
            if prev_g is not None:
                deltas.append((t, max(abs(gx - prev_g[0]),
                                      abs(gy - prev_g[1]),
                                      abs(gz - prev_g[2]))))
            prev_g = (gx, gy, gz)
            ri += 1
        while win and win[0][0] < next_tx - SENDER_WINDOW:
            win.popleft()
        while deltas and deltas[0][0] < next_tx - SENDER_WINDOW:
            deltas.popleft()

        # Fewer than 5 samples in a window means the sensor is not delivering;
        # the firmware sends the packet anyway with a zero sample count so the
        # receiver can see the fault rather than seeing nothing at all.
        if len(win) >= 5 and rng.random() >= drop:
            sx = statistics.pstdev([w[1] for w in win])
            sy = statistics.pstdev([w[2] for w in win])
            sz = statistics.pstdev([w[3] for w in win])
            big = sum(1 for _, d in deltas if d > BIG_DELTA_RAW)
            packets.append((next_tx,
                            min(sx, STD_FIELD_MAX),
                            min(sy, STD_FIELD_MAX),
                            min(sz, STD_FIELD_MAX),
                            min(big, 255)))
        next_tx += period

    return packets


def replay_summary(packets):
    """The live_plot.py state machine, stepped once per received packet.

    Byte-for-byte the same logic as replay_departures.replay() below the point
    where the statistics arrive -- the difference is purely that `sim` advances
    by the transmit period instead of the 0.1s dashboard tick, and sx/sy/sz
    come off the wire instead of being computed here.
    """
    quiet_hist = deque()
    st = dict(last_move=None, burst_at=None, departed_at=None,
              depart_base=0.0, conf=0.0)
    trace = []

    for sim, sx, sy, sz, big in packets:
        smax = max(sx, sy, sz)
        ratio = (sz > Z_MOTION_THRESHOLD_RAW
                 and sz / (sx + sy + 1) > RATIO_THRESHOLD)
        motion = ratio or big >= BIG_DELTA_DEBOUNCE

        if motion:
            st["last_move"] = sim
            st["departed_at"] = None

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
            conf = max(0.0, st["depart_base"]
                       * (1.0 - (sim - dep) / DEPART_DRAIN_SECONDS))
        else:
            conf = CONFIDENCE_MAX * max(
                0.0, 1.0 - (sim - last) / CONFIDENCE_DECAY_SECONDS)
        st["conf"] = conf
        trace.append((sim, conf, conf > OCCUPIED_WHEN_ABOVE))

    return trace


def evaluate(rows, segs, trace):
    """Same event definitions as replay_departures.score()."""
    def sl(a, b):
        return [p for p in trace if a <= p[0] < b]

    hits, misses, lats, detail = 0, 0, [], []
    for s, e, lab, sur in segs:
        if not lab.startswith("stand_up"):
            continue
        free = next((p[0] - s for p in sl(s, s + HIT_WITHIN) if not p[2]), None)
        if free is None:
            misses += 1
            detail.append(f"MISS {sur} {lab}")
        else:
            hits += 1
            lats.append(free)

    false_free = []
    for s, e, lab, sur in segs:
        if not (lab.startswith("seated") or lab in ("jerk_freeze", "partial_rise")):
            continue
        frees = [p for p in sl(s + SEATED_GRACE, e) if not p[2]]
        if frees:
            false_free.append((sur, lab, s, frees[0][0] - s, len(frees)))

    return {
        "hits": hits,
        "total": hits + misses,
        "lats": lats,
        "false_free": false_free,
        "detail": detail,
    }


def fmt(res):
    lats = res["lats"]
    if lats:
        med = statistics.median(lats)
        p90 = sorted(lats)[int(0.9 * (len(lats) - 1))]
        mx = max(lats)
    else:
        med = p90 = mx = float("nan")
    return (f"{res['hits']}/{res['total']} stand-ups   "
            f"median {med:4.1f}s  p90 {p90:4.1f}s  max {mx:4.1f}s   "
            f"false-frees {len(res['false_free'])}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("sessions", nargs="+")
    ap.add_argument("--tx-hz", default="2,4,5,10",
                    help="comma-separated transmit rates to compare")
    ap.add_argument("--drop", default="0",
                    help="comma-separated packet-loss fractions, e.g. 0,0.1,0.2")
    ap.add_argument("--seeds", type=int, default=1,
                    help="loss draws to average over (>1 only useful with --drop)")
    args = ap.parse_args()
    rates = [float(x) for x in args.tx_hz.split(",")]
    drops = [float(x) for x in args.drop.split(",")]
    combos = [(r, d) for r in rates for d in drops]

    totals = {c: {"hits": 0, "total": 0, "lats": [], "ff": 0} for c in combos}
    base_totals = {"hits": 0, "total": 0, "lats": [], "ff": 0}

    for path in args.sessions:
        rows = extend_gaps(load(path))
        segs = segments_of(rows)
        print(f"===== {Path(path).name} =====")

        base = evaluate(rows, segs, replay_100hz(rows))
        print(f"  {'100Hz baseline':>18}  {fmt(base)}")
        base_totals["hits"] += base["hits"]
        base_totals["total"] += base["total"]
        base_totals["lats"] += base["lats"]
        base_totals["ff"] += len(base["false_free"])

        for r, d in combos:
            for seed in range(args.seeds):
                res = evaluate(rows, segs,
                               replay_summary(summarize(rows, r, d, seed)))
                worse = (len(res["false_free"]) > len(base["false_free"])
                         or res["hits"] < base["hits"])
                label = f"{r:g}Hz drop{d:.0%}" + (f" s{seed}" if args.seeds > 1 else "")
                print(f"  {label:>18}  {fmt(res)}"
                      f"{'   <-- WORSE THAN BASELINE' if worse else ''}")
                totals[(r, d)]["hits"] += res["hits"]
                totals[(r, d)]["total"] += res["total"]
                totals[(r, d)]["lats"] += res["lats"]
                totals[(r, d)]["ff"] += len(res["false_free"])
        print()

    print("===== all sessions combined =====")
    def line(name, d):
        med = statistics.median(d["lats"]) if d["lats"] else float("nan")
        mx = max(d["lats"]) if d["lats"] else float("nan")
        return (f"  {name:>18}  {d['hits']}/{d['total']} stand-ups   "
                f"median {med:4.1f}s  max {mx:4.1f}s   false-frees {d['ff']}")
    print(line("100Hz baseline", base_totals))
    for r, d in combos:
        print(line(f"{r:g}Hz drop{d:.0%}", totals[(r, d)]))


if __name__ == "__main__":
    main()
