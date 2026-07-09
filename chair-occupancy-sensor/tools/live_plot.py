"""Live MPU-6050 dashboard for the chair occupancy project.

Reads new lines as they are appended to ~/motion_log.txt (written by the
background serial capture) and plots the last 10 seconds of accelerometer
and gyro data in two labeled charts.

Run with:  ~/chair-project/venv/bin/python ~/chair-project/live_plot.py
Stop with: Ctrl+C in the terminal, or just close the chart window.
"""

import collections
import re
import statistics
import time
from pathlib import Path

import matplotlib.pyplot as plt
from matplotlib.animation import FuncAnimation

# ============================================================================
#  OCCUPANCY MODEL CONSTANTS — everything tweakable lives here
# ============================================================================
CONFIDENCE_MAX = 100.0        # confidence right after person-like motion
# TWO-REGIME redesign (2026-07-08, after live testing showed the short-decay
# version failed both ways — statue sitters flipped FREE, and stand-ups felt
# undetected because the decay was doing all the work):
#   - While seated, presence is STICKY: confidence decays slowly (the decay
#     below is only a fallback for missed departures). Statue-sitting has
#     measured motion gaps up to ~19s, so any short decay is wrong by design.
#   - Responsiveness comes from the DEPARTURE EVENT instead: burst + super-
#     quiet confirmation drains confidence to 0 in DEPART_DRAIN_SECONDS.
#     Stand-ups read FREE in ~3-5s even though the decay is 90s.
CONFIDENCE_DECAY_SECONDS = 90.0  # slow fallback decay while no departure seen
OCCUPIED_WHEN_ABOVE = 5.0     # banner shows OCCUPIED while confidence > this

# What counts as "definitely a person on the chair" (either test fires).
# Tuned 2026-07-08 on the two-surface session (labeled_session_1783532146.csv,
# hard floor + carpet, 14 min): these values give ZERO false triggers on
# empty / all walk-by variants / standing near / stomping / dropped objects,
# on both surfaces. BIG_DELTA_RAW 500->3000 was the key fix (on carpet the
# chair rocks enough during walk-bys to fire 500 constantly); RATIO 0.9->0.65
# doubles seated-still coverage at no false-positive cost.
Z_MOTION_THRESHOLD_RAW = 15   # gyroZ 1s std-dev (raw counts) floor for the ratio test
RATIO_THRESHOLD = 0.65        # gyroZ std must exceed this * (gyroX std + gyroY std)
BIG_DELTA_RAW = 3000          # single-sample gyro jump (raw counts) = big motion...
BIG_DELTA_DEBOUNCE = 3        # ...if it happens >= this many times in 1s
# Known remaining weakness: a hard BUMP on the empty chair still triggers
# (false OCCUPIED until the decay runs out). Carpet also delays sit-down
# detection by ~2-3s (carpet absorbs the plop; detection starts once you
# settle in).

# Stand-up (departure) detection, v3 (2026-07-08). Signature: a burst (some
# gyro axis 1s std > 250) followed by empty-chair-grade quiet. The quiet bar
# (smax < 16) is the key discriminator, measured across both sessions: a
# truly empty chair sits at the noise floor (smax ~11-14) while a statue-
# sitting human still wobbles it slightly (median ~15-20, dips below 16 for
# at most ~2.7s at a time before a micro-movement pops back up).
#
# v3 replaced the old "smax < 16 continuously for 1s, starting within 5s of
# the burst" rule after backtesting showed two live failure modes:
#   1. An empty chair often HOVERS around the bar (13-18) for several
#      seconds after the person walks off — a strict continuous-quiet run
#      keeps resetting on single noise pops, and quiet frequently begins
#      more than 5s after the last burst, so the departure never confirmed
#      and the chair stayed OCCUPIED for the full 90s fallback decay.
#   2. The 1s quiet requirement was inside the statue-sitter dip range
#      (dips up to 2.7s), so real sitters could falsely read as departed.
# Fix: score quiet as a FRACTION of samples below the bar over a trailing
# window — robust to isolated pops. 0.70 over 4.5s demands ~3.2s of quiet,
# safely above the longest observed human dip (2.7s) and easily reached by
# an empty chair. Pairing window 12s (was 5s): statue dips with a burst
# 10.6-14.7s earlier exist in the data, so 12s max (15s was tested and
# falsely freed one statue segment; 12s frees none).
DEPART_BURST_STD_RAW = 250    # any gyro axis 1s std-dev above this arms the detector
DEPART_QUIET_STD_RAW = 16     # smax below this = one empty-chair-grade quiet sample
DEPART_QUIET_FRACTION = 0.70  # quiet-sample share needed over the quiet window
DEPART_QUIET_WINDOW = 4.5     # trailing seconds the quiet fraction is computed over
DEPART_PAIR_WINDOW = 12.0     # a burst within this many seconds pairs with the quiet
DEPART_DRAIN_SECONDS = 0.75   # confidence drains to 0 this fast once confirmed
# Burst-less safety net: if the chair is quiet 80% of a trailing 15s window,
# release it no matter what (no burst pairing needed). Catches departures
# whose wobble outlasted the pairing window AND clears the old known
# limitation where a bump on an empty chair stuck OCCUPIED for the full
# decay. A statue sitter never comes close (needs 12s of sub-16 quiet in
# 15s; longest observed human dip is 2.7s).
LONG_QUIET_WINDOW = 15.0      # trailing seconds for the burst-less release
LONG_QUIET_FRACTION = 0.80    # quiet share needed for the burst-less release
# ============================================================================

