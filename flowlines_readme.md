# Flow Lines v04

`ink_flow_lines_v04.py` animates ink-like water trails moving from left to
right through banks, obstacles, and gated circular reservoirs.

## Run

From the code directory:

```bash
python3 ink_flow_lines_v04.py
```

Set the initial normalized flow rate from the command line:

```bash
python3 ink_flow_lines_v04.py --flow-rate 0.5
```

`--flow-rate` accepts values from `0.0` to `1.0`. The script requires Python,
NumPy, and Matplotlib. Pillow is required for GIF export and FFmpeg is required
for MP4 export.

## Keyboard controls

| Key | Action |
| --- | --- |
| `0`–`9` | Set live core flow. `0` stops flow and removes trails; `9` is full flow. Intermediate keys use `digit / 9`. |
| `G` | Toggle the active reservoir gate open or closed. |
| `[` | Narrow the active reservoir gate by `GATE_WIDTH_STEP`. |
| `]` | Widen the active reservoir gate by `GATE_WIDTH_STEP`. |
| `V` | Toggle obstacle and reservoir debug geometry visibility. |
| `S` | Save a timestamped PNG of the current frame. |

Gate changes preserve the water already circulating. Increasing gate width
makes a larger stable proportion of lines eligible to leave on their next pass.
The released fraction is:

```text
outlet_width / (2 * radius)
```

## Flow and particle parameters

| Parameter | Purpose |
| --- | --- |
| `MAX_PARTICLES` | Trail count at full flow. |
| `MAX_FLOW_SPEED` | Maximum visual speed at normalized flow `1.0`. |
| `DEFAULT_FLOW_RATE` | Core flow used when `--flow-rate` is omitted. |
| `PARTICLE_FLOW_VARIATION` | Stable per-line variation around the core flow; currently `±0.1`. |
| `MIN_ACTIVE_PARTICLE_FLOW` | Positive lower bound that prevents active lines from receiving negative or backward speed scaling. |
| `BASE_FLOW_X`, `BASE_FLOW_Y` | Direction and base shape of the flow field. Reservoir behavior assumes positive-X flow. |
| `TRAIL_LENGTH` | Number of stored points in each trail. |
| `SIMULATION_SUBSTEPS` | Physics steps recorded during each displayed frame. More steps produce smoother curves at higher cost. |
| `PARTICLE_LAUNCH_DELAY_MS` | Delay between consecutive line launches. |
| `RANDOM_SEED` | Seed for repeatable widths and colors. Use `None` for a new arrangement each run. |
| `SPAWN_X` | X position where trails enter. |
| `SPAWN_Y_MARGIN` | Vertical margin between the outermost spawn positions and banks. |

`FLOW_RATE`, `FLOW_SPEED`, and `NUM_PARTICLES` are derived runtime values and
normally should not be edited directly.

## Organic motion and separation

| Parameter | Purpose |
| --- | --- |
| `NOISE_STRENGTH` | Amount of decorative curl motion. |
| `NOISE_SCALE` | Spatial frequency of the curl field. |
| `NOISE_SPEED` | Animation speed of the curl field. |
| `PARTICLE_SEPARATION_RADIUS` | Distance at which nearby line heads repel. |
| `PARTICLE_SEPARATION_STRENGTH` | Strength of the local separation pressure. |
| `PARTICLE_SEPARATION_X_SCALE` | Fraction of separation force applied along X. |
| `PARTICLE_SEPARATION_MAX_FORCE` | Maximum separation force per line. |

## Riverbanks

| Parameter | Purpose |
| --- | --- |
| `SHORE_INFLUENCE` | Distance over which each bank affects the flow. |
| `SHORE_STRENGTH` | Repulsion strength near the banks. |
| `SHORE_POWER` | Shape of the bank-force falloff. |
| `TOP_SHORE_Y_OFFSET` | Visual correction between the upper bank and data boundary. |

## Appearance and display

| Parameter | Purpose |
| --- | --- |
| `OUTPUT_WIDTH_PX`, `OUTPUT_HEIGHT_PX` | Output and requested interactive canvas size. |
| `OUTPUT_DPI` | Figure resolution. |
| `HEIGHT` | Simulation height. |
| `WIDTH` | Derived simulation width matching the output aspect ratio. |
| `TARGET_FPS` | Interactive display frame rate. |
| `LINE_WIDTH_MIN`, `LINE_WIDTH_MAX` | Stable random width range for trails. |
| `PARTICLE_ALPHA` | Trail opacity. |
| `BACKGROUND` | Canvas color. |
| `LINE_COLOR` | General line color used by non-random line elements. |
| `COLORS` | Palette randomly assigned across trails. |

