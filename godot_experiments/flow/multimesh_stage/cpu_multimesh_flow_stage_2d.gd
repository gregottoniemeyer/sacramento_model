class_name CPUMultiMeshFlowStage2D
extends Node2D

## Parallel CPU-head + MultiMesh flow stage.
##
## Live head positions and lifecycle state are CPU-owned. Immutable water trail
## segments and dynamic salmon streaks are render-only MultiMeshes. This scene
## deliberately does not replace the installed GPU stage until visual and
## two-screen performance parity have been established.

signal gate_changed(
	screen_id: StringName,
	reservoir_id: StringName,
	gate_open: bool,
	outlet_width: float
)
signal pause_changed(screen_id: StringName, paused: bool)
signal debug_visibility_changed(screen_id: StringName, visible: bool)
signal salmon_released(
	screen_id: StringName,
	requested_count: int,
	released_count: int,
	active_count: int
)

const WATER_MODEL_SCRIPT := preload(
	"res://flow/multimesh_stage/cpu_water_head_model.gd"
)
const WATER_RENDERER_SCRIPT := preload(
	"res://flow/multimesh_stage/immutable_multimesh_trail_renderer.gd"
)
const SALMON_SCHOOL_SCRIPT := preload(
	"res://flow/multimesh_stage/cpu_salmon_school_2d.gd"
)
const OVERLAY_SCRIPT := preload(
	"res://flow/multimesh_stage/cpu_multimesh_overlay.gd"
)

const STAGE_SIZE := Vector2(1920.0, 1080.0)
const WORLD_SIZE := Vector2(16.0, 9.0)
const PIXELS_PER_WORLD_UNIT := STAGE_SIZE.x / WORLD_SIZE.x
const FIXED_SIMULATION_HZ := 30.0
const RESERVOIR_ID := &"reservoir_main"
const MIN_GATE_WIDTH := 0.0
const MAX_GATE_WIDTH := 10.0
const MAX_PENDING_CONTROL_MESSAGES := 256
const MAX_INTERACTION_POLYGONS := 8
const MAX_SOURCE_POLYGONS := 8
const SOURCE_SPAWN_EPSILON_WORLD := 1.5 / PIXELS_PER_WORLD_UNIT

@export_group("Identity")
@export var stage_index: int = 0:
	set(value):
		stage_index = maxi(value, 0)
		_apply_identity()
@export var model_id: StringName = &"cpu_multimesh_flow_model"
@export var screen_id: StringName = &"cpu_multimesh_screen"
@export var control_target: StringName = &""

@export_group("Runtime")
@export var auto_start: bool = true
@export var accept_keyboard_input: bool = true
@export var debug_visible: bool = true:
	set(value):
		debug_visible = value
		_apply_debug_visibility()
@export var background_color: Color = Color("05090d"):
	set(value):
		background_color = value
		queue_redraw()

@export_group("Water Heads")
@export_range(1, 2000, 1) var particle_slots: int = 300
@export_range(0.0, 1.0, 0.01) var flow_rate: float = 0.5
@export_range(1.0, 2400.0, 1.0) var flow_speed_pixels: float = 600.0
@export_range(0.000001, 1.0, 0.000001) var min_active_flow: float = 0.001
@export_range(0.0, 1.0, 0.01) var speed_variation: float = 0.14
@export_range(0.0, 30.0, 0.1) var velocity_response: float = 12.0
@export_range(0.0, 300.0, 1.0) var noise_strength: float = 52.0
@export_range(0.0001, 0.1, 0.0001) var noise_scale: float = 0.010
@export_range(0.0, 10.0, 0.01) var noise_speed: float = 0.72
@export_range(0.1, 8.0, 0.1) var trail_lifetime: float = 2.0
@export_range(1.0, 5.0, 0.1) var line_width_min: float = 1.0
@export_range(1.0, 5.0, 0.1) var line_width_max: float = 5.0
@export_range(0.0, 1.0, 0.01) var particle_alpha: float = 0.94
@export_range(8.0, 256.0, 1.0) var trail_segment_max_length_pixels: float = 96.0
@export_range(1000, 100000, 1) var trail_segment_capacity: int = 22500

