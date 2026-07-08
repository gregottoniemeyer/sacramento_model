# Chair Occupancy Sensor

ESP32 + MPU-6050 per-chair motion sensor, feeding occupancy state into the
Sacramento Model's chevron/ring animations. Each chair gets a battery-powered
ESP32 that senses motion and radios it (ESP-NOW) to one USB-tethered receiver
board, which a Python dashboard reads to infer occupied/empty per chair.

**Downstream integration point:** `../controller.py` already exists and is
built to consume this — it currently uses keyboard keys 1-7 as a placeholder
for real chair state (`chairs: [bool] * 7`), broadcast as UDP JSON to drive
the screens. The eventual hub firmware/script needs to produce that same
`chairs` array from real sensor data instead of keypresses.

## Layout

- `firmware/` — Arduino sketches.
  - `sender_esp_now.ino` — flashed to the sensor board (has the MPU-6050
    wired to it, runs on battery). Reads the sensor at 100Hz, sends every
    sample over ESP-NOW.
  - `receiver_esp_now.ino` — flashed to the board that stays on USB. Prints
    incoming data to Serial in a fixed text format the tools below parse.
  - `i2c_scanner.ino` — diagnostic utility to confirm a sensor responds at
    I2C address `0x68`; not part of the deployed system.
  - `proposed_2hz_radio_reduction/` — a battery-efficiency redesign (transmit
    a computed summary twice a second instead of every 100Hz sample).
    **Designed but not yet flashed to any board** — see the header comment
    in `sender_2hz_summary.ino` before resuming that work.
- `tools/` — Python (venv at `venv/`, see setup below).
  - `live_plot.py` — the live dashboard: real-time accel/gyro/temp charts
    plus an occupancy status banner. Source of truth for the currently
    deployed occupancy model.
  - `collect_data.py` / `collect_standup_data.py` — guided, labeled data
    collection sessions (on-screen instructions + sound cues), write to
    `data/*.csv` with ground-truth phase labels.
  - `simple_model.py`, `tune_simple.py`, `replay_simple.py`,
    `replay_detector.py` — offline model development/scoring against labeled
    CSVs in `data/`.
  - `analyze_experiment.py`, `compare_phases.py`, `tilt_check.py` — earlier,
    informal (pre-labeled-data) analysis scripts. Superseded by the
    labeled-session workflow above, kept for reference.
- `data/` — recorded sessions (raw and labeled CSVs). Some files are several
  MB; that's expected for 100Hz sensor recordings.

## Setup on a new machine

```bash
cd chair-occupancy-sensor
python3 -m venv venv
venv/bin/pip install -r requirements.txt
```

## Running the live pipeline

1. Plug in the **receiver** board (stays on USB). Find its port:
   `ls /dev/cu.*` — look for a `wchusbserial*` (CH340) or `usbserial*`/
   `SLAB_USBtoUART` (CP2102) entry.
2. Start the serial capture (keeps the port's baud setting alive across the
   whole session — do not split the `stty` and `cat` into separate opens,
   the port silently resets to 9600 baud if you do):
   ```bash
   exec 3<>/dev/cu.YOUR_PORT_HERE
   stty -f /dev/fd/3 115200 raw
   cat <&3 > ~/motion_log.txt &
   ```
   This dies if the board is ever unplugged — restart it after any
   reconnect (check with `wc -l ~/motion_log.txt` a few seconds apart to
   confirm it's still growing).
3. Launch the dashboard: `venv/bin/python tools/live_plot.py`
   If you replace `~/motion_log.txt` (e.g. re-running step 2 with `>`
   instead of `>>`) while the dashboard is running, restart the dashboard
   too — it holds an open handle to the old file and won't see new data.

## Current occupancy model

Simple threshold model (deliberately not std-dev/windowing — see project
memory/session history for why), tuned against real labeled recordings in
`data/`. Live constants are in `tools/live_plot.py`; replay/tune against new
data with `tools/tune_simple.py` and `tools/replay_simple.py`.

Known accepted limitations: a person sitting perfectly still for longer than
the hold timeout reads as empty until their next micro-movement; a hard bump
on an empty chair reads as occupied for the hold duration. These are
structural to a motion-only sensor, not bugs to chase.
