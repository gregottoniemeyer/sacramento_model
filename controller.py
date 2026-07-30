#!/usr/bin/env python3
"""Sacramento Model - central controller.

Turns chair occupancy into the state packet the screens render, and broadcasts
it over UDP at 60Hz.

TWO INPUT SOURCES
  --source sensors    the real chairs, via the ESP-NOW receiver (default)
  --source keyboard   press 1-7 to toggle chairs by hand

Keyboard mode is not a leftover: it is how the renderers get exercised when the
chairs are not present, packed, or charging. Both sources produce byte-identical
packets, so nothing downstream can tell them apart.

WHAT IT SENDS  (JSON, UDP broadcast + 127.0.0.1, port 5005, 60Hz)
  {
    "chairs":      [0,1,0,0,0,0,0],   # one flag per chair, index 0 = chair 1
    "n_occupied":  1,                 # how many are occupied right now
    "speed":       1,                 # 0-9, scales with how many are occupied
    "ring_alpha":  0.14,              # 0.0-1.0, same scaling
    "regime":      1,                 # index of the dominant regime, -1 if none
    "regime_name": "Hydraulic Mining",
    "stale":       [],                # chairs silent >3s: flat battery or off
    "source":      "sensors",
    "timestamp":   1785440000.123
  }

Every field that existed before the sensors were connected still means the same
thing, so existing consumers keep working. "n_occupied", "stale" and "source"
are additions.

READING IT
  python3 chair_state_monitor.py     # prints the packet, no dependencies

See INTEGRATION.md for how to run the whole chain, how chairs are identified,
and what to do when one stops reporting.
"""

import argparse
import json
import select
import socket
import sys
import termios
import threading
import time
import tty
from pathlib import Path

UDP_PORT = 5005
HZ = 60              # broadcast rate
STALE_S = 3.0        # ~8Hz means a healthy chair is never silent this long
NUM_CHAIRS = 7

# 7 chairs, one per regime. Chair N drives REGIMES[N-1].
REGIMES = [
    "Yurok Kinship",
    "Hydraulic Mining",
    "Reclamation & Levees",
    "Dams and Pumps",
    "Environmental Reg",
    "Climate Stress",
    "AI Extraction",
]

# speed and ring intensity per regime
REGIME_PARAMS = [
    {"speed": 4, "ring_alpha": 0.2},  # Yurok: slow, minimal pool
    {"speed": 9, "ring_alpha": 0.3},  # Hydraulic Mining: fast, disrupted
    {"speed": 5, "ring_alpha": 0.5},  # Reclamation
    {"speed": 4, "ring_alpha": 0.8},  # Dams: slow flow, big reservoir
    {"speed": 6, "ring_alpha": 0.6},  # Environmental Reg
    {"speed": 3, "ring_alpha": 0.9},  # Climate Stress: depleted
    {"speed": 9, "ring_alpha": 1.0},  # AI Extraction: maximal
]


def get_params(chairs, last_chair):
    # more chairs occupied = faster speed
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
    """Common shape: .chairs is 7 flags, .last_chair is the dominant regime."""

    def __init__(self):
        self.chairs = [0] * NUM_CHAIRS
        self.last_chair = -1
        self.stale = []

    def _mark(self, idx, now_occupied):
        """Set one chair, keeping last_chair on the most recent arrival."""
        was = self.chairs[idx]
        self.chairs[idx] = 1 if now_occupied else 0
        if now_occupied and not was:
            self.last_chair = idx
        elif was and not now_occupied and self.last_chair == idx:
            still = [i for i, c in enumerate(self.chairs) if c]
            self.last_chair = still[-1] if still else -1


class SensorSource(Source):
    """The real chairs.

    Reads the receiver's serial capture and runs the same occupancy model that
    tools/score_model.py scores, so the artwork reacts to exactly what was
    validated on 2026-07-30 rather than to a second implementation that could
    drift away from it.

    A chair that stops reporting is forced to EMPTY rather than held at its last
    value. Per OPERATING.md a silent chair has a flat battery, and leaving a
    regime latched on because a battery died is a worse failure than dropping
    it: it would be indistinguishable from a person sitting there forever.
    """

    def __init__(self):
        super().__init__()
        tools = Path(__file__).resolve().parent / "chair-occupancy-sensor" / "tools"
        sys.path.insert(0, str(tools))
        global rp, ChairModel
        import receiver_parse as rp                      # noqa: E402
        from occupancy_model import ChairModel           # noqa: E402

        self.log = Path.home() / "motion_log.txt"
        if not self.log.exists():
            raise SystemExit(
                f"{self.log} does not exist, so the serial capture is not "
                "running.\nSee INTEGRATION.md, 'Starting the chain', step 2.")
        self.models = {c: ChairModel() for c in range(1, NUM_CHAIRS + 1)}
        self.last_seen = {c: None for c in range(1, NUM_CHAIRS + 1)}
        self.lock = threading.Lock()
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self):
        for line in rp.follow(self.log):
            pkt = rp.parse(line)
            if pkt is None or pkt.get("fmt") != "sum":
                continue
            c = pkt["chair"]
            if not (1 <= c <= NUM_CHAIRS):
                continue          # slot 8 is the bench spare, not a chair
            now = time.time()
            with self.lock:
                self.last_seen[c] = now
                m = self.models[c]
                m.update(now, pkt["stdX"], pkt["stdY"], pkt["stdZ"],
                         pkt["peak"] or 0, pkt["yawSum"], pkt["yawN"],
                         pkt["gyroZ"])
                self._mark(c - 1, m.occupied)

    def poll(self):
        now = time.time()
        with self.lock:
            self.stale = []
            for c in range(1, NUM_CHAIRS + 1):
                seen = self.last_seen[c]
                if seen is None or now - seen > STALE_S:
                    self.stale.append(c)
                    self._mark(c - 1, False)


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
        # EOF (stdin is /dev/null, a closed pipe, or redirected from a file)
        # reads as "". select() reports it readable forever, so without this the
        # loop spins. It must also be caught BEFORE the membership test, because
        # `"" in "1234567"` is True in Python: the empty string is a substring
        # of every string, so an EOF would otherwise parse as a chair number.
        if not key:
            self.eof = True
            print("stdin is not a terminal: keyboard input disabled, "
                  "still broadcasting")
            return
        if key in "1234567":
            idx = int(key) - 1
            self._mark(idx, not self.chairs[idx])
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
    ap.add_argument("--quiet", action="store_true",
                    help="do not print state changes")
    ap.add_argument("--target", action="append", default=[],
                    help="extra IP to send to directly, repeatable. More "
                         "reliable than broadcast on networks that block it.")
    args = ap.parse_args()

    # Localhost first: it is the one that cannot fail, so a screen running on
    # this machine works even where broadcast does not.
    targets = ["127.0.0.1", "255.255.255.255"] + args.target
    failed = set()

    src = SensorSource() if args.source == "sensors" else KeyboardSource()

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    sock.setblocking(False)

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
                    "source": args.source,
                    "timestamp": now,
                    **params,
                }).encode()
                # Send best-effort to every target and NEVER die on a failure.
                # Broadcasting to 255.255.255.255 raises OSError 49 ("can't
                # assign requested address") on a network with no route for it,
                # which includes campus wifi. Unguarded, that killed the
                # controller outright: in the gallery that is a dead
                # installation rather than a degraded one. Localhost always
                # works, so a screen on this machine keeps running regardless.
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
