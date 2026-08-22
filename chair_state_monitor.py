#!/usr/bin/env python3
"""Show the chair occupancy state published for diagnostics on UDP 5006.

Run this to answer "are the chairs actually driving the piece?". It listens on
the diagnostic port emitted by controller.py. Godot uses UDP 5005 separately;
its acknowledged regime application is reported by fleet/godot_controller.py.

Per chair it shows three things: whether it reads OCCUPIED, its temperature,
and the vote fraction, which is the number the model actually thresholds
(above 0.50 becomes occupied, below 0.15 becomes free).

Chairs are identified by number only. Which regime each chair represents is the
artwork's mapping and may change, so it is deliberately not asserted here.

  python3 chair_state_monitor.py            # dark graphical window
  python3 chair_state_monitor.py --plain    # terminal only, no dependencies
  python3 chair_state_monitor.py --raw      # one JSON line per packet
  python3 chair_state_monitor.py --once     # print one packet and exit

--plain needs nothing but Python, so it works on any screen Mac as-is.

If nothing appears the controller is not running:
  python3 controller.py                     # the real chairs
  python3 controller.py --source keyboard   # no chairs needed
"""

import argparse
import json
import socket
import sys
import threading
import time
from collections import deque

UDP_PORT = 5006
HISTORY_S = 60.0
ENTER_FRAC = 0.50      # mirrors controller.py, drawn as threshold lines
EXIT_FRAC = 0.15

BG, FG, MUTED = "#0d0f16", "#e8ecf4", "#6f7a91"
GREEN, RED, AMBER, CYAN = "#3ddc84", "#ff5c5c", "#ffb340", "#4de3d0"


def render_plain(st):
    chairs = st.get("chairs", [])
    stale = set(st.get("stale", []))
    temps = st.get("temp_c", [None] * 7)
    votes = st.get("vote", [0.0] * 7)
    lines = [f"  SACRAMENTO MODEL   source: {st.get('source', '?'):<9}"
             f"  {time.strftime('%H:%M:%S')}", "",
             f"   {'chair':<26} {'state':<10} {'temp':>7}  {'vote':>6}"]
    for i, c in enumerate(chairs):
        n = i + 1
        state = "OFFLINE" if n in stale else ("OCCUPIED" if c else "free")
        t = temps[i] if i < len(temps) else None
        v = votes[i] if i < len(votes) else 0.0
        ts = f"{t:.1f}C" if t is not None else "-"
        bar = "█" * int(round((v or 0) * 12))
        lines.append(f"   chair {n:<20} {state:<10} {ts:>7}  "
                     f"{v:>6.2f} {bar}")
    lines += ["", f"   occupied {st.get('n_occupied', sum(chairs))}/7"]
    return "\n".join(lines)


class Listener:
    def __init__(self, port):
        self.state = None
        self.last = None
        self.hist = [deque() for _ in range(7)]   # per chair: (t, vote)
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.sock.bind(("", port))

    def run(self):
        while True:
            try:
                data, _ = self.sock.recvfrom(4096)
                st = json.loads(data.decode())
            except (OSError, ValueError, UnicodeDecodeError):
                continue
            now = time.time()
            self.state, self.last = st, now
            votes = st.get("vote", [])
            cut = now - HISTORY_S
            for i in range(7):
                v = votes[i] if i < len(votes) else 0.0
                self.hist[i].append((now, v or 0.0))
                while self.hist[i] and self.hist[i][0][0] < cut:
                    self.hist[i].popleft()


