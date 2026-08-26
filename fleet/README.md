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
| `11` | `196.168.50.11` | `francescospagnolo` | `/Users/francescospagnolo/Documents/watercouncil/code` | `7` on extended screen `1` |
| `21` | `196.168.50.21` | `gregniemeyer` | `/Users/gregniemeyer/Documents/watercouncil/code` | `1,2` |
| `31` | `196.168.50.31` | `gregniemeyer` | `/Users/gregniemeyer/Documents/watercouncil/code` | `3,4` |
| `41` | `196.168.50.41` | `gregniemeyer` | `/Users/gregniemeyer/Documents/watercouncil/code` | `5,6` |

The controller passes stage assignments such as `--stages=7` and
`--stages=1,2` to `godot_experiments/startup_selector.gd`.

On the Governator, `godot_controller.py chairs` maps the seven absolute chair
flags to the seven regimes. Every chair is a separate binary signal: strong
motion turns chairs 1-6 on for 30 seconds and AI Watershed chair 7 on for 60
seconds. Later strong motion from the same chair renews only its complete
interval, and the timer releases exactly at its deadline. After every interval
expires, the bridge performs an explicit hard
reset to Kinship with geometry visible; it never sends an empty regime state.
Regime activation alone determines which extractor and floodplain shapes exist.
Watershed remains exclusive when chair 7 activates and clears all other chair
timers. A newer strong signal from chairs 1-6 immediately cancels Watershed and
starts that chair's timer. If Watershed reaches its own 60-second deadline, all
chairs are released. Handoffs use the same strong-motion threshold as ordinary
activation; there is no lower noise-sensitive threshold.

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
Atomic staging imports and checksum-verifies the clean Godot project first,
then copies the installed `telemetry/` and `watershed_ai/` trees into the stage
before promotion. Copying them after import prevents virtualenv sample data from
being mistaken for Godot resources. Those two runtime trees
are excluded from project deletion and checksum comparison, so deployment
preserves them byte-for-byte while still removing unprotected retired material.
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
deploy first stages and checksum-verifies every selected target, runs Godot's
headless import on each staged tree, and verifies the generated font and global
script-class caches while the current installation remains active. Cache
readiness requires the exact packaged Barlow font import and every global class
used by the flow stages. Only after every stage passes
does it stop Godot on those dedicated nodes and promote the staged trees. It
then checksum-verifies the active trees and revalidates active font and global-class
caches before deleting any predecessor backup. If staging, promotion, or final
verification fails, it rolls back every target it already promoted and returns a
nonzero status. Deployment intentionally leaves the nodes stopped; `start` is a
separate, visible operator decision.

Use a machine suffix only for a deliberate diagnostic or repair deployment:

```bash
python3 fleet/godot_controller.py deploy 21 --dry-run
python3 fleet/godot_controller.py deploy 21
```

For a production release, deploy all four together so the installation does not
run mixed code. Do not interrupt a real deployment after it begins promotion.
Do not run a regime command during a partial deployment or maintenance window.

For an offline gallery update copied directly onto the Governator, first stop
the fleet and install the changed source into target `11` locally. The updated
Governator controller can then atomically deploy that complete local source to
the three remote render nodes:

```bash
python3 fleet/godot_controller.py deploy 21 31 41 --dry-run
python3 fleet/godot_controller.py deploy 21 31 41
python3 fleet/godot_controller.py start
```

The Governator intentionally refuses to deploy target `11` to itself; the
offline update bundle owns that local copy step. The full `start` still launches
stage 7 on extended screen `1`, establishes Kinship, and restarts telemetry.

Each target is staged in a sibling `.code.deploy-<12-hex-id>` directory.
During promotion, the previous tree is moved to the matching
`.code.backup-<12-hex-id>` path so an automatic rollback remains possible.
After every promoted tree passes checksum verification, that release's old
backup is deleted. The deployed mirror preserves and excludes `telemetry/` and
`watershed_ai/`; it also excludes `.godot/`, `.DS_Store`, `godot-remote.log`,
`__pycache__/`, `*.pyc`, and `*.pyo`. `.godot/` is generated afresh on each
target rather than copied across machines. The controller does not update a
running project in place and never deletes a path that does not match the exact
generated backup/staging pattern.

## Daily start, stop, and status

Use `status` before an intervention, `check` after a deployment, and `status`
again after a start or restart. `check` includes the machine-local Godot global
class cache and Barlow font import, not only source files:

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
process per selected Mac, wait for the configured stage IDs, and apply the hard
startup baseline: Kinship with geometry visible. When target `11` starts
successfully, the controller then copies the installed fleet controller into
the Governator's isolated live runtime and restarts the telemetry launch agent.
It verifies that exactly one diagnostic publisher and one Godot chair bridge
remain, so `python3 fleet/godot_controller.py start` is also a clean telemetry
restart. Conversely, a successful `stop` that includes target `11` unloads the
telemetry LaunchAgent, terminates both telemetry processes, and verifies that
zero remain. The next `start` bootstraps the LaunchAgent again. An `OK` launch request
without the later `APPLIED` line is
not a complete successful start. Inspect the corresponding
`code/godot-remote.log` before retrying a failed start. Each new launch truncates
the active log, so copy a log that matters before `start` or `restart`.

