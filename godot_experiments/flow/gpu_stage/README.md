# Reusable GPU flow stage

## Production deployment

`scene_1.tscn` through `scene_7.tscn` each instance this component directly,
so every selected scene is one full native screen rather than the prototype's
two-up preview. The existing selector, Escape behavior, and stable screen IDs
remain unchanged. The instances use stage indices 0–6 for independent seeds.

The project uses Mobile rendering, a 1920 x 1080 logical viewport, 4x 2D MSAA,
and a project render cap of 30 FPS. An obscured or embedded macOS Metal window
may report a much lower FPS because the OS throttles it, so installation timing
should be checked in a visible window. The fixed palette-depth renderer keeps
the former particle count but uses more particle nodes and GPU dispatches; run
a visible two-screen hardware benchmark after renderer changes before treating
30 FPS as an installation guarantee.

`gpu_flow_stage_2d.tscn` is one native 1920 x 1080 screen of GPU flow. It owns
seven fixed palette layers. Each layer is a paired head `GPUParticles2D` emitter
and child `GPUParticles2D` pool of immutable trail segments. Together they still
contain exactly 300 head slots and 22,500 segment slots—the layers divide that
population rather than multiplying it by seven. The default active ratio is
`0.5` (exactly 150 moving heads). Particle simulation is render-paced while the
project caps rendering at 30 FPS; this prevents a fixed-step catch-up frame from
overwriting an earlier sub-emitter batch. Each head emits one stationary segment
between consecutive completed positions. Native particle trails are disabled
on every layer. Line cores vary from 1–5 native pixels with a one-pixel alpha
feather.

The seven water layers render once into the component's native 1920 x 1080,
transparent `WaterOnlyViewport`. `WaterTextureDisplay` composites that texture
back into the stage with premultiplied-alpha blending. The black background,
background grid, debug overlay, stage title, model date, salmon, and leaves are
siblings outside the water viewport, so they are not copied into the water
texture and the visible water is not rendered twice. Each production scene
wrapper can instance the component directly because the project viewport is also
1920 x 1080.

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
guide, gold interaction outlines, violet source outlines, stage title, model
date, salmon, and leaves are deliberately excluded.

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
- `stage_grid_visible: bool`: visibility of the screen-fixed model grid.
- `stage_grid_spacing_pixels`, `stage_grid_line_width_pixels`, and
  `stage_grid_color`: native-pixel grid presentation controls.
- `stage_date_visible: bool`: visibility of the screen-fixed
  `MM/DD-HH:MM` label.
- `model_year_duration_seconds`, `model_start_day_index`, and
  `model_calendar_auto_advance`: watershed-calendar timing and mode controls.
- `watershed_data_path`, `watershed_data_drives_flow_rate`, and
  `watershed_interpolate_flow_rate`: the stage-specific 720-row data source and
  its flow-driving policy.

It joins the existing `flow_models` group and implements
`accepts_control_target()` plus `queue_control_message()`, so the existing
`FlowControlBus` can discover and address it.

### Stage presentation layers and model calendar

The main-canvas presentation stack is fixed around the animated content:

- `Background` is the explicit black `ColorRect` at absolute Z `-100`.
- `BackgroundGrid` is a stage-owned `Node2D` at absolute Z `-75`. Its production
  default is 1-native-pixel lines every 120 pixels in `#4AB0E1` at `0.75` alpha.
  Because one world unit is exactly 120 native pixels, the default grid describes
  the model's 16 x 9 coordinate system directly. Boundary lines are omitted, so
  the grid begins one interval inside each edge and never forms a screen frame.
- `StageTitleLayer` is at absolute Z `-50` and owns both `StageTitle` and
  `ModelDate`. The title is positioned at `(40, 40)`; the date is positioned at
  `(40, 980)`. Both use the bundled Barlow Condensed Medium font at 40 native
  pixels in opaque `#4AB0E1`.
