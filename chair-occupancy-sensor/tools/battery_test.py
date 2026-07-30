"""Battery runtime test: how long does a chair actually run on one charge?

This has never been measured (see NOTES.md, Battery section: "Max is
establishing the hours-per-charge figure on the bench; until that number
exists, charge them overnight"). Greg needs the number to know a safe
charging cadence while running the exhibit alone.

WHAT IT MEASURES AND WHY THAT IS ENOUGH
There is no battery-voltage telemetry on this board (no ADC wired to the
cell -- see NOTES.md). The only observable signal of a dead battery is the
chair going silent: "a chair node that stops reporting in has a dead
battery" is already the documented operating assumption. So the test is
exactly that: watch the receiver, and time from first packet to last packet.

"Simulate real conditions" here means leaving the chair alone, mounted and
running normally, NOT rigging a special bench test. The firmware transmits
at a fixed 8Hz continuously regardless of occupancy (see sender_summary.ino
-- there is no sleep state and no change in behavior between an empty and
occupied chair), so ordinary sitting/standing during the test does not
change the current draw in any way the firmware is aware of. Idle-and-
mounted is already the real condition as far as the battery is concerned.

WHAT IT DOES NOT DO
It does not record sensor data. Every other tool in this repo (collect_
dataset.py in particular) writes a row per packet, which is the right shape
for training data and the wrong shape for a test that may run for a day or
more unattended -- that would produce a multi-hundred-MB file nobody needs.
This writes one row per EVENT (a chair starting, a periodic heartbeat, a
chair going silent, a chair coming back) to a small CSV that stays readable
by eye for the whole test.

RESUMES ACROSS RESTARTS
If the process is killed and restarted (a Mac Mini reboot, say), it reads
its own log first and picks the clock back up rather than resetting every
chair's uptime to zero -- the whole point is to survive being run unattended
for longer than any one terminal session.

Usage:
  venv/bin/python tools/battery_test.py
  venv/bin/python tools/battery_test.py --chairs 7
  venv/bin/python tools/battery_test.py --report      # summarize and exit
Ctrl+C to stop and print a summary. Safe to re-run afterward with --report.
"""

import argparse
import csv
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import receiver_parse as rp  # noqa: E402

LOG = Path.home() / "motion_log.txt"
OUT = Path(__file__).resolve().parent.parent / "data" / "battery_test_events.csv"

# A chair is "dead" once silent for this long. Set well above any ordinary
# radio hiccup -- packet loss elsewhere in this project clears in seconds --
# and well below the scale (hours) this test is actually measuring, so it
# cannot meaningfully blur the number being measured.
STALE_S = 120.0
# One routine row per chair on this cadence while it stays alive, so the log
# shows a readable timeline without needing per-packet resolution. 15 minutes
# keeps a multi-day unattended run to a few hundred rows, total.
HEARTBEAT_S = 15 * 60.0


def fmt_dur(seconds):
    h, rem = divmod(int(seconds), 3600)
    m, s = divmod(rem, 60)
    if h:
        return f"{h}h{m:02d}m"
    if m:
        return f"{m}m{s:02d}s"
    return f"{s}s"


def load_state(chairs_wanted):
    """Reconstruct each chair's current cycle start time from the existing
    log, so a restarted process resumes the clock instead of losing it."""
    state = {}
    if not OUT.exists():
        return state
    with open(OUT, newline="") as f:
        for row in csv.DictReader(f):
            c = int(row["chair"])
            if chairs_wanted and c not in chairs_wanted:
                continue
            ev = row["event"]
            t = float(row["t"])
            if ev == "START":
                state[c] = dict(cycle_start=t, last_seen=t, alive=True, died_at=None)
            elif ev == "HEARTBEAT":
                if c in state:
                    state[c]["last_seen"] = t
            elif ev == "DIED":
                if c in state:
                    state[c]["alive"] = False
                    state[c]["died_at"] = t
            elif ev == "REBORN":
                state[c] = dict(cycle_start=t, last_seen=t, alive=True, died_at=None)
    return state


def append_event(writer, f, t, chair, event, cycle_start):
    writer.writerow({"t": f"{t:.1f}", "iso": time.strftime(
        "%Y-%m-%d %H:%M:%S", time.localtime(t)),
        "chair": chair, "event": event,
        "elapsed_s": f"{t - cycle_start:.1f}" if cycle_start else ""})
    f.flush()


