"""Narrow UDP adapter for the visual-only watershed-ai/2 scope."""

from __future__ import annotations

import json
import math
import socket
import subprocess
import time
import uuid
from dataclasses import dataclass

from .schemas import SCREEN_IDS, ValidatedBasinDecision


PROTOCOL = "ink-flow/1"
ACK_PROTOCOL = "ink-flow/1-ack"
CONTROL_SCOPE = "watershed-ai/2"
FLOW_CONTROL_PORT = 5005
WATERSHED_ACTIVE_INDICES = [6]
ACK_ATTEMPTS = 24
ACK_WAIT_SECONDS = 0.75

SCREEN_DESTINATIONS: dict[str, str] = {
    "mount_shasta": "196.168.50.21",
    "mccloud_pit": "196.168.50.21",
    "cottonwood_creek": "196.168.50.31",
    "mill_creek": "196.168.50.31",
    "feather_river": "196.168.50.41",
    "american_river": "196.168.50.41",
    "delta": "196.168.50.11",
}

HOST_SCREEN_IDS: dict[str, tuple[str, ...]] = {
    "196.168.50.11": ("delta",),
    "196.168.50.21": ("mccloud_pit", "mount_shasta"),
    "196.168.50.31": ("cottonwood_creek", "mill_creek"),
    "196.168.50.41": ("american_river", "feather_river"),
}


@dataclass(frozen=True)
class FleetMoment:
    frame_index: int
    frame_fraction: float
    screen_positions: tuple[tuple[str, float], ...]


def assert_studio_operator() -> None:
    """Live AI is deliberately restricted to the isolated studio controller."""
    result = subprocess.run(
        ["/sbin/ifconfig"], capture_output=True, text=True, timeout=4, check=False
    )
    if result.returncode != 0 or "196.168.50.51" not in result.stdout:
        raise OSError("live Watershed AI requires studio Ethernet 196.168.50.51")


def _fleet_moment_from_capabilities(
    capabilities_by_screen: dict[str, dict[str, object]],
) -> FleetMoment:
    positions: dict[str, float] = {}
    for screen_id in SCREEN_DESTINATIONS:
        capability = capabilities_by_screen.get(screen_id, {})
        observation = capability.get("current_observation", {})
        if not isinstance(observation, dict):
            raise OSError(f"Godot screen {screen_id} has no current observation")
        if observation.get("screen_id") != screen_id:
            raise OSError(f"Godot screen {screen_id} reported the wrong observation ID")
        row = observation.get("watershed_row", {})
        if not isinstance(row, dict) or row.get("row_count") != 720:
            raise OSError(f"Godot screen {screen_id} has no 720-row Watershed phase")
        row_index = row.get("row_index")
        row_fraction = row.get("row_fraction")
        if (
            isinstance(row_index, bool)
            or not isinstance(row_index, int)
            or not 0 <= row_index < 720
            or isinstance(row_fraction, bool)
            or not isinstance(row_fraction, (int, float))
            or not math.isfinite(float(row_fraction))
            or not 0.0 <= float(row_fraction) < 1.0
        ):
            raise OSError(f"Godot screen {screen_id} reported an invalid Watershed phase")
        positions[screen_id] = row_index + float(row_fraction)
    reference = positions["delta"]
    for screen_id, position in positions.items():
        circular_offset = abs(((position - reference + 360.0) % 720.0) - 360.0)
        if circular_offset > 2.0:
            raise OSError(
                f"fleet model timelines are out of sync; {screen_id} differs from "
                f"Delta by {circular_offset:.3f} rows"
            )
    return FleetMoment(
        frame_index=int(math.floor(reference)) % 720,
        frame_fraction=reference - math.floor(reference),
        screen_positions=tuple(sorted(positions.items())),
    )


