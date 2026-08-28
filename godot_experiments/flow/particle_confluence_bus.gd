extends Node

## Process-wide UDP transport for the seven-screen particle confluence.
##
## This is intentionally separate from FlowControlBus (UDP 5005). Water is an
## absolute, frequently repeated state. Leaves, pollution, and salmon are
## reliable event batches with receiver de-duplication and sender retry.

signal listening_started(port: int, bind_address: String)
signal water_state_received(
	source_screen: StringName,
	state: Dictionary,
	recipient_count: int,
)
signal particle_batch_received(
	source_screen: StringName,
	target_screen: StringName,
	particle_type: StringName,
	subtype: StringName,
	count: int,
	transit_delay_seconds: float,
	event_id: String,
)
signal particle_batch_acknowledged(event_id: String, destination_ip: String)
signal packet_error(reason: String, sender_ip: String, sender_port: int)
signal transport_error(reason: String)

const Topology = preload("res://flow/confluence_topology.gd")

const PROTOCOL: String = Topology.PROTOCOL
const ACK_PROTOCOL: String = Topology.ACK_PROTOCOL
const UDP_PORT: int = Topology.UDP_PORT
const BIND_ADDRESS: String = Topology.BIND_ADDRESS
const MAX_PACKETS_PER_FRAME := 128
const MAX_PACKET_BYTES := 16384
const WATER_SNAPSHOT_INTERVAL_MSEC := 200
const WATER_STALE_TIMEOUT_MSEC := 2000
const MAX_EXIT_WIDTH_PIXELS := 1024.0
const EVENT_RETRY_INTERVAL_MSEC := 250
const EVENT_TTL_MSEC := 30000
const MAX_PENDING_EVENTS := 256
const MAX_RECEIVED_EVENTS := 1024
const MAX_SCHEDULED_INBOUND_EVENTS := 256
const BRIDGE_EVENT_PAGE_MAX := 16
const MAX_COMPLETED_OUTBOUND_EVENTS := 1024
const MAX_EVENT_COUNT := 300
const SALMON_ORIGIN_COUNT := 25
const MAX_TEXT_FIELD_LENGTH := 128
const ALLOWED_PARTICLE_TYPES: Array[String] = ["leaf", "pollution", "salmon"]
const ALLOWED_SUBTYPES: Array[String] = [
	"mixed",
	"material",
	"heat",
	"top",
	"bottom",
	"default",
]

var _udp: PacketPeerUDP
var _send_peers: Dictionary = {}
var _session_id: String = ""
var _registered_stages: Dictionary = {}
var _published_water_states: Dictionary = {}
var _published_water_last_sent_msec: Dictionary = {}
var _latest_water_by_source: Dictionary = {}
var _water_receive_state: Dictionary = {}
var _source_sequences: Dictionary = {}
var _pending_events: Dictionary = {}
var _completed_outbound_events: Dictionary = {}
var _completed_outbound_event_order: Array[String] = []
var _received_events: Dictionary = {}
var _received_event_order: Array[String] = []
var _scheduled_inbound_events: Dictionary = {}
var _last_error: String = ""
var _counters := {
	"packets_received": 0,
	"packets_sent": 0,
	"packets_rejected": 0,
	"water_snapshots_sent": 0,
	"water_snapshots_applied": 0,
	"water_snapshots_stale_ignored": 0,
	"water_sources_expired": 0,
	"particle_batches_sent": 0,
	"particle_batches_scheduled": 0,
	"particle_batches_applied": 0,
	"particle_batch_duplicates": 0,
	"particle_batch_retries": 0,
	"particle_batch_acks_sent": 0,
	"particle_batch_acks_received": 0,
	"particle_batches_expired": 0,
	"particle_batches_retained_for_bridge": 0,
	"bridge_polls": 0,
	"bridge_events_returned": 0,
	"bridge_event_acks_received": 0,
	"bridge_deliveries_accepted": 0,
	"bridge_deliveries_rejected": 0,
}


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_session_id = _new_session_id()
	start_listening()


func _process(delta: float) -> void:
	var now_msec := Time.get_ticks_msec()
	_read_available_packets()
	_advance_scheduled_inbound_events(delta)
	_resend_water_snapshots(now_msec)
	_retry_pending_events(now_msec)
	_expire_stale_water_states(now_msec)
	_prune_invalid_stages()


func _exit_tree() -> void:
	stop_listening()


func start_listening() -> Error:
	stop_listening()
	_udp = PacketPeerUDP.new()
	var bind_error := _udp.bind(UDP_PORT, BIND_ADDRESS)
	if bind_error != OK:
		var reason := "ParticleConfluenceBus could not bind UDP %s:%d (error %d)." % [
			BIND_ADDRESS,
			UDP_PORT,
			bind_error,
		]
		_udp.close()
		_udp = null
		_record_transport_error(reason)
		return bind_error
	listening_started.emit(UDP_PORT, BIND_ADDRESS)
	return OK


func stop_listening() -> void:
	if _udp != null:
		_udp.close()
		_udp = null
	for peer_variant: Variant in _send_peers.values():
		var peer := peer_variant as PacketPeerUDP
		if peer != null:
			peer.close()
	_send_peers.clear()


func is_listening() -> bool:
	return _udp != null


func register_stage(stage: Node) -> bool:
	## Register one loaded GPU stage in this process. The node must implement
	## get_screen_id(). Duplicate live owners for a screen are rejected.
	if stage == null or not is_instance_valid(stage):
		return false
	if not stage.has_method(&"get_screen_id"):
		return false
	var screen_id := String(stage.call(&"get_screen_id")).strip_edges()
	if not Topology.is_known_screen(screen_id):
		return false
	var current := _stage_for_screen(screen_id)
	if (
		current != null
		and current != stage
		and not current.is_queued_for_deletion()
	):
		return false
	_registered_stages[screen_id] = weakref(stage)
	if screen_id == Topology.DELTA_SCREEN:
		_replay_latest_water_to_delta(stage)
	return true


func unregister_stage(stage: Node) -> void:
	if stage == null:
		return
	var screens_to_remove: Array[String] = []
	for screen_variant: Variant in _registered_stages:
		var screen_id := String(screen_variant)
		if _stage_for_screen(screen_id) == stage:
			screens_to_remove.append(screen_id)
	for screen_id: String in screens_to_remove:
		_registered_stages.erase(screen_id)
		_published_water_states.erase(screen_id)
		_published_water_last_sent_msec.erase(screen_id)


