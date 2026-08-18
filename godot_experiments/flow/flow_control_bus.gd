extends Node
## UDP transport and message router for independently running flow models.
##
## Add this script as a project autoload (for example, `FlowControlBus`).
## Flow model nodes join the `flow_models` group and implement:
##
##     func queue_control_message(message: Dictionary) -> void
##
## Modern packets use the `ink-flow/1` protocol. Packets from the original
## chair controller are normalized into that protocol before they are routed.

signal listening_started(port: int, bind_address: String)
signal packet_received(packet: Dictionary, sender_ip: String, sender_port: int)
signal packet_routed(message: Dictionary, recipient_count: int)
signal packet_error(reason: String, sender_ip: String, sender_port: int)
signal transport_error(reason: String)

const PROTOCOL := "ink-flow/1"
const ACK_PROTOCOL := "ink-flow/1-ack"
const FLOW_MODELS_GROUP := &"flow_models"
const DEFAULT_UDP_PORT := 5005
const DEFAULT_BIND_ADDRESS := "0.0.0.0"
const UDP_PORT_SETTING := "flow_control/udp_port"
const BIND_ADDRESS_SETTING := "flow_control/bind_address"
const MAX_PACKETS_PER_FRAME := 256
const PROCESS_GLOBAL_REGIME_PATHS: Array[String] = [
	"regimes.active_indices",
	"regimes.active_names",
	"active_regimes",
	"regimes.kinship",
	"regimes.agriculture",
	"regimes.ranch",
	"regimes.gold_rush",
	"regimes.water_projects",
	"regimes.hydropower",
	"regimes.tech",
	"regimes.watershed",
]

# These fields describe meaningful legacy controller state. Diagnostic values
# such as timestamp, temperature, and confidence can change continuously, so
# they are deliberately excluded from the de-duplication signature. They are
# still preserved in the routed message's `metadata` dictionary.
const LEGACY_STATE_KEYS: Array[String] = [
	"speed",
	"chairs",
	"n_occupied",
	"ring_alpha",
	"regime",
	"regime_name",
	"stale",
	"source",
]

const LEGACY_TOP_LEVEL_METADATA_KEYS: Array[String] = [
	"chairs",
	"n_occupied",
	"ring_alpha",
	"regime",
	"regime_name",
	"stale",
	"source",
	"timestamp",
	"temp_c",
	"vote",
]

var listen_port: int = DEFAULT_UDP_PORT
var listen_address: String = DEFAULT_BIND_ADDRESS

var _udp: PacketPeerUDP
var _legacy_revision: int = 0
var _protocol_revision: int = 0
var _last_global_regime_revision: int = -1
var _last_legacy_signature_by_route: Dictionary = {}
var _latest_legacy_message_by_route: Dictionary = {}
var _last_legacy_recipients_by_route: Dictionary = {}
var _warned_model_instance_ids: Dictionary = {}


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	start_listening()


func _process(_delta: float) -> void:
	if _udp == null:
		return

	var packets_read := 0
	while (
		_udp.get_available_packet_count() > 0
		and packets_read < MAX_PACKETS_PER_FRAME
	):
		packets_read += 1
		var raw_packet := _udp.get_packet()
		var sender_ip := _udp.get_packet_ip()
		var sender_port := _udp.get_packet_port()
		_parse_packet(raw_packet.get_string_from_utf8(), sender_ip, sender_port)


func _exit_tree() -> void:
	stop_listening()


func start_listening() -> Error:
	## Read the current project settings and start the UDP listener.
	## Calling this while already listening first closes the previous socket.
	stop_listening()

	listen_port = clampi(
		int(ProjectSettings.get_setting(UDP_PORT_SETTING, DEFAULT_UDP_PORT)),
		1,
		65535
	)
	listen_address = String(
		ProjectSettings.get_setting(BIND_ADDRESS_SETTING, DEFAULT_BIND_ADDRESS)
	).strip_edges()
	if listen_address.is_empty():
		listen_address = DEFAULT_BIND_ADDRESS

	_udp = PacketPeerUDP.new()
	var bind_error := _udp.bind(listen_port, listen_address)
	if bind_error != OK:
		var reason := "FlowControlBus could not bind UDP %s:%d (error %d)." % [
			listen_address,
			listen_port,
			bind_error,
		]
		_udp.close()
		_udp = null
		push_error(reason)
		transport_error.emit(reason)
		return bind_error

	listening_started.emit(listen_port, listen_address)
	return OK


func stop_listening() -> void:
	if _udp == null:
		return
	_udp.close()
	_udp = null