## Debug and runtime-control parameters

| Parameter | Purpose |
| --- | --- |
| `SCREENSHOT_KEY` | Screenshot key, currently `s`. |
| `SCREENSHOT_DIR` | Screenshot output directory. |
| `GATE_TOGGLE_KEY` | Gate state key, currently `g`. |
| `GATE_NARROW_KEY`, `GATE_WIDEN_KEY` | Live gate-width keys, currently `[` and `]`. |
| `GATE_WIDTH_STEP` | Amount added to or removed from outlet width per key press. |
| `ACTIVE_RESERVOIR_INDEX` | Reservoir controlled by the gate keys; indexing starts at zero. |
| `VISIBILITY_TOGGLE_KEY` | Debug-geometry key, currently `v`. |
| `DEBUG_GEOMETRY_VISIBLE` | Whether obstacle and reservoir outlines begin visible. |
| `DEBUG_GEOMETRY_COLOR` | Debug outline color. |
| `DEBUG_GEOMETRY_LINE_WIDTH` | Debug outline thickness. |

## Obstacles

Add obstacle instances to `OBSTACLES`, `RECTANGLE_OBSTACLES`, or
`POLYGON_OBSTACLES`.

### Circular obstacle

```python
Obstacle(x, y, radius, strength=4.0, bend=1.0)
```

- `x`, `y`: center.
- `radius`: solid radius.
- `strength`: outward repulsion.
- `bend`: tangential steering direction and strength.

### Rectangular obstacle

```python
RectangleObstacle(
    x,
    y,
    width,
    height,
    angle_degrees=0.0,
    strength=4.0,
    bend=1.0,
    influence=0.65,
)
```

- `x`, `y`: center.
- `width`, `height`: dimensions before rotation.
- `angle_degrees`: counterclockwise rotation.
- `strength`: boundary repulsion.
- `bend`: tangential steering direction and strength.
- `influence`: distance over which the boundary affects flow.

### Polygon obstacle

```python
PolygonObstacle(
    vertices=((x1, y1), (x2, y2), (x3, y3)),
    strength=4.0,
    bend=1.0,
    influence=0.65,
)
```

Vertices must describe a non-self-intersecting polygon.

## Reservoirs

Add reservoir instances to `RESERVOIRS`:

```python
Reservoir(
    x,
    y,
    radius,
    outlet_width,
    gate_open=True,
    circulation=1.0,
    swirl_strength=2.4,
    confinement_strength=3.2,
    wall_strength=8.0,
    outlet_strength=4.0,
    wall_influence=0.22,
    orbit_radius_fraction=0.62,
    orbit_radius_spread=0.52,
)
```

| Parameter | Purpose |
| --- | --- |
| `x`, `y` | Reservoir center. |
| `radius` | Catchment radius and half of the upstream inlet diameter. |
| `outlet_width` | Centered downstream gate width and basis for the released-line proportion. Clamped from zero to the full diameter by runtime controls. |
| `gate_open` | Initial gate state. A closed gate releases no lines. |
| `circulation` | Direction and multiplier. Positive is counterclockwise; negative is clockwise. |
| `swirl_strength` | Tangential circulation force. |
| `confinement_strength` | Force guiding lines toward their assigned orbit radii. |
| `wall_strength` | Force preventing leakage through the downstream semicircle. |
| `outlet_strength` | Force straightening and pulling eligible lines through the gate. |
| `wall_influence` | Distance over which the downstream wall acts. |
| `orbit_radius_fraction` | Center of the distributed orbit-radius band, as a fraction of reservoir radius. |
| `orbit_radius_spread` | Width of the orbit-radius band. Increase for broader pooling; use zero for one shared orbit. |

The upstream diameter is open. Lines entering it are pooled across stable,
per-line orbit radii. At an open gate, only the stable fraction selected by the
gate-width ratio can exit; all other lines experience the gate as closed.

## Export parameters

| Parameter | Purpose |
| --- | --- |
| `SAVE_MP4`, `SAVE_GIF` | Enable MP4 or GIF export instead of the interactive window. |
| `EXPORT_FRAMES` | Save every displayed frame as a PNG. |
| `OUTPUT_MP4`, `OUTPUT_GIF` | Animation output filenames. |
| `FRAME_DIR` | PNG frame output directory. |
| `EXPORT_FPS` | Export frame rate. |
| `EXPORT_SECONDS` | Export duration. |
