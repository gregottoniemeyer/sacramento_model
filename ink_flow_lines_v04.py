"""
ink_flow_lines_v04.py

Animated 2D graphic flow lines moving around circular, rectangular,
and polygonal obstacles.

Optional export:
    Set SAVE_MP4 = True and install ffmpeg.
    Set SAVE_GIF = True and install pillow.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
import math

import numpy as np
import matplotlib.pyplot as plt
from matplotlib.animation import FuncAnimation, PillowWriter


# --------------------------------------------------
# SETTINGS
# --------------------------------------------------

MAX_PARTICLES = 300
MAX_FLOW_SPEED = 10.0
DEFAULT_FLOW_RATE = 0.5


def flow_rate_value(value: str) -> float:
    """Parse a normalized flow rate for argparse."""
    flow_rate = float(value)
    if not 0.0 <= flow_rate <= 1.0:
        raise argparse.ArgumentTypeError(
            "flow rate must be between 0.0 and 1.0"
        )
    return flow_rate


def parse_cli_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Animate river flow with smooth continuous ink trails.",
    )
    parser.add_argument(
        "--flow-rate",
        type=flow_rate_value,
        default=DEFAULT_FLOW_RATE,
        metavar="RATE",
        help=(
            "normalized river flow from 0.0 to 1.0; controls both "
            "trail count and speed (default: %(default)s)"
        ),
    )
    return parser.parse_args()


cli_args = (
    parse_cli_args()
    if __name__ == "__main__"
    else argparse.Namespace(flow_rate=DEFAULT_FLOW_RATE)
)
FLOW_RATE = cli_args.flow_rate
FLOW_SPEED = FLOW_RATE * MAX_FLOW_SPEED

OUTPUT_WIDTH_PX = 1920
OUTPUT_HEIGHT_PX = 1080
OUTPUT_DPI = 120

HEIGHT = 7.0
WIDTH = HEIGHT * OUTPUT_WIDTH_PX / OUTPUT_HEIGHT_PX

def particle_count_for_flow(flow_rate: float) -> int:
    """Map zero to no trails and positive flow up to MAX_PARTICLES."""
    return (
        0
        if flow_rate == 0.0
        else max(1, round(MAX_PARTICLES * flow_rate))
    )


# Zero flow has no trails. Every positive flow starts with the center trail,
# then scales linearly to MAX_PARTICLES at a flow rate of 1.0.
NUM_PARTICLES = particle_count_for_flow(FLOW_RATE)
TRAIL_LENGTH = 1200
TARGET_FPS = 30
DT = 1.0 / TARGET_FPS
INTERVAL_MS = 1000.0 / TARGET_FPS
# v02 looked smoother because its low speed and short timestep placed trail
# points about 0.011 units apart. At full v04 speed, twenty internal steps put
# points about 0.017 units apart while the displayed animation remains 30 FPS.
SIMULATION_SUBSTEPS = 20
PARTICLE_LAUNCH_DELAY_MS = 10
RANDOM_SEED = None

BASE_FLOW_X = 2.0
BASE_FLOW_Y = 0.0

NOISE_STRENGTH = 0.20
NOISE_SCALE = 0.55
NOISE_SPEED = 0.35

# Soft particle pressure prevents neighboring trails from collapsing onto the
# same path after they pass an obstacle.
PARTICLE_SEPARATION_RADIUS = 0.075
PARTICLE_SEPARATION_STRENGTH = 0.85
PARTICLE_SEPARATION_X_SCALE = 0.15
PARTICLE_SEPARATION_MAX_FORCE = 1.0

# Each trail receives one stable random width from this range.
LINE_WIDTH_MIN = 0.5
LINE_WIDTH_MAX = 3.0

PARTICLE_ALPHA = 0.75

BACKGROUND = "black"
LINE_COLOR = "dodgerblue"

SAVE_MP4 = False
SAVE_GIF = False
EXPORT_FRAMES = False

OUTPUT_MP4 = "ink_flow_lines_v04.mp4"
OUTPUT_GIF = "ink_flow_lines_v04.gif"
FRAME_DIR = Path("ink_flow_frames_v04")
SCREENSHOT_KEY = "s"
SCREENSHOT_DIR = Path("ink_flow_screenshots_v04")

EXPORT_FPS = 30
EXPORT_SECONDS = 12

SPAWN_X_MIN = -6.0
SPAWN_X_MAX = 0.0

COLORS = np.array([
    "#FFFFFF",  # white
    "#EAF7EE",
    "#D3EFDC",
    "#ACE1AF",  # celadon
    "#7BCFC4",
    "#4AB0E1",
    "#1E90FF",  # dodger blue
])

# Riverbank settings
SHORE_INFLUENCE = 0.85
SHORE_STRENGTH = 4.0
SHORE_POWER = 2.0
# The visual upper bank sits slightly above the data-height boundary. Without
# this offset, its repulsion starts about half a unit too low in the frame.
TOP_SHORE_Y_OFFSET = 0.5

SPAWN_Y_MARGIN = 0.15



@dataclass(frozen=True)
class Obstacle:
    x: float
    y: float
    radius: float
    strength: float = 4.0
    bend: float = 1.0


@dataclass(frozen=True)
class RectangleObstacle:
    x: float
    y: float
    width: float
    height: float
    angle_degrees: float = 0.0
    strength: float = 4.0
    bend: float = 1.0
    influence: float = 0.65


@dataclass(frozen=True)
class PolygonObstacle:
    vertices: tuple[tuple[float, float], ...]
    strength: float = 4.0
    bend: float = 1.0
    influence: float = 0.65


OBSTACLES = [
    #Obstacle(4.0, 3.7, 0.25, strength=1.5, bend=1.3),
    #Obstacle(6.8, 2.3, 0.25, strength=1.5, bend=-1.0),
]

RECTANGLE_OBSTACLES = [
    # Coordinates specify the rectangle center. Rotation is counterclockwise.
    
        RectangleObstacle(
        6.0,
        3.5,
        width=0.1,
        height=4.0,
        angle_degrees=0.0,
        strength=1.5,
        bend=-0.8,
    ),
]

POLYGON_OBSTACLES = [
    # Vertices can define any non-self-intersecting polygon.
    #PolygonObstacle(((8.65, 3.05),(9.25, 3.25),(8.85, 3.75),),strength=1.5,bend=0.9,),
]


# --------------------------------------------------
# SIMULATION
# --------------------------------------------------

rng = np.random.default_rng(RANDOM_SEED)

def shore_force(points: np.ndarray) -> np.ndarray:
    """
    Push particles away from the top and bottom riverbanks.

    The force starts gently at SHORE_INFLUENCE distance and becomes
    stronger as a particle approaches or crosses a shore.
    """
    y = points[:, 1]

    distance_from_bottom = y
    distance_from_top = HEIGHT + TOP_SHORE_Y_OFFSET - y

    bottom_influence = np.clip(
        (SHORE_INFLUENCE - distance_from_bottom) / SHORE_INFLUENCE,
        0.0,
        1.5,
    )

    top_influence = np.clip(
        (SHORE_INFLUENCE - distance_from_top) / SHORE_INFLUENCE,
        0.0,
        1.5,
    )

    force = np.zeros_like(points)

    # Bottom shore pushes upward.
    force[:, 1] += (
        SHORE_STRENGTH
        * bottom_influence ** SHORE_POWER
    )

    # Top shore pushes downward.
    force[:, 1] -= (
        SHORE_STRENGTH
        * top_influence ** SHORE_POWER
    )

    return force


def safe_normalize(vectors: np.ndarray, minimum: float = 0.05) -> tuple[np.ndarray, np.ndarray]:
    lengths = np.linalg.norm(vectors, axis=1)
    safe_lengths = np.maximum(lengths, minimum)
    normalized = vectors / safe_lengths[:, None]
    return normalized, lengths


def rectangle_vertices(obstacle: RectangleObstacle) -> np.ndarray:
    """Return the four rotated rectangle corners in counterclockwise order."""
    half_width = obstacle.width * 0.5
    half_height = obstacle.height * 0.5
    local_vertices = np.array(
        [
            (-half_width, -half_height),
            (half_width, -half_height),
            (half_width, half_height),
            (-half_width, half_height),
        ]
    )
    angle = math.radians(obstacle.angle_degrees)
    rotation = np.array(
        [
            (math.cos(angle), -math.sin(angle)),
            (math.sin(angle), math.cos(angle)),
        ]
    )
    return (
        local_vertices @ rotation.T
        + np.array((obstacle.x, obstacle.y))
    )


def points_inside_polygon(
    points: np.ndarray,
    vertices: np.ndarray,
) -> np.ndarray:
    """Vectorized even-odd test for a non-self-intersecting polygon."""
    inside = np.zeros(len(points), dtype=bool)
    x = points[:, 0]
    y = points[:, 1]

    for start, end in zip(vertices, np.roll(vertices, -1, axis=0)):
        crosses_y = (start[1] > y) != (end[1] > y)
        edge_dy = end[1] - start[1]
        if abs(edge_dy) < 1e-12:
            continue
        crossing_x = (
            (end[0] - start[0])
            * (y - start[1])
            / edge_dy
            + start[0]
        )
        inside ^= crosses_y & (x < crossing_x)

    return inside


def polygon_obstacle_force(
    points: np.ndarray,
    vertices: np.ndarray,
    strength: float,
    bend: float,
    influence_distance: float,
) -> np.ndarray:
    """Push and steer particles around a rectangle or polygon boundary."""
    edge_starts = vertices
    edge_vectors = np.roll(vertices, -1, axis=0) - vertices
    edge_length_sq = np.einsum(
        "ij,ij->i",
        edge_vectors,
        edge_vectors,
    )
    edge_length_sq = np.maximum(edge_length_sq, 1e-12)

    point_offsets = points[:, None, :] - edge_starts[None, :, :]
    projection = np.einsum(
        "nej,ej->ne",
        point_offsets,
        edge_vectors,
    ) / edge_length_sq[None, :]
    projection = np.clip(projection, 0.0, 1.0)
    closest_points = (
        edge_starts[None, :, :]
        + projection[:, :, None] * edge_vectors[None, :, :]
    )

    boundary_offsets = points[:, None, :] - closest_points
    distance_sq = np.einsum(
        "nej,nej->ne",
        boundary_offsets,
        boundary_offsets,
    )
    closest_edge = np.argmin(distance_sq, axis=1)
    row_indices = np.arange(len(points))
    nearest_offset = boundary_offsets[row_indices, closest_edge]
    outward, distance = safe_normalize(nearest_offset, minimum=1e-8)

    inside = points_inside_polygon(points, vertices)
    outward[inside] *= -1.0

    # Supply a stable normal for a point exactly on an edge.
    on_boundary = distance < 1e-8
    if np.any(on_boundary):
        selected_edges = edge_vectors[closest_edge[on_boundary]]
        signed_area = 0.5 * np.sum(
            vertices[:, 0] * np.roll(vertices[:, 1], -1)
            - np.roll(vertices[:, 0], -1) * vertices[:, 1]
        )
        if signed_area >= 0.0:
            normals = np.column_stack(
                (selected_edges[:, 1], -selected_edges[:, 0])
            )
        else:
            normals = np.column_stack(
                (-selected_edges[:, 1], selected_edges[:, 0])
            )
        outward[on_boundary], _ = safe_normalize(
            normals,
            minimum=1e-8,
        )

    influence = np.clip(
        (influence_distance - distance) / influence_distance,
        0.0,
        1.0,
    )
    influence[inside] = 1.0

    force = outward * (influence * strength)[:, None]
    tangent = np.column_stack((-outward[:, 1], outward[:, 0]))
    force += tangent * (influence * bend)[:, None]

    if np.any(inside):
        force[inside] += outward[inside] * (
            strength * (2.0 + 5.0 * distance[inside])
        )[:, None]

    return force


def particle_separation_force(points: np.ndarray) -> np.ndarray:
    """
    Apply a soft local pressure between nearby particle heads.

    Vertical separation receives most of the force so congested trails fan
    back out without fighting the river's downstream motion.
    """
    count = len(points)
    if count < 2:
        return np.zeros_like(points)

    offsets = points[:, None, :] - points[None, :, :]
    distance_sq = np.einsum(
        "ijk,ijk->ij",
        offsets,
        offsets,
    )
    nearby = (
        (distance_sq > 1e-12)
        & (distance_sq < PARTICLE_SEPARATION_RADIUS ** 2)
    )

    distance = np.sqrt(
        np.maximum(distance_sq, 1e-12)
    )
    pressure = np.where(
        nearby,
        (
            1.0
            - distance / PARTICLE_SEPARATION_RADIUS
        ) ** 2,
        0.0,
    )
    directions = offsets / distance[:, :, None]
    force = np.sum(
        directions * pressure[:, :, None],
        axis=1,
    )
    force *= PARTICLE_SEPARATION_STRENGTH
    force[:, 0] *= PARTICLE_SEPARATION_X_SCALE

    force_size = np.linalg.norm(force, axis=1)
    too_strong = force_size > PARTICLE_SEPARATION_MAX_FORCE
    if np.any(too_strong):
        force[too_strong] *= (
            PARTICLE_SEPARATION_MAX_FORCE
            / force_size[too_strong]
        )[:, None]

    return force


def curl_noise(points: np.ndarray, time_value: float) -> np.ndarray:
    """
    Lightweight divergence-like decorative motion.

    This is not Perlin noise. It combines smooth sine fields so the
    particles meander without requiring another package.
    """
    x = points[:, 0] * NOISE_SCALE
    y = points[:, 1] * NOISE_SCALE
    t = time_value * NOISE_SPEED

    vx = (
        np.sin(y * 1.7 + t)
        + 0.55 * np.sin(x * 1.1 - y * 0.8 - t * 1.4)
    )
    vy = (
        np.cos(x * 1.5 - t * 0.8)
        - 0.55 * np.cos(y * 1.2 + x * 0.7 + t)
    )

    return np.column_stack((vx, vy)) * NOISE_STRENGTH


def velocity_field(
    points: np.ndarray,
    time_value: float,
    separation_force: np.ndarray | None = None,
) -> np.ndarray:
    velocity = np.empty_like(points)
    velocity[:, 0] = BASE_FLOW_X
    velocity[:, 1] = BASE_FLOW_Y

    velocity += curl_noise(points, time_value)
    velocity += shore_force(points)
    if separation_force is not None:
        velocity += separation_force

    for obstacle in OBSTACLES:

        center = np.array([obstacle.x, obstacle.y])
        offset = points - center
        radial, distance = safe_normalize(offset)

        influence = np.clip(
            (obstacle.radius * 2.6 - distance) / (obstacle.radius * 1.6),
            0.0,
            1.0,
        )

        # Strong radial repulsion near the obstacle.
        velocity += radial * (influence * obstacle.strength)[:, None]

        # Tangential component helps trajectories split around the obstacle.
        tangent = np.column_stack((-radial[:, 1], radial[:, 0]))
        velocity += tangent * (influence * obstacle.bend)[:, None]

        # Emergency push for any particle that entered the solid obstacle.
        inside = distance < obstacle.radius
        if np.any(inside):
            penetration = obstacle.radius - distance[inside]
            velocity[inside] += radial[inside] * (
                obstacle.strength * 5.0 * penetration[:, None]
            )

    for obstacle in RECTANGLE_OBSTACLES:
        velocity += polygon_obstacle_force(
            points,
            rectangle_vertices(obstacle),
            obstacle.strength,
            obstacle.bend,
            obstacle.influence,
        )

    for obstacle in POLYGON_OBSTACLES:
        velocity += polygon_obstacle_force(
            points,
            np.asarray(obstacle.vertices, dtype=float),
            obstacle.strength,
            obstacle.bend,
            obstacle.influence,
        )

    # Map normalized flow linearly to a visual speed from 0 to 10. Scaling the
    # complete field preserves its stream shape and obstacle deflections.
    velocity *= FLOW_SPEED / BASE_FLOW_X

    # Cap speed so particles do not jump through obstacles.
    speed = np.linalg.norm(velocity, axis=1)
    max_speed = FLOW_SPEED
    fast = speed > max_speed
    if np.any(fast):
        velocity[fast] *= (max_speed / speed[fast])[:, None]

    return velocity


def alternating_spawn_y(particle_indices: np.ndarray) -> np.ndarray:
    """
    Place trail slots center, above, below, above, below, and so on.

    Spacing is based on MAX_PARTICLES, so increasing flow adds trails outward
    without moving the trails that were already present at lower flow rates.
    """
    particle_indices = np.asarray(particle_indices, dtype=np.intp)
    center = HEIGHT * 0.5
    half_span = center - SPAWN_Y_MARGIN
    levels_per_side = math.ceil((MAX_PARTICLES - 1) / 2)
    level_spacing = half_span / max(1, levels_per_side)

    level = (particle_indices + 1) // 2
    direction = np.where(
        particle_indices == 0,
        0.0,
        np.where(particle_indices % 2 == 1, 1.0, -1.0),
    )
    return center + direction * level * level_spacing


def spawn_positions(particle_indices: np.ndarray) -> np.ndarray:
    particle_indices = np.asarray(particle_indices, dtype=np.intp)
    count = len(particle_indices)
    return np.column_stack(
        (
            rng.uniform(SPAWN_X_MIN, SPAWN_X_MAX, count),
            alternating_spawn_y(particle_indices),
        )
    )


positions = spawn_positions(np.arange(MAX_PARTICLES))
trails = np.repeat(positions[:, None, :], TRAIL_LENGTH
, axis=1)
retiring = np.zeros(MAX_PARTICLES, dtype=bool)
particle_launch_times_ms = np.full(MAX_PARTICLES, np.inf)
particle_launch_times_ms[:NUM_PARTICLES] = (
    np.arange(NUM_PARTICLES) * PARTICLE_LAUNCH_DELAY_MS
)


def reset_particles(indices: np.ndarray) -> None:
    global retiring

    if len(indices) == 0:
        return

    new_positions = spawn_positions(indices)
    positions[indices] = new_positions
    trails[indices, :, :] = new_positions[:, None, :]
    retiring[indices] = False


# --------------------------------------------------
# DRAWING
# --------------------------------------------------

fig = plt.figure(
    figsize=(
        OUTPUT_WIDTH_PX / OUTPUT_DPI,
        OUTPUT_HEIGHT_PX / OUTPUT_DPI,
    ),
    dpi=OUTPUT_DPI,
    facecolor=BACKGROUND,
)

# Fill the complete 1920 × 1080 canvas: no subplot padding or layout margins.
ax = fig.add_axes([0.0, 0.0, 1.0, 1.0])
ax.set_facecolor(BACKGROUND)
ax.set_xlim(0.0, WIDTH)
ax.set_ylim(0.0, HEIGHT)
ax.set_aspect("equal", adjustable="box")
ax.margins(x=0.0, y=0.0)
ax.axis("off")

# Reserve S for the instant screenshot handler instead of Matplotlib's default
# save-file dialog.
plt.rcParams["keymap.save"] = [
    key
    for key in plt.rcParams["keymap.save"]
    if key.lower() != SCREENSHOT_KEY
]

line_widths = rng.uniform(
    LINE_WIDTH_MIN,
    LINE_WIDTH_MAX,
    MAX_PARTICLES,
)

line_colors = rng.choice(COLORS, size=MAX_PARTICLES)

trail_lines = []
for particle_index in range(MAX_PARTICLES):
    line, = ax.plot(
        [],
        [],
        color=line_colors[particle_index],
        linewidth=line_widths[particle_index],
        alpha=PARTICLE_ALPHA,
        solid_capstyle="round",
        solid_joinstyle="round",
        antialiased=True,
        clip_on=True,
    )
    trail_lines.append(line)

for obstacle in OBSTACLES:
    ax.add_patch(
        plt.Circle(
            (obstacle.x, obstacle.y),
            obstacle.radius,
            facecolor=BACKGROUND,
            edgecolor=BACKGROUND,
            linewidth=1.0,
            zorder=10
        )
    )

for obstacle in RECTANGLE_OBSTACLES:
    ax.add_patch(
        plt.Polygon(
            rectangle_vertices(obstacle),
            closed=True,
            facecolor=BACKGROUND,
            edgecolor=BACKGROUND,
            linewidth=1.0,
            zorder=10,
        )
    )

for obstacle in POLYGON_OBSTACLES:
    ax.add_patch(
        plt.Polygon(
            obstacle.vertices,
            closed=True,
            facecolor=BACKGROUND,
            edgecolor=BACKGROUND,
            linewidth=1.0,
            zorder=10,
        )
    )


frame_counter = 0
current_elapsed_ms = 0.0


def update(frame: int):
    global positions, trails, frame_counter, retiring, current_elapsed_ms

    substep_dt = DT / SIMULATION_SUBSTEPS
    new_trail_points = np.empty(
        (NUM_PARTICLES, SIMULATION_SUBSTEPS, 2),
    )
    # Neighbor relationships change much more slowly than the integration
    # timestep. Cache particle pressure once per displayed frame instead of
    # rebuilding its O(n²) distance matrix forty times.
    frame_separation_force = particle_separation_force(
        positions[:NUM_PARTICLES]
    )

    # Take several small midpoint-integration steps per displayed frame. This
    # records the actual curved trajectory instead of drawing long chords
    # between widely spaced 30 FPS positions.
    for substep in range(SIMULATION_SUBSTEPS):
        time_value = frame * DT + substep * substep_dt
        elapsed_ms = (
            frame * INTERVAL_MS
            + substep * INTERVAL_MS / SIMULATION_SUBSTEPS
        )
        substep_active = (
            elapsed_ms
            >= particle_launch_times_ms[:NUM_PARTICLES]
        )

        if np.any(substep_active):
            velocity = velocity_field(
                positions[:NUM_PARTICLES][substep_active],
                time_value,
                frame_separation_force[substep_active],
            )
            midpoint = (
                positions[:NUM_PARTICLES][substep_active]
                + velocity * substep_dt * 0.5
            )
            midpoint_velocity = velocity_field(
                midpoint,
                time_value + substep_dt * 0.5,
                frame_separation_force[substep_active],
            )
            active_indices = np.flatnonzero(substep_active)
            positions[active_indices] += midpoint_velocity * substep_dt

        new_trail_points[:, substep, :] = positions[:NUM_PARTICLES]

    frame_end_ms = (frame + 1) * INTERVAL_MS
    current_elapsed_ms = frame_end_ms
    active = (
        frame_end_ms
        > particle_launch_times_ms[:NUM_PARTICLES]
    )

    # Once a head reaches the right edge, let the line retire naturally.
    head_exited_right = active & (
        positions[:NUM_PARTICLES, 0] >= WIDTH
    )
    retiring[:NUM_PARTICLES] |= head_exited_right

    # Only reset immediately for true escape/error cases.
    hard_reset = active & (
        (positions[:NUM_PARTICLES, 0] < SPAWN_X_MIN - 0.5)
        | (positions[:NUM_PARTICLES, 1] < -0.5)
        | (positions[:NUM_PARTICLES, 1] > HEIGHT + 0.5)
    )

    trails[:NUM_PARTICLES] = np.roll(
        trails[:NUM_PARTICLES],
        -SIMULATION_SUBSTEPS,
        axis=1,
    )
    trails[
        :NUM_PARTICLES,
        -SIMULATION_SUBSTEPS:,
        :,
    ] = new_trail_points

    visible_mask = (
        (trails[:NUM_PARTICLES, :, 0] >= 0.0)
        & (trails[:NUM_PARTICLES, :, 0] <= WIDTH)
        & (trails[:NUM_PARTICLES, :, 1] >= 0.0)
        & (trails[:NUM_PARTICLES, :, 1] <= HEIGHT)
    )

    visible_counts = visible_mask.sum(axis=1)
    retired_and_gone = (
        retiring[:NUM_PARTICLES]
        & (visible_counts < 2)
    )

    reset_now = hard_reset | retired_and_gone
    reset_particles(np.flatnonzero(reset_now))

    # One continuous Line2D artist per particle keeps every trail smooth.
    for particle_index in range(NUM_PARTICLES):
        line = trail_lines[particle_index]
        if active[particle_index]:
            line.set_data(
                trails[particle_index, :, 0],
                trails[particle_index, :, 1],
            )
        else:
            line.set_data([], [])

    if EXPORT_FRAMES:
        FRAME_DIR.mkdir(parents=True, exist_ok=True)
        fig.savefig(
            FRAME_DIR / f"frame_{frame_counter:05d}.png",
            dpi=OUTPUT_DPI,
            facecolor=BACKGROUND,
            edgecolor="none",
            bbox_inches=None,
            pad_inches=0,
        )

    frame_counter += 1
    return trail_lines[:NUM_PARTICLES]


def init_animation():
    """Initialize artists without advancing the simulation."""
    for line in trail_lines:
        line.set_data([], [])
    return trail_lines


def take_screenshot() -> Path:
    """Save the current animation frame as an exact-size timestamped PNG."""
    SCREENSHOT_DIR.mkdir(parents=True, exist_ok=True)
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S_%f")
    output_path = SCREENSHOT_DIR / f"ink_flow_v04_{timestamp}.png"
    fig.savefig(
        output_path,
        dpi=OUTPUT_DPI,
        facecolor=BACKGROUND,
        edgecolor="none",
        bbox_inches=None,
        pad_inches=0,
    )
    print(f"Saved screenshot: {output_path.resolve()}")
    return output_path


def set_flow_rate(flow_rate: float) -> None:
    """Change speed and active trail count while the animation is running."""
    global FLOW_RATE, FLOW_SPEED, NUM_PARTICLES

    old_count = NUM_PARTICLES
    new_count = particle_count_for_flow(flow_rate)

    FLOW_RATE = flow_rate
    FLOW_SPEED = FLOW_RATE * MAX_FLOW_SPEED
    NUM_PARTICLES = new_count

    if new_count > old_count:
        added_indices = np.arange(old_count, new_count)
        reset_particles(added_indices)
        particle_launch_times_ms[added_indices] = (
            current_elapsed_ms
            + np.arange(len(added_indices)) * PARTICLE_LAUNCH_DELAY_MS
        )
    elif new_count < old_count:
        removed_indices = np.arange(new_count, old_count)
        for particle_index in removed_indices:
            trail_lines[particle_index].set_data([], [])
        particle_launch_times_ms[removed_indices] = np.inf
        retiring[removed_indices] = False

    print(
        f"Flow rate: {FLOW_RATE:.3f} | "
        f"speed: {FLOW_SPEED:.2f} | "
        f"trails: {NUM_PARTICLES}"
    )


def on_key_press(event) -> None:
    if not event.key:
        return

    key = event.key.lower()
    if key == SCREENSHOT_KEY:
        take_screenshot()
    elif len(key) == 1 and key.isdigit():
        digit = int(key)
        set_flow_rate(digit / 9.0)


fig.canvas.mpl_connect("key_press_event", on_key_press)


animation = FuncAnimation(
    fig,
    update,
    init_func=init_animation,
    interval=INTERVAL_MS,
    blit=True,
    cache_frame_data=False,
)


def export_animation() -> None:
    total_frames = EXPORT_FPS * EXPORT_SECONDS

    if SAVE_MP4:
        try:
            animation.save(
                OUTPUT_MP4,
                fps=EXPORT_FPS,
                dpi=OUTPUT_DPI,
                writer="ffmpeg",
                savefig_kwargs={"facecolor": BACKGROUND},
            )
            print(f"Saved {OUTPUT_MP4}")
        except Exception as exc:
            print("MP4 export failed.")
            print("Install ffmpeg and make sure it is available on PATH.")
            print(exc)

    if SAVE_GIF:
        try:
            animation.save(
                OUTPUT_GIF,
                fps=EXPORT_FPS,
                dpi=OUTPUT_DPI,
                writer=PillowWriter(fps=EXPORT_FPS),
                savefig_kwargs={"facecolor": BACKGROUND},
            )
            print(f"Saved {OUTPUT_GIF}")
        except Exception as exc:
            print("GIF export failed.")
            print("Install Pillow with: pip install pillow")
            print(exc)


def set_interactive_window_size() -> None:
    """
    Request an exact 1920 × 1080 drawable canvas from the GUI backend.

    Setting figsize and DPI determines the backing image size, but some GUI
    backends apply display scaling when they create the window. FigureManager
    performs the backend-specific conversion needed for Retina/HiDPI screens.
    """
    manager = fig.canvas.manager
    if manager is not None:
        manager.resize(OUTPUT_WIDTH_PX, OUTPUT_HEIGHT_PX)


def main() -> None:
    if SAVE_MP4 or SAVE_GIF:
        export_animation()
    else:
        set_interactive_window_size()
        plt.show()


if __name__ == "__main__":
    main()
