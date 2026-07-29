"""Guided collection of a comprehensive 7-chair labeled dataset.

This replaces the single-chair sessions in data/ (labeled_session_*.csv,
standup_session_*.csv). Those were collected with ONE sensor, on a bench or a
bare floor, running the old 100Hz raw firmware. Three things make them unfit
for rebuilding the model now:

  1. THEY CANNOT SHOW CROSS-CHAIR COUPLING. Seven chairs now share a room and
     a floor. Sitting in chair 3 shakes chairs 2 and 4. A single-chair
     recording cannot represent that at all, and it is the leading suspect for
     the false positives seen on 2026-07-29. This is the single biggest reason
     to re-collect.
  2. The chairs hang INVERTED when mounted (Z pointing down), and the sensor
     is now screwed/taped to a metal chair rather than sitting on a surface.
     Different mechanical path, different signal.
  3. The model's inputs now arrive as 8Hz on-device summaries, not 100Hz raw
     samples. Training on exactly what the model will see at runtime removes a
     whole class of mismatch.

WHAT THIS RECORDS
Every packet from every chair, with the on-device statistics as transmitted,
plus GROUND-TRUTH OCCUPANCY FOR ALL SEVEN CHAIRS at that instant. So each row
answers "what did chair N measure, and was there actually a person in chair N,
and which other chairs had people in them" -- which is what any honest model or
scoring pass needs, and what the old data cannot express.

REQUIREMENTS
  - All seven chairs powered and mounted.
  - The serial capture must ALREADY be running into ~/motion_log.txt
    (see README.md). This script tails that file; it does not open the port,
    because two readers on one serial port corrupt each other.
  - Spoken cues use macOS `say`. Wear headphones or turn it up; the cue timing
    is the ground truth.

USAGE
  venv/bin/python tools/collect_dataset.py --dry-run       # see the protocol
  venv/bin/python tools/collect_dataset.py                 # run everything
  venv/bin/python tools/collect_dataset.py --blocks A,C,I  # run some blocks
  venv/bin/python tools/collect_dataset.py --chairs 1,2,3  # fewer chairs

Ctrl+C stops cleanly and keeps everything recorded so far. Rows are flushed
continuously, so an aborted session is still a usable dataset.
"""

import argparse
import csv
import os
import re
import subprocess
import sys
import threading
import time
from collections import namedtuple
from datetime import datetime
from pathlib import Path

import matplotlib.pyplot as plt
from matplotlib.animation import FuncAnimation

LOG = Path.home() / "motion_log.txt"
OUT_DIR = Path(__file__).resolve().parent.parent / "data"

NUM_CHAIRS = 7

# Two wire formats are accepted, because model development needs raw samples
# while the deployed fleet sends summaries. The receiver already emits both
# (it tells them apart by packet length), so a single chair can be flashed with
# the old raw firmware and recorded alongside six summary chairs.
#
# V2_RE is the 8Hz on-device summary. V1_RE is the raw 100Hz sample, which has
# no Std/Big/Touch fields -- those columns are written empty for v1 rows, and
# the raw samples let any feature be computed offline instead of being limited
# to whatever the firmware chose to send.
V2_RE = re.compile(
    r"Chair:(\d+)\s+"
    r"Accel\s+X:(-?\d+)\s+Y:(-?\d+)\s+Z:(-?\d+)\s+"
    r"Gyro\s+X:(-?\d+)\s+Y:(-?\d+)\s+Z:(-?\d+)\s+"
    r"Temp:(-?\d+)\s+"
    r"Std\s+X:(\d+)\s+Y:(\d+)\s+Z:(\d+)\s+"
    r"Big:(\d+)\s+N:(\d+)\s+"
    r"Touch:(\d+)\s+TBase:(\d+)\s+"
    r"Up:(\d+)\s+Seq:(\d+)\s+Flags:(\d+)\s+Rssi:(-?\d+)"
)
V1_RE = re.compile(
    r"Chair:(\d+)\s+"
    r"Accel\s+X:(-?\d+)\s+Y:(-?\d+)\s+Z:(-?\d+)\s+"
    r"Gyro\s+X:(-?\d+)\s+Y:(-?\d+)\s+Z:(-?\d+)\s+"
    r"Temp:(-?\d+)"
)

