"""Live 7-chair dashboard for the chair occupancy project.

Reads new lines as they are appended to ~/motion_log.txt (written by the
background serial capture) and shows one row per chair: occupancy status,
confidence, accelerometer and gyro traces, temperature, and link health.

Expects the receiver to tag every line with the chair it came from:

    Chair:3  Accel  X:..  Y:..  Z:..    Gyro  X:..  Y:..  Z:..    Temp:..

An unrecognised board arrives as `Chair:?[mac]` and is surfaced in the
header rather than silently dropped.

Run with:  venv/bin/python tools/live_plot.py
Stop with: Ctrl+C in the terminal, or just close the window.
"""

import collections
import re
import statistics
import time
from pathlib import Path

import matplotlib.pyplot as plt
from matplotlib.animation import FuncAnimation
from matplotlib.patches import FancyBboxPatch, Rectangle

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
# window — robust to isolated pops. Pairing window 12s (was 5s): statue
# dips with a burst 10.6-14.7s earlier exist in the data, so 12s max (15s
# was tested and falsely freed one statue segment; 12s frees none).
#
# Window/fraction tightened 4.5s/0.70 -> 4.0s/0.65 on 2026-07-09 (requested:
# faster responses, occasional false positives acceptable). Backtest sweep
# across all three labeled sessions (not just two — the third session was
# initially missed and changes the picture: tighter settings that looked
# "only 1 new false-free" against two sessions turned out to have 2-3 new
# ones against the full corpus). 4.0s/0.65 is the point where the tradeoff
# is still genuinely "seldom": exactly 1 new false FREE (on top of one
# pre-existing, unrelated one) across all three sessions combined, for a
# ~10% latency cut. Every step past this tested (3.5/0.65, 4.5/0.65,
# 3.0/0.60) roughly doubled or tripled the false-free count for
# diminishing extra speed — re-run the full 3-session sweep before going
# further rather than guessing from a partial one.
DEPART_BURST_STD_RAW = 250    # any gyro axis 1s std-dev above this arms the detector
DEPART_QUIET_STD_RAW = 16     # smax below this = one empty-chair-grade quiet sample
DEPART_QUIET_FRACTION = 0.65  # quiet-sample share needed over the quiet window
DEPART_QUIET_WINDOW = 4.0     # trailing seconds the quiet fraction is computed over
DEPART_PAIR_WINDOW = 12.0     # a burst within this many seconds pairs with the quiet
# Drain shortened 0.75s -> 0.2s (2026-07-09): only affects how fast
# confidence falls to 0 AFTER a departure is already confirmed, so it's a
# free latency win with no false-free risk on its own (backtested clean).
# 0.2s is close to the practical floor anyway — the live dashboard updates
# on a 100ms tick, so anything shorter looks identical (1-2 frames).
DEPART_DRAIN_SECONDS = 0.2
# Burst-less safety net: if the chair is quiet 80% of a trailing 15s window,
# release it no matter what (no burst pairing needed). Catches departures
# whose wobble outlasted the pairing window AND clears the old known
# limitation where a bump on an empty chair stuck OCCUPIED for the full
# decay. A statue sitter never comes close (needs 12s of sub-16 quiet in
# 15s; longest observed human dip is 2.7s).
LONG_QUIET_WINDOW = 15.0      # trailing seconds for the burst-less release
LONG_QUIET_FRACTION = 0.80    # quiet share needed for the burst-less release
# ============================================================================

# ---- Link health / sensor health --------------------------------------------
# A chair with no packet for this long reads NO SIGNAL rather than FREE. Seven
# battery-powered boards means a flat cell is the *expected* failure, and
# silence must not be mistaken for an empty chair. 2s is ~200 missed samples
# at the 100Hz sender rate, far beyond any normal gap.
SIGNAL_TIMEOUT = 2.0
RATE_WINDOW = 2.0             # trailing seconds used for the per-chair Hz readout
EXPECTED_HZ = 100.0           # sender transmits every sample at 100Hz

# Sensor sanity, straight out of the 2026-07-22 bring-up: a stationary
# MPU-6050 must measure exactly 1g, because gravity is the only acceleration
# acting on it. A healthy board sits at 0.93-1.04g. The failures seen were far
# outside that — a board with a marginal VCC/GND joint read 0.000g on battery,
# and one with corrupted I2C read 2.008g. The band below is deliberately wide
# so that genuine motion (which legitimately swings magnitude) does not trip
# it; it is checked against the MEDIAN over several seconds, not an instant.
SENSOR_OK_LOW = 0.55
SENSOR_OK_HIGH = 1.60
SENSOR_CHECK_WINDOW = 5.0

