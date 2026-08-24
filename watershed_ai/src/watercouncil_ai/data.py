"""Load the installation's 720-point atmospheric-input and temperature year."""

from __future__ import annotations

import csv
import math
import re
from dataclasses import dataclass
from datetime import datetime, timedelta
from pathlib import Path

from .schemas import BasinObservation, SCREEN_IDS, Season, StageObservation


MODEL_START = datetime(2025, 7, 1)
MODEL_SAMPLE_COUNT = 720
MODEL_YEAR_DAYS = 365.0
TRAILING_AVERAGE_DAYS = 30.0
TRAILING_SAMPLE_COUNT = round(MODEL_SAMPLE_COUNT * TRAILING_AVERAGE_DAYS / MODEL_YEAR_DAYS)
MINIMUM_INPUT_RATE = 0.02
MORNING_FOG_START_MINUTE = 3 * 60
MORNING_FOG_END_MINUTE = 10 * 60
MORNING_FOG_PEAK_MULTIPLIER = math.pi * 24.0 / (2.0 * 7.0)


@dataclass(frozen=True)
class StageDataSpec:
    display_name: str
    input_file: str
    temperature_column: str | None
    quality_flags: tuple[str, ...]


STAGE_DATA: dict[str, StageDataSpec] = {
    "mount_shasta": StageDataSpec(
        "Mount Shasta", "shasta_720.txt", "shasta_keswick_release_temp_c",
        ("POINT_STATION_PROXY", "FLOW_TEMP_LOCATION_MISMATCH", "SPECULATIVE_BASIN_MODEL"),
    ),
    "mccloud_pit": StageDataSpec(
        "McCloud-Pit Rivers", "mccloud_720.txt", "mccloud_above_shasta_lake_temp_c",
        ("POINT_STATION_PROXY", "PIT_NOT_REPRESENTED", "SPECULATIVE_BASIN_MODEL"),
    ),
    "cottonwood_creek": StageDataSpec(
        "Cottonwood Creek", "cottonwood_720.txt", None,
        ("POINT_STATION_PROXY", "NO_TEMPERATURE", "SPECULATIVE_BASIN_MODEL"),
    ),
    "mill_creek": StageDataSpec(
        "Mill Creek", "mill_creek_720.txt", "mill_creek_temp_c",
        ("POINT_STATION_PROXY", "PROVISIONAL_TEMPERATURE", "SPECULATIVE_BASIN_MODEL"),
    ),
    "feather_river": StageDataSpec(
        "Feather River", "feather_720.txt", "feather_below_thermalito_temp_c",
        ("POINT_STATION_PROXY", "PRIOR_YEAR_TEMPERATURE", "SPECULATIVE_BASIN_MODEL"),
    ),
    "american_river": StageDataSpec(
        "American River", "american_720.txt", "american_fair_oaks_temp_c",
        ("POINT_STATION_PROXY", "PROVISIONAL_TEMPERATURE", "SPECULATIVE_BASIN_MODEL"),
    ),
    "delta": StageDataSpec(
        "Delta", "delta_720.txt", "delta_freeport_temp_c",
        ("CONCEPTUAL_WEIGHTED_AGGREGATE", "PROVISIONAL_TEMPERATURE", "SPECULATIVE_BASIN_MODEL"),
    ),
}

DATA_RELATIVE_PATH = Path("godot_experiments/flow/data/water_pipeline")
FALLBACK_DATA_RELATIVE_PATH = Path("flow/data/water_pipeline")
TEMPERATURE_FILE = "water_temperature_all_rivers_720.txt"


def _data_directory(project_root: Path) -> Path:
    root = project_root.resolve()
    primary = root / DATA_RELATIVE_PATH
    return primary if primary.is_dir() else root / FALLBACK_DATA_RELATIVE_PATH


def _read_input_file(path: Path) -> tuple[list[dict[str, str]], float]:
    comments: list[str] = []
    data_lines: list[str] = []
    with path.open("r", encoding="utf-8", newline="") as handle:
        for line in handle:
            if line.startswith("#"):
                comments.append(line)
            else:
                data_lines.append(line)
    rows = list(csv.DictReader(data_lines, delimiter="\t"))
    if len(rows) != MODEL_SAMPLE_COUNT or [int(row["frame"]) for row in rows] != list(range(MODEL_SAMPLE_COUNT)):
        raise ValueError(f"{path} must contain contiguous frames 0..719")
    header = " ".join(comments)
    match = re.search(r"fog_baseline_norm=([0-9.]+)", header)
    if match is None:
        raise ValueError(f"{path} must declare fog_baseline_norm")
    return rows, float(match.group(1))


def _read_temperature_file(path: Path) -> list[dict[str, str]]:
    with path.open("r", encoding="utf-8", newline="") as handle:
        rows = [line for line in handle if not line.startswith("#")]
    result = list(csv.DictReader(rows))
    if len(result) != MODEL_SAMPLE_COUNT or [int(row["frame"]) for row in result] != list(range(MODEL_SAMPLE_COUNT)):
        raise ValueError(f"{path} must contain contiguous frames 0..719")
    return result


def _interpolate(first: float, second: float, fraction: float) -> float:
    return first + (second - first) * fraction


def _trailing_average(values: list[float], row_index: int) -> float:
    return sum(values[(row_index - offset) % len(values)] for offset in range(TRAILING_SAMPLE_COUNT)) / TRAILING_SAMPLE_COUNT


