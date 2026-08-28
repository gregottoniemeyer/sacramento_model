#!/usr/bin/env python3
"""Pull upstream water state over UDP 5005 and inject it into Delta locally.

macOS Local Network privacy can reject Godot-originated UDP even while Python
and the established FlowControlBus request/reply path remain available.  This
process runs on the Delta Mac (.11), polls all four Godot processes, strictly
validates their ACK snapshots, relays water state into Delta over loopback, and
reliably carries immutable leaves, pollution, and surviving salmon batches in
both directions through the FlowControl request/reply channel.
"""

from __future__ import annotations

import argparse
import json
import math
import select
import signal
import socket
import sys
import threading
import time
import uuid
from dataclasses import dataclass
from typing import Callable, Optional


FLOW_PROTOCOL = "ink-flow/1"
FLOW_ACK_PROTOCOL = "ink-flow/1-ack"
FLOW_CONTROL_PORT = 5005
CONFLUENCE_PROTOCOL = "water-council-confluence/1"
CONFLUENCE_PORT = 5007
DELTA_SCREEN = "delta"
WATER_ACK_FIELD = "recipient_watershed_ai_state"
PARTICLE_BRIDGE_FIELD = "particle_confluence_bridge"
DEFAULT_INTERVAL_SECONDS = 0.2
DEFAULT_ACK_TIMEOUT_SECONDS = 0.15
WATER_TRANSIT_DISTANCE_PIXELS = 1920.0
UPSTREAM_EXIT_WIDTH_PIXELS = 1024.0
# At the existing 150 px/s minimum, one screen takes 64 samples at 5 Hz.
# Keep two screens of headroom while making memory use strictly bounded.
MAX_WATER_TRANSIT_SAMPLES = 128
MAX_DATAGRAM_BYTES = 65535
PARTICLE_EVENT_PAGE_MAX = 16
MAX_PENDING_SOURCE_ACKS = 1024
MAX_PARTICLE_EVENT_COUNT = 300
SALMON_ORIGIN_COUNT = 25
MAX_TEXT_FIELD_LENGTH = 128
PARTICLE_DELIVERY_SUCCESS_STATUSES = {
    "accepted",
    "applied",
    "scheduled",
    "duplicate",
}
SOURCE_ACK_SUCCESS_STATUSES = {"acknowledged", "already_acknowledged"}
SOURCE_ACK_TERMINAL_STATUSES = {"stale_session", "unknown_event"}
ALLOWED_PARTICLE_SUBTYPES = {
    "mixed",
    "material",
    "heat",
    "top",
    "bottom",
    "default",
}
UPSTREAM_PARTICLE_SLOTS = 1000
FLOW_DENSITY_LOW_RATE = 0.01
FLOW_DENSITY_LOW_LINE_COUNT = 20
UPSTREAM_FLOW_SPEED_PIXELS = 600.0
UPSTREAM_MIN_ACTIVE_FLOW = 0.25


@dataclass(frozen=True)
class UpstreamHost:
    ip: str
    screens: tuple[str, ...]


UPSTREAM_HOSTS = (
    UpstreamHost("196.168.50.21", ("mount_shasta", "mccloud_pit")),
    UpstreamHost("196.168.50.31", ("cottonwood_creek", "mill_creek")),
    UpstreamHost("196.168.50.41", ("feather_river", "american_river")),
)
DELTA_EVENT_SOURCE = UpstreamHost("127.0.0.1", (DELTA_SCREEN,))
EVENT_SOURCE_HOSTS = (*UPSTREAM_HOSTS, DELTA_EVENT_SOURCE)
SCREEN_DESTINATIONS = {
    screen: host.ip
    for host in UPSTREAM_HOSTS
    for screen in host.screens
}
SCREEN_DESTINATIONS[DELTA_SCREEN] = "127.0.0.1"


class AckValidationError(ValueError):
    """An ACK did not prove the expected host and per-screen water state."""


def compact_json(value: dict) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode("utf-8")


def build_poll_request(host: UpstreamHost, request_id: str) -> dict:
    if not request_id or len(request_id) > 128:
        raise ValueError("request_id must contain 1..128 characters")
    return {
        "protocol": FLOW_PROTOCOL,
        "target": list(host.screens),
        "changes": {},
        "geometry_ops": [],
        "actions": [],
        "metadata": {
            "source": "confluence-water-bridge",
            "command": "particle-confluence-water-state",
            "request_id": request_id,
        },
    }


def _finite_number(value, name: str, minimum: float, maximum: float) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise AckValidationError(f"{name} must be numeric")
    normalized = float(value)
    if not math.isfinite(normalized) or not minimum <= normalized <= maximum:
        raise AckValidationError(f"{name} is outside {minimum}..{maximum}")
    return normalized


def exit_width_pixels_for_flow_rate(flow_rate: float) -> float:
    """Return the rendered 28..1052 shoreline span occupied by upstream water."""
    rate = min(max(float(flow_rate), 0.0), 1.0)
    return UPSTREAM_EXIT_WIDTH_PIXELS * rate


