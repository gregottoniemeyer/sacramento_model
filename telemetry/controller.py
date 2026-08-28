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
# Power-saving senders emit a validation heartbeat every 10 seconds. Leave
# enough margin for radio and scheduling jitter before labeling one dormant.
STALE_S = 15.0
NUM_CHAIRS = 7
WATERSHED_CHAIR = 7
MAX_LIVE_BACKLOG_BYTES = 32 * 1024
GALLERY_CLOCK_STALE_S = 15.0

# Receiver slot 8 is currently installed as the physical replacement for
# logical chair 3. Keep this mapping explicit so a stray packet from the
# retired slot 3 cannot drive the same artwork chair.
SENSOR_TO_LOGICAL_CHAIR = {
    1: 1,
    2: 2,
    4: 4,
    5: 5,
    6: 6,
    7: 7,
    8: 3,
}

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
GALLERY_CLOCK_RE = re.compile(
    r"Gallery clock:\s+(OPEN|CLOSED)(?:\s+until open:(\d+)s)?"
)


def logical_chair(sensor_slot):
    """Return the artwork chair driven by a receiver slot, or None."""
    return SENSOR_TO_LOGICAL_CHAIR.get(int(sensor_slot))


def parse(line):
    """One serial line to a dict, or None."""
    m = GALLERY_CLOCK_RE.search(line)
    if m:
        return {
            "fmt": "gallery_clock",
            "state": m.group(1),
            "seconds_until_open": int(m.group(2) or 0),
        }

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
    """Yield only live complete lines, surviving replacement or truncation.

    Holds a partial line until its newline arrives: reading a file another
    process is appending to otherwise returns half lines, which then match the
    shorter raw pattern and silently record as data with no statistics.

    Existing contents are deliberately never replayed. Reopening at byte zero
    after a deployment replaced or truncated the capture log once turned old
    motion into new chair activations for many minutes.
    """
    def open_live_end():
        handle = open(path, "r", errors="replace")
        handle.seek(0, os.SEEK_END)
        stat = os.fstat(handle.fileno())
        return handle, handle.tell(), (stat.st_dev, stat.st_ino)

    f, where, identity = open_live_end()
    buf = ""
    try:
        while stop is None or not stop.is_set():
            try:
                stat = os.stat(path)
                if (stat.st_dev, stat.st_ino) != identity or stat.st_size < where:
                    f.close()
                    f, where, identity = open_live_end()
                    buf = ""
                elif stat.st_size - where > MAX_LIVE_BACKLOG_BYTES:
                    # A delayed consumer must recover by dropping old telemetry,
                    # never by turning historical motion into a current regime.
                    f.seek(0, os.SEEK_END)
                    where = f.tell()
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
    finally:
        f.close()


# ------------------------------------------------------------ occupancy model
# A major motion event starts a simple trailing occupancy interval. Additional
# major motion renews the complete interval; standing up is deliberately not a
# separate classification problem.

PEAK_JUMP_RAW = 1500
ROTATION_STD_RAW = 300
ROTATION_CONFIRM_PACKETS = 2
OCCUPANCY_HOLD_S = 30.0
WATERSHED_HOLD_S = 60.0


