
from pathlib import Path
import math
import random
import numpy as np
import matplotlib.pyplot as plt
from shapely.geometry import LineString, MultiLineString, Point
from shapely.ops import unary_union, polygonize, polylabel
import time

# ============================================================
# GREEDY CARPENTER BINGLIE / ICE-CRACK LATTICE
# Borderless portrait output: 1080 x 1920 px
#
# Construction principle:
#   1. Find the largest remaining opening.
#   2. Generate fabrication-valid chords across that opening.
#   3. Select the longest usable member from the current inventory.
#   4. Prefer the cut that most reduces the largest opening.
#   5. Repeat with progressively shorter inventory.
#
# The structural frame exists outside the crop and is never drawn.
# ============================================================

W, H = 1080, 1920
STROKE = 40.0
FRAME_OFFSET = 28.0

MIN_LENGTH = 150.0
MIN_ANGLE = 33.0
MAX_DEGREE = 4
CLEARANCE = 30.0
TARGET_MAX_RADIUS = 150.0

SEED = int(time.time() * 1000) % 100000
rng = random.Random(SEED)

OUTPUT_DIR = Path("./data")
PNG_PATH = OUTPUT_DIR / "binglie_greedy_carpenter_dense_1080x1920.png"
SVG_PATH = OUTPUT_DIR / "binglie_greedy_carpenter_dense_1080x1920.svg"

# Longest stock is exhausted first.
INVENTORY = [
    ("P0", 800.0, 1250.0, 8),
    ("P1", 430.0, 900.0, 14),
    ("P2", 220.0, 520.0, 30),
    ("P3", 150.0, 320.0, 36),
]

MAX_TOTAL = sum(item[3] for item in INVENTORY)

L, R = -FRAME_OFFSET, W + FRAME_OFFSET
B, T = -FRAME_OFFSET, H + FRAME_OFFSET

hidden_frame = [
    (np.array([L, B], float), np.array([R, B], float)),
    (np.array([R, B], float), np.array([R, T], float)),
    (np.array([R, T], float), np.array([L, T], float)),
    (np.array([L, T], float), np.array([L, B], float)),
]


def unit(v):
    n = float(np.linalg.norm(v))
    return v / n if n > 1e-9 else v


def seg_length(seg):
    return float(np.linalg.norm(seg[1] - seg[0]))


def cross(a, b):
    return float(a[0] * b[1] - a[1] * b[0])


def angle_between(v1, v2):
    c = float(np.clip(np.dot(unit(v1), unit(v2)), -1.0, 1.0))
    a = math.degrees(math.acos(c))
    return min(a, 180.0 - a)


def point_segment_distance(p, seg):
    a, b = seg
    ab = b - a
    den = float(np.dot(ab, ab))
    t = 0.0 if den < 1e-12 else float(np.clip(np.dot(p - a, ab) / den, 0.0, 1.0))
    q = a + t * ab
    return float(np.linalg.norm(p - q)), q, t


def segment_intersection(s1, s2, eps=1e-8):
    p, p2 = s1
    q, q2 = s2
    r = p2 - p
    s = q2 - q
    den = cross(r, s)
    if abs(den) < eps:
        return None
    qp = q - p
    t = cross(qp, s) / den
    u = cross(qp, r) / den
    if -eps <= t <= 1.0 + eps and -eps <= u <= 1.0 + eps:
        return p + t * r, t, u
    return None


def incident_directions(p, segments):
    dirs = []
    for a, b in segments:
        dist, _, t = point_segment_distance(p, (a, b))
        if dist > 1.25:
            continue
        if t <= 1e-4:
            dirs.append(b - a)
        elif t >= 1.0 - 1e-4:
            dirs.append(a - b)
        else:
            dirs.extend([b - a, a - b])
    return dirs


def degree(p, segments):
    return len(incident_directions(p, segments))


def joint_ok(p, new_direction, segments):
    return all(angle_between(new_direction, d) >= MIN_ANGLE
               for d in incident_directions(p, segments))


def candidate_intersections_ok(candidate, segments):
    a, b = candidate
    for seg in segments:
        hit = segment_intersection(candidate, seg)
        if hit is None:
            continue
        p, _, _ = hit
        # Only endpoint contact is legal.
        if np.linalg.norm(p - a) > 1.4 and np.linalg.norm(p - b) > 1.4:
            return False
    return True


def clearance_ok(candidate, segments):
    a, b = candidate
    length = seg_length(candidate)
    if length < MIN_LENGTH:
        return False

    d = unit(b - a)
    samples = [
        a + d * min(STROKE, length * 0.15),
        (a + b) * 0.5,
        b - d * min(STROKE, length * 0.15),
    ]

    for seg in segments:
        endpoint_contact = (
            point_segment_distance(a, seg)[0] <= 1.4 or
            point_segment_distance(b, seg)[0] <= 1.4
        )
        if endpoint_contact:
            continue
        if min(point_segment_distance(p, seg)[0] for p in samples) < CLEARANCE:
            return False
    return True