def validate_water_state(value, screen_id: str) -> dict:
    if not isinstance(value, dict):
        raise AckValidationError(f"water state for {screen_id} must be an object")
    required_fields = {"flow_rate", "active_heads", "speed_pixels", "paused"}
    allowed_fields = required_fields | {"exit_width_pixels"}
    if not required_fields.issubset(value) or not set(value).issubset(allowed_fields):
        raise AckValidationError(f"water state for {screen_id} has unexpected fields")
    flow_rate = _finite_number(value["flow_rate"], "flow_rate", 0.0, 1.0)
    active_heads = value["active_heads"]
    if (
        isinstance(active_heads, bool)
        or not isinstance(active_heads, int)
        or not 0 <= active_heads <= 2000
    ):
        raise AckValidationError("active_heads must be an integer in 0..2000")
    speed_pixels = _finite_number(
        value["speed_pixels"], "speed_pixels", 0.0, 2400.0
    )
    if not isinstance(value["paused"], bool):
        raise AckValidationError("paused must be boolean")
    exit_width_pixels = _finite_number(
        value.get(
            "exit_width_pixels",
            exit_width_pixels_for_flow_rate(flow_rate),
        ),
        "exit_width_pixels",
        0.0,
        UPSTREAM_EXIT_WIDTH_PIXELS,
    )
    return {
        "flow_rate": flow_rate,
        "active_heads": active_heads,
        "speed_pixels": speed_pixels,
        "paused": value["paused"],
        "exit_width_pixels": exit_width_pixels,
    }


def active_heads_for_flow_rate(flow_rate: float) -> int:
    """Mirror GPUFlowStage2D._flow_line_target_count for upstream scenes."""
    rate = min(max(float(flow_rate), 0.0), 1.0)
    if rate <= 0.0:
        return 0
    if rate <= FLOW_DENSITY_LOW_RATE:
        value = FLOW_DENSITY_LOW_LINE_COUNT * rate / FLOW_DENSITY_LOW_RATE
    else:
        value = FLOW_DENSITY_LOW_LINE_COUNT + (
            (UPSTREAM_PARTICLE_SLOTS - FLOW_DENSITY_LOW_LINE_COUNT)
            * (rate - FLOW_DENSITY_LOW_RATE)
            / (1.0 - FLOW_DENSITY_LOW_RATE)
        )
    # Godot roundi() rounds positive halves away from zero.
    return min(max(int(math.floor(value + 0.5)), 0), UPSTREAM_PARTICLE_SLOTS)


def validate_ack(
    acknowledgement,
    host: UpstreamHost,
    request_id: str,
) -> dict[str, dict]:
    if not isinstance(acknowledgement, dict):
        raise AckValidationError("ACK must be an object")
    if acknowledgement.get("protocol") != FLOW_ACK_PROTOCOL:
        raise AckValidationError("ACK protocol mismatch")
    if acknowledgement.get("request_id") != request_id:
        raise AckValidationError("ACK request_id mismatch")
    if acknowledgement.get("accepted") is not True:
        reason = acknowledgement.get("reason", "request rejected")
        raise AckValidationError(f"ACK rejected the request: {reason}")

    expected_screens = sorted(host.screens)
    recipient_ids = acknowledgement.get("recipient_screen_ids")
    if not isinstance(recipient_ids, list) or sorted(recipient_ids) != expected_screens:
        raise AckValidationError("ACK recipient_screen_ids mismatch")
    recipient_count = acknowledgement.get("recipient_count")
    if (
        isinstance(recipient_count, bool)
        or not isinstance(recipient_count, int)
        or recipient_count != len(expected_screens)
    ):
        raise AckValidationError("ACK recipient_count mismatch")

    ack_states = acknowledgement.get(WATER_ACK_FIELD)
    if not isinstance(ack_states, dict) or set(ack_states) != set(expected_screens):
        raise AckValidationError(f"ACK {WATER_ACK_FIELD} keys mismatch")
    water_states = {}
    for screen_id in expected_screens:
        ack_state = ack_states[screen_id]
        if not isinstance(ack_state, dict):
            raise AckValidationError(f"ACK state for {screen_id} must be an object")
        observation = ack_state.get("current_observation")
        if not isinstance(observation, dict):
            raise AckValidationError(
                f"ACK current_observation for {screen_id} must be an object"
            )
        if observation.get("screen_id") != screen_id:
            raise AckValidationError(f"ACK observation screen_id mismatch for {screen_id}")
        flow_rate = _finite_number(
            observation.get("flow_rate"), "flow_rate", 0.0, 1.0
        )
        water_states[screen_id] = {
            "flow_rate": flow_rate,
            "active_heads": active_heads_for_flow_rate(flow_rate),
            "speed_pixels": UPSTREAM_FLOW_SPEED_PIXELS
            * max(flow_rate, UPSTREAM_MIN_ACTIVE_FLOW),
            "paused": False,
            "exit_width_pixels": exit_width_pixels_for_flow_rate(flow_rate),
        }
    return water_states


def _validate_base_flow_ack(
    acknowledgement,
    endpoint: UpstreamHost,
    request_id: str,
) -> None:
    if not isinstance(acknowledgement, dict):
        raise AckValidationError("ACK must be an object")
    if acknowledgement.get("protocol") != FLOW_ACK_PROTOCOL:
        raise AckValidationError("ACK protocol mismatch")
    if acknowledgement.get("request_id") != request_id:
        raise AckValidationError("ACK request_id mismatch")
    if acknowledgement.get("accepted") is not True:
        reason = acknowledgement.get("reason", "request rejected")
        raise AckValidationError(f"ACK rejected the request: {reason}")
    expected_screens = sorted(endpoint.screens)
    recipient_ids = acknowledgement.get("recipient_screen_ids")
    if not isinstance(recipient_ids, list) or sorted(recipient_ids) != expected_screens:
        raise AckValidationError("ACK recipient_screen_ids mismatch")
    recipient_count = acknowledgement.get("recipient_count")
    if (
        isinstance(recipient_count, bool)
        or not isinstance(recipient_count, int)
        or recipient_count != len(expected_screens)
    ):
        raise AckValidationError("ACK recipient_count mismatch")


def build_event_ack_token(event: dict, recipient_screen_ids=None) -> dict:
    recipients = (
        event.get("target_screens")
        if recipient_screen_ids is None
        else recipient_screen_ids
    )
    if not isinstance(recipients, list) or not recipients:
        raise AckValidationError("event acknowledgement recipients are invalid")
    return {
        "source_session": event.get("session"),
        "source_screen": event.get("source_screen"),
        "event_id": event.get("event_id"),
        "recipient_screen_ids": list(recipients),
    }


