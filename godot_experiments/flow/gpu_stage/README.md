# Reusable GPU flow stage

## Production deployment

`scene_1.tscn` through `scene_7.tscn` each instance this component directly.
The startup selector offers two independent river pickers and rejects duplicate
choices. **Launch Two Displays** hands both choices to `dual_stage_host.tscn`;
**Launch Display A Only** and number keys `1…7` retain a direct single-stage
path. Stable screen IDs remain unchanged, and stage indices `0…6` provide
independent seeds.
`ModelTimeline` is a project autoload, so replacing the current scene does not
replace the model clock. Returning to the selector and choosing another river
therefore preserves the current model date instead of starting a new year.

With two or more monitors, the host keeps one Godot process and creates two
native outputs: stage A renders in the root `Window`, and stage B renders in a
non-transient native child `Window`. Each output uses a 1920 x 1080 logical
canvas with aspect-preserving canvas scaling and is placed borderlessly over
the exact `DisplayServer` rectangle of a different monitor. Windowed borderless
placement avoids creating a separate macOS Space for each output. Closing
either output or pressing Escape tears down the complete host and returns to
the selector.

With one monitor, the same host renders both independent 1920 x 1080 stages in
side-by-side `SubViewport` previews. Click a preview to direct its local G/S/L
and water controls. `V` is retained as a compatibility key but geometry remains
visible on every active stage. Shared
timeline and regime state still advance only once. Running previews do not
consume `1`–`7`; the Governator controller owns regime test input. This fallback
is for configuration and rehearsal; installation performance must still be
checked with both native monitor windows visible.

The project uses Mobile rendering, a 1920 x 1080 logical viewport, 4x 2D MSAA,
and a project render cap of 30 FPS. An obscured or embedded macOS Metal window
may report a much lower FPS because the OS throttles it, so installation timing
should be checked in a visible window. The fixed palette-depth renderer keeps
the former particle count but uses more particle nodes and GPU dispatches; run
a visible two-screen hardware benchmark after renderer changes before treating
30 FPS as an installation guarantee.

`gpu_flow_stage_2d.tscn` is one native 1920 x 1080 screen of GPU flow. It owns
seven fixed palette layers. Each layer is a paired head `GPUParticles2D` emitter
and child `GPUParticles2D` pool of immutable trail segments. Together they
contain exactly 1,000 head slots and 75,000 segment slots—the layers divide that
population rather than multiplying it by seven. Density is piecewise linear:
1% water shows 20 lines and 100% water shows all 1,000. Native emitters always
run a complete eight-second cycle; an evenly spaced global-slot selector controls
the logical population without Godot's low-count `amount_ratio` batching. A head
re-enters directly after its previous trail fades instead of waiting for another
native cycle. Particle simulation is render-paced while the project caps
rendering at 30 FPS; this prevents a fixed-step catch-up frame from overwriting
an earlier sub-emitter batch. Each head emits one stationary segment
between consecutive completed positions. Native particle trails are disabled
on every layer. Line cores vary from 1–5 native pixels with a one-pixel alpha
feather.

The seven water layers render once into the component's native 1920 x 1080,
transparent `WaterOnlyViewport`. `WaterTextureDisplay` composites that texture
back into the stage with premultiplied-alpha blending. The black background,
background grid, debug overlay, temperature-bearing stage title, model date,
salmon, and leaves are siblings outside the water viewport, so they are
not copied into the water texture and the visible water is not rendered twice.
Each production scene wrapper can instance the component directly because the
project viewport is also 1920 x 1080.

The component intentionally reuses the particle and draw shaders from
`res://flow/gpu_prototype/`. The prototype remains an isolated two-up preview;
this component is the one-screen production building block.

## Host requirements

- Use the Mobile or Forward+ renderer; Compatibility does not provide the GPU
  particle subemitters used by the immutable segment renderer.
- Set 2D MSAA on the host viewport for root-level overlays. The production
  project currently uses 4x MSAA, and the component also gives its native
  water-only viewport 4x MSAA.
- Keep the logical project viewport at 1920 x 1080. Godot can then stretch the
  finished frame to the physical output without changing shader geometry.

## Water-only texture and GPU occupancy

`get_water_texture()` returns the transparent `ViewportTexture` produced by
`WaterOnlyViewport`. Its RGB and alpha contain only the original water
head/segment renderer. The stage background, background grid, cyan reservoir
guide, gold interaction outlines, temperature-bearing stage title, model date,
active-regime panel, salmon, and leaves are deliberately excluded.

Salmon and leaves bind this exact texture and sample its alpha in their
particle-process shaders. Salmon choose a full 2D upstream heading from their
centered contact field. Free leaves steer toward nearby water and stop/fade if
their bounded bank-to-center search misses; latched leaves periodically choose
a supported downstream heading. There is no `ViewportTexture.get_image()`,
pixel transfer, mask rebuild, or other per-frame CPU readback. Occupancy UVs
are stage-native `position / Vector2(1920, 1080)`, not `SCREEN_UV`. Keeping
both ecological overlays outside the water-only viewport prevents feedback in
which a salmon or leaf could recognize itself as water.

## Scene identity and controller discovery

Every instance exposes:

- `stage_index: int`: selects a deterministic seed/phase per screen.
- `screen_id: StringName`: the installation screen name.
- `model_id: StringName`: an additional model address.
- `control_target: StringName`: an optional controller alias.
- `stage_title: String`: the human-readable river title shown on that screen.
- `stage_title_visible: bool`: title visibility without changing screen identity.
- `regime_panel_visible: bool`: visibility of the process-wide regime state on
  this screen. Production enables it only for Delta.
- `regime_heading_visible: bool`: per-stage visibility of the optional
  `Regime` heading. Delta hides it while retaining the seven regime names.
- `stage_grid_visible: bool`: visibility of the screen-fixed model grid.
- `stage_grid_spacing_pixels`, `stage_grid_line_width_pixels`, and
  `stage_grid_color`: native-pixel grid presentation controls.
- `stage_date_visible: bool`: visibility of the screen-fixed
  `MM/DD-HH:MM` label.
- `stage_temperature_visible: bool`: whether the measured temperature suffix
  is appended to the stage title. Production enables it on every stage except
  Cottonwood Creek.
- `temperature_data_path` and `temperature_data_column`: the
  shared 720-row Celsius table and the stage-specific series selected from it.
- `model_year_duration_seconds`, `model_start_day_index`, and
  `model_calendar_auto_advance`: initial watershed-calendar configuration and
  compatibility controls. In the production project they configure or mutate
  the process-wide `ModelTimeline`, not an independent per-stage clock.
- `watershed_data_path`, `watershed_data_drives_flow_rate`, and
  `watershed_interpolate_flow_rate`: the stage-specific 720-row data source and
  its flow-driving policy.

It joins the existing `flow_models` group and implements
`accepts_control_target()` plus `queue_control_message()`, so the existing
`FlowControlBus` can discover and address it.

The `ModelTimeline` autoload is the single calendar authority within one Godot
process. A stage keeps a synchronized local view only for its label, watershed
interpolation, signals, and `runtime_summary()`. It never advances or resets the
production clock independently.

`ModelRegimes` is a second in-memory process autoload and is the single live
authority for the seven historical regime toggles. Its authoritative order is
Kinship, Agriculture, Gold Rush, Water Projects, Hydropower, Tech, and
Watershed. Agriculture keeps the stable internal ID `ranch`; the preferred UI
path is `regimes.agriculture`, while `regimes.ranch` remains compatible.
The initial active set is Kinship. Any number of regimes may be active
simultaneously, and changing scenes or passing through the selector preserves
that set. A separate Godot process has a separate `ModelRegimes` authority, so
an installation controller must synchronize separate executables explicitly.
Incoming regime paths are applied to that in-memory authority by
`FlowControlBus` before the packet is routed to stages. This keeps packets sent
on the selector or during startup and prevents a dual-stage process from applying
the same global change once per hosted stage.

### First-six per-river regime pilot

`ModelRegimes` loads the comma-delimited master table at
`res://regime_feature_profiles.txt`. Each of the first six rows links through
its `river_profile_path` to one exact seven-screen table under
`res://flow/data/regimes/`: `kinship.txt`, `ranch.txt` (Agriculture),
`gold_rush.txt`, `water_projects.txt`, `hydropower.txt`, or `tech.txt`.
Master columns are addressed by header name; each linked table must use the
exact canonical column order. `profile_status` is informational and never
disables populated data.
Both the master and linked tables use schema version `2`. The supplemental
source feature and its former `source_area_fraction`/`source_season` columns are
not part of that schema. This does not remove the ordinary full-height left-edge
river inlet, which is a fixed water-lifecycle boundary rather than a regime
feature.

A populated per-river cell overrides the master default. A blank cell inherits
a populated master value; when both are blank, that feature is undefined. An
explicit `0` is defined data, not a blank. For each screen and feature, the
runtime takes an equal mean across only the defined active contributors;
undefined active regimes do not enter the denominator, while explicit zeros do.
If no active contributor defines a feature, the stage keeps its authored
baseline instead of applying a zero override. All seven production wrappers opt
in to this per-river physics. Only Delta shows the active-regime panel; that is
a presentation choice, not a Delta-only physics scope.

The current matrix uses `S` = Lake Shasta, `Mc` = McCloud/Pit, `C` =
Cottonwood Creek, `Mi` = Mill Creek, `F` = Feather River, `A` = American River,
and `D` = Delta. `R`, `Dr`, `Ob`, and `Sh` below mean reservoir area, drain
area, obstacle area, and shoreline randomness; `c` is the desired reservoir
count and `p` is interaction power.