LOG_FILE = Path.home() / "motion_log.txt"
WINDOW_SECONDS = 10           # sparkline span
NUM_CHAIRS = 7
MAX_PLOT_POINTS = 240         # decimate before drawing; 100Hz x 10s x 42 series
                              # is far more than any screen can resolve, and
                              # plotting it all is what makes the UI lag.

# Mirrors REGIMES in ../controller.py — chair N drives regime N. Kept as a
# literal rather than imported, since controller.py is a runnable script one
# directory up and importing it here would couple the two at start-up.
REGIMES = [
    "Yurok Kinship",
    "Hydraulic Mining",
    "Reclamation & Levees",
    "Dams and Pumps",
    "Environmental Reg",
    "Climate Stress",
    "AI Extraction",
]

# ---- Visual theme (light) ----------------------------------------------------
PAGE_BG = "#f9f9f7"
SURFACE = "#fcfcfb"
INK = "#0b0b0b"
INK_2 = "#52514e"
MUTED = "#898781"
GRID = "#e1e0d9"
BASELINE = "#c3c2b7"
STATUS_OCCUPIED = "#d03b3b"
STATUS_FREE = "#0ca30c"
STATUS_WAIT = "#898781"
STATUS_FAULT = "#c77b16"
ROW_ALT = "#f4f3ef"           # subtle banding so 7 rows stay readable
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

# Matches:  Chair:3  Accel  X:-12340 ... Temp:2434
# The chair token is either a digit or `?[AA:BB:...]` for an unknown board.
LINE_RE = re.compile(
    r"Chair:(\d+|\?\[[0-9A-Fa-f:]+\])\s+"
    r"Accel\s+X:(-?\d+)\s+Y:(-?\d+)\s+Z:(-?\d+)\s+"
    r"Gyro\s+X:(-?\d+)\s+Y:(-?\d+)\s+Z:(-?\d+)\s+"
    r"Temp:(-?\d+)"
)
# Same line without the Chair: prefix — i.e. a receiver still running firmware
# from before 2026-07-22. Detected only so the header can say so explicitly,
# instead of the dashboard sitting blank with no explanation.
LEGACY_RE = re.compile(r"Accel\s+X:(-?\d+)\s+Y:(-?\d+)\s+Z:(-?\d+)\s+Gyro")

SERIES_NAMES = ["Accel X", "Accel Y", "Accel Z", "Gyro X", "Gyro Y", "Gyro Z"]

# Sensitivity at the sensor's default range settings (±2g, ±250°/s):
# raw counts per unit. Dividing raw values by these converts to real units.
ACCEL_LSB_PER_G = 16384.0
GYRO_LSB_PER_DEG_S = 131.0

# (Converted once from raw counts to the °/s the charts use:)
Z_FLOOR = Z_MOTION_THRESHOLD_RAW / GYRO_LSB_PER_DEG_S
RATIO_EPS = 1.0 / GYRO_LSB_PER_DEG_S
BIG_DELTA = BIG_DELTA_RAW / GYRO_LSB_PER_DEG_S
DEPART_BURST = DEPART_BURST_STD_RAW / GYRO_LSB_PER_DEG_S
DEPART_QUIET = DEPART_QUIET_STD_RAW / GYRO_LSB_PER_DEG_S


def to_physical_units(name, raw_value):
    if name.startswith("Accel"):
        return raw_value / ACCEL_LSB_PER_G
    return raw_value / GYRO_LSB_PER_DEG_S


def temp_raw_to_celsius(raw_value):
    return raw_value / 340.0 + 36.53