@export_group("Reservoir")
@export var reservoir_center_pixels: Vector2 = Vector2(1388.57, 771.43)
@export_range(8.0, 600.0, 1.0) var reservoir_radius_pixels: float = 223.71
@export_range(0.0, 300.0, 1.0) var reservoir_influence_pixels: float = 86.0
@export_range(0.0, 600.0, 1.0) var reservoir_swirl_speed: float = 145.0
@export_range(0.02, 1.0, 0.01) var reservoir_orbit_radius_min_ratio: float = 0.05
@export_range(0.02, 1.0, 0.01) var reservoir_orbit_radius_max_ratio: float = 0.78
@export_range(0.05, 1.0, 0.01) var reservoir_orbit_full_speed_ratio: float = 0.46
@export_range(0.1, 3.0, 0.05) var reservoir_orbit_max_angular_speed: float = 1.50
@export_range(0.05, 1.0, 0.01) var reservoir_capture_y_ratio: float = 1.0
@export_range(0.0, 120.0, 1.0) var reservoir_capture_edge_softness_pixels: float = 24.0
@export_range(0.0, 1.0, 0.01) var reservoir_entry_min_incidence: float = 0.50
@export_range(0.0, 8.0, 0.05) var reservoir_entry_pull_strength: float = 3.50
@export_range(0.0, 1.0, 0.01) var reservoir_entry_min_inward_speed_ratio: float = 0.30
@export_range(0.50, 0.95, 0.01) var reservoir_gate_staging_radius_ratio: float = 0.86
var _requested_gate_width: float = 0.25
@export_range(MIN_GATE_WIDTH, MAX_GATE_WIDTH, 0.01) var gate_width: float = 0.25:
	set(value):
		_requested_gate_width = maxf(value, MIN_GATE_WIDTH)
		gate_width = clampf(
			_requested_gate_width,
			MIN_GATE_WIDTH,
			get_full_gate_width_world_units()
		)
		_apply_gate()
@export var gate_open: bool = true:
	set(value):
		gate_open = value
		_apply_gate()

@export_group("Polygon Interactions")
@export var interaction_polygons: Array[GPUFlowInteractionPolygon] = []

@export_group("Water Sources")
@export var source_polygons: Array[CPUFlowSourcePolygon] = []

@export_group("Salmon")
@export var salmon_enabled: bool = true
@export_range(1, 300, 1) var salmon_per_release: int = 25
@export_range(1.0, 600.0, 1.0) var salmon_water_contact_width_pixels: float = 240.0
@export_range(1.0, 240.0, 1.0) var salmon_water_contact_height_pixels: float = 24.0
@export_range(8.0, 160.0, 1.0) var salmon_length_pixels: float = 50.0
@export_range(1.0, 5.0, 0.1) var salmon_line_width_pixels: float = 2.0
@export_range(0.05, 4.0, 0.05) var salmon_fade_seconds: float = 0.50

var _water_model: WATER_MODEL_SCRIPT
var _water_renderer: WATER_RENDERER_SCRIPT
var _salmon_school: SALMON_SCHOOL_SCRIPT
var _overlay: OVERLAY_SCRIPT
var _paused: bool = false
var _pending_messages: Array[Dictionary] = []
var _pending_salmon_releases: PackedInt32Array = PackedInt32Array()
var _last_salmon_release_count: int = 0


func _ready() -> void:
	add_to_group(&"flow_models")
	_build_backend()
	_bind_geometry_signals()
	_apply_identity()
	_apply_runtime_parameters()
	_apply_interaction_geometry()
	_apply_source_geometry()
	_apply_gate()
	_apply_debug_visibility()
	reset_simulation()
	set_paused(not auto_start)
	queue_redraw()


