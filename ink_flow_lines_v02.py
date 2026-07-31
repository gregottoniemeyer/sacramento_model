"""
ink_flow_lines.py

Animated 2D graphic flow lines moving around circular obstacles and
spiraling into drains.

Install:
    pip install numpy matplotlib

Run:
    python ink_flow_lines.py

Optional export:
    Set SAVE_MP4 = True and install ffmpeg.
    Set SAVE_GIF = True and install pillow.

Controls:
    Close the plot window to stop.
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
import math

import numpy as np
import matplotlib.pyplot as plt
from matplotlib.animation import FuncAnimation, PillowWriter


# --------------------------------------------------
# SETTINGS
# --------------------------------------------------

OUTPUT_WIDTH_PX = 1920
OUTPUT_HEIGHT_PX = 1080
OUTPUT_DPI = 120

HEIGHT = 7.0
WIDTH = HEIGHT * OUTPUT_WIDTH_PX / OUTPUT_HEIGHT_PX

NUM_PARTICLES = 250
TRAIL_LENGTH = 1920
DT = 0.022
INTERVAL_MS = 10
RANDOM_SEED = None

BASE_FLOW_X = 0.5
BASE_FLOW_Y = 0.0

NOISE_STRENGTH = 0.20
NOISE_SCALE = 0.55
NOISE_SPEED = 0.35

LINE_WIDTH = 1.0
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
    Obstacle(5.0, 1.25, 1.0, strength=1.0, bend=0.9)
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
    distance_from_top = HEIGHT - y

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

    # Cap speed so particles do not jump through obstacles.
    speed = np.linalg.norm(velocity, axis=1)
    max_speed = 8.0
    fast = speed > max_speed
    if np.any(fast):
        velocity[fast] *= (max_speed / speed[fast])[:, None]

    return velocity


def spawn_positions(count: int) -> np.ndarray:
    return np.column_stack(
        (
            rng.uniform(SPAWN_X_MIN, SPAWN_X_MAX, count),
            rng.uniform(
                SPAWN_Y_MARGIN,
                HEIGHT - SPAWN_Y_MARGIN,
                count,
            ),
        )
    )


positions = spawn_positions(NUM_PARTICLES)
trails = np.repeat(positions[:, None, :], TRAIL_LENGTH
, axis=1)


def reset_particles(indices: np.ndarray) -> None:
    if len(indices) == 0:
        return

    new_positions = spawn_positions(len(indices))
    positions[indices] = new_positions
    trails[indices, :, :] = new_positions[:, None, :]


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

ax = fig.add_axes([0, 0, 1, 1])

ax.set_facecolor(BACKGROUND)
ax.set_xlim(0.0, WIDTH)
ax.set_ylim(0.0, HEIGHT)
ax.set_aspect("equal", adjustable="box")
ax.axis("off")

lines = [
    ax.plot(
        [],
        [],
        linewidth=LINE_WIDTH,
        alpha=PARTICLE_ALPHA,
        color=np.random.choice(COLORS),
        solid_capstyle="round",
    )[0]
    for _ in range(NUM_PARTICLES)
]

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
    global positions, trails, frame_counter

    time_value = frame * DT
    velocity = velocity_field(positions, time_value)

    # Midpoint integration is more stable than simple Euler integration.
    midpoint = positions + velocity * DT * 0.5
    midpoint_velocity = velocity_field(midpoint, time_value + DT * 0.5)
    positions += midpoint_velocity * DT

    invalid = (
        (positions[:, 0] < SPAWN_X_MIN - 0.5)
        | (positions[:, 0] > WIDTH + 0.5)
        | (positions[:, 1] < -0.5)
        | (positions[:, 1] > HEIGHT + 0.5)
        | captured_by_drain(positions)
    )

    trails = np.roll(trails, -1, axis=1)
    trails[:, -1, :] = positions

    reset_particles(np.flatnonzero(invalid))

    for line, trail in zip(lines, trails):
        line.set_data(trail[:, 0], trail[:, 1])

    if EXPORT_FRAMES:
        FRAME_DIR.mkdir(parents=True, exist_ok=True)
        fig.savefig(
            FRAME_DIR / f"frame_{frame_counter:05d}.png",
            dpi=160,
            bbox_inches="tight",
            pad_inches=0.02,
        )

    frame_counter += 1
    return lines


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
                dpi=160,
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
                dpi=120,
                writer=PillowWriter(fps=EXPORT_FPS),
                savefig_kwargs={"facecolor": BACKGROUND},
            )
            print(f"Saved {OUTPUT_GIF}")
        except Exception as exc:
            print("GIF export failed.")
            print("Install Pillow with: pip install pillow")
            print(exc)


def main() -> None:
    if SAVE_MP4 or SAVE_GIF:
        export_animation()
    else:
        plt.show()


if __name__ == "__main__":
    main()
