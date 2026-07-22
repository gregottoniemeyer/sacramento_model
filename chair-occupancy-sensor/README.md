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

**New here?** See `START_HERE.md` for the 5-point quickstart. Setting up a
new permanent installation machine (auto-sync + auto-restarting dashboard)?
See `MAC_MINI_SETUP.md` for exact steps.

## Layout

- `firmware/` — Arduino sketches.
  - `sender_esp_now.ino` — flashed to the sensor board (has the MPU-6050
    wired to it, runs on battery). Reads the sensor at 100Hz, sends every
    sample over ESP-NOW.
  - `receiver_esp_now.ino` — flashed to the board that stays on USB. Prints
    incoming data to Serial in a fixed text format the tools below parse.
  - `i2c_scanner.ino` — diagnostic utility to confirm a sensor responds at
    I2C address `0x68`; not part of the deployed system. Distinguishes two
    different fault types that need different fixes: a clean "No I2C
    devices found" (or nothing at `0x68`) means a weak/cold joint or a
    power issue, while a flood of scattered "found" addresses across the
    whole range means a short/solder bridge or floating line — fix that by
    *removing* excess solder (wick), not adding more.
  - `mpu_read_test.ino` — diagnostic utility to read the MPU-6050 and print
    straight to Serial over USB, no ESP-NOW/receiver needed. Useful for
    bench-testing a freshly soldered sensor board on its own before
    trusting it with the full sender firmware.
  - `touch_presence_test.ino` — **experiment, nothing flashed to a chair
    yet.** Capacitive presence sensing (ESP32 touch pin + an electrode on
    the seat), at Greg's suggestion 2026-07-21. Unlike the MPU-6050 it
    measures presence rather than motion, so it targets both known
    weaknesses of the current model directly. Prints raw counts to Serial
    over USB. See its header comment for electrode options and the two
    expected gotchas (floating battery ground, thermal drift).
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
   Hit this for real bringing up boards 6/7 (2026-07-10): the dashboard sat
   showing stale data for the rest of the session with no error, because
   restarting the capture pipe after the receiver was unplugged/replugged
   truncated the log file out from under the dashboard's open handle.
   Symptom: the banner freezes and "last motion Ns ago" keeps climbing even
   while you're actively wiggling a board in your hand — that's the tell
   that it's a stale dashboard, not a dead sensor. Fix: `pkill -f
   tools/live_plot.py` then relaunch it.

## Bringing up a new/repaired chair board

One sender talks over the same channel as every other one, and the packet
format has no board-ID field (see `SensorPacket` in
`firmware/sender_esp_now.ino`) — so **only ever power one sender board at a
time** while testing, or their data interleaves on the dashboard with no way
to tell which board you're looking at.

1. Read the board's MAC **before flashing anything**, so a bad flash never
   loses track of which physical board is which:
   ```bash
   esptool --port /dev/cu.YOUR_PORT read-mac
   ```
   (find `esptool` at
   `~/Library/Arduino15/packages/esp32/tools/esptool_py/*/esptool` if it's
   not on your `PATH`). Physically label the board with its assigned number
   right away — cheap sharpie/tape, easy to lose track otherwise.
2. Flash `firmware/sender_esp_now.ino` (Board: "ESP32 Dev Module", double
   check the Port before uploading).
3. With the receiver plugged in and the live pipeline running (above), pick
   the board up and shake/rotate it. Pass = Accel/Gyro traces move and the
   banner flips to OCCUPIED. If nothing moves, see the diagnostic escalation
   below before assuming the sensor is dead.
4. Move to the next board only after confirming the current one — pull its
   power first.

**If a board looks dead on the dashboard**, escalate in this order rather
than guessing:
1. `firmware/mpu_read_test.ino` — reads the sensor and prints straight to
   Serial over the board's own USB cable, no receiver needed. If this shows
   real, varying numbers when you wiggle the board, the sensor and I2C
   wiring are fine — the fault is downstream (ESP-NOW/receiver/dashboard),
   not the board itself.
2. `firmware/i2c_scanner.ino` — if step 1 shows the sensor stuck at a
   constant value (especially `-1` on every field, which means "no I2C
   response at all"), this narrows down *why*: see the diagnostic note next
   to it in the Layout section above.
3. A board's onboard power LED (present on most GY-521 modules) not
   lighting up, when other boards' do, is a fast way to localize a fault to
   VCC/GND specifically before touching SDA/SCL at all — this is what
   actually broke board 7 during the 2026-07-10 bring-up, after an initial
   solder bridge on SDA/SCL was fixed first and turned out not to be the
   whole story. See `NOTES.md` for the full board-by-board history.

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
