extends Node

const STAGE_SCENE := preload("res://flow/gpu_stage/gpu_flow_stage_2d.tscn")
const TOPOLOGY := preload("res://flow/confluence_topology.gd")
const SOURCE_ORDER := [
	"mount_shasta",
	"mccloud_pit",
	"cottonwood_creek",
	"mill_creek",
	"feather_river",
	"american_river",
]

const SOURCES := {
	"mount_shasta": [Vector2(0.0, 120.0), Vector2.RIGHT, 480.0],
	"mccloud_pit": [Vector2(0.0, 840.0), Vector2.RIGHT, 480.0],
	"cottonwood_creek": [Vector2(1200.0, 1080.0), Vector2.UP, 1440.0],
	"mill_creek": [Vector2(360.0, 1080.0), Vector2.UP, 720.0],
	"feather_river": [Vector2(600.0, 0.0), Vector2.DOWN, 960.0],
	"american_river": [Vector2(1440.0, 0.0), Vector2.DOWN, 1680.0],
}
const EXPECTED_CURVES := {
	"mount_shasta": [
		Vector2(0.0, 120.0),
		Vector2(210.0, 120.0),
		Vector2(270.0, 540.0),
		Vector2(480.0, 540.0),
	],
	"mccloud_pit": [
		Vector2(0.0, 840.0),
		Vector2(180.0, 840.0),
		Vector2(300.0, 540.0),
		Vector2(480.0, 540.0),
	],
	"cottonwood_creek": [
		Vector2(1200.0, 1080.0),
		Vector2(1200.0, 840.0),
		Vector2(1260.0, 540.0),
		Vector2(1440.0, 540.0),
	],
	"mill_creek": [
		Vector2(360.0, 1080.0),
		Vector2(360.0, 840.0),
		Vector2(540.0, 540.0),
		Vector2(720.0, 540.0),
	],
	"feather_river": [
		Vector2(600.0, 0.0),
		Vector2(600.0, 240.0),
		Vector2(780.0, 540.0),
		Vector2(960.0, 540.0),
	],
	"american_river": [
		Vector2(1440.0, 0.0),
		Vector2(1440.0, 240.0),
		Vector2(1500.0, 540.0),
		Vector2(1680.0, 540.0),
	],
}

const STAGE_BOUNDS := Rect2(Vector2.ZERO, Vector2(1920.0, 1080.0))
const CURVE_SAMPLE_COUNT := 129
const MINIMUM_CURVATURE_RADIUS_PIXELS := 140.0
const FULL_FLOW_WIDTH_MILESTONE_COUNTS := {
	480.0: 0,
	600.0: 2,
	840.0: 3,
	1080.0: 4,
	1560.0: 5,
	1800.0: 6,
}
const MAXIMUM_SOURCE_WIDTH_PIXELS := 1024.0
const EXPLICIT_SOURCE_WIDTHS := {
	"mount_shasta": 30.0,
	"mccloud_pit": 40.0,
	"cottonwood_creek": 50.0,
	"mill_creek": 60.0,
	"feather_river": 70.0,
	"american_river": 80.0,
}

var _errors: Array[String] = []


