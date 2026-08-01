# Chair occupancy sensors

Seven chairs detect whether someone is sitting in them and publish that state
over the network. Everything needed to run and fix it is in this file; the
history and reasoning are in [`development/ARCHIVE.md`](development/ARCHIVE.md).

**Jump to:**
[operating](#operating) ·
[best practices](#best-practices) ·
[troubleshooting](#troubleshooting) ·
[development](#development) ·
[integration](#integration)

```
7 chairs  ──radio──▶  receiver on USB  ──▶  controller.py  ──UDP──▶  consumers
 ESP32 +              plugged into           decides who        anything that
 motion sensor        the Mac                is sitting         needs the state
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
| **Blinks once, every 3 seconds** | Working normally |  |
| **Blinking fast, without stopping** | Reporting an error | See below |
| **Completely dark** | Not running | Charge |

**A charge lasts about 20 hours**

**If every chair is blinking fast at once**, check the receiver.

## Best practices

- **Be careful screwing a sensor board down.**
- **Be gentle with the USB ports.**
- **Leave the tape inside the case.** It stops the board moving, which keeps
  detection accurate.
- **Mount the sensor toward the outer edge of the seat, not the middle.** It
  picks up more movement there when the chair turns.
- **Do not power a second receiver** while one is running.

---

# Troubleshooting

## A single chair is offline

1. **Light off** -> check the charge.
2. **Is the power switch on?**
3. **Was it just reflashed?** Boards sometimes land in the bootloader after an
   upload and look completely dead. Fix: `esptool --after hard-reset chip-id`.

## All chairs are offline

Either the receiver is unplugged, or the serial capture has stopped.

**Wait two minutes first**: the timer job restarts the capture on its own. If it
is still wrong after that, the receiver is probably unplugged. Plug it back in
and wait another minute.

To check by hand whether data is arriving at all:

```bash
wc -l ~/motion_log.txt; sleep 5; wc -l ~/motion_log.txt
```

It should climb by about **280 every 5 seconds** (7 chairs x 8 per second).
**If it does not climb, nothing downstream has current data.**

To force the capture to restart rather than waiting:

```bash
chair-occupancy-sensor/tools/start_capture.sh
```

## Nothing downstream is reacting

Run `python3 chair_state_monitor.py`. If it shows the correct chair states then
this system is working and the problem is in whatever consumes the UDP feed.

---

# Development

## Manual startup

Only needed if you are not on the Mac Mini (the one with the NASA sticker).

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

**4. Start whatever consumes the feed**, if anything is listening.

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

## Chair identification

**Chair identity lives in the receiver, not in the chair firmware.** Every ESP32
has a permanent factory MAC address, and the receiver maps each one to a chair
number.

**The table is `chairMacs` in `firmware/receiver_esp_now.ino`.** The same list
is mirrored in `tools/flash_chair.sh`, so a new board goes in both. Changing
either one means reflashing the receiver.

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

## Setting up another machine

`controller.py` needs only Python, no packages. The development tools need the
venv (`python3 -m venv venv && venv/bin/pip install -r requirements.txt`).

Two things that are not obvious:

- **USB-serial drivers.** The boards use two different chips. Most need Silicon
  Labs' CP210x driver; the receiver uses a CH340 and needs that vendor's driver.
  A board that never appears in `/dev/cu.*` is usually missing its driver.
- **The baud rate is 921600** and must match `Serial.begin()` in
  `firmware/receiver_esp_now.ino`. If the two differ the log fills with
  unreadable characters rather than failing cleanly.

To run unattended, put `tools/pull_and_refresh.sh` on a timer. Step-by-step in
[`development/ARCHIVE.md`](development/ARCHIVE.md).

## The model

Each chair sends the standard deviation of its gyro readings eight times a
second. The model counts a one-second window as a vote for "occupied" when
rotation about the vertical axis dominates the other two axes, and the chair
flips state when enough of the last few seconds are votes.

It lives in `controller.py`, in the constants block marked `occupancy model`.

| Change | To |
|---|---|
| `ENTER_FRAC` | make it easier or harder to become occupied |
| `EXIT_FRAC` | hold a still person longer, or release faster |
| `VOTE_WINDOW` | how many seconds of history the decision uses |
| `Z_FLOOR_RAW`, `RATIO_THRESHOLD` | how much rotation counts as a person |
| `PEAK_JUMP_RAW` | sensitivity to the sit-down jolt |
| `STALE_S` | how long a silent chair waits before it reads offline |

Changing any of these invalidates the recorded validation result, so re-score:

```bash
venv/bin/python development/tools/score_model.py data/dataset_20260730_122544.csv
```

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
| `speed` | 0-9, derived from `n_occupied`. Consumer-defined meaning |
| `ring_alpha` | 0.0-1.0, same derivation. Consumer-defined meaning |
| `regime` | index of the **most recently occupied** chair, or -1 if none |
| `regime_name` | the label for that index from `REGIMES`, or `"None"` |
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
    occupied = state["chairs"]        # [0,1,0,0,0,0,0]
    count    = state["n_occupied"]
    # use them from here
```

Notes for implementers:

- Packets arrive at 60Hz whether or not anything changed. Treat each one as the
  current state rather than as an event.
- **A silent chair is reported empty, not held.** A flat battery would otherwise
  hold its regime index active indefinitely, which is indistinguishable from a
  person sitting there for hours.
- `regime` is the **most recent** arrival, not the lowest-numbered occupied
  chair.
- UDP can drop packets. Another arrives within 17ms, so never block waiting for
  one.
