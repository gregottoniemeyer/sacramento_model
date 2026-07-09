# Project Notes / History

Working log for the chair occupancy sensor subsystem — the reasoning behind
decisions, what was tried and rejected, exact hardware in use, and known
open questions. Written to be self-contained: read this plus `README.md`
and no other context should be needed to continue the work. See
`README.md` for day-to-day setup/usage commands; this file is the "why"
and the hardware/debugging history behind it.

## Why the MPU-6050

Chairs are metal, which ruled out hiding an LD2410 24GHz radar under the
seat; a VL53L0X laser distance sensor was also considered and shelved. The
working theory: nobody sits down without turning a swivel chair at least
slightly, so motion events can stand in for direct presence sensing.
Verified early on that this assumption *has* to hold, because the
alternative — seated weight tilting the chair — is not a usable signal:
measured tilt from a seated adult is only ~0.2°, buried in sensor noise
(see `tools/tilt_check.py`).

## Original project brief (from Greg, 2026-06-14 email)

Verbatim framing of the whole project, from the email that started it,
before any parts were discussed — this is the "why" behind the whole repo,
not just this subsystem: "Our project would be to build a networked sensor
to measure if anyone is sitting on a chair. There will be 7 chairs, and
their occupancy status needs to be shared with a central ESP32 via ESPNow.
The central ESP32 is connected to a computer via USB, and the computer logs
occupancy and controls an audiovisual display. The display is another
story, a model of the Sacramento river." That display (chevron flow
animation, rings, `water_pipeline/`) and the central hub (`controller.py`,
one directory up) are what this sensor subsystem ultimately feeds — see
the top-level `README.md` for how the 7 chairs map to 7 historical
"regimes" of the river.

## Parts — decision trail (from the "Parts list" email thread with Greg)

Before the formal parts list (below), an earlier board idea was floated
and dropped: on 2026-06-16 Greg linked an AliExpress listing, "ESP32
CP2104 DHT11 WiFi Bluetooth Soil Temperature Humidity Sensor Module ...
18650 Battery Shield," noting "Would need to add ESPNow." This CP2104 +
onboard-DHT11 + 18650-shield combo is the direct ancestor of the board
that was actually ordered a week later (see Full parts list below) — it's
also the source of the "DHT11 already on the board, no extra cost" framing
in the parts list, and confirms the CP2104 chip as one of the "Two chip
families" documented under Toolchain setup below.

Greg Niemeyer ordered everything below (all parts, June 26, 2026). This
section captures the *why* behind each choice, pulled from the actual
email thread, since the sensor choice went through several rounds before
landing on the MPU-6050:

1. Max's initial split: **needed regardless** (ESP32 boards, cables,
   enclosures) vs. **sensor choice to be made** (DHT11 default vs. LD2410
   radar vs. VL53L0X laser distance).
2. Greg: **the chairs are metal** — rules out hiding the LD2410 radar
   underneath the seat (radar needs a non-metal seat to sense through). A
   strain gauge was raised as an alternative but rejected as "not easy to
   mount." Decision at this point: start with the DHT11 default temp
   sensor and see if it's fast/reliable enough.
3. Greg's follow-up idea: since the chair **seats rotate** on their
   swivel, and "it is near impossible to sit down without rotating the
   chair just a little bit," a gimbal/compass-style sensor could catch
   occupancy from that rotation — and a rotation data stream could be a
   nice bonus visualization.
4. Greg then ordered an accelerometer/gyroscope module for this
   (`https://www.amazon.com/dp/B00LP25V1A` — a GY-521 MPU-6050 breakout):
   "Should do the job with temp and motion." Max confirmed: "I like the
   idea of using a gyroscope." This is the sensor actually used — see
   `tools/tilt_check.py` and the section above for how the tilt-vs-rotation
   theory was verified.
5. Greg confirmed on 2026-06-26: **all parts ordered.**

### Full parts list as ordered

**Needed regardless:**
- ESP32 board w/ integrated 18650 holder — 7 for chairs, 1 for the hub, +1
  spare (maybe 2): `https://www.aliexpress.com/item/32974107777.htm`.
  Listings for this style of board are inconsistent about which
  USB-serial chip is on board — see "Two chip families" below.
- Micro-USB data cables (USB-A to micro, 5-pack), for loading code onto
  boards and keeping the hub connected to the computer:
  `https://www.amazon.com/dp/B0FNW9J7TS`.