def event_ack_key(token: dict) -> str:
    return json.dumps(token, sort_keys=True, separators=(",", ":"))


def build_event_poll_request(
    endpoint: UpstreamHost,
    request_id: str,
    event_acks: list[dict],
    max_events: int = PARTICLE_EVENT_PAGE_MAX,
) -> dict:
    if not request_id or len(request_id) > MAX_TEXT_FIELD_LENGTH:
        raise ValueError("request_id must contain 1..128 characters")
    if not 1 <= max_events <= PARTICLE_EVENT_PAGE_MAX:
        raise ValueError("max_events is outside the bridge page bound")
    if len(event_acks) > PARTICLE_EVENT_PAGE_MAX:
        raise ValueError("event_acks exceeds the bridge page bound")
    return {
        "protocol": FLOW_PROTOCOL,
        "target": sorted(endpoint.screens),
        "changes": {},
        "geometry_ops": [],
        "actions": [],
        "metadata": {
            "source": "confluence-water-bridge",
            "command": "particle-confluence-event-poll",
            "request_id": request_id,
        },
        PARTICLE_BRIDGE_FIELD: {
            "op": "poll",
            "event_acks": [dict(token) for token in event_acks],
            "max_events": max_events,
        },
    }


def validate_particle_event(event, source_endpoint: UpstreamHost) -> UpstreamHost:
    if not isinstance(event, dict):
        raise AckValidationError("particle event must be an object")
    particle_type = event.get("particle_type")
    expected_fields = {
        "protocol",
        "kind",
        "session",
        "event_id",
        "seq",
        "source_screen",
        "target_screens",
        "particle_type",
        "subtype",
        "count",
        "transit_delay_seconds",
    }
    if particle_type == "salmon":
        expected_fields.update({"origin_count", "destination_screen"})
    if set(event) != expected_fields:
        raise AckValidationError("particle event fields do not match its type")
    if event.get("protocol") != CONFLUENCE_PROTOCOL or event.get("kind") != "particle_batch":
        raise AckValidationError("particle event protocol or kind mismatch")
    for field in ("session", "event_id", "source_screen", "subtype"):
        value = event.get(field)
        if not isinstance(value, str) or not value or len(value) > MAX_TEXT_FIELD_LENGTH:
            raise AckValidationError(f"particle event {field} is invalid")
    source_screen = event["source_screen"]
    if source_screen not in source_endpoint.screens:
        raise AckValidationError("particle event source is not owned by polled host")
    sequence = event.get("seq")
    if isinstance(sequence, bool) or not isinstance(sequence, int) or sequence < 0:
        raise AckValidationError("particle event seq must be nonnegative integer")
    targets = event.get("target_screens")
    if (
        not isinstance(targets, list)
        or len(targets) != 1
        or not isinstance(targets[0], str)
        or targets[0] not in SCREEN_DESTINATIONS
    ):
        raise AckValidationError("particle event target_screens is invalid")
    subtype = event["subtype"]
    if subtype not in ALLOWED_PARTICLE_SUBTYPES:
        raise AckValidationError("particle event subtype is unsupported")
    count = event.get("count")
    if (
        isinstance(count, bool)
        or not isinstance(count, int)
        or not 1 <= count <= MAX_PARTICLE_EVENT_COUNT
    ):
        raise AckValidationError("particle event count is outside 1..300")
    delay = event.get("transit_delay_seconds")
    _finite_number(delay, "transit_delay_seconds", 0.0, float("inf"))

    destination_screen = targets[0]
    if particle_type in {"leaf", "pollution"}:
        if source_screen == DELTA_SCREEN or destination_screen != DELTA_SCREEN:
            raise AckValidationError("leaf/pollution event direction is invalid")
    elif particle_type == "salmon":
        if (
            source_screen != DELTA_SCREEN
            or destination_screen == DELTA_SCREEN
            or event.get("origin_count") != SALMON_ORIGIN_COUNT
            or count > SALMON_ORIGIN_COUNT
            or event.get("destination_screen") != destination_screen
        ):
            raise AckValidationError("salmon event cohort or destination is invalid")
    else:
        raise AckValidationError("particle event type is unsupported")
    destination_ip = SCREEN_DESTINATIONS[destination_screen]
    return UpstreamHost(destination_ip, (destination_screen,))


def _validate_source_ack_results(sent_tokens: list[dict], results) -> tuple[set[str], set[str]]:
    if not isinstance(results, list) or len(results) != len(sent_tokens):
        raise AckValidationError("particle poll ack_results count mismatch")
    tokens_by_identity = {
        (
            token["source_session"],
            token["source_screen"],
            token["event_id"],
        ): token
        for token in sent_tokens
    }
    confirmed: set[str] = set()
    terminal: set[str] = set()
    seen = set()
    for result in results:
        if not isinstance(result, dict):
            raise AckValidationError("particle poll ack_result must be an object")
        identity = (
            result.get("source_session"),
            result.get("source_screen"),
            result.get("event_id"),
        )
        if identity not in tokens_by_identity or identity in seen:
            raise AckValidationError("particle poll ack_result identity mismatch")
        seen.add(identity)
        token = tokens_by_identity[identity]
        recipients = result.get("recipient_screen_ids")
        if recipients != token["recipient_screen_ids"]:
            raise AckValidationError("particle poll ack_result recipients mismatch")
        status = result.get("status")
        accepted = result.get("accepted")
        if not isinstance(accepted, bool) or not isinstance(status, str):
            raise AckValidationError("particle poll ack_result status is invalid")
        key = event_ack_key(token)
        if accepted and status in SOURCE_ACK_SUCCESS_STATUSES:
            confirmed.add(key)
        elif not accepted and status in SOURCE_ACK_TERMINAL_STATUSES:
            terminal.add(key)
        elif accepted or status not in {"recipient_mismatch"}:
            raise AckValidationError("particle poll ack_result acceptance is inconsistent")
    return confirmed, terminal