func publish_water_state(
	source_screen: StringName,
	state: Dictionary,
) -> bool:
	## Cache and immediately send absolute upstream water state to Delta. While
	## the source remains registered, the bus repeats the latest state at 5 Hz.
	var source := String(source_screen).strip_edges()
	if not Topology.is_upstream_screen(source) or _stage_for_screen(source) == null:
		return false
	var normalized := _normalize_water_state(state)
	if normalized.is_empty():
		return false
	_published_water_states[source] = normalized
	return _send_water_snapshot(source, Time.get_ticks_msec())


func publish_particle_batch(
	source_screen: StringName,
	particle_type: StringName,
	subtype: StringName,
	count: int,
	transit_delay_seconds: float = 0.0,
) -> String:
	## Publish one reliable leaf or pollution batch from an upstream stage to
	## Delta. Returns its stable event ID, or an empty string on validation
	## failure. The event remains queued and is retried until acknowledged, even
	## when the first socket send is temporarily unavailable.
	var source := String(source_screen).strip_edges()
	var normalized_type := String(particle_type).strip_edges().to_lower()
	if (
		normalized_type not in ["leaf", "pollution"]
		or not Topology.is_upstream_screen(source)
		or _stage_for_screen(source) == null
	):
		return ""
	return _publish_event_to_destination(
		source,
		normalized_type,
		String(subtype).strip_edges().to_lower(),
		count,
		transit_delay_seconds,
		[Topology.DELTA_SCREEN],
		Topology.DELTA_HOST,
	)


func publish_salmon_cohort(
	destination_screen: StringName,
	survivor_count: int,
	transit_delay_seconds: float = 0.0,
) -> String:
	## Publish the survivors from one 25-fish Delta cohort to exactly one named
	## upstream branch. A zero-survivor cohort has nothing to transmit and, like
	## invalid input, returns an empty event ID.
	var destination := String(destination_screen).strip_edges()
	if (
		survivor_count < 1
		or survivor_count > SALMON_ORIGIN_COUNT
		or not Topology.is_upstream_screen(destination)
		or not is_finite(transit_delay_seconds)
		or transit_delay_seconds < 0.0
		or _stage_for_screen(Topology.DELTA_SCREEN) == null
	):
		return ""
	return _publish_event_to_destination(
		Topology.DELTA_SCREEN,
		"salmon",
		"default",
		survivor_count,
		transit_delay_seconds,
		[destination],
		Topology.host_for_screen(destination),
		SALMON_ORIGIN_COUNT,
	)


func submit_packet(
	packet: Dictionary,
	sender_ip: String = "local",
	sender_port: int = 0,
) -> bool:
	## Inject a decoded packet through exactly the same validation, routing,
	## de-duplication, and acknowledgement path used by UDP. No socket is needed.
	_counters["packets_received"] += 1
	return _handle_packet(packet, sender_ip, sender_port)


func bridge_registered_screen_ids() -> Array[String]:
	## Exact stage ownership advertised to the trusted .11 pull bridge. Poll
	## requests must name this complete set; deliveries must name the event's one
	## exact destination so a dual-screen host can never fan a salmon cohort out.
	var screens: Array[String] = []
	for screen_variant: Variant in _registered_stages:
		var screen_id := String(screen_variant)
		if _stage_for_screen(screen_id) != null:
			screens.append(screen_id)
	screens.sort()
	return screens


func bridge_sender_is_authorized(sender_ip: String) -> bool:
	## Godot's denied Local Network permission still permits replies to inbound
	## FlowControlBus requests. Only the Governator bridge or same-host loopback
	## may inspect, relay, or acknowledge the semantic event outbox.
	return (
		Topology.is_local_sender(sender_ip)
		or sender_ip == Topology.DELTA_HOST
	)


func bridge_poll(event_acks: Array, max_events: int = BRIDGE_EVENT_PAGE_MAX) -> Dictionary:
	## Apply exact acknowledgements first, then return the oldest bounded page of
	## still-pending immutable particle packets. Pulling is non-destructive; an
	## event leaves the outbox only after its destination accepted or deduplicated
	## it and the bridge returns the matching producer-session acknowledgement.
	if max_events < 1 or max_events > BRIDGE_EVENT_PAGE_MAX:
		return _bridge_failure(
			"max_events must be inside 1..%d." % BRIDGE_EVENT_PAGE_MAX,
			"poll",
		)
	if event_acks.size() > BRIDGE_EVENT_PAGE_MAX:
		return _bridge_failure(
			"event_acks exceeds the bounded page size.",
			"poll",
		)
	var normalized_acks: Array[Dictionary] = []
	for ack_variant: Variant in event_acks:
		if not ack_variant is Dictionary:
			return _bridge_failure("Every event acknowledgement must be a dictionary.", "poll")
		var normalized_ack := _normalize_bridge_event_ack(Dictionary(ack_variant))
		if normalized_ack.is_empty():
			return _bridge_failure("A bridge event acknowledgement is malformed.", "poll")
		normalized_acks.append(normalized_ack)

	var ack_results: Array[Dictionary] = []
	for normalized_ack: Dictionary in normalized_acks:
		ack_results.append(_acknowledge_bridge_event(normalized_ack))

	var pending_records: Array[Dictionary] = []
	for pending_key_variant: Variant in _pending_events:
		var pending_key := String(pending_key_variant)
		var pending: Dictionary = _pending_events[pending_key]
		pending_records.append({
			"pending_key": pending_key,
			"created_msec": int(pending.get("created_msec", 0)),
			"event_id": String(pending.get("event_id", "")),
			"packet": Dictionary(pending.get("packet", {})).duplicate(true),
		})
	pending_records.sort_custom(Callable(self, &"_bridge_pending_record_less"))
	var events: Array[Dictionary] = []
	for record: Dictionary in pending_records:
		if events.size() >= max_events:
			break
		events.append(Dictionary(record["packet"]).duplicate(true))
	_counters["bridge_polls"] += 1
	_counters["bridge_events_returned"] += events.size()
	return {
		"accepted": true,
		"reason": "",
		"op": "poll",
		"source_session": _session_id,
		"events": events,
		"pending_event_count": _pending_events.size(),
		"ack_results": ack_results,
		"max_events": max_events,
	}


