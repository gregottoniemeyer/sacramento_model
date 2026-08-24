#!/usr/bin/env python3
"""Build the seven 720-sample Water Council basin-input series.

The source file is an archived NOAA/NCEI Daily Summaries response for the
2025-07-01 through 2026-06-30 water year.  The model delays frozen
precipitation in a snow store and releases it as melt, so snowfall is never
counted once when it lands and a second time when it melts.

The five-column output remains compatible with GPUFlowStage2D's legacy text
reader.  Its second column is now local water arrival in mm/day, not CFS.
"""

from __future__ import annotations

import json
import math
from dataclasses import dataclass
from pathlib import Path

import numpy as np
import pandas as pd


WATER_YEAR_START = "2025-07-01"
WATER_YEAR_END = "2026-06-30"
TARGET_SAMPLE_COUNT = 720
HATCHED_MODEL_VERSION = "basin-input/2"

# A small, explicit occult-precipitation baseline. USGS field observations in
# the northern California redwood region measured about 3 mm of fog drip from
# July 4 through September 15, 1970 (~0.041 mm/day). We round that upward to a
# still-conservative 0.05 mm/day conceptual baseline and render its equivalent
# volume as a mean-preserving 03:00-10:00 pulse in Godot.
FOG_BASELINE_MM_DAY = 0.05
FOG_WINDOW_START_MINUTE = 3 * 60
FOG_WINDOW_END_MINUTE = 10 * 60
FOG_OBSERVATION_SOURCE = "https://pubs.usgs.gov/of/1975/0568/report.pdf"

HERE = Path(__file__).resolve().parent
RAW_PATH = HERE / "raw" / "noaa_daily_2025_2026.json"
DAILY_OUTPUT_PATH = HERE / "basin_input_daily_2025_2026.csv"
SAMPLED_OUTPUT_PATH = HERE / "basin_input_all_stages_720.csv"
WATER_PIPELINE_PATH = HERE.parent / "water_pipeline"


@dataclass(frozen=True)
class StageStation:
    stage_id: str
    display_name: str
    station_id: str
    station_name: str
    latitude: float
    longitude: float
    elevation_m: float
    role: str


STATIONS = (
    StageStation(
        "shasta",
        "Mount Shasta",
        "USC00045983",
        "MOUNT SHASTA, CA US",
        41.3217,
        -122.3172,
        1101.2,
        "Upper Sacramento precipitation and snow proxy",
    ),
    StageStation(
        "mccloud",
        "McCloud-Pit Rivers",
        "USC00045449",
        "MCCLOUD, CA US",
        41.2517,
        -122.1383,
        985.4,
        "McCloud-Pit precipitation and snow proxy",
    ),
    StageStation(
        "cottonwood",
        "Cottonwood Creek",
        "USW00024216",
        "RED BLUFF MUNICIPAL AIRPORT, CA US",
        40.1519,
        -122.2547,
        107.9,
        "Lower Cottonwood watershed precipitation proxy",
    ),
    StageStation(
        "mill_creek",
        "Mill Creek",
        "USC00045679",
        "MINERAL, CA US",
        40.3458,
        -121.6092,
        1485.9,
        "Upper Mill Creek/Lassen precipitation and snow proxy",
    ),
    StageStation(
        "feather",
        "Feather River",
        "USC00047195",
        "QUINCY, CA US",
        39.9367,
        -120.9475,
        1042.4,
        "Upper Feather precipitation and snow proxy",
    ),
    StageStation(
        "american",
        "American River",
        "USW00023225",
        "BLUE CANYON NYACK AIRPORT, CA US",
        39.2761,
        -120.7092,
        1611.2,
        "Upper American precipitation and temperature snow proxy",
    ),
    StageStation(
        "delta",
        "Sacramento-San Joaquin Delta",
        "USW00023237",
        "STOCKTON AIRPORT, CA US",
        37.8900,
        -121.2264,
        8.2,
        "Local Delta precipitation proxy and basin aggregate component",
    ),
)

# Conceptual shares of water arriving at the Delta.  They are deliberately
# explicit: this is a speculative installation model, not a calibrated DWR
# accounting product.  The weights sum to one and preserve the seven observed
# seasonal signals in the Delta aggregate.
DELTA_WEIGHTS = {
    "shasta": 0.24,
    "mccloud": 0.18,
    "cottonwood": 0.10,
    "mill_creek": 0.06,
    "feather": 0.23,
    "american": 0.14,
    "delta": 0.05,
}


