extends Node

const BUS_SCRIPT := preload("res://flow/particle_confluence_bus.gd")
const Topology := preload("res://flow/confluence_topology.gd")

var _bus: Node
var _owns_bus := false
var _errors: Array[String] = []


class FakeStage:
	extends Node

	var screen_id: String
	var confluence_enabled: bool
	var simulation_paused := false
	var water_states: Array[Dictionary] = []
	var batches: Array[Dictionary] = []
	var control_messages: Array[Dictionary] = []

	func _init(value: String, enabled: bool = false) -> void:
		screen_id = value
		confluence_enabled = enabled

	func get_screen_id() -> StringName:
		return StringName(screen_id)

	func set_confluence_water_state(
		source_screen: StringName,
		state: Dictionary,
	) -> bool:
		water_states.append({
			"source_screen": String(source_screen),
			"state": state.duplicate(true),
		})
		return confluence_enabled and screen_id == Topology.DELTA_SCREEN

	func queue_confluence_batch(
		source_screen: StringName,
		particle_type: StringName,
		subtype: StringName,
		count: int,
		event_id: String = "",
	) -> bool:
		batches.append({
			"source_screen": String(source_screen),
			"particle_type": String(particle_type),
			"subtype": String(subtype),
			"count": count,
			"event_id": event_id,
		})
		return true

	func get_confluence_runtime_summary() -> Dictionary:
		return {
			"is_delta": screen_id == Topology.DELTA_SCREEN,
			"enabled": confluence_enabled,
		}

	func is_paused() -> bool:
		return simulation_paused

	func queue_control_message(message: Dictionary) -> void:
		control_messages.append(message.duplicate(true))


func _enter_tree() -> void:
	# A project-level autoload may already exist when this standalone scene is
	# run. Close it before the first scene frame so this submit-only test cannot
	# put any datagram on the installation network.
	var project_autoload := get_node_or_null("/root/ParticleConfluenceBus")
	if project_autoload != null and project_autoload.has_method(&"stop_listening"):
		project_autoload.call(&"stop_listening")
	var control_autoload := get_node_or_null("/root/FlowControlBus")
	if control_autoload != null and control_autoload.has_method(&"stop_listening"):
		control_autoload.call(&"stop_listening")


func _ready() -> void:
	call_deferred(&"_run")


func _run() -> void:
	# Keep this smoke independent of host socket permissions and any production
	# autoload. submit_packet() and all routing/reliability state are headless-safe
	# without putting the transport node in the scene tree.
	_bus = BUS_SCRIPT.new()
	_bus.name = "ParticleConfluenceBusSmokeTransport"
	_bus.set("_session_id", "particle-confluence-smoke-session")
	_owns_bus = true
	_expect(
		not _bus.call(&"is_listening"),
		"standalone smoke transport must not open a LAN socket",
	)

	var delta := FakeStage.new(Topology.DELTA_SCREEN, true)
	var shasta := FakeStage.new("mount_shasta")
	var mccloud := FakeStage.new("mccloud_pit")
	var cottonwood := FakeStage.new("cottonwood_creek")
	var mill := FakeStage.new("mill_creek")
	for stage: FakeStage in [delta, shasta, mccloud, cottonwood, mill]:
		add_child(stage)
		stage.add_to_group(&"flow_models")
		_expect(_bus.call(&"register_stage", stage), "stage registration failed")

	_test_topology()
	_test_water(delta)
	_test_particle_dedupe(delta)
	_test_single_destination_salmon_delay(shasta, mccloud)
	_test_outgoing_retry_ack(mill)
	_test_salmon_cohort_ack()
	_test_bridge_outbox_retention_and_ack()
	_test_bridge_delivery_directions(delta, shasta)
	_test_flow_control_bridge_envelope([
		delta,
		shasta,
		mccloud,
		cottonwood,
		mill,
	])
	_test_stale_water(delta)
	_test_bounds()

	var summary: Dictionary = _bus.call(&"runtime_summary")
	_expect(
		int(summary.get("pending_event_count", -1)) == 0,
		"all synthetic acknowledgements must clear pending events",
	)
	_expect(
		int(Dictionary(summary.get("counters", {})).get(
			"particle_batch_duplicates",
			0,
		)) >= 1,
		"duplicate batch counter did not advance",
	)
	_expect(
		int(summary.get("scheduled_inbound_event_count", -1)) == 0,
		"all delayed inbound events must finish in the smoke",
	)
	_expect(
		int(Dictionary(summary.get("counters", {})).get("packets_sent", -1)) == 0,
		"headless submit-only smoke unexpectedly transmitted on the LAN",
	)

	if _owns_bus:
		_bus.free()
	if _errors.is_empty():
		print("PARTICLE_CONFLUENCE_BUS_SMOKE: PASS")
		get_tree().quit(0)
	else:
		for error: String in _errors:
			push_error(error)
		print("PARTICLE_CONFLUENCE_BUS_SMOKE: FAIL (%d)" % _errors.size())
		get_tree().quit(1)