- Water, salmon, and leaves render at absolute Z `0` or higher, so active
  features can pass visibly over the grid and text.

The grid and both text labels are outside `WaterOnlyViewport` and
`ReservoirAndStatusOverlay`. Their alpha can never be sampled as water by salmon
or leaves, and the `V` debug toggle does not hide them. The bundled font is
`res://flow/assets/fonts/BarlowCondensed-Medium.ttf`; the installation does not
depend on a matching system font.

`ModelDate` displays a zero-padded `MM/DD-HH:MM` in a non-leap, 365-day model
year. Every production wrapper sets `model_start_day_index = 181`, the zero-based
index for `07/01`, so a cycle runs from July 1 through June 30 and then wraps.
The internal clock defaults to one model year every 720 running seconds, which
is 21,600 rendered frames at the project's 30 FPS cap. The date-time is derived
from the continuous year fraction rather than accumulated integer frame counts,
so it does not drift. Pausing the stage freezes the calendar, watershed data,
water, and ecology together.

Each stage loads a 720-row `water_pipeline` text file. At the default 720-second
year, one row spans exactly one running second and represents a uniform 730
model minutes (12 hours 10 minutes). The files do not contain timestamps, so the
displayed `HH:MM` is a synthetic, uniformly spaced model time rather than an
observed sample timestamp. Between row boundaries the stage linearly
interpolates the current and following `norm` values on every update, including
the last-to-first wrap. The interpolated `norm` maps directly from `0.0…1.0` to
water `flow_rate` `0.0…1.0`, or 0…100 percent; it is not multiplied by the raw or
scaled columns.

The stage's `reset` action returns the timeline to `07/01-00:00` and restarts
water, salmon, and leaves without changing pause or auto-advance mode.
`reset_model_calendar()` resets only calendar/data position and leaves particle
state intact. A direct `set_flow_rate()`, digit-key, `flow_rate`, or
`active_ratio` change is an intentional manual override and disables watershed
flow driving. Set `watershed.drives_flow_rate` back to `true` to apply the
current interpolated data value immediately.

For an external time handoff, `set_model_date_time("12/21-06:30")` (or the
compatibility name `set_model_date_mm_dd`) and runtime paths `calendar.date` or
`stage.date` validate the non-leap date and time, align the watershed row, and
disable automatic advancement. Date-only `MM/DD` input remains accepted and
means midnight, but output is always canonical `MM/DD-HH:MM`. Invalid values
return `false` without changing state. Call
`set_model_calendar_auto_advance(true)`, or set `calendar.auto_advance`, to
resume the internal clock from the displayed time.

Each wrapper assigns its title explicitly. Display text is not a controller
identity and may change without changing the stable `screen_id` or `model_id`.

| Scene | `screen_id` | Stage title | Watershed data |
|---|---|---|---|
| `scene_1.tscn` | `mount_shasta` | Mount Shasta | `shasta_720.txt` |
| `scene_2.tscn` | `mccloud_pit` | McCloud-Pit Rivers | `mccloud_720.txt` |
| `scene_3.tscn` | `cottonwood_creek` | Cottonwood Creek | `cottonwood_720.txt` |
| `scene_4.tscn` | `mill_creek` | Mill Creek | `mill_creek_720.txt` |
| `scene_5.tscn` | `feather_river` | Feather River | `feather_720.txt` |
| `scene_6.tscn` | `american_river` | American River | `american_720.txt` |
| `scene_7.tscn` | `delta` | Sacramento-San Joaquin Delta | `delta_720.txt` |

All seven files are project resources under
`res://flow/data/water_pipeline/`. The combined McCloud-Pit screen currently
uses the McCloud series. The current Delta pipeline input is a short
November 6, 2025–January 17, 2026 gauge-height window measured in feet, not a
full-year CFS series; its 720 normalized rows are nevertheless stretched over
the display year. For that reason the runtime calls the pipeline's nominal
`cfs` column `raw_value`, and Delta seasonality should be treated as provisional.