FIELDS = ["accX", "accY", "accZ", "gyroX", "gyroY", "gyroZ", "temp",
          "stdX", "stdY", "stdZ", "big", "n",
          "touch", "tbase", "up", "seq", "flags", "rssi"]

# A phase is one instruction with a fixed duration.
#   occupied    : chairs with a person actually IN them for this phase
#   transition  : True when occupancy is changing during the phase, so the
#                 label is genuinely ambiguous and the phase must be excluded
#                 from scoring rather than counted as a wrong answer
Phase = namedtuple("Phase", "block label target occupied duration cue transition")


def P(block, label, target, occupied, duration, cue, transition=False):
    return Phase(block, label, target, tuple(occupied), duration, cue, transition)


# Two profiles. STANDARD is the one to run: it keeps every case that matters
# for the failures actually being chased (false positives, missed sit-downs,
# missed stand-ups, statue-sitting) and trims the redundant repetition, landing
# around 30 minutes. FULL repeats the variant blocks on all seven chairs and
# takes over an hour; only worth it if the standard set proves ambiguous.
#
# What STANDARD deliberately drops:
#   - Block G (explicit neighbour-shaking). Block C already captures coupling
#     for free: while one chair is occupied, the other six are recorded and
#     labelled empty in the same rows, which is exactly the data needed.
#   - The fast/slow/perch variants on chairs 3-7. Those variants characterise
#     human movement, which does not differ per chair; two chairs is enough to
#     cover them. The per-chair coverage that DOES matter -- each chair's own
#     baseline and its own sit/stand cycle -- is kept for all seven.
# BASICS is for rebuilding the model from raw data. It contains ONLY the four
# things that have to work, repeated enough times to be statistically useful:
#   sit down, sit normally, stand up, and walk around without sitting.
#
# Deliberately excluded: perching, dropped objects, bags on seats, and above
# all "sit perfectly still". Perfect stillness is not a real use case -- the
# whole point of detecting the stand-up event was to avoid depending on
# whether a motionless person can be seen at all. Chasing it distorted the
# earlier model, so it is out.
#
# `reps` sit/stand cycles on one chair, plus walk-around blocks between them so
# the false-positive case is sampled under the same conditions as the true one.
PROFILES = {
    "basics": dict(reps=9, sit_hold=25, after=15, walk=35, baseline=45),
    "standard": dict(baseline=90, still=25, active=15, after=18,
                     variant_chairs=2, statue_chairs=2, statue=90,
                     disturbances=("walk_past", "bump", "bag_on_seat"),
                     neighbours=False),
    "full": dict(baseline=120, still=30, active=20, after=25,
                 variant_chairs=7, statue_chairs=2, statue=120,
                 disturbances=("walk_past", "stand_near", "bump",
                               "lean_on_back", "bag_on_seat"),
                 neighbours=True),
}

DISTURBANCE_CUES = {
    "walk_past": (12, "Walk back and forth past chair {c}, close, without touching it."),
    "stand_near": (12, "Stand right next to chair {c}. Shift your weight. Do not touch it."),
    "bump": (10, "Bump chair {c} once, firmly, then step away."),
    "lean_on_back": (12, "Lean on the backrest of chair {c} with your hands, then let go."),
    "bag_on_seat": (14, "Put a bag or a coat on the seat of chair {c}, then take it off."),
}