func _test_topology() -> void:
	_expect(Topology.UDP_PORT == 5007, "confluence must use UDP 5007")
	_expect(
		Topology.host_for_screen("mill_creek") == "196.168.50.31",
		"Mill Creek host ownership is incorrect",
	)
	_expect(
		Topology.inlet_for_screen("american_river") == {
			"edge": "top",
			"gridline": 12,
		},
		"American River Delta inlet is incorrect",
	)
	_expect(
		Topology.inlet_for_screen("mccloud_pit") == {
			"edge": "left",
			"gridline": 2,
		},
		"McCloud must enter the Delta from left gridline 2",
	)


func _test_water(delta: FakeStage) -> void:
	var packet := {
		"protocol": Topology.PROTOCOL,
		"kind": "water_state",
		"session": "mill-water-session",
		"seq": 1,
		"source_screen": "mill_creek",
		"target_screen": Topology.DELTA_SCREEN,
		"water": {
			"flow_rate": 0.42,
			"active_heads": 426,
			"speed_pixels": 252.0,
			"paused": false,
			"exit_width_pixels": 430.08,
		},
	}
	_expect(
		_bus.call(&"submit_packet", packet, "196.168.50.31", 5007),
		"authorized Mill Creek water state was rejected",
	)
	_expect(delta.water_states.size() == 1, "Delta did not receive water state")
	var first_state: Dictionary = delta.water_states.back()["state"]
	_expect(
		is_equal_approx(float(first_state.get("exit_width_pixels", -1.0)), 430.08),
		"explicit upstream exit width was not preserved",
	)
	packet["water"]["flow_rate"] = 0.99
	_expect(
		_bus.call(&"submit_packet", packet, "196.168.50.31", 5007),
		"duplicate water snapshot should be harmless",
	)
	_expect(delta.water_states.size() == 1, "duplicate water sequence was reapplied")
	packet["seq"] = 2
	_expect(
		not _bus.call(&"submit_packet", packet, "196.168.50.41", 5007),
		"spoofed Mill Creek sender was accepted",
	)
	packet["water"].erase("exit_width_pixels")
	packet["water"]["flow_rate"] = 0.25
	_expect(
		_bus.call(&"submit_packet", packet, "196.168.50.31", 5007),
		"legacy water state without an explicit width was rejected",
	)
	var legacy_state: Dictionary = delta.water_states.back()["state"]
	_expect(
		is_equal_approx(float(legacy_state.get("exit_width_pixels", -1.0)), 256.0),
		"legacy water state did not derive exit width from flow rate",
	)
	packet["seq"] = 3
	packet["water"]["exit_width_pixels"] = 1024.01
	_expect(
		not _bus.call(&"submit_packet", packet, "196.168.50.31", 5007),
		"over-cap upstream exit width was accepted",
	)


func _test_particle_dedupe(delta: FakeStage) -> void:
	var packet := _batch_packet(
		"cottonwood_creek",
		"cottonwood-events",
		1,
		"cottonwood-events:1",
		[Topology.DELTA_SCREEN],
		"leaf",
		"mixed",
		30,
	)
	_expect(
		_bus.call(&"submit_packet", packet, "196.168.50.31", 0),
		"authorized leaf batch was rejected",
	)
	var applied_count := delta.batches.size()
	_expect(applied_count == 1, "Delta did not receive exactly one leaf batch")
	_expect(
		_bus.call(&"submit_packet", packet, "196.168.50.31", 0),
		"duplicate batch should be accepted and acknowledged",
	)
	_expect(delta.batches.size() == applied_count, "duplicate leaf batch was reapplied")
	var mismatched_duplicate := packet.duplicate(true)
	mismatched_duplicate["count"] = 31
	_expect(
		not _bus.call(
			&"submit_packet",
			mismatched_duplicate,
			"196.168.50.31",
			0,
		),
		"one event_id was accepted with two different payloads",
	)
	packet["target_screens"] = ["mount_shasta"]
	packet["event_id"] = "cottonwood-events:bad-route"
	packet["seq"] = 2
	_expect(
		not _bus.call(&"submit_packet", packet, "196.168.50.31", 0),
		"upstream leaf batch escaped the Delta-only route",
	)


