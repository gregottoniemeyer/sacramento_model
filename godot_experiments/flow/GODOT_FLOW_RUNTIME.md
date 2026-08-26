# Godot Flow Runtime

> **Production GPU update:** The seven selectable `scene_N.tscn` wrappers now
> instance `res://flow/gpu_stage/gpu_flow_stage_2d.tscn` directly. Production
> water, reservoirs, interactions, and salmon are GPU systems.
> See `res://flow/gpu_stage/README.md` for their deployed rendering details,
> controls, supported controller fields, tests, and bounded schemas. The CPU
> `FlowModel2D` described in much of this document is retained only as a
> reference/fallback; it is not the production renderer.

This document describes the first Godot milestone that replaces the seven
chevron/ring scenes with independent ports of the water-line simulation in
`ink_flow_lines_v04.py`.

The production GPU milestone includes immutable water trails, coherent noise,
addressable absorb/repel polygons, reservoirs, live gates, GPU salmon, GPU
leaves, a screen-fixed model grid and calendar, runtime
geometry replacement, measured water temperature integrated into every stage
title except Cottonwood Creek, an in-memory historical-regime switcher,
UDP control, and debug
drawing. The GPU stage implements both `release_salmon` and `release_leaves`.

## Architecture

### Deployed GPU renderer

`res://flow/gpu_stage/gpu_flow_stage_2d.tscn` is the shared production scene.
Its original seven-layer GPU water renderer runs once inside a transparent,
native 1920 x 1080 `WaterOnlyViewport`. The stage composites that viewport back
to the root with premultiplied alpha. The black background, model grid, cyan
reservoir guide, gold interaction polygons, temperature-bearing stage title,
model date, active-regime panel, salmon, and leaves are kept outside that
viewport, so the water texture contains only water and no visual
feedback.

The presentation stack uses absolute canvas Z values: `Background` is `-100`,
the stage-owned `BackgroundGrid` `Node2D` is `-75`, and `StageTitleLayer` is
`-50`; water, salmon, and leaves are `0` or higher. `StageTitleLayer` owns the
temperature-bearing river title, model date, and optional active-regime panel;
there is no separate temperature node. None of it is part of the debug overlay,
so `V` does not
hide it.

Salmon and leaves sample this water texture's alpha directly in their
particle-process shaders. No frame is copied to an `Image`, no CPU occupancy
mask is generated, and no GPU particle state is read back. Salmon use a fixed
240 x 24 native-pixel contact field for both contact and full 2D upstream
steering. Free leaves use a 120-pixel 2D vicinity search before their
12-pixel-radius latch test; a bounded miss freezes and fades. Latched leaves use
periodically resampled, cached-local-heading probes with multi-radius
center/flank support. Leaves render as head-only antialiased disks and have no
segment pool or motion trail.

Absorb/repel definitions are configuration data packed into one fixed 128 x 1
`RGBAF` texture. The GPU water-head process shader reads it and owns all live
positions; the CanvasItem shaders only draw immutable completed segments.

### Retained CPU reference

`res://flow/flow_model_2d.tscn` is the shared scene used by all seven display
scenes in the retained CPU reference implementation. It contains one
`FlowModel2D` and the shared
`res://flow/default_flow_profile.tres` preset. At startup, each model deeply
duplicates the profile and every nested geometry resource. Runtime changes in
one screen therefore do not mutate the preset or any other screen.

The seven `scene_N.tscn` files are thin `Node2D` wrappers. Each retains
`stage_scene.gd` for Escape-to-selector behavior and contains one independent
instance of the shared flow scene. The former chevron shaders, disk rings,
`Governator`, `SpeedSynth`, and speed-controlled `ColorRect` nodes are not in
these seven scenes anymore.

### Two-display launcher and host

`startup_selector.tscn` provides Display A and Display B river choices. The two
selections must be different. Launching them creates `dual_stage_host.tscn` as
the one `SceneTree.current_scene`, so `FlowControlBus`, `ModelTimeline`, and
`ModelRegimes` remain single process-wide authorities.

When `DisplayServer.get_screen_count()` is at least two, stage A is a direct
child of the root `Window`; stage B is a child of a native, non-transient second
`Window`. The host selects the root/current monitor and the first distinct
monitor, then positions each borderless `MODE_WINDOWED` output using the
reported screen position and size. Both windows use a 1920 x 1080 logical
canvas, `CANVAS_ITEMS` scaling, and preserved aspect ratio. This avoids the
macOS Spaces behavior of native fullscreen while still covering each display.

On a one-monitor machine, both selected stages remain independent but render
into two 1920 x 1080 `SubViewport` instances shown side by side. Clicking a
preview selects which stage receives local keyboard controls. Keyboard `V` is
retained for compatibility, but geometry remains visible on every active stage.
Running previews do not consume
`1`–`7`; the Governator controller owns regime test input. The timeline and
controller remain common. Escape or either native close request returns the
whole host to the selector. The selector also retains a Display-A-only button
and direct number-key launch for maintenance.

`FlowModel2D` runs from `_physics_process`, but it uses a custom flow solver
rather than rigid-body collision responses. The soft influence fields,
reservoir circulation, absorption, and trail lifecycles need deterministic
simulation rules that do not map cleanly to `RigidBody2D` contacts. Water is
rendered with pooled `Line2D` trails.

The default numerical schedule is:

- 30 fixed simulation frames per second (`target_fps = 30`)
- 20 midpoint RK2 substeps per simulation frame
  (`simulation_substeps = 20`)
- nominally 600 RK2 substeps per simulated second
- a maximum of eight accumulated simulation frames processed in one Godot
  physics callback, enough for the 240 Hz parameter ceiling on the project's
  60 Hz physics clock while preventing an unbounded catch-up loop

Both timing values are live parameters. The values above are the default
profile and the intended parity baseline with the Python version.

The model scene also has four inspector-level exports that are not
`FlowProfile` runtime parameters: `screen_id`, `preset`, `auto_start`, and
`accept_keyboard_input`. Screen wrappers set `screen_id`; the shared scene sets
`preset`; `pause`/`resume` control running state after startup; and keyboard
input can be disabled per installation instance with `accept_keyboard_input`.

`FlowControlBus` is an autoload-compatible `Node`. It listens for UDP JSON,
normalizes messages, and routes a deep copy to each matching node in the
`flow_models` group through:

```gdscript
func queue_control_message(message: Dictionary) -> void
```

Messages enter a model-owned queue and are applied on a fixed simulation-frame
boundary, not in the middle of an RK2 substep.

The production project also installs `ModelTimeline` as an autoload. It is the
single calendar authority for every production GPU stage in one Godot process.
Unlike a stage node, an autoload survives `change_scene_to_file()`, so the clock
continues across Escape-to-selector navigation and subsequent river selection.
GPU stages retain synchronized calendar fields only to drive their own label,
watershed interpolation, signals, and runtime summary; they do not advance a
second private clock.

`ModelRegimes` is another production autoload and is the process-wide authority
for historical-regime state. Its fixed order is Kinship, Agriculture, Gold
Rush, Water Projects, Hydropower, Tech, and Watershed. Agriculture retains the
stable internal ID `ranch`; `regimes.agriculture` is the preferred UI alias and
`regimes.ranch` remains compatible. It starts with no active
regimes, allows any combination to be active simultaneously, and survives
`change_scene_to_file()` and selector navigation. As with `ModelTimeline`, this
persistence ends at the process boundary; a multi-process installation must
send the authoritative active set to every process. `FlowControlBus` applies
regime paths to this autoload before routing the remaining packet to stages, so
a packet received on the selector or during startup is retained for every stage
that loads afterward and is not applied once per window in a dual-stage process.

### First-six per-river regime profiles

`ModelRegimes` loads the comma-delimited master table at
`res://regime_feature_profiles.txt` by header name. The first six master rows
link through `river_profile_path` to exact seven-screen tables at
`res://flow/data/regimes/kinship.txt`, `ranch.txt` (Agriculture),
`gold_rush.txt`, `water_projects.txt`, `hydropower.txt`, and `tech.txt`.
`profile_status` is descriptive metadata and never suppresses populated data.
The master and linked tables use schema version `2`. The former supplemental
source columns are absent. Ordinary water still enters through the fixed left
river inlet; that lifecycle boundary is not a regime feature. The available
range is full-height, while the active source band is centered and flow-scaled.

A populated river cell overrides its master value. A blank river cell inherits
a populated master value; if both are blank, the feature is undefined. An
explicit numeric `0` is defined and participates in blending. For every screen
and feature, active defined contributors are combined with an equal mean.
Undefined active regimes are excluded from that feature's denominator. With no
defined contributor, an opted-in GPU stage preserves its authored baseline
instead of applying a zero override. All seven production scene wrappers now
opt in; the active-regime panel remains Delta-only presentation.

Screen abbreviations below are S = Lake Shasta, Mc = McCloud/Pit, C =
Cottonwood Creek, Mi = Mill Creek, F = Feather River, A = American River, and
D = Delta. `R`, `Dr`, `Ob`, and `Sh` mean reservoir area, drain area, obstacle
area, and shoreline randomness; `c` is desired reservoir count and `p` is
interaction power.

| Regime | Current per-river matrix and schedule |
|---|---|
| Kinship | All: `R 0/c0`, `Dr 0/p0`, `Ob 0/p0`, `Sh 1`; salmon `11/01–01/31` daily, leaves `10/01–10/31` every 2 days. |
| Agriculture (`ranch`) | `R .20/c1` S/Mi/F/A, `.20/c2` Mc/D, `0/c0` C; `Dr .75` and `Ob .10` all; `Sh .30` S/Mc/C, `0` elsewhere. Positive-area gates open `06/01–08/31`; aperture blank. |
| Gold Rush | F/A/D only: `R .10` with count blank, `Dr .30/p1`, `Ob .30/p1`, `Sh 1`, and the Kinship salmon/leaf seasons. S/Mc/C/Mi are blank. |
| Water Projects | S/Mc/F/A/D: `R .33/c1`, `Dr .50`; C/Mi: explicit `R 0/c0`, `Dr 0`; five of seven whole-river stages is the nearest discrete allocation to 75%; all: `Sh 0`, leaves `0`; no gate schedule. |
| Hydropower | S/Mc/Mi/F/A/D: `R .50/c2`, aperture `.33`, open `01/01–12/31`; C: `R 0/c0`, no gate. `Dr .25` all; `Sh .20` Mc/C and `0` elsewhere. |
| Tech | All: `R .75/c2`, `Dr .75/p1`, `Sh 0`; gate, obstacle, salmon, and leaf fields blank. |
| Watershed | The authored profile remains a no-op until a valid `watershed-ai/2` seasonal allocation is applied. Selecting Watershed clears every other regime. |

Area fractions are deterministic admission/encounter budgets, not literal
geometry or guaranteed screen-area coverage. A positive drain or obstacle
weight also chooses a count from its bounded resident bank with
`ceil(weight * capacity)`: five drains and two obstacles.
Agriculture's `.75` drain weight therefore activates four field/drain polygons,
while its `.10` obstacle weight activates one obstacle. A feature-wide stable
selector applies each budget once across the complete bank; four drains do not
independently compound the `.75` encounter budget. Drain and obstacle `power`
independently set response strength for admitted encounters. A defined zero
activates no bank slots. An undefined feature preserves one authored fallback
slot and its authored budget.

The seven resident interaction resources—five drains and two obstacles—fit in
the eight-record interaction texture and leave one controller slot. This bank is
allocated once during startup. Regime changes enable, disable, and reshape or
translate those resources without allocating another node, resource, particle
pool, or texture.