LOG_FILE = Path.home() / "motion_log.txt"
WINDOW_SECONDS = 10

# ---- Visual theme (light) ----------------------------------------------------
PAGE_BG = "#f9f9f7"        # window background
SURFACE = "#fcfcfb"        # chart surface
INK = "#0b0b0b"            # primary text
INK_2 = "#52514e"          # secondary text (axis titles)
MUTED = "#898781"          # tick labels, detail line
GRID = "#e1e0d9"           # hairline gridlines
BASELINE = "#c3c2b7"       # axis baseline
STATUS_OCCUPIED = "#d03b3b"
STATUS_FREE = "#0ca30c"
STATUS_WAIT = "#898781"
# Per-axis series colors, consistent across both charts (X/Y/Z keep the same
# hue in accel and gyro). Z gets blue — it's the trace the occupancy model
# watches, so it should be the most legible one.
AXIS_COLORS = {"X": "#1baf7a", "Y": "#eda100", "Z": "#2a78d6"}

plt.rcParams.update({
    "font.family": "sans-serif",
    "font.sans-serif": ["Helvetica Neue", "Arial", "DejaVu Sans"],
    "axes.edgecolor": BASELINE,
    "axes.labelcolor": INK_2,
    "xtick.color": MUTED,
    "ytick.color": MUTED,
    "text.color": INK,
})

# Matches: Accel  X:-12340  Y:212  Z:10700    Gyro  X:-1262  Y:-620  Z:63    Temp:2434
LINE_RE = re.compile(
    r"Accel\s+X:(-?\d+)\s+Y:(-?\d+)\s+Z:(-?\d+)\s+"
    r"Gyro\s+X:(-?\d+)\s+Y:(-?\d+)\s+Z:(-?\d+)\s+"
    r"Temp:(-?\d+)"
)

# One deque per series, holding (timestamp, value) pairs.
SERIES_NAMES = ["Accel X", "Accel Y", "Accel Z", "Gyro X", "Gyro Y", "Gyro Z"]
series = {name: collections.deque() for name in SERIES_NAMES}

# Sensitivity at the sensor's default range settings (±2g, ±250°/s):
# raw counts per unit. Dividing raw values by these converts to real units.
ACCEL_LSB_PER_G = 16384.0
GYRO_LSB_PER_DEG_S = 131.0


def to_physical_units(name, raw_value):
    if name.startswith("Accel"):
        return raw_value / ACCEL_LSB_PER_G
    return raw_value / GYRO_LSB_PER_DEG_S


def temp_raw_to_celsius(raw_value):
    return raw_value / 340.0 + 36.53


log = open(LOG_FILE, "r", errors="ignore")
log.seek(0, 2)  # start at the end: only show data from now on
partial = ""
last_read_time = time.time()
latest_temp_c = None