- **Project enclosures — ABS plastic boxes, ~100×68×50 mm, sold in
  2-packs (~4 ordered):** `https://www.amazon.com/dp/B07RTYYHK7`. These
  are the "plastic covers" protecting each chair's board + battery from
  the person sitting on the chair. **Material is ABS** (per the listing
  description at time of ordering) — relevant before cutting a hole in
  one (ABS is laser-cuttable but not ideal: it can scorch/melt at the
  edge and releases fumes that need ventilation — verify against the
  actual physical part before cutting, since "ABS box" is the vendor's
  description, not a lab-verified resin code).

**Sensor (decision above):**
- MPU-6050 / GY-521 breakout (gyroscope + accelerometer + onboard temp
  sensor, I2C): `https://www.amazon.com/dp/B00LP25V1A`. Ships with header
  pins unsoldered.
- (Considered, not used) LD2410 24GHz presence radar —
  `https://www.amazon.com/RAKSTORE-HLK-LD2410-Presence-Sensing-Millimeter/dp/B0BNXC1F97`
  — ruled out by the metal chairs.
- (Considered, not used) VL53L0X laser distance sensor (3-pack) —
  `https://www.amazon.com/dp/B0B6ZT7NRW` — needs direct line of sight to
  the sitter, shelved in favor of the hidden gyroscope approach.

**Lab-dependent (ordered anyway):**
- Electronics starter kit (breadboard + jumper wires + resistors), for
  testing sensors without soldering:
  `https://www.amazon.com/REXQualis-Electronics-Breadboard-Resistor-Raspberry/dp/B078XV3RK2`.
- Soldering iron + multimeter kit (assumed the lab already has these).
- 18650 battery cells ×9 (Molicel P28A):
  `https://www.18650batterystore.com/products/molicel-p28a`. Fit the
  holders but are physically hard to remove by hand (minor ergonomic
  annoyance, unrelated to charging).
- 18650 charger (Nitecore UMS4) ×1:
  `https://www.amazon.com/NITECORE-UMS4-Intelligent-LumenTac-Organizer/dp/B07JPL476H`,
  for cells removed from a board (charging in-place is also supported,
  see Battery section below).

**Open at order time, resolved since:** whether the ESP32 board ships
with 18650 cells included (no — ordered separately, see above); whether
mounting hardware (Velcro, foam tape, zip ties) was needed (not resolved
in the thread — check before the physical build-out step in Critical
path below).

**Board received (confirmed 2026-07-06, "Board type" email):** the
physical boards that arrived are **WEMOS/Snvi ESP32 ESP-32S with an
18650 holder** — this is the exact model/vendor name for the boards
ordered above, useful for re-ordering or looking up pinout docs. Verified
with a basic blink sketch (LED on a pin, toggled with `Serial.println`
status messages) before any sensor wiring — standard bring-up sanity
check, confirms the board and USB-serial link both work before adding
complexity.

**Battery follow-up (2026-07-07, "Batteries" email):** Max asked Greg to
re-confirm the exact cell spec before a supplementary purchase; Greg's
answer: **18650 type, 3.7V rechargeable** (matches the Molicel P28A
ordered originally — see above). Max picked up an additional pack at a
physical store as backup/supplement to the original order, generic
18650 3.7V rechargeable cells rather than a specific branded cell.

## Toolchain setup

Arduino IDE, ESP32 board package installed, board profile **"ESP32 Dev
Module"** used for every board regardless of which specific variant it is.

**Two USB-serial chip families are in circulation across these boards**,
identifiable by port name:
- `/dev/cu.usbserial-XXXX` or `/dev/cu.SLAB_USBtoUART` → **CP2102** (Silicon
  Labs) chip. Driver: Homebrew cask `silicon-labs-vcp-driver` (the
  installer from Silabs' own site tends to hang or need extra manual
  System Settings approval — the Homebrew cask avoids that).
- `/dev/cu.wch...` → **CH340** (WCH) chip. Driver: install from the
  **WCHSoftGroup/ch34xser_macos** GitHub mirror, *not* the Homebrew cask
  `wch-ch34x-usb-serial-driver` (that one is a legacy Intel/kext build that
  requires Rosetta and tends to stall). After running the `.pkg`, you must
  *also* separately open `/Applications/CH34xVCPDriver.app` and click its
  own "Install" button — the `.pkg` alone does not finish registering the
  driver.

**macOS-specific gotchas that apply to any board, not just these:**
1. New driver/system extensions need manual approval under **System
   Settings → General → Login Items & Extensions → Driver Extensions**.
   Check with `systemextensionsctl list` in Terminal — must say
   `[activated enabled]`, not `[activated waiting for user]`.
