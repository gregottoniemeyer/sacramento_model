#!/usr/bin/env python3
"""Show what the controller is broadcasting. The test tool for the whole chain.

This is the thing to run when the question is "are the chairs actually driving
the piece?". It listens on the same UDP port the screens listen on and prints
the state, so it proves the chain end to end without needing a renderer, a
display, or any of the sensor tooling.

WHY IT IS SEPARATE FROM THE SENSOR DASHBOARDS
chair-occupancy-sensor/tools/ has dashboards for debugging the RIG: noise
floors, packet rates, radio strength. None of that is relevant here. This shows
only what the ARTWORK receives, which is the contract that matters when
integrating: seven flags, a speed, a ring alpha, and a dominant regime.

It has no dependencies. Plain standard-library Python, so it runs on any of the
screen Macs as-is.

Usage:
  python3 chair_state_monitor.py            # live, redraws in place
  python3 chair_state_monitor.py --raw      # one JSON line per packet
  python3 chair_state_monitor.py --once     # print one packet and exit

If nothing appears, the controller is not running. Start it with
  python3 controller.py --source sensors
or, to test with no chairs present,
  python3 controller.py --source keyboard
"""

import argparse
import json
import socket
import sys
import time

UDP_PORT = 5005
BAR = "█"


def render(st, width=34):
    chairs = st.get("chairs", [])
    stale = set(st.get("stale", []))
    regime = st.get("regime", -1)
    lines = []
    lines.append(f"  SACRAMENTO MODEL   source: {st.get('source', '?'):<9}"
                 f"  {time.strftime('%H:%M:%S')}")
    lines.append("")
    for i, c in enumerate(chairs):
        n = i + 1
        if n in stale:
            state, mark = "OFFLINE ", "  flat battery or switched off"
        elif c:
            state, mark = "OCCUPIED", ""
        else:
            state, mark = "free    ", ""
        dom = "  <- driving the river" if i == regime else ""
        name = CONTROLLER_REGIMES[i] if i < len(CONTROLLER_REGIMES) else ""
        lines.append(f"   chair {n}  {state}  {name:<22}{dom}{mark}")
    lines.append("")
    n_occ = st.get("n_occupied", sum(chairs))
    speed = st.get("speed", 0)
    lines.append(f"   occupied   {n_occ}/7   " + BAR * (n_occ * 3))
    lines.append(f"   speed      {speed}/9   " + BAR * (speed * 2))
    lines.append(f"   ring alpha {st.get('ring_alpha', 0.0):.2f}")
    lines.append(f"   regime     {st.get('regime_name', 'None')}")
    return "\n".join(lines)


CONTROLLER_REGIMES = [
    "Yurok Kinship", "Hydraulic Mining", "Reclamation & Levees",
    "Dams and Pumps", "Environmental Reg", "Climate Stress", "AI Extraction",
]


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--port", type=int, default=UDP_PORT)
    ap.add_argument("--raw", action="store_true", help="one JSON line per packet")
    ap.add_argument("--once", action="store_true", help="print one packet, exit")
    args = ap.parse_args()

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind(("", args.port))
    sock.settimeout(5.0)

    if not args.raw:
        print(f"listening on UDP {args.port} ...", flush=True)

    last_draw = 0.0
    try:
        while True:
            try:
                data, _ = sock.recvfrom(4096)
            except socket.timeout:
                print("\nNo packets for 5s. Is controller.py running?\n"
                      "  python3 controller.py --source sensors\n"
                      "  python3 controller.py --source keyboard   (no chairs "
                      "needed)", file=sys.stderr)
                continue
            try:
                st = json.loads(data.decode())
            except (ValueError, UnicodeDecodeError):
                continue

            if args.raw:
                print(json.dumps(st), flush=True)
            elif args.once:
                print(render(st))
                return
            else:
                # The controller sends at 60Hz; redrawing that fast just flickers.
                now = time.time()
                if now - last_draw >= 0.25:
                    last_draw = now
                    print("\x1b[2J\x1b[H" + render(st), flush=True)
    except KeyboardInterrupt:
        pass
    finally:
        sock.close()


if __name__ == "__main__":
    main()
