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


WIDTH = 1080
HEIGHT = 1920
OUTPUT = Path("img/alpha_test.png")
DODGER_BLUE = (30, 144, 255, 255)
WHITE = (255, 255, 255, 255)
BLACK = (0, 0, 0, 255)
CHEVRON_ROWS = 6
CHEVRON_RISE = 0.72
CHEVRON_TOUCH_OVERLAP = 1.02


def mask_polygon(width: int, height: int) -> list[tuple[float, float]]:
    return [
        (width * 0.25, 0),
        (width * 0.75, 0),
        (width, height),
        (0, height),
    ]


def chevron_paths(width: int, height: int) -> list[tuple[tuple[int, int, int, int], list[tuple[float, float]]]]:
    paths = []
    pitch = height / CHEVRON_ROWS
    stroke_width = pitch * CHEVRON_TOUCH_OVERLAP
    y = -pitch * 0.65
    index = 0

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
    CGContextSetLineWidth(context, HEIGHT / CHEVRON_ROWS * CHEVRON_TOUCH_OVERLAP)

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