func _test_single_destination_salmon_delay(
	shasta: FakeStage,
	mccloud: FakeStage,
) -> void:
	var shasta_before := shasta.batches.size()
	var mccloud_before := mccloud.batches.size()
	var packet := _batch_packet(
		Topology.DELTA_SCREEN,
		"delta-salmon-session",
		1,
		"delta-salmon-session:1",
		["mount_shasta"],
		"salmon",
		"default",
		17,
	)
	packet["origin_count"] = 25
	packet["destination_screen"] = "mount_shasta"
	packet["transit_delay_seconds"] = 1.0
	_expect(
		_bus.call(&"submit_packet", packet, Topology.DELTA_HOST, 0),
		"destination-specific salmon cohort was rejected",
	)
	_expect(
		shasta.batches.size() == shasta_before,
		"delayed salmon was applied immediately",
	)
	_bus.call(&"_advance_scheduled_inbound_events", 0.4)
	_expect(shasta.batches.size() == shasta_before, "salmon delay ended too early")
	shasta.simulation_paused = true
	_bus.call(&"_advance_scheduled_inbound_events", 5.0)
	_expect(
		shasta.batches.size() == shasta_before,
		"paused simulation consumed salmon transit time",
	)
	shasta.simulation_paused = false
	_bus.call(&"_advance_scheduled_inbound_events", 0.61)
	_expect(
		shasta.batches.size() == shasta_before + 1,
		"salmon was not applied after its unpaused transit delay",
	)
	_expect(
		mccloud.batches.size() == mccloud_before,
		"Shasta cohort was duplicated onto its McCloud host sibling",
	)
	_expect(
		_bus.call(&"submit_packet", packet, Topology.DELTA_HOST, 0),
		"duplicate destination-specific salmon packet was rejected",
	)
	_expect(
		shasta.batches.size() == shasta_before + 1,
		"duplicate salmon cohort was applied twice",
	)
	var invalid_dual_target := packet.duplicate(true)
	invalid_dual_target["seq"] = 2
	invalid_dual_target["event_id"] = "delta-salmon-session:2"
	invalid_dual_target["target_screens"] = ["mount_shasta", "mccloud_pit"]
	_expect(
		not _bus.call(
			&"submit_packet",
			invalid_dual_target,
			Topology.DELTA_HOST,
			0,
		),
		"one salmon cohort was accepted for both screens on a dual-screen host",
	)


func _test_outgoing_retry_ack(mill: FakeStage) -> void:
	var event_id: String = _bus.call(
		&"publish_particle_batch",
		StringName("mill_creek"),
		StringName("pollution"),
		StringName("material"),
		2,
		0.0,
	)
	_expect(not event_id.is_empty(), "outgoing pollution event was not queued")
	var summary: Dictionary = _bus.call(&"runtime_summary")
	_expect(int(summary["pending_event_count"]) == 1, "outgoing event is not pending")
	var acknowledgement := {
		"protocol": Topology.ACK_PROTOCOL,
		"session": String(summary["session"]),
		"event_id": event_id,
		"accepted": true,
		"recipient_screen_ids": [Topology.DELTA_SCREEN],
	}
	_expect(
		_bus.call(&"submit_packet", acknowledgement, Topology.DELTA_HOST, 5007),
		"matching Delta acknowledgement was rejected",
	)
	_expect(
		int(Dictionary(_bus.call(&"runtime_summary"))["pending_event_count"]) == 0,
		"matching acknowledgement did not clear pending event",
	)
	_expect(_bus.call(&"register_stage", mill), "idempotent Mill registration failed")


func _test_salmon_cohort_ack() -> void:
	_expect(
		String(_bus.call(
			&"publish_salmon_cohort",
			StringName("mccloud_pit"),
			26,
			0.0,
		)).is_empty(),
		"more than one 25-fish cohort was accepted",
	)
	var event_id := String(_bus.call(
		&"publish_salmon_cohort",
		StringName("mccloud_pit"),
		17,
		1.25,
	))
	_expect(not event_id.is_empty(), "destination-specific salmon was not queued")
	var summary: Dictionary = _bus.call(&"runtime_summary")
	_expect(int(summary["pending_event_count"]) == 1, "salmon event is not pending")
	var pending_events: Dictionary = _bus.get("_pending_events")
	var queued_packet: Dictionary = {}
	for pending_key_variant: Variant in pending_events:
		var pending: Dictionary = pending_events[pending_key_variant]
		if String(pending.get("event_id", "")) == event_id:
			queued_packet = Dictionary(pending["packet"])
			break
	_expect(int(queued_packet.get("origin_count", 0)) == 25, "cohort origin is not 25")
	_expect(int(queued_packet.get("count", 0)) == 17, "survivor count changed on wire")
	_expect(
		String(queued_packet.get("destination_screen", "")) == "mccloud_pit",
		"salmon destination is missing from the wire packet",
	)
	_expect(
		Array(queued_packet.get("target_screens", [])) == ["mccloud_pit"],
		"salmon wire packet includes the destination's host sibling",
	)
	_expect(
		_bus.call(
			&"submit_packet",
			{
				"protocol": Topology.ACK_PROTOCOL,
				"session": String(summary["session"]),
				"event_id": event_id,
				"accepted": true,
				"recipient_screen_ids": ["mccloud_pit"],
			},
			"196.168.50.21",
			5007,
		),
		"destination-specific salmon acknowledgement was rejected",
	)


