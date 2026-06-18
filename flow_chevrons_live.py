#!/usr/bin/env python3
"""
Real-time live chevron renderer for the Sacramento Model.
Based directly on Greg's transparency_test.py drawing approach:
- Stroked lines for chevrons (not filled polygons) crisp edges
- Clipping mask for river channel shape
- Stroked ellipses for ring pool at bottom
- Live NSWindow + NSTimer instead of saving to PNG

KEYBOARD CONTROLS
-----------------
  0-9     flow speed (0 = stopped, 9 = fastest)
  R       reverse flow direction
  ]       increase ring pool alpha (more opaque)
  [       decrease ring pool alpha (more transparent)
  ESC     quit

INSTALL
-------
  pip install pyobjc

RUN
---
  python3 flow_chevrons_live2.py
"""

from __future__ import annotations

import math

import objc
import Quartz
from AppKit import (
    NSApp,
    NSApplication,
    NSBackingStoreBuffered,
    NSTimer,
    NSView,
    NSWindow,
    NSWindowStyleMaskClosable,
    NSWindowStyleMaskResizable,
    NSWindowStyleMaskTitled,
)
from Foundation import NSMakeRect
from Quartz import (
    CGBitmapContextCreate,
    CGBitmapContextCreateImage,
    CGColorSpaceCreateDeviceRGB,
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
    CGContextSetAlpha,
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
    kCGImageAlphaPremultipliedLast,
    kCGInterpolationHigh,
    kCGLineCapButt,
    kCGLineJoinMiter,
)

# Drawing parameters: mirrors the transparency_test.py constants

WINDOW_WIDTH = 1080
WINDOW_HEIGHT = 1920
FPS = 120.0

CHEVRON_ROWS = 16
CHEVRON_RISE = 1.2
CHEVRON_TOUCH_OVERLAP = 1.0  # exactly 1.0 = equal black and white stripe width
CHEVRON_OVERDRAW_TOP = 1

RING_WIDTH_SCALE = 0.28  # thinner rings = more concentric circles visible
RING_POOL_DIAMETER_SCALE = 4 / 3
RING_POOL_CENTER_OFFSET_SCALE = 2 / 5

WHITE = (1.0, 1.0, 1.0, 1.0)
BLACK = (0.0, 0.0, 0.0, 1.0)
BG = (30 / 255, 144 / 255, 1.0, 1.0)  # Dodger blue background

# Drawing helpers (Prof's approach: stroked lines + clip mask)


def chevron_stroke_width(height: float) -> float:
    return height / CHEVRON_ROWS * CHEVRON_TOUCH_OVERLAP


def mask_polygon(width: float, height: float) -> list[tuple[float, float]]:
    """Trapezoid clip region — the river channel shape."""
    return [
        (width / 3, 0),
        (width * 2 / 3, 0),
        (width * 3 / 4, height),
        (width / 4, height),
    ]


def draw_chevrons(ctx, width: float, height: float, offset: float) -> None:
    """
    Draw animated chevron stripes inside a clipping mask.
    offset advances each frame to create the flow animation.
    """
    CGContextSaveGState(ctx)

    # Apply clip mask (trapezoid river channel)
    # Anti-alias ON before clip so the boundary edge is smooth
    CGContextSetShouldAntialias(ctx, True)
    CGContextSetAllowsAntialiasing(ctx, True)
    CGContextBeginPath(ctx)
    points = mask_polygon(width, height)
    CGContextMoveToPoint(ctx, points[0][0], points[0][1])
    for x, y in points[1:]:
        CGContextAddLineToPoint(ctx, x, y)
    CGContextClosePath(ctx)
    CGContextClip(ctx)

    # Stroke settings
    CGContextSetLineJoin(ctx, kCGLineJoinMiter)
    CGContextSetLineCap(ctx, kCGLineCapButt)
    CGContextSetMiterLimit(ctx, 20)
    stroke_width = chevron_stroke_width(height)
    CGContextSetLineWidth(ctx, stroke_width)

    pitch = height / CHEVRON_ROWS
    # pitches_traveled keeps color locked to position as offset grows,
    # preventing the color-flip jump when offset crosses a pitch boundary
    pitches_traveled = int(offset / pitch)
    y_start = -pitch * 0.65 + (offset % pitch) - pitch * CHEVRON_OVERDRAW_TOP
    index = pitches_traveled

    y = y_start
    while y < height + pitch:
        color = WHITE if index % 2 == 0 else BLACK
        CGContextSetRGBStrokeColor(ctx, *color)
        CGContextBeginPath(ctx)
        CGContextMoveToPoint(ctx, -stroke_width, y)
        CGContextAddLineToPoint(ctx, width / 2.0, y + pitch * CHEVRON_RISE)
        CGContextAddLineToPoint(ctx, width + stroke_width, y)
        CGContextStrokePath(ctx)
        y += pitch
        index += 1

    CGContextRestoreGState(ctx)