def load_noaa_rows(path: Path = RAW_PATH) -> pd.DataFrame:
    """Load the archived NCEI response and coerce measurement columns."""
    records = json.loads(path.read_text(encoding="utf-8"))
    frame = pd.DataFrame(records)
    frame["DATE"] = pd.to_datetime(frame["DATE"])
    for column in (
        "PRCP",
        "SNOW",
        "SNWD",
        "TMAX",
        "TMIN",
        "TOBS",
        "DAPR",
        "MDPR",
    ):
        if column not in frame:
            frame[column] = np.nan
        frame[column] = pd.to_numeric(frame[column], errors="coerce")
    return frame


def _daily_station_frame(rows: pd.DataFrame, station: StageStation) -> pd.DataFrame:
    index = pd.date_range(WATER_YEAR_START, WATER_YEAR_END, freq="D")
    observed = (
        rows.loc[rows["STATION"] == station.station_id]
        .sort_values("DATE")
        .drop_duplicates("DATE", keep="last")
        .set_index("DATE")
    )
    daily = observed.reindex(index)
    daily.index.name = "date"
    daily["observed"] = daily["STATION"].notna()

    # NOAA flags accumulated reports with MDPR (multiday precipitation) and
    # DAPR (number of days).  Spread those totals back across their reporting
    # interval before treating the remaining missing precipitation as zero.
    precipitation = daily["PRCP"].copy()
    for report_date, row in daily.loc[daily["MDPR"].notna()].iterrows():
        day_count = max(int(row["DAPR"]) if pd.notna(row["DAPR"]) else 1, 1)
        interval = pd.date_range(
            max(index[0], report_date - pd.Timedelta(days=day_count - 1)),
            report_date,
            freq="D",
        )
        precipitation.loc[interval] = float(row["MDPR"]) / float(len(interval))
    daily["precip_mm"] = precipitation.fillna(0.0).clip(lower=0.0)

    daily["snowfall_mm"] = daily["SNOW"].fillna(0.0).clip(lower=0.0)
    daily["snow_depth_mm"] = daily["SNWD"].interpolate(limit=7).fillna(0.0).clip(lower=0.0)
    daily["tmax_c"] = daily["TMAX"].interpolate(limit_direction="both")
    daily["tmin_c"] = daily["TMIN"].interpolate(limit_direction="both")
    daily["tmean_c"] = (daily["tmax_c"] + daily["tmin_c"]) * 0.5

    # Tmin is a defensible first-order dew-point proxy when measured humidity is
    # absent. The small capped term represents dew/humidity condensation. Fog is
    # accounted separately below so its daily volume can be rendered at dawn.
    dewpoint = daily["tmin_c"].fillna(daily["tmean_c"])
    mean_temp = daily["tmean_c"].fillna(dewpoint)
    numerator = np.exp(17.625 * dewpoint / (243.04 + dewpoint))
    denominator = np.exp(17.625 * mean_temp / (243.04 + mean_temp))
    daily["estimated_relative_humidity_pct"] = (100.0 * numerator / denominator).clip(0.0, 100.0)
    daily["humidity_input_mm"] = (
        (daily["estimated_relative_humidity_pct"] - 80.0) / 20.0
    ).clip(0.0, 1.0) * 0.10

    snow_store = 0.0
    prior_depth = 0.0
    rain_values: list[float] = []
    snow_values: list[float] = []
    melt_values: list[float] = []
    store_values: list[float] = []
    for row in daily.itertuples():
        precip = float(row.precip_mm)
        tmean = float(row.tmean_c) if math.isfinite(float(row.tmean_c)) else 5.0
        measured_snowfall = float(row.snowfall_mm) > 0.0
        frozen_fraction = 1.0 if measured_snowfall or tmean <= 0.5 else 0.0
        snowfall_water = precip * frozen_fraction
        rainfall = precip - snowfall_water
        snow_store += snowfall_water

        depth_loss_water = max(prior_depth - float(row.snow_depth_mm), 0.0) * 0.25
        degree_day_melt = max(tmean - 1.0, 0.0) * 2.5
        snowmelt = min(snow_store, max(depth_loss_water, degree_day_melt))
        snow_store -= snowmelt
        prior_depth = float(row.snow_depth_mm)

        rain_values.append(rainfall)
        snow_values.append(snowfall_water)
        melt_values.append(snowmelt)
        store_values.append(snow_store)

    daily["rain_input_mm"] = rain_values
    daily["snow_storage_input_mm"] = snow_values
    daily["snowmelt_input_mm"] = melt_values
    daily["snow_store_mm"] = store_values
    daily["local_input_mm"] = (
        daily["rain_input_mm"]
        + daily["snowmelt_input_mm"]
        + daily["humidity_input_mm"]
    )

    # A causal 21-day unit-sum kernel approximates travel through soil, small
    # tributaries, and snow-fed channels while preserving annual water volume.
    kernel = np.exp(-np.arange(21, dtype=float) / 5.0)
    kernel /= kernel.sum()
    transported_input = np.convolve(
        daily["local_input_mm"].to_numpy(), kernel, mode="full"
    )[: len(daily)]
    daily["fog_input_mm"] = FOG_BASELINE_MM_DAY
    daily["basin_arrival_mm_day"] = transported_input + daily["fog_input_mm"]
    scale = float(daily["basin_arrival_mm_day"].quantile(0.99))
    if not math.isfinite(scale) or scale <= 0.0:
        scale = 1.0
    daily["normalization_scale_mm_day"] = scale
    daily["fog_baseline_norm"] = FOG_BASELINE_MM_DAY / scale
    daily["norm"] = (daily["basin_arrival_mm_day"] / scale).clip(0.0, 1.0)
    daily["stage_id"] = station.stage_id
    daily["station_id"] = station.station_id
    daily["station_name"] = station.station_name
    return daily.reset_index()


