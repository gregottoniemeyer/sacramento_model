#!/usr/bin/env python3
"""Convert the inclusive all-river temperature source to the model's 720-frame loop."""

from __future__ import annotations

import argparse
import bisect
import csv
from datetime import datetime, timedelta
import json
import math
from pathlib import Path
from typing import Sequence


FRAME_COUNT = 720
DEFAULT_SOURCE = Path(__file__).resolve().with_name("water_temperature_all_rivers_720.csv")
FRAME_MINUTES = 730
LOOP_START = datetime(2025, 7, 1)
SOURCE_END = datetime(2026, 7, 1)
MIN_VALID_TEMP_C = -2.0
MAX_VALID_TEMP_C = 40.0
DEFAULT_OUTPUT = (
    Path(__file__).resolve().parents[1]
    / "godot_experiments"
    / "flow"
    / "data"
    / "water_pipeline"
    / "water_temperature_all_rivers_720.txt"
)

TIMELINE_COMMENTS = {
    "period": (
        "# period=2025-07-01 through 2026-06-30T11:50:00; "
        "half-open 365-day installation loop"
    ),
    "timestamps": (
        "# timestamps=720 evenly spaced half-open bins at 730 model minutes "
        "per row; Pacific local calendar time"
    ),
    "method": (
        "# method=calendar-day means from measured observations; missing daily "
        "means linearly interpolated; completed inclusive source series linearly "
        "reinterpolated onto 720 half-open installation frames"
    ),
}


def parse_timestamp(value: str) -> datetime:
    try:
        return datetime.fromisoformat(value)
    except ValueError as error:
        raise ValueError(f"invalid timestamp {value!r}") from error


def read_source(path: Path) -> tuple[list[str], list[str], list[list[str]]]:
    comments: list[str] = []
    csv_lines: list[str] = []
    with path.open(encoding="utf-8", newline="") as handle:
        for line in handle:
            if line.startswith("#") and not csv_lines:
                comments.append(line.rstrip("\r\n"))
            elif line.strip():
                csv_lines.append(line)

    if not csv_lines:
        raise ValueError(f"source contains no CSV table: {path}")
    table = list(csv.reader(csv_lines))
    header, rows = table[0], table[1:]
    return comments, header, rows


def validate_source(header: Sequence[str], rows: Sequence[Sequence[str]]) -> None:
    if len(rows) != FRAME_COUNT:
        raise ValueError(f"expected {FRAME_COUNT} source rows, found {len(rows)}")
    if list(header[:2]) != ["frame", "timestamp_pacific"]:
        raise ValueError(f"unexpected leading columns: {list(header[:2])}")
    if len(header) < 3 or any(not name.endswith("_temp_c") for name in header[2:]):
        raise ValueError("every data column must be a Celsius temperature column")
    if any("cottonwood" in name.lower() for name in header):
        raise ValueError("Cottonwood must remain excluded from this dataset")

    frames = [int(row[0]) for row in rows]
    if frames != list(range(FRAME_COUNT)):
        raise ValueError("source frames are not continuous from 0 through 719")

    timestamps = [parse_timestamp(row[1]) for row in rows]
    if timestamps[0] != LOOP_START or timestamps[-1] != SOURCE_END:
        raise ValueError(
            "source timeline must be inclusive from "
            f"{LOOP_START.isoformat()} through {SOURCE_END.isoformat()}"
        )
    if any(right <= left for left, right in zip(timestamps, timestamps[1:])):
        raise ValueError("source timestamps must be strictly increasing")

    for row in rows:
        if len(row) != len(header):
            raise ValueError(f"frame {row[0]} has {len(row)} columns; expected {len(header)}")
        for name, raw_value in zip(header[2:], row[2:]):
            value = float(raw_value)
            if not math.isfinite(value) or not MIN_VALID_TEMP_C <= value <= MAX_VALID_TEMP_C:
                raise ValueError(f"invalid {name} value at frame {row[0]}: {raw_value}")


def corrected_comments(comments: Sequence[str]) -> list[str]:
    corrected: list[str] = []
    replaced: set[str] = set()
    for comment in comments:
        key = comment[2:].split("=", 1)[0] if comment.startswith("# ") else ""
        if key in TIMELINE_COMMENTS:
            corrected.append(TIMELINE_COMMENTS[key])
            replaced.add(key)
        else:
            corrected.append(comment)
    missing = set(TIMELINE_COMMENTS) - replaced
    if missing:
        raise ValueError(f"source is missing timeline comments: {sorted(missing)}")
    return corrected