def read_new_samples():
    """Pull any newly appended lines out of the log file."""
    global partial, last_read_time, latest_temp_c
    chunk = log.read()
    if not chunk:
        return
    text = partial + chunk
    lines = text.split("\n")
    partial = lines.pop()  # last element may be a half-written line
    if not lines:
        return

    now = time.time()
    elapsed = now - last_read_time
    n = len(lines)
    # Spread this batch evenly across the time since the last read, instead
    # of stamping every sample in the batch with the same timestamp (which
    # collapses several real points onto one vertical line and produces a
    # boxy/staircase look).
    for i, line in enumerate(lines):
        m = LINE_RE.search(line)
        if not m:
            continue
        t = last_read_time + elapsed * (i + 1) / n
        *motion_values, temp_raw = [int(g) for g in m.groups()]
        for name, value in zip(SERIES_NAMES, motion_values):
            series[name].append((t, to_physical_units(name, value)))
        latest_temp_c = temp_raw_to_celsius(temp_raw)  # kept fresh; display is throttled separately
    last_read_time = now
    # Drop anything older than the display window.
    cutoff = now - WINDOW_SECONDS
    for dq in series.values():
        while dq and dq[0][0] < cutoff:
            dq.popleft()


# Confidence gets its own, longer time window — it does NOT share the x-axis
# with accel/gyro. Fixed width (the slow 90s fallback decay would make an
# auto-sized window uselessly wide; 40s comfortably shows arrivals, the flat
# occupied stretch, and the sub-second departure drain).
CONFIDENCE_WINDOW_SECONDS = 40

fig = plt.figure(figsize=(10, 9.4))
gs = fig.add_gridspec(3, 1, height_ratios=[1, 1, 0.6], hspace=0.35)
ax_accel = fig.add_subplot(gs[0])
ax_gyro = fig.add_subplot(gs[1], sharex=ax_accel)
ax_conf = fig.add_subplot(gs[2])
fig.canvas.manager.set_window_title("MPU-6050 live — chair sensor")
fig.patch.set_facecolor(PAGE_BG)

accel_lines = {}
gyro_lines = {}
for name in SERIES_NAMES[:3]:
    axis = name[-1]  # "X" / "Y" / "Z"
    (accel_lines[name],) = ax_accel.plot([], [], label=axis, linewidth=2,
                                         color=AXIS_COLORS[axis])
for name in SERIES_NAMES[3:]:
    axis = name[-1]
    (gyro_lines[name],) = ax_gyro.plot([], [], label=axis, linewidth=2,
                                       color=AXIS_COLORS[axis])

ax_accel.set_ylabel("Acceleration (g)", fontsize=11)
ax_gyro.set_ylabel("Angular velocity (°/s)", fontsize=11)
ax_conf.set_ylabel("Confidence", fontsize=11)
ax_conf.set_xlabel("Seconds ago", fontsize=11)
for ax in (ax_accel, ax_gyro, ax_conf):
    ax.set_facecolor(SURFACE)
    ax.grid(True, color=GRID, linewidth=0.8)
    ax.set_axisbelow(True)
    for side in ("top", "right"):
        ax.spines[side].set_visible(False)
    for side in ("left", "bottom"):
        ax.spines[side].set_color(BASELINE)
    ax.tick_params(labelsize=9, length=0)
ax_accel.set_xlim(-WINDOW_SECONDS, 0)
ax_conf.set_xlim(-CONFIDENCE_WINDOW_SECONDS, 0)
for ax in (ax_accel, ax_gyro):
    leg = ax.legend(loc="upper left", ncols=3, frameon=False,
                    fontsize=10, handlelength=1.2, columnspacing=1.2,
                    labelcolor=INK_2)

temp_text = fig.text(0.985, 0.975, "-- °C", ha="right", va="top",
                     fontsize=13, color=INK_2)
TEMP_DISPLAY_INTERVAL = 1.0  # seconds; sensor data arrives much faster than this
last_temp_display_update = 0.0

# Small yellow dot, upper-left corner: at-a-glance visual confirmation that
# the dashboard running on screen has picked up the latest pushed code.
fig.add_artist(plt.Circle((0.02, 0.975), 0.012, transform=fig.transFigure,
                          facecolor="#e6c300", edgecolor="none", zorder=10))