func _ready() -> void:
	_expect(
		TOPOLOGY.inlet_for_screen("mount_shasta") == {
			"edge": "left",
			"gridline": 8,
		},
		"Shasta topology is not left gridline 8",
	)
	_expect(
		TOPOLOGY.inlet_for_screen("feather_river") == {
			"edge": "top",
			"gridline": 5,
		},
		"Feather topology is not top gridline 5",
	)
	var stage := STAGE_SCENE.instantiate()
	stage.set(&"screen_id", &"delta")
	stage.set(&"stage_index", 7)
	stage.set(&"delta_confluence_enabled", true)
	stage.set(&"regime_profile_physics_enabled", false)
	add_child(stage)
	for frame_index in range(3):
		await get_tree().process_frame

	_check_sparse_flow_coverage(stage)

	for source_id: String in SOURCE_ORDER:
		_expect(bool(stage.call(
			&"set_confluence_water_state",
			source_id,
			{
				"flow_rate": 0.50,
				"active_heads": 505,
				"speed_pixels": 300.0,
				"exit_width_pixels": EXPLICIT_SOURCE_WIDTHS[source_id],
				"paused": false,
			},
		)), "water state was rejected for %s" % source_id)

	var confluence: Dictionary = stage.call(&"get_confluence_runtime_summary")
	_expect(bool(confluence.get("enabled", false)), "Delta confluence is disabled")
	_expect(int(confluence.get("source_count", 0)) == 6, "source count is not six")
	var states: Dictionary = confluence.get("sources", {})
	for source_id: String in SOURCES:
		var actual: Dictionary = states.get(source_id, {})
		var expected: Array = SOURCES[source_id]
		_expect(
			Vector2(actual.get("anchor_pixels", Vector2.INF)) == expected[0]
			and Vector2(actual.get(
				"inward_direction_pixels",
				Vector2.INF,
			)) == expected[1]
			and is_equal_approx(
				float(actual.get("merge_x_pixels", -1.0)),
				float(expected[2]),
			)
			and int(actual.get("active_heads", 0)) > 0,
			"source geometry or live head allocation is wrong for %s" % source_id,
		)
		_expect(
			is_equal_approx(
				float(actual.get("exit_width_pixels", -1.0)),
				float(EXPLICIT_SOURCE_WIDTHS[source_id]),
			),
			"explicit delayed exit width was not retained for %s" % source_id,
		)
	for material_variant: Variant in stage.get("_process_material_layers"):
		var material := material_variant as ShaderMaterial
		_expect(
			material != null
			and bool(material.get_shader_parameter(&"confluence_mode"))
				and material.get_shader_parameter(&"confluence_source_0")
					== Vector4(0.0, 120.0, 1.0, 0.0)
				and material.get_shader_parameter(&"confluence_source_4")
					== Vector4(600.0, 0.0, 0.0, 1.0)
				and material.get_shader_parameter(&"confluence_merge_x_0")
					== Vector4(480.0, 480.0, 1440.0, 720.0)
				and material.get_shader_parameter(&"confluence_merge_x_1")
					== Vector4(960.0, 1680.0, 0.0, 0.0)
				and material.get_shader_parameter(&"confluence_source_widths_0")
					== Vector4(30.0, 40.0, 50.0, 60.0)
				and material.get_shader_parameter(&"confluence_source_widths_1")
					== Vector4(70.0, 80.0, 0.0, 0.0)
				and is_equal_approx(float(material.get_shader_parameter(
					&"confluence_trunk_center_y_pixels"
				)), 540.0)
				and is_equal_approx(float(material.get_shader_parameter(
					&"confluence_trunk_base_width_pixels"
				)), 42.0)
				and is_equal_approx(float(material.get_shader_parameter(
					&"confluence_trunk_width_transition_pixels"
				)), 120.0)
				and is_equal_approx(float(material.get_shader_parameter(
					&"confluence_curve_follow_strength"
				)), 6.0),
				"one water layer lost the curved, widening confluence contract",
			)
	var flow_material := stage.get("_process_material") as ShaderMaterial
	var flow_shader: Shader = flow_material.shader if flow_material != null else null
	var flow_shader_code := flow_shader.code if flow_shader != null else ""
	_expect(
		flow_shader_code.contains(
			"uniform vec4 confluence_source_0 = vec4(0.0, 120.0, 1.0, 0.0);"
		),
		"Shasta shader default is not left gridline 8",
	)
	_expect(
		flow_shader_code.contains(
			"uniform vec4 confluence_source_4 = vec4(600.0, 0.0, 0.0, 1.0);"
		),
		"Feather shader default is not top gridline 5",
	)
	_expect(
		flow_shader_code.contains("STATE_CONFLUENCE_DORMANT")
		and flow_shader_code.contains(
			"confluence_slot_dormant && flow_slot_enabled(particle_index)"
		)
		and flow_shader_code.contains(
			"bool process_regular_flow = !confluence_slot_dormant"
		)
		and flow_shader_code.count("STATE_CONFLUENCE_DORMANT);") >= 3,
		"zero-count Delta slots cannot wake when later water states arrive",
	)
	_expect(
		String(confluence.get("curve_mode", ""))
			== "CUBIC_BEZIER_TO_SHARED_TRUNK"
		and String(confluence.get("trunk_width_model", ""))
			== "BOUNDED_QUADRATURE_SOURCE_WIDTHS"
		and String(confluence.get("source_width_model", ""))
			== "DELAYED_UPSTREAM_EXIT_WIDTH_PIXELS"
		and String(confluence.get("source_width_legacy_fallback", ""))
			== "1024_X_FLOW_RATE"
		and is_equal_approx(float(confluence.get(
			"trunk_maximum_full_flow_width_pixels",
			0.0,
		)), MAXIMUM_SOURCE_WIDTH_PIXELS),
			"Delta does not report its smooth shared trunk and cumulative width",
		)
	_check_curve_contract(confluence)
	_check_explicit_width_contract(stage)
	_check_full_flow_width(stage)

	_expect(bool(stage.call(
		&"queue_confluence_batch",
		"mount_shasta",
		"leaf",
		"mixed",
		2,
		"leaf-smoke-1",
	)), "Shasta leaf handoff was rejected")
	var leaf_field: Node = stage.get("_leaf_field")
	var leaf_after: Dictionary = leaf_field.call(&"runtime_summary")
	_expect(
		int(leaf_after.get("source_last_scheduled_count", 0)) == 2,
		"leaf handoff did not schedule exactly two leaves",
	)
	_expect(bool(stage.call(
		&"queue_confluence_batch",
		"mount_shasta",
		"leaf",
		"mixed",
		2,
		"leaf-smoke-1",
	)), "duplicate leaf handoff was not acknowledged")
	_expect(
		int(Dictionary(leaf_field.call(&"runtime_summary")).get(
			"source_total_scheduled",
			0,
		)) == 2,
		"duplicate leaf handoff rendered twice",
	)

	_expect(bool(stage.call(
		&"queue_confluence_batch",
		"mount_shasta",
		"pollution",
		"heat",
		3,
		"pollution-smoke-1",
	)), "Shasta pollution handoff was rejected")
	var pollution_field: Node = stage.get("_pollution_field")
	var pollution_summary: Dictionary = pollution_field.call(&"runtime_summary")
	_expect(
		int(pollution_summary.get("last_scheduled_count", 0)) == 3,
		"pollution handoff did not schedule exactly three disks",
	)
	var pollution_control: Image = pollution_field.get("_control_image")
	_expect(
		is_equal_approx(pollution_control.get_pixel(0, 0).a, 4.0)
		and Vector2(
			pollution_control.get_pixel(0, 1).b,
			pollution_control.get_pixel(0, 1).a,
		) == Vector2.RIGHT,
		"heat pollution was not encoded as a latched left-edge entry",
	)

	var survivor_counts := {
		"mount_shasta": 0,
		"mccloud_pit": 5,
		"cottonwood_creek": 10,
		"mill_creek": 15,
		"feather_river": 20,
		"american_river": 25,
	}
	_expect(
		int(stage.call(&"release_delta_salmon_cohorts", survivor_counts)) == 150,
		"six joint 25-salmon cohorts were not scheduled",
	)
	var salmon_field: Node = stage.get("_salmon_school")
	var salmon_summary: Dictionary = salmon_field.call(&"runtime_summary")
	_expect(
		int(salmon_summary.get("last_cohort_count", 0)) == 6
		and int(salmon_summary.get("last_cohort_scheduled_count", 0)) == 150
		and int(salmon_summary.get("last_cohort_survivor_count", 0)) == 75
		and int(salmon_summary.get("last_cohort_death_count", 0)) == 75,
		"Delta salmon survivor/death accounting is incorrect",
	)
	confluence = stage.call(&"get_confluence_runtime_summary")
	_expect(
		int(confluence.get("pending_salmon_handoffs", -1)) == 5,
		"zero-survivor cohort was queued for an upstream handoff",
	)
	var handoffs: Array = confluence.get("last_salmon_handoffs", [])
	_expect(handoffs.size() == 6, "Delta did not retain all six handoff timings")
	var expected_transit_speed := maxf(
		float(salmon_field.get("upstream_speed_pixels")),
		1.0,
	)
	var expected_edge_clear := maxf(
		float(salmon_field.get("streak_length_pixels")),
		1.0,
	)
	var distinct_group_offsets: Dictionary = {}
	for handoff_variant: Variant in handoffs:
		if not handoff_variant is Dictionary:
			_expect(false, "Delta retained a malformed salmon handoff timing")
			continue
		var handoff: Dictionary = handoff_variant
		var destination := String(handoff.get("destination_screen", ""))
		if not SOURCES.has(destination):
			_expect(false, "Delta retained a timing for an unknown salmon destination")
			continue
		var expected: Array = SOURCES[destination]
		var destination_anchor: Vector2 = expected[0]
		var merge_x := float(expected[2])
		var trunk_distance := float(handoff.get("trunk_distance_pixels", -1.0))
		var route_arc_length := float(handoff.get("route_arc_length_pixels", -1.0))
		var route_polygon_length := float(handoff.get(
			"route_control_polygon_length_pixels",
			-1.0,
		))
		var edge_clear_distance := float(handoff.get(
			"edge_clear_distance_pixels",
			-1.0,
		))
		var transit_distance := float(handoff.get("transit_distance_pixels", -1.0))
		var transit_speed := float(handoff.get("transit_speed_pixels", -1.0))
		var transit_seconds := float(handoff.get("transit_seconds", -1.0))
		var head_arrival_seconds := float(handoff.get(
			"head_arrival_seconds",
			-1.0,
		))
		var spawn_stagger_seconds := float(handoff.get(
			"spawn_stagger_seconds",
			-1.0,
		))
		var group_offset_seconds := float(handoff.get(
			"group_offset_seconds",
			-1.0,
		))
		distinct_group_offsets[roundi(group_offset_seconds * 1000000.0)] = true
		var trail_clear_seconds := float(handoff.get(
			"trail_clear_seconds",
			-1.0,
		))
		var gpu_start_guard_seconds := float(handoff.get(
			"gpu_start_guard_seconds",
			-1.0,
		))
		var merge_point := Vector2(merge_x, 540.0)
		var direct_distance := Vector2(1920.0, 540.0).distance_to(
			destination_anchor
		)
		_expect(
			is_equal_approx(trunk_distance, 1920.0 - merge_x)
			and route_arc_length > destination_anchor.distance_to(merge_point)
			and route_polygon_length > route_arc_length
			and is_equal_approx(edge_clear_distance, expected_edge_clear)
			and is_equal_approx(
				head_arrival_seconds,
				group_offset_seconds
					+ spawn_stagger_seconds
					+ (trunk_distance + route_polygon_length) / transit_speed,
			)
			and is_equal_approx(spawn_stagger_seconds, 2.5)
			and group_offset_seconds >= 0.0
			and group_offset_seconds <= 6.0
			and trail_clear_seconds >= edge_clear_distance / transit_speed
			and is_equal_approx(gpu_start_guard_seconds, 0.5)
			and is_equal_approx(
				transit_seconds,
				head_arrival_seconds
					+ trail_clear_seconds
					+ gpu_start_guard_seconds,
			)
			and is_equal_approx(transit_distance, transit_seconds * transit_speed)
			and transit_distance > direct_distance
			and is_equal_approx(transit_speed, expected_transit_speed)
			and int(handoff.get("route_arc_sample_count", 0)) == 32,
			"%s handoff did not follow the bounded GPU route + trail-clear timing"
				% destination,
		)
	_expect(
		distinct_group_offsets.size() == 6,
		"Delta handoff deadlines did not retain six varied destination offsets",
	)

	if _errors.is_empty():
		print("DELTA_CONFLUENCE_SMOKE: PASS")
		get_tree().quit(0)
	else:
		for error: String in _errors:
			push_error("DELTA_CONFLUENCE_SMOKE: %s" % error)
		get_tree().quit(1)


