import json
import unittest
from unittest import mock

from fleet import confluence_water_bridge as bridge


def water(flow_rate=0.5, active_heads=12, speed_pixels=90.0, paused=False):
    return {
        "flow_rate": flow_rate,
        "active_heads": active_heads,
        "speed_pixels": speed_pixels,
        "paused": paused,
    }


def acknowledgement(host, request_id, flow_rates=None):
    flow_rates = flow_rates or {}
    return {
        "protocol": bridge.FLOW_ACK_PROTOCOL,
        "accepted": True,
        "request_id": request_id,
        "recipient_count": len(host.screens),
        "recipient_screen_ids": sorted(host.screens),
        bridge.WATER_ACK_FIELD: {
            screen_id: {
                "current_observation": {
                    "screen_id": screen_id,
                    "flow_rate": flow_rates.get(screen_id, 0.02 + index * 0.03),
                    "model_date_time": "07/01-00:00",
                }
            }
            for index, screen_id in enumerate(host.screens)
        },
    }


def particle_event(
    source_screen,
    session,
    event_id,
    target_screen,
    particle_type,
    count,
    subtype="default",
):
    event = {
        "protocol": bridge.CONFLUENCE_PROTOCOL,
        "kind": "particle_batch",
        "session": session,
        "event_id": event_id,
        "seq": 1,
        "source_screen": source_screen,
        "target_screens": [target_screen],
        "particle_type": particle_type,
        "subtype": subtype,
        "count": count,
        "transit_delay_seconds": 0.0,
    }
    if particle_type == "salmon":
        event["origin_count"] = 25
        event["destination_screen"] = target_screen
    return event


class FakeQuerySocket:
    def __init__(self, reply_port=bridge.FLOW_CONTROL_PORT):
        self.sent = []
        self.replies = []
        self.reply_port = reply_port
        self.flow_rates = {}
        self.respond = True

    def sendto(self, payload, destination):
        self.sent.append((payload, destination))
        request = json.loads(payload.decode("utf-8"))
        host = next(item for item in bridge.UPSTREAM_HOSTS if item.ip == destination[0])
        request_id = request["metadata"]["request_id"]
        encoded_ack = bridge.compact_json(
            acknowledgement(host, request_id, self.flow_rates)
        )
        if self.respond:
            self.replies.append((encoded_ack, (host.ip, self.reply_port)))
        return len(payload)

    def recvfrom(self, _maximum):
        return self.replies.pop(0)


class FakeInjectionSocket:
    def __init__(self):
        self.sent = []

    def sendto(self, payload, destination):
        self.sent.append((payload, destination))
        return len(payload)


class ManualClock:
    def __init__(self, now=0.0):
        self.now = float(now)

    def __call__(self):
        return self.now

    def advance(self, seconds):
        self.now += float(seconds)