func _test_bridge_outbox_retention_and_ack() -> void:
	var event_id := String(_bus.call(
		&"publish_particle_batch",
		StringName("mill_creek"),
		StringName("pollution"),
		StringName("heat"),
		3,
		0.0,
	))
	_expect(not event_id.is_empty(), "bridge pollution event was not queued")
	var first_poll: Dictionary = _bus.call(&"bridge_poll", [], 1)
	_expect(bool(first_poll.get("accepted", false)), "bounded bridge poll was rejected")
	var events: Array = first_poll.get("events", [])
	_expect(events.size() == 1, "bounded bridge poll did not return one event")
	var event: Dictionary = events[0] if not events.is_empty() else {}
	_expect(String(event.get("event_id", "")) == event_id, "bridge changed event identity")
	_expect(
		String(event.get("particle_type", "")) == "pollution",
		"bridge changed event kind",
	)
	var current_session := String(first_poll.get("source_session", ""))
	var stale_poll: Dictionary = _bus.call(&"bridge_poll", [{
		"source_session": "stale-producer-session",
		"source_screen": "mill_creek",
		"event_id": event_id,
		"recipient_screen_ids": [Topology.DELTA_SCREEN],
	}], 1)
	var stale_results: Array = stale_poll.get("ack_results", [])
	_expect(
		stale_results.size() == 1
		and String(Dictionary(stale_results[0]).get("status", "")) == "stale_session",
		"stale producer-session acknowledgement was not isolated",
	)
	_expect(
		int(Dictionary(_bus.call(&"runtime_summary"))["pending_event_count"]) == 1,
		"stale producer-session acknowledgement cleared the outbox",
	)

	var pending_events: Dictionary = _bus.get("_pending_events")
	for pending_key_variant: Variant in pending_events:
		var pending: Dictionary = pending_events[pending_key_variant]
		if String(pending.get("event_id", "")) == event_id:
			pending["created_msec"] = Time.get_ticks_msec() - 30001
	_bus.call(&"_retry_pending_events", Time.get_ticks_msec())
	var retained_summary: Dictionary = _bus.call(&"runtime_summary")
	_expect(
		int(retained_summary.get("pending_event_count", 0)) == 1,
		"direct retry TTL erased a bridge event",
	)
	_expect(
		int(Dictionary(retained_summary.get("counters", {})).get(
			"particle_batches_retained_for_bridge",
			0,
		)) >= 1,
		"direct retry exhaustion was not recorded as bridge retention",
	)

	var mismatch_poll: Dictionary = _bus.call(&"bridge_poll", [{
		"source_session": current_session,
		"source_screen": "mill_creek",
		"event_id": event_id,
		"recipient_screen_ids": ["mount_shasta"],
	}], 1)
	var mismatch_results: Array = mismatch_poll.get("ack_results", [])
	_expect(
		mismatch_results.size() == 1
		and String(Dictionary(mismatch_results[0]).get("status", "")) == "recipient_mismatch",
		"bridge accepted mismatched acknowledgement recipients",
	)
	var acknowledgement := {
		"source_session": current_session,
		"source_screen": "mill_creek",
		"event_id": event_id,
		"recipient_screen_ids": [Topology.DELTA_SCREEN],
	}
	var acknowledged_poll: Dictionary = _bus.call(
		&"bridge_poll",
		[acknowledgement],
		1,
	)
	var acknowledged_results: Array = acknowledged_poll.get("ack_results", [])
	_expect(
		acknowledged_results.size() == 1
		and String(Dictionary(acknowledged_results[0]).get("status", "")) == "acknowledged",
		"exact bridge acknowledgement did not clear the event",
	)
	_expect(
		int(acknowledged_poll.get("pending_event_count", -1)) == 0,
		"acknowledged bridge event remained pending",
	)
	var repeated_poll: Dictionary = _bus.call(&"bridge_poll", [acknowledgement], 1)
	var repeated_results: Array = repeated_poll.get("ack_results", [])
	_expect(
		repeated_results.size() == 1
		and String(Dictionary(repeated_results[0]).get("status", "")) == "already_acknowledged",
		"lost bridge ACK response was not idempotent",
	)


