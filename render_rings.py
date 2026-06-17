#!/usr/bin/env python3
"""Render transparent PNG frames of emanating black/white radial rings."""

from __future__ import annotations

import argparse
import re
from pathlib import Path

import numpy as np
from PIL import Image


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


def radial_distances(size: int, scale: int) -> np.ndarray:
    render_size = size * scale
    center = (render_size - 1) / 2.0
    coordinates = np.arange(render_size, dtype=np.float32)
    y, x = np.meshgrid(coordinates, coordinates, indexing="ij")
    return np.hypot(x - center, y - center)


def render_frame(
    distances: np.ndarray,
    size: int,
    scale: int,
    ring: int,
    phase: float,
    color: tuple[int, int, int],
    altcolor: tuple[int, int, int],
) -> Image.Image:
    scaled_ring = ring * scale
    period = scaled_ring * 2
    max_radius = size * scale / 2.0
    band_position = (distances - phase * scale) % period
    color_mask = band_position < scaled_ring
    visible_mask = distances <= max_radius

    pixels = np.zeros((*distances.shape, 4), dtype=np.uint8)
    pixels[color_mask, :3] = color
    pixels[~color_mask, :3] = altcolor
    pixels[visible_mask, 3] = 255

    image = Image.fromarray(pixels, mode="RGBA")
    if scale == 1:
        return image
    return image.resize((size, size), Image.Resampling.LANCZOS)


def render(args: argparse.Namespace) -> list[Path]:
    args.outdir.mkdir(parents=True, exist_ok=True)
    distances = radial_distances(args.size, args.scale)
    cycle_distance = args.ring * 2
    written: list[Path] = []

    for index in range(args.frames):
        phase = cycle_distance * index / args.frames - args.ring / 2
        image = render_frame(
            distances,
            args.size,
            args.scale,
            args.ring,
            phase,
            args.color,
            args.altcolor,
        )
        path = args.outdir / f"{args.prefix}_{index + 1:04d}.png"
        image.save(path)
        written.append(path)

    return written


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Render a seamless transparent PNG cycle of radial rings."
    )
    parser.add_argument("--color", type=parse_color, default="#ffffff")
    parser.add_argument("--altcolor", type=parse_color, default="#000000")
    parser.add_argument("--ring", type=positive_int, default=128)
    parser.add_argument("--size", type=positive_int, default=1024)
    parser.add_argument("--frames", type=positive_int, default=256)
    parser.add_argument("--outdir", type=Path, default=Path("img/rings"))
    parser.add_argument("--prefix", default="ring")
    parser.add_argument(
        "--scale",
        type=positive_int,
        default=4,
        help="Supersampling factor for smoother ring edges.",
    )
    return parser


def main() -> None:
    parser = build_parser()
    args = parser.parse_args()
    paths = render(args)
    print(f"wrote {len(paths)} frames to {args.outdir}")
    print(f"first: {paths[0]}")
    print(f"last:  {paths[-1]}")


if __name__ == "__main__":
    main()