func restart_listening() -> Error:
	## Re-read project settings and rebind the UDP socket.
	return start_listening()


func is_listening() -> bool:
	return _udp != null


func submit_packet(
	packet: Dictionary,
	sender_ip: String = "local",
	sender_port: int = 0
) -> bool:
	## Inject an already-decoded packet through the same normalization and
	## routing path as UDP. This is useful for a local control scene or tests.
	return _handle_packet(packet, sender_ip, sender_port)


func route_control_message(message: Dictionary) -> int:
	## Route a normalized message directly. The target defaults to `*`.
	var target: Variant = message.get("target", "*")
	var recipient_count := 0

	for candidate in get_tree().get_nodes_in_group(FLOW_MODELS_GROUP):
		var model := candidate as Node
		if model == null or not is_instance_valid(model):
			continue
		if not _target_matches_model(target, model):
			continue
		if not model.has_method("queue_control_message"):
			_warn_missing_queue_method_once(model)
			continue

		# Each receiver gets an independent deep copy so one model cannot mutate
		# the message seen by another model in the same process.
		model.call("queue_control_message", message.duplicate(true))
		recipient_count += 1

	packet_routed.emit(message.duplicate(true), recipient_count)
	return recipient_count


func _parse_packet(text: String, sender_ip: String, sender_port: int) -> void:
	var parser := JSON.new()
	var parse_error := parser.parse(text)
	if parse_error != OK:
		_emit_packet_error(
			"Invalid JSON at line %d: %s" % [
				parser.get_error_line(),
				parser.get_error_message(),
			],
			sender_ip,
			sender_port
		)
		return

	if not (parser.data is Dictionary):
		_emit_packet_error(
			"The JSON packet must be an object/dictionary.",
			sender_ip,
			sender_port
		)
		return

	var packet: Dictionary = parser.data
	_handle_packet(packet, sender_ip, sender_port)


func _handle_packet(
	packet: Dictionary,
	sender_ip: String,
	sender_port: int
) -> bool:
	packet_received.emit(packet.duplicate(true), sender_ip, sender_port)

	if packet.has("protocol"):
		if String(packet["protocol"]) != PROTOCOL:
			_emit_packet_error(
				"Unsupported protocol '%s'. Expected '%s'." % [
					String(packet["protocol"]),
					PROTOCOL,
				],
				sender_ip,
				sender_port
			)
			return false

		var normalized := _normalize_protocol_packet(
			packet,
			sender_ip,
			sender_port
		)
		if normalized.is_empty():
			return false
		var global_result := _apply_process_global_regime_changes(
			normalized,
			sender_ip,
			sender_port,
		)
		if not bool(global_result.get("ok", false)):
			return false
		normalized = Dictionary(global_result.get("message", normalized))
		var recipient_count := route_control_message(normalized)
		_send_protocol_ack(
			normalized,
			sender_ip,
			sender_port,
			recipient_count,
		)
		return true

	if packet.has("speed"):
		return _handle_legacy_packet(packet, sender_ip, sender_port)

	_emit_packet_error(
		"Packet has neither protocol '%s' nor a legacy speed field." % PROTOCOL,
		sender_ip,
		sender_port
	)
	return false


func _normalize_protocol_packet(
	packet: Dictionary,
	sender_ip: String,
	sender_port: int
) -> Dictionary:
	var target_result := _normalize_target(packet.get("target", "*"))
	if not bool(target_result["ok"]):
		_emit_packet_error(
			String(target_result["error"]),
			sender_ip,
			sender_port
		)
		return {}

	var revision_value: Variant
	if packet.has("revision"):
		revision_value = packet["revision"]
		if (
			(
				typeof(revision_value) != TYPE_INT
				and typeof(revision_value) != TYPE_FLOAT
			)
			or not is_finite(float(revision_value))
			or float(revision_value) < 0.0
			or not is_equal_approx(
				float(revision_value),
				roundf(float(revision_value))
			)
		):
			_emit_packet_error(
				"The revision field must be a nonnegative integer.",
				sender_ip,
				sender_port
			)
			return {}
		_protocol_revision = maxi(_protocol_revision, int(revision_value))
	else:
		_protocol_revision += 1
		revision_value = _protocol_revision

	var changes_value: Variant = packet.get("changes", {})
	if not (changes_value is Dictionary):
		_emit_packet_error(
			"The changes field must be a dictionary.",
			sender_ip,
			sender_port
		)
		return {}

	var geometry_value: Variant = packet.get("geometry_ops", [])
	if not (geometry_value is Array):
		_emit_packet_error(
			"The geometry_ops field must be an array.",
			sender_ip,
			sender_port
		)
		return {}

	var actions_value: Variant = packet.get("actions", [])
	if not (actions_value is Array):
		_emit_packet_error(
			"The actions field must be an array.",
			sender_ip,
			sender_port
		)
		return {}

	# Preserve optional metadata and any future protocol fields while ensuring
	# the core envelope has stable types and defaults.
	var normalized: Dictionary = packet.duplicate(true)
	normalized["protocol"] = PROTOCOL
	normalized["revision"] = int(revision_value)
	normalized["target"] = target_result["target"]
	normalized["changes"] = (changes_value as Dictionary).duplicate(true)
	normalized["geometry_ops"] = (geometry_value as Array).duplicate(true)
	normalized["actions"] = (actions_value as Array).duplicate(true)
	return normalized


