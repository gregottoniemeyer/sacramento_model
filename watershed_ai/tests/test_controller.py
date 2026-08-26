import json
from pathlib import Path
import unittest
from unittest.mock import patch

from watercouncil_ai.controller import (
    ACK_PROTOCOL,
    HOST_SCREEN_IDS,
    SCREEN_DESTINATIONS,
    WATERSHED_ACTIVE_INDICES,
    AppliedScreen,
    PartialApplyError,
    apply_decision,
    assert_studio_operator,
    assert_watershed_active,
)
from watercouncil_ai.data import load_observation
from watercouncil_ai.policy import validate_policy
from watercouncil_ai.schemas import ProposedBasinPolicy


PROJECT_ROOT = Path(__file__).resolve().parents[2]
SAMPLE = PROJECT_ROOT / "watershed_ai/data/sample_proposal.json"


class FakePreflightSocket:
    def __init__(
        self,
        incompatible_screen: str | None = None,
        positions: dict[str, float] | None = None,
    ):
        self.incompatible_screen = incompatible_screen
        self.positions = positions or {
            screen_id: 123.625 for screen_id in SCREEN_DESTINATIONS
        }
        self.request_id = ""
        self.responses = list(HOST_SCREEN_IDS)

    def __enter__(self):
        return self

    def __exit__(self, *_args):
        return False

    def bind(self, _address):
        return None

    def settimeout(self, _seconds):
        return None

    def sendto(self, encoded, _destination):
        payload = json.loads(encoded.decode("utf-8"))
        self.request_id = payload["metadata"]["request_id"]
        return len(encoded)

    def recvfrom(self, _size):
        host = self.responses.pop(0)
        screens = list(HOST_SCREEN_IDS[host])
        capabilities = {
            screen: {
                "eligible": screen != self.incompatible_screen,
                "fixed_bank_only": True,
                "current_observation": {
                    "screen_id": screen,
                    "watershed_row": {
                        "row_index": int(self.positions[screen]) % 720,
                        "row_count": 720,
                        "row_fraction": self.positions[screen] % 1.0,
                    },
                },
            }
            for screen in screens
        }
        acknowledgement = {
            "protocol": ACK_PROTOCOL,
            "accepted": True,
            "request_id": self.request_id,
            "regime_active_indices": WATERSHED_ACTIVE_INDICES,
            "recipient_count": len(screens),
            "recipient_screen_ids": screens,
            "recipient_watershed_ai_state": capabilities,
        }
        return json.dumps(acknowledgement).encode("utf-8"), (host, 5005)


class ControllerTests(unittest.TestCase):
    def test_live_ai_allows_studio_and_governator_ethernet_only(self):
        for address in ("196.168.50.11", "196.168.50.51"):
            with patch(
                "watercouncil_ai.controller.subprocess.run",
                return_value=type("Result", (), {
                    "returncode": 0,
                    "stdout": f"inet {address}\n",
                })(),
            ):
                assert_studio_operator()
        with patch(
            "watercouncil_ai.controller.subprocess.run",
            return_value=type("Result", (), {
                "returncode": 0,
                "stdout": "inet 10.0.0.2\n",
            })(),
        ):
            with self.assertRaisesRegex(OSError, "196.168.50.11"):
                assert_studio_operator()

    def test_preflight_requires_exact_hosts_and_capability(self):
        fake_socket = FakePreflightSocket()
        with patch("watercouncil_ai.controller.socket.socket", return_value=fake_socket):
            moment = assert_watershed_active()
        self.assertEqual(moment.frame_index, 123)
        self.assertAlmostEqual(moment.frame_fraction, 0.625)
        self.assertEqual(len(moment.screen_positions), 7)

    def test_preflight_rejects_ineligible_stage(self):
        fake_socket = FakePreflightSocket(incompatible_screen="delta")
        with patch("watercouncil_ai.controller.socket.socket", return_value=fake_socket):
            with self.assertRaisesRegex(OSError, "not ready"):
                assert_watershed_active()

    def test_preflight_rejects_cross_host_timeline_skew(self):
        positions = {screen_id: 123.5 for screen_id in SCREEN_DESTINATIONS}
        positions["mount_shasta"] = 126.0
        fake_socket = FakePreflightSocket(positions=positions)
        with patch("watercouncil_ai.controller.socket.socket", return_value=fake_socket):
            with self.assertRaisesRegex(OSError, "out of sync"):
                assert_watershed_active()

    def test_preflight_accepts_cyclic_wraparound(self):
        positions = {screen_id: 719.75 for screen_id in SCREEN_DESTINATIONS}
        positions["mount_shasta"] = 0.25
        fake_socket = FakePreflightSocket(positions=positions)
        with patch("watercouncil_ai.controller.socket.socket", return_value=fake_socket):
            moment = assert_watershed_active()
        self.assertEqual(moment.frame_index, 719)
        self.assertAlmostEqual(moment.frame_fraction, 0.75)

    def test_apply_uses_seven_explicit_screens(self):
        proposal = ProposedBasinPolicy.model_validate_json(SAMPLE.read_text())
        decision = validate_policy(load_observation(PROJECT_ROOT, 0), proposal)
        calls = []

        def fake_send(destination, screen_id, state):
            calls.append((destination, screen_id, state))
            return AppliedScreen(
                screen_id, destination, state["decision_id"], state["state_hash"]
            )

        with patch("watercouncil_ai.controller._send_until_applied", fake_send):
            applied = apply_decision(decision)
        self.assertEqual(len(applied), 7)
        self.assertEqual(
            {call[1] for call in calls},
            {river.screen_id for river in decision.rivers},
        )
        self.assertNotIn("*", {call[1] for call in calls})

    def test_partial_apply_names_the_screens_that_changed(self):
        proposal = ProposedBasinPolicy.model_validate_json(SAMPLE.read_text())
        decision = validate_policy(load_observation(PROJECT_ROOT, 0), proposal)

        def fake_send(destination, screen_id, state):
            if screen_id == "cottonwood_creek":
                raise OSError("simulated acknowledgement timeout")
            return AppliedScreen(
                screen_id, destination, state["decision_id"], state["state_hash"]
            )

        with patch("watercouncil_ai.controller._send_until_applied", fake_send):
            with self.assertRaises(PartialApplyError) as raised:
                apply_decision(decision)
        self.assertEqual(
            [item.screen_id for item in raised.exception.applied],
            ["mount_shasta", "mccloud_pit"],
        )
        self.assertEqual(raised.exception.failed_screen, "cottonwood_creek")


if __name__ == "__main__":
    unittest.main()
