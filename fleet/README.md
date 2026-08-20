# Water Council fleet tools

These operator-side tools manage the four dedicated Water Council render Macs.
The controller can run on the Governator at `196.168.50.11` or on the studio Mac
at `196.168.50.51`; it detects which operator it is running on. The Governator is
local only when the controller runs on `.11`. From `.51`, all four fleet Macs,
including `.11`, are remote SSH targets.

The tools remain outside `godot_experiments/`, so they are not loaded by the
Godot project. Run every command below from the repository root.

## Fleet map

| Target | Address | SSH account | Installed project | Stages |
| --- | --- | --- | --- | --- |
| `11` | `196.168.50.11` | `francescospagnolo` | `/Users/francescospagnolo/Documents/watercouncil/code` | `7` |
| `21` | `196.168.50.21` | `gregniemeyer` | `/Users/gregniemeyer/Documents/watercouncil/code` | `1,2` |
| `31` | `196.168.50.31` | `gregniemeyer` | `/Users/gregniemeyer/Documents/watercouncil/code` | `3,4` |
| `41` | `196.168.50.41` | `gregniemeyer` | `/Users/gregniemeyer/Documents/watercouncil/code` | `5,6` |

The controller passes stage assignments such as `--stages=7` and
`--stages=1,2` to `godot_experiments/startup_selector.gd`.

## Studio `.51` network setup

The studio Mac uses two separate networks:

- Ethernet connects only to the isolated fleet switch. Configure it manually as
  `196.168.50.51` with subnet mask `255.255.255.0`. Leave router and DNS blank,
  and use link-local IPv6 only.
- Wi-Fi supplies Internet access. Keep Wi-Fi above Ethernet in Network Service
  Order so the normal default route remains on Wi-Fi.
- Leave Internet Sharing and network bridging off. Do not connect the fleet
  switch to the studio GS305, wall jack, or campus network.

Before using the controller, confirm that Ethernet still has `.51` and that the
four fleet addresses are on the Ethernet route. The controller deliberately
refuses deployment unless it detects the studio `.51` operator address.

## One-time SSH onboarding from `.51`

On every fleet Mac, enable **Remote Login** and allow the account shown in the
fleet map. That same account must be logged into the visible macOS desktop so a
Godot process launched over SSH can use the displays. Confirm that Godot is
executable at `/Applications/Godot.app/Contents/MacOS/Godot` and that the parent
of the installed project is writable by the SSH account.

The controller defaults to `~/.ssh/water_council_fleet_ed25519`. Set
`WATER_COUNCIL_SSH_IDENTITY` to an alternate private-key path when necessary,
then install the matching public key on every target:

```bash
ssh-keygen -t ed25519 -f ~/.ssh/water_council_fleet_ed25519 -C water-council-studio-51
ssh francescospagnolo@196.168.50.11 true
ssh gregniemeyer@196.168.50.21 true
ssh gregniemeyer@196.168.50.31 true
ssh gregniemeyer@196.168.50.41 true
ssh-copy-id -i ~/.ssh/water_council_fleet_ed25519.pub francescospagnolo@196.168.50.11
ssh-copy-id -i ~/.ssh/water_council_fleet_ed25519.pub gregniemeyer@196.168.50.21
ssh-copy-id -i ~/.ssh/water_council_fleet_ed25519.pub gregniemeyer@196.168.50.31
ssh-copy-id -i ~/.ssh/water_council_fleet_ed25519.pub gregniemeyer@196.168.50.41
```

The first connections ask for each remote password and host-key confirmation.
Verify each fingerprint before accepting it; do not disable host-key checking.
Then prove that non-interactive authentication works with the configured key:

```bash
ssh -i ~/.ssh/water_council_fleet_ed25519 -o IdentitiesOnly=yes -o BatchMode=yes francescospagnolo@196.168.50.11 true
ssh -i ~/.ssh/water_council_fleet_ed25519 -o IdentitiesOnly=yes -o BatchMode=yes gregniemeyer@196.168.50.21 true
ssh -i ~/.ssh/water_council_fleet_ed25519 -o IdentitiesOnly=yes -o BatchMode=yes gregniemeyer@196.168.50.31 true
ssh -i ~/.ssh/water_council_fleet_ed25519 -o IdentitiesOnly=yes -o BatchMode=yes gregniemeyer@196.168.50.41 true
```

The controller uses `BatchMode=yes`, `IdentitiesOnly=yes`, a fifteen-second
connection timeout, and no connection retry; password prompts cannot rescue a
missing key. Ping alone is not an SSH test, and macOS Firewall Stealth Mode may
suppress ping even when SSH works. Godot also needs inbound UDP port `5005`,
plus the return acknowledgement to the temporary controller UDP port.

## Safe deployment from `.51`

Deployment copies the contents of the controller-relative
`../godot_experiments/` directory to each selected installed `code` directory,
then mirrors the controller-relative `fleet/` directory into `code/fleet/`.
On the studio Mac the intended source is
`/Volumes/Consulting/Water Council/code/godot_experiments`. Always review a dry
run first:

```bash
python3 fleet/godot_controller.py deploy --dry-run
python3 fleet/godot_controller.py deploy
python3 fleet/godot_controller.py check
python3 fleet/godot_controller.py start
python3 fleet/godot_controller.py status
```

The dry run reports intended changes without stopping Godot or changing remote
files. Deployment requires an existing installed `code` tree on every selected
Mac so that an automatic rollback always has a complete predecessor. A real
deploy first stages and checksum-verifies every selected target
while the current installation remains active. Only after every stage passes
does it stop Godot on those dedicated nodes and promote the staged trees. It
then checksum-verifies the active trees. If staging, promotion, or final
verification fails, it rolls back every target it already promoted and returns
a nonzero status. Deployment intentionally leaves the nodes stopped; `start` is
a separate, visible operator decision.

Use a machine suffix only for a deliberate diagnostic or repair deployment:

```bash
python3 fleet/godot_controller.py deploy --dry-run 21
python3 fleet/godot_controller.py deploy 21
```

For a production release, deploy all four together so the installation does not
run mixed code. Do not interrupt a real deployment after it begins promotion.
Do not run a regime command during a partial deployment or maintenance window.

Each target is staged in a sibling `.code.deploy-<12-hex-id>` directory.
During promotion, the previous tree is moved to the matching
`.code.backup-<12-hex-id>` path so an automatic rollback remains possible.
After every promoted tree passes checksum verification, that release's old
backup is deleted. The deployed mirror excludes `.godot/`, `.DS_Store`,
`godot-remote.log`, `__pycache__/`, `*.pyc`, and `*.pyo`. The controller does not
update a running project in place and never deletes a path that does not match
the exact generated backup/staging pattern.

## Daily start, stop, and status

Use `status` before an intervention, `check` after a deployment, and `status`
again after a start or restart:

```bash
python3 fleet/godot_controller.py ping
python3 fleet/godot_controller.py status
python3 fleet/godot_controller.py check
python3 fleet/godot_controller.py start
python3 fleet/godot_controller.py stop
python3 fleet/godot_controller.py restart
```

Pass target suffixes to limit these machine actions:

```bash
python3 fleet/godot_controller.py status 21 31
python3 fleet/godot_controller.py restart 21 31
```

`start`, `restart`, `editor`, and `stop` terminate **every** Godot instance on
each selected Mac, not only this project. That is safe only because the fleet
Macs are dedicated render nodes. `start` and `restart` launch exactly one
process per selected Mac, wait for the configured stage IDs, and reapply the
central regime state. An `OK` launch request without the later `APPLIED` line is
not a complete successful start. Inspect the corresponding
`code/godot-remote.log` before retrying a failed start. Each new launch truncates
the active log, so copy a log that matters before `start` or `restart`.

## Central regime state on `.11`

