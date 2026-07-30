"""Focused labeled data-collection session: JUST sit-down/stand-up variety.

Follow-up to the first two-surface session (labeled_session_1783532146.csv),
which only had 4 stand-up examples total — too thin to trust the departure-
detection burst/quiet thresholds in live_plot.py. This session gets many more
reps, varies the STYLE of sitting/standing (normal/slow/quick), and adds two
edge cases that specifically stress-test false positives in the departure
detector:
  - jerk_freeze:  jerk/twitch once, then go completely statue-still (checks
    that a single sharp seated movement doesn't get mistaken for departure)
  - partial_rise: half-rise (like reaching for something) then sit back down
    (checks that an aborted stand-up doesn't get mistaken for a real one)

Runs once per surface, same manual "move the chair, press SPACE" pause
pattern as collect_data.py.

Output: ~/chair-project/standup_session_<timestamp>.csv (same columns as the
v2 collect_data.py output: t, phase_idx, label, surface, accX..gyroZ, temp)

Run with:  ~/chair-project/venv/bin/python ~/chair-project/collect_standup_data.py
"""

import csv
import re
import subprocess
import time
from pathlib import Path

import matplotlib.pyplot as plt
from matplotlib.animation import FuncAnimation

LOG_FILE = Path.home() / "motion_log.txt"
OUT_FILE = Path.home() / "sacramento_model" / "chair-occupancy-sensor" / "data" / f"standup_session_{int(time.time())}.csv"

SURFACES = ["hard floor", "carpet"]

LINE_RE = re.compile(
    r"Accel\s+X:(-?\d+)\s+Y:(-?\d+)\s+Z:(-?\d+)\s+"
    r"Gyro\s+X:(-?\d+)\s+Y:(-?\d+)\s+Z:(-?\d+)"
    r"(?:\s+Temp:(-?\d+))?"
)


def build_surface_block(surface):
    block = [
        dict(kind="timer", label="empty", surface=surface,
             text="Stand clear of the chair.\nDon't touch it.", secs=5),
    ]
    # Vary the STYLE of sitting down / standing up: normal, slow, quick.
    # Trimmed 2026-07-08 at Max's request: we already have plenty of
    # seated_still/seated_active data from the first session, so the holds
    # here are just long enough to confirm a clean transition, not to
    # re-characterize stillness. 2 reps/style (was 3).
    styles = [
        ("normal", "naturally, normal speed"),
        ("slow", "SLOWLY and deliberately"),
        ("quick", "QUICKLY / abruptly"),
    ]
    for style, style_text in styles:
        for rep in (1, 2):
            block += [
                dict(kind="timer", label=f"sit_down_{style}", surface=surface,
                     text=f"SIT DOWN {style_text}\n(rep {rep}/2)", secs=4, action=True),
                dict(kind="timer", label="seated_still", surface=surface,
                     text="Sit still for a moment.", secs=3),
                dict(kind="timer", label=f"stand_up_{style}", surface=surface,
                     text=f"STAND UP {style_text}\nand step away\n(rep {rep}/2)", secs=4, action=True),
                dict(kind="timer", label="empty", surface=surface,
                     text="Stay clear.", secs=3),
            ]
    # Edge case 1: jerk then freeze — must NOT look like a departure.
    for rep in (1, 2, 3):
        block += [
            dict(kind="timer", label="empty", surface=surface,
                 text="Stand clear.", secs=3),
            dict(kind="timer", label="sit_down_normal", surface=surface,
                 text="SIT DOWN normally.", secs=4, action=True),
            dict(kind="timer", label="jerk_freeze", surface=surface,
                 text=f"JERK/twitch ONCE,\nthen FREEZE completely still.\n(rep {rep}/3)",
                 secs=3, action=True),
            dict(kind="timer", label="seated_still", surface=surface,
                 text="Keep holding still.", secs=5),
            dict(kind="timer", label="stand_up_normal", surface=surface,
                 text="STAND UP and step away.", secs=4, action=True),
        ]
    # Edge case 2: partial/aborted rise — must NOT look like a departure.
    for rep in (1, 2):
        block += [
            dict(kind="timer", label="empty", surface=surface,
                 text="Stand clear.", secs=3),
            dict(kind="timer", label="sit_down_normal", surface=surface,
                 text="SIT DOWN normally.", secs=4, action=True),
            dict(kind="timer", label="seated_still", surface=surface,
                 text="Sit for a moment.", secs=3),
            dict(kind="timer", label="partial_rise", surface=surface,
                 text=f"HALF-RISE (like reaching\nfor something), then\nSIT BACK DOWN.\n(rep {rep}/2)",
                 secs=4, action=True),
            dict(kind="timer", label="seated_still", surface=surface,
                 text="Settle back in, hold still.", secs=4),
            dict(kind="timer", label="stand_up_normal", surface=surface,
                 text="Now STAND UP for real\nand step away.", secs=4, action=True),
        ]
    block += [
        dict(kind="timer", label="empty", surface=surface,
             text="Final: stand clear.\nSurface block done.", secs=5),
    ]
    return block