class FakeEventSocket:
    def __init__(self, drop_first_event_id=None, drop_first_source_ack_ip=None):
        self.sent = []
        self.replies = []
        self.delivery_attempts = {}
        self.cleared_source_ips = set()
        self.drop_first_event_id = drop_first_event_id
        self.drop_first_source_ack_ip = drop_first_source_ack_ip
        self.source_ack_attempts = {}
        self.events_by_source_ip = {
            "196.168.50.31": particle_event(
                "mill_creek",
                "session-31",
                "mill:pollution:1",
                "delta",
                "pollution",
                4,
                "material",
            ),
            "127.0.0.1": particle_event(
                "delta",
                "session-11",
                "delta:salmon:1",
                "mount_shasta",
                "salmon",
                13,
            ),
        }
        self.sessions = {
            "196.168.50.21": "session-21",
            "196.168.50.31": "session-31",
            "196.168.50.41": "session-41",
            "127.0.0.1": "session-11",
        }

    def sendto(self, payload, destination):
        request = json.loads(payload.decode("utf-8"))
        self.sent.append((request, destination))
        request_id = request["metadata"]["request_id"]
        bridge_body = request[bridge.PARTICLE_BRIDGE_FIELD]
        targets = sorted(request["target"])
        if bridge_body["op"] == "poll":
            event_acks = bridge_body["event_acks"]
            source_ack_attempt = 0
            if event_acks:
                source_ack_attempt = self.source_ack_attempts.get(destination[0], 0) + 1
                self.source_ack_attempts[destination[0]] = source_ack_attempt
            ack_results = [
                {
                    "source_session": token["source_session"],
                    "source_screen": token["source_screen"],
                    "event_id": token["event_id"],
                    "recipient_screen_ids": token["recipient_screen_ids"],
                    "accepted": True,
                    "status": (
                        "already_acknowledged"
                        if source_ack_attempt > 1
                        else "acknowledged"
                    ),
                    "reason": "",
                }
                for token in event_acks
            ]
            if event_acks:
                self.cleared_source_ips.add(destination[0])
            event = self.events_by_source_ip.get(destination[0])
            events = (
                []
                if event is None or destination[0] in self.cleared_source_ips
                else [event]
            )
            body = {
                "accepted": True,
                "reason": "",
                "op": "poll",
                "source_session": self.sessions[destination[0]],
                "events": events,
                "pending_event_count": len(events),
                "ack_results": ack_results,
                "max_events": bridge_body["max_events"],
                "recipient_count": len(targets),
            }
            if (
                event_acks
                and destination[0] == self.drop_first_source_ack_ip
                and source_ack_attempt == 1
            ):
                return len(payload)
        else:
            event = bridge_body["event"]
            attempts = self.delivery_attempts.get(event["event_id"], 0) + 1
            self.delivery_attempts[event["event_id"]] = attempts
            if event["event_id"] == self.drop_first_event_id and attempts == 1:
                return len(payload)
            body = {
                "accepted": True,
                "reason": "",
                "op": "deliver",
                "status": "duplicate" if attempts > 1 else "applied",
                "source_session": event["session"],
                "source_screen": event["source_screen"],
                "event_id": event["event_id"],
                "recipient_screen_ids": event["target_screens"],
                "recipient_count": len(targets),
            }
        ack = {
            "protocol": bridge.FLOW_ACK_PROTOCOL,
            "accepted": True,
            "reason": "",
            "request_id": request_id,
            "recipient_count": len(targets),
            "recipient_screen_ids": targets,
            bridge.PARTICLE_BRIDGE_FIELD: body,
        }
        self.replies.append(
            (bridge.compact_json(ack), (destination[0], bridge.FLOW_CONTROL_PORT))
        )
        return len(payload)

    def recvfrom(self, _maximum):
        return self.replies.pop(0)