def report(chairs_wanted=None):
    if not OUT.exists():
        print(f"no log yet at {OUT}")
        return
    state = load_state(chairs_wanted)
    if not state:
        print("no chairs recorded yet")
        return
    now = time.time()
    print(f"{'chair':>5}  {'status':>8}  {'this cycle':>12}  {'since':>19}")
    for c in sorted(state):
        s = state[c]
        if s["alive"]:
            elapsed = now - s["cycle_start"]
            status = "ALIVE" if now - s["last_seen"] < STALE_S else "STALE?"
            since = time.strftime("%m-%d %H:%M", time.localtime(s["cycle_start"]))
        else:
            elapsed = s["died_at"] - s["cycle_start"]
            status = "DIED"
            since = time.strftime("%m-%d %H:%M", time.localtime(s["died_at"]))
        print(f"{c:>5}  {status:>8}  {fmt_dur(elapsed):>12}  "
              f"{'started' if s['alive'] else 'died at'} {since:>10}")


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--chairs", default="",
                    help="comma list to track, default: whatever transmits")
    ap.add_argument("--stale", type=float, default=STALE_S,
                    help=f"seconds silent before counted dead (default {STALE_S:.0f})")
    ap.add_argument("--heartbeat", type=float, default=HEARTBEAT_S,
                    help=f"seconds between routine log rows (default {HEARTBEAT_S:.0f})")
    ap.add_argument("--report", action="store_true",
                    help="print the current summary and exit, no monitoring")
    args = ap.parse_args()

    chairs_wanted = {int(c) for c in args.chairs.split(",") if c.strip()}

    if args.report:
        report(chairs_wanted)
        return

    OUT.parent.mkdir(exist_ok=True)
    state = load_state(chairs_wanted)
    is_new = not OUT.exists()
    f = open(OUT, "a", newline="")
    writer = csv.DictWriter(f, fieldnames=["t", "iso", "chair", "event", "elapsed_s"])
    if is_new:
        writer.writeheader()
        f.flush()

    if state:
        print(f"resumed from {OUT}, tracking {len(state)} chair(s) already seen")
    print(f"watching {LOG}  (stale={args.stale:.0f}s heartbeat={args.heartbeat:.0f}s)")
    print("Ctrl+C for a summary\n")

    try:
        for line in rp.follow(LOG):
            pkt = rp.parse(line)
            now = time.time()

            # Independent of whether a packet just arrived: check every chair
            # we are tracking for having gone silent or for a heartbeat being
            # due. Doing this on every line (not on a separate timer) is
            # simplest and cheap -- packets arrive every ~1/8s per chair while
            # anything is alive, which is plenty of resolution for a 120s
            # stale threshold and a 15-minute heartbeat.
            for c, s in state.items():
                if not s["alive"]:
                    continue
                if now - s["last_seen"] > args.stale:
                    s["alive"] = False
                    s["died_at"] = s["last_seen"]
                    append_event(writer, f, s["last_seen"], c, "DIED",
                                 s["cycle_start"])
                    dur = fmt_dur(s["died_at"] - s["cycle_start"])
                    print(f"{time.strftime('%H:%M:%S')}  chair {c}  DIED  "
                          f"(ran {dur})")
                elif now - s.get("last_heartbeat", s["cycle_start"]) > args.heartbeat:
                    s["last_heartbeat"] = now
                    append_event(writer, f, now, c, "HEARTBEAT", s["cycle_start"])
                    print(f"{time.strftime('%H:%M:%S')}  chair {c}  alive  "
                          f"{fmt_dur(now - s['cycle_start'])} so far")

            if pkt is None or pkt.get("fmt") not in ("sum", "raw"):
                continue
            c = pkt["chair"]
            if chairs_wanted and c not in chairs_wanted:
                continue

            if c not in state:
                state[c] = dict(cycle_start=now, last_seen=now, alive=True,
                                 died_at=None, last_heartbeat=now)
                append_event(writer, f, now, c, "START", now)
                print(f"{time.strftime('%H:%M:%S')}  chair {c}  START")
            elif not state[c]["alive"]:
                state[c] = dict(cycle_start=now, last_seen=now, alive=True,
                                 died_at=None, last_heartbeat=now)
                append_event(writer, f, now, c, "REBORN", now)
                print(f"{time.strftime('%H:%M:%S')}  chair {c}  REBORN "
                      f"(recharged and running again)")
            else:
                state[c]["last_seen"] = now
    except KeyboardInterrupt:
        pass
    finally:
        f.close()
        print()
        report(chairs_wanted)


if __name__ == "__main__":
    main()
