#!/usr/bin/env python3
"""Report rough model-space DXF bounds by layer using only the stdlib.

This is intentionally small: it reads coordinate-bearing entities from the
manufacturer drawing so enclosure dimensions can be checked without a CAD
dependency. INSERT transformations and spline control points are not expanded.
"""

from __future__ import annotations

import argparse
from collections import Counter, defaultdict
from pathlib import Path


def pairs(path: Path):
    lines = path.read_text(errors="replace").splitlines()
    for index in range(0, len(lines) - 1, 2):
        try:
            code = int(lines[index].strip())
        except ValueError:
            continue
        yield code, lines[index + 1].strip()


def entities(path: Path):
    section = None
    current = None
    values = []
    stream = iter(pairs(path))
    for code, value in stream:
        if code == 0 and value == "SECTION":
            section_code, section = next(stream)
            assert section_code == 2
            continue
        if code == 0 and value == "ENDSEC":
            if section == "ENTITIES" and current:
                yield current, values
            section = None
            current = None
            values = []
            continue
        if section != "ENTITIES":
            continue
        if code == 0:
            if current:
                yield current, values
            current = value
            values = []
        elif current:
            values.append((code, value))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("dxf", type=Path)
    parser.add_argument("--minimum-entities", type=int, default=1)
    parser.add_argument("--details", metavar="LAYER")
    args = parser.parse_args()

    counts = Counter()
    bounds = defaultdict(lambda: [float("inf"), float("inf"), float("-inf"), float("-inf")])
    detail_rows = []
    for kind, values in entities(args.dxf):
        layer = next((value for code, value in values if code == 8), "0")
        xs = [float(value) for code, value in values if code in {10, 11, 12, 13}]
        ys = [float(value) for code, value in values if code in {20, 21, 22, 23}]
        if not xs or not ys:
            continue
        counts[(layer, kind)] += 1
        box = bounds[layer]
        box[0] = min(box[0], *xs)
        box[1] = min(box[1], *ys)
        box[2] = max(box[2], *xs)
        box[3] = max(box[3], *ys)
        if args.details == layer:
            flags = next((value for code, value in values if code == 70), "")
            vertex_count = next((value for code, value in values if code == 90), "")
            detail_rows.append((kind, min(xs), min(ys), max(xs), max(ys), flags, vertex_count))

    if args.details:
        for kind, x1, y1, x2, y2, flags, vertex_count in sorted(
            detail_rows, key=lambda row: (row[1], row[2], row[0])
        ):
            print(
                f"{kind:12} x={x1:9.3f}..{x2:9.3f} ({x2-x1:7.3f}) "
                f"y={y1:9.3f}..{y2:9.3f} ({y2-y1:7.3f}) "
                f"flags={flags!s:>3} vertices={vertex_count}"
            )
        return

    for layer, box in sorted(bounds.items(), key=lambda item: item[0].lower()):
        total = sum(count for (name, _), count in counts.items() if name == layer)
        if total < args.minimum_entities:
            continue
        kinds = ", ".join(
            f"{kind}:{count}"
            for (name, kind), count in sorted(counts.items())
            if name == layer
        )
        print(
            f"{layer:32} entities={total:5} "
            f"x={box[0]:9.3f}..{box[2]:9.3f} ({box[2]-box[0]:8.3f}) "
            f"y={box[1]:9.3f}..{box[3]:9.3f} ({box[3]-box[1]:8.3f}) "
            f"[{kinds}]"
        )


if __name__ == "__main__":
    main()
