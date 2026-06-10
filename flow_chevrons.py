#!/usr/bin/env python3
"""Render looping chevron flow frames as JPEGs."""

from __future__ import annotations

import argparse
import math
import re
from pathlib import Path

from PIL import Image, ImageDraw


FPS = 30
MOTION_SPEED_SCALE = 0.5


def parse_color(value: str) -> tuple[int, int, int]:
    match = re.fullmatch(r"#?([0-9a-fA-F]{6})", value.strip())
    if not match:
        raise argparse.ArgumentTypeError(
            f"{value!r} is not a hex color like #ffffff"
        )

    raw = match.group(1)
    return tuple(int(raw[i : i + 2], 16) for i in (0, 2, 4))


def positive_int(value: str) -> int:
    parsed = int(value)
    if parsed <= 0:
        raise argparse.ArgumentTypeError("must be greater than 0")
    return parsed


def positive_float(value: str) -> float:
    parsed = float(value)
    if parsed <= 0:
        raise argparse.ArgumentTypeError("must be greater than 0")
    return parsed


def speed_label(speed: float) -> str:
    return f"{speed:g}".replace(".", "p")


def unit_vector(
    start: tuple[float, float],
    end: tuple[float, float],
) -> tuple[float, float]:
    dx = end[0] - start[0]
    dy = end[1] - start[1]
    length = math.hypot(dx, dy)
    if length == 0:
        return (0.0, 0.0)
    return (dx / length, dy / length)


def line_intersection(
    point_a: tuple[float, float],
    direction_a: tuple[float, float],
    point_b: tuple[float, float],
    direction_b: tuple[float, float],
) -> tuple[float, float] | None:
    denominator = direction_a[0] * direction_b[1] - direction_a[1] * direction_b[0]
    if abs(denominator) < 1e-9:
        return None

    dx = point_b[0] - point_a[0]
    dy = point_b[1] - point_a[1]
    amount = (dx * direction_b[1] - dy * direction_b[0]) / denominator
    return (
        point_a[0] + direction_a[0] * amount,
        point_a[1] + direction_a[1] * amount,
    )


def clip_polygon_x(
    points: list[tuple[float, float]],
    boundary_x: float,
    keep_left: bool,
) -> list[tuple[float, float]]:
    clipped: list[tuple[float, float]] = []

    def inside(point: tuple[float, float]) -> bool:
        return point[0] <= boundary_x if keep_left else point[0] >= boundary_x

    def intersection(
        start: tuple[float, float],
        end: tuple[float, float],
    ) -> tuple[float, float]:
        dx = end[0] - start[0]
        if abs(dx) < 1e-9:
            return (boundary_x, start[1])
        amount = (boundary_x - start[0]) / dx
        return (boundary_x, start[1] + (end[1] - start[1]) * amount)

    previous = points[-1]
    previous_inside = inside(previous)
    for current in points:
        current_inside = inside(current)
        if current_inside:
            if not previous_inside:
                clipped.append(intersection(previous, current))
            clipped.append(current)
        elif previous_inside:
            clipped.append(intersection(previous, current))
        previous = current
        previous_inside = current_inside

    return clipped


def chevron_polygon(
    center_axis: float,
    cross_center: float,
    axis_length: float,
    cross_span: float,
    thickness: float,
    orientation: str,
) -> list[tuple[float, float]]:
    half_axis = axis_length / 2.0
    half_cross = cross_span / 2.0

    if orientation == "h":
        tail_x = center_axis - half_axis
        tip_x = center_axis + half_axis
        path = [
            (tail_x, cross_center - half_cross),
            (tip_x, cross_center),
            (tail_x, cross_center + half_cross),
        ]
    else:
        tail_y = center_axis - half_axis
        tip_y = center_axis + half_axis
        path = [
            (cross_center - half_cross, tail_y),
            (cross_center, tip_y),
            (cross_center + half_cross, tail_y),
        ]

    half_thickness = thickness / 2.0
    first_direction = unit_vector(path[0], path[1])
    second_direction = unit_vector(path[1], path[2])
    first_normal = (-first_direction[1], first_direction[0])
    second_normal = (-second_direction[1], second_direction[0])

    first_plus = (
        path[0][0] + first_normal[0] * half_thickness,
        path[0][1] + first_normal[1] * half_thickness,
    )
    first_minus = (
        path[0][0] - first_normal[0] * half_thickness,
        path[0][1] - first_normal[1] * half_thickness,
    )
    second_plus = (
        path[2][0] + second_normal[0] * half_thickness,
        path[2][1] + second_normal[1] * half_thickness,
    )
    second_minus = (
        path[2][0] - second_normal[0] * half_thickness,
        path[2][1] - second_normal[1] * half_thickness,
    )

    first_join_plus = (
        path[1][0] + first_normal[0] * half_thickness,
        path[1][1] + first_normal[1] * half_thickness,
    )
    second_join_plus = (
        path[1][0] + second_normal[0] * half_thickness,
        path[1][1] + second_normal[1] * half_thickness,
    )
    first_join_minus = (
        path[1][0] - first_normal[0] * half_thickness,
        path[1][1] - first_normal[1] * half_thickness,
    )
    second_join_minus = (
        path[1][0] - second_normal[0] * half_thickness,
        path[1][1] - second_normal[1] * half_thickness,
    )

    join_plus = line_intersection(
        first_join_plus,
        first_direction,
        second_join_plus,
        second_direction,
    ) or first_join_plus
    join_minus = line_intersection(
        first_join_minus,
        first_direction,
        second_join_minus,
        second_direction,
    ) or first_join_minus

    return [
        first_plus,
        join_plus,
        second_plus,
        second_minus,
        join_minus,
        first_minus,
    ]