func bridge_deliver_event(packet: Dictionary, sender_ip: String) -> Dictionary:
	## Relay one raw confluence packet through the ordinary validator and receiver
	## ledger. An identical retry is terminal success without another stage effect;
	## the same identity with changed payload remains a hard rejection.
	if not bridge_sender_is_authorized(sender_ip):
		_counters["bridge_deliveries_rejected"] += 1
		return _bridge_failure("Particle bridge sender is not authorized.", "deliver")
	if (
		String(packet.get("protocol", "")) != PROTOCOL
		or String(packet.get("kind", "")).strip_edges().to_lower() != "particle_batch"
	):
		_counters["bridge_deliveries_rejected"] += 1
		return _bridge_failure("Bridge delivery must contain one confluence particle_batch.", "deliver")
	var source_screen := String(packet.get("source_screen", "")).strip_edges()
	var source_host := Topology.host_for_screen(source_screen)
	if source_host.is_empty():
		_counters["bridge_deliveries_rejected"] += 1
		return _bridge_failure("Bridge delivery source_screen is unknown.", "deliver")
	var duplicate_count_before := int(_counters["particle_batch_duplicates"])
	var scheduled_count_before := int(_counters["particle_batches_scheduled"])
	var applied_count_before := int(_counters["particle_batches_applied"])
	var previous_error := _last_error
	# The outer caller has already been authenticated as the trusted bridge.
	# Validate the immutable inner event exactly as if its topology owner sent it;
	# otherwise an upstream event relayed locally on .11 would be mistaken for a
	# forged Delta-origin packet and rejected by the ordinary route validator.
	var accepted := submit_packet(packet.duplicate(true), source_host, 0)
	var targets := _normalize_targets(packet.get("target_screens", []))
	var status := "rejected"
	if accepted:
		if int(_counters["particle_batch_duplicates"]) > duplicate_count_before:
			status = "duplicate"
		elif int(_counters["particle_batches_scheduled"]) > scheduled_count_before:
			status = "scheduled"
		elif int(_counters["particle_batches_applied"]) > applied_count_before:
			status = "applied"
		else:
			status = "accepted"
		_counters["bridge_deliveries_accepted"] += 1
	else:
		_counters["bridge_deliveries_rejected"] += 1
	var reason := ""
	if not accepted:
		reason = (
			_last_error
			if _last_error != previous_error and not _last_error.is_empty()
			else "Particle destination is not ready."
		)
	return {
		"accepted": accepted,
		"reason": reason,
		"op": "deliver",
		"status": status,
		"source_session": String(packet.get("session", "")),
		"source_screen": String(packet.get("source_screen", "")),
		"event_id": String(packet.get("event_id", "")),
		"recipient_screen_ids": targets if accepted else [],
	}


func runtime_summary() -> Dictionary:
	var screens := bridge_registered_screen_ids()
	var published_sources: Array[String] = []
	for source_variant: Variant in _published_water_states:
		published_sources.append(String(source_variant))
	published_sources.sort()
	var received_sources: Array[String] = []
	for source_variant: Variant in _latest_water_by_source:
		received_sources.append(String(source_variant))
	received_sources.sort()
	return {
		"protocol": PROTOCOL,
		"ack_protocol": ACK_PROTOCOL,
		"udp_port": UDP_PORT,
		"bind_address": BIND_ADDRESS,
		"listening": is_listening(),
		"outbound_peer_count": _send_peers.size(),
		"outbound_destinations": _send_peer_destinations(),
		"session": _session_id,
		"registered_screen_ids": screens,
		"published_water_source_ids": published_sources,
		"received_water_source_ids": received_sources,
		"pending_event_count": _pending_events.size(),
		"completed_outbound_event_count": _completed_outbound_events.size(),
		"bridge_event_page_max": BRIDGE_EVENT_PAGE_MAX,
		"pending_events_retained_after_direct_retry_ttl": true,
		"received_event_count": _received_events.size(),
		"scheduled_inbound_event_count": _scheduled_inbound_events.size(),
		"last_error": _last_error,
		"counters": _counters.duplicate(true),
	}


func _read_available_packets() -> void:
	var packet_count := 0
	packet_count = _read_packets_from_peer(_udp, packet_count)
	for peer_variant: Variant in _send_peers.values():
		if packet_count >= MAX_PACKETS_PER_FRAME:
			break
		packet_count = _read_packets_from_peer(
			peer_variant as PacketPeerUDP,
			packet_count,
		)


func _read_packets_from_peer(peer: PacketPeerUDP, packet_count: int) -> int:
	if peer == null:
		return packet_count
	while (
		peer.get_available_packet_count() > 0
		and packet_count < MAX_PACKETS_PER_FRAME
	):
		packet_count += 1
		var raw := peer.get_packet()
		var sender_ip := peer.get_packet_ip()
		var sender_port := peer.get_packet_port()
		_counters["packets_received"] += 1
		if raw.size() > MAX_PACKET_BYTES:
			_reject_packet("Packet exceeds the 16384-byte limit.", sender_ip, sender_port)
			continue
		var parser := JSON.new()
		var parse_error := parser.parse(raw.get_string_from_utf8())
		if parse_error != OK or not parser.data is Dictionary:
			_reject_packet("Packet must be one valid JSON object.", sender_ip, sender_port)
			continue
		_handle_packet(Dictionary(parser.data), sender_ip, sender_port)
	return packet_count


func _handle_packet(packet: Dictionary, sender_ip: String, sender_port: int) -> bool:
	var protocol := String(packet.get("protocol", ""))
	if protocol == ACK_PROTOCOL:
		return _handle_ack(packet, sender_ip, sender_port)
	if protocol != PROTOCOL:
		return _reject_packet(
			"Unsupported confluence protocol '%s'." % protocol,
			sender_ip,
			sender_port,
		)
	match String(packet.get("kind", "")).strip_edges().to_lower():
		"water_state":
			return _handle_water_state(packet, sender_ip, sender_port)
		"particle_batch":
			return _handle_particle_batch(packet, sender_ip, sender_port)
		_:
			return _reject_packet(
				"Unknown confluence packet kind.",
				sender_ip,
				sender_port,
			)


func _handle_water_state(
	packet: Dictionary,
	sender_ip: String,
	sender_port: int,
) -> bool:
	var common := _normalize_common_packet(packet, sender_ip, sender_port)
	if common.is_empty():
		return false
	var source := String(common["source_screen"])
	var target := String(packet.get("target_screen", "")).strip_edges()
	if (
		not Topology.sender_owns_screen(sender_ip, source)
		or not Topology.valid_water_route(source, target)
	):
		return _reject_packet(
			"Unauthorized water-state route from '%s' to '%s'." % [source, target],
			sender_ip,
			sender_port,
		)
	var state_variant: Variant = packet.get("water", {})
	if not state_variant is Dictionary:
		return _reject_packet("Water state must be a dictionary.", sender_ip, sender_port)
	var state := _normalize_water_state(Dictionary(state_variant))
	if state.is_empty():
		return _reject_packet("Water state fields are invalid.", sender_ip, sender_port)
	var session := String(common["session"])
	var sequence := int(common["seq"])
	var receive_state: Dictionary = _water_receive_state.get(source, {})
	if (
		String(receive_state.get("session", "")) == session
		and sequence <= int(receive_state.get("seq", -1))
	):
		_counters["water_snapshots_stale_ignored"] += 1
		return true
	var now_msec := Time.get_ticks_msec()
	_water_receive_state[source] = {
		"session": session,
		"seq": sequence,
		"last_received_msec": now_msec,
		"expired": false,
	}
	var routed_state := state.duplicate(true)
	routed_state["session"] = session
	routed_state["seq"] = sequence
	routed_state["stale"] = false
	_latest_water_by_source[source] = routed_state
	var recipient_count := _deliver_water_state(source, routed_state)
	_counters["water_snapshots_applied"] += 1
	water_state_received.emit(StringName(source), routed_state.duplicate(true), recipient_count)
	return true


