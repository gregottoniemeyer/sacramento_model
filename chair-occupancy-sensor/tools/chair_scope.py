"""Single-chair diagnostic scope: every signal the model uses, properly scaled.

The 7-chair dashboard has to fit 42 traces on one screen, so each one is tiny
and auto-scaled into uselessness. This shows ONE chair with each signal on its
own axes at a scale where you can actually see what the model is reacting to,
and the model's own intermediate values next to the raw data.

Panels, top to bottom:
  1. Gyro X/Y/Z in deg/s -- the raw motion signal.
  2. Gyro std-dev per axis over a trailing 1s, in raw counts, with the
     Z-floor threshold drawn. This is what the ratio test consumes.
  3. Z-dominance ratio, sz/(sx+sy), with the threshold drawn. Above the line
     and above the floor = "gyro-Z dominant motion", i.e. a swivel.
  4. Net yaw rotation over a trailing 6s, bias corrected, in degrees. A real
     swivel accumulates angle; footstep vibration integrates back to zero.
     This is the discriminator that separates sitting down from walking past.
  5. The decision: vote fraction with enter/exit bands, and the OCCUPIED state.

Works with either firmware. Raw 100Hz lines give every panel; 8Hz summary
lines have no per-sample detail, so panel 1 shows the transmitted means and
panel 4 is unavailable (net yaw cannot be recovered from a std-dev).

Usage:
  venv/bin/python tools/chair_scope.py            # chair 2
  venv/bin/python tools/chair_scope.py --chair 5
"""

import argparse
import collections
import os
import re
import statistics
import time
from pathlib import Path

import matplotlib.pyplot as plt
from matplotlib.animation import FuncAnimation

LOG = Path.home() / "motion_log.txt"

# ---- model constants (the rebuilt model; see NOTES.md 2026-07-29) ----------
Z_FLOOR_RAW = 15         # gyro-Z 1s std must clear this
RATIO_THRESHOLD = 0.65   # ...and dominate X+Y by this much
VOTE_WINDOW = 5.0        # seconds of votes that decide occupancy
ENTER_FRAC = 0.50        # fraction of firing windows to become OCCUPIED
EXIT_FRAC = 0.25         # ...and to drop back to FREE (hysteresis)
YAW_WINDOW = 6.0         # trailing seconds for net rotation
YAW_MIN_DEG = 1.0        # net yaw required to ENTER (walk-bys peak at 0.8)
GYRO_LSB = 131.0

SPAN = 30.0              # seconds of history on screen

V2_RE = re.compile(
    r"Chair:(\d+)\s+Accel\s+X:(-?\d+)\s+Y:(-?\d+)\s+Z:(-?\d+)\s+"
    r"Gyro\s+X:(-?\d+)\s+Y:(-?\d+)\s+Z:(-?\d+)\s+Temp:(-?\d+)\s+"
    r"Std\s+X:(\d+)\s+Y:(\d+)\s+Z:(\d+)")
V1_RE = re.compile(
    r"Chair:(\d+)\s+Accel\s+X:(-?\d+)\s+Y:(-?\d+)\s+Z:(-?\d+)\s+"
    r"Gyro\s+X:(-?\d+)\s+Y:(-?\d+)\s+Z:(-?\d+)\s+Temp:(-?\d+)")

PAGE_BG = "#f9f9f7"
INK = "#0b0b0b"
GRID = "#e1e0d9"
AX = {"X": "#1baf7a", "Y": "#eda100", "Z": "#2a78d6"}
OCC = "#d03b3b"
FREE = "#0ca30c"


