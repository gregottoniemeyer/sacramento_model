#!/usr/bin/env python3
"""
Sacramento Model — Central Controller
Runs on the central Mac Mini. Fakes chair input via keyboard for now;
swap in real ESP32 serial reading later when Max's hardware arrives.

Broadcasts UDP state packets to all screen Macs on the local network.

KEYBOARD CONTROLS
-----------------
  1-7     toggle chair occupancy (1=Yurok Kinship, 7=AI Extraction)
  Q       quit

RUN
---
  python3 controller.py

WHEN REAL ESP32 ARRIVES
-----------------------
  Replace the keyboard input section in read_chairs() with serial
  reading from the ESP32 collector. Everything else stays the same.
"""

import json
import socket
import time
import sys
import select

# --- Network config --------------------------------------------------------
BROADCAST_IP   = "255.255.255.255"  # sends to all devices on local network
UDP_PORT       = 5005               # all screen Macs listen on this port
BROADCAST_HZ   = 60                 # packets per second

# --- Regime definitions (chair index -> regime name) ----------------------
REGIMES = [
    "Yurok Kinship",        # chair 1
    "Hydraulic Mining",     # chair 2
    "Reclamation & Levees", # chair 3
    "Dams and Pumps",       # chair 4
    "Environmental Reg",    # chair 5
    "Climate Stress",       # chair 6
    "AI Extraction",        # chair 7
]

# --- Per-regime parameters ------------------------------------------------
# (speed 0-9, ring_alpha 0.0-1.0)
REGIME_PARAMS = [
    {"speed": 4, "ring_alpha": 0.2},  # Yurok: gentle flow, barely any pool
    {"speed": 9, "ring_alpha": 0.3},  # Hydraulic Mining: violent fast flow
    {"speed": 5, "ring_alpha": 0.5},  # Reclamation
    {"speed": 4, "ring_alpha": 0.8},  # Dams and Pumps: slow flow, big pool
    {"speed": 6, "ring_alpha": 0.6},  # Environmental Reg
    {"speed": 3, "ring_alpha": 0.9},  # Climate Stress: depleted flow
    {"speed": 9, "ring_alpha": 1.0},  # AI Extraction: maximal everything
]


def blend_params(chairs: list[int], last_chair: int) -> dict:
    """
    More chairs occupied = faster.
    0 chairs = stopped, 7 chairs = maximum speed.
    Last chair determines the regime name/color.
    """
    occupied = sum(chairs)
    speed = round((occupied / 7) * 9)
    ring_alpha = round((occupied / 7), 2)

    if last_chair < 0:
        return {"speed": 0, "ring_alpha": 0.0, "regime": -1, "regime_name": "None"}

    return {
        "speed": speed,
        "ring_alpha": ring_alpha,
        "regime": last_chair,
        "regime_name": REGIMES[last_chair],
    }


def main():
    chairs = [0] * 7  # 0 = empty, 1 = occupied
    last_chair = -1   # index of most recently occupied chair

    # Set up UDP broadcast socket
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    sock.setblocking(False)

    print("Sacramento Model Controller")
    print("Press 1-7 to toggle chairs, Q to quit")
    print("-" * 40)

    # Put terminal in non-blocking mode for key detection
    import tty
    import termios
    old_settings = termios.tcgetattr(sys.stdin)
    tty.setcbreak(sys.stdin.fileno())

    interval = 1.0 / BROADCAST_HZ
    last_send = 0.0

    try:
        while True:
            now = time.time()

            # Check for keypress (non-blocking)
            if select.select([sys.stdin], [], [], 0)[0]:
                key = sys.stdin.read(1)
                if key in "1234567":
                    idx = int(key) - 1
                    chairs[idx] = 1 - chairs[idx]  # toggle
                    status = "ON" if chairs[idx] else "OFF"
                    if chairs[idx]:
                        last_chair = idx  # this is now the dominant chair
                    elif last_chair == idx:
                        # last chair was just vacated -- find next most recent
                        occupied = [i for i, c in enumerate(chairs) if c]
                        last_chair = occupied[-1] if occupied else -1
                    print(f"Chair {key} ({REGIMES[idx]}): {status}")
                    print(f"Occupied: {[i+1 for i,c in enumerate(chairs) if c]}")
                    if last_chair >= 0:
                        print(f"Dominant: {REGIMES[last_chair]}")
                elif key.lower() == "q":
                    break

            # Broadcast state at BROADCAST_HZ
            if now - last_send >= interval:
                params = blend_params(chairs, last_chair)
                packet = json.dumps({
                    "chairs": chairs,
                    "timestamp": now,
                    **params,
                }).encode()
                # Send to broadcast AND localhost so same-machine testing works
                sock.sendto(packet, (BROADCAST_IP, UDP_PORT))
                sock.sendto(packet, ("127.0.0.1", UDP_PORT))
                last_send = now

    finally:
        termios.tcsetattr(sys.stdin, termios.TCSADRAIN, old_settings)
        sock.close()
        print("\nController stopped.")


if __name__ == "__main__":
    main()