def build_daily_inputs(rows: pd.DataFrame | None = None) -> pd.DataFrame:
    """Return one daily record per stage for the complete model year."""
    source = load_noaa_rows() if rows is None else rows
    stage_frames = [_daily_station_frame(source, station) for station in STATIONS]
    daily = pd.concat(stage_frames, ignore_index=True)

    # Delta receives the conceptual, weighted basin aggregate while its local
    # Stockton measurements remain present in all component columns.
    pivot_norm = daily.pivot(index="date", columns="stage_id", values="norm")
    pivot_raw = daily.pivot(
        index="date", columns="stage_id", values="basin_arrival_mm_day"
    )
    aggregate_norm = sum(pivot_norm[key] * weight for key, weight in DELTA_WEIGHTS.items())
    aggregate_raw = sum(pivot_raw[key] * weight for key, weight in DELTA_WEIGHTS.items())
    pivot_fog_norm = daily.pivot(
        index="date", columns="stage_id", values="fog_baseline_norm"
    )
    aggregate_fog_norm = sum(
        pivot_fog_norm[key] * weight for key, weight in DELTA_WEIGHTS.items()
    )
    delta_mask = daily["stage_id"] == "delta"
    daily.loc[delta_mask, "local_station_norm"] = daily.loc[delta_mask, "norm"].to_numpy()
    daily.loc[delta_mask, "local_station_arrival_mm_day"] = daily.loc[
        delta_mask, "basin_arrival_mm_day"
    ].to_numpy()
    daily.loc[delta_mask, "norm"] = aggregate_norm.to_numpy()
    daily.loc[delta_mask, "basin_arrival_mm_day"] = aggregate_raw.to_numpy()
    daily.loc[delta_mask, "fog_baseline_norm"] = aggregate_fog_norm.to_numpy()
    return daily


def _resample(values: pd.Series | np.ndarray, target_count: int = TARGET_SAMPLE_COUNT) -> np.ndarray:
    source = np.asarray(values, dtype=float)
    source_position = np.linspace(0.0, 1.0, len(source), endpoint=True)
    target_position = np.linspace(0.0, 1.0, target_count, endpoint=True)
    return np.interp(target_position, source_position, source)


def _variation_flags(values: np.ndarray, window: int = 10) -> tuple[np.ndarray, float]:
    diffs = np.concatenate(([0.0], np.abs(np.diff(values))))
    local = pd.Series(diffs).rolling(window, min_periods=1).mean().to_numpy()
    threshold = float(local.mean() + 2.0 * local.std(ddof=0))
    return local > threshold, threshold