func _handle_particle_batch(
	packet: Dictionary,
	sender_ip: String,
	sender_port: int,
) -> bool:
	var common := _normalize_common_packet(packet, sender_ip, sender_port)
	if common.is_empty():
		return false
	var source := String(common["source_screen"])
	if not Topology.sender_owns_screen(sender_ip, source):
		return _reject_packet(
			"Sender does not own particle source '%s'." % source,
			sender_ip,
			sender_port,
		)
	var particle_type := String(packet.get("particle_type", "")).strip_edges().to_lower()
	var subtype := String(packet.get("subtype", "default")).strip_edges().to_lower()
	var targets_result := _normalize_targets(packet.get("target_screens", []))
	if targets_result.is_empty():
		return _reject_packet("Particle target_screens are invalid.", sender_ip, sender_port)
	var targets: Array[String] = targets_result
	if (
		particle_type not in ALLOWED_PARTICLE_TYPES
		or subtype not in ALLOWED_SUBTYPES
		or not Topology.valid_particle_route(source, particle_type, targets)
		or not Topology.targets_belong_to_one_host(targets)
	):
		return _reject_packet(
			"Unauthorized or unsupported particle-batch route.",
			sender_ip,
			sender_port,
		)
	var count_value: Variant = packet.get("count", null)
	if not _is_integral_number(count_value):
		return _reject_packet("Particle count must be an integer.", sender_ip, sender_port)
	var count := int(count_value)
	if count < 1 or count > MAX_EVENT_COUNT:
		return _reject_packet("Particle count is outside 1..300.", sender_ip, sender_port)
	if particle_type == "salmon":
		var origin_count_value: Variant = packet.get("origin_count", null)
		var destination := String(packet.get(
			"destination_screen",
			"",
		)).strip_edges()
		if (
			not _is_integral_number(origin_count_value)
			or int(origin_count_value) != SALMON_ORIGIN_COUNT
			or count > SALMON_ORIGIN_COUNT
			or targets.size() != 1
			or destination != targets[0]
		):
			return _reject_packet(
				"Salmon must be survivors from one 25-fish cohort addressed to one branch.",
				sender_ip,
				sender_port,
			)
	var delay_value: Variant = packet.get("transit_delay_seconds", 0.0)
	if not _is_finite_number(delay_value) or float(delay_value) < 0.0:
		return _reject_packet("Transit delay must be finite and nonnegative.", sender_ip, sender_port)
	var event_id := String(packet.get("event_id", "")).strip_edges()
	if event_id.is_empty() or event_id.length() > MAX_TEXT_FIELD_LENGTH:
		return _reject_packet("Particle event_id must contain 1..128 characters.", sender_ip, sender_port)
	var event_key := "%s|%s|%s" % [source, String(common["session"]), event_id]
	var identity := {
		"particle_type": particle_type,
		"subtype": subtype,
		"count": count,
		"target_screens": targets.duplicate(),
		"transit_delay_seconds": float(delay_value),
	}
	if particle_type == "salmon":
		identity["origin_count"] = SALMON_ORIGIN_COUNT
		identity["destination_screen"] = targets[0]
	var record: Dictionary = _received_events.get(event_key, {})
	if (
		not record.is_empty()
		and Dictionary(record.get("identity", {})) != identity
	):
		return _reject_packet(
			"Particle event_id was reused with a different payload.",
			sender_ip,
			sender_port,
		)
	var delivered: Dictionary = record.get("delivered", {})
	if delivered.size() == targets.size():
		_counters["particle_batch_duplicates"] += 1
		_send_batch_ack(packet, sender_ip, sender_port, true, targets, "")
		return true
	if record.is_empty():
		_record_received_event(event_key, {
			"identity": identity.duplicate(true),
			"delivered": {},
			"last_seen_msec": 0,
		})
		record = _received_events[event_key]
		delivered = record["delivered"]
	record["last_seen_msec"] = Time.get_ticks_msec()
	var missing_stage := false
	for target: String in targets:
		if bool(delivered.get(target, false)):
			continue
		var stage := _stage_for_screen(target)
		if not _stage_is_ready_for_particle(stage, particle_type):
			missing_stage = true
			continue
		if float(delay_value) > 0.0:
			if not _schedule_inbound_particle(
				event_key,
				source,
				target,
				particle_type,
				subtype,
				count,
				event_id,
				float(delay_value),
			):
				missing_stage = true
				continue
			delivered[target] = true
			continue
		if not _deliver_particle_to_stage(
			stage,
			source,
			target,
			particle_type,
			subtype,
			count,
			event_id,
			0.0,
		):
			missing_stage = true
			continue
		delivered[target] = true
	if missing_stage or delivered.size() != targets.size():
		_send_batch_ack(
			packet,
			sender_ip,
			sender_port,
			false,
			_delivered_target_names(delivered),
			"One or more target stages are not ready.",
		)
		return false
	_send_batch_ack(packet, sender_ip, sender_port, true, targets, "")
	return true


func _handle_ack(packet: Dictionary, sender_ip: String, sender_port: int) -> bool:
	var event_id := String(packet.get("event_id", "")).strip_edges()
	var session := String(packet.get("session", "")).strip_edges()
	if event_id.is_empty() or session != _session_id:
		return _reject_packet("Acknowledgement identity does not match.", sender_ip, sender_port)
	var accepted_variant: Variant = packet.get("accepted", false)
	if not accepted_variant is bool:
		return _reject_packet("Acknowledgement accepted field must be boolean.", sender_ip, sender_port)
	if not bool(accepted_variant):
		# A not-ready receiver is expected during fleet startup. Keep retrying the
		# event, but only accept the response if it names a currently pending event
		# for this exact destination. A negative ACK must not become an identity
		# oracle for arbitrary event IDs.
		for pending_variant: Variant in _pending_events.values():
			var pending: Dictionary = pending_variant
			var pending_packet: Dictionary = pending.get("packet", {})
			if (
				String(pending.get("event_id", "")) == event_id
				and String(pending_packet.get("session", "")) == session
				and String(pending.get("destination_ip", "")) == sender_ip
			):
				return true
		return _reject_packet(
			"Acknowledgement matches no pending event.",
			sender_ip,
			sender_port,
		)
	var targets_result := _normalize_targets(packet.get("recipient_screen_ids", []))
	if targets_result.is_empty():
		return _reject_packet("Acknowledgement recipients are invalid.", sender_ip, sender_port)
	var recipients: Array[String] = targets_result
	var result := _acknowledge_outbound_event(
		session,
		"",
		event_id,
		recipients,
		sender_ip,
		false,
	)
	if bool(result.get("accepted", false)):
		return true
	return _reject_packet(
		String(result.get("reason", "Acknowledgement matches no pending event.")),
		sender_ip,
		sender_port,
	)


