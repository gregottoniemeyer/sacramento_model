# Running the chairs — one page for whoever is minding the exhibit

Written 2026-07-29, for Greg, covering the run to the 1 September opening and
beyond while Max is in Zurich. Everything here is a normal part of running the
piece. Nothing here needs a soldering iron.

## What the system is

Seven chairs each hold a battery-powered sensor board that feels whether
somebody is sitting in it, and radios that to **one receiver board plugged
into the Mac Mini over USB**. The Mac reads the receiver and drives the
screens.

Two rules that matter more than anything else on this page:

1. **The receiver must stay plugged into the Mac Mini.** No receiver, no
   chairs, no matter how healthy the chairs are.
2. **Never power two receiver boards at once.** They deliberately share one
   radio address, so two of them in range corrupt each other's reception. One
   plugged in at a time. Ever.

## The blue light on each chair tells you if that chair is fine

Look at the board through the enclosure window:

| What the blue light does | What it means | What to do |
|---|---|---|
| **One brief flash every 3 seconds** | Everything is fine | Nothing |
| **Blinking continuously** | Something is wrong on that chair | See below |
| **Nothing at all** | The board is not running | Charge that chair's battery |

That is the whole code. There is nothing to count.

**If every chair is blinking at once, the problem is not the chairs.** It means
none of them can reach the receiver, so check that the receiver is plugged into
the Mac Mini and that the Mac is awake.

**If one chair is blinking**, that chair's sensor needs attention. It will
still be transmitting, it just knows something is off. Note which chair and
carry on; it is not urgent unless that chair also stops responding on screen.

## Charging

Each chair charges over its own **micro-USB port, with the battery left in
place** — nothing needs taking apart. A red LED near the chip lights while it
is charging.

A multi-port USB charger will do several at once. Charging all seven at the
same time needs seven cables.

**How often:** measured on chair 7 on 2026-07-30, a chair runs for **about 20
hours** of continuous use on one charge. Charging overnight whenever the
gallery is closed therefore leaves several hours of margin on a normal day.
A chair left running for two full days without a charge will go flat.

A chair that goes dark, or disappears from the dashboard, has a flat battery.
That is the expected failure and it is not a fault.

> **Use a cable that carries data, not just power**, if you ever need the Mac
> to see a board. Many charging cables have no data wires. This bit us on
> 2026-07-29: a board looked completely dead to the Mac purely because of the
> cable.

## Checking the whole thing is alive

On the Mac Mini, the dashboard shows one row per chair with its status and
whether it is currently reporting. See `MAC_MINI_SETUP.md` for how it is set up
to start on its own, and `README.md` for the manual start commands if it needs
bringing up by hand.

The thing to look for: **each chair should be reporting about 8 packets per
second.** A chair reading zero has either a flat battery or is switched off.

## If a chair stops responding

Work through this in order. Stop as soon as one of them explains it.

1. **Is the blue light doing anything?** Dark means charge it.
2. **Is the board switched off?** These boards have a power switch and it is
   easy to knock. This is the first thing to check, and on 2026-07-29 it was
   the actual explanation for a board that appeared dead.
3. **Charge it**, even if you think it was charged.
4. **Is the receiver still plugged into the Mac Mini, and is the Mac awake?**
   If several chairs went at once, it is this.
5. If none of that does it, note the chair number and leave it. A single
   chair out is a degraded piece, not a broken one.

## Please do not

- **Do not screw the sensor boards down.** This is what broke four chairs
  during the July install. The boards are held in their enclosures with tape
  on purpose; the enclosure takes the screws, never the circuit board. If a
  board comes loose, re-tape it.
- **Do not power a second receiver** while one is already running.
- **Do not unplug the receiver** to charge something. Use a different port.

## If something is genuinely wrong

The full engineering history, fault signatures and repair procedures are in
`NOTES.md` in this folder, and the diagnostic sketches in `firmware/`
(`i2c_line_check.ino` and `i2c_scanner.ino`) identify specific wiring faults
without guesswork. Both need a laptop with the Arduino IDE.