def assert_watershed_active() -> FleetMoment:
    """Return the displayed fleet moment after a strict Watershed preflight."""
    request_id = uuid.uuid4().hex
    payload = {
        "protocol": PROTOCOL,
        "target": "*",
        "changes": {},
        "geometry_ops": [],
        "actions": [],
        "metadata": {
            "source": "watercouncil-watershed-ai-preflight",
            "request_id": request_id,
        },
    }
    encoded = json.dumps(payload, sort_keys=True, separators=(",", ":")).encode()
    destinations = set(SCREEN_DESTINATIONS.values())
    last_seen_screens: dict[str, object] = {}
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as udp_socket:
        udp_socket.bind(("", 0))
        for _attempt in range(ACK_ATTEMPTS):
            pending = set(destinations)
            capabilities_by_screen: dict[str, dict[str, object]] = {}
            for destination in destinations:
                udp_socket.sendto(encoded, (destination, FLOW_CONTROL_PORT))
            deadline = time.monotonic() + ACK_WAIT_SECONDS
            while pending and time.monotonic() < deadline:
                udp_socket.settimeout(max(deadline - time.monotonic(), 0.01))
                try:
                    raw_ack, sender = udp_socket.recvfrom(16384)
                except socket.timeout:
                    break
                if sender[0] not in pending:
                    continue
                try:
                    acknowledgement = json.loads(raw_ack.decode("utf-8"))
                except (UnicodeDecodeError, json.JSONDecodeError):
                    continue
                if not isinstance(acknowledgement, dict):
                    continue
                if (
                    acknowledgement.get("protocol") != ACK_PROTOCOL
                    or acknowledgement.get("request_id") != request_id
                ):
                    continue
                if acknowledgement.get("accepted") is not True:
                    reason = acknowledgement.get("reason", "preflight rejected")
                    raise OSError(f"Godot at {sender[0]} rejected preflight: {reason}")
                if acknowledgement.get("regime_active_indices") != WATERSHED_ACTIVE_INDICES:
                    raise OSError(
                        "Watershed must be the sole active regime before AI control"
                    )
                expected_screen_ids = list(HOST_SCREEN_IDS[sender[0]])
                if acknowledgement.get("recipient_count") != len(expected_screen_ids):
                    raise OSError(
                        f"Godot at {sender[0]} has the wrong number of active screens"
                    )
                if acknowledgement.get("recipient_screen_ids") != expected_screen_ids:
                    raise OSError(
                        f"Godot at {sender[0]} does not host the expected screens"
                    )
                last_seen_screens[sender[0]] = acknowledgement.get(
                    "recipient_screen_ids", []
                )
                recipient_state = acknowledgement.get(
                    "recipient_watershed_ai_state", {}
                )
                if not isinstance(recipient_state, dict):
                    raise OSError(
                        f"Godot at {sender[0]} lacks Watershed AI capability state"
                    )
                for screen_id in expected_screen_ids:
                    capability = recipient_state.get(screen_id, {})
                    if (
                        not isinstance(capability, dict)
                        or capability.get("eligible") is not True
                        or capability.get("fixed_bank_only") is not True
                    ):
                        raise OSError(
                            f"Godot at {sender[0]} screen {screen_id} is not "
                            "ready for bounded Watershed AI control"
                        )
                    capabilities_by_screen[screen_id] = capability
                pending.remove(sender[0])
            if not pending:
                return _fleet_moment_from_capabilities(capabilities_by_screen)
    detail = "; ".join(
        f"{host} saw {last_seen_screens.get(host, [])!r}"
        for host in sorted(destinations)
    )
    raise OSError(
        "not all fleet renderers acknowledged one coherent Watershed preflight: "
        + detail
    )


@dataclass(frozen=True)
class AppliedScreen:
    screen_id: str
    destination: str
    decision_id: str
    state_hash: str


class PartialApplyError(OSError):
    """A visual-only fleet update stopped after one or more screens applied."""

    def __init__(
        self,
        applied: tuple[AppliedScreen, ...],
        failed_screen: str,
        cause: OSError,
    ) -> None:
        self.applied = applied
        self.failed_screen = failed_screen
        self.cause = cause
        applied_ids = ", ".join(item.screen_id for item in applied) or "none"
        super().__init__(
            f"partial Watershed AI application; applied [{applied_ids}], "
            f"failed at {failed_screen}: {cause}"
        )