func _normalize_bridge_event_ack(ack: Dictionary) -> Dictionary:
	var source_session := String(ack.get("source_session", "")).strip_edges()
	var source_screen := String(ack.get("source_screen", "")).strip_edges()
	var event_id := String(ack.get("event_id", "")).strip_edges()
	var recipients := _normalize_targets(ack.get("recipient_screen_ids", []))
	if (
		source_session.is_empty()
		or source_session.length() > MAX_TEXT_FIELD_LENGTH
		or not Topology.is_known_screen(source_screen)
		or event_id.is_empty()
		or event_id.length() > MAX_TEXT_FIELD_LENGTH
		or recipients.is_empty()
	):
		return {}
	return {
		"source_session": source_session,
		"source_screen": source_screen,
		"event_id": event_id,
		"recipient_screen_ids": recipients,
	}


func _acknowledge_bridge_event(ack: Dictionary) -> Dictionary:
	var result := _acknowledge_outbound_event(
		String(ack["source_session"]),
		String(ack["source_screen"]),
		String(ack["event_id"]),
		Array(ack["recipient_screen_ids"]),
		"",
		true,
	)
	return {
		"source_session": String(ack["source_session"]),
		"source_screen": String(ack["source_screen"]),
		"event_id": String(ack["event_id"]),
		"recipient_screen_ids": Array(ack["recipient_screen_ids"]).duplicate(),
		"accepted": bool(result.get("accepted", false)),
		"status": String(result.get("status", "unknown_event")),
		"reason": String(result.get("reason", "")),
	}


func _acknowledge_outbound_event(
	source_session: String,
	source_screen: String,
	event_id: String,
	recipients: Array,
	destination_ip: String,
	via_bridge: bool,
) -> Dictionary:
	if source_session != _session_id:
		return {
			"accepted": false,
			"status": "stale_session",
			"reason": "Acknowledgement source_session is stale.",
		}
	var completed_key := _completed_outbound_event_key(
		source_screen,
		source_session,
		event_id,
	)
	if source_screen.is_empty():
		completed_key = _completed_outbound_event_key_for_event(
			source_session,
			event_id,
			destination_ip,
		)
	if not completed_key.is_empty() and _completed_outbound_events.has(completed_key):
		var completed: Dictionary = _completed_outbound_events[completed_key]
		if (
			Array(completed.get("recipient_screen_ids", [])) == recipients
			and (
				destination_ip.is_empty()
				or String(completed.get("destination_ip", "")) == destination_ip
			)
		):
			return {
				"accepted": true,
				"status": "already_acknowledged",
				"reason": "",
			}
		return {
			"accepted": false,
			"status": "recipient_mismatch",
			"reason": "Acknowledgement recipients do not match the completed event.",
		}

	var matching_key := ""
	for pending_key_variant: Variant in _pending_events:
		var pending_key := String(pending_key_variant)
		var pending: Dictionary = _pending_events[pending_key]
		var pending_packet: Dictionary = pending.get("packet", {})
		if (
			String(pending.get("event_id", "")) == event_id
			and String(pending_packet.get("session", "")) == source_session
			and (
				source_screen.is_empty()
				or String(pending_packet.get("source_screen", "")) == source_screen
			)
			and (
				destination_ip.is_empty()
				or String(pending.get("destination_ip", "")) == destination_ip
			)
		):
			matching_key = pending_key
			break
	if matching_key.is_empty():
		return {
			"accepted": false,
			"status": "unknown_event",
			"reason": "Acknowledgement matches no pending event.",
		}
	var pending: Dictionary = _pending_events[matching_key]
	var expected_targets := Array(pending.get("expected_targets", []))
	if expected_targets != recipients:
		return {
			"accepted": false,
			"status": "recipient_mismatch",
			"reason": "Acknowledgement recipients do not match.",
		}
	var pending_packet: Dictionary = pending.get("packet", {})
	_remember_completed_outbound_event(
		pending_packet,
		expected_targets,
		String(pending.get("destination_ip", "")),
	)
	_pending_events.erase(matching_key)
	_counters["particle_batch_acks_received"] += 1
	if via_bridge:
		_counters["bridge_event_acks_received"] += 1
	particle_batch_acknowledged.emit(
		event_id,
		String(pending.get("destination_ip", "")),
	)
	return {
		"accepted": true,
		"status": "acknowledged",
		"reason": "",
	}


func _normalize_common_packet(
	packet: Dictionary,
	sender_ip: String,
	sender_port: int,
) -> Dictionary:
	var source := String(packet.get("source_screen", "")).strip_edges()
	var session := String(packet.get("session", "")).strip_edges()
	var sequence_value: Variant = packet.get("seq", null)
	if not Topology.is_known_screen(source):
		_reject_packet("Unknown source_screen.", sender_ip, sender_port)
		return {}
	if session.is_empty() or session.length() > MAX_TEXT_FIELD_LENGTH:
		_reject_packet("Session must contain 1..128 characters.", sender_ip, sender_port)
		return {}
	if not _is_integral_number(sequence_value) or int(sequence_value) < 0:
		_reject_packet("Sequence must be a nonnegative integer.", sender_ip, sender_port)
		return {}
	return {"source_screen": source, "session": session, "seq": int(sequence_value)}


func _normalize_water_state(state: Dictionary) -> Dictionary:
	var rate: Variant = state.get("flow_rate", null)
	var heads: Variant = state.get("active_heads", 0)
	var speed: Variant = state.get("speed_pixels", 0.0)
	var paused: Variant = state.get("paused", false)
	if (
		not _is_finite_number(rate)
		or float(rate) < 0.0
		or float(rate) > 1.0
		or not _is_integral_number(heads)
		or int(heads) < 0
		or int(heads) > 2000
		or not _is_finite_number(speed)
		or float(speed) < 0.0
		or float(speed) > 2400.0
		or paused is not bool
	):
		return {}
	var exit_width: Variant = state.get(
		"exit_width_pixels",
		float(rate) * MAX_EXIT_WIDTH_PIXELS,
	)
	if (
		not _is_finite_number(exit_width)
		or float(exit_width) < 0.0
		or float(exit_width) > MAX_EXIT_WIDTH_PIXELS
	):
		return {}
	return {
		"flow_rate": float(rate),
		"active_heads": int(heads),
		"speed_pixels": float(speed),
		"paused": bool(paused),
		"exit_width_pixels": float(exit_width),
	}