func _test_bridge_delivery_directions(delta: FakeStage, shasta: FakeStage) -> void:
	var delta_before := delta.batches.size()
	var pollution_packet := _batch_packet(
		"mill_creek",
		"bridge-upstream-session",
		1,
		"bridge-upstream-session:1",
		[Topology.DELTA_SCREEN],
		"pollution",
		"material",
		4,
	)
	var unauthorized: Dictionary = _bus.call(
		&"bridge_deliver_event",
		pollution_packet,
		"196.168.50.31",
	)
	_expect(
		not bool(unauthorized.get("accepted", true)),
		"non-.11 bridge sender was authorized",
	)
	var delivered: Dictionary = _bus.call(
		&"bridge_deliver_event",
		pollution_packet,
		Topology.DELTA_HOST,
	)
	_expect(
		bool(delivered.get("accepted", false))
		and String(delivered.get("status", "")) == "applied",
		"upstream pollution bridge delivery was not applied in Delta",
	)
	_expect(delta.batches.size() == delta_before + 1, "Delta received no bridged pollution")
	var pollution_retry: Dictionary = _bus.call(
		&"bridge_deliver_event",
		pollution_packet,
		Topology.DELTA_HOST,
	)
	_expect(
		bool(pollution_retry.get("accepted", false))
		and String(pollution_retry.get("status", "")) == "duplicate",
		"identical upstream bridge retry was not deduplicated",
	)
	_expect(delta.batches.size() == delta_before + 1, "bridged pollution retry applied twice")
	var changed_pollution := pollution_packet.duplicate(true)
	changed_pollution["count"] = 5
	_expect(
			not bool(Dictionary(_bus.call(
			&"bridge_deliver_event",
			changed_pollution,
			Topology.DELTA_HOST,
		)).get("accepted", true)),
		"bridge accepted changed payload under an existing event identity",
	)

	var shasta_before := shasta.batches.size()
	var salmon_packet := _batch_packet(
		Topology.DELTA_SCREEN,
		"bridge-delta-session",
		1,
		"bridge-delta-session:1",
		["mount_shasta"],
		"salmon",
		"default",
		13,
	)
	salmon_packet["origin_count"] = 25
	salmon_packet["destination_screen"] = "mount_shasta"
	var salmon_delivery: Dictionary = _bus.call(
		&"bridge_deliver_event",
		salmon_packet,
		Topology.DELTA_HOST,
	)
	_expect(
		bool(salmon_delivery.get("accepted", false))
		and Array(salmon_delivery.get("recipient_screen_ids", [])) == ["mount_shasta"],
		"Delta survivor bridge did not preserve its one named branch",
	)
	_expect(shasta.batches.size() == shasta_before + 1, "Shasta received no survivors")
	_expect(
		int(shasta.batches.back().get("count", 0)) == 13,
		"Delta survivor count changed during bridge delivery",
	)
	var salmon_retry: Dictionary = _bus.call(
		&"bridge_deliver_event",
		salmon_packet,
		Topology.DELTA_HOST,
	)
	_expect(
		bool(salmon_retry.get("accepted", false))
		and String(salmon_retry.get("status", "")) == "duplicate",
		"identical survivor bridge retry was not deduplicated",
	)
	_expect(shasta.batches.size() == shasta_before + 1, "survivor bridge retry applied twice")