The production presentation, calendar, and watershed paths are:

| Runtime path | Compatibility alias | Effect |
|---|---|---|
| `stage.title` | `stage_title` | River display text |
| `stage.title_visible` | `stage_title_visible` | Title visibility |
| `stage.grid_visible` | `stage_grid_visible` | Grid visibility |
| `stage.grid_spacing_pixels` | `stage_grid_spacing_pixels` | Grid spacing, clamped to `1…960` native pixels |
| `stage.grid_line_width_pixels` | `stage_grid_line_width_pixels` | Grid width, clamped to `0.1…8` native pixels |
| `stage.grid_color` | `stage_grid_color` | Grid color, including alpha |
| `stage.date_visible` | `stage_date_visible` | Date-time-label visibility |
| `calendar.date` or `stage.date` | `model_date` | Validated `MM/DD-HH:MM` (or date-only `MM/DD`); disables auto-advance |
| `calendar.day_index` | `model_day_index` | Zero-based day `0…364`; disables auto-advance |
| `calendar.auto_advance` | `model_calendar_auto_advance` | Select internal-clock or externally held mode |
| `calendar.year_duration_seconds` | `model_year_duration_seconds` | Internal year duration, clamped to `1…86400` seconds |
| `calendar.start_day_index` | `model_start_day_index` | Reset/start day `0…364`; changing it resets the calendar |
| `watershed.data_path` | `watershed_data_path` | Load a pipeline text file and align it to the current timeline |
| `watershed.drives_flow_rate` | `watershed_data_drives_flow_rate` | Enable/disable data control of water `flow_rate` |
| `watershed.interpolate_flow_rate` | `watershed_interpolate_flow_rate` | Lerp adjacent `norm` rows or hold each current row |

Presentation and calendar paths do not change `screen_id`, `model_id`, debug
visibility, or water occupancy. Watershed paths can change the water rate but do
not rebuild particles or retune salmon/leaves. The date signal remains
`model_date_changed(screen_id, date_mm_dd, day_of_year)` and reports the
date-only value when the day changes. Each data-row transition emits
`watershed_data_row_changed` with row index/count, `raw_value`, `normalized_flow`,
`scaled_flow`, `high_variation`, and canonical `model_date_time`.

`runtime_summary()` exposes the complete presentation contract. Grid fields are
`stage_grid_visible`, `stage_grid_spacing_pixels`,
`stage_grid_line_width_pixels`, `stage_grid_color`, `stage_grid_z_index`, and
`stage_grid_line_count`. Date fields are `stage_date_visible`,
`stage_date_text`, `stage_date_format`, `stage_date_position`, `stage_date_color`,
`stage_date_font_size`, `stage_date_font_resource`, and `stage_date_z_index`.
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
`model_date_time`. Layer assertions are `background_z_index`,
`stage_title_z_index`, `stage_title_below_animated_features`,
`stage_grid_above_background`, and `stage_text_above_grid`. The occupancy
exclusion flags are `water_texture_excludes_background`,
`water_texture_excludes_stage_grid`, `water_texture_excludes_debug_overlay`,
`water_texture_excludes_stage_title`, and `water_texture_excludes_stage_date`.

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
stage.set_runtime_parameter(&"stage.grid_visible", true)
stage.set_runtime_parameter(&"stage.date_visible", true)
stage.set_model_date_time("12/21-06:30") # validates and disables auto-advance
stage.set_model_calendar_auto_advance(true)
stage.reset_model_calendar()         # calendar only; does not reset water
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

Absorption applies only to a swept entry through an upstream-facing boundary
edge: its outward normal must point toward -X. The shader makes one
deterministic accept/reject choice from the polygon's stable ID and the global
particle identity. An accepted head stops just inside the crossed edge; its
already emitted tail is immutable and fades normally, then the occupied head
slot recycles cleanly. A rejected head receives one Y wave impulse and
continues downstream. This is line absorption rather than visual clipping.

