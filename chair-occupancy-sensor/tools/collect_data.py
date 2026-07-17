"""Guided, labeled data-collection session for the chair occupancy project — v2.

Fresh protocol (2026-07-08), replacing the original single-surface session.
Two things this version adds that the first one didn't have:

1. Runs the whole protocol once per physical SURFACE the chair sits on
   (edit the SURFACES list below to match what you actually have available —
   e.g. hardwood, carpet/rug, tile). Floor-borne vibration from someone
   walking by should transmit differently depending on what's under the
   chair, and the first dataset only ever tested one surface.
2. Much more walk-by variety. The original session had a single 15s "nearby"
   phase — one distance, one speed, one direction — which is almost
   certainly why the walk-by rejection didn't generalize to real use. This
   version varies distance (close/far), speed (normal/fast), direction
   (front/behind), standing-still-nearby (no walking at all), and stomping
   nearby, each as its own labeled phase.

Between surfaces, the script PAUSES and waits for you to press SPACE after
physically moving the chair — it can't detect the surface itself.

Shows big on-screen instructions (with countdown + sound cues) while tailing
~/motion_log.txt, and writes every sample to a CSV with the ground-truth
phase label AND surface attached.
Output: ~/chair-project/labeled_session_<timestamp>.csv

Run with:  ~/chair-project/venv/bin/python ~/chair-project/collect_data.py
"""

import csv
import re
import subprocess
import time
from pathlib import Path

import matplotlib.pyplot as plt
from matplotlib.animation import FuncAnimation

LOG_FILE = Path.home() / "motion_log.txt"
OUT_FILE = Path.home() / "sacramento_model" / "chair-occupancy-sensor" / "data" / f"labeled_session_{int(time.time())}.csv"

# ---- EDIT THIS to match the surfaces you actually have available -----------
SURFACES = [
    "hard floor",
    "carpet",
]
# ------------------------------------------------------------------------------

LINE_RE = re.compile(
    r"Accel\s+X:(-?\d+)\s+Y:(-?\d+)\s+Z:(-?\d+)\s+"
    r"Gyro\s+X:(-?\d+)\s+Y:(-?\d+)\s+Z:(-?\d+)"
    r"(?:\s+Temp:(-?\d+))?"
)


# ---- Protocol: one block per surface, each block the same set of phases ----
def build_surface_block(surface):
    block = [
        dict(kind="timer", label="empty", surface=surface,
             text="Stand clear of the chair.\nDon't touch it.", secs=15),
    ]
    # Two full sit/active/still/stand cycles per surface (was one) — more
    # sit_down/stand_up examples and more seated-motion variety to tune on.
    for cycle in (1, 2):
        block += [
            dict(kind="timer", label="sit_down", surface=surface,
                 text=f"SIT DOWN now\n(naturally, cycle {cycle}/2)", secs=5, action=True),
            dict(kind="timer", label="seated_active", surface=surface,
                 text="Sit normally.\nSmall movements are fine.", secs=25),
            dict(kind="timer", label="seated_still", surface=surface,
                 text="Sit as STILL as you can.\nStatue mode.", secs=25),
            dict(kind="timer", label="stand_up", surface=surface,
                 text="STAND UP\nand step away.", secs=5, action=True),
            dict(kind="timer", label="empty", surface=surface,
                 text="Hands off. Stay clear.", secs=10),
        ]
    # Three bumps (was two).
    for n in (1, 2, 3):
        block += [
            dict(kind="timer", label="bump", surface=surface,
                 text=f"BUMP/KNOCK the chair\n(variation {n}/3).\nThen hands off!", secs=4, action=True),
            dict(kind="timer", label="empty", surface=surface,
                 text="Hands off. Stay clear.", secs=8),
        ]
    # --- walk-by variety: the main expansion over the first dataset ---
    # Two reps of each variant (was one) for a more reliable signal per label.
    walk_variants = [
        ("walk_close", "WALK past CLOSE to the chair\n(about one step away), normal pace.\nDon't touch it.", 10, False),
        ("walk_far", "WALK past FURTHER away\n(2-3 steps), normal pace.\nDon't touch it.", 10, False),
        ("walk_fast", "WALK/JOG BRISKLY past the chair,\nany distance. Don't touch it.", 10, False),
        ("walk_behind", "WALK past BEHIND the chair.\nDon't touch it.", 10, False),
        ("stand_near", "Walk up and STAND STILL\nright next to the chair.\nDon't touch it.", 10, False),
        ("stomp_near", "STOMP / jump in place\nNEAR the chair (not touching it).", 6, True),
        ("drop_near", "DROP a book/object on the floor\nNEAR the chair (not on it).", 5, True),
    ]
    for rep in (1, 2):
        for label, text, secs, action in walk_variants:
            block += [
                dict(kind="timer", label=label, surface=surface,
                     text=f"{text}\n(rep {rep}/2)", secs=secs, action=action),
                dict(kind="timer", label="empty", surface=surface,
                     text="Stay clear.", secs=7),
            ]
    block += [
        dict(kind="timer", label="empty", surface=surface,
             text="Final: stand clear.\nSurface block done.", secs=10),
    ]
    return block


def build_protocol():
    phases = []
    for i, surface in enumerate(SURFACES):
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


# ---- Data tailing -----------------------------------------------------------
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
    """Read new samples. If label is given, write them out with that label;
    otherwise just discard (used during manual/pause phases so the buffered
    log doesn't pile up while the chair is being moved)."""
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


# ---- UI ---------------------------------------------------------------------
fig = plt.figure(figsize=(9, 6))
fig.canvas.manager.set_window_title("Chair data collection v2 — follow the instructions")
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
        drain_log()  # discard trailing buffered samples
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
        drain_log()  # discard — chair is being physically moved
        if state["proceed"]:
            state["idx"] += 1
            state["phase_start"] = None
        return []

    # timer phase
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
