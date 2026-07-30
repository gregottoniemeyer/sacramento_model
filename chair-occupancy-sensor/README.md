# Chair occupancy sensors

Seven chairs detect whether someone is sitting in them and drive the Sacramento
River installation.

Each chair has a battery-powered ESP32 with a motion sensor. They report
wirelessly, eight times a second, to a receiver plugged into the Mac by USB.
`controller.py` turns that into occupancy and broadcasts it to the screens.

```
7 chairs  ──radio──▶  receiver on USB  ──▶  controller.py  ──UDP──▶  screens
```

**Everything needed day to day is in this file.** The engineering history, every
fault signature, and the reasoning behind each decision is in
[`development/ARCHIVE.md`](development/ARCHIVE.md).

---

## Run it

Four things must be running. Each one fails invisibly, which is why they are
listed separately.

**1. Switch the chairs on.** The power switch is on the underside of each
board. A chair is healthy when its blue light flashes briefly every 3 seconds.

**2. Start the serial capture.** Find the receiver's port first, because the
name changes depending on which USB socket it is in:

```bash
ls /dev/cu.*
```

Look for `wchusbserial*`. Then, with the real name substituted in:

```bash
exec 3<>/dev/cu.wchusbserial10
stty -f /dev/fd/3 921600 raw
cat <&3 > ~/motion_log.txt &
disown
```

**Check it is really running.** This step fails silently, and a stopped capture
freezes everything downstream with no error anywhere:

```bash
wc -l ~/motion_log.txt; sleep 5; wc -l ~/motion_log.txt
```

It should climb by about **280 every 5 seconds** (7 chairs x 8 per second). If
it does not climb, nothing downstream is real no matter how healthy it looks.

**3. Start the controller**, from the repo root:

```bash
python3 controller.py
```

**4. Start the renderers** on the screen Macs.

---

## Check it is working

```bash
python3 chair_state_monitor.py
```

Shows every chair's state, its temperature, and the vote fraction, which is the
number the model actually uses to decide. Add `--plain` for a terminal version
that needs nothing installed.

To test the whole downstream half with no chairs at all:

```bash
python3 controller.py --source keyboard
```

Press 1-7 to fake chairs. It sends identical packets, so nothing downstream can
tell the difference, and the monitor marks the source amber so a test is never
mistaken for real chairs.

---

## The blue light on each chair

Look at the board through the enclosure window.

| The light | Means | Do |
|---|---|---|
| **One brief flash every 3s** | Fine | Nothing |
| **Blinking continuously** | Something is wrong on that chair | See below |
| **Nothing at all** | Board is not running | Charge that chair |

That is the whole code, there is nothing to count.

**If every chair blinks at once the problem is not the chairs.** None of them
can reach the receiver: check it is plugged in and the Mac is awake.

**If one chair blinks** it is still transmitting, it just knows something is
off. Note which one and carry on. Not urgent unless it also stops responding.

---

## Charging

Each chair charges over its own **micro-USB port with the battery left in
place**. A red light near the chip comes on while charging.

**A chair runs about 20 hours on a charge** (measured 2026-07-30). Charging
overnight whenever the gallery is closed leaves several hours of margin. Two
full days of running without a charge will not fit.

A chair that goes dark or disappears has a flat battery. That is the expected
failure, not a fault.

> **The enclosures still need a charging notch cut.** Until then, reaching the
> port means unscrewing every chair every time. That matters for reliability
> rather than convenience: the boards that failed in July failed from being
> handled and flexed, and opening seven boxes per charge reapplies exactly that
> stress. Procedure in [`development/ARCHIVE.md`](development/ARCHIVE.md).

---

## When something stops working

Work down the list and stop at the first thing that explains it.

**One chair is offline**

1. Is its light doing anything? Nothing at all means charge it.
2. Is the power switch on? A chair read as dead on 30 July purely because of
   this.
3. Was it just reflashed? Boards sometimes land in the bootloader after an
   upload and look completely dead. Fix: `esptool --after hard-reset chip-id`.

**Every chair is offline at once**

Not the chairs. Either the receiver is unplugged or the serial capture died.
Check the capture with the `wc -l` test above. **This is the most common
failure and it is invisible: a stopped capture leaves every display frozen on
its last values.**

**A chair reads occupied with nobody in it**

Brief flickers when someone knocks or brushes a chair are expected and clear
within about 4 seconds. Permanently stuck occupied is not expected: report it.