def validate_event_poll_ack(
    acknowledgement,
    endpoint: UpstreamHost,
    request_id: str,
    sent_tokens: list[dict],
    max_events: int = PARTICLE_EVENT_PAGE_MAX,
) -> dict:
    _validate_base_flow_ack(acknowledgement, endpoint, request_id)
    body = acknowledgement.get(PARTICLE_BRIDGE_FIELD)
    if not isinstance(body, dict) or body.get("accepted") is not True or body.get("op") != "poll":
        raise AckValidationError("particle poll ACK body was rejected or malformed")
    if body.get("recipient_count") != len(endpoint.screens):
        raise AckValidationError("particle poll body recipient_count mismatch")
    source_session = body.get("source_session")
    if (
        not isinstance(source_session, str)
        or not source_session
        or len(source_session) > MAX_TEXT_FIELD_LENGTH
    ):
        raise AckValidationError("particle poll source_session is invalid")
    if body.get("max_events") != max_events:
        raise AckValidationError("particle poll max_events mismatch")
    pending_count = body.get("pending_event_count")
    if (
        isinstance(pending_count, bool)
        or not isinstance(pending_count, int)
        or not 0 <= pending_count <= 256
    ):
        raise AckValidationError("particle poll pending_event_count is invalid")
    events = body.get("events")
    if not isinstance(events, list) or len(events) > max_events:
        raise AckValidationError("particle poll events exceed the page bound")
    confirmed, terminal = _validate_source_ack_results(
        sent_tokens,
        body.get("ack_results"),
    )
    event_keys = set()
    destinations = []
    for event in events:
        destination = validate_particle_event(event, endpoint)
        if event.get("session") != source_session:
            raise AckValidationError("particle event session differs from source poll")
        identity = (
            event["session"],
            event["source_screen"],
            event["event_id"],
        )
        if identity in event_keys:
            raise AckValidationError("particle poll repeated one event identity")
        event_keys.add(identity)
        destinations.append(destination)
    return {
        "events": events,
        "destinations": destinations,
        "confirmed_ack_keys": confirmed,
        "terminal_ack_keys": terminal,
        "pending_event_count": pending_count,
        "source_session": source_session,
    }


def build_event_delivery_request(event: dict, request_id: str) -> dict:
    if not request_id or len(request_id) > MAX_TEXT_FIELD_LENGTH:
        raise ValueError("request_id must contain 1..128 characters")
    targets = event.get("target_screens")
    if not isinstance(targets, list) or not targets:
        raise AckValidationError("delivery event targets are invalid")
    return {
        "protocol": FLOW_PROTOCOL,
        "target": list(targets),
        "changes": {},
        "geometry_ops": [],
        "actions": [],
        "metadata": {
            "source": "confluence-water-bridge",
            "command": "particle-confluence-event-deliver",
            "request_id": request_id,
        },
        PARTICLE_BRIDGE_FIELD: {"op": "deliver", "event": event},
    }


def validate_event_delivery_ack(
    acknowledgement,
    destination: UpstreamHost,
    request_id: str,
    event: dict,
) -> dict:
    _validate_base_flow_ack(acknowledgement, destination, request_id)
    body = acknowledgement.get(PARTICLE_BRIDGE_FIELD)
    if not isinstance(body, dict) or body.get("accepted") is not True or body.get("op") != "deliver":
        raise AckValidationError("particle delivery ACK body was rejected or malformed")
    if body.get("recipient_count") != len(destination.screens):
        raise AckValidationError("particle delivery body recipient_count mismatch")
    recipients = event["target_screens"]
    if (
        body.get("status") not in PARTICLE_DELIVERY_SUCCESS_STATUSES
        or body.get("source_session") != event["session"]
        or body.get("source_screen") != event["source_screen"]
        or body.get("event_id") != event["event_id"]
        or body.get("recipient_screen_ids") != recipients
    ):
        raise AckValidationError("particle delivery ACK identity or recipients mismatch")
    return build_event_ack_token(event, recipients)


def build_water_packet(
    source_screen: str,
    water_state: dict,
    session: str,
    sequence: int,
) -> dict:
    if not session or len(session) > 128:
        raise ValueError("session must contain 1..128 characters")
    if sequence < 0:
        raise ValueError("sequence must be nonnegative")
    return {
        "protocol": CONFLUENCE_PROTOCOL,
        "kind": "water_state",
        "session": session,
        "seq": sequence,
        "source_screen": source_screen,
        "target_screen": DELTA_SCREEN,
        "water": validate_water_state(water_state, source_screen),
    }


@dataclass(frozen=True)
class WaterTransitSample:
    """One atomic upstream state change at its traveled-distance coordinate."""

    distance_pixels: float
    observed_at: float
    water_state: dict


