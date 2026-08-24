import json
from pathlib import Path
import unittest

from watercouncil_ai.data import load_observation
from watercouncil_ai.policy import (
    BASE_SALMON_FLOOR,
    CITY_FLOOR,
    DATA_CENTER_FLOOR,
    MAX_SALMON_FLOOR,
    SUMMER_AGRICULTURE_FLOOR,
    WINTER_DATA_CENTER_FLOOR,
    _visual_state_hash,
    validate_policy,
)
from watercouncil_ai.schemas import ProposedBasinPolicy


PROJECT_ROOT = Path(__file__).resolve().parents[2]
SAMPLE = PROJECT_ROOT / "watershed_ai/data/sample_proposal.json"


class PolicyTests(unittest.TestCase):
    def setUp(self):
        self.proposal = ProposedBasinPolicy.model_validate_json(SAMPLE.read_text(encoding="utf-8"))

    def test_budget_sums_floors_and_zero_power_projects(self):
        decision = validate_policy(load_observation(PROJECT_ROOT, 0), self.proposal)
        self.assertEqual(len(decision.rivers), 7)
        for river in decision.rivers:
            shares = river.shares
            self.assertAlmostEqual(sum(shares.model_dump().values()), 1.0, places=10)
            self.assertGreaterEqual(shares.salmon, river.salmon_floor)
            self.assertGreaterEqual(shares.city, CITY_FLOOR)
            self.assertGreaterEqual(shares.agriculture, SUMMER_AGRICULTURE_FLOOR)
            self.assertGreaterEqual(shares.data_centers, DATA_CENTER_FLOOR)
            state = river.visual_state
            self.assertAlmostEqual(
                state.extraction_fraction,
                shares.agriculture + shares.data_centers + shares.city,
            )
            self.assertAlmostEqual(
                state.remaining_rate,
                state.available_supply_rate * (1.0 - state.extraction_fraction),
            )
            self.assertEqual(state.hydropower_fraction, 0.0)
            self.assertEqual(state.water_project_fraction, 0.0)

    def test_hotter_temperature_raises_salmon_floor(self):
        observation = load_observation(PROJECT_ROOT, 0)
        cool_stage = observation.stages[0].model_copy(update={"temperature_c": 10.0})
        hot_stage = observation.stages[0].model_copy(update={"temperature_c": 23.0})
        cool = observation.model_copy(update={"stages": (cool_stage, *observation.stages[1:])})
        hot = observation.model_copy(update={"stages": (hot_stage, *observation.stages[1:])})
        cool_floor = validate_policy(cool, self.proposal).rivers[0].salmon_floor
        hot_floor = validate_policy(hot, self.proposal).rivers[0].salmon_floor
        self.assertGreaterEqual(cool_floor, BASE_SALMON_FLOOR)
        self.assertLessEqual(hot_floor, MAX_SALMON_FLOOR)
        self.assertGreater(hot_floor, cool_floor)

    def test_season_shifts_winter_compute_and_summer_food(self):
        observation = load_observation(PROJECT_ROOT, 719)
        winter = validate_policy(observation.model_copy(update={"season": "winter"}), self.proposal)
        summer = validate_policy(observation.model_copy(update={"season": "summer"}), self.proposal)
        for winter_river, summer_river in zip(winter.rivers, summer.rivers):
            self.assertGreater(winter_river.shares.data_centers, summer_river.shares.data_centers)
            self.assertGreater(summer_river.shares.agriculture, winter_river.shares.agriculture)
            self.assertGreaterEqual(winter_river.shares.data_centers, WINTER_DATA_CENTER_FLOOR)
            self.assertGreaterEqual(summer_river.shares.data_centers, DATA_CENTER_FLOOR)

    def test_same_input_is_idempotent(self):
        observation = load_observation(PROJECT_ROOT, 17, 0.25)
        self.assertEqual(validate_policy(observation, self.proposal), validate_policy(observation, self.proposal))

    def test_sample_is_strict_json(self):
        parsed = json.loads(SAMPLE.read_text(encoding="utf-8"))
        self.assertEqual(len(parsed["rivers"]), 7)

    def test_hash_matches_godot_known_answer(self):
        state = {
            "schema_version": 2,
            "atmospheric_input_rate": 0.60,
            "reservoir_release_rate": 0.10,
            "available_supply_rate": 0.70,
            "extraction_fraction": 0.40,
            "remaining_rate": 0.42,
            "salmon_fraction": 0.35,
            "floodplain_fraction": 0.25,
            "agriculture_fraction": 0.15,
            "data_center_fraction": 0.15,
            "city_fraction": 0.10,
            "reservoir_storage_fraction": 0.50,
            "hydropower_fraction": 0.0,
            "water_project_fraction": 0.0,
        }
        self.assertEqual(
            _visual_state_hash(state),
            "abfc3b0a9327e7d9c4403dcd15e475a74c4223427eb9de96d0aeea03a2e4f5f9",
        )


if __name__ == "__main__":
    unittest.main()