func _check_sparse_flow_coverage(stage: Node) -> void:
	for source_id: String in SOURCE_ORDER:
		_expect(bool(stage.call(
			&"set_confluence_water_state",
			source_id,
			{
				"flow_rate": 0.01,
				"active_heads": 1,
				"speed_pixels": 30.0,
				"paused": false,
			},
		)), "sparse water state was rejected for %s" % source_id)

	var sparse_summary: Dictionary = stage.call(&"get_confluence_runtime_summary")
	var sparse_states: Dictionary = sparse_summary.get("sources", {})
	var expected_counts: Array[int] = []
	for source_id: String in SOURCE_ORDER:
		var source_state: Dictionary = sparse_states.get(source_id, {})
		var active_heads := int(source_state.get("active_heads", 0))
		expected_counts.append(active_heads)
		_expect(
			active_heads > 0
			and is_equal_approx(float(source_state.get("flow_rate", -1.0)), 0.01)
			and is_equal_approx(
				float(source_state.get("exit_width_pixels", -1.0)),
				10.24,
			),
			"0.01 flow did not keep %s visibly active" % source_id,
		)

	for material_variant: Variant in stage.get("_process_material_layers"):
		var material := material_variant as ShaderMaterial
		if material == null:
			_expect(false, "sparse-flow coverage found a missing process material")
			continue
		var counts_0: Vector4 = material.get_shader_parameter(
			&"confluence_active_counts_0"
		)
		var counts_1: Vector4 = material.get_shader_parameter(
			&"confluence_active_counts_1"
		)
		var widths_0: Vector4 = material.get_shader_parameter(
			&"confluence_source_widths_0"
		)
		var widths_1: Vector4 = material.get_shader_parameter(
			&"confluence_source_widths_1"
		)
		var uploaded_counts := [
			counts_0.x,
			counts_0.y,
			counts_0.z,
			counts_0.w,
			counts_1.x,
			counts_1.y,
		]
		for source_index in range(SOURCE_ORDER.size()):
			_expect(
				float(uploaded_counts[source_index]) > 0.0
				and is_equal_approx(
					float(uploaded_counts[source_index]),
					float(expected_counts[source_index]),
				),
				"sparse active count for %s was not uploaded to every layer"
					% SOURCE_ORDER[source_index],
			)
		_expect(
			widths_0.is_equal_approx(Vector4(10.24, 10.24, 10.24, 10.24))
			and widths_1.is_equal_approx(Vector4(10.24, 10.24, 0.0, 0.0)),
			"legacy flow-rate widths were not uploaded to every layer",
		)


