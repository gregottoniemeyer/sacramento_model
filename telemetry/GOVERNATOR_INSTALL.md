# Governator chair telemetry

This copy is installed on `196.168.50.11` at:

```text
/Users/francescospagnolo/Documents/watercouncil/code/telemetry
```

Because macOS blocks background LaunchAgents from executing scripts inside a
user's Documents folder, the small live subset is mirrored at
`~/.water_council/runtime/code/`. The Documents copy remains
the canonical complete installation; the Application Support copy owns the
live `motion_log.txt` and processes.

## Runtime chain

1. The USB ESP32 receiver writes raw serial lines to the bounded live buffer
   `telemetry/motion_log.txt`. Existing or replaced file contents are never
   replayed, and the keep-alive clears the buffer above 1 MiB.
2. `telemetry/controller.py` treats a major-motion peak as a 30-second interval
   for chairs 1-6 and a 60-second interval for AI Watershed chair 7; later
   major motion renews that chair's complete interval.
3. `fleet/godot_controller.py chairs` loads that `SensorSource` state directly.
4. Occupied chairs become the absolute active Godot regime set on UDP 5005.
5. The optional diagnostic publisher uses UDP 5006, so it cannot collide with
   Godot. Run `python3 chair_state_monitor.py` to view it.

The fixed artwork mapping is:

1. Kinship
2. Agriculture
3. Gold Rush
4. Water Projects
5. Hydropower
6. Tech
7. Watershed

## Automatic recovery

`~/Library/LaunchAgents/com.watercouncil.telemetry.plist` runs
`chair-occupancy-sensor/tools/keep_alive.sh` at login and every 30 seconds. It
repairs the serial capture and starts both the diagnostic publisher and Godot
chair bridge if either is absent.

The repository copy of the job is
`deployment/com.watercouncil.telemetry.plist`.

Useful logs:

```text
telemetry/keep_alive.log
telemetry/controller.log
telemetry/godot_chairs.log
```

## USB drivers

Signed, universal WCH CH34x and Silicon Labs CP210x driver applications are
staged in `telemetry/drivers/`. The receiver uses CH34x. macOS may require a
one-time administrator approval and restart after installing its system
extension. CP210x is needed when directly connecting compatible chair boards
for firmware work.
