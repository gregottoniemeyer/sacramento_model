"""Graphical live dashboard, running the REBUILT occupancy model.

WHY THIS EXISTS ALONGSIDE live_plot.py
live_plot.py is the window that actually runs on the Mac Mini, and it still
computes occupancy with the confidence-and-decay machinery that the 2026-07-29
rebuild deleted (CONFIDENCE_DECAY_SECONDS = 90, and so on). That is the model
which produced chairs stuck permanently OCCUPIED. This file imports
tools/occupancy_model.py directly, so what is on screen is what the deployed
model decides, and it is the same model tools/score_model.py scores.

WHAT IT SHOWS THAT A FREE/OCCUPIED READOUT CANNOT
The 2026-07-30 validation found the fleet is not uniform. With identical
firmware, thresholds and model, chair 6 separates 14 -> 36 while seated and
holds 100%, while chair 4 separates 13 -> 15 and holds only 47%. So each chair
gets its noise floor tracked live (learned only while FREE, never while
occupied, the same discipline the gyro bias tracker uses) and drawn under its
motion trace. A chair whose trace never lifts off its own floor when somebody
sits in it is not empty, it is deaf, and both states otherwise print FREE.

Usage:
  venv/bin/python tools/live_dashboard.py
Close the window to quit.
"""

import sys
import threading
import time
from collections import deque
from pathlib import Path

import matplotlib
import matplotlib.pyplot as plt
from matplotlib.animation import FuncAnimation

sys.path.insert(0, str(Path(__file__).resolve().parent))
from occupancy_model import ChairModel  # noqa: E402
import receiver_parse as rp             # noqa: E402

LOG = Path.home() / "motion_log.txt"
NUM_CHAIRS = 7
STALE_S = 3.0
HISTORY_S = 60.0
FLOOR_ALPHA = 1.0 / 256.0
SEP_WEAK, SEP_OK = 1.25, 1.6

# Measured on 2026-07-30 (dataset_20260730_122544.csv): seated/empty separation
# and how much of a real occupancy each chair actually held. Shown until a live
# sit replaces it, so the known-bad chairs are flagged the moment this opens.
KNOWN = {1: (1.64, 100), 2: (2.00, 100), 3: (1.93, 100), 4: (1.15, 47),
         5: (2.31, 99), 6: (2.57, 100), 7: (1.36, 73)}

REGIMES = {1: "Yurok Kinship", 2: "Hydraulic Mining", 3: "Reclamation & Levees",
           4: "Dams and Pumps", 5: "Environmental Reg", 6: "Climate Stress",
           7: "AI Extraction"}

BG, FG, MUTED = "#11131a", "#e8ecf4", "#7c869b"
GREEN, RED, AMBER, BLUE = "#3ddc84", "#ff5c5c", "#ffb340", "#5aa9ff"


class Chair:
    def __init__(self, n):
        self.n = n
        self.model = ChairModel()
        self.last_seen = None
        self.bad = 0
        self.floor = None
        self.hist = deque()          # (t, smax)
        self.stamps = deque(maxlen=40)
        self.rssi = None
        self.best_seated = 0.0

    def note(self, t, pkt):
        smax = max(pkt["stdX"], pkt["stdY"], pkt["stdZ"])
        self.rssi = pkt["rssi"]
        self.stamps.append(t)
        self.hist.append((t, smax))
        cut = t - HISTORY_S
        while self.hist and self.hist[0][0] < cut:
            self.hist.popleft()
        if self.model.occupied:
            self.best_seated = max(self.best_seated, smax)
        else:
            self.floor = float(smax) if self.floor is None else \
                self.floor + FLOOR_ALPHA * (smax - self.floor)

    def hz(self):
        if len(self.stamps) < 2:
            return 0.0
        span = self.stamps[-1] - self.stamps[0]
        return (len(self.stamps) - 1) / span if span > 0 else 0.0

    def online(self, now):
        return self.last_seen is not None and now - self.last_seen <= STALE_S

    def separation(self):
        """(ratio, is_live). Falls back to the validation figure."""
        if self.floor and self.best_seated:
            return self.best_seated / self.floor, True
        if self.n in KNOWN:
            return KNOWN[self.n][0], False
        return None, False


def reader(chairs, stop):
    for line in rp.follow(LOG, stop):
        pkt = rp.parse(line)
        if pkt is None:
            continue
        c = pkt["chair"]
        if not (1 <= c <= NUM_CHAIRS):
            continue
        ch = chairs[c]
        if pkt["fmt"] == "bad":
            ch.bad += 1
            continue
        if pkt["fmt"] != "sum":
            continue
        now = time.time()
        ch.last_seen = now
        ch.model.update(now, pkt["stdX"], pkt["stdY"], pkt["stdZ"],
                        pkt["peak"] or 0, pkt["yawSum"], pkt["yawN"],
                        pkt["gyroZ"])
        ch.note(now, pkt)