The authoritative state file is
`/Users/francescospagnolo/.water_council_regime_state.json` on `.11`. A
controller running on `.51` reads and writes that same file over SSH; it must
not create a competing state file in the `.51` home directory. This keeps
regime and geometry state stable when operators alternate between `.11` and
`.51`, and a project deployment does not replace it because it lives outside
the installed `code` tree.

Back up the central file before intentionally resetting installation state. If
`.11` or its SSH authentication is unavailable, do not guess or create a local
replacement; restore access to `.11` first. `start` and `restart` use the
central state for startup synchronization, while `set`, `regime-clear`, and
`regime-console` update it only after the fleet acknowledges the requested
absolute state.

## Rollback

The deploy action performs an automatic fleet-consistent rollback if promotion
or checksum verification fails. After all four new trees verify, the temporary
predecessor trees are deleted as requested; there is no lingering on-machine
old version. To return to an earlier release after a successful deployment,
check out or extract that known release in the authoritative studio repository,
run `deploy --dry-run`, and deploy all four Macs together. The central regime
state normally does not need rollback because project deployment does not
modify it.

## First-six per-river regime pilot

The Governator at `.11` owns authoritative regime state, but the operator may
send commands from `.11` or `.51`. An active Godot stage intentionally ignores
number keys `1` through `7`; run the controller console in a focused Terminal
window instead:

```bash
python3 fleet/godot_controller.py list
python3 fleet/godot_controller.py regime-clear
python3 fleet/godot_controller.py set --regime kinship
python3 fleet/godot_controller.py set --regime kinship --regime tech
python3 fleet/godot_controller.py set --geo FALSE
python3 fleet/godot_controller.py set --regime kinship --geo TRUE
python3 fleet/godot_controller.py regime-console
```

`set --geo TRUE/FALSE` sets obstacle/debug geometry to an absolute state on all
seven screens. `FALSE` hides the reservoir guide and obstacle/drain outlines
without changing their physics; `TRUE` shows them. A geometry-only `set`
preserves the saved regime set, while a combined command replaces the regime
set and changes geometry visibility together. The geometry value is persisted
and reapplied by `start` and `restart`. Values are case-insensitive, but must be
`TRUE` or `FALSE`.

Inside `regime-console`, keys `1` through `7` toggle Kinship, Agriculture,
Gold Rush, Water Projects, Hydropower, Tech, and Watershed. Press `c` to clear
the active set, and `q` or Escape to leave the console. Exiting leaves the last
sent regime state active. The controller persists the authoritative set on
`.11` and resends that absolute state when the console opens. `start` and
`restart` also reapply it automatically after launch, so reopening the console
or relaunching the fleet does not accidentally discard an earlier command.

Each change sends the same modern `ink-flow/1` absolute-state packet on UDP
port `5005` once to every configured Godot process, with target `*`. A
dual-screen process applies the packet directly to its persistent `ModelRegimes`
authority before stage routing, even when the selector is visible or a stage is
still starting. The consumed regime paths are then removed from the stage-routed
copy, so the global change is applied exactly once; every active or subsequently
loaded stage consumes its own river row. Regime commands deliberately reject
machine suffix arguments because partial-fleet regime state would make the
installation incoherent.

Each receiver returns an `ink-flow/1-ack` containing the accepted active
indices, recipient count, and recipient screen IDs. The controller retries until
every process reports the exact screen IDs and count configured for that Mac,
and prints `APPLIED` only after every process also acknowledges the exact regime
state. A missing or mismatched acknowledgement is an error rather than a
successful send. For `--geo`, the acknowledgement also reports applied
visibility by screen ID. Stages apply routed control at a frame boundary, so the
controller retries the same absolute packet until every configured screen
reports the requested value.

## Per-river regime behavior