func _normalize_targets(value: Variant) -> Array[String]:
	var result: Array[String] = []
	if not value is Array:
		return result
	for item: Variant in value:
		if not (item is String or item is StringName):
			return []
		var target := String(item).strip_edges()
		if not Topology.is_known_screen(target) or target in result:
			return []
		result.append(target)
	result.sort()
	return result


func _publish_event_to_destination(
	source: String,
	particle_type: String,
	subtype: String,
	count: int,
	transit_delay_seconds: float,
	targets: Array[String],
	destination_ip: String,
	origin_count: int = 0,
) -> String:
	var normalized_targets := targets.duplicate()
	normalized_targets.sort()
	if (
		count < 1
		or count > MAX_EVENT_COUNT
		or subtype not in ALLOWED_SUBTYPES
		or not is_finite(transit_delay_seconds)
		or transit_delay_seconds < 0.0
		or not Topology.valid_particle_route(source, particle_type, normalized_targets)
		or not Topology.targets_belong_to_one_host(normalized_targets)
		or Topology.host_for_screen(normalized_targets[0]) != destination_ip
		or (
			particle_type == "salmon"
			and (
				origin_count != SALMON_ORIGIN_COUNT
				or count > origin_count
			)
		)
		or _pending_events.size() >= MAX_PENDING_EVENTS
	):
		return ""
	var sequence := _next_sequence(source)
	var event_id := "%s:%s:%d" % [source, _session_id, sequence]
	var packet := {
		"protocol": PROTOCOL,
		"kind": "particle_batch",
		"session": _session_id,
		"event_id": event_id,
		"seq": sequence,
		"source_screen": source,
		"target_screens": normalized_targets.duplicate(),
		"particle_type": particle_type,
		"subtype": subtype,
		"count": count,
		"transit_delay_seconds": transit_delay_seconds,
	}
	if particle_type == "salmon":
		packet["origin_count"] = origin_count
		packet["destination_screen"] = normalized_targets[0]
	var pending_key := "%s@%s" % [event_id, destination_ip]
	var now_msec := Time.get_ticks_msec()
	_pending_events[pending_key] = {
		"event_id": event_id,
		"packet": packet,
		"destination_ip": destination_ip,
		"expected_targets": normalized_targets.duplicate(),
		"created_msec": now_msec,
		"last_sent_msec": now_msec,
		"attempts": 1,
	}
	_send_packet(packet, destination_ip, UDP_PORT)
	_counters["particle_batches_sent"] += 1
	return event_id


func _send_water_snapshot(source: String, now_msec: int) -> bool:
	var state_variant: Variant = _published_water_states.get(source, {})
	if not state_variant is Dictionary or Dictionary(state_variant).is_empty():
		return false
	var packet := {
		"protocol": PROTOCOL,
		"kind": "water_state",
		"session": _session_id,
		"seq": _next_sequence(source),
		"source_screen": source,
		"target_screen": Topology.DELTA_SCREEN,
		"water": Dictionary(state_variant).duplicate(true),
	}
	var sent := _send_packet(packet, Topology.DELTA_HOST, UDP_PORT)
	if sent:
		_published_water_last_sent_msec[source] = now_msec
		_counters["water_snapshots_sent"] += 1
	return sent


func _resend_water_snapshots(now_msec: int) -> void:
	for source_variant: Variant in _published_water_states:
		var source := String(source_variant)
		if _stage_for_screen(source) == null:
			continue
		var last_sent := int(_published_water_last_sent_msec.get(source, -1000000))
		if now_msec - last_sent >= WATER_SNAPSHOT_INTERVAL_MSEC:
			_send_water_snapshot(source, now_msec)


func _retry_pending_events(now_msec: int) -> void:
	for pending_key_variant: Variant in _pending_events:
		var pending_key := String(pending_key_variant)
		var pending: Dictionary = _pending_events[pending_key]
		if now_msec - int(pending["created_msec"]) >= EVENT_TTL_MSEC:
			# Direct Godot-to-Godot retries are only a fast path. Once their bounded
			# window closes, retain the semantic event for the permission-independent
			# .11 pull bridge instead of silently erasing it.
			if not bool(pending.get("direct_retry_expired", false)):
				pending["direct_retry_expired"] = true
				_counters["particle_batches_expired"] += 1
				_counters["particle_batches_retained_for_bridge"] += 1
			continue
		if now_msec - int(pending["last_sent_msec"]) < EVENT_RETRY_INTERVAL_MSEC:
			continue
		_send_packet(
			Dictionary(pending["packet"]),
			String(pending["destination_ip"]),
			UDP_PORT,
		)
		pending["last_sent_msec"] = now_msec
		pending["attempts"] = int(pending["attempts"]) + 1
		_counters["particle_batch_retries"] += 1


func _expire_stale_water_states(now_msec: int) -> void:
	for source_variant: Variant in _water_receive_state:
		var source := String(source_variant)
		var receive_state: Dictionary = _water_receive_state[source]
		if (
			bool(receive_state.get("expired", false))
			or now_msec - int(receive_state.get("last_received_msec", now_msec))
				< WATER_STALE_TIMEOUT_MSEC
		):
			continue
		receive_state["expired"] = true
		var stale_state: Dictionary = _latest_water_by_source.get(source, {}).duplicate(true)
		stale_state["flow_rate"] = 0.0
		stale_state["active_heads"] = 0
		stale_state["exit_width_pixels"] = 0.0
		stale_state["stale"] = true
		_latest_water_by_source[source] = stale_state
		var recipient_count := _deliver_water_state(source, stale_state)
		_counters["water_sources_expired"] += 1
		water_state_received.emit(StringName(source), stale_state.duplicate(true), recipient_count)


func _deliver_water_state(source: String, state: Dictionary) -> int:
	var delta_stage := _stage_for_screen(Topology.DELTA_SCREEN)
	if delta_stage == null or not delta_stage.has_method(&"set_confluence_water_state"):
		return 0
	var result: Variant = delta_stage.call(
		&"set_confluence_water_state",
		StringName(source),
		state.duplicate(true),
	)
	return 0 if result is bool and not bool(result) else 1