Every real change to the absolute active set advances a layout generation. The
seed combines `screen_id`, sorted physical contributors, feature kind, slot
index, and generation. Active drain lanes and obstacle positions are therefore
fresh on every real transition, including `Tech -> Agriculture` and a later
`A -> B -> A`. Re-sending an identical absolute set is idempotent: it publishes
no change, advances no generation, and uploads no replacement geometry. Fields
remain stratified along X, alternate top/bottom bank assignment between adjacent
generations, and receive newly seeded widths, depths, and lane
positions. Obstacles retain their immutable captured shape and move to newly
seeded positions. An explicit zero activates no physics or debug guide.

Each active regime field is an axis-aligned rectangle touching exactly one top
or bottom screen edge. Eligible heads curve laterally toward the strongest
nearby river-facing edge, cross through that edge, continue through the field toward
the bank, and leave the screen. Offscreen recycling remains bounded and waits
for the immutable trail to fade; no field teleports water or adds particle
slots.

A defined zero reservoir area or count removes the reservoir constraint and
guide. When a live regime removes or relocates a reservoir, retained heads are
released into downstream flow and their already-recorded orbit trails fade over
the ordinary trail lifetime. Obstacles affect moving heads on the next step;
heads already committed to a field continue to its bank exit and recycle after
their immutable trail lifetime. No transition restarts the water particles. The
GPU stage has one physical `reservoir_main`;
`reservoir_count=2` remains desired-state data and does not produce a second
reservoir.

Gate scheduling is an area-weighted layer over the feature mean. Each active
profile with positive reservoir area and a complete schedule contributes its
area to the denominator and its currently open area to the numerator. That open
fraction multiplies the effective aperture, which is the equal mean of defined
aperture contributors or the authored aperture if none is defined. Therefore,
on a non-Cottonwood screen with Agriculture and Hydropower active, the aperture
is `.33` during June–August and `.33 * .50 / (.50 + .20)` otherwise.
Agriculture alone uses the authored aperture in season and closes it outside
the season; Hydropower alone uses `.33` year-round. The authored/manual gate
state remains an outer enable.

The legacy `shoreline_randomness` field now maps directly to a lightweight
top/bottom edge-turbulence amount. Its normalized `0…1` value scales a
180-pixel band at each edge. Most of the band applies deterministic, zero-mean
cross-stream turbulence plus a smaller streamwise component; only the outermost
40 pixels apply inward confinement. At zero the complete effect is disabled;
at `1.0` it is at full strength. No production shoreline polygon, collision
chain, debug outline, or data texture is created, so the effect does not narrow
the river. Ordinary left-edge lifecycles use a centered subset of the available
`y = 28…1052` range: 1% begins around `y = 540`, and increasing water widens
the band equally upward and downward until 100% uses the complete range.
Existing immutable water history is never rewritten. The uniform
field is cheaper than the former shoreline force and swept-crossing passes.

### Regime-transition work and bounded state

Regime changes mutate each resident stage in place; they do not instantiate a
new stage or resize its particle pools. `ModelRegimes` treats an identical
absolute active set as a successful no-op, so controller retries can be
acknowledged without repeating stage feature, panel, ecology, or gate-schedule
application. Ecology and regime-driven gate schedules run when the model day or
active regime state changes, not once per render frame.

Every real `ModelRegimes` revision also increments the reservoir geometry
revision before the new regime center is applied. The shader releases any
reservoir-owned heads in place into downstream flow before they can respond to
the new-center reservoir physics. Already-recorded orbit trails stay at their
old positions and fade over the ordinary trail lifetime. Reservoir and bounded
feature-bank placement is evaluated only during initial stage hydration or a
real regime transition. Each real active-set change advances the layout
generation and gives resident drains and obstacles fresh positions; an identical
absolute set does neither. Placement is not recomputed or uploaded every frame.
The single physical reservoir capacity is unchanged even when the profile's
desired `reservoir_count` is `2`.

Edge turbulence is one bounded uniform calculation in the water-head shader. It
does not scan shoreline segments or perform swept-polygon collisions. Regime
changes upload only the current field parameters to the seven resident water
materials. Kinship's explicit zero drain and obstacle budgets also skip both
generic interaction-polygon passes while its full edge-turbulence field remains
active.

The salmon and leaf release systems each retain a fixed 300-slot circular control
pool. Releases overwrite old commands; they do not append particles, nodes,
materials, or textures. Salmon retains its fixed immutable-segment pool and
leaves retain one head pool with no segment pool. The focused smokes stress 2,000
salmon releases and 500 two-bank leaf releases while checking circular indices,
control dimensions, particle amounts, resident resource identities/RIDs, and
node/resource counts. These allocation invariants do not guarantee a specific
frame rate. Before deployment, soak a full 12-minute model year with regime and
ecology changes on the oldest target Mac, monitor frame pacing and memory, and
verify exactly one Godot PID on each dedicated renderer Mac.

### Production GPU interaction path

The deployed `GPUFlowStage2D` does not send its interaction geometry through a
CanvasItem material. It validates and packs as many as eight
`GPUFlowInteractionPolygon` resources, with at most 12 vertices each, into one
shared 128 x 1 `RGBAF` texture. All seven palette layers give that same texture
to the `gpu_flow_particle` process shader. The process shader alone changes head
positions; the head and segment draw shaders remain rendering-only and never
sample the geometry texture.

This fixed-size representation makes geometry edits inexpensive and keeps the
shader loop bounded. Production reserves seven resident records for its five
drain/field and two obstacle slots, leaving one record for controller geometry.
Only active resident slots are packed for a given regime. It is separate from
the CPU profile's circle, rectangle, shoreline, polygon-obstacle, and
rectangular-absorber collections.

Production edge turbulence consumes no interaction record and no configuration
texture. The legacy shoreline geometry diagnostic fields remain available for
compatibility but report zero/empty/unbound values.

Resident absorb records used as regime fields are generated as top- or
bottom-bank rectangles. Their suction field turns eligible heads toward the
river-facing edge, the swept crossing accepts only that edge, and the field
draining state carries accepted heads across the bank and offscreen. Freeform
controller absorbers retain their legacy upstream-facing swept-entry behavior.

## Screen IDs and stage presentation

Use these IDs in controller targets. They are installation-facing identifiers
and should remain stable even if scene files or display labels are renamed.

| Scene | Stage title | `screen_id` |
|---|---|---|
| `scene_1.tscn` | Lake Shasta | `mount_shasta` |
| `scene_2.tscn` | McCloud-Pit Rivers | `mccloud_pit` |
| `scene_3.tscn` | Cottonwood Creek | `cottonwood_creek` |
| `scene_4.tscn` | Mill Creek | `mill_creek` |
| `scene_5.tscn` | Feather River | `feather_river` |
| `scene_6.tscn` | American River | `american_river` |
| `scene_7.tscn` | Delta | `delta` |

Every production wrapper sets its base title explicitly on
`GPUFlowStage2D`. The stage renders `StageTitle` bottom-to-top at `-90`
degrees, centered on native point `(60, 540)` in `#4AB0E1`, using the bundled
`res://flow/assets/fonts/BarlowCondensed-Medium.ttf` at 60 pixels. The 48-pixel
model date uses the same font and color, centered on `(1860, 540)`. Title and
date share one `FontVariation` with OpenType `tnum` enabled, so changing
temperature and date digits use fixed-width tabular figures. These are the
physical top and bottom centerlines after the displays are mounted vertically.
The font is part of the project rather than resolved from the host operating
system.

Every production stage except Cottonwood Creek appends its measured value to
the title, for example `Delta (20.5 °C)`. A configured but unavailable or
invalid series uses the explicit in-title fallback `Delta (— °C)`. Turning
`stage_temperature_visible` off removes the suffix and restores `Delta`.
No `StageTitleLayer/WaterTemperature` node is created; temperature lives in
`StageTitleLayer/StageTitle`, which is re-centered only when its one-decimal
display text changes.

Only `scene_7.tscn`, the Delta screen, enables the
active-regime panel. It is a child of `StageTitleLayer`, reads at `-90`
degrees, and uses the same Barlow Condensed Medium font and `#4AB0E1` color.
The Delta wrapper hides the optional `Regime` heading, leaving only the seven
60-pixel names at their existing positions beginning on X `1420` with 72-pixel
centerline spacing. They follow the historical order—Kinship,
Agriculture, Gold Rush, Water Project, Hydropower, Tech, AI Watershed—with a
72-pixel column interval. Active names are opaque; inactive names remain
visible at `0.25` alpha.
`Water Project` and `AI Watershed` are Delta-only presentation labels; their
stable internal regime names and IDs remain `Water Projects`/`water_projects`
and `Watershed`/`watershed`.
The panel listens to the shared `ModelRegimes` authority, so a received
absolute-state packet immediately highlights Kinship or any other active name,
including state received before the Delta stage was loaded.

The background grid defaults to 1-native-pixel `#4AB0E1` lines at `0.25` alpha,
spaced every 120 pixels. The spacing is also the production conversion from one
world unit to native pixels, so the grid directly describes the 16 x 9 model
coordinate system. The first and last boundary lines are omitted on both axes,
so the grid does not form a frame around the screen. The explicit background is
at absolute Z `-100`, the grid is at `-75`, the Delta tide profile is at `-60`,
the temperature-bearing title, date, and regime panel are at `-50`, and
water/ecology are at `0` or higher.
Active features can therefore pass visibly over both the grid and text. The grid
and text remain outside `WaterOnlyViewport`, so their alpha never counts as
water, and outside `ReservoirAndStatusOverlay`, so the `V` debug toggle does not
affect them.

`ModelDate` displays a zero-padded `MM/DD-HH:MM` from a 365-day, non-leap
calendar. Every production wrapper sets `model_start_day_index = 181`, so its
cycle begins at `07/01-00:00`, runs through June 30, and wraps to July 1. The
shared internal clock defaults to one model year in 720 running seconds, or
21,600 rendered frames at the production 30 FPS cap. Time is derived from the
continuous year fraction rather than accumulated integer frame counts. When
auto-advance is enabled and the global timeline is not paused, it keeps running
while the selector is visible; switching scenes does not snap it back.

On creation, a production stage loads its river data and optional temperature
series, then immediately consumes the current `ModelTimeline` snapshot before
building its water particles. Its date label, watershed row, interpolated water
rate and temperature, and runtime summary all start at the shared instant
rather than row zero. Multiple stages in the same process share that instant
exactly. Calling `set_paused()` or pressing Space on
any one of them changes the process-global pause state, so all active stages and
the calendar pause or resume together. Pause does not change the independent
auto-advance setting.

Each wrapper also loads one 720-row watershed file from
`res://flow/data/water_pipeline/`. At the default year duration, each row spans
one running second and a uniform 730 model minutes (12 hours 10 minutes). Since
the text files contain no timestamps, the displayed `HH:MM` is synthetic uniform
model time, not an observed timestamp. The atmospheric input rate is a
per-update linear interpolation between adjacent `norm` rows, including the
last-to-first wrap. `norm` maps directly from `0.0…1.0` to the single basin
input. Active regimes contribute explicit extraction fractions, capped at 100
percent. The one modeled output is:

`Delta remainder = basin input × (1 − total extraction fraction)`

