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

## Parts

- ESP32 board with an integrated 18650 battery holder (7 units for chairs +
  1 for a hub + spares). Listings for this style of board are inconsistent
  about which USB-serial chip is on board — see "Two chip families" below.
- MPU-6050 / GY-521 breakout modules (gyroscope + accelerometer + onboard
  temperature sensor, I2C interface). Ship with header pins unsoldered.
- 18650 battery cells (Molicel P28A used here) — fit the holders but are
  physically hard to remove by hand (minor ergonomic annoyance, unrelated
  to charging).
- A USB 18650 charger, for cells removed from a board (charging in-place is
  also supported, see Battery section below).
- Standard micro-USB data cables (confirm they're not charge-only cables).

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

All exact tuned constants, and the measurements behind each one, are kept
as comments directly above the model code in `tools/live_plot.py` — that
file is the single source of truth for current numbers, since they may
keep changing as more data comes in. This document explains the reasoning
and history, not the specific values.

## Known, accepted limitations (characterized, not bugs to chase)

- A hard bump/knock on an *empty* chair still reads OCCUPIED until decay or
  a departure event clears it.
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