| Regime | Current seven-screen definition |
|---|---|
| Kinship | All seven: `R 0/c0`, `Dr 0/p0`, `Ob 0/p0`, `Sh 1`; salmon `11/01–01/31` daily and leaves `10/01–10/31` every 2 days. |
| Agriculture (`ranch`) | `R .20/c1` on S/Mi/F/A, `.20/c2` on Mc/D, and `0/c0` on C; `Dr .75` and `Ob .10` on all seven; `Sh .30` on S/Mc/C and `0` elsewhere. Positive-area reservoir gates are scheduled open `06/01–08/31`; aperture is otherwise undefined. |
| Gold Rush | Only F/A/D define physics: `R .10` (count blank), `Dr .30/p1`, `Ob .30/p1`, `Sh 1`, plus the Kinship salmon/leaf seasons. S/Mc/C/Mi remain blank. |
| Water Projects | S/Mc/F/A/D: `R .33/c1`, `Dr .50`; C/Mi: explicit `R 0/c0`, `Dr 0`. Five of seven whole-river stages is the nearest discrete allocation to 75%. All seven define `Sh 0` and leaves `0`; other fields and gate schedules are blank. |
| Hydropower | S/Mc/Mi/F/A/D: `R .50/c2`, aperture `.33`, gate open `01/01–12/31`; C: `R 0/c0` with no gate. All seven inherit `Dr .25`; `Sh .20` on Mc/C and `0` elsewhere. |
| Tech | All seven: `R .75/c2`, `Dr .75/p1`, and `Sh 0`; gate, obstacle, salmon, and leaf fields remain blank. |
| Watershed | The authored profile remains a no-op until a valid `watershed-ai/2` seasonal allocation is applied. Watershed is exclusive: selecting it clears every other regime. |

The three `*_area_fraction` physics values are deterministic admission or
encounter budgets over particle lifecycles. They do not resize geometry or
promise literal screen-area coverage. Drain and obstacle `power` are separate
from those budgets and control response strength for admitted encounters. For
drains and obstacles, a positive weight also selects how many members of a
bounded resident bank are active: `ceil(weight * capacity)`. The capacities are
five drains and two obstacles. Thus Agriculture's `.75` drain
weight renders four field/drain polygons and its `.10` obstacle weight renders
one obstacle. The admission selector is feature-wide, so `.75` admits one 75%
cohort across all four drains rather than independently giving every drain a 75%
chance. A defined zero activates no slots; an undefined feature preserves one
authored fallback slot and its authored budget.

The seven resident interaction resources—five drains and two obstacles—fit in
the eight-record interaction texture and leave one slot available for controller
geometry. This fixed bank is allocated once during stage startup. Regime changes
only enable, disable, and reshape or translate the resident resources; they never
create or resize a node, resource, particle pool, or texture.

Every real change to the absolute active set advances a layout generation. The
placement seed combines `screen_id`, the sorted physical contributors, feature
kind, slot index, and that generation. Drain lanes and obstacle positions are
therefore fresh on each real transition, including `Tech -> Agriculture` and a
later `A -> B -> A`; they are not reused merely because an earlier active set
returns. A repeated absolute set is idempotent, publishes no new regime change,
and does not advance or re-upload a layout. Fields remain stratified along X,
swap top/bottom bank assignment on adjacent generations, and use newly seeded
width, depth, and lane position. Obstacles retain their captured authored
shape but move to newly seeded positions. Explicit zero is different from
undefined: it activates no constraint or debug guide for that feature.

Each active regime field is an axis-aligned rectangle touching exactly the top
or bottom screen edge. Eligible water bends laterally from as far as 300 pixels
toward a target inside the strongest nearby field. The target guarantees a real
river-facing-edge crossing instead
of pulling a trail vertically past the field. At that crossing, streamwise
motion drops to zero and the accepted head makes a sharp top/bottom quarter-turn
at no less than 540 pixels/second. It continues through the complete field and
past the physical screen edge before entering the normal bounded recycle delay;
its immutable trail remains visible long enough to read as a dramatic
withdrawal. The field bank does not teleport water or allocate replacement
heads.

A defined zero reservoir area or count removes the reservoir constraint and
debug guide. If a regime removes or relocates a live reservoir, retained heads
resume downstream flow and their existing orbit trails fade over the normal
trail lifetime. Obstacles affect moving heads on their next simulation step;
heads already committed to a field continue to its bank exit and recycle after
their immutable trail lifetime. None of these transitions restarts the water
particles. The GPU renderer still has one
physical `reservoir_main`; a profile value such as `reservoir_count=2` remains
desired-state data and does not create a second reservoir today.

Reservoir schedules are blended separately from the equal feature mean. Active
profiles with positive reservoir area and a complete gate schedule contribute
that area to an area-weighted open fraction; the stage multiplies the effective
aperture by that fraction. Hydropower supplies aperture `.33` all year, while
Agriculture supplies `.20` of scheduled reservoir area open only June through
August. Thus, when both are active on a non-Cottonwood screen, the aperture is
`.33` in season and `.33 * .50 / (.50 + .20)` outside the Agriculture season.
The authored/manual gate state remains an outer enable. Agriculture alone uses
the authored aperture in season and closes it outside the season.

`shoreline_randomness` is retained as the profile/data name for compatibility,
but it now drives a lightweight edge-turbulence field instead of shoreline
polygons. The normalized `0…1` value scales a 180-pixel band along both the top
and bottom edges. Most of that band adds deterministic, zero-mean cross-stream
turbulence with a smaller streamwise component; the outermost 40 pixels add an
inward confinement force so heads stay on screen. Zero disables the complete
effect and `1.0` applies full turbulence. There is no shoreline collision
geometry, debug polygon, data texture, or narrowed channel. `y = 28…1052`
remains the available left-edge inlet; the active water source occupies a
flow-scaled band inside it. At 1% the band is centered at `y = 540`, then widens
symmetrically toward the top and bottom until 100% uses the complete range.
Existing immutable water history stays in place while the live heads respond, so a
regime transition remains visibly continuous without restarting particles.
The uniform edge field is also cheaper than the former polygon force and
swept-crossing searches.

### Stage presentation layers and model calendar

The main-canvas presentation stack is fixed around the animated content:

- `Background` is the explicit black `ColorRect` at absolute Z `-100`.
- `BackgroundGrid` is a stage-owned `Node2D` at absolute Z `-75`. Its production
  default is 1-native-pixel lines every 120 pixels in `#4AB0E1` at `0.25` alpha.
  Because one world unit is exactly 120 native pixels, the default grid describes
  the model's 16 x 9 coordinate system directly. Boundary lines are omitted, so
  the grid begins one interval inside each edge and never forms a screen frame.
- `StageTitleLayer` is at absolute Z `-50` and owns `StageTitle`,
  `ModelDate`, and the optional `ActiveRegimes` panel. There is no separate
  temperature label. All type reads bottom-to-top at `-90` degrees. The
  60-pixel title is centered on `(60, 540)` and the 48-pixel date is centered
  on `(1860, 540)`—the top and bottom centerlines after the installation
  displays are mounted vertically. Both share one bundled Barlow Condensed
  Medium `FontVariation` in opaque `#4AB0E1` with OpenType `tnum` enabled.
  Tabular figures keep the title's changing temperature digits and the date's
  digits at fixed widths.
  Every production stage except Cottonwood Creek appends its measured value to
  the title, for example `Delta (20.5 °C)`. If a configured series is absent
  or invalid, the title remains visible as `Delta (— °C)`; disabling
  `stage_temperature_visible` restores the title-only form `Delta`.
  The base title, regime heading, and regime names otherwise retain their
  existing typography. Only the Delta wrapper enables the regime panel. It hides the
  optional 48-pixel `Regime` heading and leaves the seven 60-pixel names at
  their existing positions beginning on X `1420` with 72-pixel centerline
  spacing. Its last visible name is `AI Watershed`; this Delta-only label does
  not change the stable internal `Watershed` name or `watershed` ID.
  Active names are opaque and inactive names are shown at `0.25` alpha.
  The panel follows the shared `ModelRegimes` state, so matching active names
  highlight immediately even when that state arrived before Delta was loaded.
- Water, salmon, and leaves render at absolute Z `0` or higher, so active
  features can pass visibly over the grid and text.

The grid and all presentation text, including water temperature, are outside
`WaterOnlyViewport` and `ReservoirAndStatusOverlay`. Their alpha can never be
sampled as water by salmon or leaves, and the `V` debug toggle does not hide
them. The bundled font is
`res://flow/assets/fonts/BarlowCondensed-Medium.ttf`; the installation does not
depend on a matching system font.

`ModelDate` displays a zero-padded `MM/DD-HH:MM` in a non-leap, 365-day model
year. Every production wrapper sets `model_start_day_index = 181`, the zero-based
index for `07/01`, so a cycle runs from July 1 through June 30 and then wraps.
The shared internal clock defaults to one model year every 720 running seconds,
which is 21,600 rendered frames at the project's 30 FPS cap. The date-time is
derived from the continuous year fraction rather than accumulated integer frame
counts, so it does not drift. `ModelTimeline` survives both trips through
`startup_selector.tscn` and direct stage-to-stage scene replacement. While
automatic advancement is enabled and the timeline is not paused, it continues
to run even while the selector is visible.

A newly instantiated stage synchronizes from `ModelTimeline` immediately after
loading its own watershed and optional temperature files and before building
its water particles. Its date label, 720-row data positions, interpolated flow
rate and temperature, and runtime summary therefore begin at the current shared
instant; they do not briefly fall back to `07/01-00:00` or row zero. Two stages
hosted by the same Godot process consume the same authority and remain on
exactly the same clock.

