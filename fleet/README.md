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

## First-six per-river regime pilot

The Governator owns regime test input. An active Godot stage intentionally
ignores number keys `1` through `7`; run the controller console in a focused
Terminal window instead:

```bash
python3 fleet/godot_controller.py list
python3 fleet/godot_controller.py regime-clear
python3 fleet/godot_controller.py set --regime kinship
python3 fleet/godot_controller.py set --regime kinship --regime tech
python3 fleet/godot_controller.py regime-console
```

Inside `regime-console`, keys `1` through `7` toggle Kinship, Agriculture,
Gold Rush, Water Projects, Hydropower, Tech, and Watershed. Press `c` to clear
the active set, and `q` or Escape to leave the console. Exiting leaves the last
sent regime state active. The controller persists its authoritative set in
`~/.water_council_regime_state.json` and resends that absolute state when the
console opens. `start` and `restart` also reapply it automatically after launch,
so reopening the console or relaunching the fleet does not accidentally discard
an earlier command.

Each change sends the same modern `ink-flow/1` absolute-state packet on UDP
port `5005` once to every configured Godot process, with target `*`. A dual-screen
process applies the packet directly to its persistent `ModelRegimes` authority
before stage routing, even when the selector is visible or a stage is still
starting. The consumed regime paths are then removed from the stage-routed copy,
so the global change is applied exactly once; every active or subsequently loaded
stage consumes its own river row. Regime commands deliberately reject machine
suffix arguments because partial-fleet regime state would make the installation
incoherent. Each receiver returns an `ink-flow/1-ack` containing the accepted
active indices, recipient count, and recipient screen IDs. The controller retries
until every process reports the exact screen IDs and count configured for that
Mac, and prints `APPLIED` only after every process also acknowledges the exact
regime state. A missing or mismatched acknowledgement is an error rather than a
successful send.

All seven production wrappers consume their own screen row for the first six
regimes. The master
table is `godot_experiments/regime_feature_profiles.txt`; its
`river_profile_path` cells link to `kinship.txt`, `ranch.txt` (Agriculture),
`gold_rush.txt`, `water_projects.txt`, `hydropower.txt`, and `tech.txt` under
`godot_experiments/flow/data/regimes/`. A populated river cell overrides the
master, a blank inherits the master or remains undefined, and explicit `0` is a
defined contribution. For each feature on each screen, only defined active
contributors enter the equal mean; when none define it, the stage retains its
authored behavior.

The operator-level matrix is:

- Kinship removes the reservoir, drain/field, and obstacle constraints and their
  debug guides, defines source `.10`, and applies the full irregular shoreline,
  with salmon `11/01–01/31` daily and leaves `10/01–10/31` every 2 days on all
  seven. Water already retained by a reservoir is released downstream while its
  existing trail fades normally.
- Agriculture defines reservoir `.20` except Cottonwood `0` (counts 1 on
  Shasta/Mill/Feather/American, 2 on McCloud/Delta), drain `.75` everywhere,
  shoreline `.30` on Shasta/McCloud/Cottonwood and `0` elsewhere, with positive
  reservoir gates open `06/01–08/31`.
- Gold Rush defines reservoir `.10`, drain `.30` at full power, obstacle `.30`
  at full power, full shoreline, and the Kinship ecology seasons only on
  Feather/American/Delta; the other four rows are blank.
- Water Projects defines reservoir `.33`/count 1 and drain `.50` on
  Shasta/McCloud/Feather/American/Delta, explicit reservoir/drain zero on
  Cottonwood/Mill, and shoreline/leaves zero on all seven. Five of seven whole
  river stages is the nearest discrete allocation to the requested 75% scope.
- Hydropower defines reservoir `.50`/count 2 and a `.33` year-round gate on all
  but Cottonwood, reservoir/count zero on Cottonwood, drain `.25` everywhere,
  shoreline `.20` on McCloud/Cottonwood and `0` elsewhere.
- Tech defines reservoir `.75`/count 2, drain `.75` at full power, and shoreline
  zero on all seven. Watershed is reserved for the future AI model and is a
  current no-op with no linked per-river file.

The `*_area_fraction` values are deterministic particle admission/encounter
budgets, not literal geometric coverage. An explicit zero area removes that
feature's runtime constraint and hides its debug geometry; a zero reservoir
count also removes the reservoir. The Delta panel immediately renders active
regime names at full alpha and leaves inactive names dim. The renderer currently
has one physical reservoir; `reservoir_count=2` is retained desired-state data
awaiting a two-slot renderer. Agriculture and Hydropower gate schedules blend by
scheduled reservoir area, then multiply the effective aperture. With both
active on a non-Cottonwood screen, aperture is `.33` during June–August and
`.33 * .50 / (.50 + .20)` outside that season. A shoreline value of zero turns
off shoreline force; it does not redraw a straight bank.

The startup selector still accepts `1` through `7` before a stage launches.
Manual `S` and `L` ecology checks remain available in a running stage. A later
ESP32 adapter belongs in this controller and should call the same absolute-state
send path; Godot remains the state consumer rather than reading the USB device.

`start`, `restart`, and `editor` are clean launches: before opening Godot, the
controller stops and reaps every existing Godot instance on each targeted fleet
Mac, regardless of its project path. These Macs are treated as dedicated render
nodes; `stop` uses the same all-instance cleanup. This prevents a hidden instance
from owning UDP port `5005` and acknowledging or consuming regime packets
intended for the visible stages. Once `start` or `restart` sees the exact
configured screens, it reapplies the saved
regime set and treats any failed acknowledgement as startup failure.

The current addresses, login names, project paths, and stage assignments live in
the `COMPUTERS` dictionary near the top of `godot_controller.py`. Keep them in
sync with the actual fleet before deployment. Remote Macs require Remote Login,
SSH key authentication, Godot at the configured path, and an active graphical
login session.

`ping_monitor.py` uses ICMP. macOS Firewall Stealth Mode can suppress ping even
when SSH and the Water Council UDP controls are working.