class WaterTransitHistory:
    """Bounded, order-preserving screen-distance delay for one water source.

    The first valid snapshot is an immediate steady-state baseline.  Later
    changes become visible only after the source's cumulative reported motion
    has advanced one 1920-pixel screen.  Advancing with the previously observed
    speed makes speed, rate, density, pause state, and width arrive atomically
    without allowing a later fast sample to overtake an earlier slow sample.
    """

    def __init__(
        self,
        source_screen: str,
        *,
        transit_distance_pixels: float = WATER_TRANSIT_DISTANCE_PIXELS,
        max_samples: int = MAX_WATER_TRANSIT_SAMPLES,
    ) -> None:
        if not source_screen:
            raise ValueError("source_screen must not be empty")
        if (
            isinstance(transit_distance_pixels, bool)
            or not isinstance(transit_distance_pixels, (int, float))
            or not math.isfinite(transit_distance_pixels)
            or transit_distance_pixels <= 0.0
        ):
            raise ValueError("transit_distance_pixels must be finite and positive")
        if (
            isinstance(max_samples, bool)
            or not isinstance(max_samples, int)
            or max_samples < 1
        ):
            raise ValueError("max_samples must be positive")
        self.source_screen = source_screen
        self.transit_distance_pixels = float(transit_distance_pixels)
        self.max_samples = int(max_samples)
        self.distance_pixels = 0.0
        self.history_drops = 0
        self.samples_coalesced = 0
        self._last_advanced_at: Optional[float] = None
        self._source_state: Optional[dict] = None
        self._output_state: Optional[dict] = None
        self._output_observed_at: Optional[float] = None
        self._pending: list[WaterTransitSample] = []

    @staticmethod
    def _validate_now(now: float) -> float:
        if isinstance(now, bool) or not isinstance(now, (int, float)):
            raise ValueError("transit clock value must be numeric")
        normalized = float(now)
        if not math.isfinite(normalized):
            raise ValueError("transit clock value must be finite")
        return normalized

    def advance(self, now: float) -> Optional[dict]:
        """Advance distance with the last source speed and return current output."""
        current_time = self._validate_now(now)
        if self._last_advanced_at is None:
            self._last_advanced_at = current_time
        else:
            if current_time < self._last_advanced_at:
                raise ValueError("transit clock moved backwards")
            elapsed = current_time - self._last_advanced_at
            if self._source_state is not None and elapsed > 0.0:
                # paused is delayed as part of the atomic state.  The reported
                # speed remains the deterministic propagation clock so a pause
                # snapshot cannot permanently strand itself in the history.
                self.distance_pixels += (
                    float(self._source_state["speed_pixels"]) * elapsed
                )
            self._last_advanced_at = current_time
        self._release_arrived()
        return self.output_state()

    def observe(self, water_state: dict, now: float) -> Optional[dict]:
        """Record one validated snapshot after first advancing to ``now``."""
        current_time = self._validate_now(now)
        self.advance(current_time)
        normalized = validate_water_state(water_state, self.source_screen)
        if self._source_state is None:
            # A restarted bridge does not make an already-running installation
            # wait a screen-length before water returns.  This snapshot defines
            # the steady-state baseline; only subsequent changes are delayed.
            self._source_state = normalized
            self._output_state = normalized
            self._output_observed_at = current_time
            return self.output_state()
        if normalized == self._source_state:
            return self.output_state()

        self._source_state = normalized
        sample = WaterTransitSample(
            self.distance_pixels,
            current_time,
            normalized,
        )
        if (
            self._pending
            and math.isclose(
                self._pending[-1].distance_pixels,
                sample.distance_pixels,
                rel_tol=0.0,
                abs_tol=1.0e-9,
            )
        ):
            # Multiple changes while reported speed is zero have zero spatial
            # extent.  Only the newest can be visible when that coordinate
            # eventually reaches Delta.
            self._pending[-1] = sample
            self.samples_coalesced += 1
        else:
            self._pending.append(sample)
        if len(self._pending) > self.max_samples:
            overflow = len(self._pending) - self.max_samples
            del self._pending[:overflow]
            self.history_drops += overflow
        self._release_arrived()
        return self.output_state()

    def _release_arrived(self) -> None:
        arrival_cutoff = self.distance_pixels - self.transit_distance_pixels
        while (
            self._pending
            and self._pending[0].distance_pixels <= arrival_cutoff + 1.0e-9
        ):
            sample = self._pending.pop(0)
            self._output_state = sample.water_state
            self._output_observed_at = sample.observed_at

    def output_state(self) -> Optional[dict]:
        return None if self._output_state is None else dict(self._output_state)

    def runtime_summary(self, now: float) -> dict:
        current_time = self._validate_now(now)
        output_age = 0.0
        if self._output_observed_at is not None:
            output_age = max(current_time - self._output_observed_at, 0.0)
        oldest_pending_age = 0.0
        if self._pending:
            oldest_pending_age = max(
                current_time - self._pending[0].observed_at,
                0.0,
            )
        next_distance = 0.0
        if self._pending:
            next_distance = max(
                self._pending[0].distance_pixels
                + self.transit_distance_pixels
                - self.distance_pixels,
                0.0,
            )
        return {
            "baseline_established": self._output_state is not None,
            "pending_samples": len(self._pending),
            "distance_pixels": self.distance_pixels,
            "next_arrival_distance_pixels": next_distance,
            "output_observation_age_seconds": output_age,
            "oldest_pending_age_seconds": oldest_pending_age,
            "history_drops": self.history_drops,
            "samples_coalesced": self.samples_coalesced,
        }