Pause is also process-global in the production project. Calling
`set_paused(true)` or pressing Space on any active stage pauses `ModelTimeline`
and all active stages in that process; resume releases them together. This is
deliberately different from a private per-screen pause. Automatic advancement
and explicit pause are independent states: a manually held date can remain
unpaused, and resuming simulation does not implicitly enable auto-advance.

Each stage loads a 720-row `water_pipeline` text file. At the default 720-second
year, one row spans exactly one running second and represents a uniform 730
model minutes (12 hours 10 minutes). The files do not contain timestamps, so the
displayed `HH:MM` is a synthetic, uniformly spaced model time rather than an
observed sample timestamp. Between row boundaries the stage linearly
interpolates the current and following `norm` values on every update, including
the last-to-first wrap. The interpolated `norm` maps directly from `0.0…1.0` to
water `flow_rate` `0.0…1.0`, or 0…100 percent; it is not multiplied by the raw or
scaled columns.

The stage's `reset` action returns the process-wide timeline to
`07/01-00:00` and restarts water, salmon, and leaves on every stage addressed by
that action, without changing global pause or auto-advance mode. Consequently,
a reset targeted at one river still resets the shared calendar for every active
and subsequently loaded river, although only the addressed river's particles
restart. Target `*` when the Governator intends a synchronized visual reset.
`reset_model_calendar()` resets only the global calendar/data position and
leaves particle state intact. A direct `set_flow_rate()`, water-rate digit
shortcut (`0`, `8`, or `9`), `flow_rate`, or
`active_ratio` change is an intentional manual override and disables watershed
flow driving. Set `watershed.drives_flow_rate` back to `true` to apply the
current interpolated data value immediately.

For an external time handoff, `set_model_date_time("12/21-06:30")` (or the
compatibility name `set_model_date_mm_dd`) and runtime paths `calendar.date` or
`stage.date` validate the non-leap date and time, align the watershed row, and
disable automatic advancement. This handoff is process-global even when the
message was addressed through one stage: all active stages move to the same
instant, and a later stage inherits it. Date-only `MM/DD` input remains accepted
and means midnight, but output is always canonical `MM/DD-HH:MM`. Invalid values
return `false` without changing state. Call
`set_model_calendar_auto_advance(true)`, or set `calendar.auto_advance`, to
resume the shared clock from the displayed time.

An autoload is shared only inside its own Godot process. Two stages in one
process are synchronized automatically; two Godot executables, two computers,
or two separately launched display processes each have their own
`ModelTimeline`. The Governator must send those processes the same authoritative
date/phase and periodically resynchronize them if installation-wide phase lock
matters. Scene-switch persistence is not a network clock.

Each wrapper assigns its title explicitly. Display text is not a controller
identity and may change without changing the stable `screen_id` or `model_id`.

| Scene | `screen_id` | Stage title | Watershed data | Temperature series |
|---|---|---|---|---|
| `scene_1.tscn` | `mount_shasta` | Lake Shasta | `shasta_720.txt` | Keswick release |
| `scene_2.tscn` | `mccloud_pit` | McCloud-Pit Rivers | `mccloud_720.txt` | none |
| `scene_3.tscn` | `cottonwood_creek` | Cottonwood Creek | `cottonwood_720.txt` | none |
| `scene_4.tscn` | `mill_creek` | Mill Creek | `mill_creek_720.txt` | none |
| `scene_5.tscn` | `feather_river` | Feather River | `feather_720.txt` | none |
| `scene_6.tscn` | `american_river` | American River | `american_720.txt` | none |
| `scene_7.tscn` | `delta` | Delta | `delta_720.txt` | Freeport |

All seven files are project resources under
`res://flow/data/water_pipeline/`. They cover July 1, 2025 through June 30,
2026, with exactly 720 samples of normalized atmospheric water arrival built
from NOAA precipitation, temperature, snowfall, and snow-depth fields. The
combined McCloud-Pit screen uses the McCloud station proxy. The Delta combines
all seven signals using the documented conceptual weights in
`flow/data/basin_input/build_basin_input_720.py`. The runtime keeps the name
`raw_value` for compatibility, but its source column is now `input_mm_day`.

The stage applies one equation after interpolation:

`Delta remainder = basin input × (1 − total extraction fraction)`

Before extraction, the 720-point atmospheric series passes through a trailing,
cyclic 30-day running average (59 samples). This represents catchment storage
and baseflow rather than treating each dry precipitation interval as an
instantaneously dry river. The existing daily fog volume is then redistributed
into its morning pulse, and the resulting data-driven basin input is floored at
2%. Raw and interpolated atmospheric values remain available in runtime
telemetry; only the buffered value drives the one input to the budget.

Regime fractions are Kinship 0%, Agriculture 45%, Gold Rush 30%, Water
Projects/export 40%, Hydropower/reservoir loss 15%, Tech/data-center cooling
25%, and the authored Watershed fallback 0%, capped at 100%. An applied
Watershed AI state instead derives extraction from its agriculture,
data-center, and city allocations. Until that state arrives, the Delta panel
shows an em dash rather than claiming `0%`. The panel displays input, total
extraction, and remainder. Kinship floods the Delta with borderless 45-degree
blue hatching: 3-pixel round-capped lines, 6-pixel gaps, fixed 33% alpha, and a
6-pixel label knockout. Every regime draws the incoming Bay tide as a
right-anchored area using all 8,760 hourly NOAA CO-OPS predictions for San
Francisco station `9414290` over the same July 1, 2025–June 30, 2026 window.
The wrapped FIFO window covers exactly 96 hours: 48 past hours above screen
center and 48 future hours below it, with current model time fixed at `y=540`.
The polygon's left boundary follows interpolated hourly tide height; its
41–306 pixel reach preserves the earlier 66% scale reduction. It has no solid
fill, outline, label, or arrowhead. White, pixel-aligned horizontal hatches are
3 pixels wide with 6-pixel gaps and fixed 20% alpha. The tide renders at Z=-60
below all text and advances on the shared model-year clock. Delta budget
percentages use Barlow Condensed with its tabular-numeral OpenType feature.
The seven water-color head emitters keep native `amount_ratio = 1`, zero timing
randomness, and zero explosiveness. The shader selects the requested logical
population at evenly spaced global phases, while small deterministic layer
offsets interleave the colors. Completed heads recycle directly after their
two-second immutable tails fade. This removes both synchronized color packets
and the low-flow blank interval without changing trail, velocity, reservoir,
gate, extractor, city, or turbulence physics.
Agriculture fields and Tech data centers are bank-connected `Rect2` extractors.
All active geometry uses borderless,
unclipped 45-degree hatching with 3-pixel round-capped lines, 6-pixel gaps, and
fixed 33% alpha. Repelling geometry is labeled City in the artwork while
retaining `obstacle` as its protocol-compatible internal physics name. Hatches
split around measured label bounds, leaving a transparent six-pixel clearance.
Fields use green and data centers use white. All overlay labels are rotated -90°.

Six production stages read the shared table
`res://flow/data/water_pipeline/water_temperature_all_rivers_720.txt`;
Cottonwood Creek intentionally has no temperature series:

| Stage | Temperature column |
|---|---|
| Lake Shasta | `shasta_keswick_release_temp_c` |
| McCloud-Pit Rivers | `mccloud_above_shasta_lake_temp_c` |
| Mill Creek | `mill_creek_temp_c` |
| Feather River | `feather_below_thermalito_temp_c` |
| American River | `american_fair_oaks_temp_c` |
| Delta | `delta_freeport_temp_c` |

The table's 720 comma-delimited rows form a half-open July-to-June annual
series on evenly spaced Pacific-time timestamps. The runtime linearly
interpolates adjacent rows from the shared `ModelTimeline`, keeping each
title's temperature suffix phase-aligned with `ModelDate`. The annual
position is cyclic: row 719 interpolates toward row 0 as the model wraps to
July 1. `runtime_summary()` reports
`HALF_OPEN_ANNUAL_LINEAR_WRAP`. Loading succeeds only when all 720 numeric
rows are present with contiguous frame IDs `0…719`; the loader also accepts
tab-delimited pipeline exports.

These are data products rather than values inferred from regime or flow. A
missing file, missing selected column, malformed row, or non-finite
interpolated value leaves the configured title visible with the `(— °C)`
fallback; it never substitutes a regime estimate. Temperature currently
affects title text only: no background color, water-trail tint, flow physics,
or ecology parameter is changed.

The production presentation, regime, calendar, watershed, and temperature
paths are:

