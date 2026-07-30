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


# A chair only reads OCCUPIED if a sitter moves it measurably more than its own
# empty floor. The 2026-07-30 validation showed that separation is NOT uniform:
# chair 6 went 14 -> 36 (held 100%), chair 7 went 14 -> 19 (held 73%), and chair
# 4 went 13 -> 15 and held only 47%. Same firmware, same thresholds, so the
# spread is mechanical. Showing it live is the only way to tell a chair that is
# genuinely empty from one that cannot feel anybody, since both print FREE.
FLOOR_ALPHA = 1.0 / 256.0   # slow tracker, only adapts while FREE
SEP_WEAK = 1.25             # seated/floor ratio below this cannot be trusted
SEP_OK = 1.6

# Measured separation (seated smax / empty smax) and hold rate per chair from
# the 2026-07-30 validation, dataset_20260730_122544.csv. Shown greyed with a
# "~" until somebody actually sits in that chair during this session, so the
# known-bad chairs are flagged from the moment the dashboard opens rather than
# only after all seven have been tested. A live sit always supersedes it.
KNOWN_SEP = {1: (1.64, 100), 2: (2.00, 100), 3: (1.93, 100), 4: (1.15, 47),
             5: (2.31, 99), 6: (2.57, 100), 7: (1.36, 73)}


class Chair:
    def __init__(self):
        self.model = ChairModel()
        self.last_seen = None
        self.degraded = False
        self.bad = 0
        self.smax = 0            # newest 1s window max std
        self.floor = None        # this chair's own learned empty noise floor
        self.peak = 0
        self.rssi = None
        self.stamps = []         # recent arrival times, for the live rate
        self.seen_seated = 0.0   # best smax observed while OCCUPIED

    def note(self, t, pkt):
        self.smax = max(pkt["stdX"], pkt["stdY"], pkt["stdZ"])
        self.peak = pkt["peak"] or 0
        self.rssi = pkt["rssi"]
        self.stamps.append(t)
        if len(self.stamps) > 40:
            del self.stamps[:-40]
        if self.model.occupied:
            self.seen_seated = max(self.seen_seated, self.smax)
        else:
            # Learn the floor only while FREE, the same discipline the gyro bias
            # tracker uses, so an occupant can never raise it.
            self.floor = float(self.smax) if self.floor is None else \
                self.floor + FLOOR_ALPHA * (self.smax - self.floor)

    def hz(self):
        if len(self.stamps) < 2:
            return 0.0
        span = self.stamps[-1] - self.stamps[0]
        return (len(self.stamps) - 1) / span if span > 0 else 0.0

    def separation(self):
        """How far the best seen occupancy rose above this chair's own floor."""
        if not self.floor or not self.seen_seated:
            return None
        return self.seen_seated / self.floor


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
            ch.note(ch.last_seen, pkt)


def render(chairs, lock, started):
    lines = [f"{BOLD}CHAIR OCCUPANCY{RESET}   {DIM}{time.strftime('%H:%M:%S')}"
             f"  (Ctrl+C to quit){RESET}", "",
             f"{DIM}  ch  state       why                       vote   yaw    "
             f"std/floor      Hz   rssi{RESET}"]
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
            tag = f" {YELLOW}[degraded]{RESET}" if ch.degraded else ""

            online = ch.last_seen is not None and now - ch.last_seen <= STALE_S
            if online:
                vote = f"{ch.model.vote_frac:>4.2f}"
                yaw = ("  n/a" if ch.model.yaw_deg != ch.model.yaw_deg
                       else f"{ch.model.yaw_deg:>4.1f}")
                fl = ch.floor or 0
                sd = f"{ch.smax:>3}/{fl:>4.1f}" if fl else f"{ch.smax:>3}/  ?"
                sep = ch.separation()
                live = sep is not None
                if not live and c in KNOWN_SEP:
                    sep = KNOWN_SEP[c][0]
                pre = " " if live else "~"      # ~ means from the validation
                if sep is None:
                    mark = f"{DIM}  no sit yet{RESET}"
                elif sep < SEP_WEAK:
                    mark = f"{RED}{BOLD} {pre}{sep:>4.2f}x WEAK{RESET}"
                elif sep < SEP_OK:
                    mark = f"{YELLOW} {pre}{sep:>4.2f}x thin{RESET}"
                else:
                    mark = f"{GREEN} {pre}{sep:>4.2f}x ok  {RESET}"
                hz = ch.hz()
                hzs = (f"{GREEN}{hz:>4.1f}{RESET}" if 7.0 <= hz <= 9.0
                       else f"{YELLOW}{hz:>4.1f}{RESET}")
                stats = f"{vote}  {yaw}  {sd}{mark} {hzs}  {ch.rssi:>4}"
            else:
                stats = f"{DIM}     -     -        -            -      -{RESET}"

            lines.append(f"  {c}   {state}  {DIM}{detail[:24]:<24}{RESET} "
                         f"{stats}{tag}")
    lines += ["",
              f"  {RED}{BOLD}WATCH CHAIR 4{RESET}  1.15x separation, registered a "
              f"sitter only {BOLD}47%{RESET} of the time.",
              f"  {YELLOW}WATCH CHAIR 7{RESET}  1.36x, held {BOLD}73%{RESET}. "
              f"Also the weakest radio link.",
              f"  {DIM}Chairs 1, 2, 3, 5, 6 are fine (1.6x to 2.6x, held "
              f"99-100%).{RESET}",
              "",
              f"{DIM}  std/floor = current 1s window vs the floor this chair "
              f"learns for itself while FREE.{RESET}",
              f"{DIM}  The x figure is how far a sitter lifts it above that "
              f"floor. \"~\" = from the{RESET}",
              f"{DIM}  2026-07-30 validation; sit in a chair and it is replaced "
              f"by a live figure.{RESET}",
              f"{DIM}  WEAK matters because an empty chair and a chair that "
              f"cannot feel anybody{RESET}",
              f"{DIM}  both print FREE.{RESET}"]
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