class ConfluenceWaterBridge:
    def __init__(
        self,
        *,
        hosts: tuple[UpstreamHost, ...] = UPSTREAM_HOSTS,
        interval_seconds: float = DEFAULT_INTERVAL_SECONDS,
        ack_timeout_seconds: float = DEFAULT_ACK_TIMEOUT_SECONDS,
        session: Optional[str] = None,
        query_socket: Optional[socket.socket] = None,
        injection_socket: Optional[socket.socket] = None,
        clock: Callable[[], float] = time.monotonic,
        transit_distance_pixels: float = WATER_TRANSIT_DISTANCE_PIXELS,
        max_transit_samples: int = MAX_WATER_TRANSIT_SAMPLES,
    ) -> None:
        if interval_seconds <= 0.0:
            raise ValueError("interval_seconds must be positive")
        if not 0.0 < ack_timeout_seconds <= interval_seconds:
            raise ValueError("ack_timeout_seconds must be positive and <= interval")
        self.hosts = hosts
        self.interval_seconds = interval_seconds
        self.ack_timeout_seconds = ack_timeout_seconds
        self.session = session or f"bridge-{uuid.uuid4().hex}"
        self._query_socket = query_socket
        self._injection_socket = injection_socket
        self._owns_query_socket = query_socket is None
        self._owns_injection_socket = injection_socket is None
        self._clock = clock
        self.transit_distance_pixels = float(transit_distance_pixels)
        self._sequences = {screen: 0 for host in hosts for screen in host.screens}
        self._water_transit = {
            screen: WaterTransitHistory(
                screen,
                transit_distance_pixels=transit_distance_pixels,
                max_samples=max_transit_samples,
            )
            for host in hosts
            for screen in host.screens
        }
        self.cycles = 0
        self.host_acks = 0
        self.sources_injected = 0

    def open(self) -> None:
        if self._query_socket is None:
            self._query_socket = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            self._query_socket.bind(("", 0))
            self._query_socket.setblocking(False)
        if self._injection_socket is None:
            self._injection_socket = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)

    def close(self) -> None:
        if self._owns_query_socket and self._query_socket is not None:
            self._query_socket.close()
        if self._owns_injection_socket and self._injection_socket is not None:
            self._injection_socket.close()
        self._query_socket = None
        self._injection_socket = None

    def __enter__(self) -> "ConfluenceWaterBridge":
        self.open()
        return self

    def __exit__(self, _exc_type, _exc_value, _traceback) -> None:
        self.close()

    def _inject(self, source_screen: str, water_state: dict) -> None:
        sequence = self._sequences[source_screen]
        self._sequences[source_screen] = sequence + 1
        encoded = compact_json(
            build_water_packet(source_screen, water_state, self.session, sequence)
        )
        sent = self._injection_socket.sendto(
            encoded,
            ("127.0.0.1", CONFLUENCE_PORT),
        )
        if sent != len(encoded):
            raise OSError(f"loopback injection sent only {sent} of {len(encoded)} bytes")
        self.sources_injected += 1

    def poll_once(self) -> dict:
        self.open()
        requests: dict[str, tuple[UpstreamHost, str]] = {}
        errors: dict[str, str] = {}
        states_by_host: dict[str, dict[str, dict]] = {}
        for host in self.hosts:
            request_id = uuid.uuid4().hex
            encoded = compact_json(build_poll_request(host, request_id))
            sent = self._query_socket.sendto(encoded, (host.ip, FLOW_CONTROL_PORT))
            if sent != len(encoded):
                errors[host.ip] = f"sent only {sent} of {len(encoded)} query bytes"
                continue
            requests[host.ip] = (host, request_id)

        pending = set(requests)
        deadline = self._clock() + self.ack_timeout_seconds
        while pending:
            remaining = deadline - self._clock()
            if remaining <= 0.0:
                break
            readable, _writable, _exceptional = select.select(
                [self._query_socket], [], [], remaining
            )
            if not readable:
                break
            try:
                raw_ack, sender = self._query_socket.recvfrom(MAX_DATAGRAM_BYTES)
            except BlockingIOError:
                continue
            sender_ip = sender[0]
            if sender_ip not in pending:
                continue
            if sender[1] != FLOW_CONTROL_PORT:
                errors[sender_ip] = "ACK source port mismatch"
                continue
            host, request_id = requests[sender_ip]
            try:
                acknowledgement = json.loads(raw_ack.decode("utf-8"))
                states_by_host[sender_ip] = validate_ack(
                    acknowledgement, host, request_id
                )
            except (UnicodeDecodeError, json.JSONDecodeError, AckValidationError) as error:
                errors[sender_ip] = str(error)
                continue
            pending.remove(sender_ip)
            errors.pop(sender_ip, None)
            self.host_acks += 1

        for sender_ip in pending:
            errors.setdefault(sender_ip, "timed out waiting for a valid ACK")

        transit_now = self._clock()
        injected: list[str] = []
        for host in self.hosts:
            host_states = states_by_host.get(host.ip, {})
            for screen_id in host.screens:
                history = self._water_transit[screen_id]
                water_state = host_states.get(screen_id)
                try:
                    delayed_state = (
                        history.observe(water_state, transit_now)
                        if water_state is not None
                        else history.advance(transit_now)
                    )
                except (AckValidationError, ValueError) as error:
                    errors[host.ip] = f"water transit failed: {error}"
                    continue
                # Keep the internal distance clock moving through a missed
                # poll, but do not refresh Delta with cached data.  Silence on
                # the wire preserves ParticleConfluenceBus's two-second stale
                # source detection and dormant fallback.
                if water_state is None:
                    continue
                if delayed_state is None:
                    continue
                try:
                    self._inject(screen_id, delayed_state)
                except OSError as error:
                    errors[host.ip] = f"loopback injection failed: {error}"
                    continue
                injected.append(screen_id)

        self.cycles += 1
        transit_summary = {
            screen_id: history.runtime_summary(transit_now)
            for screen_id, history in self._water_transit.items()
        }
        return {
            "cycle": self.cycles,
            "hosts_ok": len(states_by_host),
            "hosts_expected": len(self.hosts),
            "sources_injected": sorted(injected),
            "water_transit_distance_pixels": self.transit_distance_pixels,
            "water_transit": transit_summary,
            "water_transit_history_drops": sum(
                int(summary["history_drops"])
                for summary in transit_summary.values()
            ),
            "errors": errors,
            "session": self.session,
        }