| Runtime path | Compatibility alias | Effect |
|---|---|---|
| `debug.geometry_visible` | `debug_visible` | Compatibility path; production geometry remains visible |
| `stage.title` | `stage_title` | River display text |
| `stage.title_visible` | `stage_title_visible` | Title visibility |
| `stage.regime_panel_visible` | `regime_panel_visible` | Active-regime panel visibility for this screen |
| `stage.grid_visible` | `stage_grid_visible` | Grid visibility |
| `stage.grid_spacing_pixels` | `stage_grid_spacing_pixels` | Grid spacing, clamped to `1…960` native pixels |
| `stage.grid_line_width_pixels` | `stage_grid_line_width_pixels` | Grid width, clamped to `0.1…8` native pixels |
| `stage.grid_color` | `stage_grid_color` | Grid color, including alpha |
| `stage.date_visible` | `stage_date_visible` | Date-time-label visibility |
| `stage.temperature_visible` or `temperature.visible` | `temperature_visible`, `stage_temperature_visible` | Append/remove the measured-temperature suffix in `StageTitle` |
| `temperature.data_path` or `stage.temperature_data_path` | `temperature_data_path` | Load the shared temperature table and align it to the current timeline |
| `temperature.data_column` or `stage.temperature_data_column` | `temperature_data_column` | Select the Celsius series by exact header name |
| `calendar.date` or `stage.date` | `model_date` | Set the process-wide `MM/DD-HH:MM` (or date-only `MM/DD`); disables auto-advance |
| `calendar.day_index` | `model_day_index` | Set the process-wide day `0…364`; disables auto-advance |
| `calendar.auto_advance` | `model_calendar_auto_advance` | Select process-wide internal-clock or externally held mode |
| `calendar.year_duration_seconds` | `model_year_duration_seconds` | Set the shared year duration, clamped to `1…86400` seconds while preserving phase |
| `calendar.start_day_index` | `model_start_day_index` | Set the shared reset/start day `0…364` and reset the calendar |
| `watershed.data_path` | `watershed_data_path` | Load a pipeline text file and align it to the current timeline |
| `watershed.drives_flow_rate` | `watershed_data_drives_flow_rate` | Enable/disable data control of water `flow_rate` |
| `watershed.interpolate_flow_rate` | `watershed_interpolate_flow_rate` | Lerp adjacent `norm` rows or hold each current row |
| `regimes.active_names` | `active_regimes` | Replace the shared active set from regime names/IDs |
| `regimes.active_indices` | none | Replace the shared active set from zero-based indices `0…6` |
| `regimes.kinship` | none | Set Kinship active/inactive |
| `regimes.agriculture` | `regimes.ranch` | Set Agriculture active/inactive |
| `regimes.gold_rush` | none | Set Gold Rush active/inactive |
| `regimes.water_projects` | none | Set Water Projects active/inactive |
| `regimes.hydropower` | none | Set Hydropower active/inactive |
| `regimes.tech` | none | Set Tech active/inactive |
| `regimes.watershed` | none | Set Watershed active/inactive |
| `shoreline.randomness` | `shoreline_randomness`, `shorelines.randomness` | Directly set this stage's top/bottom edge-turbulence amount `0…1`; the next shared regime change reapplies the normalized profile value |

The fleet controller always sends visible geometry to every configured screen
and exposes no geometry-hiding option. The controller saves no state; `start`
and `restart` restore Kinship with visible geometry.

Presentation paths do not change `screen_id`, `model_id`, debug visibility, or
water occupancy. Calendar paths mutate the shared `ModelTimeline` and are
reflected by every active stage; they still do not rebuild particles or retune
salmon/leaves. Regime paths mutate the process-wide `ModelRegimes` set and are
reflected by every active or subsequently loaded stage. `regimes.active_names`
and `regimes.active_indices` replace the complete set atomically; each
`regimes.<id>` boolean changes one member without disturbing the others.
Watershed paths can change the local river's water rate. The date signal remains
`model_date_changed(screen_id, date_mm_dd, day_of_year)` and reports the
date-only value when the day changes. Each data-row transition emits
`watershed_data_row_changed` with row index/count, `raw_value`, `normalized_flow`,
`scaled_flow`, `high_variation`, and canonical `model_date_time`.

### Watershed AI visual state

The `watershed-ai/2` scope is a visual simulator boundary, not a real-world
control interface. It cannot operate dams, gates, pumps, diversions, or other
infrastructure. It accepts one explicit canonical `screen_id` at a time and
only when the process-wide active regime set is exactly `[6]`; both the shared
bus and the addressed GPU stage validate that condition before application.
The named screen must resolve to exactly one loaded GPU stage.

The packet contains exactly one `watershed.ai.state` change, empty `actions`
and `geometry_ops`, and the complete state fields below:

```text
schema_version, decision_id,
atmospheric_input_rate, reservoir_release_rate, available_supply_rate,
extraction_fraction, remaining_rate, salmon_fraction, floodplain_fraction,
agriculture_fraction, data_center_fraction, city_fraction,
reservoir_storage_fraction, hydropower_fraction, water_project_fraction
```

`schema_version` must be `2`, `decision_id` must contain 1–128 characters, and
all other values must be finite numbers in `0..1`. Allocation shares must sum
to one; extraction must equal agriculture + data centers + city; available and
remaining rates must close the budget; hydropower and water projects must both
be zero. Missing, extra, invalid, or non-finite values reject the state atomically. The scoped envelope accepts no
top-level fields beyond `protocol`, optional `revision`, `control_scope`,
`target`, `changes`, `geometry_ops`, `actions`, and `metadata`, and requires a
nonempty `metadata.request_id` of at most 128 characters.

For convergence, compute the lowercase SHA-256 digest of these exact UTF-8
lines joined by `\n`, with no trailing newline and exactly nine fractional
digits; `decision_id` is not part of the hash:

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

Retry the same absolute state until
`recipient_watershed_ai_state[screen].applied_decision_id` and
`.applied_state_hash` match the decision and locally computed digest. The
per-screen ACK also includes `current_observation` with flow, model time,
watershed row, temperature, gate, and regime state. Identical ID/hash retries
are no-ops; an ID reused with different state is rejected; a new ID with the
same state updates acknowledgement without repeating GPU work.

Applied values derive the reservoir, bounded drain/obstacle banks, explicit
field/data-center rectangles, and Delta floodplain area. Exiting exclusive Watershed mode removes the overlay and
restores captured data-drive, flow, authored gate, and the newly active
authored/profile/timeline behavior.

### Regime-switch runtime cost

A regime switch mutates the resident stage in place; it does not instantiate a
new stage or resize the water, salmon, or leaf pools. An identical replacement
active set is idempotent and does not publish another `ModelRegimes` change, so a
replayed absolute controller state does not repeat feature, panel, ecology, or
gate-schedule work. Ecology and regime-driven gate schedules are reevaluated only
when the model day or active regime set changes. Kinship's defined zero drain and
obstacle budgets disable both generic polygon-interaction shader passes while
leaving its full edge-turbulence field active.

Every real regime revision advances `reservoir_geometry_revision` before
applying the new center. Retained reservoir heads are released in place into
downstream flow before new-center reservoir physics begins; their old orbit
trails remain immutable and fade normally. Placement of the reservoir and
bounded feature banks runs only on initial stage hydration or a real regime
transition. Each real active-set transition advances the layout generation and
gives the resident drains and obstacles fresh positions; an identical absolute
set is a no-op and does not reroll them. Placement performs no per-frame work
and creates no nodes, resources, particle pools, or extra reservoir slots. The
renderer therefore still draws at most one physical reservoir even when desired
`reservoir_count=2`.

The edge-turbulence path is a bounded uniform calculation in the water-head
shader. It uses no bank texture and performs no shoreline segment scan or
swept-polygon collision. Regime changes upload the new amount to the seven
resident water materials; they do not rebuild geometry or narrow the inlet.

Salmon and leaves each use a 300-slot circular release-control pool. New release
commands overwrite old slots without creating particles or textures; salmon's
trail pool is also preallocated, and leaves have no trail pool. The standalone
smokes include 2,000 salmon releases and 500 two-bank leaf releases and assert
stable particle amounts, node/resource counts, control dimensions, and material
and texture RIDs. These bounds do not predict frame rate on a particular GPU.
For deployment, soak the full 12-minute model year with regime/ecology changes on
the oldest target Mac, monitor frame pacing and memory, and run only one Godot PID
on each dedicated renderer Mac.