class Chair:
    """Per-chair sample buffers plus one instance of the occupancy model.

    The model is unchanged from the single-chair version — same constants,
    same tests, same v3 departure logic — only made per-chair, since each
    board now needs its own confidence and quiet history.
    """

    def __init__(self, index):
        self.index = index                       # 0-based
        self.number = index + 1
        self.regime = REGIMES[index]
        self.series = {name: collections.deque() for name in SERIES_NAMES}
        self.packet_times = collections.deque()
        self.quiet_history = collections.deque()
        self.state = {"last_move": None, "confidence": 0.0,
                      "burst_at": None, "departed_at": None, "depart_base": 0.0}
        self.confidence = 0.0
        self.temp_c = None
        self.last_packet = None
        self.detail = ""

    # -- ingest ---------------------------------------------------------------
    def add_sample(self, t, motion_values, temp_raw):
        for name, value in zip(SERIES_NAMES, motion_values):
            self.series[name].append((t, to_physical_units(name, value)))
        self.temp_c = temp_raw_to_celsius(temp_raw)
        self.last_packet = t
        self.packet_times.append(t)

    def trim(self, now):
        cutoff = now - WINDOW_SECONDS
        for dq in self.series.values():
            while dq and dq[0][0] < cutoff:
                dq.popleft()
        while self.packet_times and self.packet_times[0] < now - RATE_WINDOW:
            self.packet_times.popleft()

    # -- health ---------------------------------------------------------------
    @property
    def online(self):
        return (self.last_packet is not None
                and time.time() - self.last_packet < SIGNAL_TIMEOUT)

    def rate_hz(self):
        if not self.packet_times:
            return 0.0
        span = max(self.packet_times[-1] - self.packet_times[0], 1e-6)
        return (len(self.packet_times) - 1) / span if len(self.packet_times) > 1 else 0.0

    def sensor_fault(self, now):
        """True when the accel magnitude is nowhere near 1g while at rest.

        Checked on the MEDIAN over several seconds so that real motion, which
        legitimately swings the magnitude around, does not trip it.
        """
        xs = [v for t, v in self.series["Accel X"] if t >= now - SENSOR_CHECK_WINDOW]
        ys = [v for t, v in self.series["Accel Y"] if t >= now - SENSOR_CHECK_WINDOW]
        zs = [v for t, v in self.series["Accel Z"] if t >= now - SENSOR_CHECK_WINDOW]
        n = min(len(xs), len(ys), len(zs))
        if n < 50:
            return False
        mags = [(xs[i] ** 2 + ys[i] ** 2 + zs[i] ** 2) ** 0.5 for i in range(n)]
        med = statistics.median(mags)
        return not (SENSOR_OK_LOW <= med <= SENSOR_OK_HIGH)

    # -- occupancy model (logic identical to the single-chair version) --------
    def gyro_stds_last_second(self, now):
        xs = [v for t, v in self.series["Gyro X"] if t >= now - 1.0]
        ys = [v for t, v in self.series["Gyro Y"] if t >= now - 1.0]
        zs = [v for t, v in self.series["Gyro Z"] if t >= now - 1.0]
        if len(zs) < 5:
            return None
        return statistics.pstdev(xs), statistics.pstdev(ys), statistics.pstdev(zs)

    def big_motion_last_second(self, now):
        count = 0
        for name in SERIES_NAMES[3:]:
            recent = [v for t, v in self.series[name] if t >= now - 1.0]
            count += sum(1 for a, b in zip(recent, recent[1:]) if abs(b - a) > BIG_DELTA)
        return count >= BIG_DELTA_DEBOUNCE

    def person_motion(self, now):
        stds = self.gyro_stds_last_second(now)
        if stds is None:
            return False
        sx, sy, sz = stds
        ratio_test = sz > Z_FLOOR and sz / (sx + sy + RATIO_EPS) > RATIO_THRESHOLD
        return ratio_test or self.big_motion_last_second(now)

    def update_occupancy(self, now):
        st = self.state
        if self.person_motion(now):
            st["last_move"] = now
            st["departed_at"] = None  # person still here — cancel drain

        stds = self.gyro_stds_last_second(now)
        if stds is not None:
            smax = max(stds)
            self.quiet_history.append((now, smax < DEPART_QUIET))
            cutoff = now - max(DEPART_QUIET_WINDOW, LONG_QUIET_WINDOW)
            while self.quiet_history and self.quiet_history[0][0] < cutoff:
                self.quiet_history.popleft()
            if smax > DEPART_BURST:
                st["burst_at"] = now
            if st["departed_at"] is None:
                short = [q for t, q in self.quiet_history
                         if t >= now - DEPART_QUIET_WINDOW]
                frac_short = sum(short) / len(short) if short else 0.0
                frac_long = (sum(q for _, q in self.quiet_history)
                             / len(self.quiet_history))
                burst = st["burst_at"]
                paired = burst is not None and now - burst <= DEPART_PAIR_WINDOW
                warmed_up = now - self.quiet_history[0][0] >= LONG_QUIET_WINDOW - 1.0
                if ((paired and frac_short >= DEPART_QUIET_FRACTION)
                        or (warmed_up and frac_long >= LONG_QUIET_FRACTION
                            and st["confidence"] > 0)):
                    st["departed_at"] = now
                    st["depart_base"] = st["confidence"]
                    st["burst_at"] = None

        last = st["last_move"]
        departed = st["departed_at"]
        if last is None:
            confidence = 0.0
            detail = "no recent person-motion"
        elif departed is not None:
            frac = (now - departed) / DEPART_DRAIN_SECONDS
            confidence = max(0.0, st["depart_base"] * (1.0 - frac))
            detail = "stand-up detected"
        else:
            quiet = now - last
            confidence = CONFIDENCE_MAX * max(
                0.0, 1.0 - quiet / CONFIDENCE_DECAY_SECONDS)
            detail = f"last motion {quiet:.0f}s ago"
        st["confidence"] = confidence
        self.confidence = confidence
        self.detail = detail

    @property
    def occupied(self):
        return self.online and self.confidence > OCCUPIED_WHEN_ABOVE


