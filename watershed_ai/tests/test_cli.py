import io
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from watercouncil_ai.agent import AgentPolicyRun
from watercouncil_ai.cli import default_project_root, main, persist_live_decision
from watercouncil_ai.controller import FleetMoment
from watercouncil_ai.data import load_observation
from watercouncil_ai.policy import validate_policy
from watercouncil_ai.schemas import ProposedBasinPolicy, ValidatedBasinDecision


PROJECT_ROOT = Path(__file__).resolve().parents[2]
SAMPLE = PROJECT_ROOT / "watershed_ai/data/sample_proposal.json"


class CliTests(unittest.TestCase):
    @staticmethod
    def agent_run(proposal):
        from watercouncil_ai.schemas import ModelRunReport

        return AgentPolicyRun(
            proposal,
            ModelRunReport(
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
                pricing_source="https://developers.openai.com/api/docs/models/gpt-5.6-luna",
            ),
        )

    def test_default_root_from_subproject_directory(self):
        with patch("pathlib.Path.cwd", return_value=PROJECT_ROOT / "watershed_ai"):
            self.assertEqual(default_project_root(), PROJECT_ROOT)

    def test_live_preflight_fails_before_api_call(self):
        with (
            patch("watercouncil_ai.cli.assert_studio_operator"),
            patch(
                "watercouncil_ai.cli.assert_watershed_active",
                side_effect=OSError("not ready"),
            ),
            patch("watercouncil_ai.cli.propose_policy") as propose_policy,
            patch("sys.stderr", new_callable=io.StringIO),
        ):
            result = main(
                ["--project-root", str(PROJECT_ROOT), "--frame", "0", "--live"]
            )
        self.assertEqual(result, 1)
        propose_policy.assert_not_called()

    def test_dry_run_never_calls_preflight_or_apply(self):
        proposal = ProposedBasinPolicy.model_validate_json(SAMPLE.read_text())
        with (
            patch("watercouncil_ai.cli.propose_policy", return_value=self.agent_run(proposal)),
            patch("watercouncil_ai.cli.assert_watershed_active") as preflight,
            patch("watercouncil_ai.cli.apply_decision") as apply_decision,
            patch("sys.stdout", new_callable=io.StringIO),
            patch("sys.stderr", new_callable=io.StringIO),
        ):
            result = main(["--project-root", str(PROJECT_ROOT), "--frame", "0"])
        self.assertEqual(result, 0)
        preflight.assert_not_called()
        apply_decision.assert_not_called()

    def test_saved_decision_replays_without_api_call(self):
        proposal = ProposedBasinPolicy.model_validate_json(SAMPLE.read_text())
        decision = validate_policy(load_observation(PROJECT_ROOT, 0), proposal)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            decision_path = persist_live_decision(root, decision)
            loaded = ValidatedBasinDecision.model_validate_json(
                decision_path.read_text(encoding="utf-8")
            )
        self.assertEqual(loaded, decision)

    def test_current_live_uses_ack_derived_frame_once(self):
        proposal = ProposedBasinPolicy.model_validate_json(SAMPLE.read_text())
        moment = FleetMoment(123, 0.625, tuple())
        with (
            tempfile.TemporaryDirectory() as directory,
            patch("watercouncil_ai.cli.assert_studio_operator"),
            patch(
                "watercouncil_ai.cli.assert_watershed_active",
                return_value=moment,
            ),
            patch("watercouncil_ai.cli.load_observation") as load_observation_mock,
            patch("watercouncil_ai.cli.propose_policy", return_value=self.agent_run(proposal)),
            patch("watercouncil_ai.cli.validate_policy") as validate_policy_mock,
            patch("sys.stderr", new_callable=io.StringIO),
        ):
            load_observation_mock.return_value = load_observation(PROJECT_ROOT, 123, 0.625)
            validate_policy_mock.return_value = validate_policy(
                load_observation_mock.return_value,
                proposal,
                self.agent_run(proposal).report,
            )
            with patch("watercouncil_ai.cli.apply_decision", return_value=tuple()):
                result = main(
                    [
                        "--project-root",
                        directory,
                        "--current",
                        "--live",
                    ]
                )
        self.assertEqual(result, 0)
        load_observation_mock.assert_called_once_with(Path(directory), 123, 0.625)

    def test_live_saved_decision_is_credit_free(self):
        proposal = ProposedBasinPolicy.model_validate_json(SAMPLE.read_text())
        decision = validate_policy(load_observation(PROJECT_ROOT, 0), proposal)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            saved = persist_live_decision(root, decision)
            with (
                patch("watercouncil_ai.cli.assert_studio_operator"),
                patch(
                    "watercouncil_ai.cli.assert_watershed_active",
                    return_value=FleetMoment(10, 0.2, tuple()),
                ),
                patch("watercouncil_ai.cli.propose_policy") as propose_policy,
                patch("watercouncil_ai.cli.load_observation") as load_observation_mock,
                patch("watercouncil_ai.cli.apply_decision", return_value=tuple()),
                patch("sys.stdout", new_callable=io.StringIO),
            ):
                result = main(
                    [
                        "--project-root",
                        str(root),
                        "--decision",
                        str(saved),
                        "--live",
                    ]
                )
        self.assertEqual(result, 0)
        propose_policy.assert_not_called()
        load_observation_mock.assert_not_called()


if __name__ == "__main__":
    unittest.main()