2. macOS also shows a one-time **"Allow this USB accessory to connect?"**
   prompt per physical device. A board with no `/dev/cu.*` entry at all may
   simply be waiting on this prompt, not actually broken.
3. Port number suffixes can shift (e.g. `wchusbserial10` vs `wchusbserial110`)
   depending on which physical USB port/hub slot is used — same board,
   don't assume a different device just because the number changed.
4. A single CP2102 board can appear as two simultaneous port entries
   (`SLAB_USBtoUART` and `usbserial-XXXX`), claimed by two drivers for the
   same physical device.
5. **To read a board's MAC address without flashing anything**, use the
   ESP32 toolchain's bundled `esptool` directly:
   `esptool --port /dev/cu.XXXX read-mac`. Much faster than flashing a
   throwaway sketch that prints `WiFi.macAddress()`.

## MPU-6050 wiring

SDA→GPIO21, SCL→GPIO22, VCC→3V3, GND→GND. Wire color convention adopted for
consistency across all chair nodes: **blue=VCC, green=GND, yellow=SCL,
red=SDA**.

What was tried and didn't work, in case a future board hits the same
issues:
- **No-solder breadboard friction-fit**: consistently failed — SDA/SCL
  never made reliable contact even though VCC/GND did (their own power LED
  lit fine). Isolated the problem with a multimeter: 3.3V read fine at
  VCC/GND but was unstable/absent at SDA/SCL.
- **Soldering matched by physical pin position instead of by printed
  label**: on a different board layout, "the same 4 pins by position"
  landed on the ESP32's *internal flash* lines (CMD/SD2/SD3) instead of
  power/I2C, which broke firmware uploads with a "failed to communicate
  with the flash chip" error. **Lesson: always match by printed silkscreen
  label, never by physical position** — pin order is not consistent across
  different board designs.
- **Boot loop** (`invalid header: 0xffffffff`, RTC watchdog reset,
  repeating forever): caused by a stray wire touching **GPIO 12**, one of
  the ESP32's strapping pins (sets expected flash voltage at boot — if
  pulled high externally, flash reads fail and the board resets in a loop).
  **Isolation technique that works in general**: disconnect all external
  wires, confirm the bare board boots cleanly, then reconnect one wire at a
  time, checking for a clean boot after each addition — whichever addition
  reintroduces the loop is the culprit. Watch out for any other strapping
  pins too (0, 2, 4, 5, 15).
- **Conclusion**: soldering is not strictly required — careful manual/
  friction-fit wiring works reliably once pins are matched by label and
  kept away from strapping pins.

## ESP-NOW wireless relay

Architecture: the **sender** board (has the MPU-6050 wired to it, runs on
battery) reads the sensor and transmits over **ESP-NOW** — peer-to-peer by
MAC address, no router or WiFi network join required, low power, suitable
for battery nodes — to a **receiver** board that stays on USB and relays
everything to Serial in a fixed text format for a computer to log
(`firmware/sender_esp_now.ino` / `firmware/receiver_esp_now.ino`).

**Important debugging lesson:** when re-flashing either board, always
confirm which port is actually selected before uploading (Arduino IDE shows
the active port in the bottom-right corner). Flashing sender code to the
receiver's port (or vice versa) "succeeds" without any error, but leaves a
mismatch between the two boards' packet structs. Symptom: printed sensor
values look shifted by one field — e.g. what's labeled "Gyro X" is actually
the previous field's old value, and the very last field reads uninitialized
memory (shows up as a suspiciously constant number that never changes). If
output looks wrong in that specific way, suspect a stale/wrong-board flash
before suspecting a hardware fault.

MAC addresses are hardcoded in the sender sketch (it needs to know exactly
which receiver to talk to) — if a physical board is ever swapped, re-read
its MAC with `esptool ... read-mac` and update the constant in
`firmware/sender_esp_now.ino`.

## Battery / power

The 18650-holder boards use a **TP5400** chip — confirmed by reading the
part number printed on it. This chip both charges the cell over USB *and*
boosts its voltage to a steady output for the ESP32, meaning **cells can
stay in the holder and charge in place** — no need to remove them. A single
red LED near the chip lights during charging, matching this chip's
documented behavior (exact "fully charged" indicator behavior — LED off, or
a color change — has not yet been observed).

**Battery-level telemetry is not available on this board** — there is no
ADC pin wired to the battery, so firmware cannot read remaining charge
directly. Adding it would require soldering a 2-resistor voltage divider
per board (a well-established pattern for ESP32 + LiPo/Li-ion boards, since
raw cell voltage can exceed the 3.3V an ADC pin can safely read). This has
been deliberately deprioritized in favor of a simpler practical signal for
now: a chair node that stops reporting in has a dead battery.