chairs = [Chair(i) for i in range(NUM_CHAIRS)]
unknown_macs = {}          # mac string -> last seen timestamp
legacy_lines_seen = [0]    # boxed so the reader can mutate it


# ---- log reader --------------------------------------------------------------
class LogReader:
    """Tails the capture file, and re-opens it if it is replaced or truncated.

    Restarting the serial capture with `>` truncates the log out from under
    this process, which previously left the dashboard showing stale data with
    no error at all (see README, "Running the live pipeline"). Detecting a
    shrinking file and re-opening removes that trap.
    """

    def __init__(self, path):
        self.path = path
        self.fh = None
        self.partial = ""
        self._open(seek_end=True)

    def _open(self, seek_end):
        try:
            self.fh = open(self.path, "r", errors="ignore")
            if seek_end:
                self.fh.seek(0, 2)
            self.partial = ""
        except FileNotFoundError:
            self.fh = None

    def read_lines(self):
        if self.fh is None:
            self._open(seek_end=False)
            if self.fh is None:
                return []
        try:
            size = self.path.stat().st_size
        except FileNotFoundError:
            self.fh = None
            return []
        if size < self.fh.tell():          # truncated / replaced
            self._open(seek_end=False)
            if self.fh is None:
                return []
        chunk = self.fh.read()
        if not chunk:
            return []
        text = self.partial + chunk
        lines = text.split("\n")
        self.partial = lines.pop()
        return lines


reader = LogReader(LOG_FILE)
last_read_time = time.time()


def read_new_samples():
    global last_read_time
    lines = reader.read_lines()
    now = time.time()
    if not lines:
        last_read_time = now
        for c in chairs:
            c.trim(now)
        return

    elapsed = max(now - last_read_time, 1e-6)
    n = len(lines)
    # Spread the batch evenly across the time since the last read rather than
    # stamping every sample identically, which would collapse many real points
    # onto one vertical line.
    for i, line in enumerate(lines):
        m = LINE_RE.search(line)
        if not m:
            if LEGACY_RE.search(line):
                legacy_lines_seen[0] += 1
            continue
        t = last_read_time + elapsed * (i + 1) / n
        token = m.group(1)
        values = [int(g) for g in m.groups()[1:]]
        *motion_values, temp_raw = values
        if token.startswith("?"):
            unknown_macs[token[2:-1]] = t
            continue
        idx = int(token) - 1
        if 0 <= idx < NUM_CHAIRS:
            chairs[idx].add_sample(t, motion_values, temp_raw)
    last_read_time = now
    for c in chairs:
        c.trim(now)