func _physics_process(delta: float) -> void:
	_apply_pending_messages()
	if _paused or _water_model == null:
		return
	var completed_steps: int = _water_model.step(delta)
	if completed_steps <= 0:
		_process_pending_salmon_releases()
		return
	var simulation_delta := float(completed_steps) / FIXED_SIMULATION_HZ
	_water_renderer.advance_time(simulation_delta)
	var water_heads: Array[Dictionary] = _water_model.get_active_head_snapshots()
	_process_pending_salmon_releases(water_heads)
	if salmon_enabled:
		_salmon_school.update_salmon(simulation_delta, water_heads)


func _unhandled_input(event: InputEvent) -> void:
	if not accept_keyboard_input:
		return
	var key_event := event as InputEventKey
	if key_event == null or not key_event.pressed or key_event.echo:
		return
	match key_event.keycode:
		KEY_0, KEY_1, KEY_2, KEY_3, KEY_4, KEY_5, KEY_6, KEY_7, KEY_8, KEY_9:
			set_flow_rate(float(key_event.keycode - KEY_0) / 9.0)
		KEY_G:
			toggle_gate()
		KEY_SPACE:
			set_paused(not _paused)
		KEY_BRACKETLEFT:
			adjust_gate_width(-0.10)
		KEY_BRACKETRIGHT:
			adjust_gate_width(0.10)
		KEY_V:
			set_debug_visible(not debug_visible)
		KEY_S:
			release_salmon()
		_:
			return
	get_viewport().set_input_as_handled()


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, STAGE_SIZE), background_color, true)


func accepts_control_target(target: String) -> bool:
	return (
		target == "*"
		or target == String(screen_id)
		or target == String(model_id)
		or (not control_target.is_empty() and target == String(control_target))
	)


func get_control_target() -> StringName:
	return control_target


func get_model_id() -> StringName:
	return model_id


func get_screen_id() -> StringName:
	return screen_id


func get_native_size() -> Vector2:
	return STAGE_SIZE


func set_flow_rate(value: float) -> void:
	flow_rate = clampf(value, 0.0, 1.0)
	_apply_runtime_parameters()


func set_gate_open(first: Variant, second: Variant = null) -> void:
	var new_value := bool(first) if second == null else bool(second)
	gate_open = new_value


func set_gate_width(first: Variant, second: Variant = null) -> void:
	var new_value := float(first) if second == null else float(second)
	gate_width = new_value


func set_gate_half_width(value: float) -> void:
	gate_width = maxf(value, 0.0) * 2.0 / PIXELS_PER_WORLD_UNIT


func get_gate_half_width_pixels() -> float:
	return gate_width * PIXELS_PER_WORLD_UNIT * 0.5


func get_full_gate_width_world_units() -> float:
	return minf(
		MAX_GATE_WIDTH,
		reservoir_radius_pixels * 2.0 / PIXELS_PER_WORLD_UNIT
	)


func get_gate_aperture_fraction() -> float:
	return clampf(
		get_gate_half_width_pixels() / maxf(reservoir_radius_pixels, 0.001),
		0.0,
		1.0
	)


func get_effective_gate_release_probability() -> float:
	return get_gate_aperture_fraction() if gate_open else 0.0


func adjust_gate_width(delta_width: float) -> void:
	gate_width = gate_width + delta_width


func toggle_gate(_reservoir_id: StringName = RESERVOIR_ID) -> void:
	gate_open = not gate_open


func set_paused(value: bool) -> void:
	_paused = value
	if _water_model != null:
		_water_model.set_paused(value)
	if _water_renderer != null:
		_water_renderer.set_paused(value)
	if _salmon_school != null:
		_salmon_school.set_paused(value)
	if is_node_ready():
		pause_changed.emit(screen_id, value)


func is_paused() -> bool:
	return _paused


func set_debug_visible(value: bool) -> void:
	debug_visible = value


