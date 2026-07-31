"""
ink_flow_lines.py

Animated 2D graphic flow lines moving around circular obstacles and
spiraling into drains.

Optional export:
    Set SAVE_MP4 = True and install ffmpeg.
    Set SAVE_GIF = True and install pillow.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass
from pathlib import Path
import math

import numpy as np
import matplotlib.pyplot as plt
from matplotlib.animation import FuncAnimation, PillowWriter
from matplotlib.collections import LineCollection


# --------------------------------------------------
# SETTINGS
# --------------------------------------------------

MAX_PARTICLES = 500
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
        description="Animate river flow with tapered ink trails.",
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

# Zero flow has no trails. Every positive flow starts with the center trail,
# then scales linearly to MAX_PARTICLES at a flow rate of 1.0.
NUM_PARTICLES = (
    0
    if FLOW_RATE == 0.0
    else max(1, round(MAX_PARTICLES * FLOW_RATE))
)
TRAIL_LENGTH = 300
TARGET_FPS = 30
DT = 1.0 / TARGET_FPS
INTERVAL_MS = 1000.0 / TARGET_FPS
PARTICLE_LAUNCH_DELAY_MS = 10
RANDOM_SEED = None

BASE_FLOW_X = 2.0
BASE_FLOW_Y = 0.0

NOISE_STRENGTH = 0.20
NOISE_SCALE = 0.55
NOISE_SPEED = 0.35

# Keep these equal for the original uniform-width appearance. When they differ,
# each particle line receives a stable width spanning this range.
LINE_WIDTH_MIN = 0.5
LINE_WIDTH_MAX = 3.0

# Break each trail into this many separate brushstrokes. Each stroke contains
# roughly 1 / BRUSH_STROKES_PER_TRAIL of the trail's segments.
BRUSH_STROKES_PER_TRAIL = 10
BRUSH_GAP_SEGMENTS = 2
# Each brushstroke is rendered with this many tapered polyline pieces. Every
# piece retains its original trail points, so curves stay smooth.
RENDER_PIECES_PER_BRUSHSTROKE = 5

# Shape the width within each separate brushstroke. The assigned line width
# above is the fullest part; both ends taper to this fraction of it.
BRUSH_END_SCALE = 0.25
BRUSH_PROFILE_POWER = 0.7

PARTICLE_ALPHA = 0.75

BACKGROUND = "black"
LINE_COLOR = "dodgerblue"

SAVE_MP4 = False
SAVE_GIF = False
EXPORT_FRAMES = False

OUTPUT_MP4 = "ink_flow_lines.mp4"
OUTPUT_GIF = "ink_flow_lines.gif"
FRAME_DIR = Path("ink_flow_frames")

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
class Drain:
    x: float
    y: float
    attraction: float = 2.2
    swirl: float = 5.0
    capture_radius: float = 0.18


OBSTACLES = [
    Obstacle(4.0, 3.7, 0.25, strength=1.5, bend=1.3),
    Obstacle(6.8, 2.3, 0.25, strength=1.5, bend=-1.0),
    Obstacle(7.4, 5.1, 0.25, strength=1.5, bend=0.9),
    Obstacle(1.5, 5.5, 0.25, strength=1.5, bend=0.9),
    Obstacle(7.0, 1.25, 0.5, strength=1.0, bend=0.9)
]

DRAINS = [
    #Drain(10.3, 3.5, attraction=2.0, swirl=1.0, capture_radius=0.25),
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


def velocity_field(points: np.ndarray, time_value: float) -> np.ndarray:
    velocity = np.empty_like(points)
    velocity[:, 0] = BASE_FLOW_X
    velocity[:, 1] = BASE_FLOW_Y

    velocity += curl_noise(points, time_value)
    velocity += shore_force(points)

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

    for drain in DRAINS:
        center = np.array([drain.x, drain.y])
        offset = center - points
        inward, distance = safe_normalize(offset, minimum=0.08)

        # Attraction grows slightly as particles approach the drain.
        attraction_strength = drain.attraction * (
            0.65 + 0.9 / (distance + 0.45)
        )
        velocity += inward * attraction_strength[:, None]

        tangent = np.column_stack((-inward[:, 1], inward[:, 0]))
        swirl_strength = drain.swirl / (distance + 0.45)
        velocity += tangent * swirl_strength[:, None]

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


positions = spawn_positions(np.arange(NUM_PARTICLES))
trails = np.repeat(positions[:, None, :], TRAIL_LENGTH
, axis=1)
retiring = np.zeros(NUM_PARTICLES, dtype=bool)
particle_launch_times_ms = (
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


def captured_by_drain(points: np.ndarray) -> np.ndarray:
    captured = np.zeros(len(points), dtype=bool)

    for drain in DRAINS:
        distance_sq = (
            (points[:, 0] - drain.x) ** 2
            + (points[:, 1] - drain.y) ** 2
        )
        captured |= distance_sq < drain.capture_radius ** 2

    return captured


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

line_widths = np.linspace(
    LINE_WIDTH_MIN,
    LINE_WIDTH_MAX,
    NUM_PARTICLES,
)

line_colors = np.random.choice(COLORS, size=NUM_PARTICLES)

def make_render_layout(
    segment_count: int,
) -> tuple[np.ndarray, np.ndarray]:
    """
    Return polyline point indices and width scales for brushstroke pieces.

    Simulation trails retain all their points, but rendering combines several
    adjacent trail segments into a polyline with one width. Keeping the
    intermediate points preserves the flow's curvature while avoiding roughly
    75,000 separately managed Matplotlib paths.
    """
    stroke_length = max(
        1,
        math.ceil(segment_count / BRUSH_STROKES_PER_TRAIL),
    )
    cycle_length = stroke_length + BRUSH_GAP_SEGMENTS
    point_runs = []
    width_scales = []

    for stroke_start in range(0, segment_count, cycle_length):
        actual_length = min(stroke_length, segment_count - stroke_start)
        for piece in range(RENDER_PIECES_PER_BRUSHSTROKE):
            local_start = piece * actual_length // RENDER_PIECES_PER_BRUSHSTROKE
            local_end = (
                (piece + 1)
                * actual_length
                // RENDER_PIECES_PER_BRUSHSTROKE
            )
            if local_end <= local_start:
                continue

            # Segment range [start, end) needs point indices [start, end].
            point_runs.append(
                np.arange(
                    stroke_start + local_start,
                    stroke_start + local_end + 1,
                    dtype=np.intp,
                )
            )
            stroke_position = (piece + 0.5) / RENDER_PIECES_PER_BRUSHSTROKE
            width_scales.append(
                BRUSH_END_SCALE
                + (1.0 - BRUSH_END_SCALE)
                * math.sin(math.pi * stroke_position) ** BRUSH_PROFILE_POWER
            )

    # Pad short runs by repeating their final point. Repeated endpoints do not
    # draw extra geometry and let the complete layout remain one dense array.
    max_points = max(len(run) for run in point_runs)
    point_indices = np.empty((len(point_runs), max_points), dtype=np.intp)
    for row, run in enumerate(point_runs):
        point_indices[row] = run[-1]
        point_indices[row, :len(run)] = run

    return point_indices, np.asarray(width_scales)


render_point_indices, render_width_scales = (
    make_render_layout(TRAIL_LENGTH - 1)
)
render_piece_count, render_points_per_piece = render_point_indices.shape
render_paths = np.full(
    (
        NUM_PARTICLES * render_piece_count,
        render_points_per_piece,
        2,
    ),
    np.nan,
)
render_widths = (
    line_widths[:, None] * render_width_scales[None, :]
).reshape(-1)
render_colors = np.repeat(line_colors, render_piece_count)

stroke_collection = LineCollection(
    render_paths,
    linewidths=render_widths,
    colors=render_colors,
    alpha=PARTICLE_ALPHA,
    capstyle="butt",
    joinstyle="round",
    clip_on=True,
)
ax.add_collection(stroke_collection)

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

for drain in DRAINS:
    ax.add_patch(
        plt.Circle(
            (drain.x, drain.y),
            drain.capture_radius,
            facecolor=BACKGROUND,
            edgecolor=BACKGROUND,
            linewidth=1.0,
            zorder=11,
        )
    )


frame_counter = 0


def update(frame: int):
    global positions, trails, frame_counter, retiring

    time_value = frame * DT
    elapsed_ms = frame * INTERVAL_MS
    active = elapsed_ms >= particle_launch_times_ms

    # Midpoint integration
    if np.any(active):
        velocity = velocity_field(positions[active], time_value)
        midpoint = positions[active] + velocity * DT * 0.5
        midpoint_velocity = velocity_field(
            midpoint,
            time_value + DT * 0.5,
        )
        positions[active] += midpoint_velocity * DT

    # Once a head reaches the right edge, let the line retire naturally.
    head_exited_right = active & (positions[:, 0] >= WIDTH)
    retiring |= head_exited_right

    # Only reset immediately for true escape/error cases.
    hard_reset = active & (
        (positions[:, 0] < SPAWN_X_MIN - 0.5)
        | (positions[:, 1] < -0.5)
        | (positions[:, 1] > HEIGHT + 0.5)
        | captured_by_drain(positions)
    )

    trails = np.roll(trails, -1, axis=1)
    trails[:, -1, :] = positions

    visible_mask = (
        (trails[:, :, 0] >= 0.0)
        & (trails[:, :, 0] <= WIDTH)
        & (trails[:, :, 1] >= 0.0)
        & (trails[:, :, 1] <= HEIGHT)
    )

    visible_counts = visible_mask.sum(axis=1)
    retired_and_gone = retiring & (visible_counts < 2)

    reset_now = hard_reset | retired_and_gone
    reset_particles(np.flatnonzero(reset_now))

    # Build all render geometry in one NumPy operation. Inactive or degenerate
    # pieces receive NaN coordinates, which Matplotlib skips without requiring
    # per-particle Python lists, color rebuilding, or width rebuilding.
    piece_paths = trails[:, render_point_indices, :]
    piece_delta = piece_paths[:, :, -1, :] - piece_paths[:, :, 0, :]
    drawable = active[:, None] & (
        np.einsum("ijk,ijk->ij", piece_delta, piece_delta) > 1e-12
    )

    render_paths[:] = piece_paths.reshape(
        -1,
        render_points_per_piece,
        2,
    )
    render_paths[~drawable.reshape(-1)] = np.nan
    stroke_collection.set_segments(render_paths)

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
    return [stroke_collection]

animation = FuncAnimation(
    fig,
    update,
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
