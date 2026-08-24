#!/usr/bin/env python3
"""Sacramento Model controller: chair occupancy to UDP state for the screens.

Self-contained. Reads the receiver's serial capture, decides who is sitting
where, and broadcasts the diagnostic state on UDP 5006 at 60Hz. Godot control
remains on UDP 5005 and reads the same raw telemetry log directly.

  python3 controller.py                      # the real chairs
  python3 controller.py --source keyboard    # press 1-7, no chairs needed
  python3 chair_state_monitor.py             # see what is being sent

See chair-occupancy-sensor/README.md for the packet format, chair identification and fault modes.
"""

import argparse
import json
import os
import re
import select
import socket
import sys
import termios
import threading
import time
import tty
from pathlib import Path

INSTALL_DIR = Path(__file__).resolve().parent
LOG = Path(os.environ.get("WATER_COUNCIL_CHAIR_LOG", INSTALL_DIR / "motion_log.txt"))
UDP_PORT = 5006
HZ = 60
STALE_S = 3.0
NUM_CHAIRS = 7

REGIMES = [
    "Yurok Kinship",
    "Hydraulic Mining",
    "Reclamation & Levees",
    "Dams and Pumps",
    "Environmental Reg",
    "Climate Stress",
    "AI Extraction",
]

# ---------------------------------------------------------------- wire format

SUMMARY_FIELDS = ["accX", "accY", "accZ", "gyroX", "gyroY", "gyroZ", "temp",
                  "stdX", "stdY", "stdZ", "big", "n", "touch", "tbase",
                  "peak", "yawSum", "yawN", "up", "seq", "flags", "rssi"]
RAW_FIELDS = ["accX", "accY", "accZ", "gyroX", "gyroY", "gyroZ", "temp"]

_COMMON = (r"Chair:(\d+)\s+"
           r"Accel\s+X:(-?\d+)\s+Y:(-?\d+)\s+Z:(-?\d+)\s+"
           r"Gyro\s+X:(-?\d+)\s+Y:(-?\d+)\s+Z:(-?\d+)\s+"
           r"Temp:(-?\d+)")
_STATS = (r"\s+Std\s+X:(\d+)\s+Y:(\d+)\s+Z:(\d+)\s+"
          r"Big:(\d+)\s+N:(\d+)\s+"
          r"Touch:(\d+)\s+TBase:(\d+)")
_TAIL = r"\s+Up:(\d+)\s+Seq:(\d+)\s+Flags:(\d+)\s+Rssi:(-?\d+)"

V3_RE = re.compile(_COMMON + _STATS +
                   r"\s+Peak:(\d+)\s+YawS:(-?\d+)\s+YawN:(\d+)" + _TAIL)
V2_RE = re.compile(_COMMON + _STATS + _TAIL)
V1_RE = re.compile(_COMMON + r"\s+Rssi:(-?\d+)")
BAD_RE = re.compile(r"Chair:(\d+)\s+BAD PACKET len:(\d+)")


def parse(line):
    """One serial line to a dict, or None."""
    m = BAD_RE.search(line)
    if m:
        return dict(chair=int(m.group(1)), fmt="bad", length=int(m.group(2)))

    m = V3_RE.search(line)
    if m:
        vals = [int(g) for g in m.groups()[1:]]
        return dict(chair=int(m.group(1)), fmt="sum",
                    **dict(zip(SUMMARY_FIELDS, vals)))

    m = V2_RE.search(line)
    if m:
        # None, not 0: older firmware cannot report these, and 0 would read as
        # a measured "no rotation", which is a different and wrong claim.
        vals = [int(g) for g in m.groups()[1:]]
        body = vals[:14] + [None, None, None] + vals[14:]
        return dict(chair=int(m.group(1)), fmt="sum",
                    **dict(zip(SUMMARY_FIELDS, body)))

    m = V1_RE.search(line)
    if m:
        vals = [int(g) for g in m.groups()[1:]]
        return dict(chair=int(m.group(1)), fmt="raw",
                    **dict(zip(RAW_FIELDS, vals[:7])), rssi=vals[7])
    return None


