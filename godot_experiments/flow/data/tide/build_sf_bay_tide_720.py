#!/usr/bin/env python3
"""Build the Delta's 720-sample SF Bay tide series from NOAA predictions."""

from __future__ import annotations

import argparse
import json
import math
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone
from pathlib import Path


STATION_ID = "9414290"
STATION_NAME = "San Francisco, CA"
START = datetime(2025, 7, 1, tzinfo=timezone.utc)
END_EXCLUSIVE = datetime(2026, 7, 1, tzinfo=timezone.utc)
SAMPLE_COUNT = 720
API_ENDPOINT = "https://api.tidesandcurrents.noaa.gov/api/prod/datagetter"


def source_url() -> str:
    query = urllib.parse.urlencode(
        {
            "begin_date": START.strftime("%Y%m%d"),
            "end_date": (END_EXCLUSIVE - timedelta(days=1)).strftime("%Y%m%d"),
            "station": STATION_ID,
            "product": "predictions",
            "datum": "MLLW",
            "time_zone": "gmt",
            "units": "metric",
            "interval": "h",
            "application": "water_council",
            "format": "json",
        }
    )
    return f"{API_ENDPOINT}?{query}"


def load_payload(input_json: Path | None) -> dict:
    if input_json is not None:
        return json.loads(input_json.read_text(encoding="utf-8"))
    request = urllib.request.Request(
        source_url(), headers={"User-Agent": "WaterCouncil/1.0"}
    )
    with urllib.request.urlopen(request, timeout=60) as response:
        return json.load(response)


def validated_hourly_values(payload: dict) -> list[float]:
    if "error" in payload:
        raise ValueError(f"NOAA returned an error: {payload['error']}")
    rows = payload.get("predictions")
    if not isinstance(rows, list):
        raise ValueError("NOAA response has no predictions array")
    expected_count = int((END_EXCLUSIVE - START).total_seconds() // 3600)
    if len(rows) != expected_count:
        raise ValueError(
            f"NOAA returned {len(rows)} hourly rows; expected {expected_count}"
        )
    values: list[float] = []
    for index, row in enumerate(rows):
        expected_time = START + timedelta(hours=index)
        actual_time = datetime.strptime(row["t"], "%Y-%m-%d %H:%M").replace(
            tzinfo=timezone.utc
        )
        if actual_time != expected_time:
            raise ValueError(
                f"hour {index} is {actual_time.isoformat()}, expected "
                f"{expected_time.isoformat()}"
            )
        value = float(row["v"])
        if not math.isfinite(value):
            raise ValueError(f"hour {index} has a non-finite water level")
        values.append(value)
    return values


def linear_sample(values: list[float], position: float) -> float:
    first = min(int(math.floor(position)), len(values) - 1)
    second = min(first + 1, len(values) - 1)
    fraction = position - math.floor(position)
    return values[first] + (values[second] - values[first]) * fraction


def source_velocity(values: list[float]) -> list[float]:
    result: list[float] = []
    for index in range(len(values)):
        if index == 0:
            velocity = values[1] - values[0]
        elif index == len(values) - 1:
            velocity = values[-1] - values[-2]
        else:
            velocity = (values[index + 1] - values[index - 1]) * 0.5
        result.append(velocity)
    return result


def build_rows(values: list[float]) -> list[tuple[int, datetime, float, float, float]]:
    minimum = min(values)
    maximum = max(values)
    span = maximum - minimum
    if span <= 0.0:
        raise ValueError("NOAA tide series has no height variation")
    velocities = source_velocity(values)
    max_velocity = max(abs(value) for value in velocities)
    if max_velocity <= 0.0:
        raise ValueError("NOAA tide series has no velocity variation")
    result: list[tuple[int, datetime, float, float, float]] = []
    for frame in range(SAMPLE_COUNT):
        position = float(frame) * float(len(values)) / float(SAMPLE_COUNT)
        height = linear_sample(values, position)
        velocity = linear_sample(velocities, position)
        timestamp = START + timedelta(hours=position)
        result.append(
            (
                frame,
                timestamp,
                height,
                (height - minimum) / span,
                max(-1.0, min(1.0, velocity / max_velocity)),
            )
        )
    return result


def write_output(path: Path, rows: list[tuple[int, datetime, float, float, float]]) -> None:
    lines = [
        f"# station={STATION_ID}",
        f"# station_name={STATION_NAME.replace(' ', '_')}",
        "# product=NOAA_CO-OPS_hourly_tide_predictions",
        "# datum=MLLW units=metric time_zone=GMT",
        f"# window={START.date().isoformat()}..{(END_EXCLUSIVE - timedelta(days=1)).date().isoformat()}",
        f"# source_url={source_url()}",
        "frame\ttimestamp_utc\twater_level_m\tnormalized_height\tnormalized_velocity",
    ]
    for frame, timestamp, height, normalized_height, normalized_velocity in rows:
        lines.append(
            f"{frame}\t{timestamp.strftime('%Y-%m-%dT%H:%M:%SZ')}\t"
            f"{height:.6f}\t{normalized_height:.6f}\t{normalized_velocity:.6f}"
        )
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input-json", type=Path)
    parser.add_argument(
        "--output",
        type=Path,
        default=Path(__file__).with_name("sf_bay_9414290_tide_720.txt"),
    )
    parser.add_argument(
        "--raw-output",
        type=Path,
        default=Path(__file__).with_name("raw")
        / "noaa_9414290_predictions_2025_2026.json",
    )
    args = parser.parse_args()
    payload = load_payload(args.input_json)
    values = validated_hourly_values(payload)
    rows = build_rows(values)
    if len(rows) != SAMPLE_COUNT:
        raise AssertionError(f"built {len(rows)} rows, expected {SAMPLE_COUNT}")
    write_output(args.output, rows)
    args.raw_output.parent.mkdir(parents=True, exist_ok=True)
    args.raw_output.write_text(
        json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    print(
        f"wrote {len(rows)} samples to {args.output}; "
        f"height={min(values):.3f}..{max(values):.3f} m MLLW"
    )


if __name__ == "__main__":
    main()
