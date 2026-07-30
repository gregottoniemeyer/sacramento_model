"""Print every occupancy state change, per chair, as it happens.

Built for the sit-down/stand-up test: one person moves between chairs while
this records what the model actually decided and how long it took. The live
dashboard shows the current state beautifully but scrolls the history away,
which is the wrong shape for "did chair 3 release when I stood up, and how
fast?".

Deliberately imports the model from live_plot.py rather than reimplementing
it, so this can never drift from what the installation is actually running.

Usage:
  venv/bin/python tools/watch_occupancy.py
  venv/bin/python tools/watch_occupancy.py --table-every 15

Ctrl+C prints a per-chair summary of every transition seen.
"""

import argparse
import os
import re
import time
from collections import defaultdict
from pathlib import Path

# live_plot builds its figure at import time. Force a headless backend and
# neuter show() so importing it here does not try to open a window.
os.environ.setdefault("MPLBACKEND", "Agg")
import matplotlib.pyplot as _plt  # noqa: E402
_plt.show = lambda *a, **k: None  # noqa: E731

import sys  # noqa: E402
sys.path.insert(0, str(Path(__file__).resolve().parent))
import live_plot as lp  # noqa: E402

LOG = Path.home() / "motion_log.txt"


def follow(path):
    """Yield lines as they are appended, surviving truncation and rotation.

    The truncation case is not theoretical: re-running the serial capture with
    `>` instead of `>>` replaces the file under any reader holding it open,
    and the documented symptom is a dashboard that silently shows stale data
    forever. Detect it by watching for the file shrinking.
    """
    f = None
    inode = None
    while True:
        try:
            st = path.stat()
        except FileNotFoundError:
            time.sleep(0.5)
            continue
        if f is None or st.st_ino != inode:
            if f:
                f.close()
            f = open(path, "r", errors="replace")
            f.seek(0, os.SEEK_END)
            inode = st.st_ino
        pos = f.tell()
        if st.st_size < pos:            # truncated out from under us
            f.seek(0)
        line = f.readline()
        if line:
            if line.endswith("\n"):
                yield line
            else:
                f.seek(pos)             # partial line, wait for the rest
                time.sleep(0.05)
        else:
            time.sleep(0.05)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--table-every", type=float, default=20.0,
                    help="seconds between full status tables (0 = never)")
    args = ap.parse_args()

    chairs = {}
    prev_state = {}
    transitions = defaultdict(list)
    last_table = 0.0
    started = time.time()

    print(f"watching {LOG}")
    print("waiting for packets... (sit down / stand up and this will report it)")
    print()

    for line in follow(LOG):
        m = lp.LINE_RE.search(line)
        if not m:
            continue
        token = m.group(1)
        if token.startswith("?"):
            continue
        idx = int(token) - 1
        if not (0 <= idx < lp.NUM_CHAIRS):
            continue

        now = time.time()
        if idx not in chairs:
            chairs[idx] = lp.Chair(idx)
            prev_state[idx] = None

        c = chairs[idx]
        vals = [int(g) for g in m.groups()[1:]]
        *motion, temp = vals
        c.add_sample(now, motion, temp)

        s = lp.SUMMARY_RE.search(line)
        if s:
            g = [int(x) for x in s.groups()]
            c.add_summary(now, (g[0], g[1], g[2]), g[3], flags=g[9],
                          touch_raw=g[5], touch_base=g[6], uptime_min=g[7])
        else:
            c.update_occupancy(now)

        c.confidence, c.detail = c._confidence_at(now)
        state = "OCCUPIED" if c.confidence > lp.OCCUPIED_WHEN_ABOVE else "FREE"

        if prev_state[idx] != state:
            if prev_state[idx] is not None:
                stamp = time.strftime("%H:%M:%S")
                held = now - transitions[idx][-1][0] if transitions[idx] else 0.0
                print(f"[{stamp}]  Chair {idx + 1}   "
                      f"{prev_state[idx]:>8} -> {state:<8}  "
                      f"conf {c.confidence:5.1f}   "
                      f"held previous state {held:5.1f}s   ({c.detail})")
            transitions[idx].append((now, state))
            prev_state[idx] = state

        if args.table_every and now - last_table >= args.table_every:
            last_table = now
            print()
            print(f"--- {time.strftime('%H:%M:%S')}  "
                  f"({now - started:.0f}s elapsed) ---")
            print(f"{'chair':>5} {'state':>9} {'conf':>6} {'Hz':>5} "
                  f"{'std(x,y,z)':>14} {'quiet%':>7} {'flags':>6} {'up':>6}")
            for i in sorted(chairs):
                ch = chairs[i]
                ch.confidence, ch.detail = ch._confidence_at(now)
                st = "OCCUPIED" if ch.confidence > lp.OCCUPIED_WHEN_ABOVE else "FREE"
                if not ch.online:
                    st = "NO SIGNAL"
                q = [qq for _, qq in ch.quiet_history]
                qpct = 100.0 * sum(q) / len(q) if q else 0.0
                stds = ch.gyro_stds_last_second(now)
                if stds:
                    sraw = ",".join(f"{v * lp.GYRO_LSB_PER_DEG_S:.0f}" for v in stds)
                else:
                    sraw = "-"
                print(f"{i + 1:>5} {st:>9} {ch.confidence:6.1f} "
                      f"{ch.rate_hz():5.1f} {sraw:>14} {qpct:6.0f}% "
                      f"{str(ch.summary_flags):>6} "
                      f"{str(ch.uptime_min) + 'm':>6}")
            print()


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\nstopped")