func _test_flow_control_bridge_envelope(stages: Array) -> void:
	var particle_bus := get_node_or_null("/root/ParticleConfluenceBus")
	var control_bus := get_node_or_null("/root/FlowControlBus")
	if particle_bus == null or control_bus == null:
		_expect(false, "project particle/control autoloads are unavailable")
		return
	for stage_variant: Variant in stages:
		var stage: FakeStage = stage_variant
		_expect(
			bool(particle_bus.call(&"register_stage", stage)),
			"FlowControl envelope stage registration failed for %s" % stage.screen_id,
		)
	var local_screens_variant: Variant = particle_bus.call(
		&"bridge_registered_screen_ids",
	)
	var local_screens: Array = (
		Array(local_screens_variant).duplicate()
		if local_screens_variant is Array
		else []
	)
	_expect(
		local_screens == [
			"cottonwood_creek",
			Topology.DELTA_SCREEN,
			"mccloud_pit",
			"mill_creek",
			"mount_shasta",
		],
		"FlowControl bridge did not expose the exact local stage registry",
	)

	# The pre-existing empty control request used by the water pull bridge must
	# remain on the ordinary stage-routing path when no particle extension exists.
	var ordinary_message := _bridge_control_packet(
		local_screens,
		{},
		"ordinary-water-poll",
	)
	ordinary_message.erase("particle_confluence_bridge")
	var ordinary_before := _control_message_total(stages)
	_expect(
		bool(control_bus.call(
			&"submit_packet",
			ordinary_message,
			Topology.DELTA_HOST,
			0,
		)),
		"ordinary empty FlowControl request stopped routing",
	)
	_expect(
		_control_message_total(stages) == ordinary_before + stages.size(),
		"ordinary empty FlowControl request no longer reaches every named stage",
	)

	var leaf_event_id := String(particle_bus.call(
		&"publish_particle_batch",
		StringName("mill_creek"),
		StringName("leaf"),
		StringName("mixed"),
		6,
		0.0,
	))
	_expect(not leaf_event_id.is_empty(), "FlowControl leaf event was not queued")
	var poll_message := _bridge_control_packet(
		local_screens,
		{
			"op": "poll",
			"event_acks": [],
			"max_events": 16,
		},
		"particle-poll-1",
	)
	var unauthorized_poll: Dictionary = control_bus.call(
		&"_handle_particle_confluence_bridge_request",
		poll_message,
		"196.168.50.31",
	)
	_expect(
		not bool(unauthorized_poll.get("accepted", true)),
		"FlowControl bridge authorized a non-.11 remote sender",
	)
	var wildcard_poll := poll_message.duplicate(true)
	wildcard_poll["target"] = "*"
	var wildcard_result: Dictionary = control_bus.call(
		&"_handle_particle_confluence_bridge_request",
		wildcard_poll,
		Topology.DELTA_HOST,
	)
	_expect(
		not bool(wildcard_result.get("accepted", true)),
		"FlowControl bridge accepted wildcard ownership",
	)
	var partial_poll := poll_message.duplicate(true)
	partial_poll["target"] = [Topology.DELTA_SCREEN]
	var partial_result: Dictionary = control_bus.call(
		&"_handle_particle_confluence_bridge_request",
		partial_poll,
		Topology.DELTA_HOST,
	)
	_expect(
		not bool(partial_result.get("accepted", true)),
		"FlowControl poll accepted an incomplete local host target",
	)
	var mutating_poll := poll_message.duplicate(true)
	mutating_poll["changes"] = {"flow.rate": 0.5}
	var mutating_result: Dictionary = control_bus.call(
		&"_handle_particle_confluence_bridge_request",
		mutating_poll,
		Topology.DELTA_HOST,
	)
	_expect(
		not bool(mutating_result.get("accepted", true)),
		"FlowControl particle bridge accepted a control mutation",
	)
	for invalid_max_events: Variant in [16.5, "16", true]:
		var invalid_bound_poll := poll_message.duplicate(true)
		var invalid_bound_body: Dictionary = invalid_bound_poll[
			"particle_confluence_bridge"
		]
		invalid_bound_body["max_events"] = invalid_max_events
		var invalid_bound_result: Dictionary = control_bus.call(
			&"_handle_particle_confluence_bridge_request",
			invalid_bound_poll,
			Topology.DELTA_HOST,
		)
		_expect(
			not bool(invalid_bound_result.get("accepted", true)),
			"FlowControl particle bridge accepted non-integral max_events",
		)

	# Exercise the real UTF-8 JSON boundary used by the Python bridge. Numeric
	# JSON tokens can arrive as floating-point Variants even when written as 16.
	var wire_parser := JSON.new()
	var wire_parse_error := wire_parser.parse(JSON.stringify(poll_message))
	var wire_poll_message: Dictionary = (
		Dictionary(wire_parser.data)
		if wire_parse_error == OK and wire_parser.data is Dictionary
		else {}
	)
	_expect(
		wire_parse_error == OK and not wire_poll_message.is_empty(),
		"FlowControl particle poll did not survive UTF-8 JSON decoding",
	)
	var wire_bridge_body: Dictionary = wire_poll_message.get(
		"particle_confluence_bridge",
		{},
	)
	var wire_max_events: Variant = wire_bridge_body.get("max_events", null)
	_expect(
		(typeof(wire_max_events) == TYPE_INT or typeof(wire_max_events) == TYPE_FLOAT)
		and is_equal_approx(float(wire_max_events), 16.0),
		"decoded FlowControl max_events is not the integral JSON value 16",
	)
	var controls_before_bridge := _control_message_total(stages)
	_expect(
		bool(control_bus.call(
			&"submit_packet",
			wire_poll_message,
			Topology.DELTA_HOST,
			0,
		)),
		"authorized UTF-8 JSON FlowControl particle poll was rejected",
	)
	_expect(
		_control_message_total(stages) == controls_before_bridge,
		"particle bridge poll leaked into ordinary stage controls",
	)
	var poll_result: Dictionary = control_bus.call(
		&"_handle_particle_confluence_bridge_request",
		poll_message,
		Topology.DELTA_HOST,
	)
	var polled_events: Array = poll_result.get("events", [])
	var leaf_event: Dictionary = (
		Dictionary(polled_events[0]) if not polled_events.is_empty() else {}
	)
	_expect(
		bool(poll_result.get("accepted", false))
		and int(poll_result.get("recipient_count", 0)) == local_screens.size()
		and polled_events.size() == 1,
		"authorized FlowControl particle poll returned the wrong envelope",
	)
	_expect(
		String(leaf_event.get("event_id", "")) == leaf_event_id
		and String(leaf_event.get("source_screen", "")) == "mill_creek",
		"FlowControl particle poll changed raw leaf identity",
	)
	var ack_envelope: Dictionary = control_bus.call(
		&"_protocol_acknowledgement",
		poll_message,
		local_screens.size(),
		true,
		"",
		{"particle_confluence_bridge": poll_result},
	)
	_expect(
		String(ack_envelope.get("protocol", "")) == "ink-flow/1-ack"
		and String(ack_envelope.get("request_id", "")) == "particle-poll-1"
		and Dictionary(ack_envelope.get(
			"particle_confluence_bridge",
			{},
		)) == poll_result,
		"FlowControl ACK did not preserve the particle extension/request ID",
	)

	var forged_leaf := leaf_event.duplicate(true)
	forged_leaf["source_screen"] = Topology.DELTA_SCREEN
	var forged_result: Dictionary = control_bus.call(
		&"_handle_particle_confluence_bridge_request",
		_bridge_control_packet(
			[Topology.DELTA_SCREEN],
			{"op": "deliver", "event": forged_leaf},
			"forged-leaf",
		),
		Topology.DELTA_HOST,
	)
	_expect(
		not bool(forged_result.get("accepted", true)),
		"trusted bridge bypassed the raw event source/route validator",
	)
	var delta_stage: FakeStage = stages[0]
	var delta_before := delta_stage.batches.size()
	var deliver_message := _bridge_control_packet(
		[Topology.DELTA_SCREEN],
		{"op": "deliver", "event": leaf_event},
		"deliver-leaf",
	)
	var delivery_result: Dictionary = control_bus.call(
		&"_handle_particle_confluence_bridge_request",
		deliver_message,
		Topology.DELTA_HOST,
	)
	_expect(
		bool(delivery_result.get("accepted", false))
		and String(delivery_result.get("status", "")) == "applied"
		and Array(delivery_result.get("recipient_screen_ids", []))
			== [Topology.DELTA_SCREEN],
		"FlowControl did not deliver the upstream leaf into Delta",
	)
	_expect(
		delta_stage.batches.size() == delta_before + 1,
		"FlowControl leaf delivery produced no Delta batch",
	)
	var duplicate_delivery: Dictionary = control_bus.call(
		&"_handle_particle_confluence_bridge_request",
		deliver_message,
		Topology.DELTA_HOST,
	)
	_expect(
		bool(duplicate_delivery.get("accepted", false))
		and String(duplicate_delivery.get("status", "")) == "duplicate"
		and delta_stage.batches.size() == delta_before + 1,
		"FlowControl leaf retry was not at-most-once",
	)
	var wrong_target_delivery := deliver_message.duplicate(true)
	wrong_target_delivery["target"] = ["mount_shasta"]
	var wrong_target_result: Dictionary = control_bus.call(
		&"_handle_particle_confluence_bridge_request",
		wrong_target_delivery,
		Topology.DELTA_HOST,
	)
	_expect(
		not bool(wrong_target_result.get("accepted", true)),
		"FlowControl delivery ignored an outer/inner target mismatch",
	)

	var leaf_ack := {
		"source_session": String(leaf_event.get("session", "")),
		"source_screen": String(leaf_event.get("source_screen", "")),
		"event_id": String(leaf_event.get("event_id", "")),
		"recipient_screen_ids": [Topology.DELTA_SCREEN],
	}
	var leaf_ack_result: Dictionary = control_bus.call(
		&"_handle_particle_confluence_bridge_request",
		_bridge_control_packet(
			local_screens,
			{"op": "poll", "event_acks": [leaf_ack], "max_events": 1},
			"ack-leaf",
		),
		Topology.DELTA_HOST,
	)
	var leaf_ack_results: Array = leaf_ack_result.get("ack_results", [])
	var leaf_ack_record: Dictionary = (
		Dictionary(leaf_ack_results[0]) if not leaf_ack_results.is_empty() else {}
	)
	_expect(
		leaf_ack_results.size() == 1
		and bool(leaf_ack_record.get("accepted", false))
		and String(leaf_ack_record.get("status", "")) == "acknowledged"
		and Array(leaf_ack_record.get("recipient_screen_ids", []))
			== [Topology.DELTA_SCREEN]
		and int(leaf_ack_result.get("pending_event_count", -1)) == 0,
		"FlowControl exact leaf ACK did not clear the source outbox",
	)

	var survivor_event_id := String(particle_bus.call(
		&"publish_salmon_cohort",
		StringName("mount_shasta"),
		11,
		0.0,
	))
	_expect(not survivor_event_id.is_empty(), "FlowControl salmon survivors were not queued")
	var salmon_poll_result: Dictionary = control_bus.call(
		&"_handle_particle_confluence_bridge_request",
		_bridge_control_packet(
			local_screens,
			{"op": "poll", "event_acks": [], "max_events": 1},
			"poll-salmon",
		),
		Topology.DELTA_HOST,
	)
	var salmon_events: Array = salmon_poll_result.get("events", [])
	var salmon_event: Dictionary = (
		Dictionary(salmon_events[0]) if not salmon_events.is_empty() else {}
	)
	_expect(
		salmon_events.size() == 1
		and String(salmon_event.get("event_id", "")) == survivor_event_id
		and int(salmon_event.get("origin_count", 0)) == 25
		and int(salmon_event.get("count", 0)) == 11
		and String(salmon_event.get("destination_screen", "")) == "mount_shasta",
		"FlowControl salmon poll changed destination/survivor metadata",
	)
	var shasta_stage: FakeStage = stages[1]
	var shasta_before := shasta_stage.batches.size()
	var salmon_deliver_result: Dictionary = control_bus.call(
		&"_handle_particle_confluence_bridge_request",
		_bridge_control_packet(
			["mount_shasta"],
			{"op": "deliver", "event": salmon_event},
			"deliver-salmon",
		),
		Topology.DELTA_HOST,
	)
	_expect(
		bool(salmon_deliver_result.get("accepted", false))
		and String(salmon_deliver_result.get("status", "")) == "applied"
		and Array(salmon_deliver_result.get("recipient_screen_ids", []))
			== ["mount_shasta"],
		"FlowControl salmon survivors did not reach the exact branch",
	)
	_expect(
		shasta_stage.batches.size() == shasta_before + 1
		and int(shasta_stage.batches.back().get("count", 0)) == 11,
		"FlowControl salmon delivery changed the survivor count",
	)
	var salmon_ack := {
		"source_session": String(salmon_event.get("session", "")),
		"source_screen": Topology.DELTA_SCREEN,
		"event_id": survivor_event_id,
		"recipient_screen_ids": ["mount_shasta"],
	}
	var salmon_ack_result: Dictionary = control_bus.call(
		&"_handle_particle_confluence_bridge_request",
		_bridge_control_packet(
			local_screens,
			{"op": "poll", "event_acks": [salmon_ack], "max_events": 1},
			"ack-salmon",
		),
		Topology.DELTA_HOST,
	)
	var salmon_ack_results: Array = salmon_ack_result.get("ack_results", [])
	_expect(
		salmon_ack_results.size() == 1
		and String(Dictionary(salmon_ack_results[0]).get("status", ""))
			== "acknowledged"
		and int(salmon_ack_result.get("pending_event_count", -1)) == 0,
		"FlowControl exact salmon ACK did not clear the Delta outbox",
	)