The modeled input uses hydrologic memory before this equation. A trailing,
cyclic 30-day running average spans 59 of the 720 annual samples. The runtime
then redistributes the existing daily-average fog component into the morning
pulse and applies a 2% minimum to the combined data-driven input. This prevents
normal dry-weather precipitation gaps from depicting a dry river while keeping
the raw and interpolated atmospheric series available for inspection.

`flow_rate` remains the controller-compatible name for that post-extraction
remainder. The raw and scaled columns never multiply the normalized input.

On the Delta, Kinship floods the central floodplain using borderless 45-degree
blue hatching with 3-pixel round-capped lines, 6-pixel gaps, fixed 33% alpha,
and a 6-pixel label knockout. Every regime shows incoming Bay tide water as a
right-anchored area. Tide height and velocity come from
`res://flow/data/tide/sf_bay_9414290_tide_hourly_2025_2026.txt`: all 8,760 NOAA
CO-OPS hourly predictions for San Francisco station `9414290`, covering the
same half-open July 1, 2025–June 30, 2026 annual window. The wrapped FIFO window
shows exactly 96 hours, with 48 past hours above the centered current time and
48 future hours below it. Its polygon has a tide-shaped left boundary and a
41–306 pixel reach. White horizontal hatches fill the area at fixed 20% alpha;
they are 3 pixels wide with 6-pixel gaps. No solid fill, outline, label, or
arrowhead is drawn. The tide renders at Z=-60 below all text and advances with
the shared model-year timeline. Delta budget percentages use the Barlow
Condensed font's tabular-numeral OpenType feature. Active extractor and
city geometry is borderless 45-degree hatching with 3-pixel round-capped lines,
6-pixel gaps, and fixed 33% alpha, rendered below the water; every overlay
label is rotated -90 degrees. The internal physics name remains `obstacle` for
protocol compatibility, but the visible term is City. The Delta budget legend
has no background fill. Geometry labels use transparent hatch knockouts, with
every hatch segment stopping six pixels before the measured text bounds.
During exclusive Watershed, the extraction percentage is derived directly
from the applied agriculture, data-center, and city allocation fractions. If
no AI allocation has been applied, the panel displays an em dash instead of
the misleading authored-fallback value `0%`. The host maps each screen's own
available supply to a smooth 5%-to-50% extraction target, biases cooler water
toward data centers and warmer water toward fields, and resolves each screen
from its own observation and AI priorities.

The seven water-color head emitters keep native `amount_ratio = 1`, zero timing
randomness, and zero explosiveness. An exact global-slot selector distributes
the requested logical population over the full emission cycle, and deterministic
per-layer offsets interleave colors. After its prior two-second immutable tail
fades, each head resets directly to the inlet instead of waiting for another
native cycle. This eliminates low-flow packets and blank intervals without
changing downstream trail or interaction physics. Runtime diagnostics include
`head_emission_timing`, `head_native_amount_ratio_strategy`,
`head_reentry_waits_for_native_cycle`, `active_particle_count_uniforms`,
`water_coverage_fraction_uniforms`, `water_coverage_model`, and
`water_inlet_band_y_range_pixels`.

`set_model_date_time()`, the compatibility name `set_model_date_mm_dd()`,
`calendar.date`, and `stage.date` accept canonical `MM/DD-HH:MM`, validate it,
align the watershed timeline, and disable auto-advance. Date-only `MM/DD` input
is retained and means midnight; output is always `MM/DD-HH:MM`. Invalid input
does not change state. These operations update the process-wide authority even
when routed through one river, so every active or subsequently loaded stage sees
the same manual date. `calendar.auto_advance = true` globally resumes from the
displayed time. None of these paths changes controller routing; continue to
target the stable `screen_id`.

The full `reset` action returns the shared timeline to `07/01-00:00` and
restarts water and ecology on each addressed stage while preserving global
pause/auto-advance modes. A reset addressed to one river therefore changes the
calendar for every river but restarts only that river's particles; target `*`
for an installation-wide visual reset. `reset_model_calendar()` resets only the
global calendar/data position. Direct
`set_flow_rate()`, water-rate digit shortcut (`0`, `8`, or `9`), `flow_rate`,
or `active_ratio` input disables data
driving as a deliberate manual override; set `watershed.drives_flow_rate` to
`true` to resume at the current interpolated row.

`ModelTimeline` is process-global, not machine- or network-global. Two stages
hosted by one Godot process stay synchronized automatically. Separate Godot
executables or computers have separate authorities and can drift, so the future
Governator must distribute an authoritative date/phase and periodically resync
every display process when cross-process phase lock is required.

The production scene-to-data assignments are:

| Scene | Display | Watershed data | Temperature series |
|---|---|---|---|
| `scene_1.tscn` | Lake Shasta | `shasta_720.txt` | `shasta_keswick_release_temp_c` |
| `scene_2.tscn` | McCloud-Pit Rivers | `mccloud_720.txt` | `mccloud_above_shasta_lake_temp_c` |
| `scene_3.tscn` | Cottonwood Creek | `cottonwood_720.txt` | none |
| `scene_4.tscn` | Mill Creek | `mill_creek_720.txt` | `mill_creek_temp_c` |
| `scene_5.tscn` | Feather River | `feather_720.txt` | `feather_below_thermalito_temp_c` |
| `scene_6.tscn` | American River | `american_720.txt` | `american_fair_oaks_temp_c` |
| `scene_7.tscn` | Delta | `delta_720.txt` | `delta_freeport_temp_c` |

The combined McCloud-Pit display uses the McCloud station proxy. All seven
signals cover July 1, 2025 through June 30, 2026 and contain exactly 720
uniform samples derived from NOAA precipitation, temperature, snowfall, and
snow-depth records. The Delta is a documented weighted basin aggregate plus
local Stockton precipitation. Snowmelt, humidity/dew input, travel delay, gap
handling, normalization, and the speculative Delta weights are reproduced in
`flow/data/basin_input/basin_input_2025_2026.ipynb` and
`flow/data/basin_input/build_basin_input_720.py`. The second-column
`input_mm_day` is exposed through the retained unit-neutral `raw_value` key.

All configured stages share the comma-delimited project resource
`res://flow/data/water_pipeline/water_temperature_all_rivers_720.txt`.
Cottonwood Creek intentionally leaves temperature unconfigured. The shared
table contains 720 evenly spaced, half-open Pacific-time rows across the
July-to-June model year, with Celsius columns selected exactly as shown above.

At runtime each stage performs continuous linear interpolation between adjacent
rows using the shared annual `ModelTimeline`. Thus every displayed
temperature suffix and date remain phase-aligned; no regime or flow value is
used to estimate missing temperature. The mapping is half-open and cyclic, so
row 719 interpolates toward row 0 at the annual wrap; the runtime names this
mode `HALF_OPEN_ANNUAL_LINEAR_WRAP`. The loader requires exactly 720 numeric
rows with contiguous frame IDs `0…719` and also accepts tab-delimited pipeline
exports. A missing file, absent selected column, malformed row, or non-finite
result produces the `(— °C)` title fallback rather than a fabricated number.

This milestone is text-only. Temperature does not alter the black background,
water-trail palette or luminance, flow physics, salmon, leaves, or any regime
feature. A future water-only tint can be evaluated separately without changing
the measured numeric title suffix or using color as the sole temperature
encoding.

## Coordinate system

All simulation and controller geometry uses the Python-compatible, Y-up world:

- default size: `16 × 9`
- origin: lower-left
- positive X: left to right, the required base-flow direction
- positive Y: bottom to top
- visible bounds: X `0…16`, Y `0…9`

Godot canvas coordinates remain Y-down. `FlowModel2D.world_to_canvas()` flips Y
only at the drawing boundary, and `canvas_to_world()` performs the inverse.
Do not pre-flip geometry sent by a controller.

The production GPU stage uses the same controller world and converts it to its
native 1920 x 1080 canvas as `(x * 120, (9 - y) * 120)`. Send one Y-up geometry
definition to either runtime; do not send native pixels to the GPU stage.

Points in JSON are normally two-number arrays:

```json
[6.5, 2.25]
```

Vector parameters also accept `{"x": 6.5, "y": 2.25}` locally. For UDP JSON,
the two-number array form is the clearest convention.

Shorelines are closed land polygons. For the current Y-up winding convention,
the visible water-facing chain normally runs right-to-left for a bottom shore
and left-to-right for a top shore. `water_edge_indices` are zero-based and must
be forward-adjacent in polygon order; wrapping from the last vertex to index 0
is allowed.

## Typed resources

The runtime configuration uses typed Godot resources:

| Class | File | Role |
|---|---|---|
| `FlowProfile` | `flow_profile.gd` | Scalar parameters and typed geometry collections |
| `FlowCircleObstacle` | `flow_circle_obstacle.gd` | Circular deflection field |
| `FlowRectangleObstacle` | `flow_rectangle_obstacle.gd` | Rotated rectangular deflection field |
| `FlowPolygonObstacle` | `flow_polygon_obstacle.gd` | Irregular closed obstacle |
| `FlowShoreline` | `flow_shoreline.gd` | Closed land polygon plus water-edge chain |
| `FlowAbsorber` | `flow_absorber.gd` | Rectangular partial line absorber |
| `FlowReservoir` | `flow_reservoir.gd` | Circular capture pool and downstream gate |
| `GPUFlowInteractionPolygon` | `gpu_stage/gpu_flow_interaction_polygon.gd` | Unified bounded GPU absorb/repel polygon |

The default preset contains these stable geometry IDs:

- rectangle: `rectangle_main`
- shorelines: `shore_bottom`, `shore_top`
- absorbers: `absorber_0_5` through `absorber_8_5`
- reservoir: `reservoir_main`

The default circle and polygon collections are empty.

Separately, a production GPU stage whose `interaction_polygons` array is empty
installs two examples when `install_default_interaction_examples` is enabled:

- `absorber_test`: absorb mode, 50% absorption, `wave_strength = 0.18`, and
  `influence = 0.35`
- `repeller_test`: repel mode, `repellent_force = 0.70`, and
  `influence = 0.80`

Supplying any GPU interaction polygon suppresses both examples.

Every geometry element needs a nonempty stable ID. IDs must be unique within a
geometry kind. Controllers should keep IDs stable and update the element under
that ID. If an element is conceptually replaced, explicitly remove the old ID
and add the new one so state transitions are unambiguous.

## FlowProfile runtime parameters

Canonical parameter names are listed below. Use these names as keys in the
protocol's `changes` dictionary.

### World, timing, and pool

| Name | Type | Default | Notes |
|---|---|---:|---|
| `world_size` | Vector2 | `[16, 9]` | Both components must be positive. Rebuilds the pool. |
| `legacy_world_height` | float | `7.0` | Python-to-Godot speed scale reference. |
| `target_fps` | int | `30` | Valid range in the profile schema: 1–240. |
| `simulation_substeps` | int | `20` | RK2 substeps per simulation frame; schema range 1–200. |
| `max_particles` | int | `300` | Source-slot capacity. Rebuilds the pool. |
| `retention_capacity` | int | `100` | Extra reservoir-retention slots. Rebuilds the pool; may be zero only when no reservoirs exist. |
| `trail_length` | int | `1200` | Points retained per trail. Rebuilds the pool. |
| `particle_launch_delay_ms` | float | `10.0` | Delay between newly activated source lines. |
| `random_seed` | int | `-1` | `-1` randomizes; other values are deterministic. Rebuilds the pool. |

For display safety, source plus retention capacity may not exceed 1,500 water
slots, and `(max_particles + retention_capacity) × trail_length` may not
exceed 2,000,000 stored points. A patch above either memory budget is rejected
before the current model is changed.