func _check_explicit_width_contract(stage: Node) -> void:
	var summary: Dictionary = stage.call(&"get_confluence_runtime_summary")
	var states: Dictionary = summary.get("sources", {})
	var base_width := float(summary.get("trunk_base_width_pixels", 0.0))
	var transition := float(summary.get("trunk_width_transition_pixels", 0.0))
	var maximum_width := float(summary.get("maximum_source_width_pixels", 0.0))
	var expected_widths := {
		480.0: base_width,
		600.0: 50.0,
		840.0: sqrt(6100.0),
		1080.0: sqrt(11000.0),
		1560.0: sqrt(13500.0),
		1800.0: sqrt(19900.0),
	}
	var previous_width := 0.0
	for x_variant: Variant in expected_widths:
		var x_position := float(x_variant)
		var actual_width := _full_flow_width_at(
			x_position,
			base_width,
			transition,
			maximum_width,
			states,
		)
		_expect(
			absf(actual_width - float(expected_widths[x_variant])) <= 0.001
			and actual_width >= previous_width - 0.001,
			"explicit-width trunk milestone at x=%.0f was %.3f, expected %.3f"
				% [x_position, actual_width, float(expected_widths[x_variant])],
		)
		previous_width = actual_width


func _check_curve_contract(confluence: Dictionary) -> void:
	var states: Dictionary = confluence.get("sources", {})
	var trunk_y := float(confluence.get("trunk_center_y_pixels", -1.0))
	var turn_handle := maxf(float(confluence.get("entry_turn_pixels", 0.0)), 60.0)
	for source_id: String in SOURCE_ORDER:
		var source_state: Dictionary = states.get(source_id, {})
		var controls := _curve_controls(source_state, trunk_y, turn_handle)
		var expected: Array = EXPECTED_CURVES[source_id]
		var exact_controls := controls.size() == expected.size()
		if exact_controls:
			for control_index in range(expected.size()):
				exact_controls = (
					exact_controls
					and controls[control_index].is_equal_approx(expected[control_index])
				)
		_expect(exact_controls, "unexpected Bezier controls for %s: %s" % [
			source_id,
			controls,
		])
		if controls.size() != 4:
			continue

		var inward := Vector2(source_state.get(
			"inward_direction_pixels",
			Vector2.ZERO,
		)).normalized()
		var start_tangent := _bezier_tangent(controls, 0.0).normalized()
		var merge_tangent := _bezier_tangent(controls, 1.0).normalized()
		_expect(
			start_tangent.is_equal_approx(inward)
			and merge_tangent.is_equal_approx(Vector2.RIGHT),
			"Bezier endpoint tangents are not edge-inward then +X for %s"
				% source_id,
		)

		var shape_is_bounded := true
		var shape_is_monotone := true
		var stays_on_source_side := true
		var minimum_radius := INF
		var previous_point: Vector2 = controls[0]
		var previous_inward_progress := 0.0
		var source_side := signf(controls[0].y - trunk_y)
		for sample_index in range(CURVE_SAMPLE_COUNT):
			var progress := (
				float(sample_index) / float(CURVE_SAMPLE_COUNT - 1)
			)
			var point := _bezier_point(controls, progress)
			var derivative := _bezier_tangent(controls, progress)
			var second_derivative := _bezier_second_derivative(
				controls,
				progress,
			)
			shape_is_bounded = (
				shape_is_bounded
				and point.x >= STAGE_BOUNDS.position.x - 0.001
				and point.x <= STAGE_BOUNDS.end.x + 0.001
				and point.y >= STAGE_BOUNDS.position.y - 0.001
				and point.y <= STAGE_BOUNDS.end.y + 0.001
				and derivative.length_squared() > 0.000001
			)
			var inward_progress := (point - controls[0]).dot(inward)
			if sample_index > 0:
				shape_is_monotone = (
					shape_is_monotone
					and point.x >= previous_point.x - 0.001
					and inward_progress >= previous_inward_progress - 0.001
				)
			if sample_index < CURVE_SAMPLE_COUNT - 1 and absf(source_side) > 0.5:
				stays_on_source_side = (
					stays_on_source_side
					and (point.y - trunk_y) * source_side > -0.001
				)
			var derivative_length := derivative.length()
			var curvature := (
				absf(derivative.cross(second_derivative))
				/ maxf(pow(derivative_length, 3.0), 0.000001)
			)
			if curvature > 0.000001:
				minimum_radius = minf(minimum_radius, 1.0 / curvature)
			previous_point = point
			previous_inward_progress = inward_progress
		_expect(
			shape_is_bounded and shape_is_monotone and stays_on_source_side,
			"Bezier left the stage, reversed, or crossed the trunk before merge for %s"
				% source_id,
		)
		_expect(
			minimum_radius >= MINIMUM_CURVATURE_RADIUS_PIXELS - 0.1,
			"Bezier turn is too sharp for %s (minimum radius %.3fpx)" % [
				source_id,
				minimum_radius,
			],
		)