def decimate(pairs, now):
    """Thin a deque down to at most MAX_PLOT_POINTS (x = seconds ago)."""
    if not pairs:
        return [], []
    step = max(1, len(pairs) // MAX_PLOT_POINTS)
    sl = list(pairs)[::step]
    return [t - now for t, _ in sl], [v for _, v in sl]


# ---- figure ------------------------------------------------------------------
fig = plt.figure(figsize=(24, 13.5))
fig.canvas.manager.set_window_title("Sacramento Model — 7 chair sensors")
fig.patch.set_facecolor(PAGE_BG)

gs = fig.add_gridspec(
    NUM_CHAIRS, 3, width_ratios=[2.25, 3.4, 3.4],
    left=0.012, right=0.988, top=0.885, bottom=0.045, hspace=0.28, wspace=0.10,
)

header_title = fig.text(0.012, 0.965, "SACRAMENTO MODEL — CHAIR SENSORS",
                        ha="left", va="center", fontsize=21, fontweight="bold",
                        color=INK)
header_count = fig.text(0.5, 0.963, "—", ha="center", va="center",
                        fontsize=34, fontweight="bold", color=STATUS_WAIT)
header_regime = fig.text(0.5, 0.921, "", ha="center", va="center",
                         fontsize=14, color=INK_2)
header_link = fig.text(0.988, 0.968, "", ha="right", va="center",
                       fontsize=13, color=MUTED)
header_warn = fig.text(0.988, 0.933, "", ha="right", va="center",
                       fontsize=12, color=STATUS_FAULT, fontweight="bold")

# Small yellow dot, upper-left: at-a-glance confirmation that the dashboard on
# screen is running the latest pushed code.
fig.add_artist(plt.Circle((0.006, 0.965), 0.004, transform=fig.transFigure,
                          facecolor="#e6c300", edgecolor="none", zorder=10))

rows = []
for i, chair in enumerate(chairs):
    ax_id = fig.add_subplot(gs[i, 0])
    ax_acc = fig.add_subplot(gs[i, 1])
    ax_gyr = fig.add_subplot(gs[i, 2])

    # --- identity / status panel (drawn in 0..1 axes coordinates) ---
    ax_id.set_xlim(0, 1)
    ax_id.set_ylim(0, 1)
    ax_id.set_xticks([])
    ax_id.set_yticks([])
    ax_id.set_facecolor(ROW_ALT if i % 2 else SURFACE)
    for side in ax_id.spines.values():
        side.set_visible(False)

    t_num = ax_id.text(0.035, 0.66, str(chair.number), fontsize=40,
                       fontweight="bold", color=INK, va="center", ha="left")
    t_regime = ax_id.text(0.20, 0.80, chair.regime, fontsize=13,
                          color=INK_2, va="center", ha="left")
    pill = FancyBboxPatch((0.20, 0.44), 0.42, 0.26,
                          boxstyle="round,pad=0.012,rounding_size=0.06",
                          facecolor=STATUS_WAIT, edgecolor="none",
                          transform=ax_id.transAxes)
    ax_id.add_patch(pill)
    t_status = ax_id.text(0.41, 0.575, "NO SIGNAL", fontsize=15,
                          fontweight="bold", color="white",
                          va="center", ha="center")

    # confidence bar
    ax_id.add_patch(Rectangle((0.20, 0.245), 0.72, 0.10, facecolor=GRID,
                              edgecolor="none", transform=ax_id.transAxes))
    bar = Rectangle((0.20, 0.245), 0.0, 0.10, facecolor=STATUS_WAIT,
                    edgecolor="none", transform=ax_id.transAxes)
    ax_id.add_patch(bar)
    t_conf = ax_id.text(0.955, 0.295, "0", fontsize=12, color=INK_2,
                        va="center", ha="right", fontweight="bold")
    t_meta = ax_id.text(0.035, 0.09, "", fontsize=11, color=MUTED,
                        va="center", ha="left")

    # --- traces ---
    acc_lines, gyr_lines = {}, {}
    for axis in ("X", "Y", "Z"):
        (acc_lines[axis],) = ax_acc.plot([], [], linewidth=1.4,
                                         color=AXIS_COLORS[axis], label=axis)
        (gyr_lines[axis],) = ax_gyr.plot([], [], linewidth=1.4,
                                         color=AXIS_COLORS[axis], label=axis)
    # Fixed scales, deliberately: chairs stay directly comparable at a glance,
    # and there is no autoscale cost every frame.
    ax_acc.set_ylim(-2.0, 2.0)
    ax_gyr.set_ylim(-250, 250)
    for ax in (ax_acc, ax_gyr):
        ax.set_xlim(-WINDOW_SECONDS, 0)
        ax.set_facecolor(ROW_ALT if i % 2 else SURFACE)
        ax.grid(True, color=GRID, linewidth=0.7)
        ax.set_axisbelow(True)
        for side in ("top", "right"):
            ax.spines[side].set_visible(False)
        for side in ("left", "bottom"):
            ax.spines[side].set_color(BASELINE)
        ax.tick_params(labelsize=8, length=0)
        if i != NUM_CHAIRS - 1:
            ax.set_xticklabels([])
    if i == 0:
        ax_acc.set_title("Acceleration (g)", fontsize=12, color=INK_2, pad=8)
        ax_gyr.set_title("Angular velocity (°/s)", fontsize=12, color=INK_2, pad=8)
        ax_acc.legend(loc="upper right", ncols=3, frameon=False, fontsize=9,
                      handlelength=1.0, columnspacing=1.0, labelcolor=INK_2)
    if i == NUM_CHAIRS - 1:
        ax_acc.set_xlabel("Seconds ago", fontsize=10)
        ax_gyr.set_xlabel("Seconds ago", fontsize=10)

    rows.append(dict(pill=pill, t_status=t_status, bar=bar, t_conf=t_conf,
                     t_meta=t_meta, t_num=t_num, t_regime=t_regime,
                     acc=acc_lines, gyr=gyr_lines))

dominant = {"chair": None}


def update(_frame):
    read_new_samples()
    now = time.time()
    occupied_count = 0

    for chair, row in zip(chairs, rows):
        chair.update_occupancy(now)
        online = chair.online
        fault = online and chair.sensor_fault(now)

        if not online:
            label, color = "NO SIGNAL", STATUS_WAIT
        elif fault:
            label, color = "SENSOR FAULT", STATUS_FAULT
        elif chair.occupied:
            label, color = "OCCUPIED", STATUS_OCCUPIED
        else:
            label, color = "FREE", STATUS_FREE

        if chair.occupied and not fault:
            occupied_count += 1
            if dominant["chair"] != chair.number:
                dominant["chair"] = chair.number

        row["pill"].set_facecolor(color)
        row["t_status"].set_text(label)
        row["bar"].set_width(0.72 * chair.confidence / CONFIDENCE_MAX)
        row["bar"].set_facecolor(color)
        row["t_conf"].set_text(f"{chair.confidence:.0f}")
        row["t_num"].set_color(INK if online else MUTED)
        row["t_regime"].set_color(INK_2 if online else MUTED)

        if online:
            temp = f"{chair.temp_c:.1f} °C" if chair.temp_c is not None else "-- °C"
            meta = f"{temp}   ·   {chair.rate_hz():.0f} Hz   ·   {chair.detail}"
        elif chair.last_packet is None:
            meta = "never seen"
        else:
            meta = f"silent {now - chair.last_packet:.0f}s  ·  check battery"
        row["t_meta"].set_text(meta)
        row["t_meta"].set_color(STATUS_FAULT if fault else MUTED)

        for axis in ("X", "Y", "Z"):
            xs, ys = decimate(chair.series[f"Accel {axis}"], now)
            row["acc"][axis].set_data(xs, ys)
            xs, ys = decimate(chair.series[f"Gyro {axis}"], now)
            row["gyr"][axis].set_data(xs, ys)

    header_count.set_text(f"{occupied_count} / {NUM_CHAIRS} OCCUPIED")
    header_count.set_color(STATUS_OCCUPIED if occupied_count else STATUS_WAIT)
    if dominant["chair"] and occupied_count:
        header_regime.set_text(
            f"dominant regime — {REGIMES[dominant['chair'] - 1]}")
    else:
        header_regime.set_text("no chair occupied")

    online_n = sum(1 for c in chairs if c.online)
    total_hz = sum(c.rate_hz() for c in chairs)
    header_link.set_text(f"{online_n}/{NUM_CHAIRS} boards online   ·   "
                         f"{total_hz:.0f} samples/s")

    warn = []
    recent_unknown = [mac for mac, t in unknown_macs.items() if now - t < 10]
    if recent_unknown:
        warn.append("unrecognised board: " + ", ".join(sorted(recent_unknown)))
    if legacy_lines_seen[0] and online_n == 0:
        warn.append("receiver firmware predates chair tagging — reflash it")
    header_warn.set_text("   ".join(warn))

    return []


ani = FuncAnimation(fig, update, interval=150, cache_frame_data=False)
plt.show()
