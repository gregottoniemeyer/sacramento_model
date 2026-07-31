# Chair occupancy sensors

Seven chairs detect whether someone is sitting in them and drive the Sacramento
River installation. Everything needed to run and fix it is in this file; the
history and reasoning are in [`development/ARCHIVE.md`](development/ARCHIVE.md).

**Jump to:**
[operating](#operating) ·
[best practices](#best-practices) ·
[troubleshooting](#troubleshooting) ·
[development](#development) ·
[integration](#integration) ·
[installation](#installation)

```
7 chairs  ──radio──▶  receiver on USB  ──▶  controller.py  ──UDP──▶  screens
 ESP32 +              plugged into           decides who        the visuals
 motion sensor        the Mac                is sitting
      8 times a second                    60 times a second
```

---

# Operating

## Automatic startup

**Nothing needs starting by hand.** A job runs every couple of minutes that
pulls new code and restarts anything that has stopped, so a reboot, a knocked
cable or a crash all recover on their own.

If something looks wrong, **wait a minute before doing anything**. The only
thing this cannot fix is a chair that is switched off or flat.

## Status light

Every chair has a small blue light on its board, visible through the window in
the plastic case. It tells you whether that chair is working.

| The light | The chair is | What to do |
|---|---|---|
| **Blinks once, every 3 seconds** | Working normally | Nothing |
| **Blinking fast, without stopping** | Working, but something is wrong with it | See below |
| **Completely dark** | Not running at all | Charge it |

**A charge lasts about 20 hours**, so charging overnight
is sufficient. A chair that goes dark or disappears has a flat battery: that is the
expected way it fails, not a fault.

**If one chair is blinking fast**, it is still sending data and the exhibit
still works. The chair has just noticed a problem with itself. Note which chair
it is and carry on. It only becomes urgent if that chair also disappears from
the screen.

**If every chair is blinking fast at the same time**, the chairs are not the
problem. It means none of them can reach the receiver. Check that the receiver
is plugged into the Mac and that the Mac is awake.

## Best practices

- **Be careful screwing a sensor board down.** Several have broken this way. Let
  the case take the screws where possible.
- **Be gentle with the USB ports.** Two have broken. Push straight in, slowly.
- **Leave the tape inside the case.** It stops the board moving, which keeps
  detection accurate.
- **Mount the sensor toward the outer edge of the seat, not the middle.** It
  picks up more movement there when the chair turns.
- **Do not power a second receiver** while one is running.

---

# Troubleshooting

Work down the list and stop at the first thing that explains it.

## A single chair is offline

1. **Is its light doing anything?** Nothing at all means charge it.
2. **Is the power switch on?** It is on the underside. A chair read as dead on
   30 July purely because of this.
3. **Was it just reflashed?** Boards sometimes land in the bootloader after an
   upload and look completely dead. Fix: `esptool --after hard-reset chip-id`.

## All chairs are offline

This is not a problem with the chairs. Either the receiver is unplugged or the
serial capture has stopped.

**Wait two minutes first**: the timer job restarts the capture on its own. If it
is still wrong after that, the receiver is probably unplugged. Plug it back in
and wait another minute.

To check by hand whether data is arriving at all:

```bash
wc -l ~/motion_log.txt; sleep 5; wc -l ~/motion_log.txt
```

It should climb by about **280 every 5 seconds** (7 chairs x 8 per second).
**If it does not climb, no display is showing current data**, however healthy
they look. This is the most important single check in the system, because a
stopped capture is invisible everywhere else: no error appears, every display
simply freezes on its last values.

To force the capture to restart rather than waiting:

```bash
chair-occupancy-sensor/tools/start_capture.sh
```

It is safe to run any time. It does nothing when the capture is healthy, and
reports what it found when it is not.

## A chair reports occupied when empty

The chair is being moved by something. In order:

1. **Is anything on the seat?** A bag or a coat shifting counts as movement.
2. **Is anything shaking it?** A door swinging nearby, a fan, or people walking
   heavily past on a wooden floor will all do it.
3. **Nudge the chair a few centimetres** and leave it. If it was picking up
   vibration through the floor, that usually settles it.

A few seconds of it while somebody brushes past is normal and clears on its own.
It only matters if it stays that way with the room empty.

## The screens are not responding

Run `python3 chair_state_monitor.py`. If it shows correct chair states then the
sensing side is fine and the problem is downstream in the renderers.

---

# Development

Everything here is for a laptop, or for changing how the system behaves. None of
it is needed to keep the exhibit running.

## Manual startup

On a machine without the timer job, the four pieces are started manually.

**1. Switch the chairs on.** Power switch on the underside of each board.

**2. Start the serial capture:**

```bash
chair-occupancy-sensor/tools/start_capture.sh
```

It finds the receiver's port itself, so the port name does not need to be known.
If it reports `NO RECEIVER FOUND` it lists the ports it did see.

<details>
<summary>Doing it without the script</summary>

```bash
ls /dev/cu.*                       # find the wchusbserial* one
exec 3<>/dev/cu.wchusbserial10
stty -f /dev/fd/3 921600 raw
cat <&3 > ~/motion_log.txt &
disown
```

`stty` and `cat` must share one open of the port. Opening it twice resets the
board and silently drops the baud rate to 9600.
</details>

**3. Start the controller**, from the repo root:

```bash
python3 controller.py
```

**4. Start the renderers** on the screen Macs.

## Monitoring

```bash
python3 chair_state_monitor.py
```

Per chair: its state, its temperature, and the **vote fraction**, which is the
number the model compares against a threshold. The two faint lines on each
trace are those thresholds, so you can see why a chair changed state rather
than only that it did:

- rises above **0.50** to become occupied
- falls below **0.15** to become free

Add `--plain` for a terminal version that requires no packages, for a machine
without matplotlib.

## Testing without hardware

```bash
python3 controller.py --source keyboard
```

Press 1-7 to simulate chairs. The packets are identical to real ones, so
nothing downstream behaves differently. The monitor marks the source amber so
test input is never mistaken for real chairs.

## Chair identification

**Chair identity lives in the receiver, not in the chair firmware.** Every ESP32
has a permanent factory MAC address, and `firmware/receiver_esp_now.ino` maps
each one to a chair number.

This means every chair runs **identical firmware**, a board cannot lose its
identity by being reflashed, and renumbering chairs is a two-line edit rather
than unmounting boards. That last point matters because unmounting is what
physically broke boards in July.

Boards are labelled with the **last two octets** of their MAC, for example
`B5:54` for chair 1. Two boards in this fleet differ only in the middle of their
address, so labelling by the end is deliberate.

An unrecognised board reports its own address: the receiver prints
`Chair:?[88F155325F6C]`, which can be pasted directly into the table.

To read a board's MAC:

```bash
tools/flash_chair.sh /dev/cu.YOUR_PORT
```

**Slot 8 is not a chair.** It is the spare, for testing a sensor without
unmounting an installed chair. The controller ignores it.

## Reflashing firmware

```bash
tools/flash_chair.sh /dev/cu.YOUR_PORT              # a chair
tools/flash_chair.sh /dev/cu.YOUR_PORT receiver     # the receiver
```

It reads the MAC before writing anything and refuses to flash chair code onto
the receiver, which otherwise succeeds silently and breaks the whole fleet.

**Flash the receiver before the chairs** if both need updating. A new chair
talking to an old receiver reads as `BAD PACKET` and looks exactly like a dead
board.

## Modifying the model

The occupancy model is inside `controller.py`, near the constants marked
`occupancy model`. Changing a constant there invalidates the recorded validation result, so
re-score it:

```bash
venv/bin/python development/tools/score_model.py data/dataset_20260730_122544.csv
```

The development tools import the model **from** `controller.py`, so there is
only ever one copy and the scorer always scores what actually runs.

---

# Integration

`controller.py` broadcasts JSON over **UDP port 5005, 60 times a second**, to
`127.0.0.1` and the broadcast address.

```json
{
  "chairs":      [0, 1, 0, 0, 0, 0, 0],
  "n_occupied":  1,
  "speed":       1,
  "ring_alpha":  0.14,
  "regime":      1,
  "regime_name": "Hydraulic Mining",
  "stale":       [],
  "source":      "sensors",
  "temp_c":      [22.4, 23.1, 22.8, 22.5, 22.9, 23.0, 22.6],
  "vote":        [0.0, 0.85, 0.0, 0.0, 0.0, 0.0, 0.0]
}
```

| Field | Meaning |
|---|---|
| `chairs` | 7 flags, **index 0 is chair 1**. 1 = occupied |
| `n_occupied` | how many are occupied |
| `speed` | 0-9, scales with `n_occupied`. Drives flow rate |
| `ring_alpha` | 0.0-1.0, same scaling. Drives ring opacity |
| `regime` | index of the **most recently occupied** chair, or -1 |
| `regime_name` | that regime's name, or `"None"` |
| `stale` | chairs silent over 3s: flat battery or switched off |
| `source` | `"sensors"` or `"keyboard"`, so tests are never mistaken for real |
| `temp_c` | per chair, degrees C. Diagnostic only |
| `vote` | per chair, 0.0-1.0, the model's own confidence. Diagnostic only |

A complete consumer:

```python
import json, socket
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("", 5005))
while True:
    state = json.loads(s.recv(4096).decode())
    speed = state["speed"]
    alpha = state["ring_alpha"]
    # drive the render from here
```

Notes for implementers:

- Packets arrive at 60Hz whether or not anything changed. Treat each one as the current
  state rather than as an event.
- **A silent chair is reported empty, not held.** A flat battery would otherwise hold its
  regime active indefinitely, which is indistinguishable from a person sitting
  there for hours.
- `regime` is the **most recent** arrival, not the lowest-numbered occupied
  chair.
- UDP can drop packets. Another arrives within 17ms, so never block waiting for
  one.

### Known gaps

> **The renderers do not listen on UDP yet.** The chairs drive `controller.py`,
> but the last hop into the visuals is unconnected. It is a change to
> `flow_chevrons_live.py`, using the snippet above.

> **The chair-to-regime mapping is unverified.** `REGIMES` in `controller.py` is
> inherited from the original file and has never been checked against what the
> physical chairs represent.

---

# Installation

```bash
brew install arduino-cli
arduino-cli core install esp32:esp32
git clone https://github.com/gregottoniemeyer/sacramento_model.git
cd sacramento_model/chair-occupancy-sensor
python3 -m venv venv && venv/bin/pip install -r requirements.txt
```

`controller.py` itself needs **no packages at all**, only Python. The virtual
environment is for the development tools.

**USB-serial drivers.** The boards use two different chips. Most need Silicon
Labs' CP210x driver; the receiver uses a CH340 and needs that vendor's driver.
A board that never appears in `/dev/cu.*` is usually missing its driver.

**The baud rate is 921600** and must match `Serial.begin()` in
`firmware/receiver_esp_now.ino`. If the two differ, the log fills with unreadable
characters rather than failing cleanly.

**To make it run unattended**, put `tools/pull_and_refresh.sh` on a timer. It
pulls new code, keeps the capture alive, and keeps the controller alive. Full
step-by-step in [`development/ARCHIVE.md`](development/ARCHIVE.md).

---

# Repository layout

```
controller.py             reads the chairs, broadcasts to the screens
chair_state_monitor.py    check the chain is working

chair-occupancy-sensor/
  README.md               this file
  firmware/               sender_summary.ino   -> all 7 chairs
                          receiver_esp_now.ino -> the USB receiver
                          i2c_*, mpu_read_test -> wiring diagnostics
  tools/                  start_capture.sh     keeps the capture alive
                          pull_and_refresh.sh  the unattended timer job
                          flash_chair.sh       reflash a board safely
  data/                   recorded sessions
  development/            everything used to build and validate it, plus
                          ARCHIVE.md: the full history and reasoning
```

The occupancy model lives inside `controller.py`, so the file that runs the
installation depends on nothing else in this repository.

**Validated 2026-07-30** on data the model had never seen: 9/9 sit-downs, 9/9
stand-ups across all seven chairs, zero false positives.