func _check_full_flow_width(stage: Node) -> void:
	for source_id: String in SOURCE_ORDER:
		_expect(bool(stage.call(
			&"set_confluence_water_state",
			source_id,
			{
				"flow_rate": 1.0,
				"active_heads": int(stage.get("particle_slots")),
				"speed_pixels": 300.0,
				"paused": false,
			},
		)), "full-flow water state was rejected for %s" % source_id)

	var summary: Dictionary = stage.call(&"get_confluence_runtime_summary")
	var states: Dictionary = summary.get("sources", {})
	var base_width := float(summary.get("trunk_base_width_pixels", 0.0))
	var transition := float(summary.get("trunk_width_transition_pixels", 0.0))
	var maximum_width := float(summary.get("maximum_source_width_pixels", 0.0))
	for x_variant: Variant in FULL_FLOW_WIDTH_MILESTONE_COUNTS:
		var x_position := float(x_variant)
		var expected_source_count := int(
			FULL_FLOW_WIDTH_MILESTONE_COUNTS[x_variant]
		)
		var actual_width := _full_flow_width_at(
			x_position,
			base_width,
			transition,
			maximum_width,
			states,
		)
		var expected_width := minf(
			maximum_width,
			maxf(
				base_width,
				MAXIMUM_SOURCE_WIDTH_PIXELS * sqrt(float(expected_source_count)),
			),
		)
		_expect(
			absf(actual_width - expected_width) <= 0.001,
			"full-flow trunk width at x=%.0f was %.3f, expected %.3f" % [
				x_position,
				actual_width,
				expected_width,
			],
		)

	var final_width := _full_flow_width_at(
		1800.0,
		base_width,
		transition,
		maximum_width,
		states,
	)
	_expect(
		absf(final_width - float(summary.get(
			"trunk_maximum_full_flow_width_pixels",
			0.0,
		))) <= 0.001,
		"reported maximum trunk width does not match the completed six-way merge",
	)

	var slot_count := int(stage.get("particle_slots"))
	var expected_active_counts: Array[int] = []
	for source_index in range(SOURCE_ORDER.size()):
		var source_capacity := floori(
			float(slot_count - 1 - source_index) / float(SOURCE_ORDER.size())
		) + 1
		expected_active_counts.append(source_capacity)
		var source_state: Dictionary = states.get(SOURCE_ORDER[source_index], {})
		_expect(
			int(source_state.get("active_heads", 0)) == source_capacity
			and is_equal_approx(
				float(source_state.get("exit_width_pixels", -1.0)),
				MAXIMUM_SOURCE_WIDTH_PIXELS,
			),
			"full flow did not fill the fixed slot share for %s"
				% SOURCE_ORDER[source_index],
		)
	for material_variant: Variant in stage.get("_process_material_layers"):
		var material := material_variant as ShaderMaterial
		if material == null:
			continue
		var counts_0: Vector4 = material.get_shader_parameter(
			&"confluence_active_counts_0"
		)
		var counts_1: Vector4 = material.get_shader_parameter(
			&"confluence_active_counts_1"
		)
		var widths_0: Vector4 = material.get_shader_parameter(
			&"confluence_source_widths_0"
		)
		var widths_1: Vector4 = material.get_shader_parameter(
			&"confluence_source_widths_1"
		)
		_expect(
			widths_0 == Vector4(1024.0, 1024.0, 1024.0, 1024.0)
			and widths_1 == Vector4(1024.0, 1024.0, 0.0, 0.0),
			"full-flow source widths were not uploaded to every layer",
		)
		var uploaded_counts := [
			counts_0.x,
			counts_0.y,
			counts_0.z,
			counts_0.w,
			counts_1.x,
			counts_1.y,
		]
		for source_index in range(SOURCE_ORDER.size()):
			_expect(
				is_equal_approx(
					float(uploaded_counts[source_index]),
					float(expected_active_counts[source_index]),
				),
				"full-flow source capacity was not uploaded for %s"
					% SOURCE_ORDER[source_index],
			)