### Water flow

| Name | Type | Default | Notes |
|---|---|---:|---|
| `flow_rate` | float | `0.5` | Normalized 0–1 line population and core speed. |
| `max_flow_speed` | float | `10.0` | Maximum world-speed scale. |
| `flow_variation` | float | `0.1` | Stable per-line variation; active values never fall below `min_active_flow`. |
| `min_active_flow` | float | `0.001` | Positive lower bound that prevents backward flow. |
| `base_flow` | Vector2 | `[2.5714285714, 0]` | X must remain positive in this X-axis model. |
| `noise_strength` | float | `0.7714285715` | Coherent curl-noise amplitude. |
| `noise_scale` | float | `1.1666666667` | Spatial noise scale; must be positive. |
| `noise_speed` | float | `0.75` | Temporal noise rate; may be signed. |
| `shore_exit_angle_jitter_degrees` | float | `16.0` | Stable per-line shoreline exit-angle range. |

### Particle separation

| Name | Type | Default |
|---|---|---:|
| `separation_radius` | float | `0.18` |
| `separation_strength` | float | `1.6071428571` |
| `separation_x_scale` | float | `0.15` |
| `separation_max_force` | float | `1.9285714286` |

`separation_x_scale` is normalized 0–1. The other separation values must be
nonnegative.

### Water rendering

| Name | Type | Default/format |
|---|---|---|
| `line_width_min` | float | `0.5` reference points |
| `line_width_max` | float | `3.0` reference points |
| `particle_alpha` | float | `1.0`, normalized 0–1 |
| `background_color` | Color | `#000000ff` |
| `line_colors` | color array | nonempty array of HTML colors |

`line_width_min` may not exceed `line_width_max`. Stroke values preserve the
Matplotlib reference's 120-DPI point units and are multiplied by `120 / 72`
when assigned to Godot canvas pixels. UDP colors should use HTML strings such
as `"#4ab0e1ff"`.

### Spawn, reservoir release, and gate controls

| Name | Type | Default | Notes |
|---|---|---:|---|
| `spawn_x` | float | `-0.0642857143` | Source begins just left of the visible world. |
| `spawn_y_margin` | float | `0.1928571429` | Margin inside the open inlet channel. |
| `reservoir_release_rate` | float | `2.0` | Global readiness accumulation rate. |
| `release_threshold_min` | float | `0.5` | Lower per-line release threshold. |
| `release_threshold_max` | float | `1.5` | Upper per-line release threshold. |
| `gate_width_step` | float | `0.0642857143` | Keyboard `[` / `]` adjustment step. |

The release threshold minimum must not exceed the maximum. Reservoir aperture
is `outlet_width / (2 × radius)`, so `outlet_width` is an absolute world width,
not a percentage.

### Debug drawing

| Name | Type | Default |
|---|---|---:|
| `debug_geometry_visible` | bool | `true` |
| `debug_geometry_color` | Color | `#ffa500ff` |
| `debug_geometry_line_width` | float | `1.5` reference points |

### Geometry collections

`FlowProfile` also owns these typed arrays:

- `circle_obstacles`
- `rectangle_obstacles`
- `polygon_obstacles`
- `shorelines`
- `absorbers`
- `reservoirs`

Do not replace these arrays through `changes`. Use `geometry_ops`, which parses
JSON dictionaries into typed resources and validates the entire candidate
configuration atomically.

The production GPU stage instead owns `interaction_polygons`, with a budget of
eight polygons containing three through 12 vertices each. Use the same
`geometry_ops` envelope to manage that array; do not add it to the CPU
`FlowProfile` collections.

### Reset-required fields

Changing any of these fields rebuilds the complete water pool immediately:

- `world_size`
- `max_particles`
- `retention_capacity`
- `trail_length`
- `random_seed`

A rebuild clears active lines, trails, absorber state, and retained reservoir
water. The controller does not need to send a second `reset` action; the model
performs the rebuild as part of committing that change. The explicit `reset`
action rebuilds the pool under the current configuration and reseeds the RNG.

All other scalar/profile changes are live. Lowering `flow_rate` lets excess
source trails finish naturally instead of deleting them immediately.

## UDP transport

The control bus reads these project settings:

- `flow_control/udp_port`, default `5005`
- `flow_control/bind_address`, default `0.0.0.0`

Binding to `0.0.0.0` permits localhost, broadcast, and explicit LAN targets.
The modern protocol name is `ink-flow/1`.

### Envelope

```json
{
  "protocol": "ink-flow/1",
  "revision": 1042,
  "target": "mount_shasta",
  "changes": {},
  "geometry_ops": [],
  "actions": [],
  "metadata": {}
}
```

- `revision` is optional. When omitted, `FlowControlBus` assigns a monotonically
  increasing modern-protocol revision. A supplied revision must be a
  nonnegative integer and should increase monotonically; a model ignores one
  less than or equal to the last modern revision it accepted. Legacy chair
  packets use a separate compatibility sequence and do not advance this
  modern revision guard.
- `target` is `"*"`, one string, or an array of strings. It defaults to `"*"`.
- `changes` is a dictionary of parameter/property paths to values.
- `geometry_ops` is an array of geometry operations.
- `actions` is an array of action names or action dictionaries.
- `metadata` is optional controller state retained in model snapshots.

Every accepted modern packet receives an `ink-flow/1-ack` UDP reply to its
source address and port. The reply echoes `metadata.request_id`, reports the
number and stable `screen_id` values of routed stage recipients, and includes
the accepted process-wide regime indices and revision. The Governator retries
unanswered or not-yet-ready startup packets and prints `APPLIED` only after every
configured process acknowledges the requested indices plus its exact configured
screen IDs and count.

### Watershed AI visual-control scope

Watershed AI uses a deliberately narrow extension of the modern envelope. It
controls only the Godot visualization; it is not connected to dams, gates,
pumps, diversions, field equipment, or any other real infrastructure. A sender
must address exactly one canonical production `screen_id`, and Watershed must
already be the only active regime (`regime_active_indices == [6]`). The bus and
the addressed GPU stage both enforce these conditions synchronously before any
state is queued or applied, and the named screen must resolve to exactly one
loaded GPU stage.

```json
{
  "protocol": "ink-flow/1",
  "control_scope": "watershed-ai/2",
  "target": "feather_river",
  "changes": {
    "watershed.ai.state": {
      "schema_version": 2,
      "decision_id": "decision-2026-08-21T12:00:00Z",
      "atmospheric_input_rate": 0.6,
      "reservoir_release_rate": 0.1,
      "available_supply_rate": 0.7,
      "extraction_fraction": 0.4,
      "remaining_rate": 0.42,
      "salmon_fraction": 0.35,
      "floodplain_fraction": 0.25,
      "agriculture_fraction": 0.15,
      "data_center_fraction": 0.15,
      "city_fraction": 0.1,
      "reservoir_storage_fraction": 0.5,
      "hydropower_fraction": 0.0,
      "water_project_fraction": 0.0
    }
  },
  "geometry_ops": [],
  "actions": [],
  "metadata": {
    "source": "watershed-ai",
    "request_id": "decision-2026-08-21T12:00:00Z"
  }
}
```

The scoped envelope permits only `protocol`, optional `revision`,
`control_scope`, `target`, `changes`, `geometry_ops`, `actions`, and `metadata`.
It requires exactly one change named `watershed.ai.state`, empty `actions` and
`geometry_ops`, and a nonempty `metadata.request_id` of at most 128 characters.
The target must be one string from the canonical seven-screen list; wildcard,
array, group, node-name, and node-path targeting are rejected for this scope.

The state dictionary must contain exactly the fifteen fields shown above.
`schema_version` is the integer `2`; `decision_id` is a nonempty string of at
most 128 characters; every other state value is numeric, finite, and within
`0..1`. Shares, extraction, available supply, and remaining water must close
the deterministic budget, extraction cannot exceed 50%, and both legacy
power/project fractions must be zero.
Unknown, missing, non-finite, or out-of-range values reject the complete state,
so no partial visual update is possible.

Godot computes `applied_state_hash` over the visual values only; `decision_id`
is intentionally excluded. The sender must reproduce this exact UTF-8 payload,
joined with `\n` and with no trailing newline, and take its lowercase SHA-256
hex digest:

```text
schema_version=%d
atmospheric_input_rate=%.9f
reservoir_release_rate=%.9f
available_supply_rate=%.9f
extraction_fraction=%.9f
remaining_rate=%.9f
salmon_fraction=%.9f
floodplain_fraction=%.9f
agriculture_fraction=%.9f
data_center_fraction=%.9f
city_fraction=%.9f
reservoir_storage_fraction=%.9f
hydropower_fraction=%.9f
water_project_fraction=%.9f
```

The fixed-decimal lines use exactly nine digits after the decimal point. A
replayed `decision_id` with the same hash is an idempotent no-op. Reusing that
ID with different visual values is rejected. A new ID with the same state hash
updates the acknowledged ID without repeating GPU or geometry work.

Because delivery to the stage is frame-queued, the immediate ACK may still
describe the previously applied state. The sender converges by retrying the
same absolute packet until all of these are true:

- `accepted` is `true` and `control_scope` is `watershed-ai/2`;
- `regime_active_indices` is exactly `[6]`;
- `recipient_screen_ids` contains the one requested screen; and
- `recipient_watershed_ai_state[screen].applied_decision_id` and
  `.applied_state_hash` equal the sent decision and locally computed hash.

That per-screen entry also returns `eligible`, `applied`, `applied_state`,
`last_error`, counters, `fixed_bank_only`, and `current_observation`. The
observation reports the current screen, model date/time, flow, watershed row,
temperature validity/value, authored and effective gate state/aperture, and
regime indices/revision for the sender's next decision.

The state overlays only the already resident reservoir, five-drain, and
two-obstacle banks plus existing shader parameters. It allocates no nodes,
resources, textures, pools, or new geometry. Leaving exclusive Watershed mode
clears the AI overlay and restores the stage's captured data-drive setting,
flow, authored gate value, and the newly active authored/profile/timeline
behavior.

For the CPU `FlowModel2D`, one message is atomic for `changes` and
`geometry_ops`: the model validates a duplicated candidate profile and rejects
the whole configuration update if any field or geometry operation is invalid.
Actions run after a valid update. The GPU stage instead validates and applies
accepted fields and operations in message order. Use one GPU `replace`
operation when a complete interaction set must change as one validated unit.

### Target routing

For installation control, use `"*"` or the stable screen IDs above:

```json
"target": "delta"
```

```json
"target": ["mount_shasta", "delta"]
```

The bus routes `"*"` to every node in `flow_models`. A string can match a
model's `screen_id`, node name/path, or an additional Godot group. Each
recipient receives its own deep copy of the message.

### Parameter and gate example

```json
{
  "protocol": "ink-flow/1",
  "revision": 1043,
  "target": ["mount_shasta", "mccloud_pit"],
  "changes": {
    "flow_rate": 0.72,
    "noise_strength": 0.95,
    "line_width_max": 4.0,
    "reservoir.reservoir_main.gate_open": true,
    "reservoir.reservoir_main.outlet_width": 0.7
  },
  "geometry_ops": [],
  "actions": []
}
```

Any mutable geometry field may be addressed as `<kind>.<id>.<field>`, using
canonical kinds `circle`, `rectangle`, `polygon`, `shoreline`, `absorber`, and
`reservoir`. Gate-width changes made through this path are clamped to
`0…2 × radius`. `element_id` itself is intentionally immutable; remove and
upsert an element when its identity must change.

