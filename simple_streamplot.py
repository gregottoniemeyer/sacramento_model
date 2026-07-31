"""
simple_streamplot.py

Static 2D flow-line drawing using matplotlib.streamplot.

Install:
    pip install numpy matplotlib

Run:
    python simple_streamplot.py

Output:
    simple_streamplot.png
"""

import numpy as np
import matplotlib.pyplot as plt


# --------------------------------------------------
# SETTINGS
# --------------------------------------------------

WIDTH = 12.0
HEIGHT = 7.0
GRID_X = 300
GRID_Y = 180

BASE_FLOW = np.array([1.2, 0.0])

OBSTACLES = [
    # (x, y, radius, strength)
    (4.0, 3.7, 0.85, 4.0),
    (7.0, 2.2, 0.65, 3.5),
]

DRAINS = [
    # (x, y, attraction, swirl)
    (10.2, 3.5, 2.1, 4.0),
]

STREAM_DENSITY = 2.2
LINE_WIDTH = 0.8
OUTPUT_FILE = "simple_streamplot.png"


def build_velocity_field(x: np.ndarray, y: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    """Build a vector field over the meshgrid."""
    u = np.full_like(x, BASE_FLOW[0], dtype=float)
    v = np.full_like(y, BASE_FLOW[1], dtype=float)

    for ox, oy, radius, strength in OBSTACLES:
        dx = x - ox
        dy = y - oy
        distance = np.sqrt(dx * dx + dy * dy)
        safe_distance = np.maximum(distance, 0.05)

        influence = np.clip((radius * 2.3 - distance) / (radius * 1.3), 0.0, 1.0)

        # Radial repulsion
        u += (dx / safe_distance) * influence * strength
        v += (dy / safe_distance) * influence * strength

        # Tangential bend
        u += (-dy / safe_distance) * influence * 0.8
        v += ( dx / safe_distance) * influence * 0.8

    for dx0, dy0, attraction, swirl in DRAINS:
        dx = dx0 - x
        dy = dy0 - y
        distance = np.sqrt(dx * dx + dy * dy)
        safe_distance = np.maximum(distance, 0.08)

        inward_x = dx / safe_distance
        inward_y = dy / safe_distance

        u += inward_x * attraction
        v += inward_y * attraction

        swirl_strength = swirl / (distance + 0.45)
        u += -inward_y * swirl_strength
        v +=  inward_x * swirl_strength

    return u, v


def main() -> None:
    x_values = np.linspace(0.0, WIDTH, GRID_X)
    y_values = np.linspace(0.0, HEIGHT, GRID_Y)
    x, y = np.meshgrid(x_values, y_values)

    u, v = build_velocity_field(x, y)

    # Mask obstacle interiors
    mask = np.zeros_like(x, dtype=bool)
    for ox, oy, radius, _strength in OBSTACLES:
        mask |= (x - ox) ** 2 + (y - oy) ** 2 < radius ** 2

    u = np.ma.array(u, mask=mask)
    v = np.ma.array(v, mask=mask)

    fig, ax = plt.subplots(figsize=(12, 7))
    ax.set_xlim(0, WIDTH)
    ax.set_ylim(0, HEIGHT)
    ax.set_aspect("equal")
    ax.axis("off")

    ax.streamplot(
        x,
        y,
        u,
        v,
        density=STREAM_DENSITY,
        linewidth=LINE_WIDTH,
        arrowsize=0.0,
        integration_direction="forward",
        maxlength=5.0,
    )

    for ox, oy, radius, _strength in OBSTACLES:
        ax.add_patch(plt.Circle((ox, oy), radius, fill=False, linewidth=1.5))

    for drain_x, drain_y, _attraction, _swirl in DRAINS:
        ax.add_patch(plt.Circle((drain_x, drain_y), 0.12, fill=True))

    fig.savefig(OUTPUT_FILE, dpi=200, bbox_inches="tight", pad_inches=0.05)
    print(f"Saved {OUTPUT_FILE}")
    plt.show()


if __name__ == "__main__":
    main()