func toggle_debug_visibility() -> void:
	set_debug_visible(not debug_visible)


func release_salmon(count: int = -1) -> int:
	if not salmon_enabled:
		return 0
	var requested_count := salmon_per_release if count < 0 else count
	if requested_count < 1 or requested_count > 300:
		return 0
	_pending_salmon_releases.append(requested_count)
	return requested_count


func reset_simulation() -> void:
	if _water_renderer != null:
		_water_renderer.reset()
	if _water_model != null:
		_water_model.reset()
	if _salmon_school != null:
		_salmon_school.reset()
	_pending_salmon_releases.clear()
	_last_salmon_release_count = 0


func queue_control_message(message: Dictionary) -> void:
	if _pending_messages.size() >= MAX_PENDING_CONTROL_MESSAGES:
		_pending_messages.pop_front()
	_pending_messages.append(message.duplicate(true))


func apply_runtime_parameters() -> void:
	_apply_runtime_parameters()


func apply_interaction_polygons() -> void:
	_apply_interaction_geometry()


func get_interaction_polygon(element_id: StringName) -> GPUFlowInteractionPolygon:
	for polygon: GPUFlowInteractionPolygon in interaction_polygons:
		if polygon != null and polygon.element_id == element_id:
			return polygon
	return null


func get_source_polygon(element_id: StringName) -> CPUFlowSourcePolygon:
	for source: CPUFlowSourcePolygon in source_polygons:
		if source != null and source.element_id == element_id:
			return source
	return null


func set_runtime_parameter(
	path: String,
	value: Variant,
	apply_immediately: bool = true
) -> bool:
	var changed := true
	match path.strip_edges().to_lower():
		"flow_rate", "active_ratio":
			flow_rate = clampf(float(value), 0.0, 1.0)
		"flow_speed_pixels", "max_flow_speed_pixels":
			flow_speed_pixels = maxf(float(value), 1.0)
		"speed_variation":
			speed_variation = clampf(float(value), 0.0, 1.0)
		"velocity_response":
			velocity_response = maxf(float(value), 0.0)
		"noise_strength":
			noise_strength = maxf(float(value), 0.0)
		"noise_scale":
			noise_scale = maxf(float(value), 0.0001)
		"noise_speed":
			noise_speed = maxf(float(value), 0.0)
		"trail_lifetime":
			trail_lifetime = clampf(float(value), 0.1, 8.0)
		"line_width_min":
			line_width_min = clampf(float(value), 1.0, 5.0)
		"line_width_max":
			line_width_max = clampf(float(value), 1.0, 5.0)
		"particle_alpha":
			particle_alpha = clampf(float(value), 0.0, 1.0)
		"reservoir_center_pixels":
			reservoir_center_pixels = _variant_to_vector2(value, reservoir_center_pixels)
		"reservoir.reservoir_main.x":
			reservoir_center_pixels.x = float(value) * PIXELS_PER_WORLD_UNIT
		"reservoir.reservoir_main.y":
			reservoir_center_pixels.y = STAGE_SIZE.y - float(value) * PIXELS_PER_WORLD_UNIT
		"reservoir_radius_pixels":
			reservoir_radius_pixels = clampf(float(value), 8.0, 600.0)
			gate_width = _requested_gate_width
		"reservoir.reservoir_main.radius":
			reservoir_radius_pixels = clampf(
				float(value) * PIXELS_PER_WORLD_UNIT, 8.0, 600.0
			)
			gate_width = _requested_gate_width
		"reservoir.reservoir_main.gate_open", "gate_open":
			gate_open = bool(value)
		"reservoir.reservoir_main.outlet_width", "gate_width", "outlet_width":
			gate_width = float(value)
		"salmon.enabled", "salmon_enabled":
			salmon_enabled = bool(value)
		"salmon.per_release", "salmon_per_release":
			salmon_per_release = clampi(int(value), 1, 300)
		"salmon.water_contact_width_pixels", "salmon_water_contact_width_pixels":
			salmon_water_contact_width_pixels = clampf(float(value), 1.0, 600.0)
		"salmon.water_contact_height_pixels", "salmon_water_contact_height_pixels":
			salmon_water_contact_height_pixels = clampf(float(value), 1.0, 240.0)
		"salmon.length_pixels", "salmon_length_pixels":
			salmon_length_pixels = clampf(float(value), 8.0, 160.0)
		"salmon.line_width_pixels", "salmon_line_width_pixels":
			salmon_line_width_pixels = clampf(float(value), 1.0, 5.0)
		"salmon.fade_seconds", "salmon_fade_seconds":
			salmon_fade_seconds = clampf(float(value), 0.05, 4.0)
		"debug_visible":
			debug_visible = bool(value)
		"background_color":
			background_color = Color(value)
		_:
			changed = false
	if changed and apply_immediately:
		_apply_runtime_parameters()
		_apply_gate()
	return changed


