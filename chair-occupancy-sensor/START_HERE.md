# Start Here — 5 things you need to know

New to this? Read this file only. (`README.md` = full setup, `NOTES.md` =
full history/reasoning, `MAC_MINI_SETUP.md` = exact steps to set up a new
permanent installation host from scratch — go there only once you need
more detail.)

### 1. What this is
A chair with an ESP32 + motion sensor detects if someone's sitting in it,
and sends that wirelessly to a receiver plugged into a computer. A Python
dashboard shows live sensor data and an OCCUPIED/FREE banner.

### 2. How to see it running
```bash
cd chair-occupancy-sensor
venv/bin/python tools/live_plot.py
```
(Needs the receiver board plugged in and the serial capture running first
— see "Running the live pipeline" in `README.md` if nothing shows up.)

### 3. Where the occupancy logic lives
`tools/live_plot.py`, function `update_occupancy()`. All the tunable
numbers are in one comment block near the top of that file — change those,
don't rewrite the logic.

### 4. Where the firmware lives
`firmware/sender_esp_now.ino` (goes on the chair's sensor board) and
`firmware/receiver_esp_now.ino` (goes on the board that stays plugged in).
Flash both with the Arduino IDE, board type "ESP32 Dev Module."

### 5. The one rule that saves the most pain
Always double-check which port you're uploading to in the Arduino IDE
(bottom-right corner) before clicking Upload. Flashing the wrong sketch to
the wrong board fails silently and produces very confusing symptoms. Also:
only ever power one sender board at a time when testing — see "Bringing up
a new/repaired chair board" in `README.md` for why and the full procedure.