def build_sampled_inputs(daily: pd.DataFrame) -> pd.DataFrame:
    sampled_frames = []
    for station in STATIONS:
        stage = daily.loc[daily["stage_id"] == station.stage_id].sort_values("date")
        raw_values = _resample(stage["basin_arrival_mm_day"])
        normalized = np.clip(_resample(stage["norm"]), 0.0, 1.0)
        fog_baseline_normalized = np.clip(
            _resample(stage["fog_baseline_norm"]), 0.0, 1.0
        )
        high_variation, threshold = _variation_flags(normalized)
        sampled_frames.append(
            pd.DataFrame(
                {
                    "stage_id": station.stage_id,
                    "frame": np.arange(TARGET_SAMPLE_COUNT, dtype=int),
                    "input_mm_day": raw_values,
                    "norm": normalized,
                    "fog_baseline_mm_day": FOG_BASELINE_MM_DAY,
                    "fog_baseline_norm": fog_baseline_normalized,
                    "scaled": normalized * 200.0,
                    "high_variation": high_variation.astype(int),
                    "variation_threshold": threshold,
                }
            )
        )
    return pd.concat(sampled_frames, ignore_index=True)


def write_runtime_files(sampled: pd.DataFrame) -> None:
    WATER_PIPELINE_PATH.mkdir(parents=True, exist_ok=True)
    station_by_id = {station.stage_id: station for station in STATIONS}
    for stage_id, stage in sampled.groupby("stage_id", sort=False):
        station = station_by_id[stage_id]
        threshold = float(stage["variation_threshold"].iloc[0])
        fog_baseline_norm = float(stage["fog_baseline_norm"].median())
        lines = [
            (
                f"# river={stage_id} model={HATCHED_MODEL_VERSION} "
                f"input=precipitation+snowmelt+humidity+fog rows={TARGET_SAMPLE_COUNT}"
            ),
            (
                f"# water_year=2025-07-01/2026-06-30 station={station.station_id} "
                f"station_name={station.station_name.replace(' ', '_')}"
            ),
            (
                f"# fog_baseline_mm_day={FOG_BASELINE_MM_DAY:.4f} "
                f"fog_baseline_norm={fog_baseline_norm:.8f} "
                f"fog_window_minutes={FOG_WINDOW_START_MINUTE}-{FOG_WINDOW_END_MINUTE} "
                f"fog_source={FOG_OBSERVATION_SOURCE}"
            ),
            "# units=input_mm_day norm=0..1 scaled=0..200",
            "frame\tinput_mm_day\tnorm\tscaled\thigh_variation",
        ]
        for row in stage.itertuples(index=False):
            lines.append(
                f"{row.frame}\t{row.input_mm_day:.4f}\t{row.norm:.6f}\t"
                f"{row.scaled:.4f}\t{row.high_variation}"
            )
        output = WATER_PIPELINE_PATH / f"{stage_id}_720.txt"
        output.write_text("\n".join(lines) + "\n", encoding="utf-8")


def validate_outputs(daily: pd.DataFrame, sampled: pd.DataFrame) -> None:
    expected_dates = pd.date_range(WATER_YEAR_START, WATER_YEAR_END, freq="D")
    assert len(expected_dates) == 365
    assert set(daily["stage_id"].unique()) == {station.stage_id for station in STATIONS}
    assert daily.groupby("stage_id").size().eq(365).all()
    assert sampled.groupby("stage_id").size().eq(TARGET_SAMPLE_COUNT).all()
    assert sampled["norm"].between(0.0, 1.0).all()
    assert math.isclose(sum(DELTA_WEIGHTS.values()), 1.0, abs_tol=1.0e-9)
    for station in STATIONS:
        output = WATER_PIPELINE_PATH / f"{station.stage_id}_720.txt"
        data_rows = [line for line in output.read_text().splitlines() if line[:1].isdigit()]
        assert len(data_rows) == TARGET_SAMPLE_COUNT, output


def build_all(write_outputs: bool = True) -> tuple[pd.DataFrame, pd.DataFrame]:
    daily = build_daily_inputs()
    sampled = build_sampled_inputs(daily)
    if write_outputs:
        daily.to_csv(DAILY_OUTPUT_PATH, index=False)
        sampled.to_csv(SAMPLED_OUTPUT_PATH, index=False)
        write_runtime_files(sampled)
        validate_outputs(daily, sampled)
    return daily, sampled


if __name__ == "__main__":
    daily_frame, sampled_frame = build_all(write_outputs=True)
    summary = (
        daily_frame.groupby(["stage_id", "station_id"], sort=False)
        .agg(
            observed_days=("observed", "sum"),
            annual_precip_mm=("precip_mm", "sum"),
            annual_melt_mm=("snowmelt_input_mm", "sum"),
            annual_fog_mm=("fog_input_mm", "sum"),
            peak_normalized_input=("norm", "max"),
        )
        .round(3)
    )
    print(summary.to_string())
    print(f"\nWrote 7 x {TARGET_SAMPLE_COUNT} runtime samples to {WATER_PIPELINE_PATH}")