def build_basics(chair, cfg):
    """Sit / sit-normally / stand / walk-around, repeated. Nothing else."""
    ph = [P("A", "empty", None, [], cfg["baseline"],
            "Empty baseline. Stay away from all the chairs.")]
    for i in range(cfg["reps"]):
        n = i + 1
        ph.append(P("W", "walk_around", chair, [], cfg["walk"],
                    f"Round {n}. Walk around the room and past chair {chair}. "
                    f"Do not sit down."))
        ph.append(P("S", "sit_down", chair, [chair], 8,
                    f"Sit down in chair {chair} now.", transition=True))
        ph.append(P("S", "seated", chair, [chair], cfg["sit_hold"],
                    f"Sit in chair {chair} normally. Breathe, shift a little, "
                    f"behave like a person. Do not freeze."))
        ph.append(P("S", "stand_up", chair, [], 8,
                    "Stand up now and step away.", transition=True))
        ph.append(P("S", "empty_after", chair, [], cfg["after"],
                    "Stay away from the chairs."))
    ph.append(P("I", "empty", None, [], cfg["baseline"],
                "Final empty baseline. Stay away from the chairs. Then done."))
    return ph


def build_protocol(chairs, profile="standard"):
    """The protocol, as data. Read this to know exactly what gets collected."""
    cfg = PROFILES[profile]
    if profile == "basics":
        return build_basics(chairs[0], cfg)
    ph = []
    variant = chairs[:cfg["variant_chairs"]]
    statue = chairs[:cfg["statue_chairs"]]

    # ---- A: empty baseline ------------------------------------------------
    # Establishes each chair's true noise floor IN PLACE, which the bench
    # cannot measure (a desk carries building vibration; chair 1 read 15-16 on
    # a desk and 11 mounted). Also captures the room's own background.
    ph.append(P("A", "empty", None, [], cfg["baseline"],
                "Block A. Leave the room, or stand completely still, "
                "away from all chairs, until I speak again."))

    # ---- B: disturbance WITHOUT occupancy --------------------------------
    # The false-positive cases. Every one of these must read FREE. bag_on_seat
    # matters most of the three: it is weight on the seat with no person, which
    # is the case a naive load-based model gets wrong.
    for c in chairs:
        for name in cfg["disturbances"]:
            dur, cue = DISTURBANCE_CUES[name]
            ph.append(P("B", name, c, [], dur, cue.format(c=c)))

    # ---- C: the core sit/stand cycle, ALL SEVEN CHAIRS -------------------
    # The heart of the dataset. Run on every chair, because this is what
    # captures cross-chair coupling: while chair N is occupied, the other six
    # are recorded and labelled empty at the same instant.
    for c in chairs:
        ph.append(P("C", "sit_down", c, [c], 8,
                    f"Sit down in chair {c} now, normally.", transition=True))
        ph.append(P("C", "seated_still", c, [c], cfg["still"],
                    f"Stay in chair {c}. Sit still."))
        ph.append(P("C", "seated_active", c, [c], cfg["active"],
                    f"Still in chair {c}. Shift about, cross your legs, lean back."))
        ph.append(P("C", "stand_up", c, [], 8,
                    "Stand up now and step away.", transition=True))
        ph.append(P("C", "empty_after", c, [], cfg["after"],
                    "Stay away from the chairs."))

    # ---- D: fast and slow variants ---------------------------------------
    # Slow departures are the hardest to catch and quick ones the easiest to
    # miss the arrival of. Human movement style does not vary by chair, so a
    # subset of chairs covers this.
    for c in variant:
        ph.append(P("D", "sit_quick", c, [c], 6,
                    f"Drop quickly into chair {c} now.", transition=True))
        ph.append(P("D", "seated_still_short", c, [c], 15, "Sit still."))
        ph.append(P("D", "stand_quick", c, [], 6,
                    "Jump up quickly now.", transition=True))
        ph.append(P("D", "empty_after", c, [], 15, "Stay away."))
        ph.append(P("D", "sit_slow", c, [c], 10,
                    f"Now lower yourself into chair {c} as slowly as you can.",
                    transition=True))
        ph.append(P("D", "seated_still_short", c, [c], 15, "Sit still."))
        ph.append(P("D", "stand_slow", c, [], 10,
                    "Rise as slowly as you can.", transition=True))
        ph.append(P("D", "empty_after", c, [], 15, "Stay away."))

    # ---- E: perching and partial movement --------------------------------
    # partial_rise is the case that must NOT read FREE: standing halfway then
    # sitting back down. Perching loads the seat differently again.
    for c in variant:
        ph.append(P("E", "perch", c, [c], 20,
                    f"Perch on the front edge of chair {c}.", transition=True))
        ph.append(P("E", "partial_rise", c, [c], 20,
                    "Half stand up, hover, then sit back down. Twice."))
        ph.append(P("E", "stand_up", c, [], 8, "Stand up and step away.",
                    transition=True))
        ph.append(P("E", "empty_after", c, [], 15, "Stay away."))

    # ---- F: the statue case ----------------------------------------------
    # The failure that broke the first model: a motionless person reads as
    # empty. Measured motion gaps up to 19s, so this needs long segments.
    for c in statue:
        ph.append(P("F", "sit_down", c, [c], 8,
                    f"Sit down in chair {c}.", transition=True))
        ph.append(P("F", "statue", c, [c], cfg["statue"],
                    "Now sit as still as you possibly can, until I speak again. "
                    "Try not to move at all."))
        ph.append(P("F", "stand_up", c, [], 8, "Stand up and step away.",
                    transition=True))
        ph.append(P("F", "empty_after", c, [], 25, "Stay away."))

    # ---- G: neighbour coupling, isolated (full profile only) -------------
    if cfg["neighbours"]:
        for c in chairs:
            for n in [x for x in (c - 1, c + 1) if x in chairs]:
                ph.append(P("G", "sit_then_disturb_neighbour", c, [c], 10,
                            f"Sit in chair {c}.", transition=True))
                ph.append(P("G", "occupied_neighbour_bumped", c, [c], 15,
                            f"While seated in {c}, reach over and shake chair {n}."))
                ph.append(P("G", "stand_up", c, [], 8,
                            "Stand up and step away.", transition=True))
                ph.append(P("G", "empty_after", c, [], 12, "Stay away."))

    # ---- H: multi-occupancy (needs a second person; opt in via --blocks) --
    if len(chairs) >= 3:
        a, b = chairs[0], chairs[2]
        ph.append(P("H", "two_sit_down", None, [a, b], 12,
                    f"Two people: one sit in chair {a}, one in chair {b}.",
                    transition=True))
        ph.append(P("H", "two_seated_still", None, [a, b], 30, "Both sit still."))
        ph.append(P("H", "one_stands", None, [b], 10,
                    f"Person in chair {a} only, stand up and step away.",
                    transition=True))
        ph.append(P("H", "one_seated", None, [b], 25,
                    f"Person in chair {b}, stay seated and still."))
        ph.append(P("H", "both_empty", None, [], 12,
                    "Everyone stand up and step away.", transition=True))
        ph.append(P("H", "empty_after", None, [], 20, "Stay away."))

    # ---- I: closing empty baseline ---------------------------------------
    # A second empty stretch at the END. Comparing it against block A is how
    # thermal drift over the session becomes visible; the touch electrode in
    # particular drifts over tens of minutes.
    ph.append(P("I", "empty", None, [], cfg["baseline"],
                "Final block. Stay away from all chairs until I speak again. "
                "Then we are done."))

    return ph