# ---- Occupancy detection: confidence-decay model -----------------------------
# One idea only: person-like motion snaps a confidence factor to
# CONFIDENCE_MAX; with no motion it decays linearly to 0 over
# CONFIDENCE_DECAY_SECONDS. Banner reads OCCUPIED while confidence is above
# OCCUPIED_WHEN_ABOVE. All tunable numbers live in the constants block at the
# very top of this file.
#
# "Person-like motion" = either:
#   (a) ratio test — gyroZ 1s std-dev above the Z floor AND Z std dominating
#       X+Y std (seated micro-motion is chair swivel, nearly pure Z; walk-by
#       floor vibration shakes all three axes and is rejected), OR
#   (b) big-motion test — repeated large sample-to-sample gyro jumps in 1s.
# (Converted once from raw counts to the °/s the charts use:)
Z_FLOOR = Z_MOTION_THRESHOLD_RAW / GYRO_LSB_PER_DEG_S
RATIO_EPS = 1.0 / GYRO_LSB_PER_DEG_S
BIG_DELTA = BIG_DELTA_RAW / GYRO_LSB_PER_DEG_S

occupancy_state = {"last_move": None, "confidence": 0.0,
                   "burst_at": None,      # time of last departure-strength jolt
                   "departed_at": None,   # when a departure was confirmed
                   "depart_base": 0.0}    # confidence value at that moment
DEPART_BURST = DEPART_BURST_STD_RAW / GYRO_LSB_PER_DEG_S
DEPART_QUIET = DEPART_QUIET_STD_RAW / GYRO_LSB_PER_DEG_S
quiet_history = collections.deque()       # (timestamp, is_quiet) pairs
confidence_history = collections.deque()  # (timestamp, confidence) pairs

# Big status banner: bold white text on a colored pill centered at the top.
status_text = fig.text(0.5, 0.955, "WAITING FOR DATA…", ha="center", va="center",
                       fontsize=28, fontweight="bold", color="white",
                       bbox=dict(boxstyle="round,pad=0.55,rounding_size=0.9",
                                 facecolor=STATUS_WAIT, edgecolor="none"))
# Small sub-line for the "how long" detail.
status_detail = fig.text(0.5, 0.895, "", ha="center", va="center",
                         fontsize=10, color=MUTED)

# Confidence chart: scrolling line + fill, same time axis as accel/gyro, with
# a dashed cutoff at the OCCUPIED/FREE threshold and a live number top-right.
ax_conf.set_ylim(0, CONFIDENCE_MAX)
(conf_line,) = ax_conf.plot([], [], linewidth=2, color=STATUS_FREE)
conf_fill = ax_conf.fill_between([], [], color=STATUS_FREE, alpha=0.15)
ax_conf.axhline(OCCUPIED_WHEN_ABOVE, color=INK_2, linewidth=1, linestyle="--")
conf_value = ax_conf.text(0.99, 0.92, "–", transform=ax_conf.transAxes,
                          ha="right", va="top", fontsize=13, fontweight="bold",
                          color=INK_2)


def set_banner(text, color, detail):
    status_text.set_text(text)
    status_text.get_bbox_patch().set_facecolor(color)
    status_detail.set_text(detail)


def gyro_stds_last_second(now):
    """1s trailing std-dev of each gyro axis, or None until enough data."""
    xs = [v for t, v in series["Gyro X"] if t >= now - 1.0]
    ys = [v for t, v in series["Gyro Y"] if t >= now - 1.0]
    zs = [v for t, v in series["Gyro Z"] if t >= now - 1.0]
    if len(zs) < 5:
        return None
    return statistics.pstdev(xs), statistics.pstdev(ys), statistics.pstdev(zs)


def big_motion_last_second(now):
    """>= BIG_DELTA_DEBOUNCE consecutive-sample deltas above BIG_DELTA in 1s."""
    count = 0
    for name in SERIES_NAMES[3:]:
        recent = [v for t, v in series[name] if t >= now - 1.0]
        count += sum(1 for a, b in zip(recent, recent[1:]) if abs(b - a) > BIG_DELTA)
    return count >= BIG_DELTA_DEBOUNCE


def person_motion(now):
    """True when the trailing 1s of gyro data looks like a person on the chair."""
    stds = gyro_stds_last_second(now)
    if stds is None:
        return False
    sx, sy, sz = stds
    ratio_test = sz > Z_FLOOR and sz / (sx + sy + RATIO_EPS) > RATIO_THRESHOLD
    return ratio_test or big_motion_last_second(now)