func runtime_summary() -> Dictionary:
	var water_summary: Dictionary = (
		_water_model.runtime_summary() if _water_model != null else {}
	)
	var renderer_summary: Dictionary = (
		_water_renderer.runtime_summary() if _water_renderer != null else {}
	)
	var salmon_summary: Dictionary = (
		_salmon_school.runtime_summary() if _salmon_school != null else {}
	)
	var interaction_definitions: Array[Dictionary] = []
	for polygon: GPUFlowInteractionPolygon in interaction_polygons:
		if polygon != null:
			interaction_definitions.append(polygon.to_dictionary())
	var source_definitions: Array[Dictionary] = []
	for source: CPUFlowSourcePolygon in source_polygons:
		if source != null:
			source_definitions.append(source.to_dictionary())
	return {
		"backend": "cpu_heads_multimesh",
		"simulation_authority": "cpu",
		"renderer_backend": "multimesh_segments",
		"stage_index": stage_index,
		"model_id": String(model_id),
		"screen_id": String(screen_id),
		"control_target": String(control_target),
		"stage_size": STAGE_SIZE,
		"amount": particle_slots,
		"amount_ratio": flow_rate,
		"flow_rate": flow_rate,
		"active_heads_approx": int(water_summary.get("active_slot_count", 0)),
		"water": water_summary,
		"water_renderer": renderer_summary,
		"salmon": salmon_summary,
		"gate_open": gate_open,
		"gate_width": gate_width,
		"gate_half_width_pixels": get_gate_half_width_pixels(),
		"gate_aperture_fraction": get_gate_aperture_fraction(),
		"gate_release_probability": get_effective_gate_release_probability(),
		"reservoir_center_pixels": reservoir_center_pixels,
		"reservoir_radius_pixels": reservoir_radius_pixels,
		"interaction_polygon_count": interaction_definitions.size(),
		"interaction_polygons": interaction_definitions,
		"source_polygon_count": source_definitions.size(),
		"source_polygons": source_definitions,
		"overlay_interaction_count": (
			_overlay.get_interaction_polygon_count() if _overlay != null else 0
		),
		"overlay_source_count": (
			_overlay.get_source_polygon_count() if _overlay != null else 0
		),
		"pending_salmon_release_count": _pending_salmon_releases.size(),
		"salmon_last_release_count": _last_salmon_release_count,
		"paused": _paused,
		"debug_visible": debug_visible,
	}