class Tailer(threading.Thread):
    """Timestamp packets as they land, tagged with whatever phase is current.

    Tails the log rather than opening the serial port, because the capture
    pipeline already owns that port and two readers would corrupt each other.
    Timestamping on read adds a few tens of milliseconds of jitter, which is
    irrelevant against a model that works on 1-second windows.
    """

    def __init__(self, writer, state):
        super().__init__(daemon=True)
        self.writer = writer
        self.state = state
        self.stop_flag = threading.Event()
        self.counts = {c: 0 for c in range(1, NUM_CHAIRS + 1)}

    def run(self):
        f = open(LOG, "r", errors="replace")
        f.seek(0, os.SEEK_END)
        inode = LOG.stat().st_ino
        while not self.stop_flag.is_set():
            try:
                if LOG.stat().st_ino != inode:      # capture restarted
                    f.close()
                    f = open(LOG, "r", errors="replace")
                    f.seek(0, os.SEEK_END)
                    inode = LOG.stat().st_ino
            except FileNotFoundError:
                time.sleep(0.2)
                continue

            line = f.readline()
            if not line:
                time.sleep(0.02)
                continue
            m = V2_RE.search(line)
            raw = False
            if not m:
                m = V1_RE.search(line)
                raw = True
                if not m:
                    continue

            now = time.time()
            ph = self.state.get("phase")
            if ph is None:
                continue
            chair = int(m.group(1))
            if raw:
                # v1 carries accel, gyro and temp only. Everything the firmware
                # would have derived is left blank and computed offline.
                vals = [int(m.group(i)) for i in range(2, 9)] + [""] * 11
            else:
                vals = [int(m.group(i)) for i in range(2, 20)]
            occ = self.state["occupied"]
            self.counts[chair] = self.counts.get(chair, 0) + 1

            self.writer.writerow({
                "t": f"{now:.3f}",
                "chair": chair,
                "fmt": "raw" if raw else "sum",
                **dict(zip(FIELDS, vals)),
                "is_occupied": 1 if chair in occ else 0,
                "occupied_chairs": "|".join(str(c) for c in sorted(occ)),
                "n_occupied": len(occ),
                "block": ph.block,
                "label": ph.label,
                "target_chair": ph.target if ph.target else "",
                "is_target": 1 if ph.target == chair else 0,
                "is_transition": 1 if ph.transition else 0,
                "phase_idx": self.state["phase_idx"],
                "t_phase_start": f"{self.state['phase_start']:.3f}",
            })




