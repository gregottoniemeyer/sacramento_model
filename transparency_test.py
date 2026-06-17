#!/usr/bin/env python3
"""Render an alpha-masked chevron test image."""

from __future__ import annotations

from pathlib import Path

from PIL import Image
from Quartz import (  # type: ignore
    CGBitmapContextCreate,
    CGBitmapContextCreateImage,
    CGColorSpaceCreateDeviceRGB,
    CGDataProviderCopyData,
    CGContextAddLineToPoint,
    CGContextBeginPath,
    CGContextClip,
    CGContextClosePath,
    CGContextFillRect,
    CGContextMoveToPoint,
    CGContextRestoreGState,
    CGContextSaveGState,
    CGContextScaleCTM,
    CGContextSetAllowsAntialiasing,
    CGContextSetInterpolationQuality,
    CGContextSetLineCap,
    CGContextSetLineJoin,
    CGContextSetLineWidth,
    CGContextSetMiterLimit,
    CGContextSetRGBFillColor,
    CGContextSetRGBStrokeColor,
    CGContextSetShouldAntialias,
    CGContextStrokeEllipseInRect,
    CGContextStrokePath,
    CGContextTranslateCTM,
    CGRectMake,
    CGImageGetDataProvider,
    CGImageGetHeight,
    CGImageGetWidth,
    kCGImageAlphaPremultipliedLast,
    kCGInterpolationHigh,
    kCGLineCapButt,
    kCGLineJoinMiter,
)


WIDTH = 1080 #1800
HEIGHT = 1920 #2400
OUTPUT = Path("img/alpha_test.png")
DODGER_BLUE = (30, 144, 255, 255)
WHITE = (255, 255, 255, 255)
BLACK = (0, 0, 0, 255)
CHEVRON_ROWS = 16
CHEVRON_RISE = 1.2 #1.5
CHEVRON_TOUCH_OVERLAP = 1.02
CHEVRON_OFFSET = 0.5
CHEVRON_OVERDRAW_TOP = 1
RING_WIDTH_SCALE = 0.9
RING_POOL_DIAMETER_SCALE = 4 / 3
RING_POOL_CENTER_OFFSET_SCALE = 2/5#2.3 / 5


def mask_polygon(width: int, height: int) -> list[tuple[float, float]]:
    return [
        (width / 3, 0),
        (width * 2 / 3, 0),
        (width * 3 / 4, height),
        (width / 4, height),
    ]


def chevron_stroke_width(height: int) -> float:
    return height / CHEVRON_ROWS * CHEVRON_TOUCH_OVERLAP


def chevron_paths(width: int, height: int) -> list[tuple[tuple[int, int, int, int], list[tuple[float, float]]]]:
    paths = []
    pitch = height / CHEVRON_ROWS
    stroke_width = chevron_stroke_width(height)
    y = -pitch * 0.65 + pitch * CHEVRON_OFFSET - pitch * CHEVRON_OVERDRAW_TOP
    index = 1

    while y < height + pitch:
        points = [
            (-stroke_width, y),
            (width / 2.0, y + pitch * CHEVRON_RISE),
            (width + stroke_width, y),
        ]
        color = WHITE if index % 2 == 0 else BLACK
        paths.append((color, points))
        y += pitch
        index += 1

    return paths


def draw_ring_pool(context) -> None:
    ring_width = chevron_stroke_width(HEIGHT) * RING_WIDTH_SCALE
    max_diameter = WIDTH * RING_POOL_DIAMETER_SCALE
    center_x = WIDTH / 2
    center_y = HEIGHT + WIDTH * RING_POOL_CENTER_OFFSET_SCALE
    radius = ring_width / 2
    index = 0

    CGContextSetLineWidth(context, ring_width)
    CGContextSetLineCap(context, kCGLineCapButt)

    while radius <= max_diameter / 2 + ring_width:
        color = WHITE if index % 2 == 0 else BLACK
        CGContextSetRGBStrokeColor(
            context,
            color[0] / 255,
            color[1] / 255,
            color[2] / 255,
            color[3] / 255,
        )
        CGContextStrokeEllipseInRect(
            context,
            CGRectMake(
                center_x - radius,
                center_y - radius,
                radius * 2,
                radius * 2,
            ),
        )
        radius += ring_width
        index += 1


def render(path: Path) -> None:
    bytes_per_row = WIDTH * 4
    color_space = CGColorSpaceCreateDeviceRGB()
    context = CGBitmapContextCreate(
        None,
        WIDTH,
        HEIGHT,
        8,
        bytes_per_row,
        color_space,
        kCGImageAlphaPremultipliedLast,
    )

    CGContextSetShouldAntialias(context, True)
    CGContextSetAllowsAntialiasing(context, True)
    CGContextSetInterpolationQuality(context, kCGInterpolationHigh)
    CGContextTranslateCTM(context, 0, HEIGHT)
    CGContextScaleCTM(context, 1, -1)

    CGContextSetRGBFillColor(context, 30 / 255, 144 / 255, 1, 1)
    CGContextFillRect(context, CGRectMake(0, 0, WIDTH, HEIGHT))

    CGContextSaveGState(context)
    CGContextBeginPath(context)
    points = mask_polygon(WIDTH, HEIGHT)
    CGContextMoveToPoint(context, points[0][0], points[0][1])
    for x, y in points[1:]:
        CGContextAddLineToPoint(context, x, y)
    CGContextClosePath(context)
    CGContextClip(context)

    CGContextSetLineJoin(context, kCGLineJoinMiter)
    CGContextSetLineCap(context, kCGLineCapButt)
    CGContextSetMiterLimit(context, 20)
    CGContextSetLineWidth(context, chevron_stroke_width(HEIGHT))

    for color, points in chevron_paths(WIDTH, HEIGHT):
        CGContextSetRGBStrokeColor(
            context,
            color[0] / 255,
            color[1] / 255,
            color[2] / 255,
            color[3] / 255,
        )
        CGContextBeginPath(context)
        CGContextMoveToPoint(context, points[0][0], points[0][1])
        for x, y in points[1:]:
            CGContextAddLineToPoint(context, x, y)
        CGContextStrokePath(context)

    CGContextRestoreGState(context)
    draw_ring_pool(context)

    cg_image = CGBitmapContextCreateImage(context)
    width = CGImageGetWidth(cg_image)
    height = CGImageGetHeight(cg_image)
    provider = CGImageGetDataProvider(cg_image)
    data = CGDataProviderCopyData(provider)
    image = Image.frombuffer("RGBA", (width, height), bytes(data), "raw", "RGBA", 0, 1)
    path.parent.mkdir(parents=True, exist_ok=True)
    image.save(path)


def main() -> None:
    render(OUTPUT)
    print(f"wrote {OUTPUT} using Quartz")


if __name__ == "__main__":
    main()