On a production GPU target, `polygon.<id>.<field>` addresses a
`GPUFlowInteractionPolygon`, not the CPU `FlowPolygonObstacle`. Its mutable
fields are `mode`, `vertices`, `absorption_fraction`, `repellent_force`,
`wave_strength`, `influence`, and `enabled`. The GPU stage also accepts
`interaction`, `absorber`, `obstacle`, and `repeller` as geometry-kind aliases.
`absorption`, `repel`/`strength`, and `perturbation` are accepted field aliases
for `absorption_fraction`, `repellent_force`, and `wave_strength`, respectively.
All GPU kind aliases address one interaction array, so IDs must be unique across
absorb and repel modes. Canonical names are recommended for saved controller
regimes.

Production GPU presentation, regime, calendar, watershed, and temperature
paths are:

| Runtime path | Compatibility alias | Value/effect |
|---|---|---|
| `debug.geometry_visible` | `debug_visible` | Compatibility path; production geometry remains visible |
| `stage.title` | `stage_title` | River display text |
| `stage.title_visible` | `stage_title_visible` | Title visibility |
| `stage.regime_panel_visible` | `regime_panel_visible` | Active-regime panel visibility on this screen |
| `stage.grid_visible` | `stage_grid_visible` | Grid visibility |
| `stage.grid_spacing_pixels` | `stage_grid_spacing_pixels` | Native spacing, clamped to `1…960` |
| `stage.grid_line_width_pixels` | `stage_grid_line_width_pixels` | Native width, clamped to `0.1…8` |
| `stage.grid_color` | `stage_grid_color` | Grid color including alpha |
| `stage.date_visible` | `stage_date_visible` | `MM/DD-HH:MM` visibility |
| `stage.temperature_visible` or `temperature.visible` | `temperature_visible`, `stage_temperature_visible` | Append/remove the measured-temperature suffix in `StageTitle` |
| `temperature.data_path` or `stage.temperature_data_path` | `temperature_data_path` | Load the temperature table and align it to the current timeline |
| `temperature.data_column` or `stage.temperature_data_column` | `temperature_data_column` | Select a Celsius series by exact header name |
| `calendar.date` or `stage.date` | `model_date` | Set process-wide `MM/DD-HH:MM` (or date-only `MM/DD`); disables auto-advance |
| `calendar.day_index` | `model_day_index` | Set process-wide day `0…364`; disables auto-advance |
| `calendar.auto_advance` | `model_calendar_auto_advance` | Shared internal clock enabled/disabled |
| `calendar.year_duration_seconds` | `model_year_duration_seconds` | Shared year duration, clamped to `1…86400` seconds while preserving phase |
| `calendar.start_day_index` | `model_start_day_index` | Shared reset/start day `0…364`; setting it resets the calendar |
| `watershed.data_path` | `watershed_data_path` | Load a pipeline text file and align it to the current timeline |
| `watershed.drives_flow_rate` | `watershed_data_drives_flow_rate` | Enable/disable data control of water `flow_rate` |
| `watershed.interpolate_flow_rate` | `watershed_interpolate_flow_rate` | Lerp adjacent `norm` rows or hold each current row |
| `regimes.active_names` | `active_regimes` | Atomically replace the shared active set from names/IDs |
| `regimes.active_indices` | none | Atomically replace the shared set from zero-based indices `0…6` |
| `regimes.kinship` | none | Set Kinship active/inactive |
| `regimes.agriculture` | `regimes.ranch` | Set Agriculture active/inactive |
| `regimes.gold_rush` | none | Set Gold Rush active/inactive |
| `regimes.water_projects` | none | Set Water Projects active/inactive |
| `regimes.hydropower` | none | Set Hydropower active/inactive |
| `regimes.tech` | none | Set Tech active/inactive |
| `regimes.watershed` | none | Set Watershed active/inactive |
| `shoreline.randomness` | `shoreline_randomness`, `shorelines.randomness` | Direct per-stage top/bottom edge-turbulence override `0…1`; a later regime change reapplies the normalized shared value |

The fleet controller always sends visible geometry to every configured screen.
It exposes no geometry-hiding option. No controller state is saved; `start` and
`restart` restore Kinship with visible geometry.

The public `set_model_date_time(model_date_time)` method provides the same
validated external-time handoff as `calendar.date` and `stage.date`;
`set_model_date_mm_dd()` remains as a compatibility name. Canonical input and
output are zero-padded `MM/DD-HH:MM`; date-only `MM/DD` input means midnight.
Invalid input returns `false` without changing state.
`set_model_calendar_auto_advance(true)` globally resumes the shared clock from
the displayed time. `reset_model_calendar()` globally resets calendar/data
position only and does not reset water or ecology.
`get_current_watershed_data_row()` returns the addressed river's raw row plus
its interpolated flow at the shared synthetic model date-time.

The stage API exposes `toggle_regime(index)`, `set_regime_active(index,
active)`, `set_active_regime_names(names)`, and `get_regime_state()`. Indices
are zero-based. Code may also address `/root/ModelRegimes` directly through
`set_regime_active_by_id(id, active)`, `set_active_indices(indices)`,
`clear_regimes()`, and `snapshot()`. Replacement setters validate the complete
request before publishing it. The stage emits `regimes_changed` with its
`screen_id`, active names, active indices, and shared revision.

`ModelRegimes.snapshot()` additionally exposes `profile_path`,
`profiles_loaded`, `profile_count`, `profile_reload_revision`,
`profile_diagnostics`, the legacy master-level `effective_features`, and the
authoritative per-screen `effective_feature_state_by_screen` plus
`active_schedules_by_screen`. Each per-screen feature state reports
`defined`, `value`, `contributor_count`, and `contributor_ids`. The stage mirrors
these and publishes its resolved `regime_effective_feature_state`,
`regime_applied_feature_budgets`, `regime_applied_feature_overrides`,
`regime_feature_presence`, `regime_gate_open_fraction`,
`regime_reservoir_count_desired_raw`,
`regime_reservoir_count_rendered`, `regime_reservoir_renderer_capacity`,
`regime_geometry_mode`, `regime_layout_generation`,
`regime_layout_active_signature`, `regime_geometry_keys`,
`regime_geometry_update_count`, `regime_geometry_undefined_fallback`,
`regime_geometry_mixed_contributors`, and
`regime_geometry_preserves_particle_pools`. Feature-bank diagnostics are
`regime_feature_slot_capacities`, `regime_feature_slot_counts_desired`,
`regime_feature_slot_counts_rendered`, `regime_feature_slot_counts_resident`,
and `regime_feature_controller_spare_capacity`. Together they expose the
profile-derived counts, enabled regime-bank counts, the resident startup banks,
and the remaining one interaction controller slot. Bank-field diagnostics add
`regime_field_bank_layouts`, `regime_field_bank_counts`,
`field_turn_mode`,
`bank_field_suction_reach_pixels`, `bank_field_suction_crossflow_ratio`,
`bank_field_suction_streamwise_ratio`,
`bank_field_min_withdrawal_speed_pixels`, and
`bank_field_capture_depth_pixels` plus their seven-layer uniform mirrors.
The bank-only path aims through the mouth, snaps to a zero-streamwise
quarter-turn there, and preserves at least 540 pixels/second of withdrawal
speed until it leaves the screen. `regime_geometry_mode` reports
`GENERATION_SALTED_BOUNDED_SLOT_BANKS`. Reservoir diagnostics also expose
`reservoir_center_pixels`, `reservoir_center_pixels_authored`,
`reservoir_geometry_revision`, and `reservoir_geometry_revision_uniforms`.
These fields distinguish an undefined feature that preserves authored behavior
from an explicit-zero override. Shoreline diagnostics are
`shoreline_effect_mode`, `shoreline_randomness`, `shoreline_count`,
`shoreline_vertex_count`,
`shoreline_ids`, `shoreline_obstacles`, `shoreline_data_texture_bound`,
`shoreline_data_texture_size`, `shoreline_count_uniforms`,
`shoreline_texture_bound_uniforms`, `shoreline_inlet_y_range_pixels`,
`shoreline_inlet_y_range_uniforms`, `shoreline_overlay_count`, and
`shoreline_preserves_interaction_capacity`. `shoreline_effect_mode` reports
`EDGE_TURBULENCE`; the legacy geometry and texture fields report
zero/empty/unbound and the inlet reports its full range.
Edge-field diagnostics are `edge_turbulence_amount`,
`edge_turbulence_band_pixels`, `edge_turbulence_wall_band_pixels`,
`edge_turbulence_crossflow_ratio`, `edge_turbulence_streamwise_ratio`,
`edge_turbulence_inward_ratio`, `edge_turbulence_amount_uniforms`,
`edge_turbulence_band_uniforms`, `edge_turbulence_wall_band_uniforms`, and
`edge_turbulence_parameter_upload_count`.

Presentation paths do not alter `screen_id`, `model_id`, particle state, debug
visibility, or the water-only occupancy texture. Calendar paths update the
process-wide timeline and all active stages but do not rebuild particles or
retune ecology. Regime paths mutate `ModelRegimes`, so every active or later
stage sees the same set. The two list paths replace the whole active set; each
`regimes.<id>` boolean changes one toggle without clearing the others.
Watershed paths may change the addressed river's `flow_rate`.
Date
applications emit `model_date_changed(screen_id, date_mm_dd, day_of_year)`; the
date signal intentionally remains date-only. Row changes emit
`watershed_data_row_changed(screen_id, row_index, row_count, raw_value,
normalized_flow, scaled_flow, high_variation, model_date_time)`.

Salmon scalar paths on a production GPU target are `salmon.enabled`,
`salmon.per_release`, `salmon.min_speed_pixels`, `salmon.water_alpha_threshold`,
`salmon.contact_width_pixels`, `salmon.contact_height_pixels`,
`salmon.water_steering_strength`, `salmon.trail_length_pixels`,
`salmon.line_width_pixels`, `salmon.fade_seconds`, and `salmon.alpha`.
`salmon.occupancy_flip_y` is a default-false platform/debug fallback for a
vertically inverted viewport texture.

Leaf scalar paths on a production GPU target are `leaves.enabled`,
`leaves.per_side`, `leaves.release_stagger_interval_seconds`,
`leaves.free_speed_pixels`, `leaves.flow_speed_pixels`,
`leaves.speed_variation`, `leaves.velocity_response`,
`leaves.sway_amplitude_min_pixels`, `leaves.sway_amplitude_max_pixels`,
`leaves.sway_period_min_seconds`, `leaves.sway_period_max_seconds`,
`leaves.water_alpha_threshold`, `leaves.contact_radius_pixels`,
`leaves.free_water_search_radius_pixels`,
`leaves.free_water_steering_strength`,
`leaves.free_search_max_distance_pixels`, `leaves.stopped_fade_seconds`,
`leaves.follow_probe_min_pixels`, `leaves.follow_probe_max_pixels`,
`leaves.follow_turn_degrees`, `leaves.follow_resample_interval_seconds`,
`leaves.occupancy_flip_y`, `leaves.disk_radius_pixels`,
`leaves.radius_variation`, and `leaves.alpha`. `leaves.line_width_pixels`
remains a compatibility diameter control and `leaves.line_width_variation`
remains an alias for radius variation.

Canonical names are preferred, but the model currently accepts these scalar
aliases: `flow.rate`, `flow.max_speed`, `flow.variation`, `noise.strength`,
`noise.scale`, `noise.speed`, `separation.radius`, `separation.strength`, and
`debug.visible`.