def speak(text):
    """Non-blocking. The animation loop must never stall waiting on audio."""
    try:
        subprocess.Popen(["say", "-r", "190", text],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except FileNotFoundError:
        pass


def beep():
    try:
        subprocess.Popen(["afplay", "/System/Library/Sounds/Ping.aiff"],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except FileNotFoundError:
        pass


def wrap(text, width=42):
    words, line, out = text.split(), "", []
    for w in words:
        if len(line) + len(w) + 1 > width:
            out.append(line)
            line = w
        else:
            line = f"{line} {w}".strip()
    if line:
        out.append(line)
    return "\n".join(out)


def fmt_dur(seconds):
    m, s = divmod(int(seconds), 60)
    return f"{m}m{s:02d}s" if m else f"{s}s"


def run_session(protocol, out_path, events_path, voice=True):
    """Big on-screen instructions with a countdown, matching collect_data.py.

    The protocol is driven from the animation callback rather than a sleep
    loop, so the window stays responsive and the countdown actually ticks.
    Audio is fired non-blocking for the same reason.
    """
    header = (["t", "chair", "fmt"] + FIELDS +
              ["is_occupied", "occupied_chairs", "n_occupied", "block", "label",
               "target_chair", "is_target", "is_transition", "phase_idx",
               "t_phase_start"])
    out_f = open(out_path, "w", newline="")
    writer = csv.DictWriter(out_f, fieldnames=header)
    writer.writeheader()
    ev_f = open(events_path, "w", newline="")
    ev = csv.writer(ev_f)
    ev.writerow(["phase_idx", "block", "label", "target_chair", "occupied_chairs",
                 "is_transition", "t_start", "t_end", "duration"])

    state = {"phase": None, "phase_idx": -1, "occupied": (), "phase_start": 0.0}
    tailer = Tailer(writer, state)
    tailer.start()

    total = sum(p.duration for p in protocol)
    ui = {"idx": -1, "t0": 0.0, "done": False, "lead_in": 5.0,
          "started": time.time()}

    fig = plt.figure(figsize=(10, 7))
    fig.patch.set_facecolor("#f9f9f7")
    fig.canvas.manager.set_window_title(
        "Chair dataset collection — follow the instructions")

    progress = fig.text(0.5, 0.95, "", ha="center", va="top",
                        fontsize=12, color="#52514e")
    chairbar = fig.text(0.5, 0.90, "", ha="center", va="top",
                        fontsize=11, color="#898781", family="monospace")
    target = fig.text(0.5, 0.75, "", ha="center", va="center",
                      fontsize=34, color="#d03b3b", fontweight="bold")
    instruction = fig.text(0.5, 0.50, "Get ready...", ha="center", va="center",
                           fontsize=24, color="#0b0b0b")
    countdown = fig.text(0.5, 0.17, "", ha="center", va="center",
                         fontsize=64, color="#0b0b0b")
    hint = fig.text(0.5, 0.03, "SPACE = skip this step    Q = stop and save",
                    ha="center", va="bottom", fontsize=10, color="#c3c2b7")

    def on_key(event):
        if event.key == " ":
            ui["t0"] = 0.0            # expire the current phase immediately
        elif event.key in ("q", "Q"):
            finish("Stopped early. Data saved.")

    fig.canvas.mpl_connect("key_press_event", on_key)

    def close_files():
        tailer.stop_flag.set()
        try:
            out_f.flush(); out_f.close()
            ev_f.flush(); ev_f.close()
        except Exception:
            pass

    def finish(msg="DONE!"):
        if ui["done"]:
            return
        ui["done"] = True
        state["phase"] = None
        close_files()
        counts = dict(sorted(tailer.counts.items()))
        missing = [c for c, n in counts.items() if n == 0]
        target.set_text("")
        countdown.set_text("")
        instruction.set_text(f"{msg}\nYou can close this window.")
        note = f"saved {Path(out_path).name}   ·   {sum(counts.values())} rows"
        if missing:
            note += f"   ·   WARNING: no packets from chairs {missing}"
        progress.set_text(note)
        chairbar.set_text("  ".join(f"c{c}:{n}" for c, n in counts.items()))
        speak("Data collection complete." if msg == "DONE!" else "Stopped.")
        fig.canvas.draw_idle()

    def update(_frame):
        if ui["done"]:
            return

        now = time.time()

        # Lead-in so the operator can get into position before phase 0.
        if ui["idx"] < 0:
            left = ui["lead_in"] - (now - ui["started"])
            if left > 0:
                instruction.set_text(
                    "Starting in a moment.\n\n"
                    "Instructions appear here and are spoken aloud.\n"
                    "A beep marks the moment to act.")
                countdown.set_text(f"{left:.0f}")
                progress.set_text(f"0/{len(protocol)}   ·   "
                                  f"about {fmt_dur(total)} of recording")
                return
            ui["idx"] = 0
            ui["t0"] = 0.0

        # Start a phase whose timer has expired (or which has not begun).
        if ui["t0"] == 0.0 or now - ui["t0"] >= protocol[ui["idx"]].duration:
            if ui["t0"] != 0.0:
                p_done = protocol[ui["idx"]]
                ev.writerow([ui["idx"], p_done.block, p_done.label,
                             p_done.target or "",
                             "|".join(str(c) for c in p_done.occupied),
                             1 if p_done.transition else 0,
                             f"{ui['t0']:.3f}", f"{now:.3f}",
                             f"{now - ui['t0']:.1f}"])
                ev_f.flush()
                out_f.flush()
                ui["idx"] += 1

            if ui["idx"] >= len(protocol):
                finish()
                return

            p = protocol[ui["idx"]]
            ui["t0"] = time.time()
            state["phase"] = p
            state["phase_idx"] = ui["idx"]
            state["occupied"] = p.occupied
            state["phase_start"] = ui["t0"]
            if voice:
                speak(p.cue)
                beep()
            instruction.set_text(wrap(p.cue))
            target.set_text(f"CHAIR {p.target}" if p.target else "")

        p = protocol[ui["idx"]]
        left = max(p.duration - (now - ui["t0"]), 0)
        countdown.set_text(f"{left:.0f}")
        elapsed = now - ui["started"]
        progress.set_text(
            f"step {ui['idx'] + 1}/{len(protocol)}   ·   block {p.block}   ·   "
            f"{p.label}   ·   elapsed {fmt_dur(elapsed)}")
        counts = tailer.counts
        chairbar.set_text("  ".join(
            f"c{c}:{'ok' if counts.get(c, 0) else 'NONE'}"
            for c in range(1, NUM_CHAIRS + 1)))

    ani = FuncAnimation(fig, update, interval=100, cache_frame_data=False)
    fig._keep_ani = ani
    try:
        plt.show()
    finally:
        close_files()
    return tailer.counts


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--profile", default="standard", choices=sorted(PROFILES),
                    help="standard (~30 min, default) or full (~70 min)")
    ap.add_argument("--blocks", default="",
                    help="comma-separated blocks to run, e.g. A,C,I")
    ap.add_argument("--chairs", default=",".join(str(i) for i in range(1, 8)))
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--smoke", action="store_true",
                    help="20-second fake protocol to prove the rig works")
    ap.add_argument("--no-voice", action="store_true")
    ap.add_argument("--out", default="")
    args = ap.parse_args()

    chairs = [int(c) for c in args.chairs.split(",") if c.strip()]
    if args.smoke:
        protocol = [
            P("SMOKE", "empty", None, [], 6, "Smoke test. Stay away from the chairs."),
            P("SMOKE", "sit_down", chairs[0], [chairs[0]], 4,
              f"Sit down in chair {chairs[0]}.", transition=True),
            P("SMOKE", "seated_still", chairs[0], [chairs[0]], 8,
              f"Stay in chair {chairs[0]} and sit still."),
            P("SMOKE", "stand_up", chairs[0], [], 4, "Stand up and step away.",
              transition=True),
        ]
    else:
        protocol = build_protocol(chairs, args.profile)
        if args.blocks:
            want = {b.strip().upper() for b in args.blocks.split(",")}
            protocol = [p for p in protocol if p.block in want]
        else:
            protocol = [p for p in protocol if p.block != "H"]

    if not protocol:
        print("nothing to run: no phases matched those blocks")
        return 1

    total = sum(p.duration for p in protocol)
    print(f"\nprotocol: {len(protocol)} phases, chairs {chairs}")
    print(f"recording time: {fmt_dur(total)}\n")
    by_block = {}
    for p in protocol:
        b = by_block.setdefault(p.block, [0, 0])
        b[0] += 1
        b[1] += p.duration
    for b in sorted(by_block):
        n, secs = by_block[b]
        print(f"  block {b}: {n:>3} phases, {fmt_dur(secs)}")
    print()

    if args.dry_run:
        for i, p in enumerate(protocol):
            occ = ",".join(str(c) for c in p.occupied) or "-"
            print(f"{i:>4} [{p.block}] {p.label:<28} "
                  f"target={str(p.target or '-'):<3} occupied={occ:<6} "
                  f"{p.duration:>4}s{'  (transition)' if p.transition else ''}")
        return 0

    if not LOG.exists():
        print(f"ERROR: {LOG} does not exist. Start the serial capture first.")
        return 1
    size0 = LOG.stat().st_size
    time.sleep(1.5)
    if LOG.stat().st_size == size0:
        print(f"ERROR: {LOG} is not growing -- the capture is not running or")
        print("the receiver is unplugged. Fix that before recording: the")
        print("protocol timing is the ground truth and cannot be re-run cheaply.")
        return 1

    OUT_DIR.mkdir(exist_ok=True)
    stamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    out_path = Path(args.out) if args.out else OUT_DIR / f"dataset_{stamp}.csv"
    events_path = out_path.with_name(out_path.stem + "_phases.csv")
    print(f"writing  {out_path}")
    print(f"phases   {events_path}\n")

    counts = run_session(protocol, out_path, events_path,
                         voice=not args.no_voice)
    print(f"packets recorded per chair: {dict(sorted(counts.items()))}")
    missing = [c for c in chairs if counts.get(c, 0) == 0]
    if missing:
        print(f"WARNING: chairs {missing} produced NO packets at all.")
    print(f"\nwrote {out_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