Repulsion acts on heads only. It applies a soft redirect within the configured
influence distance and a swept boundary correction when a fixed step would
cross the polygon, so a head cannot tunnel through a thin object. Immutable
trail segments never run either interaction again.

When `install_default_interaction_examples` is enabled and the configured
interaction array is empty, the stage installs `absorber_test` and
`repeller_test`. Supplying any interaction polygon prevents those examples from
being added.

### GPU water-source polygons

`GPUFlowSourcePolygon` is an independently addressable polygon from which
ordinary GPU water heads can begin a new lifecycle. A stage supports at most
eight sources with at most 12 vertices each. Controller geometry remains in the
16 x 9 Y-up world. Each source has these fields:

- `vertices`: three through 12 finite vertices forming a simple polygon
- `enabled`: whether the source participates in water admission
- `emission_fraction`: normalized `0.0…1.0` share of lifecycle starts
- `flow_direction`: a finite, nonzero Y-up vector; `[1, 0]` is downstream +X
- `seed`: optional deterministic nonnegative integer; `null` or `-1` uses the
  ordinary particle sample without an added phase

`element_id` is stable and immutable through field-path changes. Source IDs are
unique within the source array. The controller accepts `source`, `sources`,
`source_polygon`, `source_polygons`, `water_source`, and `water_sources` as kind
aliases. Operations are `upsert` (`add`/`update`), `remove` (`delete`), and
whole-set `replace`:

```json
{
  "geometry_ops": [
    {
      "op": "upsert",
      "kind": "source",
      "id": "tributary_west",
      "value": {
        "vertices": [[1.2, 3.6], [2.0, 3.6], [2.0, 5.4], [1.2, 5.4]],
        "enabled": true,
        "emission_fraction": 0.18,
        "flow_direction": [1.0, 0.0],
        "seed": 1701
      }
    }
  ]
}
```

Mutable fields can also use `source.<id>.<field>` in `changes`; `fraction`,
`emission`, and `rate` alias `emission_fraction`, and `direction` aliases
`flow_direction`.

At the start of each water-head lifecycle, the process shader selects enabled
sources according to their emission fractions. The sum, clamped to `1.0`, is
the probability that a lifecycle starts at a source instead of the ordinary
left inlet; selection among several sources is weighted by their fractions.
Within the selected source, emission is spread across every downstream-facing
edge. Edge weight is its length multiplied by the positive alignment of its
outward normal with `flow_direction`. In the production +X flow model, that
weighted edge sample continues to supply the head's Y coordinate. A second,
independent deterministic lifecycle sample supplies X across the polygon's
complete bounding-box minimum and maximum X. Heads therefore emerge throughout
the source's horizontal extent instead of sharing one hard vertical launch
seam. The head then travels in the configured direction, so the polygon visibly
produces water rather than serving only as a debug shape.

Source configuration is packed into its own fixed 128 x 1 `RGBAF` texture.
Only the water-head particle-process shader reads it. Configuration-time image
packing is not a water simulation readback. With `V` enabled, sources have a
violet outline and outward tick arrows on their emitting edges; disabled
sources remain visible with a faint violet outline. When
`install_default_source_examples` is enabled and no source array is supplied,
the stage installs `source_test` using the geometry in the example above.

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
| `leaves.free_search_max_distance_pixels` | `256` | Inward bank distance searched before a miss freezes and fades |
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

At the defaults, `ceil(300 * 30 * 2.0 * 1.25)` is 22,500 slots per stage.
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
300 slots, head allocations are `[43, 43, 43, 43, 43, 43, 42]`; at 50% flow,
the active counts are `[22, 22, 22, 21, 21, 21, 21]`, totaling exactly 150.
Segment capacities are `[3225, 3225, 3225, 3225, 3225, 3225, 3150]`, totaling
22,500. Runtime flow changes use the same global threshold, so splitting the
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

