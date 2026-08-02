"""
ink_flow_lines_v04.py

Animated 2D graphic flow lines moving around circular, rectangular,
and polygonal obstacles, absorbers, and reservoirs.

Optional export:
    Set SAVE_MP4 = True and install ffmpeg.
    Set SAVE_GIF = True and install pillow.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass, replace
from datetime import datetime
from pathlib import Path
import math

import numpy as np
import matplotlib.pyplot as plt
from matplotlib.animation import FuncAnimation, PillowWriter
from matplotlib.collections import LineCollection
from matplotlib.colors import to_rgba_array
from matplotlib.patches import Arc, Circle, Polygon as PolygonPatch


# --------------------------------------------------
# SETTINGS
# --------------------------------------------------

# The simulation world is the final 16 x 9 patch layout.  One world unit is
# one 120 px patch, so the axes map directly to the installation grid.
GRID_COLUMNS = 16
GRID_ROWS = 9
PATCH_SIZE_PX = 120
OUTPUT_WIDTH_PX = GRID_COLUMNS * PATCH_SIZE_PX
OUTPUT_HEIGHT_PX = GRID_ROWS * PATCH_SIZE_PX
OUTPUT_DPI = 120
WIDTH = float(GRID_COLUMNS)
HEIGHT = float(GRID_ROWS)

# v04 was tuned in a seven-unit-high 16:9 world.  Spatial values are migrated
# by this uniform factor so the 9 x 16 refactor does not change the image.
LEGACY_WORLD_HEIGHT = 7.0
WORLD_SCALE = HEIGHT / LEGACY_WORLD_HEIGHT

MAX_PARTICLES = 300
# Reservoir water has its own bounded set of drawable trails. Those slots do
# not count against source trails, so a full reservoir cannot stop the inlet.
RESERVOIR_RETENTION_CAPACITY = 100
PARTICLE_POOL_SIZE = MAX_PARTICLES + RESERVOIR_RETENTION_CAPACITY
MAX_FLOW_SPEED = 10.0
DEFAULT_FLOW_RATE = 0.5
PARTICLE_FLOW_VARIATION = 0.1
MIN_ACTIVE_PARTICLE_FLOW = 0.001


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

BASE_FLOW_X = 2.0 * WORLD_SCALE
BASE_FLOW_Y = 0.0

NOISE_STRENGTH = 0.6 * WORLD_SCALE
NOISE_SCALE = 1.5 / WORLD_SCALE
NOISE_SPEED = 0.75

# Soft particle pressure prevents neighboring trails from collapsing onto the
# same path after they pass an obstacle.
PARTICLE_SEPARATION_RADIUS = 0.075 * WORLD_SCALE
PARTICLE_SEPARATION_STRENGTH = 0.85 * WORLD_SCALE
PARTICLE_SEPARATION_X_SCALE = 0.15
PARTICLE_SEPARATION_MAX_FORCE = 1.0 * WORLD_SCALE

# Each trail receives one stable random width from this range.
LINE_WIDTH_MIN = 0.5
LINE_WIDTH_MAX = 3.0

PARTICLE_ALPHA = 1.0

BACKGROUND = "black"
LINE_COLOR = "dodgerblue"

SAVE_MP4 = False
SAVE_GIF = False
EXPORT_FRAMES = False

OUTPUT_MP4 = "ink_flow_lines_v04.mp4"
OUTPUT_GIF = "ink_flow_lines_v04.gif"
FRAME_DIR = Path("ink_flow_frames_v04")
SCREENSHOT_KEY = "f12"
SCREENSHOT_DIR = Path("ink_flow_screenshots_v04")
SALMON_RELEASE_KEY = "s"
SALMON_PER_RELEASE = 25
MAX_SALMON = 300
SALMON_LENGTH_PX = 50.0
SALMON_LINE_WIDTH = 2.0
SALMON_FADE_SECONDS = 0.5
SALMON_HISTORY_POINTS = 160
SALMON_MOTION_THRESHOLD_PX = 1.0
SALMON_RETURN_RATE = 0.75
SALMON_DAM_APPROACH_PX = 14.0
SALMON_DAM_PASSAGE_SPEED_PX = 180.0
SALMON_SPAWN_OFFSET = 0.05 * WORLD_SCALE
SALMON_WATER_RADIUS_PX = 10.0
SALMON_LOOKAHEAD_PX = 8.0
WATER_GRID_CELL_PX = 4.0
GATE_TOGGLE_KEY = "g"
GATE_NARROW_KEY = "["
GATE_WIDEN_KEY = "]"
GATE_WIDTH_STEP = 0.05 * WORLD_SCALE
# At a fully open gate, retained lines accumulate this many release-progress
# units per second. Aperture scales the rate linearly; every nonzero aperture
# therefore releases all retained lines eventually.
RESERVOIR_RELEASE_RATE = 2.0
RESERVOIR_RELEASE_THRESHOLD_MIN = 0.5
RESERVOIR_RELEASE_THRESHOLD_MAX = 1.5
ACTIVE_RESERVOIR_INDEX = 0
VISIBILITY_TOGGLE_KEY = "v"
DEBUG_GEOMETRY_VISIBLE = True
DEBUG_GEOMETRY_COLOR = "orange"
DEBUG_GEOMETRY_LINE_WIDTH = 1.5

EXPORT_FPS = 30
EXPORT_SECONDS = 12

# All trails enter from one aligned inlet just outside the visible left edge.
# This preserves the evenly spaced wind-tunnel appearance at x=0.
SPAWN_X = -0.05 * WORLD_SCALE

COLORS = np.array([
    "#FFFFFF",  # white
    "#EAF7EE",
    "#D3EFDC",
    "#ACE1AF",  # celadon
    "#7BCFC4",
    "#4AB0E1",
    "#1E90FF",  # dodger blue
])

SALMON_COLORS = np.array([
    "#FF5C8A",  # pink
    "#FF7A72",
    "#FF8C42",  # orange
    "#FFAD33",
    "#FFD23F",  # yellow
])

# Riverbank settings
SHORE_INFLUENCE = 0.85 * WORLD_SCALE
SHORE_STRENGTH = 4.0 * WORLD_SCALE
SHORE_POWER = 2.0
# Keep both effective banks the same distance outside the visible frame so
# their repulsion profiles are exact vertical mirrors.
BOTTOM_SHORE_Y_OFFSET = 0.5 * WORLD_SCALE
TOP_SHORE_Y_OFFSET = 0.5 * WORLD_SCALE

SPAWN_Y_MARGIN = 0.15 * WORLD_SCALE



@dataclass(frozen=True)
class Obstacle:
    x: float
    y: float
    radius: float
    strength: float = 4.0 * WORLD_SCALE
    bend: float = 1.0 * WORLD_SCALE


@dataclass(frozen=True)
class RectangleObstacle:
    x: float
    y: float
    width: float
    height: float
    angle_degrees: float = 0.0
    strength: float = 4.0 * WORLD_SCALE
    bend: float = 1.0 * WORLD_SCALE
    influence: float = 0.65 * WORLD_SCALE


@dataclass(frozen=True)
class PolygonObstacle:
    vertices: tuple[tuple[float, float], ...]
    strength: float = 4.0 * WORLD_SCALE
    bend: float = 1.0 * WORLD_SCALE
    influence: float = 0.65 * WORLD_SCALE


@dataclass(frozen=True)
class Absorber:
    """An axis-aligned area that permanently consumes some passing trails."""

    x: float
    y: float
    width: float
    height: float
    absorption_fraction: float = 1.0
    stop_margin_fraction: float = 0.12


@dataclass(frozen=True)
class Reservoir:
    """A circular pool with an open upstream face and downstream gate.

    Flow is assumed to travel in the positive X direction.  The upstream
    diameter (x <= center x) admits every line within the reservoir radius.
    The downstream semicircle retains those lines except at the centered
    gate when ``gate_open`` is true.
    """

    x: float
    y: float
    radius: float
    outlet_width: float
    gate_open: bool = True
    circulation: float = 1.0
    swirl_strength: float = 2.4 * WORLD_SCALE
    confinement_strength: float = 3.2
    wall_strength: float = 8.0 * WORLD_SCALE
    outlet_strength: float = 4.0 * WORLD_SCALE
    wall_influence: float = 0.22 * WORLD_SCALE
    orbit_radius_fraction: float = 0.62
    orbit_radius_spread: float = 0.52


OBSTACLES = [
    #Obstacle(4.0, 3.7, 0.25, strength=1.5, bend=1.3),
    #Obstacle(6.8, 2.3, 0.25, strength=1.5, bend=-1.0),
]

RECTANGLE_OBSTACLES = [
    # Coordinates specify the rectangle center. Rotation is counterclockwise.
    RectangleObstacle(
        7.7142857143,
        4.5,
        width=2.5714285714,
        height=2.5714285714,
        angle_degrees=45.0,
        strength=0.3214285714,
        bend=-1.0285714286,
    ),
]

POLYGON_OBSTACLES = [
    # Vertices can define any non-self-intersecting polygon.
    #PolygonObstacle(((8.65, 3.05),(9.25, 3.25),(8.85, 3.75),),strength=1.5,bend=0.9,),
]

# Absorption is assigned stably per trail. A selected trail enters the absorber,
# stops at a deterministic-random interior depth, and then erodes point by
# point instead of vanishing all at once.
ABSORBERS = [
    Absorber(
        3.5,
        8.5,
        width=0.5,
        height=0.5,
        absorption_fraction=0.6,
    ),
    Absorber(
        3.5,
        7.5,
        width=0.5,
        height=0.5,
        absorption_fraction=0.6,
    ),
    Absorber(
        3.5,
        6.5,
        width=0.5,
        height=0.5,
        absorption_fraction=0.6,
    ),
    Absorber(
        3.5,
        5.5,
        width=0.5,
        height=0.5,
        absorption_fraction=0.6,
    ),
    Absorber(
        3.5,
        4.5,
        width=0.5,
        height=0.5,
        absorption_fraction=0.6,
    ),
    Absorber(
        3.5,
        3.5,
        width=0.5,
        height=0.5,
        absorption_fraction=0.6,
    ),
    Absorber(
        3.5,
        2.5,
        width=0.5,
        height=0.5,
        absorption_fraction=0.6,
    ),

    Absorber(
        3.5,
        1.5,
        width=0.5,
        height=0.5,
        absorption_fraction=0.6,
    ),
        Absorber(
        3.5,
        0.5,
        width=0.5,
        height=0.5,
        absorption_fraction=0.6,
    ),
]

# Reservoirs face flow traveling from left to right.  Lines enter across the
# complete upstream diameter, circulate inside, then leave through the centered
# gap in the downstream semicircle.  Set gate_open=False to retain the water.
RESERVOIRS = [
    Reservoir(
        11.5714285714,
        2.5714285714,
        radius=1.8642857143,
        outlet_width=0.1285714286,
        gate_open=True,
        circulation=2.0,  # positive is counterclockwise; negative is clockwise
    ),
]

# --------------------------------------------------
# SIMULATION
# --------------------------------------------------

rng = np.random.default_rng(RANDOM_SEED)

# Give each line one stable offset around the core flow value.  A
# low-discrepancy sequence fills the complete variation range evenly without
# making line speeds jump when the user changes the core flow at runtime.
particle_flow_offsets = (
    np.mod(
        (np.arange(PARTICLE_POOL_SIZE) + 1) * 0.6180339887498949,
        1.0,
    )
    * (PARTICLE_FLOW_VARIATION * 2.0)
    - PARTICLE_FLOW_VARIATION
)

def shore_force(points: np.ndarray) -> np.ndarray:
    """
    Push particles away from the top and bottom riverbanks.

    The force starts gently at SHORE_INFLUENCE distance and becomes
    stronger as a particle approaches or crosses a shore.
    """
    y = points[:, 1]

    distance_from_bottom = y + BOTTOM_SHORE_Y_OFFSET
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


def safe_normalize(
    vectors: np.ndarray,
    minimum: float = 0.05 * WORLD_SCALE,
) -> tuple[np.ndarray, np.ndarray]:
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


def reservoir_gate_fraction(reservoir: Reservoir) -> float:
    """Return normalized aperture from closed (0) to full diameter (1)."""
    return float(np.clip(
        reservoir.outlet_width / (2.0 * reservoir.radius),
        0.0,
        1.0,
    ))


def reservoir_force(
    points: np.ndarray,
    reservoir: Reservoir,
    reservoir_index: int,
    particle_indices: np.ndarray | None = None,
) -> np.ndarray:
    """Pool lines until their aperture-controlled release becomes ready."""
    if particle_indices is None:
        particle_indices = np.arange(len(points), dtype=np.intp)
    else:
        particle_indices = np.asarray(particle_indices, dtype=np.intp)
        if len(particle_indices) != len(points):
            raise ValueError(
                "particle_indices must contain one index per point"
            )

    center = np.array((reservoir.x, reservoir.y))
    local = points - center
    radial, distance = safe_normalize(local, minimum=1e-8)
    force = np.zeros_like(points)

    inside = distance < reservoir.radius
    downstream_half = local[:, 0] >= 0.0
    half_gate_width = np.clip(
        reservoir.outlet_width * 0.5,
        0.0,
        reservoir.radius,
    )
    in_gate = (
        downstream_half
        & (np.abs(local[:, 1]) <= half_gate_width)
    )

    # Readiness is latched: aperture controls how quickly it is reached, but a
    # ready line stays eligible through subsequent laps until it finds the gap.
    selected_for_release = (
        reservoir_release_ready[particle_indices]
        & (retained_reservoir_indices[particle_indices] == reservoir_index)
    )
    usable_gate = in_gate & reservoir.gate_open & selected_for_release

    release = inside & usable_gate
    pooling = inside & ~release

    if np.any(pooling):
        # Remove the river's uniform downstream push while the water is held.
        # Tangential motion creates the visible circular pooling pattern.
        force[pooling, 0] -= BASE_FLOW_X
        force[pooling, 1] -= BASE_FLOW_Y

        tangent = np.column_stack((-radial[:, 1], radial[:, 0]))
        force[pooling] += tangent[pooling] * (
            reservoir.swirl_strength * reservoir.circulation
        )

        # Give every trail a stable orbit within a broad annulus.  Previously
        # all trails converged on one target radius and visually piled up.
        orbit_sample = np.mod(
            (particle_indices + 1) * 0.7548776662466927,
            1.0,
        )
        target_radius_fraction = np.clip(
            reservoir.orbit_radius_fraction
            + (orbit_sample - 0.5) * reservoir.orbit_radius_spread,
            0.08,
            0.94,
        )
        target_radius = (
            reservoir.radius * target_radius_fraction[pooling]
        )
        radial_error = target_radius - distance[pooling]
        force[pooling] += radial[pooling] * (
            radial_error * reservoir.confinement_strength
        )[:, None]

    if np.any(release):
        # Straighten circulating lines into the outlet and restore a decisive
        # downstream movement through the opening.
        gate_center = np.array(
            (reservoir.x + reservoir.radius, reservoir.y)
        )
        toward_gate, _ = safe_normalize(
            gate_center - points[release],
            minimum=1e-8,
        )
        force[release] += toward_gate * reservoir.outlet_strength
        force[release, 0] += BASE_FLOW_X
        force[release, 1] -= local[release, 1] * (
            reservoir.outlet_strength
            / max(half_gate_width, 0.05 * WORLD_SCALE)
        )

    # Only the downstream semicircle is a wall.  Its centered section is
    # omitted for an open gate, and retained for a closed gate.
    # A line not selected for release experiences the gate section as closed.
    wall_has_gate = usable_gate
    wall_distance = np.abs(distance - reservoir.radius)
    near_wall = (
        downstream_half
        & ~wall_has_gate
        & (wall_distance < reservoir.wall_influence)
    )
    if np.any(near_wall):
        wall_weight = (
            1.0
            - wall_distance[near_wall] / reservoir.wall_influence
        ) ** 2
        # Points on either side are pushed away from the wall, preventing a
        # numerical integration step from leaking through the solid arc.
        wall_side = np.where(
            distance[near_wall] < reservoir.radius,
            -1.0,
            1.0,
        )
        force[near_wall] += radial[near_wall] * (
            reservoir.wall_strength * wall_weight * wall_side
        )[:, None]

    return force


def reservoir_pooling_mask(
    points: np.ndarray,
    reservoir: Reservoir,
    reservoir_index: int,
    particle_indices: np.ndarray,
) -> np.ndarray:
    """Return source heads retained by this reservoir at these positions."""
    particle_indices = np.asarray(particle_indices, dtype=np.intp)
    local = points - np.array((reservoir.x, reservoir.y))
    distance = np.linalg.norm(local, axis=1)
    inside = distance < reservoir.radius
    half_gate_width = np.clip(
        reservoir.outlet_width * 0.5,
        0.0,
        reservoir.radius,
    )
    in_gate = (
        (local[:, 0] >= 0.0)
        & (np.abs(local[:, 1]) <= half_gate_width)
    )
    selected_for_release = (
        reservoir_release_ready[particle_indices]
        & (retained_reservoir_indices[particle_indices] == reservoir_index)
    )
    released = (
        inside
        & in_gate
        & reservoir.gate_open
        & selected_for_release
    )
    return inside & ~released


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
    particle_indices: np.ndarray | None = None,
) -> np.ndarray:
    if particle_indices is None:
        particle_indices = np.arange(len(points), dtype=np.intp)
    else:
        particle_indices = np.asarray(particle_indices, dtype=np.intp)
        if len(particle_indices) != len(points):
            raise ValueError(
                "particle_indices must contain one index per point"
            )

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

    for reservoir_index, reservoir in enumerate(RESERVOIRS):
        velocity += reservoir_force(
            points,
            reservoir,
            reservoir_index,
            particle_indices,
        )

    # Lines retired by a flow-rate reduction keep their previous speed until
    # their complete tails leave the frame. All other lines use the live rate.
    base_flow_rates = np.full(len(points), FLOW_RATE)
    retirement_overrides = retirement_flow_rates[particle_indices]
    has_retirement_override = np.isfinite(retirement_overrides)
    base_flow_rates[has_retirement_override] = retirement_overrides[
        has_retirement_override
    ]

    particle_flow_rates = np.zeros(len(points))
    flowing = base_flow_rates > 0.0
    particle_flow_rates[flowing] = np.clip(
        base_flow_rates[flowing]
        + particle_flow_offsets[particle_indices[flowing]],
        MIN_ACTIVE_PARTICLE_FLOW,
        1.0,
    )
    # MAX_FLOW_SPEED remains the user-facing 0..10 value. WORLD_SCALE converts
    # it to the new 16 x 9 coordinate system without changing pixel velocity.
    particle_max_speeds = (
        particle_flow_rates * MAX_FLOW_SPEED * WORLD_SCALE
    )
    velocity *= (particle_max_speeds / BASE_FLOW_X)[:, None]

    # Cap speed so particles do not jump through obstacles.
    speed = np.linalg.norm(velocity, axis=1)
    fast = speed > particle_max_speeds
    if np.any(fast):
        velocity[fast] *= (
            particle_max_speeds[fast] / speed[fast]
        )[:, None]

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
            np.full(count, SPAWN_X),
            alternating_spawn_y(particle_indices),
        )
    )


positions = np.full((PARTICLE_POOL_SIZE, 2), np.nan)
positions[:MAX_PARTICLES] = spawn_positions(np.arange(MAX_PARTICLES))
trails = np.full((PARTICLE_POOL_SIZE, TRAIL_LENGTH, 2), np.nan)
trails[:MAX_PARTICLES] = np.repeat(
    positions[:MAX_PARTICLES, None, :],
    TRAIL_LENGTH,
    axis=1,
)
retiring = np.zeros(PARTICLE_POOL_SIZE, dtype=bool)
absorber_indices = np.full(PARTICLE_POOL_SIZE, -1, dtype=np.intp)
absorption_target_x = np.full(PARTICLE_POOL_SIZE, np.nan)
absorbed = np.zeros(PARTICLE_POOL_SIZE, dtype=bool)
particle_launch_times_ms = np.full(PARTICLE_POOL_SIZE, np.inf)
particle_launch_times_ms[:NUM_PARTICLES] = (
    np.arange(NUM_PARTICLES) * PARTICLE_LAUNCH_DELAY_MS
)
# A finite value preserves the speed a source had when it was retired by a
# runtime flow reduction. NaN means that the slot follows the live FLOW_RATE.
retirement_flow_rates = np.full(PARTICLE_POOL_SIZE, np.nan)
retained = np.zeros(PARTICLE_POOL_SIZE, dtype=bool)
retention_birth_ms = np.full(PARTICLE_POOL_SIZE, np.inf)
retained_reservoir_indices = np.full(
    PARTICLE_POOL_SIZE,
    -1,
    dtype=np.intp,
)
reservoir_release_progress = np.zeros(PARTICLE_POOL_SIZE)
reservoir_release_thresholds = np.full(PARTICLE_POOL_SIZE, np.inf)
reservoir_release_ready = np.zeros(PARTICLE_POOL_SIZE, dtype=bool)

DATA_UNITS_PER_PIXEL = WIDTH / OUTPUT_WIDTH_PX
SALMON_LENGTH_DATA = SALMON_LENGTH_PX * DATA_UNITS_PER_PIXEL
SALMON_WATER_RADIUS_DATA = (
    SALMON_WATER_RADIUS_PX * DATA_UNITS_PER_PIXEL
)
SALMON_LOOKAHEAD_DATA = SALMON_LOOKAHEAD_PX * DATA_UNITS_PER_PIXEL
SALMON_MOTION_THRESHOLD_DATA = (
    SALMON_MOTION_THRESHOLD_PX * DATA_UNITS_PER_PIXEL
)
SALMON_DAM_APPROACH_DATA = SALMON_DAM_APPROACH_PX * DATA_UNITS_PER_PIXEL
SALMON_DAM_PASSAGE_SPEED_DATA = (
    SALMON_DAM_PASSAGE_SPEED_PX * DATA_UNITS_PER_PIXEL
)
WATER_GRID_CELL_SIZE = WATER_GRID_CELL_PX * DATA_UNITS_PER_PIXEL

SALMON_STATE_UPSTREAM = 0
SALMON_STATE_ENTERING = 1
SALMON_STATE_RETREATING = 2

salmon_positions = np.full((MAX_SALMON, 2), np.nan)
salmon_trails = np.full(
    (MAX_SALMON, SALMON_HISTORY_POINTS, 2),
    np.nan,
)
salmon_active = np.zeros(MAX_SALMON, dtype=bool)
salmon_fading = np.zeros(MAX_SALMON, dtype=bool)
salmon_fade_started_ms = np.full(MAX_SALMON, np.nan)
salmon_birth_ms = np.full(MAX_SALMON, -np.inf)
salmon_states = np.full(MAX_SALMON, SALMON_STATE_UPSTREAM, dtype=np.int8)
salmon_reservoir_indices = np.full(MAX_SALMON, -1, dtype=np.intp)
salmon_passed_reservoir = np.zeros(
    (MAX_SALMON, len(RESERVOIRS)),
    dtype=bool,
)
salmon_source_indices = np.arange(MAX_SALMON) % MAX_PARTICLES
salmon_rgba = to_rgba_array(
    rng.choice(SALMON_COLORS, size=MAX_SALMON)
)


def reset_particles(indices: np.ndarray) -> None:
    global retiring

    if len(indices) == 0:
        return

    new_positions = spawn_positions(indices)
    positions[indices] = new_positions
    trails[indices, :, :] = new_positions[:, None, :]
    retiring[indices] = False
    absorber_indices[indices] = -1
    absorption_target_x[indices] = np.nan
    absorbed[indices] = False
    retirement_flow_rates[indices] = np.nan
    retained_reservoir_indices[indices] = -1
    reservoir_release_progress[indices] = 0.0
    reservoir_release_thresholds[indices] = np.inf
    reservoir_release_ready[indices] = False


def deactivate_source_particles(indices: np.ndarray) -> None:
    """Free completed source slots that are above the current spawn target."""
    indices = np.asarray(indices, dtype=np.intp)
    if len(indices) == 0:
        return

    positions[indices] = np.nan
    trails[indices] = np.nan
    retiring[indices] = False
    absorber_indices[indices] = -1
    absorption_target_x[indices] = np.nan
    absorbed[indices] = False
    particle_launch_times_ms[indices] = np.inf
    retirement_flow_rates[indices] = np.nan
    retained_reservoir_indices[indices] = -1
    reservoir_release_progress[indices] = 0.0
    reservoir_release_thresholds[indices] = np.inf
    reservoir_release_ready[indices] = False
    for particle_index in indices:
        trail_lines[particle_index].set_data([], [])


def deactivate_retained_particles(indices: np.ndarray) -> None:
    """Free retained-water slots without respawning them at the inlet."""
    indices = np.asarray(indices, dtype=np.intp)
    if len(indices) == 0:
        return

    positions[indices] = np.nan
    trails[indices] = np.nan
    retiring[indices] = False
    absorber_indices[indices] = -1
    absorption_target_x[indices] = np.nan
    absorbed[indices] = False
    particle_launch_times_ms[indices] = np.inf
    retirement_flow_rates[indices] = np.nan
    retained[indices] = False
    retention_birth_ms[indices] = np.inf
    retained_reservoir_indices[indices] = -1
    reservoir_release_progress[indices] = 0.0
    reservoir_release_thresholds[indices] = np.inf
    reservoir_release_ready[indices] = False
    for particle_index in indices:
        trail_lines[particle_index].set_data([], [])


def claim_retention_slots(count: int, elapsed_ms: float) -> np.ndarray:
    """Claim free reservoir slots, recycling the oldest retained water."""
    if count <= 0:
        return np.empty(0, dtype=np.intp)

    retention_slots = np.arange(MAX_PARTICLES, PARTICLE_POOL_SIZE)
    free = retention_slots[~retained[retention_slots]]
    claimed = list(free[:count])
    remaining = count - len(claimed)

    if remaining > 0:
        occupied = retention_slots[retained[retention_slots]]
        oldest = occupied[
            np.argsort(retention_birth_ms[occupied])[:remaining]
        ]
        deactivate_retained_particles(oldest)
        claimed.extend(oldest.tolist())

    claimed_array = np.asarray(claimed, dtype=np.intp)
    retention_birth_ms[claimed_array] = elapsed_ms
    return claimed_array


def retain_source_particles(
    source_indices: np.ndarray,
    reservoir_index: int,
    elapsed_ms: float,
    new_trail_points: np.ndarray,
    substep: int,
    newly_retained_steps: np.ndarray,
) -> None:
    """Move source histories into reservoir storage, then reopen the sources."""
    source_indices = np.asarray(source_indices, dtype=np.intp)
    if len(source_indices) == 0:
        return

    retention_indices = claim_retention_slots(
        len(source_indices),
        elapsed_ms,
    )
    for source_index, retention_index in zip(
        source_indices,
        retention_indices,
    ):
        # Include samples already integrated in this frame so the copied line
        # remains continuous all the way into the reservoir.
        samples = new_trail_points[source_index, :substep + 1]
        samples = samples[np.isfinite(samples[:, 0])]
        source_history = trails[source_index]
        source_history = source_history[np.isfinite(source_history[:, 0])]
        combined = np.concatenate((source_history, samples), axis=0)
        combined = combined[-TRAIL_LENGTH:]

        trails[retention_index] = np.nan
        trails[retention_index, -len(combined):] = combined
        positions[retention_index] = positions[source_index]
        particle_flow_offsets[retention_index] = particle_flow_offsets[
            source_index
        ]
        retirement_flow_rates[retention_index] = retirement_flow_rates[
            source_index
        ]
        particle_launch_times_ms[retention_index] = elapsed_ms
        retained[retention_index] = True
        retained_reservoir_indices[retention_index] = reservoir_index
        reservoir_release_progress[retention_index] = 0.0
        reservoir_release_thresholds[retention_index] = rng.uniform(
            RESERVOIR_RELEASE_THRESHOLD_MIN,
            RESERVOIR_RELEASE_THRESHOLD_MAX,
        )
        reservoir_release_ready[retention_index] = False
        retiring[retention_index] = False
        absorbed[retention_index] = False
        newly_retained_steps[retention_index] = substep

        # Preserve the line's appearance when its history changes artists.
        line_widths[retention_index] = line_widths[source_index]
        line_colors[retention_index] = line_colors[source_index]
        retained_line = trail_lines[retention_index]
        retained_line.set_color(line_colors[source_index])
        retained_line.set_linewidth(line_widths[source_index])
        retained_line.set_markersize(line_widths[source_index])
        retained_line.set_markerfacecolor(line_colors[source_index])
        retained_line.set_markeredgecolor(line_colors[source_index])

    # Reopen only source slots still included in the current flow target. A
    # source retired by a rate reduction ends here while its copied history
    # continues naturally as retained reservoir water.
    transferred_sources = source_indices[:len(retention_indices)]
    continuing_sources = transferred_sources[
        transferred_sources < NUM_PARTICLES
    ]
    ending_sources = transferred_sources[
        transferred_sources >= NUM_PARTICLES
    ]
    reset_particles(continuing_sources)
    particle_launch_times_ms[continuing_sources] = elapsed_ms
    new_trail_points[continuing_sources, :substep + 1] = positions[
        continuing_sources, None, :
    ]
    deactivate_source_particles(ending_sources)
    new_trail_points[ending_sources] = np.nan


def transfer_new_reservoir_water(
    source_indices: np.ndarray,
    elapsed_ms: float,
    new_trail_points: np.ndarray,
    substep: int,
    newly_retained_steps: np.ndarray,
) -> None:
    """Detach newly pooled source lines from their reusable inlet slots."""
    eligible = np.asarray(source_indices, dtype=np.intp)
    for reservoir_index, reservoir in enumerate(RESERVOIRS):
        if len(eligible) == 0:
            return
        pooling = reservoir_pooling_mask(
            positions[eligible],
            reservoir,
            reservoir_index,
            eligible,
        )
        captured = eligible[pooling]
        retain_source_particles(
            captured,
            reservoir_index,
            elapsed_ms,
            new_trail_points,
            substep,
            newly_retained_steps,
        )
        eligible = eligible[~pooling]


def update_reservoir_release_progress(
    particle_indices: np.ndarray,
    timestep: float,
) -> None:
    """Advance retained lines toward release at the live aperture rate."""
    particle_indices = np.asarray(particle_indices, dtype=np.intp)
    retained_indices = particle_indices[retained[particle_indices]]
    if len(retained_indices) == 0:
        return

    for reservoir_index, reservoir in enumerate(RESERVOIRS):
        if not reservoir.gate_open:
            continue
        aperture = reservoir_gate_fraction(reservoir)
        if aperture <= 0.0:
            continue

        waiting = retained_indices[
            (retained_reservoir_indices[retained_indices] == reservoir_index)
            & ~reservoir_release_ready[retained_indices]
        ]
        if len(waiting) == 0:
            continue

        reservoir_release_progress[waiting] += (
            aperture * RESERVOIR_RELEASE_RATE * timestep
        )
        reservoir_release_ready[waiting] = (
            reservoir_release_progress[waiting]
            >= reservoir_release_thresholds[waiting]
        )


def absorber_bounds(
    absorber: Absorber,
) -> tuple[float, float, float, float]:
    """Return left, right, bottom, and top edges for an absorber."""
    return (
        absorber.x - absorber.width * 0.5,
        absorber.x + absorber.width * 0.5,
        absorber.y - absorber.height * 0.5,
        absorber.y + absorber.height * 0.5,
    )


def update_absorption_states(particle_indices: np.ndarray) -> None:
    """Assign eligible trails and stop them inside absorbers."""
    particle_indices = np.asarray(particle_indices, dtype=np.intp)
    if len(particle_indices) == 0:
        return

    for absorber_index, absorber in enumerate(ABSORBERS):
        left, right, bottom, top = absorber_bounds(absorber)
        points = positions[particle_indices]
        unassigned = absorber_indices[particle_indices] < 0
        inside = (
            (points[:, 0] >= left)
            & (points[:, 0] <= right)
            & (points[:, 1] >= bottom)
            & (points[:, 1] <= top)
        )

        # Low-discrepancy samples make the percentage stable across frames and
        # repeated particle lifecycles while still looking randomly selected.
        selection_sample = np.mod(
            (particle_indices + 1) * 0.6180339887498949
            + (absorber_index + 1) * 0.4142135623730950,
            1.0,
        )
        selected = selection_sample < np.clip(
            absorber.absorption_fraction,
            0.0,
            1.0,
        )
        newly_assigned = unassigned & inside & selected

        if np.any(newly_assigned):
            assigned_indices = particle_indices[newly_assigned]
            margin_fraction = float(np.clip(
                absorber.stop_margin_fraction,
                0.0,
                0.49,
            ))
            stop_sample = np.mod(
                (assigned_indices + 1) * 0.7548776662466927
                + (absorber_index + 1) * 0.5698402909980532,
                1.0,
            )
            absorber_indices[assigned_indices] = absorber_index
            absorption_target_x[assigned_indices] = (
                left
                + absorber.width
                * (
                    margin_fraction
                    + stop_sample * (1.0 - 2.0 * margin_fraction)
                )
            )

        tracking = particle_indices[
            (absorber_indices[particle_indices] == absorber_index)
            & ~absorbed[particle_indices]
        ]
        if len(tracking) == 0:
            continue

        # Once selected, keep the trail inside the orchard until it reaches
        # its stopping depth. This guarantees disappearance in the absorber.
        interior_margin = min(absorber.width, absorber.height) * 0.005
        positions[tracking, 1] = np.clip(
            positions[tracking, 1],
            bottom + interior_margin,
            top - interior_margin,
        )
        reached_target = (
            positions[tracking, 0]
            >= absorption_target_x[tracking]
        )
        if np.any(reached_target):
            stopped_indices = tracking[reached_target]
            positions[stopped_indices, 0] = absorption_target_x[
                stopped_indices
            ]
            absorbed[stopped_indices] = True


def build_water_occupancy_grid() -> np.ndarray:
    """Rasterize current water trails into a softly dilated lookup grid."""
    grid_width = math.ceil(WIDTH / WATER_GRID_CELL_SIZE) + 1
    grid_height = math.ceil(HEIGHT / WATER_GRID_CELL_SIZE) + 1
    grid = np.zeros((grid_height, grid_width), dtype=bool)

    active_water_slots = np.flatnonzero(
        particle_launch_times_ms <= current_elapsed_ms
    )
    if len(active_water_slots) == 0:
        return grid

    water_points = trails[active_water_slots].reshape(-1, 2)
    valid = (
        np.isfinite(water_points[:, 0])
        & np.isfinite(water_points[:, 1])
        & (water_points[:, 0] >= 0.0)
        & (water_points[:, 0] <= WIDTH)
        & (water_points[:, 1] >= 0.0)
        & (water_points[:, 1] <= HEIGHT)
    )
    water_points = water_points[valid]
    if len(water_points) == 0:
        return grid

    grid_x = np.clip(
        (water_points[:, 0] / WATER_GRID_CELL_SIZE).astype(np.intp),
        0,
        grid_width - 1,
    )
    grid_y = np.clip(
        (water_points[:, 1] / WATER_GRID_CELL_SIZE).astype(np.intp),
        0,
        grid_height - 1,
    )
    grid[grid_y, grid_x] = True

    radius_cells = max(
        1,
        math.ceil(SALMON_WATER_RADIUS_DATA / WATER_GRID_CELL_SIZE),
    )
    padded = np.pad(grid, radius_cells)
    dilated = np.zeros_like(grid)
    for offset_y in range(-radius_cells, radius_cells + 1):
        for offset_x in range(-radius_cells, radius_cells + 1):
            if offset_x ** 2 + offset_y ** 2 > radius_cells ** 2:
                continue
            y_start = radius_cells + offset_y
            x_start = radius_cells + offset_x
            dilated |= padded[
                y_start:y_start + grid_height,
                x_start:x_start + grid_width,
            ]

    return dilated


def points_have_water(
    points: np.ndarray,
    water_grid: np.ndarray,
) -> np.ndarray:
    """Return whether each point lies in the current water corridor."""
    result = np.zeros(len(points), dtype=bool)
    inside = (
        (points[:, 0] >= 0.0)
        & (points[:, 0] <= WIDTH)
        & (points[:, 1] >= 0.0)
        & (points[:, 1] <= HEIGHT)
    )
    if not np.any(inside):
        return result

    inside_points = points[inside]
    grid_x = np.clip(
        (inside_points[:, 0] / WATER_GRID_CELL_SIZE).astype(np.intp),
        0,
        water_grid.shape[1] - 1,
    )
    grid_y = np.clip(
        (inside_points[:, 1] / WATER_GRID_CELL_SIZE).astype(np.intp),
        0,
        water_grid.shape[0] - 1,
    )
    result[inside] = water_grid[grid_y, grid_x]
    return result


def water_exit_y_candidates() -> np.ndarray:
    """Collect downstream-edge Y positions where salmon can enter water."""
    candidates = []
    edge_band = max(
        SALMON_WATER_RADIUS_DATA * 2.0,
        0.12 * WORLD_SCALE,
    )
    active_water_slots = np.flatnonzero(
        particle_launch_times_ms <= current_elapsed_ms
    )
    for trail in trails[active_water_slots]:
        valid = (
            np.isfinite(trail[:, 0])
            & np.isfinite(trail[:, 1])
            & (trail[:, 0] >= WIDTH - edge_band)
            & (trail[:, 0] <= WIDTH)
            & (trail[:, 1] >= 0.0)
            & (trail[:, 1] <= HEIGHT)
        )
        if np.any(valid):
            edge_points = trail[valid]
            candidates.append(edge_points[np.argmax(edge_points[:, 0]), 1])
    return np.asarray(candidates)


def release_salmon() -> None:
    """Release exactly SALMON_PER_RELEASE short upstream-swimming lines."""
    inactive_slots = np.flatnonzero(~salmon_active)
    if len(inactive_slots) >= SALMON_PER_RELEASE:
        slots = inactive_slots[:SALMON_PER_RELEASE]
    else:
        needed = SALMON_PER_RELEASE - len(inactive_slots)
        active_slots = np.flatnonzero(salmon_active)
        oldest = active_slots[
            np.argsort(salmon_birth_ms[active_slots])[:needed]
        ]
        slots = np.concatenate((inactive_slots, oldest))

    candidate_y = water_exit_y_candidates()
    if len(candidate_y) > 0:
        spawn_y = rng.choice(
            candidate_y,
            size=SALMON_PER_RELEASE,
            replace=len(candidate_y) < SALMON_PER_RELEASE,
        )
    else:
        spawn_y = rng.uniform(
            SPAWN_Y_MARGIN,
            HEIGHT - SPAWN_Y_MARGIN,
            SALMON_PER_RELEASE,
        )

    salmon_positions[slots, 0] = WIDTH + SALMON_SPAWN_OFFSET
    salmon_positions[slots, 1] = spawn_y
    salmon_trails[slots] = np.nan
    salmon_active[slots] = True
    salmon_fading[slots] = False
    salmon_fade_started_ms[slots] = np.nan
    salmon_birth_ms[slots] = current_elapsed_ms
    salmon_states[slots] = SALMON_STATE_UPSTREAM
    salmon_reservoir_indices[slots] = -1
    salmon_passed_reservoir[slots] = False
    salmon_rgba[slots] = to_rgba_array(
        rng.choice(SALMON_COLORS, size=SALMON_PER_RELEASE)
    )
    print(f"Released {SALMON_PER_RELEASE} salmon")


def trim_salmon_trail(slot: int) -> None:
    """Keep only the most recent approximately 50 pixels of one path."""
    path = salmon_trails[slot]
    valid = np.isfinite(path[:, 0]) & np.isfinite(path[:, 1])
    points = path[valid]
    if len(points) < 2:
        return

    segment_lengths = np.linalg.norm(np.diff(points, axis=0), axis=1)
    distance_to_head = np.concatenate(
        (np.cumsum(segment_lengths[::-1])[::-1], np.array([0.0]))
    )
    kept = points[distance_to_head <= SALMON_LENGTH_DATA]
    if len(kept) < 2:
        kept = points[-2:]
    salmon_trails[slot] = np.nan
    salmon_trails[slot, -len(kept):] = kept


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


def create_obstacle_artists() -> list:
    """Draw every solid obstacle for live geometry debugging."""
    style = dict(
        fill=False,
        edgecolor=DEBUG_GEOMETRY_COLOR,
        linewidth=DEBUG_GEOMETRY_LINE_WIDTH,
        alpha=0.8,
        zorder=5,
    )
    artists = []

    for obstacle in OBSTACLES:
        artist = Circle(
            (obstacle.x, obstacle.y),
            obstacle.radius,
            **style,
        )
        ax.add_patch(artist)
        artists.append(artist)

    for obstacle in RECTANGLE_OBSTACLES:
        artist = PolygonPatch(
            rectangle_vertices(obstacle),
            closed=True,
            **style,
        )
        ax.add_patch(artist)
        artists.append(artist)

    for obstacle in POLYGON_OBSTACLES:
        artist = PolygonPatch(
            np.asarray(obstacle.vertices, dtype=float),
            closed=True,
            **style,
        )
        ax.add_patch(artist)
        artists.append(artist)

    for absorber in ABSORBERS:
        left, right, bottom, top = absorber_bounds(absorber)
        absorber_style = dict(style)
        absorber_style.update(
            edgecolor="yellowgreen",
            linestyle="--",
        )
        artist = PolygonPatch(
            np.array(
                [
                    (left, bottom),
                    (right, bottom),
                    (right, top),
                    (left, top),
                ]
            ),
            closed=True,
            **absorber_style,
        )
        ax.add_patch(artist)
        artists.append(artist)

    return artists


def reservoir_arc_ranges(
    reservoir: Reservoir,
) -> tuple[tuple[float, float], ...]:
    """Return the visible downstream arc segments around the gate."""
    if not reservoir.gate_open or reservoir.outlet_width <= 0.0:
        return ((-90.0, 90.0),)

    half_gate_angle = math.degrees(
        math.asin(
            min(
                1.0,
                reservoir.outlet_width / (reservoir.radius * 2.0),
            )
        )
    )
    return (
        (-90.0, -half_gate_angle),
        (half_gate_angle, 90.0),
    )


def create_reservoir_artists(
    reservoir: Reservoir,
) -> tuple[Arc, Arc]:
    """Create two reusable arc artists so the gate can change at runtime."""
    arc_style = dict(
        edgecolor=DEBUG_GEOMETRY_COLOR,
        linewidth=DEBUG_GEOMETRY_LINE_WIDTH,
        alpha=0.8,
        fill=False,
        zorder=5,
    )
    diameter = reservoir.radius * 2.0
    artists = []
    for _ in range(2):
        arc = Arc(
            (reservoir.x, reservoir.y),
            diameter,
            diameter,
            theta1=-90.0,
            theta2=90.0,
            **arc_style,
        )
        ax.add_patch(arc)
        artists.append(arc)
    return artists[0], artists[1]


def update_reservoir_artists(reservoir_index: int) -> None:
    """Update a reservoir wall after a live gate setting change."""
    reservoir = RESERVOIRS[reservoir_index]
    artists = reservoir_arc_artists[reservoir_index]
    arc_ranges = reservoir_arc_ranges(reservoir)

    for artist_index, artist in enumerate(artists):
        if artist_index < len(arc_ranges):
            theta1, theta2 = arc_ranges[artist_index]
            artist.theta1 = theta1
            artist.theta2 = theta2
            artist.set_visible(DEBUG_GEOMETRY_VISIBLE)
        else:
            artist.set_visible(False)


obstacle_artists = create_obstacle_artists()
reservoir_arc_artists = [
    create_reservoir_artists(reservoir)
    for reservoir in RESERVOIRS
]
for reservoir_index in range(len(RESERVOIRS)):
    update_reservoir_artists(reservoir_index)

reservoir_artists = [
    artist
    for artist_pair in reservoir_arc_artists
    for artist in artist_pair
]
debug_geometry_artists = obstacle_artists + reservoir_artists

# Reserve the salmon-release key instead of opening Matplotlib's save dialog.
plt.rcParams["keymap.save"] = [
    key
    for key in plt.rcParams["keymap.save"]
    if key.lower() != SALMON_RELEASE_KEY
]

line_widths = rng.uniform(
    LINE_WIDTH_MIN,
    LINE_WIDTH_MAX,
    PARTICLE_POOL_SIZE,
)

line_colors = rng.choice(COLORS, size=PARTICLE_POOL_SIZE)

trail_lines = []
for particle_index in range(PARTICLE_POOL_SIZE):
    line, = ax.plot(
        [],
        [],
        color=line_colors[particle_index],
        linewidth=line_widths[particle_index],
        alpha=PARTICLE_ALPHA,
        solid_capstyle="round",
        dash_capstyle="round",
        solid_joinstyle="round",
        marker="o",
        markevery=[-1],
        markersize=line_widths[particle_index],
        markerfacecolor=line_colors[particle_index],
        markeredgecolor=line_colors[particle_index],
        markeredgewidth=0.0,
        antialiased=True,
        clip_on=True,
    )
    trail_lines.append(line)

initial_salmon_colors = salmon_rgba.copy()
initial_salmon_colors[:, 3] = 0.0
salmon_collection = LineCollection(
    salmon_trails,
    colors=initial_salmon_colors,
    linewidths=SALMON_LINE_WIDTH,
    capstyle="round",
    joinstyle="round",
    antialiased=True,
    clip_on=True,
    zorder=7,
)
ax.add_collection(salmon_collection)


def resolve_salmon_reservoir_encounters(
    candidate_slots: np.ndarray,
) -> None:
    """Immediately choose whether salmon return or enter at a dam wall."""
    candidate_slots = np.asarray(candidate_slots, dtype=np.intp)
    for reservoir_index, reservoir in enumerate(RESERVOIRS):
        eligible = candidate_slots[
            (salmon_states[candidate_slots] == SALMON_STATE_UPSTREAM)
            & ~salmon_passed_reservoir[candidate_slots, reservoir_index]
        ]
        if len(eligible) == 0:
            continue

        local = salmon_positions[eligible] - np.array(
            (reservoir.x, reservoir.y)
        )
        distance = np.linalg.norm(local, axis=1)
        approaching_face = (
            (local[:, 0] >= 0.0)
            & (np.abs(distance - reservoir.radius) <= SALMON_DAM_APPROACH_DATA)
        )
        starting = eligible[approaching_face]
        if len(starting) == 0:
            continue

        returning = rng.random(len(starting)) < np.clip(
            SALMON_RETURN_RATE,
            0.0,
            1.0,
        )
        returning_slots = starting[returning]
        entering_slots = starting[~returning]
        salmon_states[returning_slots] = SALMON_STATE_RETREATING
        salmon_states[entering_slots] = SALMON_STATE_ENTERING
        salmon_reservoir_indices[entering_slots] = reservoir_index


def update_entering_salmon(
    timestep: float,
    new_samples: np.ndarray,
    substep: int,
    frame_travel_distance: np.ndarray,
    state_changed_this_frame: np.ndarray,
) -> None:
    """Carry non-returning salmon directly into the reservoir swirl."""
    for reservoir_index, reservoir in enumerate(RESERVOIRS):
        slots = np.flatnonzero(
            salmon_active
            & ~salmon_fading
            & (salmon_states == SALMON_STATE_ENTERING)
            & (salmon_reservoir_indices == reservoir_index)
        )
        if len(slots) == 0:
            continue

        center = np.array((reservoir.x, reservoir.y))
        local = salmon_positions[slots] - center
        radial, _ = safe_normalize(local, minimum=1e-8)
        target = center + radial * (reservoir.radius * 0.65)
        toward_target = target - salmon_positions[slots]
        direction, remaining = safe_normalize(
            toward_target,
            minimum=1e-8,
        )
        step = np.minimum(
            SALMON_DAM_PASSAGE_SPEED_DATA * timestep,
            remaining,
        )
        proposed = salmon_positions[slots] + direction * step[:, None]

        frame_travel_distance[slots] += np.linalg.norm(
            proposed - salmon_positions[slots],
            axis=1,
        )
        salmon_positions[slots] = proposed
        new_samples[slots, substep] = proposed

        entered = slots[
            np.linalg.norm(salmon_positions[slots] - center, axis=1)
            <= reservoir.radius * 0.72
        ]
        if len(entered) > 0:
            salmon_passed_reservoir[entered, reservoir_index] = True
            salmon_states[entered] = SALMON_STATE_UPSTREAM
            salmon_reservoir_indices[entered] = -1
            state_changed_this_frame[entered] = True


def update_salmon(frame: int, frame_end_ms: float) -> None:
    """Move salmon upstream, into reservoirs, or back downstream."""
    if not np.any(salmon_active):
        return

    water_grid = build_water_occupancy_grid()
    substep_dt = DT / SIMULATION_SUBSTEPS
    frame_start_positions = salmon_positions.copy()
    frame_travel_distance = np.zeros(MAX_SALMON)
    state_changed_this_frame = np.zeros(MAX_SALMON, dtype=bool)
    new_samples = np.full(
        (MAX_SALMON, SIMULATION_SUBSTEPS, 2),
        np.nan,
    )

    for substep in range(SIMULATION_SUBSTEPS):
        active_slots = np.flatnonzero(salmon_active & ~salmon_fading)
        if len(active_slots) == 0:
            break

        time_value = frame * DT + substep * substep_dt
        elapsed_ms = (
            frame * INTERVAL_MS
            + substep * INTERVAL_MS / SIMULATION_SUBSTEPS
        )
        upstream_candidates = active_slots[
            salmon_states[active_slots] == SALMON_STATE_UPSTREAM
        ]
        resolve_salmon_reservoir_encounters(
            upstream_candidates,
        )
        update_entering_salmon(
            substep_dt,
            new_samples,
            substep,
            frame_travel_distance,
            state_changed_this_frame,
        )

        field_slots = np.flatnonzero(
            salmon_active
            & ~salmon_fading
            & ~state_changed_this_frame
            & (
                (salmon_states == SALMON_STATE_UPSTREAM)
                | (salmon_states == SALMON_STATE_RETREATING)
            )
        )
        if len(field_slots) == 0:
            continue

        source_indices = salmon_source_indices[field_slots]
        direction_sign = np.where(
            salmon_states[field_slots] == SALMON_STATE_RETREATING,
            1.0,
            -1.0,
        )
        field_velocity = velocity_field(
            salmon_positions[field_slots],
            time_value,
            particle_indices=source_indices,
        )
        travel_velocity = field_velocity * direction_sign[:, None]
        midpoint = (
            salmon_positions[field_slots]
            + travel_velocity * substep_dt * 0.5
        )
        midpoint_field_velocity = velocity_field(
            midpoint,
            time_value + substep_dt * 0.5,
            particle_indices=source_indices,
        )
        midpoint_velocity = (
            midpoint_field_velocity * direction_sign[:, None]
        )
        proposed = (
            salmon_positions[field_slots]
            + midpoint_velocity * substep_dt
        )
        travel_direction, travel_speed = safe_normalize(
            midpoint_velocity,
            minimum=1e-8,
        )
        ahead = proposed + travel_direction * SALMON_LOOKAHEAD_DATA
        has_water = points_have_water(ahead, water_grid)
        has_water &= travel_speed > 1e-8

        upstream = salmon_states[field_slots] == SALMON_STATE_UPSTREAM
        retreating = (
            salmon_states[field_slots] == SALMON_STATE_RETREATING
        )
        # Once an exiting head reaches either boundary, let the complete short
        # body continue off-screen even though the occupancy grid ends there.
        leaving_upstream = (
            upstream
            & (salmon_positions[field_slots, 0] <= SALMON_WATER_RADIUS_DATA)
            & (midpoint_velocity[:, 0] < 0.0)
        )
        leaving_downstream = (
            retreating
            & (
                salmon_positions[field_slots, 0]
                >= WIDTH - SALMON_WATER_RADIUS_DATA
            )
            & (midpoint_velocity[:, 0] > 0.0)
        )
        has_water |= leaving_upstream | leaving_downstream

        stranded_slots = field_slots[~has_water]
        if len(stranded_slots) > 0:
            salmon_fading[stranded_slots] = True
            salmon_fade_started_ms[stranded_slots] = elapsed_ms

        swimming_slots = field_slots[has_water]
        if len(swimming_slots) > 0:
            frame_travel_distance[swimming_slots] += np.linalg.norm(
                proposed[has_water] - salmon_positions[swimming_slots],
                axis=1,
            )
            salmon_positions[swimming_slots] = proposed[has_water]
            new_samples[swimming_slots, substep] = proposed[has_water]

    # Water in a reservoir can leave a salmon at a near-equilibrium point.
    # Treat motion of one pixel or less over the complete displayed frame as
    # stalled. Preserve its existing body instead of replacing it with twenty
    # nearly identical substep samples, then use the normal fade lifecycle.
    motion_candidates = np.flatnonzero(
        salmon_active
        & ~salmon_fading
        & ~state_changed_this_frame
        & (
            (salmon_states == SALMON_STATE_UPSTREAM)
            | (salmon_states == SALMON_STATE_RETREATING)
        )
    )
    stalled_slots = motion_candidates[
        frame_travel_distance[motion_candidates]
        <= SALMON_MOTION_THRESHOLD_DATA
    ]
    if len(stalled_slots) > 0:
        salmon_positions[stalled_slots] = frame_start_positions[stalled_slots]
        new_samples[stalled_slots] = np.nan
        salmon_fading[stalled_slots] = True
        salmon_fade_started_ms[stalled_slots] = frame_end_ms

    sampled_slots = np.flatnonzero(
        np.any(np.isfinite(new_samples[:, :, 0]), axis=1)
    )
    for slot in sampled_slots:
        existing = salmon_trails[slot]
        existing = existing[np.isfinite(existing[:, 0])]
        samples = new_samples[slot]
        samples = samples[np.isfinite(samples[:, 0])]
        combined = np.concatenate((existing, samples), axis=0)
        combined = combined[-SALMON_HISTORY_POINTS:]
        salmon_trails[slot] = np.nan
        salmon_trails[slot, -len(combined):] = combined
        trim_salmon_trail(slot)

    exited_slots = []
    for slot in np.flatnonzero(salmon_active & ~salmon_fading):
        path = salmon_trails[slot]
        finite_x = path[np.isfinite(path[:, 0]), 0]
        exited_upstream = (
            salmon_states[slot] != SALMON_STATE_RETREATING
            and len(finite_x) > 0
            and np.max(finite_x) < 0.0
        )
        exited_downstream = (
            salmon_states[slot] == SALMON_STATE_RETREATING
            and len(finite_x) > 0
            and np.min(finite_x) > WIDTH
        )
        if exited_upstream or exited_downstream:
            exited_slots.append(slot)
    if exited_slots:
        exited_slots = np.asarray(exited_slots, dtype=np.intp)
        salmon_active[exited_slots] = False
        salmon_positions[exited_slots] = np.nan
        salmon_trails[exited_slots] = np.nan
        salmon_states[exited_slots] = SALMON_STATE_UPSTREAM
        salmon_reservoir_indices[exited_slots] = -1

    fading_slots = np.flatnonzero(salmon_active & salmon_fading)
    if len(fading_slots) > 0:
        fade_progress = (
            frame_end_ms - salmon_fade_started_ms[fading_slots]
        ) / (SALMON_FADE_SECONDS * 1000.0)
        finished = fading_slots[fade_progress >= 1.0]
        if len(finished) > 0:
            salmon_active[finished] = False
            salmon_fading[finished] = False
            salmon_positions[finished] = np.nan
            salmon_trails[finished] = np.nan
            salmon_fade_started_ms[finished] = np.nan
            salmon_states[finished] = SALMON_STATE_UPSTREAM
            salmon_reservoir_indices[finished] = -1

    display_colors = salmon_rgba.copy()
    display_colors[~salmon_active, 3] = 0.0
    fading_slots = np.flatnonzero(salmon_active & salmon_fading)
    if len(fading_slots) > 0:
        fade_alpha = 1.0 - np.clip(
            (
                frame_end_ms - salmon_fade_started_ms[fading_slots]
            ) / (SALMON_FADE_SECONDS * 1000.0),
            0.0,
            1.0,
        )
        display_colors[fading_slots, 3] *= fade_alpha

    salmon_collection.set_segments(salmon_trails)
    salmon_collection.set_color(display_colors)




frame_counter = 0
current_elapsed_ms = 0.0


def update(frame: int):
    global positions, trails, frame_counter, retiring, current_elapsed_ms

    substep_dt = DT / SIMULATION_SUBSTEPS
    new_trail_points = np.full(
        (PARTICLE_POOL_SIZE, SIMULATION_SUBSTEPS, 2),
        np.nan,
    )
    newly_retained_steps = np.full(PARTICLE_POOL_SIZE, -1, dtype=np.intp)
    # Neighbor relationships change much more slowly than the integration
    # timestep. Cache particle pressure once per displayed frame instead of
    # rebuilding its O(n²) distance matrix twenty times. Reservoir-retained
    # lines use their stable orbit spread instead of joining this matrix.
    frame_separation_force = np.zeros((PARTICLE_POOL_SIZE, 2))
    frame_start_ms = frame * INTERVAL_MS
    source_slots = np.arange(MAX_PARTICLES, dtype=np.intp)
    separation_slots = source_slots[
        (particle_launch_times_ms[source_slots] <= frame_start_ms)
        & ~absorbed[source_slots]
    ]
    frame_separation_force[separation_slots] = particle_separation_force(
        positions[separation_slots]
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
        launched = elapsed_ms >= particle_launch_times_ms
        absorbed_before_substep = absorbed.copy()
        substep_active = launched & ~absorbed_before_substep

        if np.any(substep_active):
            active_indices = np.flatnonzero(substep_active)
            update_reservoir_release_progress(
                active_indices,
                substep_dt,
            )
            velocity = velocity_field(
                positions[active_indices],
                time_value,
                frame_separation_force[active_indices],
                active_indices,
            )
            midpoint = (
                positions[active_indices]
                + velocity * substep_dt * 0.5
            )
            midpoint_velocity = velocity_field(
                midpoint,
                time_value + substep_dt * 0.5,
                frame_separation_force[substep_active],
                active_indices,
            )
            positions[active_indices] += midpoint_velocity * substep_dt

        update_absorption_states(np.flatnonzero(launched))
        new_trail_points[launched, substep, :] = positions[launched]
        # An absorbed head contributes no new geometry. Rolling these NaNs
        # through the history erases the trail progressively from tail to head.
        new_trail_points[
            absorbed_before_substep,
            substep,
            :,
        ] = np.nan

        source_candidates = np.flatnonzero(
            substep_active
            & ~absorbed
            & (np.arange(PARTICLE_POOL_SIZE) < MAX_PARTICLES)
        )
        transfer_new_reservoir_water(
            source_candidates,
            elapsed_ms,
            new_trail_points,
            substep,
            newly_retained_steps,
        )

    frame_end_ms = (frame + 1) * INTERVAL_MS
    current_elapsed_ms = frame_end_ms
    active = frame_end_ms > particle_launch_times_ms

    # Once a head reaches the right edge, let the line retire naturally.
    head_exited_right = active & (positions[:, 0] >= WIDTH)
    retiring |= head_exited_right

    # Only reset immediately for true escape/error cases.
    escape_margin = 0.5 * WORLD_SCALE
    hard_reset = active & (
        (positions[:, 0] < SPAWN_X - escape_margin)
        | (positions[:, 1] < -escape_margin)
        | (positions[:, 1] > HEIGHT + escape_margin)
    )

    # Existing lines receive a complete frame of points. A line detached into
    # reservoir storage already copied the source history at its capture step,
    # so append only the subsequent samples for that newly retained slot.
    existing_slots = np.flatnonzero(active & (newly_retained_steps < 0))
    trails[existing_slots] = np.roll(
        trails[existing_slots],
        -SIMULATION_SUBSTEPS,
        axis=1,
    )
    trails[existing_slots, -SIMULATION_SUBSTEPS:, :] = new_trail_points[
        existing_slots
    ]

    for retention_index in np.flatnonzero(newly_retained_steps >= 0):
        first_new_sample = newly_retained_steps[retention_index] + 1
        samples = new_trail_points[retention_index, first_new_sample:]
        samples = samples[np.isfinite(samples[:, 0])]
        if len(samples) > 0:
            trails[retention_index] = np.roll(
                trails[retention_index],
                -len(samples),
                axis=0,
            )
            trails[retention_index, -len(samples):] = samples

    visible_mask = (
        (trails[:, :, 0] >= 0.0)
        & (trails[:, :, 0] <= WIDTH)
        & (trails[:, :, 1] >= 0.0)
        & (trails[:, :, 1] <= HEIGHT)
    )

    visible_counts = visible_mask.sum(axis=1)
    retired_and_gone = (
        (retiring | absorbed)
        & (visible_counts < 2)
    )

    reset_now = hard_reset | retired_and_gone
    completed_sources = np.flatnonzero(
        reset_now & (np.arange(PARTICLE_POOL_SIZE) < MAX_PARTICLES)
    )
    source_reset = completed_sources[completed_sources < NUM_PARTICLES]
    source_end = completed_sources[completed_sources >= NUM_PARTICLES]
    retention_reset = np.flatnonzero(reset_now & retained)
    reset_particles(source_reset)
    deactivate_source_particles(source_end)
    deactivate_retained_particles(retention_reset)

    update_salmon(frame, frame_end_ms)

    # One continuous Line2D artist per particle keeps every trail smooth.
    display_active = frame_end_ms > particle_launch_times_ms
    for particle_index in range(PARTICLE_POOL_SIZE):
        line = trail_lines[particle_index]
        if display_active[particle_index]:
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
    return (
        trail_lines
        + [salmon_collection]
        + debug_geometry_artists
    )


def init_animation():
    """Initialize artists without advancing the simulation."""
    for line in trail_lines:
        line.set_data([], [])
    salmon_collection.set_segments(salmon_trails)
    return trail_lines + [salmon_collection] + debug_geometry_artists


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
    """Change new-source flow while allowing excess lines to finish."""
    global FLOW_RATE, FLOW_SPEED, NUM_PARTICLES

    old_flow_rate = FLOW_RATE
    old_count = NUM_PARTICLES
    new_count = particle_count_for_flow(flow_rate)

    FLOW_RATE = flow_rate
    FLOW_SPEED = FLOW_RATE * MAX_FLOW_SPEED
    NUM_PARTICLES = new_count

    if new_count > old_count:
        added_indices = np.arange(old_count, new_count)
        already_flowing = added_indices[
            np.isfinite(particle_launch_times_ms[added_indices])
        ]
        inactive = added_indices[
            ~np.isfinite(particle_launch_times_ms[added_indices])
        ]

        # A line that was still retiring simply rejoins the active source set.
        retiring[already_flowing] = False
        retirement_flow_rates[already_flowing] = np.nan

        reset_particles(inactive)
        particle_launch_times_ms[inactive] = (
            current_elapsed_ms
            + np.arange(len(inactive)) * PARTICLE_LAUNCH_DELAY_MS
        )
    elif new_count < old_count:
        removed_indices = np.arange(new_count, old_count)
        existing = removed_indices[
            particle_launch_times_ms[removed_indices] <= current_elapsed_ms
        ]
        not_yet_launched = removed_indices[
            particle_launch_times_ms[removed_indices] > current_elapsed_ms
        ]

        # Existing excess lines keep their pre-change speed and stop respawning
        # only after their complete visible trails have naturally left.
        retiring[existing] = True
        retirement_flow_rates[existing] = old_flow_rate
        deactivate_source_particles(not_yet_launched)

    active_source_count = np.count_nonzero(
        particle_launch_times_ms[:MAX_PARTICLES] <= current_elapsed_ms
    )

    print(
        f"Flow rate: {FLOW_RATE:.3f} | "
        f"speed: {FLOW_SPEED:.2f} | "
        f"source target: {NUM_PARTICLES} | "
        f"currently visible/retiring: {active_source_count}"
    )


def report_gate_state(reservoir_index: int) -> None:
    """Print active gate geometry and its accumulated release rate."""
    reservoir = RESERVOIRS[reservoir_index]
    aperture = reservoir_gate_fraction(reservoir)
    effective_aperture = aperture if reservoir.gate_open else 0.0
    progress_rate = effective_aperture * RESERVOIR_RELEASE_RATE
    state = "OPEN" if reservoir.gate_open else "CLOSED"
    print(
        f"Reservoir {reservoir_index + 1} gate: {state} | "
        f"width: {reservoir.outlet_width:.2f} | "
        f"aperture: {effective_aperture:.1%} | "
        f"release rate: {progress_rate:.2f}/s"
    )


def set_gate_width(reservoir_index: int, outlet_width: float) -> None:
    """Change gate width without resetting water already in the reservoir."""
    reservoir = RESERVOIRS[reservoir_index]
    clamped_width = float(np.clip(
        outlet_width,
        0.0,
        reservoir.radius * 2.0,
    ))
    RESERVOIRS[reservoir_index] = replace(
        reservoir,
        outlet_width=clamped_width,
    )
    update_reservoir_artists(reservoir_index)
    report_gate_state(reservoir_index)


def toggle_gate(reservoir_index: int) -> None:
    """Open or close a reservoir gate without resetting its water."""
    reservoir = RESERVOIRS[reservoir_index]
    RESERVOIRS[reservoir_index] = replace(
        reservoir,
        gate_open=not reservoir.gate_open,
    )
    update_reservoir_artists(reservoir_index)
    report_gate_state(reservoir_index)


def toggle_debug_geometry() -> None:
    """Show or hide obstacle, absorber, and reservoir debug geometry."""
    global DEBUG_GEOMETRY_VISIBLE

    DEBUG_GEOMETRY_VISIBLE = not DEBUG_GEOMETRY_VISIBLE
    for artist in obstacle_artists:
        artist.set_visible(DEBUG_GEOMETRY_VISIBLE)
    for reservoir_index in range(len(RESERVOIRS)):
        update_reservoir_artists(reservoir_index)

    state = "VISIBLE" if DEBUG_GEOMETRY_VISIBLE else "HIDDEN"
    print(f"Debug geometry: {state}")


def on_key_press(event) -> None:
    if not event.key:
        return

    key = event.key.lower()
    if key == SCREENSHOT_KEY:
        take_screenshot()
    elif key == SALMON_RELEASE_KEY:
        release_salmon()
    elif key == VISIBILITY_TOGGLE_KEY:
        toggle_debug_geometry()
    elif key == GATE_TOGGLE_KEY and RESERVOIRS:
        toggle_gate(ACTIVE_RESERVOIR_INDEX)
    elif key == GATE_NARROW_KEY and RESERVOIRS:
        reservoir = RESERVOIRS[ACTIVE_RESERVOIR_INDEX]
        set_gate_width(
            ACTIVE_RESERVOIR_INDEX,
            reservoir.outlet_width - GATE_WIDTH_STEP,
        )
    elif key == GATE_WIDEN_KEY and RESERVOIRS:
        reservoir = RESERVOIRS[ACTIVE_RESERVOIR_INDEX]
        set_gate_width(
            ACTIVE_RESERVOIR_INDEX,
            reservoir.outlet_width + GATE_WIDTH_STEP,
        )
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
