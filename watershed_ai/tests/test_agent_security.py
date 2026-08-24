import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from watercouncil_ai.agent import _cost_report, load_local_api_key


class AgentSecurityTests(unittest.TestCase):
    def test_key_loader_reads_only_named_value_without_output(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / ".env.local").write_text(
                "IGNORED=value\nOPENAI_API_KEY=test-secret\n", encoding="utf-8"
            )
            with patch.dict(os.environ, {}, clear=True):
                load_local_api_key(root)
                self.assertEqual(os.environ["OPENAI_API_KEY"], "test-secret")

    def test_missing_key_fails_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            with patch.dict(os.environ, {}, clear=True):
                with self.assertRaises(RuntimeError):
                    load_local_api_key(Path(directory))

    def test_cost_report_uses_measured_usage_and_luna_rates(self):
        class Details:
            cached_tokens = 200
            cache_write_tokens = 100

        class Usage:
            requests = 1
            input_tokens = 1000
            output_tokens = 250
            total_tokens = 1250
            input_tokens_details = Details()

        report = _cost_report("gpt-5.6-luna", Usage())
        expected = (700 * 0.20 + 200 * 0.02 + 100 * 0.25 + 250 * 1.20) / 1_000_000
        self.assertAlmostEqual(report.estimated_cost_usd, expected)
        self.assertEqual(report.cached_input_tokens, 200)
        self.assertEqual(report.cache_write_tokens, 100)


if __name__ == "__main__":
    unittest.main()