### Geometry operation examples

Upsert one element. `add` and `update` are aliases of `upsert`:

```json
{
  "op": "upsert",
  "kind": "circle",
  "id": "island_west",
  "value": {
    "x": 5.2,
    "y": 4.0,
    "radius": 0.65,
    "strength": 5.0,
    "bend": 1.1
  }
}
```

Remove one element. `delete` is an alias of `remove`:

```json
{
  "op": "remove",
  "kind": "circle",
  "id": "island_west"
}
```

Replace an entire kind. Every value needs `id` or `element_id`:

```json
{
  "op": "replace",
  "kind": "absorber",
  "values": [
    {
      "id": "diversion_a",
      "x": 6.0,
      "y": 2.0,
      "width": 0.5,
      "height": 1.0,
      "absorption_fraction": 0.4,
      "stop_margin_fraction": 0.12
    }
  ]
}
```

A complete message can combine operations:

```json
{
  "protocol": "ink-flow/1",
  "revision": 1044,
  "target": "feather_river",
  "changes": {},
  "geometry_ops": [
    {
      "op": "upsert",
      "kind": "rectangle",
      "id": "weir_a",
      "value": {
        "x": 8.0,
        "y": 4.5,
        "width": 1.6,
        "height": 0.4,
        "angle_degrees": 12.0,
        "strength": 4.0,
        "bend": -0.8,
        "influence": 0.7
      }
    },
    {"op": "remove", "kind": "absorber", "id": "absorber_4_5"}
  ],
  "actions": []
}
```

Accepted kind aliases include singular/plural names, `circle_obstacle`,
`rectangle_obstacle`, `polygon_obstacle`, and `shore`.

#### Production GPU interaction operations

Use `polygon` as the canonical kind. An upsert can create an absorber or reshape
an existing polygon under the same stable ID:

```json
{
  "op": "upsert",
  "kind": "polygon",
  "id": "intake_west",
  "value": {
    "mode": "absorb",
    "vertices": [[4.2, 7.35], [5.3, 7.55], [5.1, 8.45], [4.1, 8.25]],
    "absorption_fraction": 0.5,
    "repellent_force": 0.0,
    "wave_strength": 0.18,
    "influence": 0.35,
    "enabled": true
  }
}
```

Remove one interaction with the same ID:

```json
{"op": "remove", "kind": "polygon", "id": "intake_west"}
```

Replace the complete GPU interaction set in one operation:

```json
{
  "op": "replace",
  "kind": "polygon",
  "values": [
    {
      "id": "intake_west",
      "mode": "absorb",
      "vertices": [[4.2, 7.35], [5.3, 7.55], [5.1, 8.45], [4.1, 8.25]],
      "absorption_fraction": 0.5,
      "wave_strength": 0.18,
      "influence": 0.35,
      "enabled": true
    },
    {
      "id": "weir_east",
      "mode": "repel",
      "vertices": [[7.4, 6.0], [8.4, 6.2], [8.2, 7.4], [7.3, 7.1]],
      "repellent_force": 0.7,
      "wave_strength": 0.0,
      "influence": 0.8,
      "enabled": true
    }
  ]
}
```

`add` and `update` alias `upsert`; `delete` aliases `remove`. Kind and operation
matching is case-insensitive, and plural interaction-kind aliases are accepted.
If an absorber or repeller alias omits `mode`, the GPU stage infers `absorb` for
`absorber` and `repel` for `obstacle`/`repeller`. Whole-set `replace` is accepted
only with the neutral `polygon`/`interaction` kinds, so it cannot unexpectedly
erase objects of the opposite mode. Every accepted change repacks the one
shared texture used by all seven palette layers.

## Geometry dictionary schemas

For `upsert`, the operation's `id` is authoritative; the `value` dictionary may
omit `element_id`. For `replace`, include `id` or `element_id` in every value.
All numeric fields must be finite.

### Circle

```json
{
  "element_id": "island_west",
  "x": 5.2,
  "y": 4.0,
  "radius": 0.65,
  "strength": 5.0,
  "bend": 1.1
}
```

`radius > 0`, `strength >= 0`; signed `bend` chooses steering direction.

### Rectangle

```json
{
  "element_id": "weir_a",
  "x": 8.0,
  "y": 4.5,
  "width": 1.6,
  "height": 0.4,
  "angle_degrees": 12.0,
  "strength": 4.0,
  "bend": -0.8,
  "influence": 0.7
}
```

`width` and `height` must be positive, `strength >= 0`, and `influence > 0`.
The angle is counterclockwise in the Y-up simulation world.

### Polygon

```json
{
  "element_id": "island_irregular",
  "vertices": [[5.0, 2.0], [6.3, 2.2], [6.0, 3.4], [4.8, 3.0]],
  "strength": 5.0,
  "bend": 1.0,
  "influence": 0.8
}
```

A polygon needs at least three vertices, nonzero area, and no self-intersection
or zero-length edge. `strength >= 0` and `influence > 0`.

### GPU interaction polygon

This is the unified production-GPU schema; it is not an additional CPU profile
collection:

```json
{
  "element_id": "intake_west",
  "vertices": [[4.2, 7.35], [5.3, 7.55], [5.1, 8.45], [4.1, 8.25]],
  "mode": "absorb",
  "absorption_fraction": 0.5,
  "repellent_force": 0.0,
  "wave_strength": 0.18,
  "influence": 0.35,
  "enabled": true
}
```

The ID must be nonempty. A polygon needs three through 12 finite vertices, no
zero-length edge, nonzero area, and no self-intersection.
`absorption_fraction`, `repellent_force`, and `wave_strength` are normalized
`0.0…1.0`; `influence >= 0`; and `mode` is `"absorb"` or `"repel"`. Across one
stage, at most eight valid enabled or disabled resources can be configured.

Regime-owned absorb polygons are bank-connected fields. The shader applies
lateral suction toward the strongest eligible river-facing mouth, accepts only
a swept crossing of that mouth, then carries the head through the field and
offscreen. Root and side edges are not intakes. The feature-wide cohort selector
prevents multiple active fields from multiplying the regime budget, and the
immutable trail records the visible turn without teleportation. Freeform
controller absorbers keep the legacy upstream-facing swept-entry rule; an
accepted head stops just inside the crossed edge until its tail fades.
`absorption_fraction = 0.0` accepts no heads and `1.0` accepts every qualifying
head.

Repel mode changes heads only. It applies a soft redirect across `influence` and
a swept boundary correction to prevent a fixed step from tunneling through the
polygon. `repellent_force = 0.0` contributes no redirect and `1.0` applies the
maximum configured response. Already emitted trail segments are immutable and
never evaluate either mode.

### Shoreline

```json
{
  "element_id": "shore_bottom",
  "vertices": [
    [-2.0, -2.0], [18.0, -2.0], [18.0, 0.0],
    [12.0, 0.7], [8.0, 2.1], [4.0, 3.5], [-2.0, 3.5]
  ],
  "water_edge_indices": [2, 3, 4, 5],
  "side": "bottom",
  "strength": 5.1428571429,
  "influence": 1.0928571429,
  "power": 2.0,
  "force_offset": 0.6428571429
}
```

The land polygon must be simple and closed implicitly. The water-edge chain
needs at least two valid, forward-adjacent, zero-based indices. `side` is
`"bottom"` or `"top"`; `strength >= 0`, `influence > 0`, `power > 0`, and
`force_offset >= 0`.

### Absorber

```json
{
  "element_id": "diversion_a",
  "x": 6.0,
  "y": 2.0,
  "width": 0.5,
  "height": 1.0,
  "absorption_fraction": 0.4,
  "stop_margin_fraction": 0.12
}
```

`width` and `height` must be positive. `absorption_fraction` is 0–1 and
`stop_margin_fraction` is 0–0.49.

Absorber selection and stopping depth are deterministic for a water-slot ID
and absorber stable ID. Reordering the absorber array therefore does not
change which lines an existing absorber selects.

### Reservoir

```json
{
  "element_id": "reservoir_main",
  "x": 11.5714285714,
  "y": 2.5714285714,
  "radius": 1.8642857143,
  "outlet_width": 0.7,
  "gate_open": true,
  "circulation": 2.0,
  "swirl_strength": 3.0857142857,
  "confinement_strength": 3.2,
  "wall_strength": 10.2857142857,
  "outlet_strength": 5.1428571429,
  "wall_influence": 0.2828571429,
  "orbit_radius_fraction": 0.62,
  "orbit_radius_spread": 0.52
}
```

`radius > 0`; `outlet_width` is 0 through the full diameter.
`swirl_strength`, `confinement_strength`, `wall_strength`, and
`outlet_strength` are nonnegative; `wall_influence > 0`;
`orbit_radius_fraction` is 0–1; and `orbit_radius_spread >= 0`. Circulation is
signed, so its sign may reverse the swirl direction.

### Reservoir removal policy

Removing a reservoir, or replacing the reservoir set without its stable ID,
immediately deactivates retained water assigned to that reservoir. It does not
teleport that stored water downstream and does not route it through a deleted
gate. Source lines and water associated with remaining reservoirs continue.

This policy prevents orphaned retained slots from circling an object that no
longer exists. To drain a reservoir visibly, first open/widen its gate and
allow it to release; remove it only after the desired drain period.

### Editing occupied geometry

A live center or radius change to a reservoir with the same stable ID remaps
water that is still inside the old reservoir into the new circle. The model
preserves each head's normalized local radius/angle and remaps the portion of
its trail inside the old pool. Water that already left the old gate continues
downstream and is not teleported by the edit. Release readiness and accumulated
gate progress remain intact.

Moving or resizing an absorber similarly remaps a trail currently assigned to
that absorber, its in-absorber history, and its normalized stopping depth.
Removing the absorber clears that assignment so a stopped head can resume.
These continuity rules depend on stable IDs. A removal committed in one
message, followed by an add in a later message, has removal semantics rather
than migration semantics. A remove and upsert of the same ID inside one atomic
message leaves that ID present in the final candidate and therefore preserves
continuity.

GPU interaction edits have a different, intentionally simple policy. New and
ordinary flowing heads use the repacked polygon texture on their next process
step, so a controller may move, reshape, enable, disable, or retune polygons at
runtime. Previously emitted segments never move. A head already accepted by an
absorber stays at its recorded stop position until its tail finishes fading and
the slot recycles, even if that polygon is subsequently moved or removed. This
prevents a live geometry edit from stretching or rewriting visible history.

### Production GPU reservoir slot occupancy

Unlike the retained CPU model's configurable `retention_capacity`, the
production GPU water system has no separate reservoir-retention pool. A
retained head continues to occupy one of the stage's fixed 1,000 active water-head
slots until it exits. A closed or high-capture reservoir can therefore
temporarily thin ordinary inlet lanes. If all active slots are retained, no new
ordinary inlet lifecycle can start until release and recycling free a slot.
This is bounded slot occupancy, not a memory leak or rendering failure.

At every ordinary lifecycle restart, the water shader mixes the slot's
lifecycle generation into its inlet-lane seed. A recycled slot can reappear in
a different Y lane and refill a band that was previously starved instead of
returning forever to the same lane. Lifecycle reseeding redistributes freed
slots; it cannot create capacity while slots remain retained.

## Production GPU salmon

`GPUSalmon2D` is a fixed 300-slot GPU system outside the water-only viewport.
The CPU writes only release generations, evenly distributed lane selectors, and
five palette indices into a small control texture. The shader searches the
right edge of the water-only texture for occupied lanes, moves accepted salmon
upstream, samples water contact, steers, latches water loss, and emits immutable
curved segments. It never reads particle state or the rendered water image back
to the CPU.