def _minute_of_day(model_time: datetime) -> int:
    return model_time.hour * 60 + model_time.minute


def _morning_fog_multiplier(minute_of_day: int) -> float:
    if minute_of_day < MORNING_FOG_START_MINUTE or minute_of_day > MORNING_FOG_END_MINUTE:
        return 0.0
    progress = (minute_of_day - MORNING_FOG_START_MINUTE) / (MORNING_FOG_END_MINUTE - MORNING_FOG_START_MINUTE)
    return math.sin(progress * math.pi) * MORNING_FOG_PEAK_MULTIPLIER


def _displayed_input_rate(buffered_rate: float, fog_baseline: float, minute_of_day: int) -> float:
    fog_adjustment = fog_baseline * (_morning_fog_multiplier(minute_of_day) - 1.0)
    return max(MINIMUM_INPUT_RATE, min(buffered_rate + fog_adjustment, 1.0))


def _season(model_time: datetime) -> Season:
    if model_time.month in (12, 1, 2):
        return "winter"
    if model_time.month in (3, 4, 5):
        return "spring"
    if model_time.month in (6, 7, 8, 9):
        return "summer"
    return "fall"


def _reservoir_cycle(buffered_rates: list[float]) -> tuple[list[float], list[float]]:
    """Conceptual cyclic spring storage and summer release for the art model."""
    storage = 0.35
    storage_rows = [0.0] * MODEL_SAMPLE_COUNT
    release_rows = [0.0] * MODEL_SAMPLE_COUNT
    # Iterate several model years so July carryover is not an arbitrary cold start.
    for cycle in range(4):
        for index, rate in enumerate(buffered_rates):
            month = (MODEL_START + timedelta(days=index * MODEL_YEAR_DAYS / MODEL_SAMPLE_COUNT)).month
            release = 0.0
            if month in (2, 3, 4, 5):
                storage = min(1.0, storage + max(rate - 0.08, 0.0) * 0.080)
            elif month in (6, 7, 8, 9):
                requested = 0.03 + max(0.22 - rate, 0.0) * 0.55
                release = min(requested, storage * 0.055)
                storage = max(0.0, storage - release * 0.060)
            else:
                storage = max(0.0, storage - 0.00035)
            if cycle == 3:
                storage_rows[index] = storage
                release_rows[index] = min(release, 1.0)
    return storage_rows, release_rows


def load_observation(project_root: Path, frame_index: int, frame_fraction: float = 0.0) -> BasinObservation:
    """Return the exact seasonal input moment used by the 720-sample installation."""
    if frame_index < 0 or frame_index >= MODEL_SAMPLE_COUNT:
        raise ValueError("frame_index must be in 0..719")
    if frame_fraction < 0.0 or frame_fraction >= 1.0:
        raise ValueError("frame_fraction must be in [0, 1)")
    data_dir = _data_directory(project_root)
    temperature_rows = _read_temperature_file(data_dir / TEMPERATURE_FILE)
    next_index = (frame_index + 1) % MODEL_SAMPLE_COUNT
    model_time = MODEL_START + timedelta(minutes=(frame_index + frame_fraction) * 730.0)
    stages: list[StageObservation] = []
    for screen_id in SCREEN_IDS:
        spec = STAGE_DATA[screen_id]
        rows, fog_baseline = _read_input_file(data_dir / spec.input_file)
        normalized = [max(0.0, min(float(row["norm"]), 1.0)) for row in rows]
        buffered = [_trailing_average(normalized, index) for index in range(MODEL_SAMPLE_COUNT)]
        storage, release = _reservoir_cycle(buffered)
        raw_value = _interpolate(float(rows[frame_index]["input_mm_day"]), float(rows[next_index]["input_mm_day"]), frame_fraction)
        buffered_rate = _interpolate(buffered[frame_index], buffered[next_index], frame_fraction)
        displayed_rate = _displayed_input_rate(buffered_rate, fog_baseline, _minute_of_day(model_time))
        temperature_c: float | None = None
        if spec.temperature_column:
            temperature_c = _interpolate(
                float(temperature_rows[frame_index][spec.temperature_column]),
                float(temperature_rows[next_index][spec.temperature_column]),
                frame_fraction,
            )
        stages.append(StageObservation(
            screen_id=screen_id,
            display_name=spec.display_name,
            frame_index=frame_index,
            atmospheric_input_mm_day=max(raw_value, 0.0),
            atmospheric_input_0_1=displayed_rate,
            trailing_30_day_input_0_1=max(0.0, min(buffered_rate, 1.0)),
            fog_baseline_0_1=fog_baseline,
            reservoir_storage_0_1=_interpolate(storage[frame_index], storage[next_index], frame_fraction),
            reservoir_release_0_1=_interpolate(release[frame_index], release[next_index], frame_fraction),
            temperature_c=temperature_c,
            high_variation=rows[frame_index]["high_variation"] == "1" or rows[next_index]["high_variation"] == "1",
            quality_flags=spec.quality_flags,
        ))
    return BasinObservation(
        frame_index=frame_index,
        frame_fraction=frame_fraction,
        model_time_pacific_local=model_time.isoformat(timespec="minutes"),
        season=_season(model_time),
        stages=tuple(stages),
    )
