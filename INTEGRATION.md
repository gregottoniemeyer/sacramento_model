# Sacramento Model: chairs to artwork

How the seven chairs drive the river piece, how to run it, how to test it with
no chairs present, and what to do when something stops working.

This is the readme Greg asked for on 11 July ("a smart way to make sure the
chair ID can be set ... please write a readme document that addresses this and
other system properties"). Chair identity is covered under
**[Which chair is which](#which-chair-is-which)**.

---

## The chain

```
  7 chairs                  receiver              Mac                screens
  ESP32 + MPU-6050   --->   ESP32 on USB   --->   controller.py  --->  renderers
  ESP-NOW radio, 8Hz        serial 921600         UDP 5005 @60Hz
```

Four things have to be running. **Each one is invisible when it fails**, which
is why they are listed separately here rather than as one command.

| # | What | Fails as |
|---|---|---|
| 1 | The chairs are powered on | that chair reads `OFFLINE` |
| 2 | The serial capture into `~/motion_log.txt` | **everything freezes on stale data, silently** |
| 3 | `controller.py` | no UDP packets |
| 4 | A renderer listening on UDP 5005 | screens do not react |

---

## Starting the chain

**1. Switch the chairs on.** Each has a power switch on the underside. A chair
whose status LED flashes briefly every 3 seconds is healthy. See `OPERATING.md`.

**2. Start the serial capture.** Find the receiver's port first, because the
suffix changes between USB sockets:

```bash
ls /dev/cu.*                       # look for wchusbserial*
```

Then, substituting the real name:

```bash
exec 3<>/dev/cu.wchusbserial10
stty -f /dev/fd/3 921600 raw
cat <&3 > ~/motion_log.txt &
disown
```

**921600 must match `Serial.begin()` in `firmware/receiver_esp_now.ino`.** They
are a pair. Change one and the log fills with garbled bytes instead of failing
cleanly.

Confirm it is actually running, because this is the step that fails silently:

```bash
wc -l ~/motion_log.txt; sleep 5; wc -l ~/motion_log.txt
```

It should climb by roughly **280 per 5 seconds** (7 chairs x 8Hz). If it does
not climb, nothing downstream is real, no matter how healthy it looks.

**3. Start the controller.**

```bash
python3 controller.py --source sensors
```

It prints a line whenever occupancy changes. Add `--target 10.0.0.42` for each
screen Mac if broadcast does not reach them.

**4. Start the renderers** on the screen Macs.

---

## Testing with no chairs

Both of these matter, because the chairs may be packed, charging, or not in the
room.

**Drive the artwork by hand.** Identical packets, so nothing downstream can tell
the difference:

```bash
python3 controller.py --source keyboard      # press 1-7 to toggle chairs
```

**See what the artwork is receiving:**

```bash
python3 chair_state_monitor.py
```

That prints the seven chair states, the occupied count, speed, ring alpha, and
which regime is driving the river. It has **no dependencies** and needs no
sensor tooling, so it runs anywhere and is the fastest way to answer "are the
chairs actually driving the piece?".

Run the keyboard controller and the monitor together and the whole downstream
half of the system can be exercised with no hardware at all.

---

## Integrating into the model

The controller broadcasts **JSON over UDP, port 5005, 60 times a second**, to
`127.0.0.1` and to the broadcast address. To consume it, listen for datagrams
and parse:

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
  "timestamp":   1785440000.123
}
```

| Field | Meaning |
|---|---|
| `chairs` | 7 flags, **index 0 is chair 1**. 1 = someone is sitting in it |
| `n_occupied` | how many are occupied, the same as `sum(chairs)` |
| `speed` | 0-9, scales with `n_occupied`. Drives flow rate |
| `ring_alpha` | 0.0-1.0, same scaling. Drives ring pool opacity |
| `regime` | index into `REGIMES` of the **most recently occupied** chair, or -1 |
| `regime_name` | that regime's name, or `"None"` |
| `stale` | chairs silent for over 3s. Flat battery or switched off |
| `source` | `"sensors"` or `"keyboard"`, so test data is never mistaken for real |

A minimal consumer, which is all a renderer needs:

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

**Points worth knowing before wiring this up:**

- Packets arrive at 60Hz whether or not anything changed. Treat each one as the
  current truth rather than as an event, and there is no need to track history.
- **A chair that goes silent is reported EMPTY, not held.** A flat battery would
  otherwise latch its regime on forever, which is indistinguishable from someone
  sitting there for hours. The chair also appears in `stale`, so a renderer that
  wants to show a fault can.
- `regime` is the **most recent** arrival, not the lowest-numbered occupied
  chair. Sitting in a second chair moves the dominant regime to it.
- UDP can drop packets. At 60Hz another arrives in 17ms, so never block waiting.

---

## Which chair is which

This is the part Greg asked about specifically.

**Chair identity is set at the receiver, not in the sender firmware.** Every
ESP32 has a permanent factory MAC address, and `firmware/receiver_esp_now.ino`
holds a table mapping MAC to chair number:

```c
const uint8_t chairMacs[NUM_CHAIRS][6] = {
  {0x8C, 0x94, 0xDF, 0x46, 0xB5, 0x54},  // chair 1
  {0x88, 0xF1, 0x55, 0x30, 0xAF, 0xB4},  // chair 2
  ...
```

**Why this is better than putting an ID in the firmware**, which was the
original suggestion:

- **Every chair runs byte-identical firmware.** One binary, `sender_summary.ino`,
  flashed to all seven. There is no per-chair build to keep track of, and no way
  to flash "chair 3's firmware" onto chair 5.
- **A board cannot lose its identity.** The MAC is burned in at the factory, so
  it survives reflashing, a flat battery, and a full erase.
- **Renumbering needs no chair to be touched.** Swapping two chairs' positions
  in the room is a two-line edit to the receiver, not two boards unmounted,
  carried to a laptop, reflashed and remounted. Given that unmounting is what
  physically broke boards on 24 July, this matters more than it sounds.
- **An unknown board announces itself.** The receiver prints
  `Chair:?[88F155325F6C]` with the MAC, so a new or swapped board can be added to
  the table by copying the number it just printed.

**To find a board's MAC:**

```bash
cd chair-occupancy-sensor
tools/flash_chair.sh /dev/cu.YOUR_PORT      # prints the MAC, then flashes
```

**Board labelling.** Boards are labelled with the **last two octets** of their
MAC, for example `B5:54` for chair 1, because that is unique across the fleet
and readable without opening anything or plugging anything in. Two boards in
this project differ only in the middle of their MAC (`88:f1:55:32:5f:6c` vs
`88:f1:55:30:af:b4`), so labelling by the last two octets is deliberate.

**Slot 8 is not a chair.** It is the bench spare, used to test a sensor against
the dashboard without unmounting an installed chair. `controller.py` ignores it,
so powering it on never affects the artwork.

---

## When something stops working

Work down this list. Stop at the first one that explains it.

**One chair reads OFFLINE**

1. Is its LED doing anything? Nothing at all means the board is not running:
   charge it. See `OPERATING.md`.
2. Is the power switch on? A chair read as dead on 30 July purely because of
   this.
3. Did it just get reflashed? Boards sometimes land in `DOWNLOAD_BOOT` after an
   upload and look completely dead. Fix is a second explicit reset:
   `esptool --after hard-reset chip-id`.

**Every chair reads OFFLINE at once**

The problem is not the chairs. Either the receiver is unplugged, or the serial
capture died. Check the capture first with the `wc -l` test above. This is the
single most common failure and it is invisible: **a stopped capture leaves every
display frozen on its last values with no error anywhere.**

**A chair reads OCCUPIED with nobody in it**

Brief flickers when somebody knocks or brushes a chair are expected and
self-correct within about 4 seconds. Permanently stuck OCCUPIED is not expected;
report it, since that was the failure the model rebuild removed.

**Everything looks fine but the screens do not react**

The chain is broken between the controller and the renderers. Run
`python3 chair_state_monitor.py`. If it shows correct states, the controller is
fine and the renderer is the problem.

---

## Why the occupancy model is not the 8 July algorithm

Greg proposed a confidence score on 8 July: 100 on a sit-down, +10 on motion, a
slow decay while still, occupied above 50. That was implemented, and it is not
what runs now. The reason is worth recording, because the change was made on
evidence rather than preference.

**The decay is what broke it.** With confidence latched to 100 by any single
detection and bled off over 90 seconds, a 4% false-fire rate during someone
walking past turned into **90 seconds of false OCCUPIED**. Worse, release was
gated on a departure being confirmed against a global quiet threshold, so a
chair whose noise floor sat above that threshold could never be released at all:
chair 6 had only 3.2% of its empty samples below the bar and was therefore
**permanently OCCUPIED by construction**.

**What replaced it** keeps the part that was right. The core insight, that a
person in a swivel chair rotates it and a passer-by does not, discriminates
cleanly: it fires on 96% of seated windows, 4% of walk-bys, and 0% of empty
chairs. The rebuilt model is a vote fraction over a trailing window with
hysteresis, plus a fast path for the sit-down impulse, plus that rotation gate.
No confidence, no decay: **the state stops when the evidence stops.**

**Measured on 30 July across all seven chairs**, on data the model had never
seen: 9/9 sit-downs, 9/9 stand-ups, zero chairs failing to detect, and no
cross-coupling between chairs. Reproduce it with:

```bash
cd chair-occupancy-sensor
venv/bin/python tools/score_model.py data/dataset_20260730_122544.csv
```

The one behaviour Greg's design was reaching for, holding a motionless sitter,
is handled by the vote window and its exit threshold rather than by decay. It is
the honest weak point: a person who sits completely still for a very long time
is the hardest case, and it is measured rather than assumed.