## The occupancy model — how it evolved

**Reference: Greg's independently proposed model (2026-07-08 email,
subject "Occupied").** Sent the same day as the departure-detection v3
rework below, as Greg's own sketch of how the score should work — not
implemented verbatim, but worth keeping as a design reference since it
independently arrives at the same core shape (score-based, sticky decay,
explicit event resets) as the model actually built:

```
occupied_score = 0

if sit_down_event:
    occupied_score = 100

if rotation_or_body_motion:
    occupied_score = min(100, occupied_score + 10)

if get_up_event:
    occupied_score = 0

if very_still:
    occupied_score -= 0.01 # decay very slowly, not quickly

occupied = occupied_score > 50
```

The implemented model (below) differs mainly in having two independently
tuned event detectors (person-motion vs. departure) instead of one score
incremented/decremented by fixed steps, because plain "very_still" was
exactly the case that caused the real failures (statue-sitters vs. actual
empty-chair silence look alike on a single instantaneous reading — see
departure v3 below for the fraction-of-quiet fix this required).

1. **First attempt:** windowed std-dev of gyro noise + a flat 30-second hold
   timer, based on informal, unlabeled "sit down / stand up" tests. Failed
   immediately in real use — read "occupied" almost permanently.
2. **First labeled dataset:** a guided, sound-cued data collection script
   (on-screen instructions + a ping sound at every phase change, so the
   experimenter doesn't need to watch the screen while performing an
   action) recorded ground-truth phases: empty, sit_down, seated_active,
   seated_still, stand_up, bump, nearby. Single physical surface, one
   narrow walk-by variant. A tuned flat-threshold model (single
   motion-delta threshold + fixed hold window) scored reasonably well when
   replayed against this recording, but still failed live: statue-sitters
   eventually flipped to "empty" after the hold window elapsed, and
   departures felt slow to register.
3. **Current model:** a **confidence score (0–100)** instead of a flat
   timer, combining two independent signals:
   - *Person-like motion* — either a swivel (gyro-Z std-dev dominating
     gyro-X/Y std-dev) or a run of large single-sample gyro jumps (a
     plop/jolt). Either resets confidence to 100.
   - *Departure detection*, scored separately from decay: a motion burst
     followed within a few seconds by empty-chair-grade silence is treated
     as a confirmed stand-up, and drains confidence to 0 quickly (over
     ~2 seconds).
   - Absent a confirmed departure, confidence decays **slowly** (90 seconds)
     as a pure fallback. Presence is deliberately made "sticky" this way,
     because a real person sitting very still can go well over 15 seconds
     between micro-movements — a short decay misreads that stillness as an
     empty chair.
   This two-signal design directly replaced the single-timer version after
   it was shown to fail in both directions during live testing.
4. **Retuned** against a second, much richer labeled session spanning
   **two physical surfaces** (a hard floor and carpet) and many more
   walk-by variants (close/far/fast/from-behind/standing still
   nearby/stomping nearby/dropping an object nearby). Carpet turned out to
   transmit enough floor vibration during a normal walk-by to false-trigger
   the original, more sensitive motion threshold — this is specifically
   why the deployed threshold is higher than it would need to be on a hard
   floor alone. Tuning against this session achieved zero false triggers
   across every empty/walk-by/stand-near/stomp/dropped-object variant
   tested, on both surfaces.

