"""Deterministic seasonal policy between model priorities and Godot state."""

from __future__ import annotations

import hashlib
import json
import math

from .schemas import (
    BasinObservation,
    ModelRunReport,
    ProposedBasinPolicy,
    SCREEN_IDS,
    Season,
    ValidatedBasinDecision,
    ValidatedRiverDecision,
    WaterAllocationShares,
    WatershedVisualState,
)


BASE_SALMON_FLOOR = 0.35
MAX_SALMON_FLOOR = 0.61
FLOODPLAIN_FLOOR = 0.08
WET_SEASON_FLOODPLAIN_FLOOR = 0.15
MIN_SUSTAINABLE_EXTRACTION = 0.05
MAX_SUSTAINABLE_EXTRACTION = 0.50
DRY_SUPPLY_RATE = 0.03
ABUNDANT_SUPPLY_RATE = 0.60
COOL_WATER_ALLOCATION_C = 8.0
WARM_WATER_ALLOCATION_C = 24.0
CITY_EXTRACTION_FLOOR_RATIO = 0.20
AGRICULTURE_EXTRACTION_FLOOR_RATIO = 0.15
SUMMER_AGRICULTURE_EXTRACTION_FLOOR_RATIO = 0.25
DATA_CENTER_EXTRACTION_FLOOR_RATIO = 0.15
WINTER_DATA_CENTER_EXTRACTION_FLOOR_RATIO = 0.25
TEMPERATURE_STRESS_BEGINS_C = 15.0
TEMPERATURE_STRESS_FULL_C = 23.0
MAX_THERMAL_FLOOR_INCREMENT = 0.15
SUPPLY_SCARCITY_THRESHOLD = 0.25
MAX_SCARCITY_FLOOR_INCREMENT = 0.15

SEASONAL_MULTIPLIERS: dict[Season, tuple[float, float, float, float, float]] = {
    # salmon, floodplain, agriculture, data centers, city
    "winter": (1.10, 1.35, 0.45, 2.40, 0.90),
    "spring": (1.20, 1.80, 0.75, 1.25, 0.90),
    "summer": (1.35, 0.60, 2.00, 0.75, 1.00),
    "fall": (1.25, 0.80, 1.15, 0.90, 1.00),
}


def _clamp(value: float, minimum: float = 0.0, maximum: float = 1.0) -> float:
    if not math.isfinite(value):
        raise ValueError("policy values must be finite")
    return max(minimum, min(value, maximum))


def _sustainable_extraction_fraction(available_supply: float) -> float:
    """Map each screen's available water to a smooth, bounded withdrawal."""
    progress = _clamp(
        (available_supply - DRY_SUPPLY_RATE)
        / (ABUNDANT_SUPPLY_RATE - DRY_SUPPLY_RATE)
    )
    smooth_progress = progress * progress * (3.0 - 2.0 * progress)
    return (
        MIN_SUSTAINABLE_EXTRACTION
        + (MAX_SUSTAINABLE_EXTRACTION - MIN_SUSTAINABLE_EXTRACTION)
        * smooth_progress
    )


def _warm_water_fraction(temperature: float | None) -> float:
    if temperature is None:
        return 0.5
    return _clamp(
        (temperature - COOL_WATER_ALLOCATION_C)
        / (WARM_WATER_ALLOCATION_C - COOL_WATER_ALLOCATION_C)
    )