**Everything looks fine but the screens do not react**

Run `python3 chair_state_monitor.py`. If it shows correct states then the
controller is fine and the problem is in the renderers.

---

## Please do not

- **Do not screw the sensor boards down.** This broke four chairs in July. The
  enclosure takes the screws, never the circuit board. If one comes loose,
  re-tape it.
- **Do not power a second receiver** while one is running.
- **Do not unplug the receiver** to charge something. Use another port.

---

## Which chair is which

**Chair identity lives in the receiver, not in the chair firmware.** Every ESP32
has a permanent factory MAC address, and `firmware/receiver_esp_now.ino` maps
each one to a chair number.

This means every chair runs **identical firmware**, a board cannot lose its
identity by being reflashed, and renumbering chairs is a two-line edit rather
than unmounting boards. That last point matters because unmounting is what
physically broke boards in July.

Boards are labelled with the **last two octets** of their MAC, for example
`B5:54` for chair 1. Two boards in this fleet differ only in the middle of
their address, so labelling by the end is deliberate.

An unrecognised board announces itself: the receiver prints
`Chair:?[88F155325F6C]`, and that address can be pasted straight into the table.

To read a board's MAC:

```bash
tools/flash_chair.sh /dev/cu.YOUR_PORT
```

**Slot 8 is not a chair.** It is the bench spare, for testing a sensor without
unmounting an installed chair. The controller ignores it.

---

## Feeding the artwork

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

Worth knowing:

- Packets arrive at 60Hz whether or not anything changed. Treat each one as the
  current truth, not as an event.
- **A silent chair is reported empty, not held.** A flat battery would otherwise
  latch its regime on forever, which looks identical to someone sitting there
  for hours.
- `regime` is the **most recent** arrival, not the lowest-numbered occupied
  chair.
- UDP drops packets. Another arrives in 17ms, so never block waiting.

> **Not connected yet:** the renderers do not listen on UDP. That last hop is a
> change to `flow_chevrons_live.py` using the snippet above.

> **Unverified:** the chair-to-regime mapping in `controller.py` is inherited
> from the original file and has never been checked against the physical chairs.

---

## Setting up a new machine

```bash
brew install arduino-cli
arduino-cli core install esp32:esp32
git clone https://github.com/gregottoniemeyer/sacramento_model.git
cd sacramento_model/chair-occupancy-sensor
python3 -m venv venv && venv/bin/pip install -r requirements.txt
```

**USB-serial drivers.** The boards use two different chips. Most need Silicon
Labs' CP210x driver; the receiver uses a CH340 and needs that vendor's driver.
If a board never appears in `/dev/cu.*`, this is why.

**The baud rate is 921600** and must match `Serial.begin()` in
`firmware/receiver_esp_now.ino`. Change one and the log fills with garbage
rather than failing cleanly.

**Automatic updates.** `tools/pull_and_refresh.sh` on a timer pulls new code and
restarts the controller. The serial capture does **not** auto-start and must be
started by hand after any reboot or replug.

---

## Reflashing a board

```bash
tools/flash_chair.sh /dev/cu.YOUR_PORT              # a chair
tools/flash_chair.sh /dev/cu.YOUR_PORT receiver     # the receiver
```

It reads the MAC before writing anything and refuses to flash chair code onto
the receiver, which otherwise succeeds silently and breaks the whole fleet.

**Flash the receiver before the chairs** if both need updating. A new chair
talking to an old receiver reads as `BAD PACKET` and looks exactly like a dead
board.

---

## What is where

```
controller.py             reads the chairs, broadcasts to the screens
chair_state_monitor.py    check the chain is working

chair-occupancy-sensor/
  README.md               this file
  firmware/               sender_summary.ino   -> all 7 chairs
                          receiver_esp_now.ino -> the USB receiver
                          i2c_*, mpu_read_test -> wiring diagnostics
  tools/                  flash_chair.sh, pull_and_refresh.sh
  data/                   recorded sessions
  development/            everything used to build and validate it, plus
                          ARCHIVE.md: the full history and reasoning
```

The occupancy model lives inside `controller.py`, so the file that runs the
installation depends on nothing else. The development tools import it from
there, so there is only ever one copy of the model.

**Validated 2026-07-30** on data the model had never seen: 9/9 sit-downs, 9/9
stand-ups across all seven chairs, zero false positives. Reproduce it with:

```bash
venv/bin/python development/tools/score_model.py data/dataset_20260730_122544.csv
```