class ChairModel:
    """Hold occupancy for the configured interval after the latest major motion."""

    def __init__(self, hold_seconds=OCCUPANCY_HOLD_S):
        self.hold_seconds = float(hold_seconds)
        self.occupied = False
        self.occupied_until = 0.0
        self.vote_frac = 0.0
        self.last_peak = 0
        self.reason = "no data"

    def update(self, t, peak_jump, rotation_motion=False):
        self.last_peak = max(int(peak_jump or 0), 0)
        major_motion = (
            self.last_peak >= PEAK_JUMP_RAW
            or bool(rotation_motion)
        )
        self.vote_frac = 1.0 if major_motion else 0.0
        if major_motion:
            self.occupied = True
            self.occupied_until = float(t) + self.hold_seconds
            self.reason = (
                ("confirmed rotation" if rotation_motion else "major motion")
                + f"; {self.hold_seconds:g}s interval renewed"
            )
            return
        self.advance(t)

    def advance(self, t):
        """Expire a held chair even when no fresh sensor packet arrives."""
        if self.occupied and float(t) >= self.occupied_until:
            self.occupied = False
            self.reason = f"{self.hold_seconds:g}s interval expired"
        elif self.occupied:
            remaining = max(self.occupied_until - float(t), 0.0)
            self.reason = f"held {remaining:.1f}s"

    def cancel(self, reason):
        """End a held interval immediately because a newer input superseded it."""
        self.occupied = False
        self.occupied_until = 0.0
        self.vote_frac = 0.0
        self.reason = str(reason)


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
        self.gallery_clock = "UNKNOWN"
        self.gallery_clock_seconds_until_open = None
        self.gallery_clock_updated = None

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

    Chairs 1-6 are independent binary 30-second timers. Watershed uses a
    60-second timer so its AI call and visual decision can complete; it still
    clears all other timers when it activates, and a newer strong
    non-Watershed signal cancels it immediately.

    A stale chair remains marked offline but any prior strong-motion interval
    is allowed to expire normally. It can therefore never latch forever.
    """

    def __init__(self):
        super().__init__()
        if not LOG.exists():
            raise SystemExit(
                f"{LOG} does not exist, so the serial capture is not running.\n"
                "See chair-occupancy-sensor/README.md, 'Run it', step 2.")
        self.log = LOG
        self.models = {
            c: ChairModel(
                WATERSHED_HOLD_S if c == WATERSHED_CHAIR else OCCUPANCY_HOLD_S
            )
            for c in range(1, NUM_CHAIRS + 1)
        }
        self.last_seen = {c: None for c in range(1, NUM_CHAIRS + 1)}
        self.last_peak = {c: 0 for c in range(1, NUM_CHAIRS + 1)}
        self.rotation_count = {c: 0 for c in range(1, NUM_CHAIRS + 1)}
        self.watershed_armed = True
        self.lock = threading.Lock()
        threading.Thread(target=self._read, daemon=True).start()

    def _ingest_summary_packet(self, c, peak, temp, now, std_axis=0):
        """Apply one mapped sensor packet while holding ``self.lock``."""
        self.last_seen[c] = now
        peak = max(int(peak or 0), 0)
        std_axis = max(int(std_axis or 0), 0)
        model = self.models[c]
        self.last_peak[c] = peak
        if std_axis >= ROTATION_STD_RAW:
            self.rotation_count[c] += 1
        else:
            self.rotation_count[c] = 0
        rotation_motion = (
            self.rotation_count[c] >= ROTATION_CONFIRM_PACKETS
        )
        strong_motion = peak >= PEAK_JUMP_RAW or rotation_motion

        if c == WATERSHED_CHAIR:
            # A packet from the same rolling peak must not immediately restore
            # Watershed after a newer chair has canceled it. A quiet Watershed
            # packet rearms the next genuinely new strong event.
            if not self.watershed_armed:
                if not strong_motion:
                    self.watershed_armed = True
                model.update(now, 0)
            else:
                model.update(now, peak, rotation_motion)
                if strong_motion:
                    for other_c, other_model in self.models.items():
                        if other_c == WATERSHED_CHAIR:
                            continue
                        if other_model.occupied:
                            other_model.cancel("cleared by Watershed")
                        self._mark(other_c - 1, False)
                        self.vote[other_c - 1] = 0.0
        else:
            watershed = self.models[WATERSHED_CHAIR]
            if strong_motion and watershed.occupied:
                watershed.cancel("ended by newer strong chair input")
                self._mark(WATERSHED_CHAIR - 1, False)
                self.vote[WATERSHED_CHAIR - 1] = 0.0
                self.watershed_armed = False
            model.update(now, peak, rotation_motion)

        self._mark(c - 1, model.occupied)
        # MPU-6050 datasheet conversion.
        self.temp_c[c - 1] = round(temp / 340.0 + 36.53, 1)
        self.vote[c - 1] = round(model.vote_frac, 3)

    def _read(self):
        for line in follow(self.log):
            pkt = parse(line)
            if pkt is None:
                continue
            if pkt.get("fmt") == "gallery_clock":
                with self.lock:
                    self.gallery_clock = pkt["state"]
                    self.gallery_clock_seconds_until_open = pkt[
                        "seconds_until_open"
                    ]
                    self.gallery_clock_updated = time.time()
                continue
            if pkt.get("fmt") != "sum":
                continue
            c = logical_chair(pkt["chair"])
            if c is None:
                continue
            now = time.time()
            with self.lock:
                self._ingest_summary_packet(
                    c,
                    pkt["peak"],
                    pkt["temp"],
                    now,
                    max(pkt["stdX"], pkt["stdY"], pkt["stdZ"]),
                )

    def poll(self, now=None):
        now = time.time() if now is None else float(now)
        with self.lock:
            if (
                self.gallery_clock_updated is None
                or now - self.gallery_clock_updated > GALLERY_CLOCK_STALE_S
            ):
                self.gallery_clock = "UNKNOWN"
                self.gallery_clock_seconds_until_open = None
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
                    "gallery_clock": src.gallery_clock,
                    "gallery_clock_seconds_until_open": (
                        src.gallery_clock_seconds_until_open
                    ),
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