The head positions still use an eight-second startup prewarm so a scene opens
with water distributed across the screen. Both reservoir admission and segment
recording are held off during that prewarm. Heads which pass the reservoir are
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
retained head continues to occupy one of the stage's fixed 300 active
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

Source polygons use a second bounded 128 x 1 `RGBAF` configuration texture.
Salmon use the water-only viewport texture for occupancy and a 300 x 1
write-only release-control texture. None of these paths reads live water or
particle state back to the CPU.

For controller compatibility, `changes.flow_rate` controls both population and
core speed: `0.0` emits no heads, `0.5` activates about 150 slots at 300 px/s,
and `1.0` activates all 300 slots at 600 px/s. `flow_speed_pixels` is the
maximum speed at a flow rate of `1.0`.

## Local keyboard controls

- `0`–`9`: set normalized flow rate from 0 to 1
- `G`: open/close the gate
- `[` / `]`: narrow/widen the full outlet by 0.1 world units, clamped at the
  live reservoir diameter
- `Space`: pause/resume water, salmon, leaves, and the internal model calendar
- `S`: release 25 salmon
- `L`: release 15 leaves from the top and 15 from the bottom (30 total)
- `V`: show/hide the cyan reservoir guide, gold interaction-polygon outlines,
  and violet source outlines/emission arrows; the grid, river title, and model
  date remain visible
- `Escape`: return to the seven-scene selector (handled by `stage_scene.gd`)

These keyboard paths are isolated. Digit keys update only the water
`flow_rate`; they do not rebuild, retune, or release the salmon/leaf systems or
resize their segment pools. `S` releases only salmon, and `L` releases only
leaves. Every recognized stage key is marked handled so another scene node
cannot process the same event a second time. Use the ecology runtime paths and
release actions when a controller needs to change those systems.

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
also verifies that runtime
reservoir center and radius updates reach every particle simulation layer, that
the two default interaction polygons pack into the shared 128 x 1 `RGBAF`
texture, and that controller upsert, field update, reshape, and removal reach all
seven particle materials.
The source, salmon, and leaf smoke scenes additionally validate source packing,
weighted-edge Y plus independent bounding-box X sampling, release scheduling,
their occupancy contracts, bounded water/salmon immutable trails, and the
absence of CPU readback. Visual testing confirms the salmon's damped rolling
loss fade and full 2D contact-field steering, continuous UV-interpolated segment alpha, and
the leaves' nearby-water search, stopped-fade miss state, one-way water latch,
periodically cached local path following, and head-only disk rendering.

```sh
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
  --rendering-method mobile \
  --scene res://flow/gpu_stage/gpu_flow_source_texture_smoke.tscn

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
readback.

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

The retained validation set contains six suites: the reusable GPU stage, source
texture, salmon, leaf, seven-scene integration, and the transport/runtime suite
at `res://flow/tests/flow_runtime_smoke.tscn`. The last suite retains unique
localhost UDP normalization and routing coverage for the shared controller
protocol; it is not a production rendering path.

## Current GPU scope

The GPU shaders currently implement stable flow/noise, immutable trail
segments, variable line width and color, a circular reservoir, retained
circulation, gate state, proportional gate-width release, runtime reservoir
geometry, up to eight addressable absorb/repel polygons, and up to eight
addressable water-source polygons. Polygon capacity is deliberately bounded at
12 vertices each so every stage can use small geometry textures with predictable
shader cost. The stage also includes GPU salmon and leaves whose contact and
steering are driven directly by the water-only texture.

The CPU `FlowModel2D` remains in the project as a reference/fallback for its
arbitrary shoreline chain, circle and rotated-rectangle obstacle types, legacy
rectangular absorber collection, exact neighbor separation, and CPU-readable
retention statistics. Those CPU-specific features are not automatically mapped
to the unified GPU polygon array.