def draw_ring_pool(
    ctx, width: float, height: float, alpha: float = 1.0, ring_offset: float = 0.0
) -> None:
    """
    Concentric ring pool at bottom, alpha-composited over whatever is below.
    ring_offset animates rings moving inward each frame.
    alpha controls transparency of the entire pool layer (0.0 = invisible, 1.0 = opaque).
    """
    ring_width = chevron_stroke_width(height) * RING_WIDTH_SCALE
    max_diameter = width * RING_POOL_DIAMETER_SCALE
    center_x = width / 2
    center_y = height + width * RING_POOL_CENTER_OFFSET_SCALE

    CGContextSaveGState(ctx)
    CGContextSetAlpha(ctx, alpha)  # whole layer alpha -- composites over chevrons
    CGContextSetLineWidth(ctx, ring_width)
    CGContextSetLineCap(ctx, kCGLineCapButt)

    # ring_offset shifts which ring is drawn at each radius,
    # creating the inward-moving animation effect
    period = ring_width * 2
    radius = ring_width / 2

    while radius <= max_diameter / 2 + ring_width:
        # Use offset to shift color boundary -- rings appear to move inward
        band = (radius + ring_offset) % period
        color = WHITE if band < ring_width else BLACK
        CGContextSetRGBStrokeColor(ctx, *color)
        CGContextStrokeEllipseInRect(
            ctx,
            CGRectMake(
                center_x - radius,
                center_y - radius,
                radius * 2,
                radius * 2,
            ),
        )
        radius += ring_width

    CGContextRestoreGState(ctx)


# NSView subclass


class ChevronView(NSView):
    def initWithFrame_(self, frame):
        self = objc.super(ChevronView, self).initWithFrame_(frame)
        if self is None:
            return None

        self.speed = 5  # 0-9
        self.reversed = False
        self.offset = 0.0  # chevron pixel offset
        self.ring_alpha = 1.0  # 0.0-1.0, controlled by [ and ]
        self.ring_offset = 0.0  # animates rings inward

        self.timer = (
            NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(
                1.0 / FPS, self, "tick:", None, True
            )
        )
        # Enable Retina / HiDPI rendering so the view draws at full
        # physical pixel resolution instead of logical points -- fixes blur
        self.setWantsLayer_(True)
        self.layer().setContentsScale_(
            NSApplication.sharedApplication().mainWindow().backingScaleFactor()
            if NSApplication.sharedApplication().mainWindow()
            else 2.0
        )
        return self

    def acceptsFirstResponder(self):
        return True

    def viewDidChangeBackingProperties(self):
        # Called when moved between displays or backing scale changes
        window = self.window()
        if window:
            self.layer().setContentsScale_(window.backingScaleFactor())
        self.setNeedsDisplay_(True)

    def tick_(self, _timer):
        pitch = WINDOW_HEIGHT / CHEVRON_ROWS
        px_per_frame = (self.speed / 9.0) * pitch * 0.02
        if self.reversed:
            self.offset -= px_per_frame
        else:
            self.offset += px_per_frame
        # No modulo here -- draw_chevrons handles wrapping internally
        # Advance ring animation inward (independent of chevron speed)
        ring_pitch = WINDOW_HEIGHT / CHEVRON_ROWS * RING_WIDTH_SCALE
        self.ring_offset += ring_pitch * 0.015
        self.setNeedsDisplay_(True)

    def keyDown_(self, event):
        chars = event.characters()
        if not chars:
            return
        key = chars[0]

        if key.isdigit():
            self.speed = int(key)
            print(f"speed: {self.speed}")
        elif key.lower() == "r":
            self.reversed = not self.reversed
            print(f"reversed: {self.reversed}")
        elif key == "]":
            self.ring_alpha = min(1.0, self.ring_alpha + 0.05)
            print(f"ring alpha: {self.ring_alpha:.2f}")
        elif key == "[":
            self.ring_alpha = max(0.0, self.ring_alpha - 0.05)
            print(f"ring alpha: {self.ring_alpha:.2f}")
        elif ord(key) == 27:
            NSApp.terminate_(self)

    def drawRect_(self, rect):
        ctx = Quartz.NSGraphicsContext.currentContext().CGContext()
        bounds = self.bounds()
        w = bounds.size.width
        h = bounds.size.height

        # Match the coordinate system: flip Y so 0,0 is top-left
        CGContextTranslateCTM(ctx, 0, h)
        CGContextScaleCTM(ctx, 1, -1)

        # Anti-aliasing on, gives smooth strokes
        CGContextSetShouldAntialias(ctx, True)
        CGContextSetAllowsAntialiasing(ctx, True)
        CGContextSetInterpolationQuality(ctx, kCGInterpolationHigh)

        # Background
        CGContextSetRGBFillColor(ctx, *BG)
        CGContextFillRect(ctx, CGRectMake(0, 0, w, h))

        # Chevrons (animated)
        draw_chevrons(ctx, w, h, self.offset)

        # Ring pool: alpha-composited over chevrons, animated inward
        draw_ring_pool(ctx, w, h, alpha=self.ring_alpha, ring_offset=self.ring_offset)


# App entry point


def main() -> None:
    app = NSApplication.sharedApplication()

    style = (
        NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable
    )
    # Start at half resolution for easier testing; scales up fine
    rect = NSMakeRect(100, 100, WINDOW_WIDTH // 2, WINDOW_HEIGHT // 2)
    window = NSWindow.alloc().initWithContentRect_styleMask_backing_defer_(
        rect, style, NSBackingStoreBuffered, False
    )
    window.setTitle_("Sacramento Model — Live Chevron Flow")

    view = ChevronView.alloc().initWithFrame_(rect)
    window.setContentView_(view)
    window.makeFirstResponder_(view)
    window.makeKeyAndOrderFront_(None)

    app.activateIgnoringOtherApps_(True)
    app.run()


if __name__ == "__main__":
    main()