func _build_backend() -> void:
	_water_renderer = WATER_RENDERER_SCRIPT.new() as WATER_RENDERER_SCRIPT
	_water_renderer.name = "WaterTrailMultiMeshRenderer"
	_water_renderer.auto_advance_time = false
	_water_renderer.total_segment_capacity = trail_segment_capacity
	_water_renderer.trail_lifetime_seconds = trail_lifetime
	add_child(_water_renderer)

	_water_model = WATER_MODEL_SCRIPT.new() as WATER_MODEL_SCRIPT
	_water_model.name = "CPUWaterHeadModel"
	_water_model.auto_step = false
	add_child(_water_model)
	_water_model.set_segment_sink(Callable(_water_renderer, "append_segment"))
	_water_model.set_spawn_provider(Callable(self, "_source_spawn_position"))

	_salmon_school = SALMON_SCHOOL_SCRIPT.new() as SALMON_SCHOOL_SCRIPT
	_salmon_school.name = "CPUSalmonSchool2D"
	add_child(_salmon_school)

	_overlay = OVERLAY_SCRIPT.new() as OVERLAY_SCRIPT
	_overlay.name = "CPUMultiMeshDebugOverlay"
	_overlay.z_index = 100
	_overlay.z_as_relative = false
	add_child(_overlay)


func _apply_identity() -> void:
	if _water_model != null:
		_water_model.stage_phase = float(stage_index) * 1.731


func _apply_runtime_parameters() -> void:
	if _water_model != null:
		_water_model.configure({
			"auto_step": false,
			"stage_size": STAGE_SIZE,
			"world_size": WORLD_SIZE,
			"stage_phase": float(stage_index) * 1.731,
			"particle_slots": particle_slots,
			"flow_rate": flow_rate,
			"flow_speed_pixels": flow_speed_pixels,
			"speed_variation": speed_variation,
			"velocity_response": velocity_response,
			"noise_strength": noise_strength,
			"noise_scale": noise_scale,
			"noise_speed": noise_speed,
			"trail_lifetime": trail_lifetime,
			"line_width_min": minf(line_width_min, line_width_max),
			"line_width_max": maxf(line_width_min, line_width_max),
			"particle_alpha": particle_alpha,
			"trail_segment_max_length_pixels": trail_segment_max_length_pixels,
			"reservoir_center_pixels": reservoir_center_pixels,
			"reservoir_radius_pixels": reservoir_radius_pixels,
			"reservoir_influence_pixels": reservoir_influence_pixels,
			"reservoir_swirl_speed": reservoir_swirl_speed,
			"reservoir_orbit_radius_min_ratio": reservoir_orbit_radius_min_ratio,
			"reservoir_orbit_radius_max_ratio": reservoir_orbit_radius_max_ratio,
			"reservoir_orbit_full_speed_ratio": reservoir_orbit_full_speed_ratio,
			"reservoir_orbit_max_angular_speed": reservoir_orbit_max_angular_speed,
			"reservoir_capture_y_ratio": reservoir_capture_y_ratio,
			"reservoir_capture_edge_softness_pixels": reservoir_capture_edge_softness_pixels,
			"reservoir_entry_min_incidence": reservoir_entry_min_incidence,
			"reservoir_entry_pull_strength": reservoir_entry_pull_strength,
			"reservoir_entry_min_inward_speed_ratio": reservoir_entry_min_inward_speed_ratio,
			"reservoir_gate_staging_radius_ratio": reservoir_gate_staging_radius_ratio,
			"gate_open": gate_open,
			"gate_width": gate_width,
		})
	if _water_renderer != null:
		_water_renderer.trail_lifetime_seconds = trail_lifetime
	if _salmon_school != null:
		_salmon_school.stage_size = STAGE_SIZE
		_salmon_school.water_contact_width_pixels = salmon_water_contact_width_pixels
		_salmon_school.water_contact_height_pixels = salmon_water_contact_height_pixels
		_salmon_school.right_edge_band_pixels = salmon_water_contact_width_pixels * 0.5
		_salmon_school.streak_length_pixels = salmon_length_pixels
		_salmon_school.streak_width_pixels = salmon_line_width_pixels
		_salmon_school.fade_seconds = salmon_fade_seconds
	if _overlay != null:
		_overlay.set_reservoir_geometry(
			reservoir_center_pixels,
			reservoir_radius_pixels
		)