def _allocation_floors(
    season: Season,
    available_supply: float,
    temperature: float | None,
) -> tuple[tuple[float, ...], float, float, float, float]:
    scarcity_stress = _clamp((SUPPLY_SCARCITY_THRESHOLD - available_supply) / SUPPLY_SCARCITY_THRESHOLD)
    thermal_stress = 0.0 if temperature is None else _clamp(
        (temperature - TEMPERATURE_STRESS_BEGINS_C) / (TEMPERATURE_STRESS_FULL_C - TEMPERATURE_STRESS_BEGINS_C)
    )
    floodplain_floor = WET_SEASON_FLOODPLAIN_FLOOR if season in ("winter", "spring") else FLOODPLAIN_FLOOR
    extraction_target = _sustainable_extraction_fraction(available_supply)
    salmon_floor = _clamp(
        BASE_SALMON_FLOOR
        + scarcity_stress * MAX_SCARCITY_FLOOR_INCREMENT
        + thermal_stress * MAX_THERMAL_FLOOR_INCREMENT,
        BASE_SALMON_FLOOR,
        min(MAX_SALMON_FLOOR, 1.0 - floodplain_floor),
    )
    extraction_target = min(
        extraction_target,
        max(1.0 - salmon_floor - floodplain_floor, 0.0),
    )
    agriculture_ratio = (
        SUMMER_AGRICULTURE_EXTRACTION_FLOOR_RATIO
        if season == "summer"
        else AGRICULTURE_EXTRACTION_FLOOR_RATIO
    )
    data_center_ratio = (
        WINTER_DATA_CENTER_EXTRACTION_FLOOR_RATIO
        if season == "winter"
        else DATA_CENTER_EXTRACTION_FLOOR_RATIO
    )
    return (
        (
            salmon_floor,
            floodplain_floor,
            extraction_target * agriculture_ratio,
            extraction_target * data_center_ratio,
            extraction_target * CITY_EXTRACTION_FLOOR_RATIO,
        ),
        scarcity_stress,
        thermal_stress,
        salmon_floor,
        extraction_target,
    )


def _shares_from_priorities(
    season: Season,
    floors: tuple[float, ...],
    priorities: tuple[float, ...],
    reservoir_storage: float,
    reservoir_release: float,
    extraction_target: float,
    temperature: float | None,
) -> WaterAllocationShares:
    multipliers = list(SEASONAL_MULTIPLIERS[season])
    if season == "summer":
        # Spring storage specifically strengthens food production in the dry season.
        multipliers[2] *= 1.0 + reservoir_storage * 1.5 + reservoir_release * 4.0
    warm_water = _warm_water_fraction(temperature)
    # Within the extraction budget, cool water favors compute and warm water
    # favors fields. Missing temperature is neutral rather than invented.
    multipliers[2] *= 0.65 + warm_water * 1.35
    multipliers[3] *= 2.00 - warm_water * 1.35
    weighted = [_clamp(value) * multipliers[index] for index, value in enumerate(priorities)]
    ecology_budget = 1.0 - extraction_target
    ecology_remaining = ecology_budget - floors[0] - floors[1]
    productive_remaining = extraction_target - sum(floors[2:])
    if ecology_remaining < -1e-9 or productive_remaining < -1e-9:
        raise ValueError("deterministic water floors exceed their budgets")
    ecology_weight_sum = sum(weighted[:2])
    ecology_weights = (
        [value / ecology_weight_sum for value in weighted[:2]]
        if ecology_weight_sum > 1e-12
        else [0.5, 0.5]
    )
    productive_weight_sum = sum(weighted[2:])
    productive_weights = (
        [value / productive_weight_sum for value in weighted[2:]]
        if productive_weight_sum > 1e-12
        else [1.0 / 3.0] * 3
    )
    values = [
        floors[0] + ecology_remaining * ecology_weights[0],
        floors[1] + ecology_remaining * ecology_weights[1],
        floors[2] + productive_remaining * productive_weights[0],
        floors[3] + productive_remaining * productive_weights[1],
        floors[4] + productive_remaining * productive_weights[2],
    ]
    values[1] += 1.0 - sum(values)  # residue stays in-system as floodplain water
    return WaterAllocationShares(
        salmon=values[0],
        floodplain=values[1],
        agriculture=values[2],
        data_centers=values[3],
        city=values[4],
    )


def _state_payload_without_hash(
    decision_id: str,
    frame_index: int,
    atmospheric_input: float,
    reservoir_release: float,
    reservoir_storage: float,
    shares: WaterAllocationShares,
) -> dict[str, object]:
    available_supply = _clamp(atmospheric_input + reservoir_release)
    extraction = _clamp(
        shares.extraction_fraction,
        maximum=MAX_SUSTAINABLE_EXTRACTION,
    )
    remaining = _clamp(available_supply * (1.0 - extraction))
    return {
        "schema_version": 2,
        "decision_id": decision_id,
        "frame_index": frame_index,
        "atmospheric_input_rate": _clamp(atmospheric_input),
        "reservoir_release_rate": _clamp(reservoir_release),
        "available_supply_rate": available_supply,
        "extraction_fraction": extraction,
        "remaining_rate": remaining,
        "salmon_fraction": shares.salmon,
        "floodplain_fraction": shares.floodplain,
        "agriculture_fraction": shares.agriculture,
        "data_center_fraction": shares.data_centers,
        "city_fraction": shares.city,
        "reservoir_storage_fraction": _clamp(reservoir_storage),
        "hydropower_fraction": 0.0,
        "water_project_fraction": 0.0,
    }