func _test_stale_water(delta: FakeStage) -> void:
	var receive_states: Dictionary = _bus.get("_water_receive_state")
	var state: Dictionary = receive_states["mill_creek"]
	var now_msec := Time.get_ticks_msec()
	state["last_received_msec"] = now_msec - 3000
	_bus.call(&"_expire_stale_water_states", now_msec)
	var latest: Dictionary = delta.water_states.back()["state"]
	_expect(bool(latest.get("stale", false)), "stale water source was not marked")
	_expect(is_zero_approx(float(latest["flow_rate"])), "stale water did not fade to zero")
	_expect(
		is_zero_approx(float(latest.get("exit_width_pixels", -1.0))),
		"stale water did not collapse its upstream exit width",
	)


func _test_bounds() -> void:
	var packet := _batch_packet(
		"mill_creek",
		"bounds-session",
		1,
		"bounds-session:1",
		[Topology.DELTA_SCREEN],
		"pollution",
		"heat",
		301,
	)
	_expect(
		not _bus.call(&"submit_packet", packet, "196.168.50.31", 0),
		"over-cap particle count was accepted",
	)


func _batch_packet(
	source: String,
	session: String,
	sequence: int,
	event_id: String,
	targets: Array,
	particle_type: String,
	subtype: String,
	count: int,
) -> Dictionary:
	return {
		"protocol": Topology.PROTOCOL,
		"kind": "particle_batch",
		"session": session,
		"event_id": event_id,
		"seq": sequence,
		"source_screen": source,
		"target_screens": targets.duplicate(),
		"particle_type": particle_type,
		"subtype": subtype,
		"count": count,
		"transit_delay_seconds": 0.0,
	}


func _bridge_control_packet(
	target: Variant,
	bridge_body: Dictionary,
	request_id: String,
) -> Dictionary:
	return {
		"protocol": "ink-flow/1",
		"revision": 9000,
		"target": target,
		"changes": {},
		"geometry_ops": [],
		"actions": [],
		"metadata": {"request_id": request_id},
		"particle_confluence_bridge": bridge_body.duplicate(true),
	}


func _control_message_total(stages: Array) -> int:
	var total := 0
	for stage_variant: Variant in stages:
		var stage: FakeStage = stage_variant
		total += stage.control_messages.size()
	return total


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_errors.append(message)
