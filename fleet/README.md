# Water Council fleet tools

These operator-side tools run on the Governator and manage the four Mac fleet.
They are intentionally outside `godot_experiments/`, so they are not bundled into
the exported Godot application.

## Files

- `godot_controller.py` checks, starts, stops, restarts, and reports the status of
  Godot on the Governator and the three renderer Macs over SSH.
- `ping_monitor.py` performs a lightweight periodic reachability check of the
  renderer Macs.

The controller launches stage assignments through the command-line interface in
`godot_experiments/startup_selector.gd`:

```text
--stages=7
--stages=1,2
```

## Typical commands

Run these from the repository root:

```bash
python3 fleet/godot_controller.py check
python3 fleet/godot_controller.py start
python3 fleet/godot_controller.py status
python3 fleet/godot_controller.py restart
python3 fleet/godot_controller.py stop
```

Pass one or more configured target suffixes to limit an action:

```bash
python3 fleet/godot_controller.py restart 21 31
```

The current addresses, login names, project paths, and stage assignments live in
the `COMPUTERS` dictionary near the top of `godot_controller.py`. Keep them in
sync with the actual fleet before deployment. Remote Macs require Remote Login,
SSH key authentication, Godot at the configured path, and an active graphical
login session.

`ping_monitor.py` uses ICMP. macOS Firewall Stealth Mode can suppress ping even
when SSH and the Water Council UDP controls are working.
