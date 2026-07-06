#!/usr/bin/env python3
# Sacramento Model — central controller
# Reads chair input (keyboard for now, ESP32 serial later)
# and broadcasts UDP state to all screen Macs

import json
import socket
import time
import sys
import select
import tty
import termios

UDP_PORT = 5005
HZ = 60  # broadcast rate

# 7 chairs, one per regime
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
    speed = round((occupied / 7) * 9)
    ring_alpha = round(occupied / 7, 2)

    if last_chair < 0:
        return {"speed": 0, "ring_alpha": 0.0, "regime": -1, "regime_name": "None"}

    return {
        "speed": speed,
        "ring_alpha": ring_alpha,
        "regime": last_chair,
        "regime_name": REGIMES[last_chair],
    }


def main():
    chairs = [0] * 7   # which chairs are occupied
    last_chair = -1    # most recently occupied chair = dominant regime

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    sock.setblocking(False)

    print("Controller running — press 1-7 to toggle chairs, Q to quit")

    # raw key input so we don't need Enter after each keypress
    try:
        old_settings = termios.tcgetattr(sys.stdin)
        tty.setcbreak(sys.stdin.fileno())
    except termios.error:
        old_settings = None
        print("Note: run in a real terminal for best key input")

    interval = 1.0 / HZ
    last_send = 0.0

    try:
        while True:
            now = time.time()

            if select.select([sys.stdin], [], [], 0)[0]:
                key = sys.stdin.read(1)
                if key in "1234567":
                    idx = int(key) - 1
                    chairs[idx] = 1 - chairs[idx]  # toggle on/off
                    if chairs[idx]:
                        last_chair = idx
                    elif last_chair == idx:
                        # if dominant chair just left, fall back to previous
                        occupied = [i for i, c in enumerate(chairs) if c]
                        last_chair = occupied[-1] if occupied else -1
                    status = "ON" if chairs[idx] else "OFF"
                    print(f"Chair {key} ({REGIMES[idx]}): {status} | {sum(chairs)}/7 occupied")
                elif key.lower() == "q":
                    break

            # send state packet to all screens
            if now - last_send >= interval:
                params = get_params(chairs, last_chair)
                packet = json.dumps({"chairs": chairs, "timestamp": now, **params}).encode()
                sock.sendto(packet, ("255.255.255.255", UDP_PORT))
                sock.sendto(packet, ("127.0.0.1", UDP_PORT))  # localhost for same-machine testing
                last_send = now

    finally:
        if old_settings:
            termios.tcsetattr(sys.stdin, termios.TCSADRAIN, old_settings)
        sock.close()


if __name__ == "__main__":
    main()