The default release contains 25 salmon. Their colors are `#FF5C8A`, `#FF7A72`,
`#FF8C42`, `#FFAD33`, and `#FFD23F`. Their default visible trail is 100 native
pixels long and 3 pixels wide. The centered contact rectangle is 240 pixels
wide by 24 pixels tall. `salmon.water_alpha_threshold` defaults to `0.001`, so
any meaningfully nontransparent pixel counts as water. The same fixed 9 x 13
sample field selects a complete 2D direction toward occupied samples behind the
fish. Its score strongly favors continuity with the current swim heading and
adds a smaller upstream bias; `salmon.water_steering_strength` controls how
strongly that direction changes the current velocity. If the right edge has no
suitable water when a release arrives, the invisible slot retries rather than
losing the command. No salmon runtime path or default changes with this 2D
steering update.

Water loss is a one-way decision for that release generation. The salmon
cannot be revived by later water contact. During its configured 0.5-second
fade, it continues in the last direction with exponential damping and emits a
rolling short trail whose alpha diminishes to zero. Existing immutable child
segments retain their own short spatial lifetime and age out normally, while
the newly emitted fading segments make the complete loss transition visible.

The salmon draw shader interpolates age along each segment's `UV.x` over one
30 Hz sample interval. Neighboring endpoints therefore receive the same alpha,
removing the fixed-alpha steps that were previously visible in faint tails.

Production GPU salmon paths and defaults are:

| Path | Default | Meaning |
|---|---:|---|
| `salmon.enabled` | `true` | Enables visible salmon/release handling |
| `salmon.per_release` | `25` | Default `S`/action batch |
| `salmon.min_speed_pixels` | `60` | Low-flow upstream-speed floor and trail-pool bound |
| `salmon.water_alpha_threshold` | `0.001` | Any meaningfully nontransparent water qualifies |
| `salmon.contact_width_pixels` | `240` | Full centered contact width |
| `salmon.contact_height_pixels` | `24` | Full centered contact height |
| `salmon.water_steering_strength` | `5.0` | Full 2D occupancy steering with heading continuity and upstream bias |
| `salmon.trail_length_pixels` | `100` | Spatial immutable-trail length |
| `salmon.line_width_pixels` | `3` | Trail width |
| `salmon.fade_seconds` | `0.5` | Latched no-water fade interval |
| `salmon.alpha` | `1.0` | Global salmon alpha |
| `salmon.occupancy_flip_y` | `false` | Platform/debug fallback for an inverted viewport texture |

Above 60 pixels/second, salmon follow the effective live water speed. The
minimum prevents a 100-pixel spatial trail from acquiring an unbounded lifetime
and segment-pool requirement as `flow_rate` approaches zero.

Leave `salmon.occupancy_flip_y` false unless a target renderer presents the
`ViewportTexture` vertically inverted. It changes only occupancy sampling; it
does not alter water or salmon rendering coordinates.

## Production GPU leaves

`GPULeaf2D` is a fixed 300-slot GPU system at absolute Z index `10`, outside the
water-only viewport. The CPU writes only release generations, scheduled delays,
independently shuffled stratified X-lane selectors, seven palette indices, and
top/bottom-origin codes into a fixed 300 x 2 control texture. Leaf position,
size, delay countdown, water contact, irreversible attachment, water-path
following, disk rendering, and stopped-fade opacity stay on the GPU. There is
one resident head pool and no leaf segment pool. Neither particle state nor the
rendered water image is read back.

Pressing `L`, calling `release_leaves()`, or sending a `release_leaves` action
schedules 15 leaves from the top edge and 15 from the bottom edge by default.
Each cohort retains one sample in every stratified lane across the complete X
axis. A separate deterministic shuffle per bank assigns those X lanes to launch
times, so X position and delay order are decoupled. The public API argument is a
per-side count from 1 through 150 and the return value is the total scheduled:

```gdscript
stage.release_leaves()       # 15 top + 15 bottom; returns 30
stage.release_leaves(20)     # 20 top + 20 bottom; returns 40
```

The default batch does not appear simultaneously. Its deterministic sequence
alternates top, bottom, top, bottom. `leaves.release_stagger_interval_seconds`
sets a `0.20`-second base gap, while a stable multiplier from `0.55` through
`1.45` makes successive gaps irregularly span `0.11…0.29` seconds. The default
15-plus-15 batch spans about `5.93` seconds, approximately twice its former
maximum delay. Lane order uses a separate stable mix from gap timing. All
absolute delays are written once with the release; the GPU scheduled state
counts them down without CPU timers or particle readback. Resetting and
replaying the same batch reproduces its cadence and lane shuffle.

Leaves are head-only filled disks. Their exact palette is `#8C3F0A`, `#A95412`,
`#C47A12`, `#C29A18`, `#8A8F2A`, `#4F772D`, and `#365F32`. The default base
diameter is 10 pixels, or a 5-pixel radius. A stable per-generation scale from
`1.0…2.0` produces diameters of 10…20 pixels, or radii of 5…10 pixels. The draw
shader gives each disk a soft antialiased radial edge; no motion segments or
trail pool are created. Before
water contact, each leaf searches while moving inward from its top or bottom
source edge at 120 pixels per second with 2–6 pixels of horizontal sway and a
stable random period from 1.2 through 2.8 seconds. A
17 x 17 grid samples the forward/inward portion of a 120-pixel-radius 2D
vicinity; samples back toward the originating bank are rejected. A detected
stream steers the leaf 35% toward the selected water direction while preserving
an inward component. If no water is touched within 256 pixels of inward travel,
the leaf enters `STOPPED_FADING`: its disk freezes, fades to transparent, and
retires after 0.5 seconds.

The contact disk has a 12-pixel radius and accepts water alpha at or above
`0.001`. Contact makes one position-preserving transition into the latched
water-following state at 300 pixels per second and initializes its cached
heading to +X. At a default `0.12`-second interval with a deterministic per-leaf
phase, a forward probe fan searches 8 through 56 pixels around that cached local
heading over a 35-degree half-angle. At multiple radii it combines center
samples with lower-weight flank samples before applying strong continuity and a
smaller downstream bias. This wider water support lets a leaf anticipate bends
without reacting to a different neighboring alpha sample on every frame. Each
accepted turn becomes the next cached heading, so turns accumulate around
reservoir curves. Velocity response is `8.0 s⁻¹`. Attachment never returns to
free motion, including through a temporary alpha gap, and an attached leaf
retires only after its complete disk clears the right edge.

The disk's stable size is derived from particle index and release generation,
so it does not flicker or change radius while moving. `STOPPED_FADING` changes
the resident disk's alpha directly. The visual radius is independent of the
larger water-contact radius used by the occupancy test.

Production GPU leaf paths and defaults are:

| Path | Default | Meaning |
|---|---:|---|
| `leaves.enabled` | `true` | Enables visible leaves/release handling |
| `leaves.per_side` | `15` | Default count from each of the top and bottom edges |
| `leaves.release_stagger_interval_seconds` | `0.20` | Base gap for alternating top/bottom scheduled starts; fixed multipliers produce 0.11…0.29-second gaps and an approximately 5.93-second default span |
| `leaves.free_speed_pixels` | `120` | Free-flight vertical speed |
| `leaves.flow_speed_pixels` | `300` | Attached downstream speed |
| `leaves.speed_variation` | `0.0` | Per-leaf speed variation |
| `leaves.velocity_response` | `8.0` | Response toward the cached local water heading |
| `leaves.sway_amplitude_min_pixels` | `2` | Minimum horizontal sway amplitude |
| `leaves.sway_amplitude_max_pixels` | `6` | Maximum horizontal sway amplitude |
| `leaves.sway_period_min_seconds` | `1.2` | Minimum sway period |
| `leaves.sway_period_max_seconds` | `2.8` | Maximum sway period |
| `leaves.water_alpha_threshold` | `0.001` | Minimum alpha counted as water |
| `leaves.contact_radius_pixels` | `12` | Radius of the one-way contact test |
| `leaves.free_water_search_radius_pixels` | `120` | Radius of the free leaf's 17 x 17 forward/inward 2D water search |
| `leaves.free_water_steering_strength` | `0.35` | Blend from inward fall toward nearby water |
| `leaves.free_search_max_distance_pixels` | `540` | Minimum inward bank distance before a miss can fade; never less than the screen midline |
| `leaves.stopped_fade_seconds` | `0.50` | Retirement fade after a missed leaf disk stops moving |
| `leaves.follow_probe_min_pixels` | `8` | Nearest cached-local-heading probe radius |
| `leaves.follow_probe_max_pixels` | `56` | Farthest multi-radius center/flank probe radius |
| `leaves.follow_turn_degrees` | `35` | Cached-local-heading probe half-angle per resample |
| `leaves.follow_resample_interval_seconds` | `0.12` | Interval between cached water-heading refreshes |
| `leaves.occupancy_flip_y` | `false` | Platform/debug fallback for an inverted texture |
| `leaves.disk_radius_pixels` | `5` | Canonical base visual radius for the head-only disk |
| `leaves.radius_variation` | `1.0` | Canonical one-sided deterministic radius variation, range 0…1; base × 1.0…2.0 gives radii of 5…10 pixels |
| `leaves.line_width_pixels` | `10` | Compatibility diameter control; equivalent to twice `disk_radius_pixels` |
| `leaves.line_width_variation` | `1.0` | Compatibility alias for `radius_variation` |
| `leaves.alpha` | `1.0` | Global leaf alpha |

`leaves.contact_radius_pixels` controls water detection and is independent of
the smaller visual `leaves.disk_radius_pixels`. Pause/resume applies to the leaf
head pool; in production the pause state is shared by every active stage in the
process. The stage's `reset` action clears leaf release generations and all
visible disks on each addressed stage; an immediate new release remains valid
even while paused.

## Actions

Actions can be strings:

```json
{
  "protocol": "ink-flow/1",
  "revision": 1045,
  "target": "delta",
  "changes": {},
  "geometry_ops": [],
  "actions": ["pause", "capture_screenshot"]
}
```

Or dictionaries with future-facing arguments:

```json
"actions": [
  {"name": "release_salmon", "arguments": {"count": 40}},
  {"name": "release_leaves", "arguments": {"count_per_side": 20}}
]
```

Common implemented action names are:

- `toggle_debug_geometry` (compatibility no-op; geometry remains visible)
- `reset`
- `pause`
- `resume`
- `capture_screenshot`
- `release_salmon`
- `release_leaves`

On the production GPU stage, `release_salmon` without arguments schedules the
configured `salmon.per_release` batch (25 by default). A dictionary may specify
`arguments.count` from 1 through the fixed capacity of 300. `release_leaves`
without arguments schedules `leaves.per_side` from both the top and bottom
edges (15 + 15 by default). Its dictionary form accepts
`arguments.count_per_side` from 1 through 150; `arguments.count` is an alias
with the same per-side meaning. The stage also accepts `toggle_gate`; `reset`
restarts water, salmon, and leaves and returns the presentation calendar to its
configured production start (`07/01-00:00`). The calendar reset is process-wide,
while particle restart follows message targeting. Reset preserves both global
pause and calendar auto-advance mode. Screenshot
capture remains part of the retained CPU action set unless the hosting scene
supplies its own capture handler.

## Legacy origin/main controller compatibility

The existing `origin/main` `controller.py` does not send an `ink-flow/1`
envelope. It broadcasts a legacy dictionary at 60 Hz with a `speed` value from
0 through 9 plus chair/regime metadata.