def polygon_cells(segments):
    lines = [
        LineString([(float(a[0]), float(a[1])),
                    (float(b[0]), float(b[1]))])
        for a, b in segments
    ]
    merged = unary_union(MultiLineString(lines))
    return [p for p in polygonize(merged) if p.area > 100.0]


def measure_cell(poly):
    c = polylabel(poly, tolerance=1.5)
    return float(c.distance(poly.boundary)), np.array([c.x, c.y], float)


def measured_cells(segments):
    result = []
    for poly in polygon_cells(segments):
        radius, center = measure_cell(poly)
        result.append((radius, center, poly))
    return sorted(result, key=lambda x: x[0], reverse=True)


def sample_polygon_boundary(poly, spacing=76.0):
    coords = list(poly.exterior.coords)
    points = []

    for i in range(len(coords) - 1):
        a = np.array(coords[i], float)
        b = np.array(coords[i + 1], float)
        length = float(np.linalg.norm(b - a))
        count = max(2, int(length / spacing))
        # Keep points away from polygon corners to preserve joint capacity.
        for t in np.linspace(0.10, 0.90, count):
            points.append(a + t * (b - a))

    # Add a restrained set of vertices; they can still be useful.
    for x, y in coords[:-1]:
        points.append(np.array([x, y], float))

    unique = {}
    for p in points:
        unique[(round(float(p[0]), 2), round(float(p[1]), 2))] = p
    return list(unique.values())


def point_is_on_cell_boundary(p, poly):
    return Point(float(p[0]), float(p[1])).distance(poly.boundary) <= 1.5


def valid_candidate(a, b, poly, segments):
    candidate = (a.copy(), b.copy())
    length = seg_length(candidate)

    if length < MIN_LENGTH:
        return False
    if degree(a, segments) >= MAX_DEGREE or degree(b, segments) >= MAX_DEGREE:
        return False
    if not joint_ok(a, b - a, segments):
        return False
    if not joint_ok(b, a - b, segments):
        return False
    if not candidate_intersections_ok(candidate, segments):
        return False
    if not clearance_ok(candidate, segments):
        return False

    line = LineString([(float(a[0]), float(a[1])),
                       (float(b[0]), float(b[1]))])
    # Chord must remain inside the selected opening.
    if not poly.buffer(1.5).covers(line):
        return False

    # Avoid merely tracing the existing boundary.
    if line.length - line.difference(poly.boundary.buffer(2.0)).length > line.length * 0.65:
        return False

    return True


def split_quality(candidate, poly):
    """Estimate how evenly the candidate divides the selected opening."""
    line = LineString([
        (float(candidate[0][0]), float(candidate[0][1])),
        (float(candidate[1][0]), float(candidate[1][1])),
    ])
    boundary = poly.boundary
    network = unary_union([boundary, line])
    pieces = [p for p in polygonize(network) if p.area > 20.0]

    if len(pieces) < 2:
        return None

    areas = sorted([p.area for p in pieces], reverse=True)
    if len(areas) < 2:
        return None

    balance = min(areas[0], areas[1]) / max(areas[0], areas[1])
    child_radii = [measure_cell(p)[0] for p in pieces]
    worst_child = max(child_radii)
    return balance, worst_child


def longest_greedy_candidate(poly, center, min_len, max_len, segments):
    boundary_points = sample_polygon_boundary(poly)
    candidates = []

    # Generate many endpoint pairs, but rank primarily by usable length.
    # A small quality term prevents very long cuts that barely shave a corner.
    for _ in range(900):
        a, b = rng.sample(boundary_points, 2)
        length = float(np.linalg.norm(b - a))
        if not (min_len <= length <= max_len):
            continue
        if not valid_candidate(a, b, poly, segments):
            continue

        quality = split_quality((a, b), poly)
        if quality is None:
            continue

        balance, worst_child = quality
        midpoint = (a + b) * 0.5
        center_alignment = 1.0 - min(
            float(np.linalg.norm(midpoint - center)) / max(W, H),
            1.0,
        )

        # Lexicographic spirit:
        # 1) longest fitting stock
        # 2) meaningful reduction of the opening
        # 3) reasonably balanced light spots
        score = (
            length
            + 0.55 * (max_len - worst_child)
            + 90.0 * balance
            + 30.0 * center_alignment
        )
        candidates.append((score, length, balance, worst_child, (a, b)))

    if not candidates:
        return None

    candidates.sort(key=lambda item: item[0], reverse=True)
    return candidates[0]


def phase_for_radius(radius, used_by_phase):
    # The opening determines which stock pile the carpenter visits.
    preferred = (
        "P0" if radius > 430 else
        "P1" if radius > 310 else
        "P2" if radius > TARGET_MAX_RADIUS else
        "P3"
    )

    names = [x[0] for x in INVENTORY]
    start = names.index(preferred)
    order = names[start:] + names[:start]

    inventory_map = {name: (lo, hi, count) for name, lo, hi, count in INVENTORY}
    for name in order:
        lo, hi, count = inventory_map[name]
        if used_by_phase.get(name, 0) < count:
            return name, lo, hi
    return None