func _replay_latest_water_to_delta(delta_stage: Node) -> void:
	if not delta_stage.has_method(&"set_confluence_water_state"):
		return
	for source_variant: Variant in _latest_water_by_source:
		var source := String(source_variant)
		delta_stage.call(
			&"set_confluence_water_state",
			StringName(source),
			Dictionary(_latest_water_by_source[source]).duplicate(true),
		)


func _schedule_inbound_particle(
	event_key: String,
	source: String,
	target: String,
	particle_type: String,
	subtype: String,
	count: int,
	event_id: String,
	delay_seconds: float,
) -> bool:
	var scheduled_key := "%s|target:%s" % [event_key, target]
	if _scheduled_inbound_events.has(scheduled_key):
		return true
	if _scheduled_inbound_events.size() >= MAX_SCHEDULED_INBOUND_EVENTS:
		return false
	_scheduled_inbound_events[scheduled_key] = {
		"source_screen": source,
		"target_screen": target,
		"particle_type": particle_type,
		"subtype": subtype,
		"count": count,
		"event_id": event_id,
		"delay_seconds": delay_seconds,
		"remaining_seconds": delay_seconds,
	}
	_counters["particle_batches_scheduled"] += 1
	return true


func _advance_scheduled_inbound_events(delta: float) -> void:
	if delta <= 0.0 or _scheduled_inbound_events.is_empty():
		return
	var completed_keys: Array[String] = []
	for scheduled_key_variant: Variant in _scheduled_inbound_events:
		var scheduled_key := String(scheduled_key_variant)
		var scheduled: Dictionary = _scheduled_inbound_events[scheduled_key]
		var target := String(scheduled["target_screen"])
		var particle_type := String(scheduled["particle_type"])
		var stage := _stage_for_screen(target)
		if not _stage_is_ready_for_particle(stage, particle_type):
			continue
		if _stage_simulation_paused(stage):
			continue
		var remaining := maxf(
			float(scheduled["remaining_seconds"]) - delta,
			0.0,
		)
		scheduled["remaining_seconds"] = remaining
		if remaining > 0.0:
			continue
		if _deliver_particle_to_stage(
			stage,
			String(scheduled["source_screen"]),
			target,
			particle_type,
			String(scheduled["subtype"]),
			int(scheduled["count"]),
			String(scheduled["event_id"]),
			float(scheduled["delay_seconds"]),
		):
			completed_keys.append(scheduled_key)
	for scheduled_key: String in completed_keys:
		_scheduled_inbound_events.erase(scheduled_key)


func _deliver_particle_to_stage(
	stage: Node,
	source: String,
	target: String,
	particle_type: String,
	subtype: String,
	count: int,
	event_id: String,
	transit_delay_seconds: float,
) -> bool:
	var result: Variant = stage.call(
		&"queue_confluence_batch",
		StringName(source),
		StringName(particle_type),
		StringName(subtype),
		count,
		event_id,
	)
	if result is bool and not bool(result):
		return false
	_counters["particle_batches_applied"] += 1
	particle_batch_received.emit(
		StringName(source),
		StringName(target),
		StringName(particle_type),
		StringName(subtype),
		count,
		transit_delay_seconds,
		event_id,
	)
	return true


func _stage_is_ready_for_particle(stage: Node, particle_type: String) -> bool:
	if (
		stage == null
		or not is_instance_valid(stage)
		or stage.is_queued_for_deletion()
		or not stage.is_node_ready()
		or not stage.has_method(&"queue_confluence_batch")
	):
		return false
	if particle_type in ["leaf", "pollution"]:
		return _delta_stage_ready(stage)
	return true


func _stage_simulation_paused(stage: Node) -> bool:
	if is_inside_tree() and get_tree().paused:
		return true
	if stage.is_inside_tree() and not stage.can_process():
		return true
	if not stage.has_method(&"is_paused"):
		return false
	var paused_variant: Variant = stage.call(&"is_paused")
	return paused_variant is bool and bool(paused_variant)


func _delta_stage_ready(stage: Node) -> bool:
	if not stage.has_method(&"get_confluence_runtime_summary"):
		return true
	var summary_variant: Variant = stage.call(&"get_confluence_runtime_summary")
	if not summary_variant is Dictionary:
		return false
	var summary: Dictionary = summary_variant
	return bool(summary.get("is_delta", false)) and bool(summary.get("enabled", false))


func _send_batch_ack(
	message: Dictionary,
	sender_ip: String,
	sender_port: int,
	accepted: bool,
	recipients: Array[String],
	reason: String,
) -> void:
	var acknowledgement := {
		"protocol": ACK_PROTOCOL,
		"session": String(message.get("session", "")),
		"event_id": String(message.get("event_id", "")),
		"accepted": accepted,
		"reason": reason,
		"recipient_screen_ids": recipients.duplicate(),
	}
	if sender_port > 0 and not sender_ip.is_empty() and sender_ip != "local":
		if _send_bound_reply(acknowledgement, sender_ip, sender_port):
			_counters["particle_batch_acks_sent"] += 1


func _send_packet(packet: Dictionary, destination_ip: String, destination_port: int) -> bool:
	# Headless runs are smoke/tests in this installation. Never let them emit
	# confluence traffic onto the live gallery LAN; submit_packet() still covers
	# the full validation, routing, scheduling, retry, and de-duplication path.
	if DisplayServer.get_name() == "headless":
		return false
	var peer_key := _send_peer_key(destination_ip, destination_port)
	var peer := _send_peer_for(destination_ip, destination_port)
	if peer == null:
		return false
	var encoded := JSON.stringify(packet).to_utf8_buffer()
	if encoded.size() > MAX_PACKET_BYTES:
		_record_transport_error("Refusing to send an oversized confluence packet.")
		return false
	var send_error := peer.put_packet(encoded)
	if send_error != OK:
		_record_transport_error(
			"Could not send confluence packet to %s:%d (error %d)." % [
				destination_ip,
				destination_port,
				send_error,
			]
		)
		_drop_send_peer(peer_key)
		return false
	_counters["packets_sent"] += 1
	return true


func _send_bound_reply(
	packet: Dictionary,
	destination_ip: String,
	destination_port: int,
) -> bool:
	# Reliable batches originate on a connected ephemeral peer. Reply from the
	# well-known receive port so that connected peer accepts the ACK. Ordinary
	# snapshots and batches never use this bound socket for outbound traffic.
	if DisplayServer.get_name() == "headless" or _udp == null:
		return false
	var encoded := JSON.stringify(packet).to_utf8_buffer()
	if encoded.size() > MAX_PACKET_BYTES:
		_record_transport_error("Refusing to send an oversized confluence reply.")
		return false
	var address_error := _udp.set_dest_address(destination_ip, destination_port)
	if address_error != OK:
		_record_transport_error(
			"Could not address confluence reply to %s:%d (error %d)." % [
				destination_ip,
				destination_port,
				address_error,
			]
		)
		return false
	var send_error := _udp.put_packet(encoded)
	if send_error != OK:
		_record_transport_error(
			"Could not send confluence reply to %s:%d (error %d)." % [
				destination_ip,
				destination_port,
				send_error,
			]
		)
		return false
	_counters["packets_sent"] += 1
	return true