`FlowControlBus` recognizes packets without `protocol` that contain `speed` and
normalizes them to:

```json
{
  "protocol": "ink-flow/1",
  "revision": 1,
  "target": "*",
  "changes": {"flow_rate": 0.5555555556},
  "geometry_ops": [],
  "actions": [],
  "legacy": true,
  "legacy_speed": 5.0,
  "metadata": {"speed": 5, "chairs": [0, 1, 0, 0, 0, 0, 0]}
}
```

The mapping is `basin input = clamp(speed, 0, 9) / 9`; `flow_rate` is retained
as its compatibility input path. A valid seven-value `chairs` array is also
converted to the absolute `regimes.active_indices` set in this order: Kinship,
Agriculture, Gold Rush, Water Projects, Hydropower, Tech, Watershed.
Agriculture + Gold Rush + Tech applies `45% + 30% + 25% = 100%` extraction.
When the controller reports all seven chairs released, the absolute state
returns to Kinship instead of becoming an empty regime set.
All original chair metadata remains available under `metadata`.

Unchanged 60 Hz legacy packets are coalesced instead of filling every model's
queue. Meaningful speed/chair/regime changes are delivered. The latest state is
cached and replayed once if a model appears after the bus began listening, so
selecting a scene does not require a chair state to change before flow starts.
Localhost and broadcast copies of the same packet are also deduplicated.

## Keyboard controls

When `accept_keyboard_input` is enabled on a model:

| Key | Runtime effect |
|---|---|
| `0`, `8`, `9` | Production GPU: set `flow_rate` to `0/9`, `8/9`, or `9/9` |
| `V` | Compatibility key; drain/obstacle and reservoir geometry remains visible on every active stage |
| `G` | Toggle the first reservoir's gate |
| `[` | Narrow the first reservoir gate by `gate_width_step` |
| `]` | Widen the first reservoir gate by `gate_width_step` |
| `S` | Production GPU: release the configured salmon batch (25 by default) |
| `L` | Production GPU: release 15 leaves from the top and 15 from the bottom |
| `Space` | Production GPU: globally pause/resume the timeline and all active stages in this process |
| `F12` | Capture a PNG screenshot |
| `Escape` | Return to `startup_selector.tscn`; the process-wide clock is preserved |

The first reservoir in the default profile is `reservoir_main`.

Running production stages intentionally do not consume `1`–`7`. The Governator
controller's `regime-console` owns those keys for the pilot and sends an
absolute active set once to every configured Godot process with target `*`; the startup selector still
uses `1`–`7` before a stage launches. Keys `0`, `8`, and `9` update only water
`flow_rate` and do not rebuild, retune, or release the salmon/leaf systems or
resize their segment pools. `S` releases only salmon, and `L` releases only
leaves. Every recognized stage key is marked handled so another scene node
cannot process the same event a second time. Use absolute regime state, ecology
runtime paths, and release actions when a controller changes those systems.
Keyboard `V` and controller-targeted debug actions are compatibility no-ops;
geometry remains visible on every active stage.

In the production GPU host, the reservoir guide remains cyan and absorb/repel
polygons remain gold. Disabled polygons use a faint version of that color so
they can still be found while debugging. The background grid, stage title, and
model date remain visible because they are not debug geometry.

## Screenshots

Screenshots are written to:

```text
user://ink_flow_screenshots/<screen_id>_<timestamp>.png
```

Godot resolves `user://` to the current platform's application-data directory.
On success, `FlowModel2D.action_completed` emits the globalized absolute path in
`details.path`, which is the reliable path for a controller UI to display.

## Runtime state and signals

`FlowModel2D.get_state_snapshot()` returns the protocol name, screen ID, last
revision, serialized parameter values, all geometry, runtime stats, and the
latest controller metadata. `describe_parameters()` adds type/range/reset
schema information to every scalar parameter.

Model signals include configuration, parameter, geometry, gate, action,
reset, stats, and control-error notifications. The transport emits
`listening_started`, `packet_received`, `packet_routed`, `packet_error`, and
`transport_error`.

`GPUFlowStage2D.runtime_summary()` exposes its presentation state directly.
Grid fields are `stage_grid_visible`, `stage_grid_spacing_pixels`,
`stage_grid_line_width_pixels`, `stage_grid_color`, `stage_grid_z_index`, and
`stage_grid_line_count`. Date fields are `stage_date_visible`,
`stage_date_text`, `stage_date_format`, `stage_date_position`, `stage_date_color`,
`stage_date_font_size`, `stage_date_font_resource`, `stage_date_z_index`,
`stage_date_position_anchor`, `stage_date_rotation_degrees`,
`stage_date_tabular_numerals`, and `stage_date_opentype_feature`.
The title namespace additionally exposes `stage_title_display_text`,
`stage_title_font_instance_id`, `stage_title_tabular_numerals`,
`stage_title_opentype_feature`, `stage_title_temperature_integrated`, and
`stage_title_temperature_visible`. The complete water-temperature namespace
is `water_temperature_visible`,
`water_temperature_text`, `water_temperature_value_c`,
`water_temperature_value_valid`, `water_temperature_position`,
`water_temperature_position_anchor`, `water_temperature_rotation_degrees`,
`water_temperature_color`, `water_temperature_font_size`,
`water_temperature_font_resource`, `water_temperature_font_shared_with_date`,
`water_temperature_font_shared_with_title`,
`water_temperature_font_instance_id`,
`water_temperature_tabular_numerals`,
`water_temperature_opentype_feature`, `water_temperature_z_index`,
`water_temperature_format`, `water_temperature_fallback_text`,
`water_temperature_data_path`, `water_temperature_data_column`,
`water_temperature_data_loaded`, `water_temperature_data_status`,
`water_temperature_data_error`, `water_temperature_data_row_count`,
`water_temperature_data_expected_row_count`,
`water_temperature_data_row_count_matches_expected`,
`water_temperature_data_row_index`, `water_temperature_data_row_fraction`,
`water_temperature_interpolation_mode`, `water_temperature_node_path`,
`water_temperature_integrated_with_stage_title`, and
`water_temperature_outside_water_viewport`. The node path resolves to
`StageTitleLayer/StageTitle`; no separate temperature node is created.
Presentation also has the
stage-family aliases `stage_temperature_visible`, `stage_temperature_text`,
`stage_temperature_value_c`, `stage_temperature_position`,
`stage_temperature_position_anchor`, `stage_temperature_rotation_degrees`,
`stage_temperature_color`, `stage_temperature_font_size`,
`stage_temperature_font_resource`, `stage_temperature_tabular_numerals`,
`stage_temperature_opentype_feature`,
`stage_temperature_integrated_with_stage_title`, and
`stage_temperature_z_index`.
Clock fields are `model_day_index`, `model_day_of_year`,
`model_minute_of_day`, `model_elapsed_seconds`, `model_year_progress`,
`model_year_duration_seconds`, `model_year_frames_at_30_fps`,
`model_year_minute_count`, `model_calendar_day_count`,
`model_calendar_auto_advance`, `model_calendar_source`, and
`model_start_day_index`. In production these fields are synchronized mirrors of
`ModelTimeline`, not independent stage clocks.

Watershed fields are `watershed_data_path`, `watershed_data_loaded`,
`watershed_data_error`, `watershed_data_river`, `watershed_data_row_count`,
`watershed_data_row_index`, `watershed_data_row_fraction`,
`watershed_data_drives_flow_rate`, `watershed_interpolate_flow_rate`,
`watershed_interpolated_flow_rate`, `watershed_flow_percent`,
`watershed_row_duration_seconds`, `watershed_model_minutes_per_row`, and
`watershed_current_row`. The current-row dictionary contains `row_index`,
`row_count`, `raw_value`, `normalized_flow`, `scaled_flow`, `high_variation`,
`interpolated_flow_rate`, `row_fraction`, and `model_date_time`.

Layering can be inspected through `background_z_index`, `stage_title_z_index`,
`stage_title_below_animated_features`, `stage_grid_above_background`, and
`stage_text_above_grid`. The corresponding occupancy guarantees are
`water_texture_excludes_background`, `water_texture_excludes_stage_grid`,
`water_texture_excludes_debug_overlay`, `water_texture_excludes_stage_title`,
`water_texture_excludes_stage_date`, and
`water_texture_excludes_stage_temperature`.

This state/control layer is the intended seam for a later control scene. The
production GPU stage adds salmon and leaves through that seam. Both ecological
overlays sample the same water-only texture without changing the water-profile,
geometry targeting, or UDP envelope described here.

## Automated validation suites

From `godot_experiments/`, run:

```sh
Godot --headless --path . \
  --scene res://flow/tests/flow_runtime_smoke.tscn
```

The test loads a real `FlowModel2D`, exercises parameters, gates, geometry
upsert/removal, atomic rollback, pause/resume, direct protocol routing, legacy
speed compatibility, and a real localhost UDP JSON packet. A successful run
ends with `FLOW_RUNTIME_SMOKE: PASS`. It deliberately submits one over-budget
configuration to verify rollback, so the corresponding rejection warning is
expected.

The retained validation set has six suites:

| Suite | Scene |
|---|---|
| Basin input, extraction budget, chair mapping, rectangles, flood/tide | `res://flow/tests/basin_budget_smoke.tscn` |
| Controller transport and retained runtime | `res://flow/tests/flow_runtime_smoke.tscn` |
| Reusable production GPU stage | `res://flow/gpu_stage/gpu_flow_stage_smoke.tscn` |
| GPU salmon | `res://flow/gpu_stage/gpu_salmon_smoke.tscn` |
| GPU leaves | `res://flow/gpu_stage/gpu_leaf_smoke.tscn` |
| Seven production wrappers | `res://flow/tests/gpu_stage_scenes_smoke.tscn` |

The four deployed GPU suites verify the water-only viewport, the bounded
interaction texture and its propagation to all seven water particle-process
materials, interaction controller operations, salmon and leaf release/control
without CPU readback, fixed circular ecology pools and stable resident
allocations during their high-volume release stress passes, targeted screen
isolation, and the shared Barlow Condensed Medium resource. The
grid, date-time, and watershed
timeline described above are runtime contracts; the current smoke scenes do not
assert their complete behavior.
The standalone leaf smoke is:

```sh
Godot --headless --path . \
  --rendering-method mobile \
  --scene res://flow/gpu_stage/gpu_leaf_smoke.tscn
```

It checks the fixed 300-slot pool, exact 15-top/15-bottom default release,
deterministic irregular alternating `0.11…0.29`-second gaps and an approximately
5.93-second default span, independent deterministic X-lane shuffles per bank,
custom per-side release, palette, head-only antialiased disks with deterministic
10…20-pixel diameters and 5…10-pixel radii, 2–6-pixel free-sway contract, the
120-pixel 17 x 17
nearby-water search and 0.35 steering blend, 256-pixel inward search bound,
frozen 0.5-second disk fade, zero segment capacity, one-way attachment state,
8…56-pixel center/flank support over a 35-degree fan at a 0.12-second cadence,
water-texture assignment, pause/reset/immediate re-release behavior, and
absence of CPU readback. Its 500-call stress pass also checks circular wrapping,
bounded last-release state, fixed particle amount and control dimensions, and
unchanged resident node/resource identities and RIDs; the salmon smoke performs
the corresponding checks across 2,000 release calls. All GPU
smoke commands and their expected scope are listed in
`res://flow/gpu_stage/README.md`.
