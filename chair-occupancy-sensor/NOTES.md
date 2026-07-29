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

## Installation day: mounting into the chairs (2026-07-24)

The chairs and mounting tape arrived, and all seven sensor boards were
screwed into them. Two failure patterns emerged that are specific to the
physical install, both new since the last bench-verified all-seven-good
state on 2026-07-22:

- **The screw-in step reliably destroys the GY-521 power LED.** Not
  transit damage, not a one-off — it happens on every chair. The dead LED
  itself is cosmetic (but see the 2026-07-27 follow-up below: the same
  mounting step is not cosmetic for the boards underneath), and it kills
  the fast VCC/GND glance-check documented at the bottom of this file. See that caveat and the matching one in
  `README.md`. A dark LED on a mounted board now means nothing; use a
  multimeter.
- **Two previously-repaired boards regressed on VCC/GND after mounting.**
  On a clean 6-of-7 capture (chair 2 aside): chairs 1, 3, 4, 5 streamed
  live varying data; **chairs 6 and 7 transmitted at full 100Hz but with
  every field pinned at exactly 0** (all-zeros, single distinct sample
  repeated). That is the board-4 brownout signature (analog sensor core
  starved while the digital I2C side and the radio keep running), *not*
  an I2C fault (which reads `-1`). Notably 6 and 7 are exactly the two
  boards with prior solder history — board 6 an SDA/SCL reflow, board 7 a
  VCC/GND resolder — and VCC/GND is what is failing again. Reading: the
  mounting mechanically stressed the weakest existing joints first.
  - **Do NOT run the usual USB escalation on these** (`i2c_scanner`,
    `mpu_read_test`). Both pass over USB and both will clear a board that
    is genuinely broken on battery — this is the exact board-4 confound.
    Go straight to a multimeter on battery: measure 3V3-to-GND at the
    module and compare against a known-good chair on battery, then reflow
    VCC and GND at both ends. Verify on battery AND after remounting,
    since mounting is the stressor.
- **Chair 2 is a different, more basic failure: no packets at all**, and
  critically no `Chair:?[mac]` line either (the receiver announces
  unknown boards by MAC, so "nothing" means not transmitting, not
  unrecognized). The ESP32 itself is not running — a power/battery
  problem, not the sensor. Check the cell first (this board was built
  2026-07-22 and may never have been charged); if a fresh cell does
  nothing, USB-power it to split battery-path fault from dead board.

Accelerometer magnitudes on the four good chairs, mounted (note the
chairs hang **inverted**, Z pointing down, so magnitudes sit just above
1g where the bench readings sat just below — 0.930g upright and 1.104g
inverted on the same chair straddle 1.000g symmetrically, the signature
of a fixed zero-g offset, not a fault): chair 1 ~1.04g, chair 3 ~1.10g,
chair 4 ~1.00g, chair 5 ~0.97g. All calibratable in software later.

### Follow-up (2026-07-27): the install is the cause, and nothing is visibly broken

Confirmed by Max: every one of these boards was **bench-verified working
before the install**, and there is **no external damage on any of them**. So
the mounting step is the cause, and whatever it does is internal. Two things
follow that change how this should be worked.

**1. Every failure so far is on the power path, not the sensor.** Lining up
the three recorded on the day:

| Chair | Symptom | Layer that failed |
|---|---|---|
| 6 | 100Hz packets, every field exactly 0 | VCC/GND to the module (analog core starved, radio and I2C alive) |
| 7 | 100Hz packets, every field exactly 0 | same |
| 2 | no packets at all, not even `Chair:?[mac]` | ESP32 itself not running (cell or power path) |

Not one of these is a dead MPU-6050. An I2C fault reads `-1`, a corrupt
sensor reads implausible values (the chair-2-original signature at 2.008 g),
and a dead die reads nothing at all over USB. All-zeros at full packet rate
is specifically **power delivered to the analog core**, and chair 2 is not
even a sensor question. Combined with "no external damage," the reading is
**mechanically stressed solder joints, cracked or gone high-resistance**, in
a package that looks perfect from the outside. Supporting evidence already in
this file: boards 6 and 7 were **exactly the two with prior solder rework**
(6 an SDA/SCL reflow, 7 a VCC/GND resolder), so the install found the weakest
joints first, which is what mechanical stress does and what a bad component
batch does not.