func _apply_process_global_regime_changes(
	message: Dictionary,
	sender_ip: String,
	sender_port: int,
) -> Dictionary:
	## Regime state belongs to the process-wide ModelRegimes autoload, not to an
	## individual stage. Apply it here so an absolute controller packet remains
	## effective even while the selector is visible or stages are still loading.
	## Remove consumed paths before stage routing to avoid applying one global
	## state once per hosted screen in a dual-window process.
	var model_regimes := get_node_or_null("/root/ModelRegimes")
	if model_regimes == null:
		return {"ok": true, "message": message}
	var changes_variant: Variant = message.get("changes", {})
	if not changes_variant is Dictionary:
		return {"ok": true, "message": message}
	var routed_changes: Dictionary = Dictionary(changes_variant).duplicate(true)
	var handled_paths: Array[String] = []
	for path_variant: Variant in Dictionary(changes_variant):
		var path := String(path_variant)
		if path in PROCESS_GLOBAL_REGIME_PATHS:
			handled_paths.append(path)
	if handled_paths.is_empty():
		return {"ok": true, "message": message}
	if handled_paths.size() > 1:
		_emit_packet_error(
			"A packet may contain only one process-global regime change path.",
			sender_ip,
			sender_port,
		)
		return {"ok": false, "message": {}}
	var revision := int(message.get("revision", 0))
	if revision < _last_global_regime_revision:
		_emit_packet_error(
			"Stale process-global regime revision %d; latest is %d." % [
				revision,
				_last_global_regime_revision,
			],
			sender_ip,
			sender_port,
		)
		return {"ok": false, "message": {}}
	var path := handled_paths[0]
	if revision > _last_global_regime_revision:
		var value: Variant = Dictionary(changes_variant)[path]
		var apply_ok := false
		match path:
			"regimes.active_indices":
				apply_ok = value is Array and bool(
					model_regimes.call(&"set_active_indices", value)
				)
			"regimes.active_names", "active_regimes":
				apply_ok = value is Array and bool(
					model_regimes.call(&"set_active_names", value)
				)
			"regimes.kinship":
				apply_ok = bool(model_regimes.call(&"set_regime_active", 0, bool(value)))
			"regimes.agriculture", "regimes.ranch":
				apply_ok = bool(model_regimes.call(&"set_regime_active", 1, bool(value)))
			"regimes.gold_rush":
				apply_ok = bool(model_regimes.call(&"set_regime_active", 2, bool(value)))
			"regimes.water_projects":
				apply_ok = bool(model_regimes.call(&"set_regime_active", 3, bool(value)))
			"regimes.hydropower":
				apply_ok = bool(model_regimes.call(&"set_regime_active", 4, bool(value)))
			"regimes.tech":
				apply_ok = bool(model_regimes.call(&"set_regime_active", 5, bool(value)))
			"regimes.watershed":
				apply_ok = bool(model_regimes.call(&"set_regime_active", 6, bool(value)))
		if not apply_ok:
			_emit_packet_error(
				"Invalid process-global regime change for path '%s'." % path,
				sender_ip,
				sender_port,
			)
			return {"ok": false, "message": {}}
		_last_global_regime_revision = revision
	routed_changes.erase(path)
	var routed_message := message.duplicate(true)
	routed_message["changes"] = routed_changes
	return {"ok": true, "message": routed_message}


