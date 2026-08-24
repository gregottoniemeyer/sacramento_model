"""Typed inputs and outputs for the seasonal Watershed art-model policy."""

from __future__ import annotations

from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, model_validator


ScreenId = Literal[
    "mount_shasta",
    "mccloud_pit",
    "cottonwood_creek",
    "mill_creek",
    "feather_river",
    "american_river",
    "delta",
]
Season = Literal["winter", "spring", "summer", "fall"]

SCREEN_IDS: tuple[str, ...] = (
    "mount_shasta", "mccloud_pit", "cottonwood_creek", "mill_creek",
    "feather_river", "american_river", "delta",
)


class StrictModel(BaseModel):
    model_config = ConfigDict(extra="forbid")


class StageObservation(StrictModel):
    screen_id: ScreenId
    display_name: str
    frame_index: int = Field(ge=0, le=719)
    atmospheric_input_mm_day: float = Field(ge=0.0)
    atmospheric_input_0_1: float = Field(ge=0.0, le=1.0)
    trailing_30_day_input_0_1: float = Field(ge=0.0, le=1.0)
    fog_baseline_0_1: float = Field(ge=0.0, le=1.0)
    reservoir_storage_0_1: float = Field(ge=0.0, le=1.0)
    reservoir_release_0_1: float = Field(ge=0.0, le=1.0)
    temperature_c: float | None = Field(default=None, ge=-2.0, le=40.0)
    high_variation: bool
    quality_flags: tuple[str, ...] = ()


class BasinObservation(StrictModel):
    schema_version: Literal[2] = 2
    frame_index: int = Field(ge=0, le=719)
    frame_fraction: float = Field(default=0.0, ge=0.0, lt=1.0)
    model_time_pacific_local: str
    season: Season
    stages: tuple[StageObservation, ...]
    purpose: Literal["ART_MODEL_ONLY"] = "ART_MODEL_ONLY"

    @model_validator(mode="after")
    def require_all_screens_once(self) -> "BasinObservation":
        screen_ids = [stage.screen_id for stage in self.stages]
        if tuple(screen_ids) != SCREEN_IDS:
            raise ValueError("stages must contain all seven canonical screens in order")
        if any(stage.frame_index != self.frame_index for stage in self.stages):
            raise ValueError("all stage observations must use the basin frame")
        return self


class ProposedRiverPriority(StrictModel):
    screen_id: ScreenId
    salmon_priority: float = Field(ge=0.0, le=1.0)
    floodplain_priority: float = Field(ge=0.0, le=1.0)
    agriculture_priority: float = Field(ge=0.0, le=1.0)
    data_center_priority: float = Field(ge=0.0, le=1.0)
    city_priority: float = Field(ge=0.0, le=1.0)
    confidence: float = Field(ge=0.0, le=1.0)
    rationale: str = Field(min_length=1, max_length=240)


class ProposedBasinPolicy(StrictModel):
    policy_summary: str = Field(min_length=1, max_length=500)
    rivers: tuple[ProposedRiverPriority, ...]

    @model_validator(mode="after")
    def require_all_screens_once(self) -> "ProposedBasinPolicy":
        screen_ids = [river.screen_id for river in self.rivers]
        if len(screen_ids) != len(set(screen_ids)):
            raise ValueError("proposal repeats a screen")
        if set(screen_ids) != set(SCREEN_IDS):
            raise ValueError("proposal must cover all seven screens")
        return self


class WaterAllocationShares(StrictModel):
    """Fractions of available water; the five values must total exactly one."""

    salmon: float = Field(ge=0.0, le=1.0)
    floodplain: float = Field(ge=0.0, le=1.0)
    agriculture: float = Field(ge=0.0, le=1.0)
    data_centers: float = Field(ge=0.0, le=1.0)
    city: float = Field(ge=0.0, le=1.0)

    @model_validator(mode="after")
    def require_unit_sum(self) -> "WaterAllocationShares":
        total = self.salmon + self.floodplain + self.agriculture + self.data_centers + self.city
        if abs(total - 1.0) > 1e-8:
            raise ValueError("water-allocation shares must sum to one")
        return self

    @property
    def extraction_fraction(self) -> float:
        return self.agriculture + self.data_centers + self.city


class WatershedVisualState(StrictModel):
    """Complete state accepted by Godot's exclusive watershed-ai/2 scope."""

    schema_version: Literal[2] = 2
    decision_id: str = Field(pattern=r"^[a-f0-9]{16}$")
    state_hash: str = Field(pattern=r"^[a-f0-9]{64}$")
    frame_index: int = Field(ge=0, le=719)
    atmospheric_input_rate: float = Field(ge=0.0, le=1.0)
    reservoir_release_rate: float = Field(ge=0.0, le=1.0)
    available_supply_rate: float = Field(ge=0.0, le=1.0)
    extraction_fraction: float = Field(ge=0.0, le=1.0)
    remaining_rate: float = Field(ge=0.0, le=1.0)
    salmon_fraction: float = Field(ge=0.0, le=1.0)
    floodplain_fraction: float = Field(ge=0.0, le=1.0)
    agriculture_fraction: float = Field(ge=0.0, le=1.0)
    data_center_fraction: float = Field(ge=0.0, le=1.0)
    city_fraction: float = Field(ge=0.0, le=1.0)
    reservoir_storage_fraction: float = Field(ge=0.0, le=1.0)
    hydropower_fraction: Literal[0.0] = 0.0
    water_project_fraction: Literal[0.0] = 0.0


class ModelRunReport(StrictModel):
    model: str
    requests: int = Field(ge=0)
    input_tokens: int = Field(ge=0)
    cached_input_tokens: int = Field(ge=0)
    cache_write_tokens: int = Field(ge=0)
    output_tokens: int = Field(ge=0)
    total_tokens: int = Field(ge=0)
    estimated_cost_usd: float = Field(ge=0.0)
    pricing_snapshot_date: str
    input_usd_per_million_tokens: float = Field(ge=0.0)
    cached_input_usd_per_million_tokens: float = Field(ge=0.0)
    cache_write_usd_per_million_tokens: float = Field(ge=0.0)
    output_usd_per_million_tokens: float = Field(ge=0.0)
    pricing_source: str


class ValidatedRiverDecision(StrictModel):
    screen_id: ScreenId
    frame_index: int = Field(ge=0, le=719)
    season: Season
    shares: WaterAllocationShares
    salmon_floor: float = Field(ge=0.0, le=1.0)
    floodplain_floor: float = Field(ge=0.0, le=1.0)
    data_center_floor: float = Field(ge=0.0, le=1.0)
    thermal_stress: float = Field(ge=0.0, le=1.0)
    scarcity_stress: float = Field(ge=0.0, le=1.0)
    confidence: float = Field(ge=0.0, le=1.0)
    rationale: str
    visual_state: WatershedVisualState


class ValidatedBasinDecision(StrictModel):
    schema_version: Literal[2] = 2
    decision_id: str = Field(pattern=r"^[a-f0-9]{16}$")
    frame_index: int = Field(ge=0, le=719)
    season: Season
    policy_summary: str
    rivers: tuple[ValidatedRiverDecision, ...]
    model_run: ModelRunReport | None = None
    disclaimer: Literal["VISUALIZATION ONLY — NOT A WATER-OPERATIONS DECISION"] = (
        "VISUALIZATION ONLY — NOT A WATER-OPERATIONS DECISION"
    )