All seven production wrappers consume their own screen row for the first six
regimes. The master table is `godot_experiments/regime_feature_profiles.txt`;
its `river_profile_path` cells link to `kinship.txt`, `ranch.txt`
(Agriculture), `gold_rush.txt`, `water_projects.txt`, `hydropower.txt`, and
`tech.txt` under `godot_experiments/flow/data/regimes/`. A populated river cell
overrides the master, a blank inherits the master or remains undefined, and
explicit `0` is a defined contribution. For each feature on each screen, only
defined active contributors enter the equal mean; when none define it, the
stage retains its authored behavior.

The master and linked files use source-free schema version `2`: reservoir,
drain/field, obstacle, shoreline, and ecology values remain, while supplemental
source-area/season columns and source-polygon controls do not. The ordinary
full-height left river inlet remains part of every water lifecycle.

The operator-level matrix is:

- Kinship removes the reservoir, drain/field, and obstacle constraints and their
  debug guides and applies the full irregular shoreline, with salmon
  `11/01–01/31` daily and leaves `10/01–10/31` every 2 days on all seven. Water
  already retained by a reservoir is released downstream while its existing
  trail fades normally.
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

The reservoir, drain, and obstacle `*_area_fraction` values are deterministic
particle admission/encounter budgets, not literal geometric coverage. An
explicit zero area removes that feature's runtime constraint and hides its
debug geometry; a zero reservoir count also removes the reservoir. The Delta
panel immediately renders active regime names at full alpha and leaves inactive
names dim. The renderer currently has one physical reservoir;
`reservoir_count=2` is retained desired-state data awaiting a two-slot renderer.

Agriculture and Hydropower gate schedules blend by scheduled reservoir area,
then multiply the effective aperture. With both active on a non-Cottonwood
screen, aperture is `.33` during June–August and `.33 * .50 / (.50 + .20)`
outside that season. A shoreline value of zero turns off shoreline force; it
does not redraw a straight bank.

The startup selector still accepts `1` through `7` before a stage launches.
Manual `S` and `L` ecology checks remain available in a running stage. A later
ESP32 adapter belongs in this controller and should call the same absolute-state
send path; Godot remains the state consumer rather than reading the USB device.

Regime changes update the already-running stages and their fixed particle pools;
they do not create replacement scenes or additional Godot processes. Re-sending
the same absolute active set is idempotent: it can be acknowledged without
reapplying stage features or schedules. Ecology and scheduled reservoir gates
are evaluated on an actual regime change or model-day boundary, rather than on
every rendered frame. Kinship's explicit zero drain and obstacle budgets also
skip the generic polygon-interaction passes; its shoreline remains active as a
bounded edge-turbulence field.

Every real change to the absolute active set advances a layout generation on
each stage. The five resident drain/field slots and two resident obstacle slots
are reused but receive fresh per-screen positions; switching `Tech` to
Agriculture therefore cannot leave the same layout in place. Re-sending the
identical set does not reroll it. Active fields are newly sized trapezoids rooted
at alternating top/bottom screen edges. Eligible water curves laterally through
their river-facing mouths, continues toward the bank, and drains offscreen before
its fixed head slot is recycled. Obstacles likewise move on each real
transition. No transition restarts water or grows a node, resource, texture, or
particle pool.

## Post-installation validation

After `start` reports an acknowledged state, confirm exactly one Godot PID on
each dedicated renderer Mac, inspect all four logs, and visually confirm all
seven assigned stages. Run a representative 12-minute/full-model-year soak on
the oldest fleet Mac while exercising regime changes and seasonal salmon/leaves.
Confirm steady frame pacing and memory in Activity Monitor. The controller's
clean start enforces the one-process layout, and the fixed-pool smokes cover
retained node/resource growth, but neither guarantees sustained performance on
a particular older Mac.

The addresses, login names, identity paths, project paths, and stage assignments
live near the top of `godot_controller.py`. Keep them synchronized with the
physical fleet. `ping_monitor.py` is only a lightweight ICMP availability view;
use controller `check`, acknowledged startup, logs, and the physical screens for
an operational verdict.