func _apply_gate() -> void:
	if _water_model != null:
		_water_model.gate_open = gate_open
		_water_model.gate_aperture = get_gate_aperture_fraction()
	if _overlay != null:
		_overlay.set_gate(gate_open, get_gate_half_width_pixels())
	if is_node_ready():
		gate_changed.emit(screen_id, RESERVOIR_ID, gate_open, gate_width)


func _apply_debug_visibility() -> void:
	if _overlay != null:
		_overlay.visible = debug_visible
	if is_node_ready():
		debug_visibility_changed.emit(screen_id, debug_visible)


func _bind_geometry_signals() -> void:
	for polygon: GPUFlowInteractionPolygon in interaction_polygons:
		if polygon != null and not polygon.changed.is_connected(_on_interaction_changed):
			polygon.changed.connect(_on_interaction_changed)
	for source: CPUFlowSourcePolygon in source_polygons:
		if source != null and not source.changed.is_connected(_on_source_changed):
			source.changed.connect(_on_source_changed)


func _on_interaction_changed() -> void:
	_apply_interaction_geometry()


func _on_source_changed() -> void:
	_apply_source_geometry()


func _apply_interaction_geometry() -> void:
	if _water_model != null:
		_water_model.set_interaction_polygons(interaction_polygons)
	if _overlay == null:
		return
	var definitions: Array[Dictionary] = []
	for polygon: GPUFlowInteractionPolygon in interaction_polygons:
		if polygon == null:
			continue
		definitions.append({
			"vertices": _world_vertices_to_native(polygon.vertices),
			"enabled": polygon.enabled,
		})
	_overlay.set_interaction_polygons(definitions)


func _apply_source_geometry() -> void:
	if _overlay == null:
		return
	var definitions: Array[Dictionary] = []
	for source: CPUFlowSourcePolygon in source_polygons:
		if source == null:
			continue
		var native_vertices := _world_vertices_to_native(source.vertices)
		var native_edges: Array[Dictionary] = []
		var world_edges: Array[Dictionary] = CPUFlowSourcePolygon.selected_downstream_edges(
			source.vertices,
			source.flow_direction
		)
		for edge: Dictionary in world_edges:
			var world_normal: Vector2 = edge["outward_normal"]
			native_edges.append({
				"edge_index": int(edge["edge_index"]),
				"outward_normal": Vector2(world_normal.x, -world_normal.y).normalized(),
			})
		definitions.append({
			"vertices": native_vertices,
			"enabled": source.enabled,
			"downstream_edges": native_edges,
		})
	_overlay.set_source_polygons(definitions)


func _source_spawn_position(
	head_id: int,
	generation: int,
	lane_seed: float
) -> Variant:
	var enabled_sources: Array[CPUFlowSourcePolygon] = []
	var total_fraction := 0.0
	for source: CPUFlowSourcePolygon in source_polygons:
		if (
			source == null
			or not source.enabled
			or source.emission_fraction <= 0.0
			or not source.validate().is_empty()
		):
			continue
		enabled_sources.append(source)
		total_fraction += source.emission_fraction
	if enabled_sources.is_empty():
		return null
	var selector := _hash11(
		float(head_id) * 17.137
		+ float(generation) * 3.119
		+ lane_seed * 37.0
		+ float(stage_index) * 11.0
	)
	var source_probability := minf(total_fraction, 1.0)
	if selector >= source_probability:
		return null
	var weighted_target := selector / maxf(source_probability, 0.000001) * total_fraction
	var accumulated := 0.0
	var selected_source: CPUFlowSourcePolygon = enabled_sources[-1]
	for source: CPUFlowSourcePolygon in enabled_sources:
		accumulated += source.emission_fraction
		if weighted_target <= accumulated:
			selected_source = source
			break
	var sample_value := _hash11(
		float(head_id) * 5.271
		+ float(generation) * 19.731
		+ lane_seed * 173.0
	)
	var world_point := selected_source.sample_emission_point(
		sample_value,
		SOURCE_SPAWN_EPSILON_WORLD
	)
	if not is_finite(world_point.x) or not is_finite(world_point.y):
		return null
	return _world_to_native(world_point)