func _send_protocol_ack(
	message: Dictionary,
	sender_ip: String,
	sender_port: int,
	recipient_count: int,
) -> void:
	if _udp == null or sender_port <= 0 or sender_ip.is_empty():
		return
	var active_indices: Array = []
	var regime_revision := 0
	var model_regimes := get_node_or_null("/root/ModelRegimes")
	if model_regimes != null:
		var snapshot: Dictionary = model_regimes.call(&"snapshot")
		active_indices = Array(snapshot.get("active_indices", [])).duplicate()
		regime_revision = int(snapshot.get("revision", 0))
	var metadata_variant: Variant = message.get("metadata", {})
	var request_id := ""
	if metadata_variant is Dictionary:
		request_id = String(Dictionary(metadata_variant).get("request_id", ""))
	var acknowledgement := {
		"protocol": ACK_PROTOCOL,
		"accepted": true,
		"revision": int(message.get("revision", 0)),
		"request_id": request_id,
		"recipient_count": recipient_count,
		"recipient_screen_ids": _recipient_screen_ids(message.get("target", "*")),
		"regime_active_indices": active_indices,
		"regime_revision": regime_revision,
	}
	var destination_error := _udp.set_dest_address(sender_ip, sender_port)
	if destination_error != OK:
		var destination_reason := (
			"FlowControlBus could not address acknowledgement to %s:%d (error %d)."
			% [sender_ip, sender_port, destination_error]
		)
		push_warning(destination_reason)
		transport_error.emit(destination_reason)
		return
	var send_error := _udp.put_packet(JSON.stringify(acknowledgement).to_utf8_buffer())
	if send_error != OK:
		var send_reason := (
			"FlowControlBus could not send acknowledgement to %s:%d (error %d)."
			% [sender_ip, sender_port, send_error]
		)
		push_warning(send_reason)
		transport_error.emit(send_reason)


func _recipient_screen_ids(target: Variant) -> Array[String]:
	var screen_ids: Array[String] = []
	for candidate in get_tree().get_nodes_in_group(FLOW_MODELS_GROUP):
		var model := candidate as Node
		if (
			model == null
			or not is_instance_valid(model)
			or not _target_matches_model(target, model)
		):
			continue
		var screen_id := ""
		if model.has_method(&"get_screen_id"):
			screen_id = String(model.call(&"get_screen_id"))
		else:
			var screen_variant: Variant = _property_value(model, "screen_id")
			if screen_variant != null:
				screen_id = String(screen_variant)
		if not screen_id.is_empty():
			screen_ids.append(screen_id)
	screen_ids.sort()
	return screen_ids


func _handle_legacy_packet(
	packet: Dictionary,
	sender_ip: String,
	sender_port: int
) -> bool:
	var speed_value: Variant = packet["speed"]
	if typeof(speed_value) != TYPE_INT and typeof(speed_value) != TYPE_FLOAT:
		_emit_packet_error(
			"The legacy speed field must be numeric.",
			sender_ip,
			sender_port
		)
		return false

	var target_result := _normalize_target(packet.get("target", "*"))
	if not bool(target_result["ok"]):
		_emit_packet_error(
			String(target_result["error"]),
			sender_ip,
			sender_port
		)
		return false

	var target: Variant = target_result["target"]
	var speed_step := clampf(float(speed_value), 0.0, 9.0)
	var legacy_signature := _legacy_state_signature(packet, target)
	# De-duplicate per destination rather than per sender address. The current
	# controller transmits the same packet to localhost and broadcast, and a
	# listener bound to all interfaces can receive both copies.
	var route_key := JSON.stringify(target)

	# The chair controller broadcasts an identical state at 60 Hz. Only a
	# meaningful speed/chair/regime change is queued, while the entire latest
	# packet remains available as metadata when such a change occurs.
	if _last_legacy_signature_by_route.get(route_key, "") == legacy_signature:
		_update_cached_legacy_metadata(route_key, packet, speed_step)

		# The autoload can receive controller state while the selector scene is
		# visible and no flow model exists. Replay the coalesced latest state once
		# when a model later joins (or when a scene replaces one model with
		# another), without queueing the unchanged 60 Hz packets in between.
		var recipients := _recipient_signature(target)
		if _last_legacy_recipients_by_route.get(route_key, "") != recipients:
			var cached_message: Dictionary = _latest_legacy_message_by_route.get(
				route_key,
				{}
			)
			if not cached_message.is_empty():
				route_control_message(cached_message)
			_last_legacy_recipients_by_route[route_key] = recipients
		return true
	_last_legacy_signature_by_route[route_key] = legacy_signature

	_legacy_revision += 1
	var normalized: Dictionary = {
		"protocol": PROTOCOL,
		"revision": _legacy_revision,
		"target": target,
		"changes": {"flow_rate": speed_step / 9.0},
		"geometry_ops": [],
		"actions": [],
		"metadata": packet.duplicate(true),
		"legacy": true,
		"legacy_speed": speed_step,
	}

	# Keep frequently used chair/regime fields directly accessible as well as
	# preserving the full original packet under `metadata`.
	for key in LEGACY_TOP_LEVEL_METADATA_KEYS:
		if packet.has(key):
			normalized[key] = packet[key]

	_latest_legacy_message_by_route[route_key] = normalized.duplicate(true)
	route_control_message(normalized)
	_last_legacy_recipients_by_route[route_key] = _recipient_signature(target)
	return true