`runtime_summary()` exposes the complete presentation contract. Grid fields are
`stage_grid_visible`, `stage_grid_spacing_pixels`,
`stage_grid_line_width_pixels`, `stage_grid_color`, `stage_grid_z_index`, and
`stage_grid_line_count`. Date fields are `stage_date_visible`,
`stage_date_text`, `stage_date_format`, `stage_date_position`, `stage_date_color`,
`stage_date_font_size`, `stage_date_font_resource`, `stage_date_z_index`,
`stage_date_position_anchor`, `stage_date_rotation_degrees`,
`stage_date_tabular_numerals`, and `stage_date_opentype_feature`.
Regime fields are `regime_state_shared`, `regime_state_scope`, `regime_names`,
`regime_ids`, `regime_active_states`, `active_regime_indices`,
`active_regime_names`, `active_regime_count`, `regime_revision`,
`regime_panel_visible`, `regime_panel_position`,
`regime_panel_rotation_degrees`, `regime_heading_text`,
`regime_heading_font_size`, `regime_name_font_size`,
`regime_name_row_height`, `regime_active_alpha`, `regime_inactive_alpha`, and
`regime_panel_z_index`.
Profile fields are `regime_profile_path`, `regime_profiles_loaded`,
`regime_profile_count`, `regime_profile_reload_revision`,
`regime_profile_diagnostics`, the legacy `regime_effective_features`,
`regime_effective_feature_state_by_screen`,
`regime_active_schedules_by_screen`, and the current screen's
`regime_effective_feature_state`. Applied-physics fields include
`regime_profile_physics_enabled`, `regime_applied_feature_budgets`,
`regime_applied_feature_overrides`, `regime_feature_presence`,
`regime_gate_open_fraction`,
`regime_reservoir_count_desired_raw`, `regime_reservoir_count_rendered`,
`regime_reservoir_renderer_capacity`, `regime_geometry_mode`,
`regime_layout_generation`, `regime_layout_active_signature`,
`regime_geometry_keys`, `regime_geometry_update_count`,
`regime_geometry_undefined_fallback`, `regime_geometry_mixed_contributors`, and
`regime_geometry_preserves_particle_pools`. The bounded feature-bank fields are
`regime_feature_slot_capacities`, `regime_feature_slot_counts_desired`,
`regime_feature_slot_counts_rendered`, `regime_feature_slot_counts_resident`,
and `regime_feature_controller_spare_capacity`. They distinguish the profile's
requested count from the enabled regime-bank count, report the resident startup
banks, and expose the one spare interaction controller slot. Bank-field
diagnostics additionally include `regime_field_bank_layouts`,
`regime_field_bank_counts`, `field_turn_mode`,
`bank_field_suction_reach_pixels`,
`bank_field_suction_crossflow_ratio`, `bank_field_suction_streamwise_ratio`, and
`bank_field_min_withdrawal_speed_pixels`, and
`bank_field_capture_depth_pixels` plus their seven-layer uniform mirrors.
Bank extractors use a 720 px reach, a 3.0 lateral-flow multiplier, and a
720 px/s minimum withdrawal speed, so an active intake pulls visibly from the
river centerline before turning captured trails through its bank mouth.
`regime_geometry_mode` reports `GENERATION_SALTED_BOUNDED_SLOT_BANKS`.
Reservoir placement fields are
`reservoir_center_pixels`, `reservoir_center_pixels_authored`,
`reservoir_geometry_revision`, and `reservoir_geometry_revision_uniforms`.
Shoreline fields are
`shoreline_effect_mode`, `shoreline_randomness`, `shoreline_count`,
`shoreline_vertex_count`,
`shoreline_ids`, `shoreline_obstacles`, `shoreline_data_texture_bound`,
`shoreline_data_texture_size`, `shoreline_count_uniforms`,
`shoreline_texture_bound_uniforms`, `shoreline_inlet_y_range_pixels`,
`shoreline_inlet_y_range_uniforms`, `shoreline_overlay_count`, and
`shoreline_preserves_interaction_capacity`. `shoreline_effect_mode` reports
`EDGE_TURBULENCE`; the legacy geometry/texture fields report zero/empty/unbound
and the inlet reports the full range. Edge-field diagnostics are
`edge_turbulence_amount`, `edge_turbulence_band_pixels`,
`edge_turbulence_wall_band_pixels`, `edge_turbulence_crossflow_ratio`,
`edge_turbulence_streamwise_ratio`, `edge_turbulence_inward_ratio`,
`edge_turbulence_amount_uniforms`, `edge_turbulence_band_uniforms`,
`edge_turbulence_wall_band_uniforms`, and
`edge_turbulence_parameter_upload_count`.
Clock fields are `model_day_index`, `model_day_of_year`,
`model_minute_of_day`, `model_elapsed_seconds`, `model_year_progress`,
`model_year_duration_seconds`, `model_year_frames_at_30_fps`,
`model_year_minute_count`, `model_calendar_day_count`,
`model_calendar_auto_advance`, `model_calendar_source`, and
`model_start_day_index`. Watershed fields are `watershed_data_path`,
`watershed_data_loaded`, `watershed_data_error`, `watershed_data_river`,
`watershed_data_row_count`, `watershed_data_row_index`,
`watershed_data_row_fraction`, `watershed_data_drives_flow_rate`,
`watershed_interpolate_flow_rate`, `watershed_interpolated_flow_rate`,
`watershed_flow_percent`, `watershed_row_duration_seconds`,
`watershed_model_minutes_per_row`, and `watershed_current_row`. The current-row
dictionary contains `row_index`, `row_count`, `raw_value`, `normalized_flow`,
`scaled_flow`, `high_variation`, `interpolated_flow_rate`, `row_fraction`, and
`model_date_time`. The title namespace additionally exposes
`stage_title_display_text`, `stage_title_font_instance_id`,
`stage_title_tabular_numerals`, `stage_title_opentype_feature`,
`stage_title_temperature_integrated`, and
`stage_title_temperature_visible`. The complete water-temperature namespace is
`water_temperature_visible`, `water_temperature_text`,
`water_temperature_value_c`, `water_temperature_value_valid`,
`water_temperature_position`, `water_temperature_position_anchor`,
`water_temperature_rotation_degrees`, `water_temperature_color`,
`water_temperature_font_size`, `water_temperature_font_resource`,
`water_temperature_font_shared_with_date`,
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
`water_temperature_outside_water_viewport`. `water_temperature_node_path`
resolves to `StageTitleLayer/StageTitle`; no separate temperature node is
created. Presentation also has the
stage-family aliases `stage_temperature_visible`, `stage_temperature_text`,
`stage_temperature_value_c`, `stage_temperature_position`,
`stage_temperature_position_anchor`, `stage_temperature_rotation_degrees`,
`stage_temperature_color`, `stage_temperature_font_size`,
`stage_temperature_font_resource`, `stage_temperature_tabular_numerals`,
`stage_temperature_opentype_feature`,
`stage_temperature_integrated_with_stage_title`, and
`stage_temperature_z_index`. Layer
assertions are `background_z_index`,
`stage_title_z_index`, `stage_title_below_animated_features`,
`stage_grid_above_background`, and `stage_text_above_grid`. The occupancy
exclusion flags are `water_texture_excludes_background`,
`water_texture_excludes_stage_grid`, `water_texture_excludes_debug_overlay`,
`water_texture_excludes_stage_title`, `water_texture_excludes_stage_date`,
`water_texture_excludes_stage_temperature`, and
`water_texture_excludes_regime_panel`.

## Runtime API

```gdscript
stage.set_gate_open(&"reservoir_main", false)
stage.set_gate_width(&"reservoir_main", 0.50)
stage.toggle_gate()
stage.set_paused(true)
stage.set_debug_visible(false)
stage.set_runtime_parameter(&"noise_strength", 60.0)
stage.set_runtime_parameter(&"stage.title", "Mill Creek")
stage.set_runtime_parameter(&"stage.title_visible", true)
stage.set_runtime_parameter(&"stage.regime_panel_visible", true)
stage.set_runtime_parameter(&"stage.grid_visible", true)
stage.set_runtime_parameter(&"stage.date_visible", true)
stage.toggle_regime(0) # Kinship; all regime indices are zero-based
stage.set_regime_active(1, true) # Agriculture; preserves the other toggles
stage.set_active_regime_names(["Gold Rush", "Tech"]) # replaces the active set
var regime_state := stage.get_regime_state()
stage.set_runtime_parameter(&"regimes.active_indices", [0, 2, 6])
stage.set_runtime_parameter(&"regimes.water_projects", true)
stage.set_runtime_parameter(&"shoreline.randomness", 0.4) # direct diagnostic override
stage.set_model_date_time("12/21-06:30") # global; disables auto-advance
stage.set_model_calendar_auto_advance(true) # global; resumes shared clock
stage.reset_model_calendar()         # global calendar only; no particle reset
stage.set_runtime_parameter(&"watershed.drives_flow_rate", false)
stage.set_flow_rate(0.75)            # manual override; also disables data drive
stage.set_runtime_parameter(&"watershed.drives_flow_rate", true)
var watershed_row := stage.get_current_watershed_data_row()
stage.apply_runtime_parameters()
stage.release_salmon()       # schedules the default batch of 25
stage.release_salmon(40)     # explicit batch, maximum 300
stage.release_leaves()       # schedules 15 top + 15 bottom; returns 30
stage.release_leaves(8)      # schedules eight top + eight bottom; returns 16
var occupancy := stage.get_water_texture()
```

The stage API forwards regime changes to `ModelRegimes` through
`toggle_regime(index)`, `set_regime_active(index, active)`,
`set_active_regime_names(names)`, and `get_regime_state()`. Code that addresses
the autoload directly may additionally call `set_regime_active_by_id(id,
active)`, `set_active_indices(indices)`, `clear_regimes()`, or `snapshot()`.
Both index APIs are zero-based and all replacement setters validate the entire
input before publishing a change. `regimes_changed` carries the shared snapshot;
the stage's forwarded signal adds its `screen_id`, active names, active indices,
and revision.

Gate width is the **full outlet width in the CPU model's 16 x 9 world units**.
The default `0.25` is 30 native pixels wide. `set_gate_open(true)` and the
prototype-era pixel helper `set_gate_half_width(15.0)` also remain valid. The
effective maximum is always the live reservoir diameter; keyboard and
controller values beyond that diameter clamp to the exact `1.0` aperture.

### GPU interaction polygons

`GPUFlowInteractionPolygon` is the production stage's unified addressable
polygon for partial absorption and soft repulsion. A stage supports at most
eight polygons, with at most 12 vertices in each polygon. Controller vertices
use the same 16 x 9, Y-up world as the CPU model; the stage converts each point
to the native 1920 x 1080 canvas as `(x * 120, (9 - y) * 120)`.

An opted-in production stage allocates a fixed regime bank at startup: five
drain/field polygons and two obstacles. Those seven resident resources leave
one of the eight interaction records available to controller geometry. Inactive
internal bank members remain resident but are omitted from the packed GPU
records. A real active-set transition changes their enabled state and generates
fresh placement in the same resident resources; repeating an identical absolute
set leaves them untouched.

Every polygon has these mutable fields:

- `mode`: `"absorb"` or `"repel"`
- `vertices`: three through 12 points forming a simple, nondegenerate polygon
- `absorption_fraction`: `0.0` through `1.0`
- `repellent_force`: `0.0` through `1.0`
- `wave_strength`: `0.0` through `1.0`
- `influence`: a nonnegative world-space distance outside the polygon
- `enabled`: whether the polygon participates in simulation

The stable `element_id` is addressable but immutable. Use a new ID when an
object's identity must change. IDs are unique across both modes because all
kind aliases address one interaction array. With debug geometry visible, both
modes have a gold outline; disabled polygons remain visible with a faint
outline so their configuration can still be inspected.