def run_graphical(port):
    try:
        import matplotlib.pyplot as plt
        from matplotlib.animation import FuncAnimation
    except ImportError:
        print("matplotlib is not installed; falling back to --plain.\n")
        return run_plain(port, False, False)

    lis = Listener(port)
    threading.Thread(target=lis.run, daemon=True).start()

    plt.rcParams.update({"figure.facecolor": BG, "axes.facecolor": BG,
                         "text.color": FG, "font.size": 9})
    fig = plt.figure(figsize=(11.5, 8))
    fig.canvas.manager.set_window_title("Sacramento Model  |  chair state")
    gs = fig.add_gridspec(8, 1, height_ratios=[0.55] + [1] * 7, hspace=0.28,
                          left=0.015, right=0.985, top=0.97, bottom=0.035)

    head = fig.add_subplot(gs[0]); head.axis("off")
    hcount = head.text(0.0, 0.5, "", ha="left", va="center", fontsize=26,
                       fontweight="bold", color=MUTED)
    hsrc = head.text(1.0, 0.5, "", ha="right", va="center", fontsize=10,
                     color=MUTED)

    rows = []
    for i in range(7):
        ax = fig.add_subplot(gs[i + 1])
        ax.set_xlim(-HISTORY_S, 0)
        ax.set_ylim(-0.04, 1.04)
        ax.set_xticks([]); ax.set_yticks([])
        for s in ax.spines.values():
            s.set_color("#1c2233")
        # The two numbers the model compares the vote against.
        ax.axhline(ENTER_FRAC, color="#2b3348", lw=1.0, ls="--", zorder=1)
        ax.axhline(EXIT_FRAC, color="#232a3c", lw=1.0, ls=":", zorder=1)
        (line,) = ax.plot([], [], lw=1.8, color=CYAN, zorder=3)
        fillref = [None]
        name = ax.text(0.008, 0.80, f"chair {i+1}",
                       transform=ax.transAxes, fontsize=11,
                       fontweight="bold", va="center", color=FG, zorder=4)
        state = ax.text(0.008, 0.30, "", transform=ax.transAxes, fontsize=11,
                        fontweight="bold", va="center", color=MUTED, zorder=4)
        temp = ax.text(0.985, 0.80, "", transform=ax.transAxes, fontsize=10,
                       ha="right", va="center", color=MUTED, zorder=4)
        vote = ax.text(0.985, 0.30, "", transform=ax.transAxes, fontsize=13,
                       ha="right", va="center", fontweight="bold",
                       color=MUTED, zorder=4)
        rows.append(dict(ax=ax, line=line, fill=fillref, name=name,
                         state=state, temp=temp, vote=vote))

    def update(_):
        st, now = lis.state, time.time()
        live = st is not None and lis.last is not None and now - lis.last <= 3.0

        if not live:
            hcount.set_text("no signal"); hcount.set_color(AMBER)
            hsrc.set_text("start:  python3 controller.py")
            for r in rows:
                r["state"].set_text("")
                r["temp"].set_text("")
                r["vote"].set_text("")
                r["line"].set_data([], [])
            return []

        chairs = st.get("chairs", [])
        stale = set(st.get("stale", []))
        temps = st.get("temp_c", [None] * 7)
        votes = st.get("vote", [0.0] * 7)
        n_occ = st.get("n_occupied", 0)

        hcount.set_text(f"{n_occ} / 7  occupied")
        hcount.set_color(RED if n_occ else MUTED)
        src = st.get("source", "?")
        hsrc.set_text(f"source: {src}"
                      + ("   (test input, not the chairs)"
                         if src == "keyboard" else "")
                      + f"     {time.strftime('%H:%M:%S')}")
        hsrc.set_color(AMBER if src == "keyboard" else GREEN)

        for i, r in enumerate(rows):
            n = i + 1
            occ = i < len(chairs) and chairs[i]
            off = n in stale
            col = AMBER if off else (RED if occ else GREEN)

            r["state"].set_text("OFFLINE" if off else
                                ("OCCUPIED" if occ else "free"))
            r["state"].set_color(col)
            r["name"].set_color(MUTED if off else FG)

            t = temps[i] if i < len(temps) else None
            r["temp"].set_text("-" if t is None else f"{t:.1f} °C")

            v = (votes[i] if i < len(votes) else 0.0) or 0.0
            r["vote"].set_text(f"{v:.2f}")
            r["vote"].set_color(col)

            xs = [t0 - now for t0, _ in lis.hist[i]]
            ys = [vv for _, vv in lis.hist[i]]
            r["line"].set_data(xs, ys)
            r["line"].set_color(AMBER if off else CYAN)
            if r["fill"][0]:
                r["fill"][0].remove()
            r["fill"][0] = (r["ax"].fill_between(
                xs, 0, ys, color=(AMBER if off else CYAN), alpha=0.15, zorder=2)
                if xs else None)
            r["ax"].set_facecolor("#160f14" if occ and not off else BG)
        return []

    # Must be held: matplotlib keeps only a weak reference, and an unassigned
    # FuncAnimation is garbage-collected, freezing the window with no error.
    anim = FuncAnimation(fig, update, interval=250, blit=False,
                         cache_frame_data=False)
    plt.show()
    del anim


def run_plain(port, raw, once):
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind(("", port))
    sock.settimeout(5.0)
    if not raw:
        print(f"listening on UDP {port} ...", flush=True)
    last_draw = 0.0
    try:
        while True:
            try:
                data, _ = sock.recvfrom(4096)
            except socket.timeout:
                print("\nNo packets for 5s. Is controller.py running?",
                      file=sys.stderr)
                continue
            try:
                st = json.loads(data.decode())
            except (ValueError, UnicodeDecodeError):
                continue
            if raw:
                print(json.dumps(st), flush=True)
            elif once:
                print(render_plain(st))
                return
            else:
                now = time.time()
                if now - last_draw >= 0.25:
                    last_draw = now
                    print("\x1b[2J\x1b[H" + render_plain(st), flush=True)
    except KeyboardInterrupt:
        pass
    finally:
        sock.close()


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--port", type=int, default=UDP_PORT)
    ap.add_argument("--plain", action="store_true",
                    help="terminal only, no dependencies")
    ap.add_argument("--raw", action="store_true")
    ap.add_argument("--once", action="store_true")
    args = ap.parse_args()

    if args.plain or args.raw or args.once:
        run_plain(args.port, args.raw, args.once)
    else:
        run_graphical(args.port)


if __name__ == "__main__":
    main()
