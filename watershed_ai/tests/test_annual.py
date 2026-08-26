import json
from pathlib import Path
import tempfile
import unittest

from watercouncil_ai.agent import AgentPolicyRun
from watercouncil_ai.annual import (
    ANNUAL_PARTIAL_FILENAME,
    MODEL_DAY_COUNT,
    build_annual_decisions,
    load_annual_decision,
    model_day_for_position,
    model_position_for_day,
)
from watercouncil_ai.data import load_observation
from watercouncil_ai.policy import validate_policy
from watercouncil_ai.schemas import ModelRunReport, ProposedBasinPolicy


PROJECT_ROOT = Path(__file__).resolve().parents[2]
SAMPLE = PROJECT_ROOT / "watershed_ai/data/sample_proposal.json"


def model_report() -> ModelRunReport:
    return ModelRunReport(
        model="gpt-5.6-luna",
        requests=1,
        input_tokens=1000,
        cached_input_tokens=0,
        cache_write_tokens=0,
        output_tokens=200,
        total_tokens=1200,
        estimated_cost_usd=0.00044,
        pricing_snapshot_date="2026-08-23",
        input_usd_per_million_tokens=0.20,
        cached_input_usd_per_million_tokens=0.02,
        cache_write_usd_per_million_tokens=0.25,
        output_usd_per_million_tokens=1.20,
        pricing_source="test",
    )


class AnnualDecisionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.proposal = ProposedBasinPolicy.model_validate_json(SAMPLE.read_text())

    def test_every_day_noon_maps_back_to_the_same_day(self):
        for day_index in range(MODEL_DAY_COUNT):
            frame, fraction = model_position_for_day(day_index)
            self.assertEqual(
                model_day_for_position(frame, fraction),
                day_index,
            )
        self.assertEqual(model_position_for_day(0)[0], 0)
        self.assertEqual(model_position_for_day(364)[0], 719)

    def test_complete_array_selects_the_live_day(self):
        base = validate_policy(
            load_observation(PROJECT_ROOT, 0),
            self.proposal,
            model_report(),
        )
        entries = []
        for day_index in range(MODEL_DAY_COUNT):
            frame, _fraction = model_position_for_day(day_index)
            decision_id = f"{day_index:016x}"
            rivers = tuple(
                river.model_copy(
                    update={
                        "frame_index": frame,
                        "visual_state": river.visual_state.model_copy(
                            update={
                                "decision_id": decision_id,
                                "frame_index": frame,
                            }
                        ),
                    }
                )
                for river in base.rivers
            )
            entries.append(
                base.model_copy(
                    update={
                        "decision_id": decision_id,
                        "frame_index": frame,
                        "rivers": rivers,
                    }
                ).model_dump(mode="json")
            )
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "annual.json"
            path.write_text(json.dumps(entries), encoding="utf-8")
            frame, fraction = model_position_for_day(177)
            day_index, decision = load_annual_decision(path, frame, fraction)
        self.assertEqual(day_index, 177)
        self.assertEqual(decision.decision_id, f"{177:016x}")

    def test_partial_generation_is_checkpointed_and_resumable(self):
        calls = []

        def proposer(observation, _root, _model):
            calls.append(observation.frame_index)
            return AgentPolicyRun(self.proposal, model_report())

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source_project = (
                PROJECT_ROOT / "godot_experiments"
                if (PROJECT_ROOT / "godot_experiments").is_dir()
                else PROJECT_ROOT
            )
            (root / "godot_experiments").symlink_to(
                source_project,
                target_is_directory=True,
            )
            path, failures, cost = build_annual_decisions(
                root,
                workers=2,
                proposer=proposer,
                days=[0, 1],
            )
            target = root / "watershed_ai/runlogs" / ANNUAL_PARTIAL_FILENAME
            path, failures, cost = build_annual_decisions(
                root,
                workers=2,
                proposer=proposer,
                days=[0, 1],
            )
            raw = json.loads(target.read_text(encoding="utf-8"))
        self.assertIsNone(path)
        self.assertEqual(failures, [])
        self.assertEqual(len(calls), 2)
        self.assertIsNotNone(raw[0])
        self.assertIsNotNone(raw[1])
        self.assertEqual(sum(value is not None for value in raw), 2)
        self.assertAlmostEqual(cost, 0.00088)


if __name__ == "__main__":
    unittest.main()