Every controller `start` or `editor` launch runs Godot as the child of
`/usr/bin/caffeinate -d -i -s`. Those assertions prevent display sleep, idle
system sleep, and system sleep on AC power for exactly the lifetime of Godot;
they are released automatically when Godot exits. The controller matches the
child executable at the start of its command line, so the caffeinate parent is
not counted as a second Godot process and `status`/`stop` retain their exact
one-process behavior.

This runtime guard is not a substitute for fleet power configuration. Apple's
power assertions are advisory: a repeating sleep event should ordinarily be
deferred by `-s` while these Mac minis are on AC power, but an explicit
shutdown/restart, power loss, or an OS thermal/power emergency can still take a
node down. On 2026-08-21 the audit found a repeating 7:00 PM sleep / 10:00 AM
wake schedule on `.11`, one-minute system sleep on `.31` and `.41`, a ten-minute
display sleep on `.31`, and `autorestart 0` on all four nodes.

For dedicated, continuously running render nodes, run these commands once in
Terminal on **each** fleet Mac. They require an administrator password and are
intentionally not executed by the controller:

```bash
sudo pmset repeat cancel
sudo pmset -a sleep 0 displaysleep 0 autorestart 1
pmset -g custom
pmset -g sched
```

The first command clears the repeating schedule (only `.11` had one in this
audit, but running it on all four makes the desired state explicit). The second
disables idle system/display sleep and enables automatic restart after a power
failure. The final two commands are read-only verification; their output should
show `sleep 0`, `displaysleep 0`, `autorestart 1`, and no repeating sleep or
shutdown event. Do not use `pmset schedule cancelall` merely to remove benign
one-time wake entries created by macOS; use it only if `pmset -g sched` reveals
an unwanted one-time **sleep** or **shutdown** event.

## Stateless regime control

The fleet controller does not save regime or geometry state to disk. It has no
state file to read, write, or replay. `start` and `restart` always establish
Kinship with visible geometry after the launched processes acknowledge the
baseline. Live chair and operator commands affect the running Godot processes
only; a later process launch begins from Kinship again.

This is intentional. A chair release cannot be acknowledged while Godot is
stopped, so replaying an older on-disk chair state could incorrectly restore an
extractive regime the next morning. The running Godot process keeps only the
volatile state needed to render its current scenes.

## Rollback

The deploy action performs an automatic fleet-consistent rollback if promotion
or checksum verification fails. After all four new trees verify, the temporary
predecessor trees are deleted as requested; there is no lingering on-machine
old version. To return to an earlier release after a successful deployment,
check out or extract that known release in the authoritative studio repository,
run `deploy --dry-run`, and deploy all four Macs together.

## First-six per-river regime pilot

The running Godot processes own the current volatile regime state, and the
operator may send commands from `.11` or `.51`. An active Godot stage intentionally ignores
number keys `1` through `7`; run the controller console in a focused Terminal
window instead:

```bash
python3 fleet/godot_controller.py list
python3 fleet/godot_controller.py regime-clear
python3 fleet/godot_controller.py set --regime kinship
python3 fleet/godot_controller.py set --regime kinship --regime tech
python3 fleet/godot_controller.py set --regime watershed
python3 fleet/godot_controller.py regime-console
```

Geometry is always visible. The controller has no geometry-hiding option, and
every startup, chair, clear, console, and `set` packet explicitly establishes
visible geometry. Regime activation still determines which extractor and
floodplain shapes exist.

Inside `regime-console`, keys `1` through `6` toggle the first six regimes.
Key `7` cannot activate Watershed because doing so would bypass its one-shot AI
decision; use `set --regime watershed` instead. Key `7` may still remove an
already-active Watershed regime. Press `c` to clear the active set, and `q` or
Escape to leave the console. The console opens by sending Kinship with visible
geometry. Exiting leaves its last state active only until the Godot processes
are restarted.

An explicit transition into exclusive Watershed through
`set --regime watershed` is a single-command operation from the studio `.51`
Mac. Before changing the regime, the controller verifies that the local
`watershed_ai/.venv` runtime exists. It then obtains all four regime ACKs and
invokes exactly one OpenAI proposal using the currently displayed fleet phase.
Watershed is exclusive: a request or chair state that also contains other
regimes is normalized to Watershed alone. Each explicit `set --regime
watershed` is one new optimization request; UDP retries make no API call. Every
new proposal prints measured token usage and
its estimated USD cost.

The live preflight requires all seven updated stage capabilities and uses
Delta's 720-row phase as the reference. Other screens must be within two cyclic
rows or the model call is refused. If the API fails after activation, Watershed
remains active with its baseline appearance and the command exits nonzero; it
does not silently retry or spend another credit. A partial application records
an ignored local recovery decision that can be replayed without the API.

`start` and `restart` never purchase or replay a Watershed decision: every
launch begins in Kinship. A later explicit `set --regime watershed` performs
the one-shot optimization normally.

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
successful send. The acknowledgement also reports visible geometry by screen
ID. Stages apply routed control at a frame boundary, so the
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
  zero on all seven. Watershed's static profile remains a no-op; its one-shot,
  host-validated AI overlay supplies bounded per-screen visual settings only
  while exclusive Watershed is active.

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
identical set does not reroll it. Active fields are newly sized axis-aligned
rectangles touching alternating top/bottom screen edges. Eligible water curves
laterally into each bank-connected field, continues toward the bank, and drains offscreen before
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