The controller accepts `upsert` (`add` and `update` aliases), `remove`
(`delete` alias), and `replace` operations. `polygon` is the canonical kind;
`interaction`, `absorber`, `obstacle`, and `repeller` are accepted aliases,
including their plural forms. Matching is case-insensitive. Whole-set `replace`
is accepted only with the neutral `polygon`/`interaction` kinds, so a mode alias
cannot accidentally erase objects of the other mode.
When an alias supplies no explicit mode, `absorber` selects `absorb` and
`obstacle`/`repeller` select `repel`.

```json
{
  "geometry_ops": [
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
  ]
}
```

Mutable fields can also be set through `changes` as
`polygon.<id>.<field>`, for example:

```json
{
  "changes": {
    "polygon.intake_west.absorption_fraction": 0.8,
    "polygon.intake_west.wave_strength": 0.1
  }
}
```

Regime-owned drain/field polygons are bank-connected rectangles, not interior
absorbers. One horizontal edge coincides with the top or bottom screen edge and
the opposite river-facing edge lies inside the channel. The shader makes one deterministic
accept/reject choice for the complete drain/field feature cohort and global
particle lifecycle, so adding more field polygons does not compound the
regime-wide fraction. An accepted nearby head is pulled toward a point inside
the strongest mouth; probability chooses the cohort and does not weaken the
motion of heads already accepted. After a swept mouth crossing, the shader
removes the remaining downstream component and records a sharp 90-degree turn
toward the top or bottom bank at a minimum 540-pixel/second withdrawal speed.
The trail runs through the rectangle and off the corresponding screen edge,
then recycles only after its immutable history has faded. Root and side edges
never admit water, and no head teleports to a field center.

Freeform controller absorbers retain the legacy swept-entry behavior through an
upstream-facing edge whose outward normal points toward -X. An accepted head
stops just inside that edge while its trail fades; a rejected head receives one
Y wave impulse and continues downstream. Obstacles use the corresponding
feature-wide obstacle cohort.

Repulsion acts on heads only. It applies a soft redirect within the configured
influence distance and a swept boundary correction when a fixed step would
cross the polygon, so a head cannot tunnel through a thin object. Immutable
trail segments never run either interaction again.

When `install_default_interaction_examples` is enabled and the configured
interaction array is empty, the stage installs `absorber_test` and
`repeller_test`. Supplying any interaction polygon prevents those examples from
being added.

## GPU salmon

`GPUSalmon2D` is a separate 300-slot GPU system drawn above the water and
outside `WaterOnlyViewport`. Pressing `S`, calling `release_salmon()`, or sending
the `release_salmon` controller action schedules 25 fish by default. An explicit
count may be from 1 through 300. The action forms are:

```json
"actions": ["release_salmon"]
```

```json
"actions": [
  {"name": "release_salmon", "arguments": {"count": 40}}
]
```

Each release selector searches the right edge of the current water-only texture
and starts on visible water. If no qualifying water exists yet, the slot stays
invisible and retries instead of discarding the release. Swimming is upstream
from right to left. Salmon use reversed flow/noise plus occupancy steering, so
their short trails curve with the river instead of remaining straight.

The default water-contact footprint is a centered 240 x 24 native-pixel
rectangle: `salmon.contact_width_pixels = 240` and
`salmon.contact_height_pixels = 24`. The same fixed occupancy field establishes
contact and selects a complete 2D swim direction toward occupied samples behind
the fish. The score strongly favors continuity with its current heading and
adds a smaller upstream bias, so nearby bends can change both X and Y without
making the fish jump between streams. `salmon.water_alpha_threshold` defaults
to `0.001`, so any meaningfully nontransparent water pixel qualifies as water.
Once contact falls below that threshold, the loss is latched and later water
contact cannot revive that release generation. For the configured
`salmon.fade_seconds = 0.5`, the head continues in its last direction with
exponential damping and emits a short, rolling trail whose alpha diminishes
continuously to zero. The salmon API and defaults are otherwise unchanged.

The visible salmon are 100-pixel immutable curved trails, three pixels wide,
using `#FF5C8A`, `#FF7A72`, `#FF8C42`, `#FFAD33`, and `#FFD23F`. Their runtime
paths are:

- `salmon.enabled`
- `salmon.per_release`
- `salmon.min_speed_pixels`
- `salmon.water_alpha_threshold`
- `salmon.contact_width_pixels`
- `salmon.contact_height_pixels`
- `salmon.water_steering_strength`
- `salmon.trail_length_pixels`
- `salmon.line_width_pixels`
- `salmon.fade_seconds`
- `salmon.alpha`
- `salmon.occupancy_flip_y` (default `false`; platform/debug fallback only)

`salmon.min_speed_pixels` (inspector export `salmon_min_speed_pixels`) defaults
to `60`. Salmon follow the live water flow speed above that floor, while the
floor keeps a 100-pixel trail's lifetime and preallocated GPU segment pool
bounded when water flow approaches zero.

The CPU writes only a small release-generation/control texture. Head movement,
right-edge lane search, water contact, latching, fade state, and trail emission
stay on the GPU, and no active-particle state is read back. During a latched
loss, the damped head keeps emitting progressively fainter immutable segments
for the full fade interval, so the 0.5-second loss is visible in the trail
itself. Older samples retain their own short spatial lifetime and age out
normally.

The salmon draw shader interpolates age over `UV.x` across one 30 Hz sample
interval. Adjacent segment endpoints therefore share the same alpha instead of
showing fixed-alpha steps or bands in the faint tail.

## GPU leaves

`GPULeaf2D` is a separate 300-slot GPU system drawn at absolute Z index `10`,
above the water and outside `WaterOnlyViewport`. Pressing `L`, calling
`release_leaves()`, or sending the `release_leaves` controller action schedules
15 leaves from the top edge and 15 from the bottom edge by default. Each cohort
retains one sample in every stratified X lane across the complete width, but a
separate deterministic shuffle assigns those lanes to launch times for each
bank. X position is therefore decoupled from the stagger order instead of
marching visibly from left to right. The public method's argument is a per-side
count from 1 through 150, and its return value is the total scheduled across
both sides:

```gdscript
stage.release_leaves()       # 15 top + 15 bottom, returns 30
stage.release_leaves(20)     # 20 top + 20 bottom, returns 40
```

Controller actions may use the default as a string or provide a per-side count
as a dictionary. `arguments.count` is accepted as an alias for
`arguments.count_per_side`:

```json
"actions": ["release_leaves"]
```

```json
"actions": [
  {"name": "release_leaves", "arguments": {"count_per_side": 20}}
]
```

A release does not place all 30 heads on the banks at once. Its deterministic
schedule alternates top, bottom, top, bottom. The base gap is `0.20` seconds,
and every successive gap receives a stable multiplier from `0.55` through
`1.45`, producing irregular `0.11…0.29`-second spacing without changing on
replay. The default 15-plus-15 batch spans about `5.93` seconds, approximately
twice its former maximum delay. X-lane shuffling uses a different deterministic
mix than the gap sequence. The CPU writes all absolute delays once into the
second row of the fixed 300 x 2 control texture; a GPU-only scheduled state
counts them down. There are no per-leaf CPU timers or particle readback.

Each free leaf begins at its originating top or bottom edge and searches while
moving inward at 120 native pixels per second. Its horizontal sway has a stable
random amplitude from 2 through 6 pixels and a stable random period from 1.2
through 2.8 seconds. Every frame, a 17 x 17 sample grid searches the forward or
inward portion of a 120-pixel-radius 2D vicinity. Backward samples toward the
originating bank are rejected. When water is nearby, the leaf blends 35% toward
the selected sample while retaining a guaranteed inward component. This lets a
near miss adjust its course instead of testing only the original vertical line.
If it has not touched water after traveling 256 pixels inward from its bank, it
enters `STOPPED_FADING`: the disk freezes and retires after a 0.5-second opacity
fade instead of crossing the rest of the screen.

The default contact test samples a 12-pixel-radius disk around the head and
accepts water alpha at or above `0.001`. Contact makes one irreversible,
position-preserving transition from free motion to water-following motion. Every
accepted leaf initially turns downstream at 300 native pixels per second. It
caches a local water heading and resamples that heading every `0.12` seconds,
with a stable per-leaf phase so all leaves do not probe on the same frame. Each
8-to-56-pixel probe fan is centered on the cached heading and may turn up to 35
degrees from that local direction. At several radii it combines center samples
with lower-weight flank samples, then scores that water support together with
strong heading continuity and a smaller +X bias. This wider supported vicinity
helps a leaf anticipate a bend while remaining on one water path. Because each
accepted turn becomes the next cached heading, turns accumulate around
reservoir curves without restoring frame-by-frame wandering. The default
velocity response is `8.0`.
Attachment never returns to the free state, including across temporary alpha
gaps, and an attached leaf retires only after its complete disk clears the right
edge.

Leaves are head-only filled disks using the colors `#8C3F0A`, `#A95412`,
`#C47A12`, `#C29A18`, `#8A8F2A`, `#4F772D`, and `#365F32`. Their base diameter
is 10 pixels, or a 5-pixel radius. A stable per-generation size factor from
`1.0…2.0` produces diameters of 10…20 pixels, or radii of 5…10 pixels. The head
transform owns that diameter and the draw shader applies a soft antialiased
radial edge to a single white texel. Leaves emit no motion segments and
allocate no trail pool. When a missed
leaf enters `STOPPED_FADING`, its disk remains fixed while its opacity falls to
zero over the configured interval.

The CPU writes only release generations, absolute delays, independently
shuffled stratified X selectors, palette indices, and top/bottom-origin codes
into the fixed control texture. Position, size, contact, irreversible
attachment, water following, and stopped-fade opacity stay on the GPU; no
particle state or rendered image is read back.

Production leaf paths and defaults are:

| Path | Default | Meaning |
|---|---:|---|
| `leaves.enabled` | `true` | Enables visible leaves and release handling |
| `leaves.per_side` | `15` | Default count from each of the top and bottom edges |
| `leaves.release_stagger_interval_seconds` | `0.20` | Base gap for alternating top/bottom scheduled starts; fixed multipliers produce 0.11…0.29-second gaps and an approximately 5.93-second default span |
| `leaves.free_speed_pixels` | `120` | Unattached vertical speed |
| `leaves.flow_speed_pixels` | `300` | Attached downstream speed |
| `leaves.speed_variation` | `0.0` | Per-leaf speed variation |
| `leaves.velocity_response` | `8.0` | Smoothing toward the cached local water heading |
| `leaves.sway_amplitude_min_pixels` | `2` | Minimum free-flight horizontal sway amplitude |
| `leaves.sway_amplitude_max_pixels` | `6` | Maximum free-flight horizontal sway amplitude |
| `leaves.sway_period_min_seconds` | `1.2` | Minimum free-flight sway period |
| `leaves.sway_period_max_seconds` | `2.8` | Maximum free-flight sway period |
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
| `leaves.occupancy_flip_y` | `false` | Platform/debug fallback for an inverted viewport texture |
| `leaves.disk_radius_pixels` | `5` | Canonical base visual radius for the head-only disk |
| `leaves.radius_variation` | `1.0` | Canonical one-sided deterministic radius variation, range 0…1; base × 1.0…2.0 gives radii of 5…10 pixels |
| `leaves.line_width_pixels` | `10` | Compatibility diameter control; equivalent to twice `disk_radius_pixels` |
| `leaves.line_width_variation` | `1.0` | Compatibility alias for `radius_variation` |
| `leaves.alpha` | `1.0` | Global leaf alpha |

`leaves.contact_radius_pixels` controls water detection and is independent of
the smaller visual `leaves.disk_radius_pixels`. Pause/resume sets the leaf head
pool's speed scale, and the stage's `reset` action clears all leaf release
generations and visible disks.
`reset_leaves()` followed immediately by a new release is valid even while the
stage is paused.

## Water immutable segment trails

For water, the moving head is only the simulation state. The particle-process
shader—not the CanvasItem draw shader—calculates every head position from
runtime flow and geometry values. The draw shader is rendering-only: it turns
completed segment transforms into width, color, antialiasing, and alpha fade.
After the particle
process shader completes the head's ordinary flow, wave, reservoir, gate,
interaction-polygon, and final position corrections for a fixed step, it emits
one child segment spanning the previous completed position to the new completed
position. That child segment is stationary: it does not run flow, wave,
reservoir, absorption, or repulsion physics again, and it fades independently
for two seconds. The visible trail is therefore a collection of literal path
segments rather than a native history strip whose old samples can move later.

Segment-pool capacity is calculated as:

```text
ceil(particle_slots * 30 updates/second * trail_lifetime * 1.25)
```

At the defaults, `ceil(1000 * 30 * 2.0 * 1.25)` is 75,000 slots per stage.
Changing flow rate does not resize the pool while visible segments are using
it; changing particle-slot count or trail lifetime updates the required capacity.

## Stable trail depth

Godot does not preserve a useful per-particle Z coordinate inside one
`GPUParticles2D` pool. Its recycled GPU slots can therefore change which of two
differently colored segments is composited last, producing an alternating
over/under pattern at overlaps. The production stage avoids that unstable slot
order by assigning each of the seven palette colors to a separate CanvasItem
layer with absolute `z_index` values `0` through `6`. White is the rear layer
and the darkest blue is the front layer, so different colors now have a fixed
stacking order for their full lifetime.

The global particle identity is interleaved across those layers. At the default
1,000 slots, head allocations are `[143, 143, 143, 143, 143, 143, 142]`.
Segment capacities are `[10725, 10725, 10725, 10725, 10725, 10725, 10650]`,
totaling 75,000. Runtime flow changes use the same global threshold, so splitting the
renderer does not change the requested population or the deterministic path
seeds. Segments within one layer share the same RGB color; their alpha blending
is visually order-independent, so they do not need one node per trail.

`emit_subparticle()` can briefly reject an append while reusable GPU slots
change generation. The head advances its stored trail anchor only after a
successful append. If one append is rejected, the next segment spans both
samples, repairing the interval instead of preserving a fixed-size hole.

`trail_segment_max_length_pixels` is a hard discontinuity bound and defaults to
`96.0`. If one completed head step is longer than 96 pixels, no segment is
emitted for that step, so a visible gap appears instead of a long chord between
unrelated positions. `trail_segment_overlap_pixels` defaults to `0.0`; raise it
slightly only if a target GPU shows subpixel seams, since excessive overlap can
make the 30 Hz junctions brighter through alpha overdraw. It adds
a small overlap between normal adjacent segments to hide raster seams.

This ordering is important around the reservoir: the wave and reservoir can
change where a head finishes its current step, and can change its future
motion, but they cannot rewrite, pull, reconnect, or disconnect trail segments
that were already emitted. Existing tail history remains fixed even if runtime
wave or reservoir parameters change.

The head positions use a sixteen-second startup prewarm so even the slowest
center-originating flow opens with water distributed across the screen.
Both reservoir admission and segment recording are held off during that
prewarm. Heads which pass the reservoir are
latched as bypasses, so turning admission on after prewarm cannot reconsider
them and cannot begin with a prefilled reservoir. The river therefore opens
distributed while the reservoir opens empty. Segment recording remains off
because the child pool cannot age prewarm emissions in lockstep. The immutable
tails grow cleanly to their full two-second length just after launch instead of
opening with disconnected prewarm fragments.

Reservoir capture is clipped to its vertical diameter. A configurable buffer
at its top and bottom prevents adjacent lanes from being classified as
marginal entries. Tune the active height with
`reservoir_capture_y_ratio` (`0.05`–`1.0`) and the buffer with
`reservoir_capture_edge_softness_pixels` (`0`–`120`). Controller geometry uses
`reservoir.reservoir_main.capture_y_ratio` and
`reservoir.reservoir_main.capture_edge_softness` (world units).

Admission is an upstream-only, one-shot decision. Before any reservoir force
is visible, every +X head crosses a decision plane at least 32 pixels upstream
of the influence field. The shader interpolates the exact fixed-step crossing
and classifies its Y position once: accepted heads latch as `ENTERING`; rejected
heads latch as `BYPASSING` and cannot be reconsidered closer to the center.
`reservoir_entry_min_incidence` defaults to `0.50`; `0.0` admits tangent-edge
positions and `1.0` approaches centerline-only capture. Its controller alias is
`reservoir.reservoir_main.entry_min_incidence`.

Accepted heads blend into a stronger radial entry pull as they cross the
influence field, then become fully retained at the physical rim. Tune the pull
with `reservoir_entry_pull_strength` (default `3.50`, range `0`–`8`); its
controller alias is `reservoir.reservoir_main.entry_pull_strength`. A swept
segment/rim test preserves the same transition even when a very small reservoir
or unusually high runtime speed would cross the circle between 30 Hz samples.

After admission, `reservoir_entry_min_inward_speed_ratio` guarantees that the
head keeps at least `0.30` of its flow speed toward the reservoir center. The
wave can still curve the approach, but it cannot reverse entry or push a
committed head back out near the influence edge. The constraint fades at the
head's assigned orbit radius; set it to `0.0` to restore unconstrained entry.
Its controller alias is
`reservoir.reservoir_main.entry_min_inward_speed_ratio`.

Reservoir retention is a head-only, one-way state transition. Once admitted,
the head remains owned by the reservoir and cannot return to ordinary flow or
cross back through the rim. Its only exit is a successful release at the open
gate. Gate selection now enters an owned `GATE_STAGING` phase. The assigned
orbit expands smoothly to `reservoir_gate_staging_radius_ratio` (default
`0.86`). Selection commits the head immediately: it starts a continuous outward
spiral with no release timer or trail-lifetime dwell. Position is never
teleported. Once it physically reaches the outer staging ring, it continues only
as far around that ring as needed to meet the downstream aperture, enters the
short `EXITING` corridor, and becomes `RELEASED` after crossing the rim.

The staging controller alias is
`reservoir.reservoir_main.gate_staging_radius_ratio`. Aperture width directly
sets release probability as `gate half-width / reservoir radius`, which is the
same as full opening width divided by reservoir diameter. A closed or zero-width
gate has probability `0.0`; an opening as wide as the diameter has probability
`1.0`; intermediate widths interpolate linearly. There is no separate release
probability control: the `[` and `]` aperture setting is the probability. A gate
that closes while a selected head is travelling holds it on the outer ring
until reopening. At full aperture, release is a hard drain: every retained head
is selected without waiting to reach the ordinary outlet-approach window or
orbit-settling tolerance. Minimum outward and tangential transport, a bounded
staging fallback, and a deterministic direction at the exact reservoir center
prevent zero-speed or numerical edge cases from remaining trapped. A released
head bypasses reservoir forces for one full segment fade lifetime and until it
is downstream of the influence field. Its immutable alpha-faded segments
record the released head's path through the outlet; they cannot be captured
separately or leave an old loop parked in the reservoir.

The debug wall uses the exact same aperture fraction. It no longer visually
saturates at `0.95`; the downstream wall reaches the top and bottom of the
circle only when the effective aperture and release probability are truly
`1.0`. With continuing inflow, a nearly full gate can show a steady cluster as
newly admitted heads replace those leaving. The hard-drain state is reserved
for the diameter-wide setting.