def draw_frame(
    width: int,
    height: int,
    color: tuple[int, int, int],
    altcolor: tuple[int, int, int],
    count: int,
    orientation: str,
    offset: float,
    scale: int,
) -> Image.Image:
    render_width = width * scale
    render_height = height * scale
    image = Image.new("RGB", (render_width, render_height), altcolor)
    draw = ImageDraw.Draw(image)

    actual_axis_size = height * scale
    nominal_axis_size = (width if orientation == "h" else height) * scale
    tile_cross_size = (height if orientation == "h" else width) * scale
    pitch = nominal_axis_size / count
    axis_length = pitch * 0.86
    thickness = min(axis_length * 0.34, tile_cross_size * 0.18)
    cross_span = tile_cross_size + thickness * 1.5
    if orientation == "h":
        center_line = width * scale / 2.0
        cross_centers = [
            center_line - tile_cross_size / 2.0,
            center_line + tile_cross_size / 2.0,
        ]
    else:
        cross_centers = [width * scale / 2.0]
    scaled_offset = offset * scale

    # Draw beyond both edges so every shifted frame fully covers the plane.
    start = -pitch * 2.0 + scaled_offset
    end = actual_axis_size + pitch * 2.0
    chevron_total = int(math.ceil((end - start) / pitch)) + 1

    center_line = width * scale / 2.0
    for cross_index, cross_center in enumerate(cross_centers):
        for idx in range(chevron_total):
            center_axis = start + idx * pitch
            points = chevron_polygon(
                center_axis,
                cross_center,
                axis_length,
                cross_span,
                thickness,
                "v",
            )
            if orientation == "h":
                points = clip_polygon_x(
                    points,
                    center_line,
                    keep_left=cross_index == 0,
                )
            if len(points) >= 3:
                draw.polygon(points, fill=color)

    return image.resize((width, height), Image.Resampling.LANCZOS)


def loop_timing(axis_pixels: int, count: int, speed: float) -> tuple[int, int, float]:
    pitch = axis_pixels / count
    frames_per_pitch = pitch / speed * FPS
    loop_pitches = max(1, math.ceil(30 / frames_per_pitch))
    frames = max(30, round(frames_per_pitch * loop_pitches))
    actual_speed = pitch * loop_pitches / (frames / FPS)
    return frames, loop_pitches, actual_speed


def render(args: argparse.Namespace) -> list[Path]:
    axis_pixels = args.width if args.orientation == "h" else args.height
    pitch = axis_pixels / args.count
    motion_speed = args.speed * MOTION_SPEED_SCALE
    frames, loop_pitches, actual_speed = loop_timing(
        axis_pixels,
        args.count,
        motion_speed,
    )

    args.outdir.mkdir(parents=True, exist_ok=True)
    stem = f"{args.count}_{speed_label(args.speed)}_{args.orientation}"
    written: list[Path] = []

    for frame in range(frames):
        offset = (pitch * loop_pitches * frame / frames) % pitch
        image = draw_frame(
            args.width,
            args.height,
            args.color,
            args.altcolor,
            args.count,
            args.orientation,
            offset,
            args.scale,
        )
        path = args.outdir / f"{stem}_{frame:04d}.jpg"
        image.save(path, quality=args.quality, optimize=True)
        written.append(path)

    args.actual_speed = actual_speed
    args.loop_pitches = loop_pitches
    return written


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Render black/white chevron flow-rate animation frames."
    )
    parser.add_argument("--color", type=parse_color, default="#ffffff")
    parser.add_argument("--altcolor", type=parse_color, default="#000000")
    parser.add_argument("--count", type=positive_int, required=True)
    parser.add_argument(
        "--speed",
        type=positive_float,
        required=True,
        help="Nominal flow speed; rendered motion is calibrated to half this value.",
    )
    parser.add_argument("--orientation", choices=("h", "v"), required=True)
    parser.add_argument(
        "--width",
        type=positive_int,
        default=None,
        help="Defaults to 1920 for horizontal and 1080 for vertical.",
    )
    parser.add_argument(
        "--height",
        type=positive_int,
        default=None,
        help="Defaults to 1080 for horizontal and 1920 for vertical.",
    )
    parser.add_argument("--outdir", type=Path, default=Path("img"))
    parser.add_argument("--quality", type=positive_int, default=95)
    parser.add_argument(
        "--scale",
        type=positive_int,
        default=4,
        help="Supersampling factor for smoother chevron edges.",
    )
    return parser


def main() -> None:
    parser = build_parser()
    args = parser.parse_args()

    if args.quality > 100:
        parser.error("--quality must be 100 or less")

    if args.width is None:
        args.width = 1920 if args.orientation == "h" else 1080
    if args.height is None:
        args.height = 1080 if args.orientation == "h" else 1920

    paths = render(args)
    print(f"wrote {len(paths)} frames to {args.outdir}")
    print(f"loop shift: {args.loop_pitches} chevron spacing(s)")
    print(f"actual speed at {FPS} fps: {args.actual_speed:.3f} px/s")
    print(f"first: {paths[0]}")
    print(f"last:  {paths[-1]}")


if __name__ == "__main__":
    main()