segments = list(hidden_frame)
struts = []
records = []
used_by_phase = {}

# Greedy loop: always reassess the openings after every installed member.
for step in range(MAX_TOTAL):
    cells = measured_cells(segments)
    if not cells:
        break

    radius, center, poly = cells[0]
    if radius <= TARGET_MAX_RADIUS and len(struts) >= 30:
        break

    phase = phase_for_radius(radius, used_by_phase)
    if phase is None:
        break

    name, min_len, max_len = phase
    chosen = longest_greedy_candidate(poly, center, min_len, max_len, segments)

    # If the preferred pile cannot fit, try progressively shorter stock.
    if chosen is None:
        fallback = []
        for n, lo, hi, count in INVENTORY:
            if used_by_phase.get(n, 0) >= count:
                continue
            test = longest_greedy_candidate(poly, center, lo, hi, segments)
            if test is not None:
                fallback.append((test[0], n, lo, hi, test))
        if not fallback:
            # Try the next-largest opening before giving up globally.
            installed = False
            for radius2, center2, poly2 in cells[1:6]:
                for n, lo, hi, count in INVENTORY:
                    if used_by_phase.get(n, 0) >= count:
                        continue
                    test = longest_greedy_candidate(poly2, center2, lo, hi, segments)
                    if test is not None:
                        _, length, balance, child_radius, candidate = test
                        struts.append(candidate)
                        segments.append(candidate)
                        used_by_phase[n] = used_by_phase.get(n, 0) + 1
                        records.append((n, length, radius2, child_radius, balance, candidate))
                        installed = True
                        break
                if installed:
                    break
            if not installed:
                break
            continue

        _, name, min_len, max_len, chosen = max(fallback, key=lambda x: x[0])

    _, length, balance, child_radius, candidate = chosen
    struts.append(candidate)
    segments.append(candidate)
    used_by_phase[name] = used_by_phase.get(name, 0) + 1
    records.append((name, length, radius, child_radius, balance, candidate))


# -----------------------------
# Validation
# -----------------------------
cells = measured_cells(segments)
radii = [item[0] for item in cells]

junctions = {}
for i, s1 in enumerate(segments):
    for s2 in segments[i + 1:]:
        hit = segment_intersection(s1, s2)
        if hit:
            p, _, _ = hit
            junctions[(round(float(p[0]), 2), round(float(p[1]), 2))] = p

angles = []
degrees = []
unsupported_degree2 = 0

for p in junctions.values():
    dirs = incident_directions(p, segments)
    degrees.append(len(dirs))

    on_hidden_frame = (
        abs(p[0] - L) < 1.5 or abs(p[0] - R) < 1.5 or
        abs(p[1] - B) < 1.5 or abs(p[1] - T) < 1.5
    )
    if not on_hidden_frame and len(dirs) == 2:
        unsupported_degree2 += 1

    for i in range(len(dirs)):
        for j in range(i + 1, len(dirs)):
            a = angle_between(dirs[i], dirs[j])
            if a > 0.05:
                angles.append(a)


# -----------------------------
# Borderless rendering
# -----------------------------
fig = plt.figure(figsize=(W / 100.0, H / 100.0), dpi=100)
ax = fig.add_axes([0, 0, 1, 1])

for a, b in struts:
    ax.plot(
        [a[0], b[0]],
        [a[1], b[1]],
        color="black",
        linewidth=STROKE * 72.0 / 100.0,
        solid_capstyle="butt",
        solid_joinstyle="miter",
        clip_on=True,
    )

ax.set_xlim(0, W)
ax.set_ylim(0, H)
ax.set_aspect("equal")
ax.axis("off")

fig.savefig(PNG_PATH, dpi=100, pad_inches=0)
fig.savefig(SVG_PATH, format="svg", pad_inches=0)
plt.close(fig)

print({
    "algorithm": "greedy carpenter",
    "canvas": f"{W}x{H}",
    "visible_border": False,
    "total_struts": len(struts),
    "phase_counts": used_by_phase,
    "shortest_member_px": round(min(seg_length(s) for s in struts), 1) if struts else None,
    "longest_member_px": round(max(seg_length(s) for s in struts), 1) if struts else None,
    "largest_cell_radius_px": round(max(radii), 1) if radii else None,
    "cells_over_240_px": sum(r > TARGET_MAX_RADIUS for r in radii),
    "minimum_joint_angle_deg": round(min(angles), 2) if angles else None,
    "maximum_degree": max(degrees) if degrees else None,
    "unsupported_interior_degree2": unsupported_degree2,
})
print(PNG_PATH)
print(SVG_PATH)