func _send_peer_for(
	destination_ip: String,
	destination_port: int,
) -> PacketPeerUDP:
	var peer_key := _send_peer_key(destination_ip, destination_port)
	var existing := _send_peers.get(peer_key) as PacketPeerUDP
	if existing != null:
		return existing
	var peer := PacketPeerUDP.new()
	var connect_error := peer.connect_to_host(destination_ip, destination_port)
	if connect_error != OK:
		peer.close()
		_record_transport_error(
			"Could not connect confluence sender to %s:%d (error %d)." % [
				destination_ip,
				destination_port,
				connect_error,
			]
		)
		return null
	_send_peers[peer_key] = peer
	return peer


func _drop_send_peer(peer_key: String) -> void:
	var peer := _send_peers.get(peer_key) as PacketPeerUDP
	if peer != null:
		peer.close()
	_send_peers.erase(peer_key)


func _send_peer_key(destination_ip: String, destination_port: int) -> String:
	return "%s:%d" % [destination_ip, destination_port]


func _send_peer_destinations() -> Array[String]:
	var destinations: Array[String] = []
	for peer_key_variant: Variant in _send_peers:
		destinations.append(String(peer_key_variant))
	destinations.sort()
	return destinations


func _bridge_pending_record_less(left: Dictionary, right: Dictionary) -> bool:
	var left_created := int(left.get("created_msec", 0))
	var right_created := int(right.get("created_msec", 0))
	if left_created != right_created:
		return left_created < right_created
	return String(left.get("event_id", "")) < String(right.get("event_id", ""))


func _bridge_failure(reason: String, operation: String) -> Dictionary:
	return {
		"accepted": false,
		"reason": reason,
		"op": operation,
	}


func _remember_completed_outbound_event(
	packet: Dictionary,
	recipients: Array,
	destination_ip: String,
) -> void:
	var source_screen := String(packet.get("source_screen", ""))
	var source_session := String(packet.get("session", ""))
	var event_id := String(packet.get("event_id", ""))
	var completed_key := _completed_outbound_event_key(
		source_screen,
		source_session,
		event_id,
	)
	if completed_key.is_empty():
		return
	var record := {
		"source_screen": source_screen,
		"source_session": source_session,
		"event_id": event_id,
		"recipient_screen_ids": recipients.duplicate(),
		"destination_ip": destination_ip,
	}
	if _completed_outbound_events.has(completed_key):
		_completed_outbound_events[completed_key] = record
		return
	while _completed_outbound_event_order.size() >= MAX_COMPLETED_OUTBOUND_EVENTS:
		var oldest_key: String = _completed_outbound_event_order.pop_front()
		_completed_outbound_events.erase(oldest_key)
	_completed_outbound_events[completed_key] = record
	_completed_outbound_event_order.append(completed_key)


func _completed_outbound_event_key(
	source_screen: String,
	source_session: String,
	event_id: String,
) -> String:
	if source_screen.is_empty() or source_session.is_empty() or event_id.is_empty():
		return ""
	return "%s|%s|%s" % [source_screen, source_session, event_id]


func _completed_outbound_event_key_for_event(
	source_session: String,
	event_id: String,
	destination_ip: String,
) -> String:
	for completed_key_variant: Variant in _completed_outbound_events:
		var completed_key := String(completed_key_variant)
		var completed: Dictionary = _completed_outbound_events[completed_key]
		if (
			String(completed.get("source_session", "")) == source_session
			and String(completed.get("event_id", "")) == event_id
			and String(completed.get("destination_ip", "")) == destination_ip
		):
			return completed_key
	return ""


func _record_received_event(event_key: String, record: Dictionary) -> void:
	if _received_events.has(event_key):
		_received_events[event_key] = record
		return
	while _received_event_order.size() >= MAX_RECEIVED_EVENTS:
		var oldest: String = _received_event_order.pop_front()
		_received_events.erase(oldest)
	_received_events[event_key] = record
	_received_event_order.append(event_key)


func _delivered_target_names(delivered: Dictionary) -> Array[String]:
	var targets: Array[String] = []
	for target_variant: Variant in delivered:
		if bool(delivered[target_variant]):
			targets.append(String(target_variant))
	targets.sort()
	return targets


func _stage_for_screen(screen_id: String) -> Node:
	var reference_variant: Variant = _registered_stages.get(screen_id, null)
	if not reference_variant is WeakRef:
		return null
	var stage_variant: Variant = (reference_variant as WeakRef).get_ref()
	if stage_variant is Node and is_instance_valid(stage_variant):
		return stage_variant as Node
	return null


func _prune_invalid_stages() -> void:
	var invalid_screens: Array[String] = []
	for screen_variant: Variant in _registered_stages:
		var screen_id := String(screen_variant)
		if _stage_for_screen(screen_id) == null:
			invalid_screens.append(screen_id)
	for screen_id: String in invalid_screens:
		_registered_stages.erase(screen_id)
		_published_water_states.erase(screen_id)
		_published_water_last_sent_msec.erase(screen_id)


func _next_sequence(source: String) -> int:
	var sequence := int(_source_sequences.get(source, 0)) + 1
	_source_sequences[source] = sequence
	return sequence


func _new_session_id() -> String:
	var crypto := Crypto.new()
	var random_bytes := crypto.generate_random_bytes(16)
	if not random_bytes.is_empty():
		return random_bytes.hex_encode()
	return "%d-%d" % [Time.get_unix_time_from_system(), Time.get_ticks_usec()]


func _is_finite_number(value: Variant) -> bool:
	return (
		(typeof(value) == TYPE_INT or typeof(value) == TYPE_FLOAT)
		and is_finite(float(value))
	)


func _is_integral_number(value: Variant) -> bool:
	return (
		_is_finite_number(value)
		and is_equal_approx(float(value), roundf(float(value)))
	)


func _reject_packet(reason: String, sender_ip: String, sender_port: int) -> bool:
	_last_error = reason
	_counters["packets_rejected"] += 1
	packet_error.emit(reason, sender_ip, sender_port)
	return false


func _record_transport_error(reason: String) -> void:
	_last_error = reason
	push_warning(reason)
	transport_error.emit(reason)