**Consequence for the repair path: reach for the soldering iron and the
multimeter, not the parts drawer.** This is the board-4 fault mode, and board
4 was fixed by reflowing VCC/GND. Replacement modules were ordered on
2026-07-27 (see Spares status) and are worth having, but **there is currently
no evidence that a single MPU-6050 is actually dead**, so swapping in a new
module may cure nothing while consuming a spare and adding a fresh set of
joints to the same stressor. Diagnose before swapping.

**2. The count does not reconcile yet, and it matters.** Friday recorded
three failures (chairs 2, 6, 7) against four good (1, 3, 4, 5). As of
2026-07-27 Max puts it at roughly **four** not working, which would mean one
of the four that passed on Friday has dropped out since. That is the more
worrying possibility, because it would mean the damage is **progressive**
(a cracked joint that still made contact on Friday and has since opened) and
not a one-time event at screw-in time. **Recount all seven on battery before
doing anything else**, and record the date of each result, because a board
that changes state between two capture sessions is itself the finding.

**Order of work when the chairs come down:**
1. Recount and log all seven, on battery, with dates.
2. Multimeter 3V3-to-GND at the module on battery, against a known-good
   chair. Do **not** start with `i2c_scanner` / `mpu_read_test` over USB:
   they pass on brownout boards and will clear a board that is genuinely
   broken (the board-4 confound, documented above).
3. Reflow VCC and GND at both ends. Only if that fails does the module get
   replaced.
4. Verify on battery, then verify **again after remounting**, since mounting
   is the stressor and a bench pass proves nothing about a mounted board.

**Open and worth solving before the next install:** what specifically the
screw-in does. It kills the power LED on every single chair and cracks joints
on the weak ones, which points at the module being torqued or flexed as the
screws come down (board bowing against a standoff, or the screws pulling the
PCB against an uneven surface). Until that is understood, remounting a
repaired board reproduces the same stress. Worth checking whether the modules
are being clamped flat against the chair versus standing off on the header
pins, and whether nylon washers or a compliant pad between module and chair
changes the outcome.

### RESOLVED (2026-07-29): stop putting screws through the PCB

Max's call, and the evidence supports it: **screwing the module down is what
breaks these sensors.** Treat this as settled and change the build, rather
than continuing to repair boards and remount them the same way.

The decisive tell is the one that looked cosmetic. **The power LED dies on
every single chair, without exception.** A surface-mount LED does not fail
from vibration, heat or handling; it fails when the board it is soldered to is
*flexed*. So every mounted module has been bent far enough to crack a
component. The VCC/GND failures on chairs 6 and 7 are the same event finding a
different weak point, which is exactly why the two boards with prior solder
rework were the two that went: rework joints are the most brittle thing on the
board, so they fail first under a stress every board is receiving.

Mechanism: the GY-521 is thin FR4 with mounting holes at the edge. A screw
pulls that edge against a surface that is not perfectly flat and the whole
board bows. The chairs are metal, so nothing yields except the PCB. Stiff
wires soldered to the header make it worse by transmitting torque into the
joints as the screw turns.

**The rule from here: the sensor board is never a structural member.**
- Mount the module on foam tape or a compliant pad inside the enclosure, and
  screw the *enclosure* to the chair. Nothing clamps the PCB itself.
- If a screw through the board is genuinely unavoidable, use nylon standoffs
  on both sides and tighten finger-tight only; the board must stay flat and
  unloaded.
- Strain-relieve the wires near the module so chair movement pulls on the
  anchor and not on the solder joints.

This also reframes the repair plan. Reflowing VCC/GND on chairs 6 and 7 is
still right, but reflowing and then remounting the same way just re-applies
the stress that broke them. Fix the mounting first, then repair.

Note that a fresh module out of the delivery box was also found dead on SCL
(2026-07-29, see `firmware/i2c_line_check.ino`), which is consistent: these
boards arrive fragile and do not tolerate being clamped.

## v2 firmware rollout (2026-07-29): all seven flashed

`sender_summary.ino` flashed to all seven chairs in one session. USB health
readings at flash time, from the firmware's own once-a-second `STATUS` line:

| Chair | accMag | gyro noise floor | Verdict |
|---|---|---|---|
| 1 | 0.819g | 15-16 | weak, see below |
| 2 | 0.991g | 10-12 | good |
| 3 | 0.937g | 11-14 | good |
| 4 | 1.015g | 8-11 | good |
| 5 | 1.058g | 10-12 | good |
| 6 | 1.005g | 10-14 | good, no brownout signature |
| 7 | 0.869g | 11-13 | good, no brownout signature |

Notably **chairs 6 and 7 showed no trace of the install-day all-zeros
brownout** and chair 2 came up fine, so the fleet is in better shape than the
2026-07-24 capture suggested. Chair 2's "not running at all" turned out to be
mundane: **the board was switched off.** These boards have a power switch and
it is easy to knock, which is now the first thing to check in `OPERATING.md`.

**A USB pass still proves nothing.** Chairs 4, 6 and 7 have all passed USB
before and failed on battery — that is the board-4 confound. The gate is all
seven **on battery, mounted**, which is the only configuration that has ever
caught these faults.

**Chair 1 is the one to watch.** Its noise floor sits at 15-16 where the others
are 10-14, and the departure detector only counts a window as quiet below 16,
so it measured **0% quiet windows** on the bench. It reads FREE only because
nothing has moved it, not because a departure was ever confirmed. This is the
same mechanism as the original "always occupied" complaint, and it survived a
sensor swap — so it may be the board, the mounting, or bench vibration rather
than the module. Re-check in an actual chair.

### Reflashing quirk: boards land in DOWNLOAD_BOOT

Two of the seven booted into the ROM bootloader instead of running the sketch
immediately after upload, printing `boot:0x3 (DOWNLOAD_BOOT...)` and
`waiting for download`. `arduino-cli` reported a successful upload and did not
recover them, so the board looks completely dead: no serial, no packets.

Cause is GPIO0 being sampled low at reset, from the USB-serial adapter's
RTS/DTR timing rather than any hardware fault. Fix is a second explicit reset:

```bash
esptool --port /dev/cu.YOUR_PORT --after hard-reset chip-id
```

Worth building into any reflash procedure rather than treating it as a fault.
**A chair that appears dead right after a firmware update is very likely this,
not a broken board** — check for `DOWNLOAD_BOOT` on the serial line first.

### Two device nodes, one board

`/dev/cu.SLAB_USBtoUART` and `/dev/cu.usbserial-0001` reported the same MAC
because both Apple's CP210x driver and Silicon Labs' own VCP driver are
installed, and each claims the device. `README.md` implies these are different
boards. They are not. Either node works.

## Toolchain setup

Arduino IDE, ESP32 board package installed, board profile **"ESP32 Dev
Module"** used for every board regardless of which specific variant it is.

**Core version:** the ESP32 core was updated to **3.3.11** (esptool_py
5.3.1) on 2026-07-22, mid-session, via the IDE's "Updates are available for
some of your boards" prompt. The original 7 boards were brought up on an
older core. Nothing broke — the ESP-NOW API is stable across 3.x and the
packet is plain data with no version coupling — but it's worth knowing that
the boards in the field are not all built from the same core, and that
`esptool`'s path contains its version number (so a hardcoded
`.../esptool_py/5.3.0/esptool` path silently breaks after an update; glob
the version instead).

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

### A second receiver board (2026-07-24)

Motivation: the receiver had to be physically unplugged and carried
between the development MacBook and the installation Mac Mini every time,
which is tedious and is itself a reliability risk (every reconnect also
kills the serial capture, see `README.md` step 2).

The obstacle is that every sender **unicasts** to one hardcoded MAC
(`78:1c:3c:35:83:6c`), so a second ESP32 flashed with the receiver sketch
receives *nothing*. It boots cleanly, reports no error and prints silence
— indistinguishable from a dead board, which is why this is worth writing
down rather than rediscovering.

**Chosen fix: the receiver sketch now claims that MAC in software**, via
`esp_wifi_set_mac(WIFI_IF_STA, RECEIVER_MAC)` called after `WiFi.mode()`
(the interface must exist) and before `esp_now_init()` (ESP-NOW binds to
whatever MAC the interface has at init). Any ESP32 flashed with it becomes
a drop-in receiver, and **no sender changes are needed at all**. On the
original Lonely Binary board the call is a no-op, so one firmware serves
every receiver board and there is no second sketch to keep in sync.