def build_protocol():
    phases = []
    for surface in SURFACES:
        phases.append(dict(
            kind="manual", surface=surface,
            text=f"Move the chair onto:\n{surface}\n\n"
                 f"Check the sensor board (on the chair) and the receiver\n"
                 f"(on USB) are both still connected.\n\n"
                 f"Press SPACE when ready.",
        ))
        phases += build_surface_block(surface)
    return phases


PROTOCOL = build_protocol()


def beep():
    subprocess.Popen(["afplay", "/System/Library/Sounds/Ping.aiff"],
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


log = open(LOG_FILE, "r", errors="ignore")
log.seek(0, 2)
partial = ""
last_read_time = time.time()

out = open(OUT_FILE, "w", newline="")
writer = csv.writer(out)
writer.writerow(["t", "phase_idx", "label", "surface", "accX", "accY", "accZ",
                 "gyroX", "gyroY", "gyroZ", "temp"])
sample_counts = {}


def drain_log(phase_idx=None, label=None, surface=None):
    global partial, last_read_time
    chunk = log.read()
    if not chunk:
        return
    text = partial + chunk
    lines = text.split("\n")
    partial = lines.pop()
    if not lines:
        return
    now = time.time()
    elapsed = now - last_read_time
    n = len(lines)
    if label is not None:
        for i, line in enumerate(lines):
            m = LINE_RE.search(line)
            if not m:
                continue
            t = last_read_time + elapsed * (i + 1) / n
            vals = [g if g is not None else "" for g in m.groups()]
            writer.writerow([f"{t:.3f}", phase_idx, label, surface] + list(vals))
            sample_counts[label] = sample_counts.get(label, 0) + 1
    last_read_time = now


fig = plt.figure(figsize=(9, 6))
fig.canvas.manager.set_window_title("Stand-up data collection — follow the instructions")
instruction = fig.text(0.5, 0.55, "Get ready...", ha="center", va="center",
                       fontsize=26, fontweight="bold", wrap=True)
countdown = fig.text(0.5, 0.22, "", ha="center", va="center", fontsize=48)
progress = fig.text(0.5, 0.93, "", ha="center", va="top", fontsize=12, color="gray")

state = {"idx": 0, "phase_start": None, "start": None, "done": False, "proceed": False}


def on_key(event):
    if event.key == " ":
        state["proceed"] = True


fig.canvas.mpl_connect("key_press_event", on_key)


def finish():
    state["done"] = True
    out.flush()
    beep(); beep()
    instruction.set_text("DONE!\nYou can close this window.")
    instruction.set_color("tab:green")
    countdown.set_text("")
    summary = ", ".join(f"{k}:{v}" for k, v in sorted(sample_counts.items()))
    progress.set_text(f"saved {OUT_FILE.name}  ·  {summary}")
    print(f"saved: {OUT_FILE}")
    print("samples per label:", sample_counts)


def update(_frame):
    now = time.time()
    if state["start"] is None:
        state["start"] = now
        instruction.set_text("Starting in a moment...\nFollow the instructions.\nSound plays at each step.\nSpacebar advances the pause screens.")
        beep()
        return []
    if state["done"]:
        return []

    idx = state["idx"]
    if idx >= len(PROTOCOL):
        drain_log()
        finish()
        return []

    phase = PROTOCOL[idx]
    if state["phase_start"] is None:
        state["phase_start"] = now
        state["proceed"] = False
        beep()
        instruction.set_text(phase["text"])
        instruction.set_color("tab:purple" if phase["kind"] == "manual"
                              else ("tab:red" if phase.get("action") else "tab:blue"))

    step_no = idx + 1
    progress.set_text(f"step {step_no}/{len(PROTOCOL)}  ·  surface: {phase['surface']}")

    if phase["kind"] == "manual":
        countdown.set_text("press SPACE")
        drain_log()
        if state["proceed"]:
            state["idx"] += 1
            state["phase_start"] = None
        return []

    remaining = phase["secs"] - (now - state["phase_start"])
    countdown.set_text(f"{max(remaining, 0):.0f}")
    drain_log(idx, phase["label"], phase["surface"])
    if remaining <= 0:
        state["idx"] += 1
        state["phase_start"] = None
    return []


ani = FuncAnimation(fig, update, interval=100, cache_frame_data=False)
plt.show()
out.flush()
out.close()
print(f"session file: {OUT_FILE}")