def follow(path, stop=None):
    """Yield complete lines as they are appended, surviving truncation.

    Holds a partial line until its newline arrives: reading a file another
    process is appending to otherwise returns half lines, which then match the
    shorter raw pattern and silently record as data with no statistics.
    """
    f = open(path, "r", errors="replace")
    f.seek(0, os.SEEK_END)
    where = f.tell()
    buf = ""
    while stop is None or not stop.is_set():
        try:
            if os.stat(path).st_size < where:
                f.close()
                f = open(path, "r", errors="replace")
                buf = ""
        except FileNotFoundError:
            time.sleep(0.2)
            continue
        chunk = f.readline()
        where = f.tell()
        if not chunk:
            time.sleep(0.02)
            continue
        buf += chunk
        if not buf.endswith("\n"):
            continue
        line, buf = buf, ""
        yield line


# ------------------------------------------------------------ occupancy model
# A major motion event starts a simple trailing occupancy interval. Additional
# major motion renews the complete interval; standing up is deliberately not a
# separate classification problem.

PEAK_JUMP_RAW = 1500
OCCUPANCY_HOLD_S = 60.0


class ChairModel:
    """Hold occupancy until 60 seconds after the latest major motion."""

    def __init__(self):
        self.occupied = False
        self.occupied_until = 0.0
        self.vote_frac = 0.0
        self.last_peak = 0
        self.reason = "no data"

    def update(self, t, peak_jump):
        self.last_peak = max(int(peak_jump or 0), 0)
        major_motion = self.last_peak >= PEAK_JUMP_RAW
        self.vote_frac = 1.0 if major_motion else 0.0
        if major_motion:
            self.occupied = True
            self.occupied_until = float(t) + OCCUPANCY_HOLD_S
            self.reason = "major motion; 60s interval renewed"
            return
        self.advance(t)

    def advance(self, t):
        """Expire a held chair even when no fresh sensor packet arrives."""
        if self.occupied and float(t) >= self.occupied_until:
            self.occupied = False
            self.reason = "60s interval expired"
        elif self.occupied:
            remaining = max(self.occupied_until - float(t), 0.0)
            self.reason = f"held {remaining:.1f}s"


# ------------------------------------------------------------------- controller

def get_params(chairs, last_chair):
    occupied = sum(chairs)
    speed = round((occupied / NUM_CHAIRS) * 9)
    ring_alpha = round(occupied / NUM_CHAIRS, 2)

    if last_chair < 0:
        return {"speed": 0, "ring_alpha": 0.0, "regime": -1, "regime_name": "None"}

    return {
        "speed": speed,
        "ring_alpha": ring_alpha,
        "regime": last_chair,
        "regime_name": REGIMES[last_chair],
    }


class Source:
    def __init__(self):
        self.chairs = [0] * NUM_CHAIRS
        self.last_chair = -1
        self.stale = []
        # Diagnostics for chair_state_monitor.py. The artwork ignores these.
        self.temp_c = [None] * NUM_CHAIRS
        self.vote = [0.0] * NUM_CHAIRS

    def _mark(self, idx, now_occupied):
        was = self.chairs[idx]
        self.chairs[idx] = 1 if now_occupied else 0
        if now_occupied and not was:
            self.last_chair = idx
        elif was and not now_occupied and self.last_chair == idx:
            still = [i for i, c in enumerate(self.chairs) if c]
            self.last_chair = still[-1] if still else -1


class SensorSource(Source):
    """The real chairs.

    A stale chair remains marked offline but any prior major-motion interval is
    allowed to expire normally. It can therefore never latch forever.
    """

    def __init__(self):
        super().__init__()
        if not LOG.exists():
            raise SystemExit(
                f"{LOG} does not exist, so the serial capture is not running.\n"
                "See chair-occupancy-sensor/README.md, 'Run it', step 2.")
        self.log = LOG
        self.models = {c: ChairModel() for c in range(1, NUM_CHAIRS + 1)}
        self.last_seen = {c: None for c in range(1, NUM_CHAIRS + 1)}
        self.lock = threading.Lock()
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self):
        for line in follow(self.log):
            pkt = parse(line)
            if pkt is None or pkt.get("fmt") != "sum":
                continue
            c = pkt["chair"]
            if not (1 <= c <= NUM_CHAIRS):
                continue                      # slot 8 is the bench spare
            now = time.time()
            with self.lock:
                self.last_seen[c] = now
                m = self.models[c]
                m.update(now, pkt["peak"] or 0)
                self._mark(c - 1, m.occupied)
                # MPU-6050 datasheet conversion.
                self.temp_c[c - 1] = round(pkt["temp"] / 340.0 + 36.53, 1)
                self.vote[c - 1] = round(m.vote_frac, 3)

    def poll(self):
        now = time.time()
        with self.lock:
            self.stale = []
            for c in range(1, NUM_CHAIRS + 1):
                model = self.models[c]
                model.advance(now)
                self._mark(c - 1, model.occupied)
                seen = self.last_seen[c]
                if seen is None or now - seen > STALE_S:
                    self.stale.append(c)
                    self.temp_c[c - 1] = None
                    self.vote[c - 1] = 0.0