func _curve_controls(
	source_state: Dictionary,
	trunk_y: float,
	turn_handle: float,
) -> Array[Vector2]:
	if source_state.is_empty():
		return []
	var point_0 := Vector2(source_state.get("anchor_pixels", Vector2.INF))
	var inward := Vector2(source_state.get(
		"inward_direction_pixels",
		Vector2.ZERO,
	)).normalized()
	var point_3 := Vector2(
		float(source_state.get("merge_x_pixels", -1.0)),
		trunk_y,
	)
	var horizontal_source := absf(inward.x) > 0.5
	var horizontal_handle := minf(
		turn_handle,
		maxf(absf(point_3.y - point_0.y) * 0.5, 180.0),
	)
	var inlet_handle := (
		horizontal_handle
		if horizontal_source
		else minf(
			turn_handle,
			maxf(absf(point_3.y - point_0.y) * 0.45, 60.0),
		)
	)
	var outlet_handle := (
		horizontal_handle
		if horizontal_source
		else minf(turn_handle, 180.0)
	)
	return [
		point_0,
		point_0 + inward * inlet_handle,
		point_3 - Vector2(outlet_handle, 0.0),
		point_3,
	]


func _bezier_point(controls: Array[Vector2], progress: float) -> Vector2:
	var one_minus := 1.0 - progress
	return (
		controls[0] * one_minus * one_minus * one_minus
		+ controls[1] * 3.0 * one_minus * one_minus * progress
		+ controls[2] * 3.0 * one_minus * progress * progress
		+ controls[3] * progress * progress * progress
	)


