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

A **confidence score (0-100)** rather than a flat timer, computed each frame
in `tools/live_plot.py` (`update_occupancy()` — that function is the source
of truth; all tunable constants live in one block near the top of the file).
Two independent signals feed it:

1. **Person-like motion** — either gyro-Z std-dev dominating X/Y (a swivel),
   or a run of large single-sample gyro jumps (a jolt/plop). Either one
   resets confidence to 100 and marks "last motion now."
2. **Departure detection** — a motion burst followed within a few seconds by
   empty-chair-grade silence (below the measured noise floor of a genuinely
   empty chair) is treated as a confirmed stand-up, and drains confidence to
   0 over ~2 seconds.

Absent a confirmed departure, confidence decays **slowly** (90s) as a
fallback only — presence is deliberately "sticky" so that sitting still
doesn't get misread as empty. This two-signal design replaced an earlier
single-timer version that failed in live testing both ways (statue-sitters
flipped to FREE, stand-ups felt sluggish).

Thresholds were tuned against `data/labeled_session_1783532146.csv` (a
guided two-surface session, hard floor + carpet) to get zero false triggers
across every walk-by/stand-near/stomp/dropped-object variant tested, on
both surfaces. Re-tune with `tools/tune_simple.py` / `tools/replay_simple.py`
against any new labeled recording.

**Known remaining weaknesses** (see the constants-block comments in
`live_plot.py` for the measurements behind these):
- A hard bump/knock on an empty chair still reads OCCUPIED until the decay
  or a departure event clears it.
- On carpet, sit-down detection lags ~2-3s behind hard floor (carpet
  absorbs the initial "plop").