class ParticleEventBridge:
    """Reliably relay immutable particle events through FlowControl replies."""

    def __init__(
        self,
        *,
        sources: tuple[UpstreamHost, ...] = EVENT_SOURCE_HOSTS,
        ack_timeout_seconds: float = DEFAULT_ACK_TIMEOUT_SECONDS,
        event_socket: Optional[socket.socket] = None,
        clock: Callable[[], float] = time.monotonic,
    ) -> None:
        if ack_timeout_seconds <= 0.0:
            raise ValueError("ack_timeout_seconds must be positive")
        self.sources = sources
        self.ack_timeout_seconds = ack_timeout_seconds
        self._event_socket = event_socket
        self._owns_socket = event_socket is None
        self._clock = clock
        self._pending_source_acks: dict[str, dict[str, dict]] = {
            source.ip: {} for source in sources
        }
        self.cycles = 0
        self.events_received = 0
        self.events_delivered = 0

    def open(self) -> None:
        if self._event_socket is None:
            self._event_socket = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            self._event_socket.bind(("", 0))
            self._event_socket.setblocking(False)

    def close(self) -> None:
        if self._owns_socket and self._event_socket is not None:
            self._event_socket.close()
        self._event_socket = None

    def __enter__(self) -> "ParticleEventBridge":
        self.open()
        return self

    def __exit__(self, _exc_type, _exc_value, _traceback) -> None:
        self.close()

    def _exchange(self, records: list[dict]) -> tuple[dict[str, dict], dict[str, str]]:
        self.open()
        pending: dict[str, dict] = {}
        responses: dict[str, dict] = {}
        errors: dict[str, str] = {}
        for record in records:
            request_id = record["request_id"]
            encoded = compact_json(record["request"])
            try:
                sent = self._event_socket.sendto(
                    encoded,
                    (record["endpoint"].ip, FLOW_CONTROL_PORT),
                )
            except OSError as error:
                errors[request_id] = f"send failed: {error}"
                continue
            if sent != len(encoded):
                errors[request_id] = f"sent only {sent} of {len(encoded)} bytes"
                continue
            pending[request_id] = record

        deadline = self._clock() + self.ack_timeout_seconds
        while pending:
            remaining = deadline - self._clock()
            if remaining <= 0.0:
                break
            try:
                readable, _writable, _exceptional = select.select(
                    [self._event_socket], [], [], remaining
                )
            except OSError as error:
                for request_id in pending:
                    errors.setdefault(request_id, f"receive select failed: {error}")
                break
            if not readable:
                break
            try:
                raw_ack, sender = self._event_socket.recvfrom(MAX_DATAGRAM_BYTES)
            except BlockingIOError:
                continue
            except OSError as error:
                for request_id in pending:
                    errors.setdefault(request_id, f"receive failed: {error}")
                break
            try:
                acknowledgement = json.loads(raw_ack.decode("utf-8"))
            except (UnicodeDecodeError, json.JSONDecodeError):
                continue
            if not isinstance(acknowledgement, dict):
                continue
            request_id = acknowledgement.get("request_id")
            if request_id not in pending:
                continue
            expected = pending[request_id]["endpoint"]
            if sender != (expected.ip, FLOW_CONTROL_PORT):
                errors[request_id] = "ACK sender address mismatch"
                continue
            responses[request_id] = acknowledgement
            pending.pop(request_id)
            errors.pop(request_id, None)
        for request_id in pending:
            errors.setdefault(request_id, "timed out waiting for a valid ACK")
        return responses, errors

    def _source_ack_page(self, endpoint: UpstreamHost) -> list[dict]:
        values = self._pending_source_acks.setdefault(endpoint.ip, {}).values()
        return [dict(token) for token in list(values)[:PARTICLE_EVENT_PAGE_MAX]]

    def _remove_source_ack_keys(self, endpoint: UpstreamHost, keys: set[str]) -> None:
        pending = self._pending_source_acks.setdefault(endpoint.ip, {})
        for key in keys:
            pending.pop(key, None)

    def _queue_source_ack(self, endpoint: UpstreamHost, token: dict) -> bool:
        key = event_ack_key(token)
        pending = self._pending_source_acks.setdefault(endpoint.ip, {})
        if key in pending:
            return True
        total = sum(len(values) for values in self._pending_source_acks.values())
        if total >= MAX_PENDING_SOURCE_ACKS:
            return False
        pending[key] = dict(token)
        return True

    def cycle_once(self) -> dict:
        self.open()
        errors: dict[str, str] = {}
        poll_records = []
        poll_context: dict[str, tuple[UpstreamHost, list[dict]]] = {}
        for source in self.sources:
            request_id = uuid.uuid4().hex
            ack_page = self._source_ack_page(source)
            request = build_event_poll_request(source, request_id, ack_page)
            poll_records.append({
                "request_id": request_id,
                "endpoint": source,
                "request": request,
            })
            poll_context[request_id] = (source, ack_page)

        poll_responses, poll_errors = self._exchange(poll_records)
        source_polls_ok = 0
        events_to_deliver: list[tuple[dict, UpstreamHost, UpstreamHost]] = []
        for request_id, (source, ack_page) in poll_context.items():
            label = f"poll:{source.ip}"
            if request_id in poll_errors:
                errors[label] = poll_errors[request_id]
                continue
            try:
                result = validate_event_poll_ack(
                    poll_responses.get(request_id),
                    source,
                    request_id,
                    ack_page,
                )
            except AckValidationError as error:
                errors[label] = str(error)
                continue
            self._remove_source_ack_keys(
                source,
                result["confirmed_ack_keys"] | result["terminal_ack_keys"],
            )
            if result["terminal_ack_keys"]:
                errors[label] = "source discarded stale or unknown event acknowledgement"
            source_polls_ok += 1
            for event, destination in zip(
                result["events"],
                result["destinations"],
            ):
                events_to_deliver.append((event, source, destination))
                self.events_received += 1

        delivery_records = []
        delivery_context: dict[str, tuple[dict, UpstreamHost, UpstreamHost]] = {}
        for event, source, destination in events_to_deliver:
            request_id = uuid.uuid4().hex
            request = build_event_delivery_request(event, request_id)
            delivery_records.append({
                "request_id": request_id,
                "endpoint": destination,
                "request": request,
            })
            delivery_context[request_id] = (event, source, destination)

        delivery_responses, delivery_errors = self._exchange(delivery_records)
        delivered_ids = []
        for request_id, (event, source, destination) in delivery_context.items():
            label = f"deliver:{event['source_screen']}:{event['event_id']}"
            if request_id in delivery_errors:
                errors[label] = delivery_errors[request_id]
                continue
            try:
                token = validate_event_delivery_ack(
                    delivery_responses.get(request_id),
                    destination,
                    request_id,
                    event,
                )
            except AckValidationError as error:
                errors[label] = str(error)
                continue
            if not self._queue_source_ack(source, token):
                errors[label] = "source acknowledgement queue is full"
                continue
            delivered_ids.append(event["event_id"])
            self.events_delivered += 1

        self.cycles += 1
        return {
            "cycle": self.cycles,
            "source_polls_ok": source_polls_ok,
            "source_polls_expected": len(self.sources),
            "events_received": len(events_to_deliver),
            "events_delivered": len(delivered_ids),
            "delivered_event_ids": delivered_ids,
            "pending_source_ack_count": sum(
                len(values) for values in self._pending_source_acks.values()
            ),
            "errors": errors,
        }