func _process_pending_salmon_releases(
	water_heads: Array[Dictionary] = []
) -> void:
	if _pending_salmon_releases.is_empty() or _salmon_school == null:
		return
	var snapshots := water_heads
	if snapshots.is_empty() and _water_model != null:
		snapshots = _water_model.get_active_head_snapshots()
	while not _pending_salmon_releases.is_empty():
		var requested_count: int = _pending_salmon_releases[0]
		_pending_salmon_releases.remove_at(0)
		var released_count := _salmon_school.release_salmon(
			snapshots,
			requested_count
		)
		_last_salmon_release_count = released_count
		var salmon_summary: Dictionary = _salmon_school.runtime_summary()
		salmon_released.emit(
			screen_id,
			requested_count,
			released_count,
			int(salmon_summary.get("active_count", 0))
		)


func _apply_pending_messages() -> void:
	if _pending_messages.is_empty():
		return
	var messages := _pending_messages
	_pending_messages = []
	for message: Dictionary in messages:
		_apply_control_message(message)


func _apply_control_message(message: Dictionary) -> void:
	var changes_value: Variant = message.get("changes", {})
	if changes_value is Dictionary:
		var changes: Dictionary = changes_value
		# Geometry-dependent values are intentionally applied in one batch before
		# the solver receives the new parameter set.
		for raw_path: Variant in changes:
			set_runtime_parameter(String(raw_path), changes[raw_path], false)
		_apply_runtime_parameters()
		_apply_gate()
	var command := String(message.get("command", "")).strip_edges().to_lower()
	if command == "set_gate":
		if message.has("gate_open"):
			gate_open = bool(message["gate_open"])
		if message.has("outlet_width"):
			gate_width = float(message["outlet_width"])
	var actions_value: Variant = message.get("actions", [])
	if not actions_value is Array:
		return
	for action_value: Variant in actions_value:
		var action_name := ""
		var arguments: Dictionary = {}
		if action_value is Dictionary:
			var action: Dictionary = action_value
			action_name = String(
				action.get("name", action.get("action", ""))
			).strip_edges().to_lower()
			var arguments_value: Variant = action.get("arguments", {})
			if arguments_value is Dictionary:
				arguments = arguments_value
		else:
			action_name = String(action_value).strip_edges().to_lower()
		match action_name:
			"pause":
				set_paused(true)
			"resume":
				set_paused(false)
			"toggle_gate":
				toggle_gate()
			"toggle_debug", "toggle_debug_geometry":
				toggle_debug_visibility()
			"release_salmon":
				release_salmon(int(arguments.get("count", salmon_per_release)))
			"reset":
				reset_simulation()


func _world_to_native(point: Vector2) -> Vector2:
	return Vector2(
		point.x * PIXELS_PER_WORLD_UNIT,
		STAGE_SIZE.y - point.y * PIXELS_PER_WORLD_UNIT
	)


func _world_vertices_to_native(vertices: PackedVector2Array) -> PackedVector2Array:
	var result := PackedVector2Array()
	result.resize(vertices.size())
	for index in range(vertices.size()):
		result[index] = _world_to_native(vertices[index])
	return result


func _variant_to_vector2(value: Variant, fallback: Vector2) -> Vector2:
	if value is Vector2:
		return value
	if value is Vector2i:
		return Vector2(value)
	if value is Array and value.size() == 2:
		return Vector2(float(value[0]), float(value[1]))
	if value is Dictionary and value.has("x") and value.has("y"):
		return Vector2(float(value["x"]), float(value["y"]))
	return fallback


func _hash11(value: float) -> float:
	return fposmod(sin(value * 127.1 + 311.7) * 43758.5453123, 1.0)