Second board built this way: `78:1c:3c:35:04:84` (another Lonely Binary).
Verified by flashing it and confirming it receives all six live chairs.

**Constraint this buys: never power two receivers at once.** They share a
MAC, so both answer to the same address and both ACK the senders. During
the verification both were plugged in simultaneously and it did still
work, but per-chair packet counts came out uneven over the window, so
that is evidence the clone works and *not* evidence that running two is
harmless. One at a time.

**The alternative, for when the restriction starts to hurt: broadcast.**
Point the senders at `FF:FF:FF:FF:FF:FF` and any number of receivers can
listen simultaneously. Rejected for now only because it needs all seven
senders reflashed over USB, and as of 2026-07-24 the mounting step is
itself damaging boards (below), so unmounting four healthy chairs to
reflash them is a real risk of ending up with fewer working chairs. It
migrates incrementally though: a broadcast sender is still picked up by
the existing receiver, so boards can be converted one at a time, ideally
as they come out for other reasons.

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

**Charging all 7 chair nodes at once (researched 2026-07-10):** since the
TP5400 charges the cell in place over the board's micro-USB port, the
simplest bulk-charging setup is a multi-port USB-A wall charger + one
micro-USB cable per board. Verified in stock: **SHANCAO 10-port USB
charging station**, $18.99 (4.4★, 5,700+ ratings, Amazon's Choice, ships
from Amazon):
`https://www.amazon.com/Charging-Technology-Guaranteed-Family-Sized-Multiple/dp/B084G2RH1C`
(the better-known Anker PowerPort 10 is discontinued/unavailable). 10
ports covers all 7 chair nodes with spares. Cable math: the original
order was ONE 5-pack of USB-A-to-micro cables (`amazon.com/dp/B0FNW9J7TS`)
— charging 7 boards simultaneously needs 7 cables, so **one more 5-pack
is needed** regardless of charger choice.

**Spares status (updated 2026-07-22).** The 2026-07-10 position — no spare
assembled sensors, one spare ESP32 — no longer holds: more sensors arrived
(Greg offered to order them in his 2026-07-12 email), and two further nodes
were assembled on 2026-07-22. Both verified by accelerometer magnitude
against gravity, which is a cheap end-to-end check of solder + I2C in one
number (1g = 16,384 raw at the MPU-6050's default ±2g scale; anything
within a percent or so of that means the sensor is genuinely working, not
limping on a marginal joint):

| Board | MAC | Role | Verified |
|---|---|---|---|
| 1 (rebuilt) | `8c:94:df:46:b5:54` | replaces the dead-USB original | 16,315 raw = 0.996 g |
| 8 → chair 2 | `88:f1:55:30:af:b4` | built as spare, **swapped into chair 2 the same day** | 16,220 raw = 0.990 g |