5. **Departure detection reworked (v3)** after live use showed stand-ups
   still weren't read reliably. Event-level backtesting (new tool
   `tools/replay_departures.py`) found why the burst-then-quiet rule
   underperformed despite looking fine in the per-second replay:
   - An empty chair often *hovers* around the quiet bar (smax ~13–18) for
     several seconds after the person walks off. The old rule demanded an
     unbroken quiet run, which a single noise pop resets, and demanded
     quiet to *begin* within 5s of the last burst — late-settling wobble
     (chair pushed back, slow rise) missed the window entirely, leaving the
     chair OCCUPIED for the full 90s fallback decay.
   - Meanwhile the old 1s quiet requirement was *inside* the statue-sitter
     dip range (a real sitter's longest measured continuous sub-bar dip is
     2.7s), so a still sitter could falsely read as departed.
   The fix: quiet is now a **fraction of samples below the bar over a
   trailing window** (0.70 over 4.5s ≈ 3.2s of quiet, robust to pops, above
   the 2.7s human dip), the burst-pairing window widened 5s→12s (15s was
   tested and falsely freed one statue segment; 12s frees none), and a
   **burst-less long-quiet release** (80% quiet over 15s) was added as a
   safety net — it also clears the old bump-on-empty-chair false OCCUPIED,
   which previously stuck for the whole decay.
   An important measurement lesson from this round: the collection protocol
   left only ~3s of "empty" after each stand-up, so *any* detector with
   realistic latency scores terribly in the naive per-second replay — the
   new backtest pads those gaps to 30s with looped real empty-chair samples
   from the same surface. Result on both labeled sessions, gap-extended:
   **26/26 stand-ups reach FREE (median ~8–9s, max 12.5s), zero false
   FREEs across every seated / jerk-freeze / partial-rise segment.**
   Accelerometer-based departure sensing was investigated and rejected
   again: the seated-vs-empty accel DC shift is real but confounded by
   seat swivel orientation (the ~2° mount tilt rotates between the X and Y
   axes as the seat turns), and accZ shifts only ~5 raw counts under load.

All exact tuned constants, and the measurements behind each one, are kept
as comments directly above the model code in `tools/live_plot.py` — that
file is the single source of truth for current numbers, since they may
keep changing as more data comes in. This document explains the reasoning
and history, not the specific values.

## Known, accepted limitations (characterized, not bugs to chase)

- A hard bump/knock on an *empty* chair still reads OCCUPIED briefly, but
  since departure v3 the long-quiet release clears it in ~15-16s (it used
  to stick until the 90s decay ran out).
- Stand-up → FREE takes ~8-13s. Most of that is physics, not tuning slack:
  the chair keeps wobbling near the quiet bar for seconds after the person
  leaves, and the quiet window must stay longer than a statue-sitter's
  longest still dip (2.7s measured) or real sitters get falsely freed.
- On carpet, sit-down detection lags roughly 2–3 seconds behind hard floor
  (the carpet absorbs the initial "plop" that the model listens for).
- The occupancy model currently runs in Python on a laptop reading serial
  data relayed from the receiver board — it has not yet been ported onto
  the ESP32 itself, which the real per-chair deployment will need (no
  laptop will sit next to each chair in the field).
- Only one sender talking to one receiver has been tested. A real
  deployment needs one hub listening to seven independent chair nodes at
  once, which has not yet been attempted.

## Integration target

`controller.py` (one directory up from this subsystem) is the actual
downstream consumer this work needs to feed. It currently uses keyboard
keys 1–7 as a placeholder for real chair occupancy state, and broadcasts a
UDP JSON packet (chair states, a computed speed/intensity, and which
"regime" is currently dominant) to drive the installation's screens. The
end goal for this subsystem is a hub that listens to all 7 chair nodes over
ESP-NOW and produces that same array of 7 occupancy booleans from real
sensor data, instead of keypresses.

## Critical path

1. ~~Hardware bring-up, wiring, ESP-NOW relay, temperature sensing, live
   dashboard, first occupancy model, confidence-decay model~~ — all done.
2. **Current step:** field-test the confidence-decay model against ordinary,
   everyday chair use over time, not just replayed labeled recordings.
3. If the two known weaknesses above prove to matter in practice, address
   them specifically — both are already characterized, not mysteries.
4. Resume a paused battery-efficiency firmware redesign that reduces radio
   transmissions from 100/sec to 2/sec by computing statistics on-device
   (already written, in `firmware/proposed_2hz_radio_reduction/`, but not
   yet flashed to any board — deliberately paused to get the occupancy
   model right first). Model constants will likely need re-tuning for the
   different on-device window size this introduces.
5. Port the occupancy logic itself onto the ESP32 (currently laptop-side
   only).
6. Build a real hub that listens to all 7 chairs at once and emits the
   occupancy array `controller.py` expects.
7. Physical build-out: enclosures, mounting, battery charging workflow,
   replicate across all 7 chairs and spares, track each board's MAC
   address.
   - **TODO: check transparent covers** for the chair sensor board
     enclosures — confirm a transparent cover doesn't interfere with
     mounting, wiring access, or the wireless range/antenna, and that it
     looks right on the chairs. The enclosures as ordered (see Parts
     above) are opaque **ABS**, `https://www.amazon.com/dp/B07RTYYHK7` —
     if a transparent option/cover is swapped in, confirm the material
     matches (or re-check laser-cutting/mounting properties for whatever
     it turns out to be; ABS itself is laser-cuttable but not ideal —
     scorches at the edge and needs fume ventilation).