The production GPU reservoir does not have a separate retention pool. Every
retained head continues to occupy one of the stage's fixed 1,000 active
water-head slots until it exits. A closed or high-capture reservoir can
therefore temporarily thin ordinary inlet lanes. If every active slot is
retained, no new ordinary inlet lifecycle can begin until a head is released
and recycled. This is bounded slot occupancy, not a memory leak or rendering
failure.

Every ordinary lifecycle restart mixes that slot's lifecycle generation into
its inlet-lane seed. A recycled slot can therefore reappear in a different Y
lane and refill a band that was previously starved, rather than returning
forever to the same lane. Lifecycle reseeding redistributes freed slots; it
cannot create capacity while slots remain retained.

Retained heads now circulate across the reservoir rather than only around its
edge. `reservoir_orbit_radius_min_ratio` defaults to `0.05` and
`reservoir_orbit_radius_max_ratio` defaults to `0.78`, so seeded paths range
from near the center to the existing outer band. Their controller aliases are
`reservoir.reservoir_main.orbit_radius_min_ratio` and
`reservoir.reservoir_main.orbit_radius_max_ratio`; reversed values are sorted
by the shader. Orbit placement has its own deterministic seed, independent of
inlet height, so capture geometry cannot accidentally remove the inner paths.
Inner paths reduce tangential speed in proportion to radius until
`reservoir_orbit_full_speed_ratio` (default `0.46`) and are capped by
`reservoir_orbit_max_angular_speed` (default `1.50 rad/s`). This keeps tight
center paths smooth at 30 Hz without slowing the established outer circulation.
Both also have matching `reservoir.reservoir_main.*` controller aliases.

`velocity_response` defaults to `12 s⁻¹`. It blends the head toward each new
velocity target consistently over time, rounding tight reservoir turns and
gate transitions without changing the 30 FPS render lock. Set it to `0` to
restore instantaneous velocity changes; lower positive values make broader,
softer turns and higher values make the flow track force targets more tightly.

Runtime message support covers `set_gate`, `set_parameter`, a `changes`
dictionary, presentation/calendar paths, geometry operations, salmon release,
and pause/resume/toggle/reset actions. Reservoir center and radius are
sent to all seven particle-process materials as runtime uniforms, so one
reservoir can be repositioned or resized without changing rendering code.
`runtime_summary()` provides a small inspection snapshot for tests and
controllers. Interaction polygons are packed on the CPU into one shared
128 x 1 `RGBAF` geometry texture. Only the `gpu_flow_particle` process shader
reads that texture; all seven palette layers share it, and neither CanvasItem
draw shader samples geometry. An abrupt geometry move changes the live force
field while immutable trail history correctly stays at its recorded world
positions. Making stored reservoir water or a stopped absorbed head move with
its owning geometry would require an explicit controller policy rather than a
rendering change.

Salmon use the water-only viewport texture for occupancy and a 300 x 1
write-only release-control texture. None of these paths reads live water or
particle state back to the CPU.

For controller compatibility, `changes.flow_rate` controls both population and
core speed: `0.0` emits no heads, `0.01` activates 20 slots, and `1.0` activates
all 1,000 slots. Positive water has a 25%-of-maximum speed floor so sparse water
still forms long lines; `flow_speed_pixels` is the maximum speed at `1.0`.

## Local keyboard controls

- `0`, `8`, `9`: retain the legacy normalized water-rate shortcuts (`0/9`,
  `8/9`, and `9/9`)
- `G`: open/close the gate
- `[` / `]`: narrow/widen the full outlet by 0.1 world units, clamped at the
  live reservoir diameter
- `Space`: globally pause/resume the timeline and every active stage in this process
- `S`: release 25 salmon
- `L`: release 15 leaves from the top and 15 from the bottom (30 total)
- `V`: compatibility key; the cyan reservoir guide and gold interaction-polygon
  geometry remain visible on every active stage
- `Escape`: return to the seven-scene selector; the shared clock is preserved

Running production stages intentionally ignore `1`–`7`. The Governator's
`fleet/godot_controller.py regime-console` owns those keys and sends an absolute
active set to every configured Godot process with target `*`. On
`startup_selector.tscn`, `1`–`7` still select scenes before a stage launches.
The active set starts in Kinship, survives scene replacement within a process, and
can contain several regimes at once. Keys `0`, `8`, and `9` update only water
`flow_rate`; no digit rebuilds, retunes, or releases the salmon/leaf systems or
resizes their segment pools. `S` releases only salmon, and `L` releases only
leaves. Every recognized stage key is marked handled so another scene node
cannot process the same event a second time. Use absolute regime state, ecology
runtime paths, and release actions when a controller changes those systems.
Controller-targeted debug actions are also compatibility no-ops; geometry
remains visible.

Set `accept_keyboard_input = false` when a scene must respond only to the
external controller.

## Smoke test

From the Godot project directory:

```sh
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
  --rendering-method mobile \
  --scene res://flow/gpu_stage/gpu_flow_stage_smoke.tscn
```

The smoke test checks all seven paired head/segment particle systems, their
absolute palette Z order, exact aggregate head and segment counts, interleaved
global identity, native size, disabled native trails, render-paced updates under
the project's 30 FPS cap, the two-second segment fade, the 96-pixel
discontinuity cutoff, identity aliases, gate width conversion, pause state, and
debug visibility. It verifies the transparent native water-only viewport, its
single composite display, and the ecological overlays' occupancy isolation. It
also verifies that runtime reservoir center and radius updates reach every
particle simulation layer, that the bounded interaction bank activates and
compacts to its expected GPU records, that the one interaction controller slot
remains available, and that controller upsert, field update, reshape, and
removal reach all seven particle materials. Regime coverage includes
Agriculture's four bank-connected drains and one obstacle, fresh per-screen
placement on every real active-set transition, identical-set idempotence,
explicit-zero removal, undefined fallback, 300-pixel lateral field capture,
sharp minimum-speed quarter-turn withdrawal and offscreen drainage, and stable
pool/resource identity across live transitions.
The salmon and leaf smoke scenes additionally validate release scheduling,
their occupancy contracts, bounded water/salmon immutable trails, fixed circular
release pools, stable resident particle/material/texture allocations under 2,000
salmon and 500 leaf release calls, and the absence of CPU readback. Visual testing
confirms the salmon's damped rolling
loss fade and full 2D contact-field steering, continuous UV-interpolated segment alpha, and
the leaves' nearby-water search, stopped-fade miss state, one-way water latch,
periodically cached local path following, and head-only disk rendering.

The real-renderer continuity test must run without `--headless`, whose dummy
backend cannot read a `ViewportTexture`:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --path . \
  --rendering-method mobile \
  --scene res://flow/tests/water_emission_continuity_smoke.tscn
```

It samples 24 seconds of 2% water. The test fails on any blank sample or if the
steady visible-pixel average leaves the calibrated 1–4% band.

```sh
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
  --rendering-method mobile \
  --scene res://flow/gpu_stage/gpu_salmon_smoke.tscn

/Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
  --rendering-method mobile \
  --scene res://flow/gpu_stage/gpu_leaf_smoke.tscn
```

The leaf smoke checks its 300-slot GPU pool, exact 15-top/15-bottom default
release, deterministic irregular alternating `0.11…0.29`-second gaps and an
approximately 5.93-second default span, independently shuffled X lanes per
bank, custom per-side releases, seven-color palette, head-only antialiased disks
with deterministic 10…20-pixel diameters and 5…10-pixel radii, 2–6-pixel
free-sway contract, the
120-pixel 17 x 17 nearby-water search and 0.35 steering blend, 256-pixel inward
search bound, frozen 0.5-second disk fade, zero segment capacity, one-way
attachment state,
8…56-pixel center/flank support over a 35-degree fan at a 0.12-second cadence,
assigned water texture, pause/reset/immediate re-release behavior, and no CPU
readback. Its 500-call stress pass additionally verifies circular-slot wrapping,
bounded last-release lane state, unchanged control-texture dimensions, fixed
particle amounts, and unchanged resident node/resource identities and RIDs. The
salmon smoke applies the corresponding allocation checks across 2,000 release
calls.

The production integration smoke is:

```sh
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
  --rendering-method mobile \
  --scene res://flow/tests/gpu_stage_scenes_smoke.tscn
```

It loads all seven wrappers, verifies their unique IDs and native sizes, routes
a targeted `flow_rate` message through `FlowControlBus` to each stage, and
checks that targeted interaction-polygon geometry operations remain isolated to
the addressed screen. It also checks the exact seven-title mapping and shared
Barlow Condensed Medium resource. The grid, date-time, and watershed timeline
described above are runtime contracts; the existing smoke scenes do not assert
their complete behavior.

The retained validation set contains six suites: basin budget, reusable GPU
stage, salmon, leaf, seven-scene integration, and the transport/runtime suite
at `res://flow/tests/flow_runtime_smoke.tscn`. The last suite retains unique
localhost UDP normalization and routing coverage for the shared controller
protocol; it is not a production rendering path.

## Current GPU scope

The GPU shaders currently implement stable flow/noise, immutable trail
segments, variable line width and color, a circular reservoir, retained
circulation, gate state, proportional gate-width release, runtime reservoir
geometry, and up to eight addressable absorb/repel polygons. Polygon capacity is
deliberately bounded at 12 vertices each so every stage can use a small geometry
texture with predictable shader cost. The stage also includes GPU salmon and
leaves whose contact and steering are driven directly by the water-only texture.

The CPU `FlowModel2D` remains in the project as a reference/fallback for its
arbitrary shoreline chain, circle and rotated-rectangle obstacle types, legacy
rectangular absorber collection, exact neighbor separation, and CPU-readable
retention statistics. Those CPU-specific features are not automatically mapped
to the unified GPU polygon array.