**Both spares were consumed on the day they were built** — one replacing
chair 1's dead-USB board, one replacing chair 2's corrupted-I2C board. So
as of 2026-07-22 there is again **no working spare node**, and the two
retired boards are each faulty in a different way (chair 1's original:
sound electronics, no USB port, cannot be reflashed or charged in place;
chair 2's original: intact USB, corrupted I2C reads). Either could
plausibly be recovered — the chair-2 board by reflowing SDA/SCL, which is
exactly what fixed board 6 — but neither should be deployed until it is.

Remaining loose sensor/board counts were not tallied — check physically
before assuming another spare node can be built, and treat "we have
spares" as unverified until then.

**Update 2026-07-27: still no spares, replacements ordered.** The 2026-07-24
install took out multiple mounted boards (see the Installation day follow-up
above), against zero spares on hand. Max ordered replacement GY-521 /
MPU-6050 modules on 2026-07-27, arriving 2026-07-28. Two caveats on that
order: the Amazon confirmation describes the contents only as "1 Hardware
item" and names neither the part nor the quantity, so **count the box before
planning around it**; and, more importantly, **new modules are probably not
the fix**. Every install failure recorded so far is a power-path fault
(cracked joint or dead cell), not a dead sensor, so the modules are spares
for a repair that may never need them. Do not let their arrival short-circuit
the diagnose-then-reflow order of work.

**Label boards with the last two MAC octets, not just a number.** On
2026-07-22 the good board and the faulty one were briefly confused because
their MACs differ by one character in the middle — `88:f1:55:32:5f:6c`
(faulty) against `88:f1:55:30:af:b4` (good) — while the reused number "8"
ended up on the *retired* board even though the records had board 8 sitting
in chair 2. Two rules that prevent the repeat:

- Every label carries the chair number **and** the MAC's last two octets,
  e.g. `CHAIR 2 · AF:B4`. Those octets are exactly what the receiver prints
  in a `Chair:?[...]` line, so a label can be checked against live output
  without opening anything. `5F:6C` vs `AF:B4` is unmistakable where
  `...55:32:...` vs `...55:30:...` is not.
- **Retired boards get no number at all** — a spare number invites reuse.
  Label them by fault: `DEAD · I2C · 5F:6C`, `DEAD · NO USB · 63:0C`.

For the same reason, the board built on 2026-07-22 as "board 8" is better
referred to as **chair 2 (`af:b4`)** now that it is deployed; "board 8" is
retired as a name.

**Health check worth reusing:** accelerometer magnitude at rest is a
single number that validates solder, I2C and packet decoding end to end.
At the MPU-6050's default ±2g scale, 16,384 raw = 1 g, and a stationary
sensor must read 1 g because gravity is the only acceleration acting on
it. Healthy boards land within ~1% (0.990–0.996 g measured here); the
faulty board read 2.008 g. It must be measured **stationary** — the same
faulty board read 2.18 g while simply being held, which is not diagnostic.

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
   from the same surface. Result on all three labeled sessions, gap-extended:
   **29/29 stand-ups reach FREE (median ~7–9s, max ~12s), one false FREE**
   (a pre-existing artifact on one `seated_active` carpet segment, present
   even in the original pre-v3 model — not something v3 introduced).
   Accelerometer-based departure sensing was investigated and rejected
   again: the seated-vs-empty accel DC shift is real but confounded by
   seat swivel orientation (the ~2° mount tilt rotates between the X and Y
   axes as the seat turns), and accZ shifts only ~5 raw counts under load.
6. **Drain sped up 0.75s → 0.2s (2026-07-09)**, on request to make
   stand-up detection "a bit faster." Backtesting first ruled out
   shortening the quiet-detection window/fraction — that reintroduces a
   false FREE on a real seated-still segment, the exact failure v3 above
   fixed. The drain is the only latency knob that's free: it only affects
   how fast confidence falls to 0 *after* a departure is already
   confirmed, so shortening it doesn't touch the confirmation logic at
   all. Re-backtested clean (still 29/29, still one pre-existing false
   free) with every session's latency improved by ~0.5-0.6s.
7. **Quiet window/fraction tightened 4.5s/0.70 → 4.0s/0.65 (2026-07-09)**,
   on explicit request to trade a *seldom* false positive for more
   responsiveness. A parameter sweep across all three labeled sessions
   (median/p90/max latency vs. false-FREE count) found this is the point
   where that trade is still genuinely rare: **one new false FREE** (a
   `seated_still` segment on hard floor, on top of the one pre-existing
   unrelated `seated_active`/carpet artifact) for a ~10% latency cut
   across every session. First swept against only two of the three
   sessions and looked cheaper than it is — the third session (the
   original `labeled_session_1783469350.csv`, no `surface` column)
   surfaced 2 more false-frees at the same settings, which is why the
   full 3-session sweep matters before picking a number. Every setting
   tighter than 4.0s/0.65 tested (3.5/0.65, 3.0/0.60, 4.5/0.65 alone)
   roughly doubled or tripled the false-free count for diminishing extra
   speed — if asked to go faster again, re-run the sweep across all three
   sessions rather than extrapolating from a partial one.

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

**Plan for the week of 2026-07-13** (communicated to Greg): install all 7
boards into their enclosures, build the hub that shows the status of all 7
chairs at once (items 6 below, plus a status view), and flash/tune the
battery-efficiency firmware (item 4 below).

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
   - **Transparent covers — researched 2026-07-10, at Greg's request** (he
     wants to see the LEDs working through the case). The enclosure
     currently ordered (`https://www.amazon.com/dp/B07RTYYHK7`, Zulkit,
     ABS, 100×68×50mm) offers plenty of *size* variants on its own listing
     but **no clear/transparent color option at all** — every size is
     opaque black.
     - **Best option found (verified in stock 2026-07-10): LMioEtool,
       same exact 100×68×50mm size, black ABS body + clear (PC) cover,
       IP65, fixed mounting ears** —
       `https://www.amazon.com/LMioEtool-Junction-Waterproof-Plastic-Universal/dp/B0FDQJ4N7R`.
       $6.99 single / $8.99 2-pack, ships from Amazon (fast delivery),
       4.9★ (34 ratings), Amazon's Choice. Black-body-with-clear-lid is
       exactly the requirement (LEDs visible through the cover) and
       matches the look of the current black Zulkit boxes.
     - Runners-up, verified but worse: uxcell fully-clear ABS
       (`https://www.amazon.com/uxcell-100x68x50mm-Electronic-Waterproof-Enclosure/dp/B07FKN8SZG`,
       $15.69, **only 2 in stock**); Fielect grey + clear cover
       (`https://www.amazon.com/Fielect-Transparent-Switchboard-Distribution-100x68x50mm/dp/B07ZR1W119`,
       $14.89, third-party seller, ~3-week delivery). Unverified backups:
       AliExpress `https://www.aliexpress.com/i/3256802662395680.html`,
       grobotronics (EU, IP67)
       `https://grobotronics.com/project-box-abs-100x68x50mm-flanged-and-clear-cover-ip67.html`.
     - Whichever is ordered, re-check laser-cutting/mounting properties
       for its actual material before cutting any holes — clear ABS is
       laser-cuttable but not ideal (scorches at the edge, needs fume
       ventilation); confirm it's genuinely ABS and not a different clear
       plastic (e.g. acrylic/PETG) before assuming that guidance applies.
   - **All 7 chair sender boards soldered and confirmed working
     (2026-07-10)**, each verified end-to-end (I2C sensor read + ESP-NOW
     relay + live dashboard, wiggle-tested individually with only one
     board powered at a time to avoid cross-talk on the shared receiver).
     Board-number → MAC table (needed any time a physical board is
     swapped, so `firmware/sender_esp_now.ino`'s hardcoded receiver MAC
     logic has a parallel per-chair reference):
     | # | MAC | notes |
     |---|-----|-------|
     | 1 | `8c:94:df:46:b5:54` | **rebuilt 2026-07-22.** The original chair-1 board (`88:f1:55:32:63:0c`) had its **micro-USB connector physically torn off**. It still runs and transmits fine on battery, but the port is both how the TP5400 charges the cell in place *and* the only way to reflash — so that board can never receive a firmware update again (it would be stranded at the 100Hz sender when the 2Hz firmware is flashed). Kept as a limited emergency spare, physically labelled "DEAD USB — DO NOT DEPLOY"; its cell must be charged externally in the Nitecore UMS4. Replaced by a freshly built node rather than transplanting the old sensor, since spare sensors were available and desoldering risked the one irreplaceable part. Verified on build: accel magnitude 16,315 raw = 0.996 g. |
     | 2 | `88:f1:55:30:af:b4` | **swapped 2026-07-22** — this is the board built that day as spare "board 8". The original chair-2 board (`88:f1:55:32:5f:6c`) developed **corrupted I2C reads** after handling: at rest it reported 2.008 g (physically impossible — a stationary sensor measures exactly 1 g), with two axes reading 1.23 g and 1.41 g *simultaneously*, noise 130× a healthy board (sd 6971 vs 54), and gyro-X frozen at a constant while Y/Z varied. Values were wrong, not absent, so the sensor was responding and the bytes were corrupt — the marginal-SDA/SCL signature, same class as board 6. Swapped rather than repaired to keep the build moving; the faulty board is worth a reflow of SDA/SCL later (that alone fixed board 6). Verified on build: 16,220 raw = 0.990 g. |
     | 3 | `88:f1:55:32:49:c4` | clean |
     | 4 | `8c:94:df:45:ca:28` | clean |
     | 5 | `88:f1:55:30:a6:58` | clean |
     | 6 | `8c:94:df:97:4f:34` | initially dead (SDA/SCL read `-1` — no I2C response despite ESP-NOW/power working); fixed by reflowing the SDA and SCL solder joints |
     | 7 | `8c:94:df:45:b3:d0` | initially a **solder bridge** (i2c_scanner found ~30 scattered phantom addresses instead of a clean single hit — classic shorted/floating-line signature, not a cold joint); after removing the bridge, VCC/GND turned out to be the real fault (board's power LED wasn't lighting, unlike every other board) — fixed by resoldering VCC/GND, confirmed by i2c_scanner then reliably finding only `0x68` |
     Receiver/hub board MAC (hardcoded in every sender, from
     `firmware/sender_esp_now.ino`): `78:1c:3c:35:83:6c` ("Lonely Binary"
     board, per the code comment).
   - **A board can pass every USB diagnostic and still be broken on
     battery (board 4, 2026-07-22).** Chair 4 transmitted a full 100
     samples/sec but every field — accel, gyro *and temperature* — read
     exactly `0`. Note that all-zeros is a different fault from board 6's
     all-`-1`: `-1` means no I2C response at all, while zeros mean the
     device answers and reports nothing. The escalation in `README.md`
     cleared it completely and misleadingly:
     - `i2c_scanner` → clean single hit at `0x68`, so no cold joint and no
       bridge;
     - `mpu_read_test` → perfectly good data, 0.957 g, normal temperature.

     Both of those run over **USB**, and the fault only appears on
     **battery**. Reflashing the sender also appeared to fix it — but only
     because the board was on USB at the time, which is a confound worth
     avoiding: change one variable at a time. A fresh cell ruled out simple
     depletion.

     Signature and reading of it: the ESP32 boots, drives the radio and
     transmits at full rate, while only the sensor fails, and it fails to
     zeros rather than to no-response. That is a brownout pattern — the
     ESP32 and the MPU's digital I2C interface tolerate a sagging 3V3 rail;
     the MPU's analog sensing core does not. On USB the board runs off a
     stiff 5V supply, whereas on battery the TP5400 boosts a 3.7V cell, so
     a marginal VCC/GND joint that conducts enough for I2C can still starve
     the sensor. Same fault class as board 7, but without the obvious tell
     of an unlit GY-521 power LED. Fix: reflow VCC and GND at both ends;
     confirm by measuring 3V3-to-GND at the sensor on battery vs USB.

     **Resolved the same day** by reflowing VCC and GND at both ends —
     board 4 then read 1.037 g on battery, in line with the other six.
     Confirms the brownout reading: nothing was wrong with the module, the
     bus or the firmware, only the joint's resistance under a supply that
     had less headroom to give.

     **Procedural lesson: verify a repair under battery power**, since that
     is how these boards actually run. A USB-only pass is not a pass.
   - **Diagnostic technique that generalizes beyond this round**: when a
     board's sensor data looked dead, `tools/firmware/i2c_scanner.ino`
     distinguishes two very different failure modes that need different
     fixes — a clean **"No I2C devices found"** (or a clean single hit at
     the wrong-looking result) means a weak/cold joint or a power issue,
     while a **flood of scattered "found" addresses** across the whole
     0x00-0x7F range means a short/bridge or floating line, and needs the
     excess solder *removed* (solder wick), not more solder added. A
     board's onboard power LED (present on most GY-521 modules) not
     lighting up, when other boards' LEDs do, is a fast way to localize a
     fault to VCC/GND specifically before touching SDA/SCL at all.

     **Caveat added 2026-07-24 — the LED check is dead for mounted
     chairs.** Screwing the sensor module into a chair reliably kills the
     GY-521 power LED (found while installing chairs 1-4, the day the
     chairs and mounting tape arrived). It happens on every chair, so a
     dark LED on a mounted board carries no information.

     **Do not read this as "mounting damage is only cosmetic"** (amended
     2026-07-27). The dead LED by itself is cosmetic, but the same
     mounting step also produced real functional failures on the boards
     with the weakest joints, so a mounted board is *unverified*, not
     healthy. The LED just stops being the instrument that tells you
     which. Use the multimeter check below.
     Confirmed on chair 1: LED dead, board streaming clean 100Hz data,
     0.968 g at rest, normal temperature. The voltages settle it in
     general — an LED needs roughly 2V forward to light and the MPU-6050
     needs at least 2.375V to operate, so any board producing valid data
     necessarily has a rail well above what the LED needed. Substitute
     check on a mounted board: measure 3V3-to-GND at the module on
     battery.

