# Chair power-save tests

This test changes firmware only. The MPU-6050 remains on GPIO21/GPIO22 with no
interrupt wire.

The prototype preserves 100 Hz sensing and the receiver's 39-byte packet
format. While idle it shuts Wi-Fi/ESP-NOW off and uses timer-driven ESP32 light
sleep between samples. It transmits three copies of a motion event and sends a
two-packet heartbeat every 10 seconds during validation.

Every accepted motion event is encoded at or above the receiver's 1500
occupied threshold, so a motion-triggered transmission cannot arrive as a free
report.

The controller waits 15 seconds before marking a chair dormant. This is longer
than the 10-second validation heartbeat interval, so a healthy power-saving
sensor remains live between heartbeats.

## Flash the test

```bash
tools/flash_chair_power_test.sh /dev/cu.usbserial-0001 power-save upload
```

The tool reads the factory MAC first and refuses every board except the
explicitly selected target. The active targets are `chair1`, `agriculture`,
`gold-rush`, `water-projects`, `hydropower`, `tech`, and `watershed`. Gold Rush
is receiver slot 8, mapped to logical chair 3; retired slot 3 is excluded.

## Immediate rollback

```bash
tools/flash_chair_power_test.sh /dev/cu.usbserial-0001 rollback upload
```

Rollback uses the exact deployed `sender_summary.ino` from Git commit
`0cfad3388a3d5956b160d64e4b853b0b0ac2eccd`, verifies its SHA-256 checksum,
compiles it with ESP32 core 3.3.11, uploads it, and hard-resets the board.

## Serial validation

The prototype reports at 115200 baud:

- `IDLE`: the sensor window, current peak/std values, radio-off state, and
  percentage of elapsed time spent in light sleep.
- `TX heartbeat`: a periodic liveness packet.
- `TX impact` or `TX rotation`: a motion-triggered three-packet burst.
- `ack:N/M`: how many packets the receiver acknowledged.

The light-sleep percentage is a behavioral diagnostic, not a current
measurement. Battery-life claims still require a timed battery test or an
inline current meter.

## Chair 1 validation — 2026-08-26

- Confirmed MAC `8c:94:df:46:b5:54` before every upload.
- Sensor health remained good (`Flags:7`, 100 samples per window).
- Idle gyro variation was approximately 13-18.
- Firmware reported approximately 88-89% of elapsed time in light sleep.
- Heartbeats received 2/2 ESP-NOW acknowledgements.
- Motion bursts received 3/3 ESP-NOW acknowledgements.
- Motion on the correct physical chair reported occupied successfully.
- A redundant-heartbeat timing issue found during the first trace was fixed
  before the final build.

Chair 1 was rolled back to the original deployed firmware after this
validation. The 10-second heartbeat remains intentionally short in the test
build.

## Gold Rush scheduled build — 2026-08-27

The scheduled power-saving build was loaded onto the Gold Rush replacement
sensor after verifying factory MAC `88:f1:55:32:5f:6c`:

```bash
tools/flash_chair_power_test.sh /dev/cu.usbserial-0001 power-save-scheduled upload gold-rush
```

The image was compiled, uploaded, flash-verified, and hard-reset successfully.
It fails awake until the scheduled USB receiver and `.11` bridge are deployed.

## Optional .11 gallery schedule

The scheduled build uses the Governator computer at `196.168.50.11` as its
wall-clock authority. `telemetry/serial_schedule_bridge.py` keeps capturing the
receiver's serial output and sends its local `America/Los_Angeles` gallery state
to the USB receiver every five seconds. The scheduled receiver answers only
sensor packets carrying `FLAG_SCHEDULE_REQUEST`, so all older sensors remain
compatible.

At or shortly after 9 p.m., a scheduled sensor receives the number of seconds
until the next 9 a.m., puts the MPU-6050 into sleep mode, and enters ESP32 deep
sleep. It wakes by timer at 9 a.m. A reset or battery swap while closed is also
handled: after boot, the sensor asks the receiver for the current remaining
closed interval. Missing or stale `.11` clock data always **fails awake**.

Deployment order matters:

1. Flash the USB receiver with `receiver_scheduled.ino` and verify ordinary
   chair packets still reach `motion_log.txt`.
2. Deploy/start the `.11` serial schedule bridge and verify the receiver prints
   `Gallery clock: OPEN` or `Gallery clock: CLOSED`.
3. Flash one test sensor with `power-save-scheduled`.
4. Test a simulated short closed interval before enabling the permanent 9-to-9
   schedule across the fleet.

Commands for the two firmware roles are:

```bash
tools/flash_receiver_schedule.sh /dev/cu.wchusbserial10 scheduled upload
tools/flash_chair_power_test.sh /dev/cu.usbserial-0001 power-save-scheduled upload gold-rush
```

Both flash tools retain a verified rollback option. Do not flash the scheduled
sensor before the receiver relay and `.11` clock bridge have been verified.

## Optional interrupt-wire upgrade

The MPU-6050 breakout pin labeled `INT` is the motion-interrupt output. If the
firmware-only test is insufficient, it can be connected to a verified free
RTC-capable ESP32 GPIO so motion wakes the processor immediately. Confirm the
specific board pinout before wiring.