func _bezier_tangent(controls: Array[Vector2], progress: float) -> Vector2:
	var one_minus := 1.0 - progress
	return (
		(controls[1] - controls[0]) * 3.0 * one_minus * one_minus
		+ (controls[2] - controls[1]) * 6.0 * one_minus * progress
		+ (controls[3] - controls[2]) * 3.0 * progress * progress
	)


func _bezier_second_derivative(
	controls: Array[Vector2],
	progress: float,
) -> Vector2:
	return (
		(controls[2] - controls[1] * 2.0 + controls[0])
			* 6.0 * (1.0 - progress)
		+ (controls[3] - controls[2] * 2.0 + controls[1])
			* 6.0 * progress
	)


func _full_flow_width_at(
	x_position: float,
	base_width: float,
	transition: float,
	maximum_width: float,
	states: Dictionary,
) -> float:
	var merged_width_squared := 0.0
	for source_id: String in SOURCE_ORDER:
		var source_state: Dictionary = states.get(source_id, {})
		var merge_x := float(source_state.get("merge_x_pixels", INF))
		var progress := clampf(
			(x_position - merge_x) / maxf(transition, 30.0),
			0.0,
			1.0,
		)
		var joined := (
			progress * progress * progress
			* (10.0 + progress * (-15.0 + 6.0 * progress))
		)
		var source_width := float(source_state.get("exit_width_pixels", 0.0))
		merged_width_squared += source_width * source_width * joined
	return minf(
		maximum_width,
		maxf(base_width, sqrt(maxf(merged_width_squared, 0.0))),
	)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_errors.append(message)
