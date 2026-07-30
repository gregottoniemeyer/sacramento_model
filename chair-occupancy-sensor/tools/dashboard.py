"""Simplified live dashboard: one line per chair, current occupancy only.

Deliberately not live_plot.py, which still runs the OLD confidence/decay model
(see NOTES.md, "MODEL REBUILT") -- this imports tools/occupancy_model.py
directly, so what you see here is what the rebuilt model actually decides.

Full-screen, redraws in place, plain ANSI (no curses dependency). Reads
~/motion_log.txt the same way every other tool does, via tools/receiver_parse
and tools/occupancy_model.

A chair is STALE if no packet has arrived in STALE_S seconds -- per
OPERATING.md, "a chair reading zero has either a flat battery or is switched
off." That is distinct from FREE, which means "sensor is fine and nobody is
sitting here," and the dashboard never lets one be mistaken for the other.

Usage:
  venv/bin/python tools/dashboard.py
Ctrl+C to quit.
"""

import sys
import threading
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from occupancy_model import ChairModel  # noqa: E402
import receiver_parse as rp             # noqa: E402

LOG = Path.home() / "motion_log.txt"
NUM_CHAIRS = 7
STALE_S = 3.0            # ~8Hz means a healthy chair never goes this long silent
REDRAW_S = 0.5

CLEAR = "\x1b[2J\x1b[H"
BOLD = "\x1b[1m"
DIM = "\x1b[2m"
RED = "\x1b[31m"
GREEN = "\x1b[32m"
YELLOW = "\x1b[33m"
RESET = "\x1b[0m"


class Chair:
    def __init__(self):
        self.model = ChairModel()
        self.last_seen = None
        self.degraded = False
        self.bad = 0


def reader(chairs, lock, stop):
    for line in rp.follow(LOG, stop):
        pkt = rp.parse(line)
        if pkt is None:
            continue
        c = pkt["chair"]
        if not (1 <= c <= NUM_CHAIRS):
            continue
        with lock:
            ch = chairs[c]
            if pkt["fmt"] == "bad":
                ch.bad += 1
                continue
            if pkt["fmt"] != "sum":
                continue                # a raw 100Hz sender, not this fleet
            ch.last_seen = time.time()
            ch.degraded = pkt["yawSum"] is None
            ch.model.update(ch.last_seen, pkt["stdX"], pkt["stdY"], pkt["stdZ"],
                             pkt["peak"] or 0, pkt["yawSum"], pkt["yawN"],
                             pkt["gyroZ"])


def render(chairs, lock, started):
    lines = [f"{BOLD}CHAIR OCCUPANCY{RESET}   {DIM}{time.strftime('%H:%M:%S')}"
             f"  (Ctrl+C to quit){RESET}", ""]
    now = time.time()
    with lock:
        for c in range(1, NUM_CHAIRS + 1):
            ch = chairs[c]
            if ch.bad and (ch.last_seen is None or now - ch.last_seen > STALE_S):
                state = f"{YELLOW}WRONG FIRMWARE{RESET}"
                detail = f"{ch.bad} BAD PACKET -- reflash this chair"
            elif ch.last_seen is None or now - ch.last_seen > STALE_S:
                state = f"{DIM}--- OFFLINE{RESET}"
                since = "never seen" if ch.last_seen is None \
                    else f"silent {now - ch.last_seen:.0f}s"
                detail = f"{since} -- flat battery or switched off"
            elif ch.model.occupied:
                state = f"{RED}{BOLD}OCCUPIED{RESET}"
                detail = ch.model.reason
            else:
                state = f"{GREEN}FREE    {RESET}"
                # The model's own default reason is "no data", set at
                # construction and never overwritten until the first vote
                # fires. Left as-is that reads as "not receiving packets"
                # right next to a state that says the opposite.
                detail = "quiet" if ch.model.reason == "no data" else ch.model.reason
            tag = f"  {YELLOW}[degraded]{RESET}" if ch.degraded else ""
            lines.append(f"  chair {c}   {state}   {DIM}{detail}{tag}{RESET}")
    print(CLEAR + "\n".join(lines), end="", flush=True)


def main():
    chairs = {c: Chair() for c in range(1, NUM_CHAIRS + 1)}
    lock = threading.Lock()
    stop = threading.Event()
    t = threading.Thread(target=reader, args=(chairs, lock, stop), daemon=True)
    t.start()
    try:
        while True:
            render(chairs, lock, t)
            time.sleep(REDRAW_S)
    except KeyboardInterrupt:
        stop.set()
        print()


if __name__ == "__main__":
    main()