class KeyboardSource(Source):
    """Toggle chairs by hand, to exercise the screens without the chairs."""

    def __init__(self):
        super().__init__()
        self.old = None
        self.eof = False
        try:
            self.old = termios.tcgetattr(sys.stdin)
            tty.setcbreak(sys.stdin.fileno())
        except (termios.error, ValueError):
            print("Note: run in a real terminal for key input")

    def poll(self):
        if self.eof or not select.select([sys.stdin], [], [], 0)[0]:
            return
        key = sys.stdin.read(1)
        # Must precede the membership test: at EOF read() returns "", and
        # `"" in "1234567"` is True in Python.
        if not key:
            self.eof = True
            print("stdin is not a terminal: keyboard input disabled, "
                  "still broadcasting")
            return
        if key in "1234567":
            idx = int(key) - 1
            self._mark(idx, not self.chairs[idx])
            self.vote[idx] = 1.0 if self.chairs[idx] else 0.0
            status = "ON" if self.chairs[idx] else "OFF"
            print(f"Chair {key} ({REGIMES[idx]}): {status} | "
                  f"{sum(self.chairs)}/{NUM_CHAIRS} occupied")
        elif key.lower() == "q":
            raise KeyboardInterrupt

    def restore(self):
        if self.old:
            termios.tcsetattr(sys.stdin, termios.TCSADRAIN, self.old)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--source", choices=("sensors", "keyboard"),
                    default="sensors")
    ap.add_argument("--port", type=int, default=UDP_PORT)
    ap.add_argument("--quiet", action="store_true")
    ap.add_argument("--target", action="append", default=[],
                    help="extra IP to send to directly, repeatable")
    args = ap.parse_args()

    src = SensorSource() if args.source == "sensors" else KeyboardSource()

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    sock.setblocking(False)

    # Localhost first: it is the one that cannot fail.
    targets = ["127.0.0.1", "255.255.255.255"] + args.target
    failed = set()

    if args.source == "keyboard":
        print("Controller running (keyboard) - press 1-7 to toggle, Q to quit")
    else:
        print(f"Controller running (sensors) - reading {src.log}")
        print("Ctrl+C to quit")

    interval = 1.0 / HZ
    last_send = 0.0
    announced = None

    try:
        while True:
            now = time.time()
            src.poll()

            if now - last_send >= interval:
                params = get_params(src.chairs, src.last_chair)
                packet = json.dumps({
                    "chairs": list(src.chairs),
                    "n_occupied": sum(src.chairs),
                    "stale": list(src.stale),
                    "temp_c": list(src.temp_c),
                    "vote": list(src.vote),
                    "source": args.source,
                    "timestamp": now,
                    **params,
                }).encode()
                # Never die on a send failure: broadcasting to 255.255.255.255
                # raises OSError 49 on a network with no route for it, and an
                # unguarded send makes that a dead installation.
                for addr in targets:
                    try:
                        sock.sendto(packet, (addr, args.port))
                    except OSError as e:
                        if addr not in failed:
                            failed.add(addr)
                            print(f"note: cannot reach {addr} ({e.strerror}); "
                                  f"continuing without it. Use --target "
                                  f"<screen-ip> for a direct address.")
                last_send = now

                state = (tuple(src.chairs), tuple(src.stale))
                if state != announced and not args.quiet:
                    announced = state
                    occ = [str(i + 1) for i, c in enumerate(src.chairs) if c]
                    line = (f"{time.strftime('%H:%M:%S')}  "
                            f"{sum(src.chairs)}/{NUM_CHAIRS} occupied"
                            f"{'  chairs ' + ','.join(occ) if occ else ''}")
                    if src.stale:
                        line += (f"   [OFFLINE: "
                                 f"{','.join(str(c) for c in src.stale)}]")
                    print(line)
            else:
                time.sleep(0.001)

    except KeyboardInterrupt:
        pass
    finally:
        if isinstance(src, KeyboardSource):
            src.restore()
        sock.close()


if __name__ == "__main__":
    main()