def _send_until_applied(
    destination: str,
    screen_id: str,
    state: dict[str, object],
) -> AppliedScreen:
    request_id = uuid.uuid4().hex
    wire_state = {
        key: value
        for key, value in state.items()
        if key not in {"state_hash", "frame_index"}
    }
    payload = {
        "protocol": PROTOCOL,
        "control_scope": CONTROL_SCOPE,
        "target": screen_id,
        "changes": {"watershed.ai.state": wire_state},
        "geometry_ops": [],
        "actions": [],
        "metadata": {
            "source": "watercouncil-watershed-ai",
            "request_id": request_id,
        },
    }
    encoded = json.dumps(payload, sort_keys=True, separators=(",", ":")).encode()
    expected_decision_id = str(state["decision_id"])
    expected_state_hash = str(state["state_hash"])
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as udp_socket:
        udp_socket.bind(("", 0))
        for _attempt in range(ACK_ATTEMPTS):
            sent = udp_socket.sendto(encoded, (destination, FLOW_CONTROL_PORT))
            if sent != len(encoded):
                raise OSError(f"sent only {sent} of {len(encoded)} bytes")
            deadline = time.monotonic() + ACK_WAIT_SECONDS
            while time.monotonic() < deadline:
                udp_socket.settimeout(max(deadline - time.monotonic(), 0.01))
                try:
                    raw_ack, sender = udp_socket.recvfrom(16384)
                except socket.timeout:
                    break
                if sender[0] != destination:
                    continue
                try:
                    acknowledgement = json.loads(raw_ack.decode("utf-8"))
                except (UnicodeDecodeError, json.JSONDecodeError):
                    continue
                if not isinstance(acknowledgement, dict):
                    continue
                if acknowledgement.get("protocol") != ACK_PROTOCOL:
                    continue
                if acknowledgement.get("request_id") != request_id:
                    continue
                if acknowledgement.get("accepted") is not True:
                    reason = acknowledgement.get("reason", "packet rejected")
                    raise OSError(f"Godot at {destination} rejected state: {reason}")
                if acknowledgement.get("regime_active_indices") != WATERSHED_ACTIVE_INDICES:
                    raise OSError(
                        "Watershed must be the sole active regime before AI control"
                    )
                if acknowledgement.get("recipient_screen_ids") != [screen_id]:
                    continue
                if acknowledgement.get("recipient_count") != 1:
                    continue
                applied = acknowledgement.get("recipient_watershed_ai_state", {})
                if not isinstance(applied, dict):
                    continue
                screen_state = applied.get(screen_id, {})
                if not isinstance(screen_state, dict):
                    continue
                if (
                    screen_state.get("applied_decision_id") == expected_decision_id
                    and screen_state.get("applied_state_hash") == expected_state_hash
                ):
                    return AppliedScreen(
                        screen_id,
                        destination,
                        expected_decision_id,
                        expected_state_hash,
                    )
    raise OSError(
        f"no applied Watershed AI acknowledgement from {screen_id} at {destination}"
    )


def apply_decision(decision: ValidatedBasinDecision) -> tuple[AppliedScreen, ...]:
    """Apply seven absolute per-screen states; no actions or geometry operations."""
    by_screen = {river.screen_id: river for river in decision.rivers}
    if set(by_screen) != set(SCREEN_IDS):
        raise ValueError("decision does not cover all canonical screens")
    applied = []
    for screen_id in SCREEN_IDS:
        river = by_screen[screen_id]
        try:
            applied.append(
                _send_until_applied(
                    SCREEN_DESTINATIONS[screen_id],
                    screen_id,
                    river.visual_state.model_dump(mode="json"),
                )
            )
        except OSError as error:
            raise PartialApplyError(tuple(applied), screen_id, error) from error
    return tuple(applied)