HASH_FIELDS = (
    "atmospheric_input_rate", "reservoir_release_rate", "available_supply_rate",
    "extraction_fraction", "remaining_rate", "salmon_fraction",
    "floodplain_fraction", "agriculture_fraction", "data_center_fraction",
    "city_fraction", "reservoir_storage_fraction", "hydropower_fraction",
    "water_project_fraction",
)


def _visual_state_hash(payload: dict[str, object]) -> str:
    """Match Godot's language-neutral fixed-precision visual-state hash."""
    parts = [f"schema_version={int(payload['schema_version'])}"]
    parts.extend(f"{field}={float(payload[field]):.9f}" for field in HASH_FIELDS)
    return hashlib.sha256("\n".join(parts).encode()).hexdigest()


def validate_policy(
    observation: BasinObservation,
    proposal: ProposedBasinPolicy,
    model_run: ModelRunReport | None = None,
) -> ValidatedBasinDecision:
    """Project one model proposal into an exact, bounded seasonal water budget."""
    proposals = {river.screen_id: river for river in proposal.rivers}
    if set(proposals) != set(SCREEN_IDS):
        raise ValueError("proposal does not cover the canonical screens")
    rows: list[tuple[object, ...]] = []
    canonical_seed: list[dict[str, object]] = []
    for stage in observation.stages:
        proposed = proposals[stage.screen_id]
        available = _clamp(stage.atmospheric_input_0_1 + stage.reservoir_release_0_1)
        (
            floors,
            scarcity_stress,
            thermal_stress,
            salmon_floor,
            extraction_target,
        ) = _allocation_floors(
            observation.season, available, stage.temperature_c
        )
        shares = _shares_from_priorities(
            observation.season,
            floors,
            (
                proposed.salmon_priority,
                proposed.floodplain_priority,
                proposed.agriculture_priority,
                proposed.data_center_priority,
                proposed.city_priority,
            ),
            stage.reservoir_storage_0_1,
            stage.reservoir_release_0_1,
            extraction_target,
            stage.temperature_c,
        )
        rows.append((stage, proposed, shares, floors, scarcity_stress, thermal_stress, salmon_floor))
        canonical_seed.append({
            "screen_id": stage.screen_id,
            "shares": shares.model_dump(),
            "input": stage.atmospheric_input_0_1,
            "release": stage.reservoir_release_0_1,
            "storage": stage.reservoir_storage_0_1,
        })
    basin_seed = {
        "schema_version": 2,
        "frame": observation.frame_index,
        "season": observation.season,
        "policy_summary": proposal.policy_summary,
        "rivers": canonical_seed,
    }
    decision_id = hashlib.sha256(
        json.dumps(basin_seed, sort_keys=True, separators=(",", ":")).encode()
    ).hexdigest()[:16]
    rivers: list[ValidatedRiverDecision] = []
    for stage, proposed, shares, floors, scarcity_stress, thermal_stress, salmon_floor in rows:
        state_payload = _state_payload_without_hash(
            decision_id,
            observation.frame_index,
            stage.atmospheric_input_0_1,
            stage.reservoir_release_0_1,
            stage.reservoir_storage_0_1,
            shares,
        )
        visual_state = WatershedVisualState(
            **state_payload,
            state_hash=_visual_state_hash(state_payload),
        )
        rivers.append(ValidatedRiverDecision(
            screen_id=stage.screen_id,
            frame_index=observation.frame_index,
            season=observation.season,
            shares=shares,
            salmon_floor=salmon_floor,
            floodplain_floor=floors[1],
            data_center_floor=floors[3],
            thermal_stress=thermal_stress,
            scarcity_stress=scarcity_stress,
            confidence=proposed.confidence,
            rationale=proposed.rationale,
            visual_state=visual_state,
        ))
    return ValidatedBasinDecision(
        decision_id=decision_id,
        frame_index=observation.frame_index,
        season=observation.season,
        policy_summary=proposal.policy_summary,
        rivers=tuple(rivers),
        model_run=model_run,
    )