def update_occupancy(now):
    if person_motion(now):
        occupancy_state["last_move"] = now
        occupancy_state["departed_at"] = None  # person still here — cancel drain

    # Stand-up detection: a burst followed by mostly-quiet (fraction of
    # samples below the quiet bar) means the person left — start the fast
    # confidence drain. A long mostly-quiet stretch releases even without a
    # paired burst (safety net for missed departures and bumped empty chairs).
    stds = gyro_stds_last_second(now)
    if stds is not None:
        smax = max(stds)
        quiet_history.append((now, smax < DEPART_QUIET))
        cutoff = now - max(DEPART_QUIET_WINDOW, LONG_QUIET_WINDOW)
        while quiet_history and quiet_history[0][0] < cutoff:
            quiet_history.popleft()
        if smax > DEPART_BURST:
            occupancy_state["burst_at"] = now
        if occupancy_state["departed_at"] is None:
            short = [q for t, q in quiet_history if t >= now - DEPART_QUIET_WINDOW]
            frac_short = sum(short) / len(short) if short else 0.0
            frac_long = sum(q for _, q in quiet_history) / len(quiet_history)
            burst = occupancy_state["burst_at"]
            paired = burst is not None and now - burst <= DEPART_PAIR_WINDOW
            warmed_up = now - quiet_history[0][0] >= LONG_QUIET_WINDOW - 1.0
            if ((paired and frac_short >= DEPART_QUIET_FRACTION)
                    or (warmed_up and frac_long >= LONG_QUIET_FRACTION
                        and occupancy_state["confidence"] > 0)):
                occupancy_state["departed_at"] = now
                occupancy_state["depart_base"] = occupancy_state["confidence"]
                occupancy_state["burst_at"] = None

    last = occupancy_state["last_move"]
    departed = occupancy_state["departed_at"]
    if last is None:
        confidence = 0.0
        detail = "no recent person-motion"
    elif departed is not None:
        # Departure confirmed: drain from the value at confirmation to 0.
        frac = (now - departed) / DEPART_DRAIN_SECONDS
        confidence = max(0.0, occupancy_state["depart_base"] * (1.0 - frac))
        detail = "stand-up detected"
    else:
        quiet = now - last
        confidence = CONFIDENCE_MAX * max(0.0, 1.0 - quiet / CONFIDENCE_DECAY_SECONDS)
        detail = f"last motion {quiet:.0f}s ago"
    occupancy_state["confidence"] = confidence
    confidence_history.append((now, confidence))
    cutoff = now - CONFIDENCE_WINDOW_SECONDS
    while confidence_history and confidence_history[0][0] < cutoff:
        confidence_history.popleft()

    occupied = confidence > OCCUPIED_WHEN_ABOVE
    color = STATUS_OCCUPIED if occupied else STATUS_FREE
    set_banner("OCCUPIED" if occupied else "FREE", color, detail)
    conf_value.set_text(f"{confidence:.0f}")
    conf_value.set_color(color)

    global conf_fill
    xs = [t - now for t, _ in confidence_history]
    ys = [c for _, c in confidence_history]
    conf_line.set_data(xs, ys)
    conf_line.set_color(color)
    conf_fill.remove()
    conf_fill = ax_conf.fill_between(xs, ys, color=color, alpha=0.15)
# -----------------------------------------------------------------------------


def update(_frame):
    global last_temp_display_update
    read_new_samples()
    now = time.time()
    for name, line in list(accel_lines.items()) + list(gyro_lines.items()):
        data = series[name]
        xs = [t - now for t, _ in data]  # seconds ago (negative)
        ys = [v for _, v in data]
        line.set_data(xs, ys)
    ax_accel.relim(); ax_accel.autoscale_view(scalex=False)
    ax_gyro.relim(); ax_gyro.autoscale_view(scalex=False)

    update_occupancy(now)

    if latest_temp_c is not None and now - last_temp_display_update >= TEMP_DISPLAY_INTERVAL:
        temp_text.set_text(f"{latest_temp_c:.1f} °C")
        last_temp_display_update = now

    return []


ani = FuncAnimation(fig, update, interval=100, cache_frame_data=False)
fig.subplots_adjust(left=0.08, right=0.97, bottom=0.06, top=0.85)
plt.show()
