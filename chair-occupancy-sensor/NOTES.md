# Project Notes / History

Working log for the chair occupancy sensor subsystem — the reasoning behind
decisions, what was tried and rejected, and known open questions. See
`README.md` for setup/usage; this file is the "why," not the "how."

## Why the MPU-6050

Chairs are metal, which ruled out hiding an LD2410 24GHz radar under the
seat; a VL53L0X laser distance sensor was also considered and shelved. The
working theory: nobody sits down without turning a swivel chair at least
slightly, so motion events can stand in for direct presence sensing.
Verified early on that this assumption *has* to hold, because the
alternative — seated weight tilting the chair — is not a usable signal:
measured tilt from a seated adult is only ~0.2°, buried in sensor noise
(see the git history of `tools/tilt_check.py` for the experiment).

## Hardware path

- ESP32 (WEMOS-style board with an 18650 battery holder) + MPU-6050/GY-521
  breakout, connected over I2C (SDA→GPIO21, SCL→GPIO22, VCC→3V3, GND→GND).
- Wire color convention: blue=VCC, green=GND, yellow=SCL, red=SDA.
- Sensor board reads the MPU-6050 and transmits over **ESP-NOW** (no router,
  no WiFi network join, peer-to-peer by MAC address) to a second ESP32 that
  stays on USB and relays everything to Serial for a computer to log.
- Battery: the 18650 holder boards use a **TP5400** chip, which both charges
  the cell over USB *and* boosts its voltage to power the ESP32 — confirmed
  by reading the part number and by physical test (red LED while charging).
  Cells can stay in the holder and charge in place.
- Onboard battery-voltage telemetry is **not available** on this board (no
  ADC pin is wired to the battery) — would need a soldered 2-resistor
  divider per board to add it. Currently de-prioritized in favor of a
  simpler practical signal: a chair node that's gone silent has a dead
  battery.

## The occupancy model — how it evolved

1. **First attempt:** windowed std-dev of gyro noise + a flat 30s hold timer,
   based on informal, unlabeled "sit down / stand up" tests. Failed
   immediately in real use — read "occupied" almost permanently.
2. **First labeled dataset:** a guided, sound-cued collection script recorded
   ground-truth phases (empty / sit_down / seated_active / seated_still /
   stand_up / bump / nearby), single surface, one narrow walk-by variant.
   A tuned flat-threshold model (single motion-delta threshold + fixed hold
   window) scored reasonably on replay but still failed live: statue-sitters
   eventually flipped to "empty," and departures felt slow.
3. **Current model:** a **confidence score (0-100)** instead of a flat timer,
   with two independent signals:
   - *Person-like motion* (a swivel — gyroZ dominating X/Y — or a run of
     large single-sample gyro jumps, i.e. a plop/jolt) resets confidence to
     100.
   - *Departure detection*, scored separately from decay: a motion burst
     followed within a few seconds by empty-chair-grade silence is treated
     as a confirmed stand-up, and drains confidence to 0 quickly (~2s).
   - Absent a confirmed departure, confidence decays **slowly** (90s) as a
     pure fallback — presence is deliberately "sticky," because a real
     person sitting very still can go ~19+ seconds between micro-movements,
     and a short decay misreads that as empty.
4. Retuned against a second, much richer labeled session covering **two
   physical surfaces** (hard floor and carpet) and many walk-by variants
   (close/far/fast/behind/standing-near/stomping/dropping an object nearby)
   — carpet turned out to transmit enough floor vibration during walk-bys to
   false-trigger the original motion threshold, which is why that threshold
   is higher than it might look like it needs to be on a hard floor alone.

All the exact tuned constants and the measurements behind them live as
comments directly above the model code in `tools/live_plot.py` — that file
is the single source of truth; this document explains the reasoning, not
the numbers (which may keep changing as more data comes in).

## Known, accepted limitations (not bugs to chase)

- A hard bump/knock on an *empty* chair still reads OCCUPIED until decay or
  a departure event clears it.
- On carpet, sit-down detection lags ~2-3 seconds behind hard floor (the
  carpet absorbs the initial "plop").
- The model currently runs in Python on a Mac reading serial data — it has
  not yet been ported onto the ESP32 itself, which the real deployment
  needs (no laptop will sit next to each chair in the field).

## Integration target

`controller.py` (one directory up) is the actual consumer this subsystem
needs to feed. It currently uses keyboard keys 1-7 as a stand-in for chair
state and broadcasts UDP JSON to drive the screens. The end goal is a hub
that listens to all 7 chair nodes over ESP-NOW and produces that same
`chairs: [bool] * 7` array from real sensor data.

## Critical path

1. ~~Hardware bring-up, ESP-NOW relay, temperature, live dashboard, first
   model, confidence-decay model~~ — all done.
2. **Current step:** field-test the confidence-decay model against ordinary
   everyday chair use, not just replayed labeled recordings.
3. If the two known weaknesses above prove to matter in practice, address
   them specifically.
4. Resume the paused 2Hz radio-efficiency redesign
   (`firmware/proposed_2hz_radio_reduction/`) once the model is solid.
5. Port the occupancy logic onto the ESP32 itself (currently Mac-side only).
6. Build a real hub that listens to all 7 chairs at once and emits the
   `chairs` array `controller.py` expects (only 1-to-1 sender/receiver has
   been tested so far).
7. Physical build-out: enclosures, mounting, replicate across all 7 chairs
   and spares, track each board's MAC address.