def main():
    chairs = {c: Chair(c) for c in range(1, NUM_CHAIRS + 1)}
    stop = threading.Event()
    threading.Thread(target=reader, args=(chairs, stop), daemon=True).start()

    plt.rcParams.update({"figure.facecolor": BG, "axes.facecolor": BG,
                         "text.color": FG, "axes.labelcolor": MUTED,
                         "xtick.color": MUTED, "ytick.color": MUTED,
                         "font.size": 9})
    fig = plt.figure(figsize=(13, 8.2))
    fig.canvas.manager.set_window_title("Sacramento River  |  chair occupancy")
    gs = fig.add_gridspec(NUM_CHAIRS + 1, 1, height_ratios=[0.7] + [1] * NUM_CHAIRS,
                          hspace=0.45, left=0.015, right=0.985,
                          top=0.965, bottom=0.045)

    head = fig.add_subplot(gs[0]); head.axis("off")
    title = head.text(0.0, 0.62, "", ha="left", va="center", fontsize=15,
                      fontweight="bold", color=FG)
    subtitle = head.text(0.0, 0.05, "", ha="left", va="center", fontsize=9,
                         color=MUTED)
    counter = head.text(1.0, 0.5, "", ha="right", va="center", fontsize=22,
                        fontweight="bold", color=FG)

    axes, arts = {}, {}
    for i, c in enumerate(range(1, NUM_CHAIRS + 1), start=1):
        ax = fig.add_subplot(gs[i])
        ax.set_xlim(-HISTORY_S, 0); ax.set_ylim(0, 60)
        ax.set_yticks([]); ax.set_xticks([])
        for s in ax.spines.values():
            s.set_color("#222736")
        (trace,) = ax.plot([], [], lw=1.4, color=BLUE)
        floor_ln = ax.axhline(0, ls="--", lw=1.0, color=MUTED, alpha=0.7)
        label = ax.text(-HISTORY_S + 0.6, 52, "", fontsize=11,
                        fontweight="bold", va="top", color=FG)
        regime = ax.text(-HISTORY_S + 0.6, 34, REGIMES[c], fontsize=8,
                         va="top", color=MUTED, style="italic")
        state = ax.text(0.845, 0.72, "", transform=ax.transAxes, fontsize=13,
                        fontweight="bold", ha="left", va="center", color=GREEN)
        detail = ax.text(0.845, 0.26, "", transform=ax.transAxes, fontsize=8,
                         ha="left", va="center", color=MUTED)
        sep = ax.text(0.66, 0.72, "", transform=ax.transAxes, fontsize=10,
                      fontweight="bold", ha="left", va="center", color=MUTED)
        link = ax.text(0.66, 0.26, "", transform=ax.transAxes, fontsize=8,
                       ha="left", va="center", color=MUTED)
        axes[c] = ax
        arts[c] = dict(trace=trace, floor=floor_ln, label=label, state=state,
                       detail=detail, sep=sep, link=link, regime=regime)

    def update(_):
        now = time.time()
        occupied = 0
        online = 0
        for c in range(1, NUM_CHAIRS + 1):
            ch, a, ax = chairs[c], arts[c], axes[c]
            up = ch.online(now)
            online += up

            if ch.hist:
                t0 = ch.hist[-1][0]
                a["trace"].set_data([t - t0 for t, _ in ch.hist],
                                    [v for _, v in ch.hist])
            if ch.floor:
                a["floor"].set_ydata([ch.floor, ch.floor])

            if not up:
                a["state"].set_text("OFFLINE")
                a["state"].set_color(MUTED)
                since = "never seen" if ch.last_seen is None else \
                    f"silent {now - ch.last_seen:.0f}s"
                a["detail"].set_text(f"{since}: flat battery or switched off")
                a["trace"].set_color("#333a4a")
            elif ch.model.occupied:
                occupied += 1
                a["state"].set_text("OCCUPIED")
                a["state"].set_color(RED)
                a["detail"].set_text(ch.model.reason[:34])
                a["trace"].set_color(RED)
                ax.set_facecolor("#1d1418")
            else:
                a["state"].set_text("FREE")
                a["state"].set_color(GREEN)
                r = ch.model.reason
                a["detail"].set_text("quiet" if r == "no data" else r[:34])
                a["trace"].set_color(BLUE)
                ax.set_facecolor(BG)

            ratio, live = ch.separation()
            if ratio is None:
                a["sep"].set_text("")
            else:
                mark = "WEAK" if ratio < SEP_WEAK else \
                       ("thin" if ratio < SEP_OK else "ok")
                col = RED if ratio < SEP_WEAK else \
                      (AMBER if ratio < SEP_OK else GREEN)
                a["sep"].set_text(f"{'' if live else '~'}{ratio:.2f}x {mark}")
                a["sep"].set_color(col)

            a["label"].set_text(f"chair {c}")
            if up:
                hz = ch.hz()
                fl = f"{ch.floor:.1f}" if ch.floor else "?"
                a["link"].set_text(f"floor {fl}   {hz:.1f} Hz   {ch.rssi} dBm"
                                   + ("   BAD PKT" if ch.bad else ""))
            else:
                a["link"].set_text("")

        title.set_text("CHAIR OCCUPANCY")
        counter.set_text(f"{occupied} / {NUM_CHAIRS}")
        counter.set_color(RED if occupied else MUTED)
        subtitle.set_text(
            f"rebuilt model (occupancy_model.py)   ·   {online}/{NUM_CHAIRS} "
            f"online   ·   {time.strftime('%H:%M:%S')}   ·   "
            f"WATCH CHAIR 4 (1.15x, held 47%) and CHAIR 7 (1.36x, held 73%)")
        return []

    # The return value MUST be held. matplotlib keeps only a weak reference to
    # a FuncAnimation, so an unassigned one is garbage-collected and its timer
    # dies while the window stays on screen: it draws frame one and then freezes
    # with no error, which looks exactly like a dead serial capture.
    anim = FuncAnimation(fig, update, interval=400, blit=False,
                         cache_frame_data=False)
    plt.show()
    del anim
    stop.set()


if __name__ == "__main__":
    main()