class BridgeTests(unittest.TestCase):
    def test_poll_request_is_a_targeted_noop(self):
        host = bridge.UPSTREAM_HOSTS[0]
        request = bridge.build_poll_request(host, "water-poll-1")
        self.assertEqual(bridge.FLOW_PROTOCOL, request["protocol"])
        self.assertEqual(list(host.screens), request["target"])
        self.assertEqual({}, request["changes"])
        self.assertEqual([], request["geometry_ops"])
        self.assertEqual([], request["actions"])
        self.assertEqual("water-poll-1", request["metadata"]["request_id"])

    def test_ack_requires_exact_host_screens_and_bounded_water(self):
        host = bridge.UPSTREAM_HOSTS[1]
        ack = acknowledgement(host, "request-31")
        states = bridge.validate_ack(ack, host, "request-31")
        self.assertEqual(set(host.screens), set(states))
        self.assertEqual(30, states[host.screens[0]]["active_heads"])
        self.assertEqual(150.0, states[host.screens[0]]["speed_pixels"])

        wrong_screen = json.loads(json.dumps(ack))
        wrong_screen[bridge.WATER_ACK_FIELD]["delta"] = water()
        with self.assertRaisesRegex(bridge.AckValidationError, "keys mismatch"):
            bridge.validate_ack(wrong_screen, host, "request-31")

        bad_number = json.loads(json.dumps(ack))
        bad_number[bridge.WATER_ACK_FIELD][host.screens[0]][
            "current_observation"
        ]["flow_rate"] = 1.1
        with self.assertRaisesRegex(bridge.AckValidationError, "outside"):
            bridge.validate_ack(bad_number, host, "request-31")

        with self.assertRaisesRegex(bridge.AckValidationError, "request_id"):
            bridge.validate_ack(ack, host, "stale-request")

    def test_water_packet_targets_only_delta_with_stable_session_and_sequence(self):
        packet = bridge.build_water_packet(
            "mount_shasta", water(), "bridge-session", 42
        )
        self.assertEqual(bridge.CONFLUENCE_PROTOCOL, packet["protocol"])
        self.assertEqual("water_state", packet["kind"])
        self.assertEqual("mount_shasta", packet["source_screen"])
        self.assertEqual("delta", packet["target_screen"])
        self.assertEqual("bridge-session", packet["session"])
        self.assertEqual(42, packet["seq"])
        self.assertEqual(512.0, packet["water"]["exit_width_pixels"])

        explicit = water()
        explicit["exit_width_pixels"] = 377.0
        self.assertEqual(
            377.0,
            bridge.build_water_packet(
                "mount_shasta", explicit, "bridge-session", 43
            )["water"]["exit_width_pixels"],
        )
        explicit["exit_width_pixels"] = 1024.01
        with self.assertRaisesRegex(bridge.AckValidationError, "outside"):
            bridge.build_water_packet(
                "mount_shasta", explicit, "bridge-session", 44
            )

    def test_upstream_density_curve_matches_exact_boundaries(self):
        self.assertEqual(0, bridge.active_heads_for_flow_rate(0.0))
        self.assertEqual(10, bridge.active_heads_for_flow_rate(0.005))
        self.assertEqual(20, bridge.active_heads_for_flow_rate(0.01))
        self.assertEqual(1000, bridge.active_heads_for_flow_rate(1.0))
        self.assertEqual(0.0, bridge.exit_width_pixels_for_flow_rate(0.0))
        self.assertEqual(1024.0, bridge.exit_width_pixels_for_flow_rate(1.0))

    def test_distance_history_delays_one_atomic_state_and_preserves_order(self):
        history = bridge.WaterTransitHistory("mount_shasta")
        baseline = water(0.25, 258, 150.0)
        first_change = water(0.40, 416, 150.0)
        second_change = water(0.75, 753, 600.0, paused=True)

        self.assertEqual(0.25, history.observe(baseline, 0.0)["flow_rate"])
        self.assertEqual(0.25, history.observe(first_change, 0.2)["flow_rate"])
        self.assertEqual(0.25, history.observe(second_change, 0.4)["flow_rate"])

        # The later faster snapshot cannot overtake the earlier snapshot.  Both
        # rate and derived width switch together at their distance coordinates.
        before = history.advance(3.549)
        self.assertEqual(0.25, before["flow_rate"])
        first_arrival = history.advance(3.55)
        self.assertEqual(0.40, first_arrival["flow_rate"])
        self.assertEqual(409.6, first_arrival["exit_width_pixels"])
        self.assertEqual(416, first_arrival["active_heads"])
        second_arrival = history.advance(3.60)
        self.assertEqual(0.75, second_arrival["flow_rate"])
        self.assertEqual(768.0, second_arrival["exit_width_pixels"])
        self.assertTrue(second_arrival["paused"])

    def test_distance_history_is_bounded_and_coalesces_zero_speed_changes(self):
        history = bridge.WaterTransitHistory(
            "mill_creek",
            transit_distance_pixels=100000.0,
            max_samples=3,
        )
        history.observe(water(0.1, 1, 1.0), 0.0)
        for index in range(1, 6):
            history.observe(water(index / 10.0, index, 1.0), float(index))
        summary = history.runtime_summary(5.0)
        self.assertEqual(3, summary["pending_samples"])
        self.assertEqual(1, summary["history_drops"])

        stopped = bridge.WaterTransitHistory("cottonwood_creek", max_samples=3)
        stopped.observe(water(0.1, 1, 0.0), 0.0)
        for index in range(2, 8):
            stopped.observe(water(index / 10.0, index, 0.0), float(index))
        stopped_summary = stopped.runtime_summary(7.0)
        self.assertEqual(1, stopped_summary["pending_samples"])
        self.assertEqual(0, stopped_summary["history_drops"])
        self.assertEqual(5, stopped_summary["samples_coalesced"])

    def test_one_cycle_polls_concurrently_and_injects_all_six_on_loopback(self):
        query_socket = FakeQuerySocket()
        injection_socket = FakeInjectionSocket()
        instance = bridge.ConfluenceWaterBridge(
            session="test-session",
            query_socket=query_socket,
            injection_socket=injection_socket,
        )

        def ready(readers, _writers, _errors, _timeout):
            return (readers if query_socket.replies else [], [], [])

        with mock.patch.object(bridge.select, "select", side_effect=ready):
            result = instance.poll_once()

        self.assertEqual(3, len(query_socket.sent))
        self.assertEqual(3, result["hosts_ok"])
        self.assertEqual({}, result["errors"])
        self.assertEqual(6, len(injection_socket.sent))
        decoded = [json.loads(payload) for payload, _destination in injection_socket.sent]
        self.assertEqual(
            {screen for host in bridge.UPSTREAM_HOSTS for screen in host.screens},
            {packet["source_screen"] for packet in decoded},
        )
        self.assertTrue(
            all(destination == ("127.0.0.1", 5007) for _payload, destination in injection_socket.sent)
        )
        self.assertTrue(all(packet["session"] == "test-session" for packet in decoded))
        self.assertTrue(all(packet["seq"] == 0 for packet in decoded))
        self.assertTrue(
            all("exit_width_pixels" in packet["water"] for packet in decoded)
        )

    def test_bridge_delays_changes_but_does_not_mask_stale_poll_failure(self):
        host = bridge.UPSTREAM_HOSTS[0]
        query_socket = FakeQuerySocket()
        injection_socket = FakeInjectionSocket()
        clock = ManualClock()
        query_socket.flow_rates = {screen: 0.25 for screen in host.screens}
        instance = bridge.ConfluenceWaterBridge(
            hosts=(host,),
            session="delayed-water",
            query_socket=query_socket,
            injection_socket=injection_socket,
            clock=clock,
        )

        def ready(readers, _writers, _errors, _timeout):
            return (readers if query_socket.replies else [], [], [])

        with mock.patch.object(bridge.select, "select", side_effect=ready):
            baseline_result = instance.poll_once()
            self.assertEqual(2, len(injection_socket.sent))
            baseline_packets = [
                json.loads(payload) for payload, _destination in injection_socket.sent
            ]
            self.assertTrue(
                all(packet["water"]["flow_rate"] == 0.25 for packet in baseline_packets)
            )
            self.assertTrue(
                all(
                    packet["water"]["exit_width_pixels"] == 256.0
                    for packet in baseline_packets
                )
            )
            self.assertEqual(0, baseline_result["water_transit_history_drops"])

            clock.advance(0.2)
            query_socket.flow_rates = {screen: 0.50 for screen in host.screens}
            instance.poll_once()
            delayed_packets = [
                json.loads(payload)
                for payload, _destination in injection_socket.sent[-2:]
            ]
            self.assertTrue(
                all(packet["water"]["flow_rate"] == 0.25 for packet in delayed_packets)
            )

            # History keeps advancing, but a failed source must be silent on
            # loopback so Delta's two-second stale detector can make it dormant.
            sent_before_failure = len(injection_socket.sent)
            clock.advance(2.1)
            query_socket.respond = False
            failed_result = instance.poll_once()
            self.assertEqual(0, failed_result["hosts_ok"])
            self.assertEqual([], failed_result["sources_injected"])
            self.assertEqual(sent_before_failure, len(injection_socket.sent))

            query_socket.respond = True
            clock.advance(4.3)
            arrival_result = instance.poll_once()
            arrived_packets = [
                json.loads(payload)
                for payload, _destination in injection_socket.sent[-2:]
            ]
            self.assertTrue(
                all(packet["water"]["flow_rate"] == 0.50 for packet in arrived_packets)
            )
            self.assertTrue(
                all(
                    packet["water"]["exit_width_pixels"] == 512.0
                    for packet in arrived_packets
                )
            )
            self.assertEqual({}, arrival_result["errors"])

    def test_ack_from_wrong_source_port_is_never_injected(self):
        query_socket = FakeQuerySocket(reply_port=4999)
        injection_socket = FakeInjectionSocket()
        instance = bridge.ConfluenceWaterBridge(
            hosts=(bridge.UPSTREAM_HOSTS[0],),
            session="wrong-port",
            query_socket=query_socket,
            injection_socket=injection_socket,
        )

        def ready(readers, _writers, _errors, _timeout):
            return (readers if query_socket.replies else [], [], [])

        with mock.patch.object(bridge.select, "select", side_effect=ready):
            result = instance.poll_once()
        self.assertEqual(0, result["hosts_ok"])
        self.assertEqual("ACK source port mismatch", result["errors"]["196.168.50.21"])
        self.assertEqual([], injection_socket.sent)

    def test_pure_validation_tests_never_open_a_network_socket(self):
        with mock.patch.object(bridge.socket, "socket") as socket_factory:
            host = bridge.UPSTREAM_HOSTS[0]
            bridge.validate_ack(acknowledgement(host, "offline"), host, "offline")
            bridge.build_water_packet(host.screens[0], water(), "offline", 0)
        socket_factory.assert_not_called()

    def test_bidirectional_events_preserve_identity_and_ack_only_after_delivery(self):
        event_socket = FakeEventSocket()
        instance = bridge.ParticleEventBridge(event_socket=event_socket)

        def ready(readers, _writers, _errors, _timeout):
            return (readers if event_socket.replies else [], [], [])

        with mock.patch.object(bridge.select, "select", side_effect=ready):
            first = instance.cycle_once()
            second = instance.cycle_once()

        self.assertEqual(4, first["source_polls_ok"])
        self.assertEqual(2, first["events_received"])
        self.assertEqual(2, first["events_delivered"])
        self.assertEqual(2, first["pending_source_ack_count"])
        self.assertEqual(0, second["events_received"])
        self.assertEqual(0, second["pending_source_ack_count"])
        self.assertEqual({}, first["errors"])
        self.assertEqual({}, second["errors"])

        deliveries = [
            (request, destination)
            for request, destination in event_socket.sent
            if request[bridge.PARTICLE_BRIDGE_FIELD]["op"] == "deliver"
        ]
        self.assertEqual(2, len(deliveries))
        by_type = {
            request[bridge.PARTICLE_BRIDGE_FIELD]["event"]["particle_type"]:
                (request, destination)
            for request, destination in deliveries
        }
        pollution_request, pollution_destination = by_type["pollution"]
        salmon_request, salmon_destination = by_type["salmon"]
        self.assertEqual(("127.0.0.1", 5005), pollution_destination)
        self.assertEqual(("196.168.50.21", 5005), salmon_destination)
        self.assertEqual(
            event_socket.events_by_source_ip["196.168.50.31"],
            pollution_request[bridge.PARTICLE_BRIDGE_FIELD]["event"],
        )
        self.assertEqual(
            event_socket.events_by_source_ip["127.0.0.1"],
            salmon_request[bridge.PARTICLE_BRIDGE_FIELD]["event"],
        )
        self.assertEqual(["mount_shasta"], salmon_request["target"])

    def test_missing_salmon_delivery_ack_retries_then_accepts_destination_dedupe(self):
        salmon_id = "delta:salmon:1"
        event_socket = FakeEventSocket(drop_first_event_id=salmon_id)
        instance = bridge.ParticleEventBridge(event_socket=event_socket)

        def ready(readers, _writers, _errors, _timeout):
            return (readers if event_socket.replies else [], [], [])

        with mock.patch.object(bridge.select, "select", side_effect=ready):
            first = instance.cycle_once()
            second = instance.cycle_once()
            third = instance.cycle_once()

        self.assertIn(f"deliver:delta:{salmon_id}", first["errors"])
        self.assertEqual(2, event_socket.delivery_attempts[salmon_id])
        self.assertIn(salmon_id, second["delivered_event_ids"])
        self.assertEqual(0, third["pending_source_ack_count"])

    def test_lost_source_ack_response_retries_exact_token_without_redelivery(self):
        event_socket = FakeEventSocket(drop_first_source_ack_ip="196.168.50.31")
        instance = bridge.ParticleEventBridge(event_socket=event_socket)

        def ready(readers, _writers, _errors, _timeout):
            return (readers if event_socket.replies else [], [], [])

        with mock.patch.object(bridge.select, "select", side_effect=ready):
            first = instance.cycle_once()
            second = instance.cycle_once()
            third = instance.cycle_once()

        self.assertEqual(2, first["pending_source_ack_count"])
        self.assertIn("poll:196.168.50.31", second["errors"])
        self.assertEqual(1, second["pending_source_ack_count"])
        self.assertEqual(0, third["pending_source_ack_count"])
        self.assertEqual(2, event_socket.source_ack_attempts["196.168.50.31"])
        self.assertEqual(1, event_socket.delivery_attempts["mill:pollution:1"])


if __name__ == "__main__":
    unittest.main()