def follow(path):
    f = None
    inode = None
    while True:
        try:
            st = path.stat()
        except FileNotFoundError:
            yield None
            time.sleep(0.3)
            continue
        if f is None or st.st_ino != inode:
            if f:
                f.close()
            f = open(path, "r", errors="replace")
            f.seek(0, os.SEEK_END)
            inode = st.st_ino
        pos = f.tell()
        if st.st_size < pos:
            f.seek(0)
        line = f.readline()
        if line and line.endswith("\n"):
            yield line
        else:
            if line:
                f.seek(pos)
            yield None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--chair", type=int, default=2)
    args = ap.parse_args()
    CH = args.chair

    gyro = {a: collections.deque() for a in "XYZ"}
    accel = {a: collections.deque() for a in "XYZ"}
    stds = {a: collections.deque() for a in "XYZ"}
    ratio_hist = collections.deque()
    yaw_hist = collections.deque()
    votes = collections.deque()
    raw_win = collections.deque()
    yaw_win = collections.deque()
    vote_hist = collections.deque()
    # Running sums so the 1s std-dev costs O(1) per sample instead of
    # re-reducing 100 samples three times for every one of 100 packets a
    # second. This is what made the scope fall behind the log and report
    # NO SIGNAL while data was arriving perfectly well.
    rs = {a: [0.0, 0.0] for a in "XYZ"}   # [sum, sumsq]
    yaw_sum = [0.0]
    state = {"occupied": False, "biasZ": None, "bias_buf": collections.deque(),
             "is_raw": True, "last": 0.0, "n": 0}

    reader = follow(LOG)

    fig, axes = plt.subplots(5, 1, figsize=(13, 11), sharex=True)
    fig.patch.set_facecolor(PAGE_BG)
    fig.canvas.manager.set_window_title(f"Chair {CH} scope")
    for ax in axes:
        ax.set_facecolor("#fcfcfb")
        ax.grid(color=GRID, lw=0.6)
    title = fig.suptitle("", fontsize=15, y=0.985)

    lines = {}
    for a in "XYZ":
        lines[f"g{a}"], = axes[0].plot([], [], color=AX[a], lw=1.0, label=f"gyro {a}")
        lines[f"s{a}"], = axes[1].plot([], [], color=AX[a], lw=1.2, label=f"std {a}")
    axes[0].set_ylabel("gyro  deg/s")
    axes[0].legend(loc="upper left", fontsize=8, ncol=3, framealpha=0.8)
    axes[1].set_ylabel("1s std  raw")
    axes[1].axhline(Z_FLOOR_RAW, color=OCC, ls="--", lw=1,
                    label=f"Z floor {Z_FLOOR_RAW}")
    axes[1].legend(loc="upper left", fontsize=8, ncol=4, framealpha=0.8)

    lines["ratio"], = axes[2].plot([], [], color=INK, lw=1.2)
    axes[2].axhline(RATIO_THRESHOLD, color=OCC, ls="--", lw=1)
    axes[2].set_ylabel(f"Z dominance\nsz/(sx+sy)")
    axes[2].set_ylim(0, 3)

    lines["yaw"], = axes[3].plot([], [], color="#7a3fbf", lw=1.4)
    axes[3].axhline(YAW_MIN_DEG, color=OCC, ls="--", lw=1,
                    label=f"swivel gate {YAW_MIN_DEG}deg")
    axes[3].set_ylabel(f"net yaw {YAW_WINDOW:.0f}s\ndeg")
    axes[3].legend(loc="upper left", fontsize=8, framealpha=0.8)

    lines["vote"], = axes[4].plot([], [], color=INK, lw=1.6)
    axes[4].axhline(ENTER_FRAC, color=OCC, ls="--", lw=1, label="enter")
    axes[4].axhline(EXIT_FRAC, color=FREE, ls="--", lw=1, label="exit")
    axes[4].set_ylabel("vote fraction")
    axes[4].set_ylim(-0.05, 1.05)
    axes[4].set_xlabel("seconds ago")
    axes[4].legend(loc="upper left", fontsize=8, ncol=2, framealpha=0.8)
    occ_band = axes[4].axhspan(0, 1, color=OCC, alpha=0.12)
    occ_band.set_visible(False)

    def trim(now):
        for d in list(gyro.values()) + list(accel.values()) + list(stds.values()) \
                + [ratio_hist, yaw_hist, vote_hist]:
            while d and d[0][0] < now - SPAN:
                d.popleft()

    def update(_frame):
        now = time.time()
        for _ in range(4000):
            line = next(reader)
            if line is None:
                break
            m = V2_RE.search(line)
            is_raw = False
            if m is None:
                m = V1_RE.search(line)
                is_raw = True
                if m is None:
                    continue
            if int(m.group(1)) != CH:
                continue
            t = time.time()
            state["is_raw"] = is_raw
            state["last"] = t
            state["n"] += 1
            g = {a: int(m.group(5 + i)) for i, a in enumerate("XYZ")}
            for i, a in enumerate("XYZ"):
                accel[a].append((t, int(m.group(2 + i)) / 16384.0))
                gyro[a].append((t, g[a] / GYRO_LSB))

            if is_raw:
                raw_win.append((t, g))
                for a in "XYZ":
                    rs[a][0] += g[a]
                    rs[a][1] += g[a] * g[a]
                while raw_win and raw_win[0][0] < t - 1.0:
                    _, og = raw_win.popleft()
                    for a in "XYZ":
                        rs[a][0] -= og[a]
                        rs[a][1] -= og[a] * og[a]
                yaw_win.append((t, g["Z"]))
                yaw_sum[0] += g["Z"]
                while yaw_win and yaw_win[0][0] < t - YAW_WINDOW:
                    yaw_sum[0] -= yaw_win.popleft()[1]
                if state["biasZ"] is None:
                    state["bias_buf"].append(g["Z"])
                    if len(state["bias_buf"]) >= 300:
                        state["biasZ"] = statistics.mean(state["bias_buf"])
                if len(raw_win) < 40:
                    continue
                n = len(raw_win)
                s = {}
                for a in "XYZ":
                    mean = rs[a][0] / n
                    var = max(rs[a][1] / n - mean * mean, 0.0)
                    s[a] = var ** 0.5
            else:
                s = {a: float(m.group(9 + i)) for i, a in enumerate("XYZ")}

            for a in "XYZ":
                stds[a].append((t, s[a]))
            rat = s["Z"] / (s["X"] + s["Y"] + 1)
            ratio_hist.append((t, rat))
            fire = s["Z"] > Z_FLOOR_RAW and rat > RATIO_THRESHOLD
            votes.append((t, fire))

            bz = state["biasZ"] if state["biasZ"] is not None else 0.0
            if is_raw and len(yaw_win) > 2:
                dt = (yaw_win[-1][0] - yaw_win[0][0]) / (len(yaw_win) - 1)
                yaw = abs((yaw_sum[0] - bz * len(yaw_win)) * dt / GYRO_LSB)
            else:
                yaw = float("nan")
            yaw_hist.append((t, yaw))

            while votes and votes[0][0] < t - VOTE_WINDOW:
                votes.popleft()
            frac = sum(f for _, f in votes) / len(votes) if votes else 0.0
            vote_hist.append((t, frac))
            gate = (yaw >= YAW_MIN_DEG) if is_raw else True
            if not state["occupied"] and frac >= ENTER_FRAC and gate:
                state["occupied"] = True
            elif state["occupied"] and frac <= EXIT_FRAC:
                state["occupied"] = False

        trim(now)

        MAXPTS = 700

        def xy(d):
            step = max(1, len(d) // MAXPTS)
            sl = list(d)[::step]
            return [t - now for t, _ in sl], [v for _, v in sl]

        for a in "XYZ":
            lines[f"g{a}"].set_data(*xy(gyro[a]))
            lines[f"s{a}"].set_data(*xy(stds[a]))
        lines["ratio"].set_data(*xy(ratio_hist))
        lines["yaw"].set_data(*xy(yaw_hist))
        vt, vv = xy(vote_hist)
        lines["vote"].set_data(vt, vv)

        # explicit, sensible scales rather than autoscale-into-noise
        for a, ax, dq in (("gyro", axes[0], gyro), ("std", axes[1], stds)):
            vals = [v for d in dq.values() for _, v in d]
            if vals:
                hi = max(abs(min(vals)), abs(max(vals)))
                if a == "gyro":
                    ax.set_ylim(-max(hi * 1.2, 5), max(hi * 1.2, 5))
                else:
                    ax.set_ylim(0, max(hi * 1.2, 40))
        yv = [v for _, v in yaw_hist if v == v]
        axes[3].set_ylim(0, max(max(yv) * 1.3, 3) if yv else 3)
        for ax in axes:
            ax.set_xlim(-SPAN, 0)

        occ_band.set_visible(state["occupied"])

        online = (time.time() - state["last"]) < 2.0
        fmt = "raw 100Hz" if state["is_raw"] else "8Hz summary"
        st_txt = "OCCUPIED" if state["occupied"] else "FREE"
        if not online:
            st_txt = "NO SIGNAL"
        title.set_text(
            f"Chair {CH}   ·   {st_txt}   ·   {fmt}   ·   "
            f"vote {vv[-1] if vv else 0:.2f}   ·   "
            f"yaw {yaw_hist[-1][1] if yaw_hist else 0:.2f} deg   ·   "
            f"{state['n']} packets")
        title.set_color(OCC if st_txt == "OCCUPIED" else
                        (INK if st_txt == "FREE" else "#898781"))

    ani = FuncAnimation(fig, update, interval=120, cache_frame_data=False)
    fig._keep = ani
    plt.tight_layout(rect=[0, 0, 1, 0.97])
    plt.show()


if __name__ == "__main__":
    main()
