extends Node

## Headless integration smoke test for the reusable flow model and control bus.
##
## Run from the Godot project directory:
##
##     Godot --headless --path . \
##       --scene res://flow/tests/flow_runtime_smoke.tscn

var _failures := PackedStringArray()
var _control_error_count: int = 0


func _ready() -> void:
	call_deferred(&"_run")


func _run() -> void:
	var packed_scene := load("res://flow/flow_model_2d.tscn") as PackedScene
	_expect(packed_scene != null, "The reusable flow scene must load.")
	if packed_scene == null:
		_finish()
		return

	var model := packed_scene.instantiate() as FlowModel2D
	_expect(model != null, "The reusable flow scene must instantiate as FlowModel2D.")
	if model == null:
		_finish()
		return

	model.screen_id = &"runtime_smoke"
	model.accept_keyboard_input = false
	model.control_error.connect(_on_control_error)
	add_child(model)
	await _settle()

	var snapshot: Dictionary = model.get_state_snapshot()
	var parameters: Dictionary = snapshot["parameters"]
	_expect(
		is_equal_approx(float(parameters["flow_rate"]), 0.5),
		"The default flow rate must be 0.5."
	)

	model.set_flow_rate(0.72)
	await _settle()
	parameters = model.get_state_snapshot()["parameters"]
	_expect(
		is_equal_approx(float(parameters["flow_rate"]), 0.72),
		"set_flow_rate() must update the live model."
	)

	model.set_gate_width(&"reservoir_main", 0.7)
	model.set_gate_open(&"reservoir_main", false)
	await _settle()
	var reservoir := _first_geometry(model, "reservoir")
	_expect(
		is_equal_approx(float(reservoir.get("outlet_width", -1.0)), 0.7),
		"The live reservoir gate width must update."
	)
	_expect(
		reservoir.get("gate_open", true) == false,
		"The live reservoir gate state must update."
	)

	model.upsert_geometry(
		&"circle",
		&"smoke_circle",
		{
			"x": 5.0,
			"y": 4.0,
			"radius": 0.5,
			"strength": 4.0,
			"bend": 1.0,
		}
	)
	await _settle()
	var circle := _geometry_by_id(model, "circle", "smoke_circle")
	_expect(not circle.is_empty(), "A runtime circle upsert must create geometry.")

	model.remove_geometry(&"circle", &"smoke_circle")
	await _settle()
	circle = _geometry_by_id(model, "circle", "smoke_circle")
	_expect(circle.is_empty(), "A runtime geometry removal must remove its ID.")

	var errors_before := _control_error_count
	model.apply_patch({
		"max_particles": 1500,
		"retention_capacity": 1500,
	})
	await _settle()
	parameters = model.get_state_snapshot()["parameters"]
	_expect(
		int(parameters["max_particles"]) == 300
			and int(parameters["retention_capacity"]) == 100,
		"An over-budget atomic patch must leave the previous pool intact."
	)
	_expect(
		_control_error_count == errors_before + 1,
		"A rejected atomic patch must emit control_error once."
	)

	var bus := get_node_or_null("/root/FlowControlBus") as Node
	_expect(bus != null, "FlowControlBus must be available as an autoload.")
	if bus != null:
		var model_regimes := get_node_or_null("/root/ModelRegimes") as Node
		_expect(model_regimes != null, "ModelRegimes must be available as an autoload.")
		if model_regimes != null:
			model_regimes.call(&"clear_regimes")
			var regime_submitted: bool = bool(bus.call(
				&"submit_packet",
				{
					"protocol": "ink-flow/1",
					"target": "*",
					"changes": {"regimes.active_indices": [0]},
				},
				"smoke-test",
				0,
			))
			_expect(
				regime_submitted,
				"A process-global regime packet must be accepted.",
			)
			var regime_snapshot: Dictionary = model_regimes.call(&"snapshot")
			_expect(
				Array(regime_snapshot.get("active_indices", [])) == [0],
				"The bus must apply Kinship directly to persistent ModelRegimes.",
			)
			model_regimes.call(&"clear_regimes")
		var submitted: bool = bool(bus.call(
			&"submit_packet",
			{
				"protocol": "ink-flow/1",
				"target": "runtime_smoke",
				"changes": {"noise_strength": 0.91},
			},
			"smoke-test",
			0
		))
		_expect(submitted, "The modern control envelope must be accepted.")
		await _settle()
		parameters = model.get_state_snapshot()["parameters"]
		_expect(
			is_equal_approx(float(parameters["noise_strength"]), 0.91),
			"Targeted modern control must reach the matching screen ID."
		)

		submitted = bool(bus.call(
			&"submit_packet",
			{"speed": 9, "target": "runtime_smoke"},
			"smoke-test",
			0
		))
		_expect(submitted, "A legacy speed packet must be accepted.")
		await _settle()
		parameters = model.get_state_snapshot()["parameters"]
		_expect(
			is_equal_approx(float(parameters["flow_rate"]), 1.0),
			"Legacy speed 9 must map to flow_rate 1.0."
		)

		var udp := PacketPeerUDP.new()
		var listen_port := int(bus.get("listen_port"))
		var destination_error: Error = udp.set_dest_address(
			"127.0.0.1",
			listen_port
		)
		_expect(destination_error == OK, "The UDP smoke sender must resolve localhost.")
		var wire_packet := JSON.stringify({
			"protocol": "ink-flow/1",
			"target": "runtime_smoke",
			"changes": {"separation_strength": 1.23},
			"metadata": {"request_id": "flow-runtime-smoke-ack"},
		}).to_utf8_buffer()
		var send_error: Error = udp.put_packet(wire_packet)
		_expect(send_error == OK, "The UDP smoke packet must send successfully.")
		# UDP arrival is asynchronous and the retained CPU fallback can take longer
		# than four physics frames on a busy installation machine. Poll for at most
		# one second at the 30 Hz project rate instead of making delivery timing a
		# performance assertion.
		var acknowledgement_received := false
		for _attempt in range(30):
			await get_tree().process_frame
			await get_tree().physics_frame
			while udp.get_available_packet_count() > 0:
				var ack_parser := JSON.new()
				if ack_parser.parse(udp.get_packet().get_string_from_utf8()) != OK:
					continue
				if not ack_parser.data is Dictionary:
					continue
				var acknowledgement: Dictionary = ack_parser.data
				acknowledgement_received = (
					String(acknowledgement.get("protocol", "")) == "ink-flow/1-ack"
					and String(acknowledgement.get("request_id", ""))
						== "flow-runtime-smoke-ack"
					and bool(acknowledgement.get("accepted", false))
					and int(acknowledgement.get("recipient_count", 0)) == 1
					and Array(acknowledgement.get("recipient_screen_ids", []))
						== ["runtime_smoke"]
				)
			parameters = model.get_state_snapshot()["parameters"]
			if (
				acknowledgement_received
				and is_equal_approx(float(parameters["separation_strength"]), 1.23)
			):
				break
		_expect(
			is_equal_approx(float(parameters["separation_strength"]), 1.23),
			"A UDP JSON packet must be decoded and routed to the target model."
		)
		_expect(
			acknowledgement_received,
			"The UDP sender must receive a matching ink-flow/1 acknowledgement.",
		)
		udp.close()

	model.queue_action(&"pause")
	await _settle()
	_expect(
		model.get_runtime_stats()["running"] == false,
		"The pause action must stop simulation advancement."
	)
	model.queue_action(&"resume")
	await _settle()
	_expect(
		model.get_runtime_stats()["running"] == true,
		"The resume action must restart simulation advancement."
	)

	_finish()


func _settle() -> void:
	await get_tree().physics_frame
	await get_tree().physics_frame


func _first_geometry(model: FlowModel2D, kind: String) -> Dictionary:
	var geometry: Dictionary = model.get_state_snapshot()["geometry"]
	var values: Array = geometry.get(kind, [])
	return {} if values.is_empty() else values[0]


func _geometry_by_id(
	model: FlowModel2D,
	kind: String,
	element_id: String
) -> Dictionary:
	var geometry: Dictionary = model.get_state_snapshot()["geometry"]
	var values: Array = geometry.get(kind, [])
	for value_variant in values:
		var value: Dictionary = value_variant
		if String(value.get("element_id", "")) == element_id:
			return value
	return {}


func _on_control_error(
	_screen_id: StringName,
	_message: String,
	_details: Dictionary
) -> void:
	_control_error_count += 1


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)


func _finish() -> void:
	if _failures.is_empty():
		print("FLOW_RUNTIME_SMOKE: PASS")
		get_tree().quit(0)
		return

	for failure in _failures:
		push_error("FLOW_RUNTIME_SMOKE: %s" % failure)
	print("FLOW_RUNTIME_SMOKE: FAIL (%d failures)" % _failures.size())
	get_tree().quit(1)
