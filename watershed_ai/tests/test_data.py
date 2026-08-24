from pathlib import Path
import unittest

from watercouncil_ai.data import MINIMUM_INPUT_RATE, load_observation


PROJECT_ROOT = Path(__file__).resolve().parents[2]


class DataTests(unittest.TestCase):
    def test_all_screens_use_atmospheric_input_semantics(self):
        observation = load_observation(PROJECT_ROOT, 0)
        self.assertEqual(len(observation.stages), 7)
        by_id = {stage.screen_id: stage for stage in observation.stages}
        self.assertIsNone(by_id["cottonwood_creek"].temperature_c)
        self.assertIn("CONCEPTUAL_WEIGHTED_AGGREGATE", by_id["delta"].quality_flags)
        for stage in observation.stages:
            self.assertGreaterEqual(stage.atmospheric_input_mm_day, 0.0)
            self.assertGreaterEqual(stage.atmospheric_input_0_1, MINIMUM_INPUT_RATE)

    def test_wrap_interpolation_and_reservoir_state_are_bounded(self):
        observation = load_observation(PROJECT_ROOT, 719, 0.5)
        self.assertEqual(observation.frame_index, 719)
        self.assertEqual(observation.season, "summer")
        for stage in observation.stages:
            for value in (
                stage.atmospheric_input_0_1,
                stage.trailing_30_day_input_0_1,
                stage.reservoir_storage_0_1,
                stage.reservoir_release_0_1,
            ):
                self.assertGreaterEqual(value, 0.0)
                self.assertLessEqual(value, 1.0)

    def test_spring_storage_is_available_for_summer_release(self):
        spring = load_observation(PROJECT_ROOT, 660)
        summer = load_observation(PROJECT_ROOT, 719)
        self.assertTrue(any(stage.reservoir_storage_0_1 > 0.2 for stage in spring.stages))
        self.assertTrue(any(stage.reservoir_release_0_1 > 0.0 for stage in summer.stages))


if __name__ == "__main__":
    unittest.main()