func _legacy_state_signature(packet: Dictionary, target: Variant) -> String:
	var state: Dictionary = {"target": target}
	for key in LEGACY_STATE_KEYS:
		state[key] = packet.get(key, null)
	return JSON.stringify(state)


func _update_cached_legacy_metadata(
	route_key: String,
	packet: Dictionary,
	speed_step: float
) -> void:
	var cached_message: Dictionary = _latest_legacy_message_by_route.get(
		route_key,
		{}
	)
	if cached_message.is_empty():
		return

	cached_message["metadata"] = packet.duplicate(true)
	cached_message["legacy_speed"] = speed_step
	for key in LEGACY_TOP_LEVEL_METADATA_KEYS:
		if packet.has(key):
			cached_message[key] = packet[key]
		else:
			cached_message.erase(key)


func _recipient_signature(target: Variant) -> String:
	var instance_ids: Array[int] = []
	for candidate in get_tree().get_nodes_in_group(FLOW_MODELS_GROUP):
		var model := candidate as Node
		if model == null or not is_instance_valid(model):
			continue
		if not model.has_method("queue_control_message"):
			continue
		if _target_matches_model(target, model):
			instance_ids.append(model.get_instance_id())
	instance_ids.sort()
	return JSON.stringify(instance_ids)


func _normalize_target(target: Variant) -> Dictionary:
	if target is String or target is StringName:
		var single := String(target).strip_edges()
		if single.is_empty():
			return {
				"ok": false,
				"error": "A string target cannot be empty.",
			}
		return {"ok": true, "target": single}

	if target is Array:
		var normalized_targets: Array[String] = []
		for item in target:
			if not (item is String or item is StringName):
				return {
					"ok": false,
					"error": "Every item in a target array must be a string.",
				}
			var target_name := String(item).strip_edges()
			if target_name.is_empty():
				return {
					"ok": false,
					"error": "A target array cannot contain an empty string.",
				}
			if target_name not in normalized_targets:
				normalized_targets.append(target_name)
		return {"ok": true, "target": normalized_targets}

	return {
		"ok": false,
		"error": "The target field must be '*', a string, or an array of strings.",
	}


func _target_matches_model(target: Variant, model: Node) -> bool:
	if target is Array:
		for target_item in target:
			if _single_target_matches_model(String(target_item), model):
				return true
		return false

	return _single_target_matches_model(String(target), model)


func _single_target_matches_model(target_name: String, model: Node) -> bool:
	if target_name == "*":
		return true

	# A model may provide its own matching policy when aliases or more complex
	# addressing are needed.
	if model.has_method("accepts_control_target"):
		if bool(model.call("accepts_control_target", target_name)):
			return true

	if String(model.name) == target_name or String(model.get_path()) == target_name:
		return true

	# A target can also name a group, which is convenient for addressing a
	# subset of models without assigning every node a unique property.
	if model.is_in_group(StringName(target_name)):
		return true

	for method_name in ["get_control_target", "get_model_id", "get_screen_id"]:
		if model.has_method(method_name):
			if String(model.call(method_name)) == target_name:
				return true

	for property_name in ["control_target", "model_id", "screen_id", "target_id"]:
		var property_value: Variant = _property_value(model, property_name)
		if property_value != null and String(property_value) == target_name:
			return true

	return false


func _property_value(node: Node, property_name: String) -> Variant:
	for property_info in node.get_property_list():
		if String(property_info.get("name", "")) == property_name:
			return node.get(property_name)
	return null


func _warn_missing_queue_method_once(model: Node) -> void:
	var instance_id := model.get_instance_id()
	if _warned_model_instance_ids.has(instance_id):
		return
	_warned_model_instance_ids[instance_id] = true

	var reason := (
		"Node '%s' is in group '%s' but does not implement "
		+ "queue_control_message(Dictionary)."
	) % [model.get_path(), FLOW_MODELS_GROUP]
	push_warning(reason)
	transport_error.emit(reason)


func _emit_packet_error(
	reason: String,
	sender_ip: String,
	sender_port: int
) -> void:
	push_warning("FlowControlBus packet from %s:%d: %s" % [
		sender_ip,
		sender_port,
		reason,
	])
	packet_error.emit(reason, sender_ip, sender_port)
