"""Live occupancy from tools/occupancy_model.py. The sit-down/stand-up test.

Prints one line per state change, per chair, with the wall-clock time, so a
sit/stand test can be scored by reading the output against what you actually
did. Between changes it prints a periodic status row per chair so a silent
system can be told apart from a stalled one.

This is the model the scorer scores. tools/watch_occupancy.py imports the OLD
confidence-and-decay model out of live_plot.py and is kept only for comparing
against it; live_plot.py itself has not been migrated yet. Use this one to
judge the rebuilt model.

Usage:
  venv/bin/python tools/watch_model.py
  venv/bin/python tools/watch_model.py --chairs 2
  venv/bin/python tools/watch_model.py --status-every 5
"""

import argparse
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from occupancy_model import ChairModel      # noqa: E402
import receiver_parse as rp                 # noqa: E402

LOG = Path.home() / "motion_log.txt"


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--chairs", default="", help="comma list, default all seen")
    ap.add_argument("--status-every", type=float, default=10.0,
                    help="seconds between status rows (0 disables)")
    ap.add_argument("--log", default=str(LOG))
    args = ap.parse_args()

    want = {int(c) for c in args.chairs.split(",") if c.strip()}
    models, last_state, changes = {}, {}, []
    degraded, bad_seen = set(), {}
    t_status = time.time()

    print(f"watching {args.log}   (Ctrl+C for a summary)")
    print("waiting for packets...\n")

    try:
        for line in rp.follow(args.log):
            pkt = rp.parse(line)
            if pkt is None:
                continue
            chair = pkt["chair"]
            if want and chair not in want:
                continue

            if pkt["fmt"] == "bad":
                # Sender and receiver disagree on packet length. Report it once
                # per chair: it means that chair has not been reflashed, and it
                # would otherwise look identical to a flat battery.
                if chair not in bad_seen:
                    print(f"  chair {chair}: BAD PACKET len:{pkt['length']} "
                          f"- this chair still runs the old firmware, reflash it")
                bad_seen[chair] = bad_seen.get(chair, 0) + 1
                continue
            if pkt["fmt"] != "sum":
                continue                    # raw 100Hz sender, not summarised

            if pkt["yawSum"] is None and chair not in degraded:
                print(f"  chair {chair}: no Peak/YawS fields, model runs "
                      f"DEGRADED (no impulse path, no swivel gate)")
                degraded.add(chair)

            m = models.setdefault(chair, ChairModel())
            t = time.time()
            m.update(t, pkt["stdX"], pkt["stdY"], pkt["stdZ"],
                     pkt["peak"] or 0, pkt["yawSum"], pkt["yawN"],
                     pkt["gyroZ"])

            was = last_state.get(chair)
            if was != m.occupied:
                last_state[chair] = m.occupied
                if was is not None:
                    changes.append((t, chair, m.occupied, m.reason))
                    state = "OCCUPIED" if m.occupied else "FREE    "
                    print(f"{time.strftime('%H:%M:%S')}  chair {chair}  "
                          f"{state}  vote={m.vote_frac:.2f} "
                          f"yaw={m.yaw_deg:.1f}deg peak={m.last_peak:<6} "
                          f"({m.reason})")

            if args.status_every and time.time() - t_status >= args.status_every:
                t_status = time.time()
                row = "  ".join(
                    f"c{c}:{'OCC' if mm.occupied else '---'}"
                    f"/v{mm.vote_frac:.2f}/y{mm.yaw_deg:.1f}"
                    for c, mm in sorted(models.items()))
                print(f"{time.strftime('%H:%M:%S')}  {row}")
    except KeyboardInterrupt:
        pass

    print(f"\n{len(changes)} state changes")
    for t, chair, occ, reason in changes:
        print(f"  {time.strftime('%H:%M:%S', time.localtime(t))}  chair {chair}  "
              f"{'OCCUPIED' if occ else 'FREE':<9} {reason}")
    if bad_seen:
        print("\nchairs sending the wrong packet length (need reflashing): "
              + ", ".join(f"{c} ({n} packets)" for c, n in sorted(bad_seen.items())))


if __name__ == "__main__":
    main()