def _render_result(result: dict) -> str:
    return json.dumps(result, sort_keys=True, separators=(",", ":"))


def run_forever(
    bridge: ConfluenceWaterBridge,
    quiet: bool = False,
    event_bridge: Optional[ParticleEventBridge] = None,
) -> int:
    stopping = False
    event_stop = threading.Event()

    def request_stop(_signal_number, _frame) -> None:
        nonlocal stopping
        stopping = True
        event_stop.set()

    def run_events() -> None:
        next_cycle = time.monotonic()
        last_error_signature = ""
        last_error_printed = 0.0
        try:
            while not event_stop.is_set():
                try:
                    result = event_bridge.cycle_once()
                except Exception as error:
                    result = {"errors": {"event_bridge": str(error)}}
                now = time.monotonic()
                if result["errors"]:
                    signature = _render_result(result["errors"])
                    if signature != last_error_signature or now - last_error_printed >= 5.0:
                        print(_render_result(result), file=sys.stderr, flush=True)
                        last_error_signature = signature
                        last_error_printed = now
                elif not quiet and (
                    event_bridge.cycles == 1 or event_bridge.cycles % 50 == 0
                ):
                    print(_render_result({"particle_events": result}), flush=True)
                    last_error_signature = ""
                next_cycle += bridge.interval_seconds
                remaining = next_cycle - time.monotonic()
                if remaining > 0.0:
                    event_stop.wait(remaining)
                else:
                    next_cycle = time.monotonic()
        finally:
            event_bridge.close()

    signal.signal(signal.SIGINT, request_stop)
    signal.signal(signal.SIGTERM, request_stop)
    event_thread = None
    if event_bridge is not None:
        event_thread = threading.Thread(
            target=run_events,
            name="particle-confluence-event-bridge",
            daemon=True,
        )
        event_thread.start()
    next_cycle = time.monotonic()
    last_error_signature = ""
    last_error_printed = 0.0
    try:
        with bridge:
            while not stopping:
                result = bridge.poll_once()
                now = time.monotonic()
                if result["errors"]:
                    signature = _render_result(result["errors"])
                    if signature != last_error_signature or now - last_error_printed >= 5.0:
                        print(_render_result(result), file=sys.stderr, flush=True)
                        last_error_signature = signature
                        last_error_printed = now
                elif not quiet and (bridge.cycles == 1 or bridge.cycles % 50 == 0):
                    print(_render_result(result), flush=True)
                    last_error_signature = ""
                next_cycle += bridge.interval_seconds
                remaining = next_cycle - time.monotonic()
                if remaining > 0.0:
                    time.sleep(remaining)
                else:
                    next_cycle = time.monotonic()
    finally:
        event_stop.set()
        if event_thread is not None:
            event_thread.join(timeout=2.0)
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--once", action="store_true", help="poll once and exit")
    parser.add_argument("--quiet", action="store_true", help="suppress healthy summaries")
    parser.add_argument(
        "--interval",
        type=float,
        default=DEFAULT_INTERVAL_SECONDS,
        help="poll interval in seconds (default: 0.2)",
    )
    parser.add_argument(
        "--ack-timeout",
        type=float,
        default=DEFAULT_ACK_TIMEOUT_SECONDS,
        help="per-cycle ACK deadline in seconds (default: 0.15)",
    )
    args = parser.parse_args()
    bridge = ConfluenceWaterBridge(
        interval_seconds=args.interval,
        ack_timeout_seconds=args.ack_timeout,
    )
    event_bridge = ParticleEventBridge(ack_timeout_seconds=args.ack_timeout)
    if args.once:
        with bridge, event_bridge:
            water_result = bridge.poll_once()
            event_result = event_bridge.cycle_once()
        result = {"water": water_result, "particle_events": event_result}
        print(_render_result(result), flush=True)
        expected_sources = sorted(
            screen for host in UPSTREAM_HOSTS for screen in host.screens
        )
        healthy = (
            water_result["hosts_ok"] == water_result["hosts_expected"]
            and water_result["sources_injected"] == expected_sources
            and not water_result["errors"]
            and event_result["source_polls_ok"]
                == event_result["source_polls_expected"]
            and not event_result["errors"]
        )
        return 0 if healthy else 1
    return run_forever(bridge, quiet=args.quiet, event_bridge=event_bridge)


if __name__ == "__main__":
    raise SystemExit(main())
