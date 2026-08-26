"""Offline seasonal-policy evals: no API, socket, or fleet access."""

from __future__ import annotations

import json
from pathlib import Path

from watercouncil_ai.data import load_observation
from watercouncil_ai.policy import MAX_SUSTAINABLE_EXTRACTION, validate_policy
from watercouncil_ai.schemas import ProposedBasinPolicy, SCREEN_IDS


ROOT = Path(__file__).resolve().parents[2]


def require(condition: bool, message: str) -> None:
    if not condition:
        raise RuntimeError(message)


def check_assertion(name, observation, decision, proposal) -> None:
    by_screen = {river.screen_id: river for river in decision.rivers}
    observed = {stage.screen_id: stage for stage in observation.stages}
    proposed = {river.screen_id: river for river in proposal.rivers}
    if name == "all_screens":
        require(tuple(by_screen) == SCREEN_IDS, "canonical screen coverage failed")
    elif name == "unit_sum":
        for river in decision.rivers:
            require(abs(sum(river.shares.model_dump().values()) - 1.0) < 1e-8, "allocation does not sum to one")
    elif name == "seasonal_floors":
        for river in decision.rivers:
            require(river.shares.salmon >= river.salmon_floor, "salmon floor failed")
            require(river.shares.data_centers >= river.data_center_floor, "data-center floor failed")
    elif name == "winter_data_center_floor":
        require(all(r.shares.data_centers >= r.data_center_floor for r in decision.rivers), "winter compute floor failed")
    elif name == "summer_reservoir_release":
        require(any(s.reservoir_release_0_1 > 0.0 for s in observation.stages), "summer did not release stored spring water")
    elif name == "spring_reservoir_storage":
        require(any(s.reservoir_storage_0_1 > 0.2 for s in observation.stages), "spring storage did not accumulate")
    elif name == "zero_legacy_power":
        require(all(r.visual_state.hydropower_fraction == 0.0 and r.visual_state.water_project_fraction == 0.0 for r in decision.rivers), "legacy power/project extraction was not zero")
    elif name == "all_values_bounded":
        for river in decision.rivers:
            require(river.visual_state.extraction_fraction <= MAX_SUSTAINABLE_EXTRACTION, "extraction exceeds 50%")
            for field, value in river.visual_state.model_dump().items():
                if isinstance(value, float):
                    require(0.0 <= value <= 1.0, f"{field} out of bounds")
    elif name == "missing_temperature_is_not_invented":
        require(observed["cottonwood_creek"].temperature_c is None, "Cottonwood temperature was invented")
        require(by_screen["cottonwood_creek"].thermal_stress == 0.0, "missing temperature created thermal stress")
    elif name == "quality_flag_preserved":
        require("CONCEPTUAL_WEIGHTED_AGGREGATE" in observed["delta"].quality_flags, "Delta aggregate flag is missing")
    elif name == "low_confidence_requested":
        require(proposed["delta"].confidence <= 0.5, "uncertain Delta fixture did not request low confidence")
    else:
        raise RuntimeError(f"unknown eval assertion: {name}")


def main() -> int:
    proposal = ProposedBasinPolicy.model_validate_json((ROOT / "watershed_ai/data/sample_proposal.json").read_text(encoding="utf-8"))
    cases = [json.loads(line) for line in (ROOT / "watershed_ai/evals/cases.jsonl").read_text(encoding="utf-8").splitlines() if line.strip()]
    for case in cases:
        observation = load_observation(ROOT, int(case["frame"]))
        decision = validate_policy(observation, proposal)
        for assertion_name in case["assertions"]:
            check_assertion(assertion_name, observation, decision, proposal)
        print(f"PASS {case['name']} frame={case['frame']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