def interpolate_rows(
    header: Sequence[str], rows: Sequence[Sequence[str]]
) -> list[list[str]]:
    source_times = [parse_timestamp(row[1]) for row in rows]
    source_offsets = [(timestamp - LOOP_START).total_seconds() for timestamp in source_times]
    source_values = [[float(value) for value in row[2:]] for row in rows]
    output: list[list[str]] = []

    for frame in range(FRAME_COUNT):
        timestamp = LOOP_START + timedelta(minutes=frame * FRAME_MINUTES)
        offset = (timestamp - LOOP_START).total_seconds()
        right_index = bisect.bisect_left(source_offsets, offset)

        if right_index < len(source_offsets) and source_offsets[right_index] == offset:
            values = source_values[right_index]
        else:
            if right_index == 0 or right_index == len(source_offsets):
                raise ValueError(f"target timestamp is outside source timeline: {timestamp}")
            left_index = right_index - 1
            span = source_offsets[right_index] - source_offsets[left_index]
            weight = (offset - source_offsets[left_index]) / span
            values = [
                left + (right - left) * weight
                for left, right in zip(
                    source_values[left_index], source_values[right_index]
                )
            ]

        output.append(
            [
                str(frame),
                timestamp.isoformat(timespec="seconds"),
                *(f"{value:.3f}" for value in values),
            ]
        )

    return output


def validate_output(header: Sequence[str], rows: Sequence[Sequence[str]]) -> dict[str, object]:
    if len(rows) != FRAME_COUNT:
        raise ValueError(f"expected {FRAME_COUNT} output rows, found {len(rows)}")
    expected_timestamps = [
        LOOP_START + timedelta(minutes=frame * FRAME_MINUTES)
        for frame in range(FRAME_COUNT)
    ]
    if [int(row[0]) for row in rows] != list(range(FRAME_COUNT)):
        raise ValueError("output frames are not continuous from 0 through 719")
    if [parse_timestamp(row[1]) for row in rows] != expected_timestamps:
        raise ValueError("output timestamps do not match the 730-minute half-open timeline")

    ranges: dict[str, dict[str, float]] = {}
    for column_index, name in enumerate(header[2:], start=2):
        values = [float(row[column_index]) for row in rows]
        if any(
            not math.isfinite(value)
            or not MIN_VALID_TEMP_C <= value <= MAX_VALID_TEMP_C
            for value in values
        ):
            raise ValueError(f"output column {name} contains an invalid temperature")
        ranges[name] = {"min": min(values), "max": max(values)}

    return {
        "rows": len(rows),
        "first_frame": int(rows[0][0]),
        "last_frame": int(rows[-1][0]),
        "first_timestamp": rows[0][1],
        "last_timestamp": rows[-1][1],
        "frame_minutes": FRAME_MINUTES,
        "temperature_ranges_c": ranges,
    }


def write_output(
    path: Path,
    comments: Sequence[str],
    header: Sequence[str],
    rows: Sequence[Sequence[str]],
) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary_path = path.with_suffix(path.suffix + ".tmp")
    with temporary_path.open("w", encoding="utf-8", newline="") as handle:
        handle.write("\n".join(comments) + "\n")
        writer = csv.writer(handle, lineterminator="\n")
        writer.writerow(header)
        writer.writerows(rows)
    temporary_path.replace(path)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=DEFAULT_SOURCE)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    args = parser.parse_args()

    comments, header, source_rows = read_source(args.source)
    validate_source(header, source_rows)
    output_rows = interpolate_rows(header, source_rows)
    summary = validate_output(header, output_rows)
    write_output(args.output, corrected_comments(comments), header, output_rows)

    written_comments, written_header, written_rows = read_source(args.output)
    if written_header != header or written_comments != corrected_comments(comments):
        raise ValueError("written metadata or columns do not match the transformed dataset")
    if validate_output(written_header, written_rows) != summary:
        raise ValueError("written data does not match the validated transformation")

    summary.update({"source": str(args.source), "output": str(args.output)})
    print(json.dumps(summary, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
