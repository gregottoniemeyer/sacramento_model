#!/usr/bin/env python3
"""Sacramento Model controller: chair occupancy to UDP state for the screens.

Self-contained. Reads the receiver's serial capture, decides who is sitting
where, and broadcasts the state on UDP 5005 at 60Hz.

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

LOG = Path.home() / "motion_log.txt"
UDP_PORT = 5005
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
# Validated 2026-07-30 on held-out labelled data: 9/9 sit-downs, 9/9 stand-ups
# across all seven chairs, zero false positives. Reproduce with
# development/tools/score_model.py. Change a constant here and that result no
# longer describes what runs.

Z_FLOOR_RAW = 15
RATIO_THRESHOLD = 0.65
VOTE_WINDOW = 5.0
ENTER_FRAC = 0.50
EXIT_FRAC = 0.15
PEAK_JUMP_RAW = 1500
PROVISIONAL_S = 4.0
CONFIRM_FRAC = 0.40
IMPULSE_REFRACTORY_S = 4.0
YAW_WINDOW = 6.0
YAW_MIN_DEG = 1.0
BIAS_ALPHA = 1.0 / 512.0
BIAS_QUIET_STD = 20
GYRO_LSB_PER_DEG_S = 131.0
SAMPLE_HZ = 100.0


class ChairModel:
    """Occupancy for one chair. Feed it packets, read `.occupied`."""

    def __init__(self):
        self.votes = []
        self.yaw_parts = []
        self.occupied = False
        self.provisional_at = None
        self.bias_z = None
        self.vote_frac = 0.0
        self.yaw_deg = 0.0
        self.last_peak = 0
        self.prev_peak = None
        self.impulse_blocked_until = None
        self.reason = "no data"

    def update(self, t, std_x, std_y, std_z, peak_jump,
               yaw_sum_new=None, n_new=None, gyro_mean_z=None):
        self.last_peak = peak_jump

        fires = (std_z > Z_FLOOR_RAW
                 and std_z / (std_x + std_y + 1) > RATIO_THRESHOLD)
        self.votes.append((t, fires))
        cutoff = t - VOTE_WINDOW
        self.votes = [v for v in self.votes if v[0] >= cutoff]
        self.vote_frac = (sum(f for _, f in self.votes) / len(self.votes)
                          if self.votes else 0.0)

        # Learn the bias only while FREE and quiet, so a seated person's real
        # rotation is never absorbed into it.
        smax = max(std_x, std_y, std_z)
        if gyro_mean_z is not None and not self.occupied and smax < BIAS_QUIET_STD:
            if self.bias_z is None:
                self.bias_z = float(gyro_mean_z)
            else:
                self.bias_z += (gyro_mean_z - self.bias_z) * BIAS_ALPHA

        have_yaw = yaw_sum_new is not None and n_new is not None
        if have_yaw:
            self.yaw_parts.append((t, yaw_sum_new, n_new))
            ycut = t - YAW_WINDOW
            self.yaw_parts = [y for y in self.yaw_parts if y[0] >= ycut]
            bias = self.bias_z if self.bias_z is not None else 0.0
            tot_y = sum(y[1] for y in self.yaw_parts)
            tot_n = sum(y[2] for y in self.yaw_parts)
            self.yaw_deg = (abs((tot_y - bias * tot_n) / SAMPLE_HZ
                                / GYRO_LSB_PER_DEG_S) if tot_n else 0.0)
        else:
            self.yaw_deg = float("nan")

        self._decide(t, peak_jump, have_yaw)

    def _decide(self, t, peak_jump, have_yaw):
        # Rising edge, not level. peak_jump is a MAX over a trailing 1s window,
        # so sustained motion holds it high for many seconds; a level test
        # re-arms every time an unconfirmed entry reverts and the state
        # oscillates with a period of exactly PROVISIONAL_S.
        rising = (self.prev_peak is not None
                  and self.prev_peak < PEAK_JUMP_RAW <= peak_jump)
        blocked = (self.impulse_blocked_until is not None
                   and t < self.impulse_blocked_until)
        self.prev_peak = peak_jump

        if not self.occupied:
            if rising and not blocked:
                # A knock on an empty chair looks identical for an instant, so
                # this entry is provisional until the vote confirms it.
                self.occupied = True
                self.provisional_at = t
                self.reason = "impulse (provisional)"
                return
            gate = (self.yaw_deg >= YAW_MIN_DEG) if have_yaw else True
            if self.vote_frac >= ENTER_FRAC and gate:
                self.occupied = True
                self.provisional_at = None
                self.reason = "sustained motion"
            return

        if self.provisional_at is not None:
            if t - self.provisional_at >= PROVISIONAL_S:
                if self.vote_frac >= CONFIRM_FRAC:
                    self.provisional_at = None
                    self.reason = "confirmed"
                else:
                    self.occupied = False
                    self.provisional_at = None
                    self.impulse_blocked_until = t + IMPULSE_REFRACTORY_S
                    self.reason = "impulse not confirmed - was a knock"
            return

        if self.vote_frac <= EXIT_FRAC:
            self.occupied = False
            self.reason = "motion stopped"


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

    A chair that stops reporting is forced EMPTY, not held: a flat battery
    would otherwise latch its regime on forever, indistinguishable from someone
    sitting there for hours.
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
                m.update(now, pkt["stdX"], pkt["stdY"], pkt["stdZ"],
                         pkt["peak"] or 0, pkt["yawSum"], pkt["yawN"],
                         pkt["gyroZ"])
                self._mark(c - 1, m.occupied)
                # MPU-6050 datasheet conversion.
                self.temp_c[c - 1] = round(pkt["temp"] / 340.0 + 36.53, 1)
                self.vote[c - 1] = round(m.vote_frac, 3)

    def poll(self):
        now = time.time()
        with self.lock:
            self.stale = []
            for c in range(1, NUM_CHAIRS + 1):
                seen = self.last_seen[c]
                if seen is None or now - seen > STALE_S:
                    self.stale.append(c)
                    self._mark(c - 1, False)
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
