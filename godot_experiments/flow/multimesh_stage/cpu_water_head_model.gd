class_name CPUWaterHeadModel
extends Node

## Prototype-safe, CPU-owned water-head simulation for the immutable MultiMesh
## renderer. This node intentionally owns no CanvasItem, MultiMesh, particle, or
## trail-history state. Every successful fixed head step emits one immutable
## segment; a renderer may retain or discard that record independently.
##
## Positions are native stage pixels (Y points down). Interaction polygon
## resources retain the controller-facing 16 x 9 coordinates (Y points up) and
## are converted once when their cache is rebuilt.

signal segment_created(
	from_position: Vector2,
	to_position: Vector2,
	width: float,
	palette_index: int,
	alpha: float
)
signal simulation_reset()

const GPUFlowInteractionPolygonScript := preload(
	"res://flow/gpu_stage/gpu_flow_interaction_polygon.gd"
)

const FIXED_HZ := 30.0
const FIXED_DELTA := 1.0 / FIXED_HZ
const PALETTE_SIZE := 7
const INLET_X := -18.0
const INLET_MARGIN_Y := 28.0
const EXIT_MARGIN := 96.0
const RECYCLE_SAFETY_SECONDS := 0.067
const MAX_INTERACTION_POLYGONS := 8
const EPSILON := 0.000001

enum HeadState {
	FLOWING,
	ENTERING,
	RETAINED,
	GATE_STAGING,
	GATE_FLUSHING,
	EXITING,
	RELEASED,
	BYPASSING,
	ABSORBED,
	RECYCLE_WAIT,
}

@export_group("Runtime")
@export var auto_step: bool = true
@export var start_paused: bool = false
@export_range(1, 16, 1) var max_catch_up_steps: int = 4

@export_group("Stage")
@export var stage_size := Vector2(1920.0, 1080.0)
@export var world_size := Vector2(16.0, 9.0)
@export var stage_phase: float = 0.0

@export_group("Heads")
@export_range(1, 4000, 1) var particle_slots: int = 300
@export_range(0.0, 1.0, 0.001) var flow_rate: float = 0.5
@export_range(1.0, 2400.0, 1.0) var flow_speed_pixels: float = 600.0
@export_range(0.000001, 1.0, 0.000001) var min_active_flow: float = 0.001
@export_range(0.0, 1.0, 0.001) var speed_variation: float = 0.14
@export_range(0.0, 30.0, 0.1) var velocity_response: float = 12.0
@export_range(0.0, 300.0, 1.0) var noise_strength: float = 52.0
@export_range(0.0001, 0.1, 0.0001) var noise_scale: float = 0.010
@export_range(0.0, 10.0, 0.01) var noise_speed: float = 0.72
@export_range(0.1, 8.0, 0.1) var trail_lifetime: float = 2.0
@export_range(1.0, 5.0, 0.1) var line_width_min: float = 1.0
@export_range(1.0, 5.0, 0.1) var line_width_max: float = 5.0
@export_range(0.0, 1.0, 0.001) var particle_alpha: float = 0.94
@export_range(8.0, 256.0, 1.0) var maximum_segment_length: float = 96.0

@export_group("Reservoir")
@export var reservoir_enabled: bool = true
@export var reservoir_center_pixels := Vector2(1388.57, 771.43)
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
@export var gate_open: bool = true
## This one normalized value owns both the physical half-width and release
## probability: 0 is closed, 1 spans the complete downstream semicircle.
@export_range(0.0, 1.0, 0.001) var gate_aperture: float = 0.25

# Compact structure-of-arrays storage. Slot index is the stable public head ID.
var _positions := PackedVector2Array()
var _velocities := PackedVector2Array()
var _states := PackedByteArray()
var _enabled := PackedByteArray()
var _reservoir_decided := PackedByteArray()
var _capture_envelope_entered := PackedByteArray()
var _gate_sector_latched := PackedByteArray()
var _generations := PackedInt32Array()
var _gate_attempts := PackedInt32Array()
var _state_times := PackedFloat32Array()
var _lane_seeds := PackedFloat32Array()
var _style_seeds := PackedFloat32Array()
var _orbit_seeds := PackedFloat32Array()
var _orbit_radii := PackedFloat32Array()

var _storage_capacity: int = 0
var _active_slot_count: int = 0
var _fixed_accumulator: float = 0.0
var _simulation_time: float = 0.0
var _fixed_step_index: int = 0
var _paused: bool = false
var _suppress_segments: bool = false
var _segment_sink: Callable
var _spawn_provider: Callable
var _interaction_polygons: Array[GPUFlowInteractionPolygon] = []
var _interaction_cache: Array[Dictionary] = []


func _ready() -> void:
	_paused = start_paused
	reset()


func _process(delta: float) -> void:
	if auto_step:
		step(delta)


func step(delta: float) -> int:
	## Consume real time through a deterministic 30 Hz accumulator. The return
	## value is the number of completed simulation ticks.
	if _paused or delta <= 0.0:
		return 0
	_ensure_storage()
	var bounded_delta := minf(delta, FIXED_DELTA * float(max_catch_up_steps))
	_fixed_accumulator += bounded_delta
	var completed_steps := 0
	while (
		_fixed_accumulator + EPSILON >= FIXED_DELTA
		and completed_steps < max_catch_up_steps
	):
		_fixed_accumulator -= FIXED_DELTA
		_fixed_step(FIXED_DELTA)
		completed_steps += 1
	return completed_steps


func advance_fixed_steps(count: int) -> void:
	## Deterministic test/controller entry point that bypasses the accumulator.
	_ensure_storage()
	for _index in range(maxi(count, 0)):
		_fixed_step(FIXED_DELTA)


func reset() -> void:
	_resize_storage(maxi(particle_slots, 1))
	_fixed_accumulator = 0.0
	_simulation_time = 0.0
	_fixed_step_index = 0
	_active_slot_count = _desired_active_slot_count()
	for slot in range(_storage_capacity):
		_enabled[slot] = 1 if slot < _active_slot_count else 0
		_generations[slot] = 0
		_initialize_slot_seeds(slot)
		if _enabled[slot] != 0:
			_spawn_initially_distributed(slot)
		else:
			_clear_slot(slot)
	simulation_reset.emit()


func configure(values: Dictionary) -> bool:
	## Apply the controller-facing subset used by this prototype. Unknown keys
	## return false so integration mistakes do not fail silently.
	var capacity_changed := false
	var interaction_conversion_changed := false
	var orbit_geometry_changed := false
	for raw_key: Variant in values:
		var key := String(raw_key)
		var value: Variant = values[raw_key]
		match key:
			"auto_step":
				auto_step = bool(value)
			"paused":
				_paused = bool(value)
			"stage_size":
				stage_size = _variant_to_vector2(value, stage_size)
				interaction_conversion_changed = true
			"world_size":
				world_size = _variant_to_vector2(value, world_size)
				interaction_conversion_changed = true
			"stage_phase":
				stage_phase = float(value)
			"particle_slots":
				var requested_capacity := maxi(int(value), 1)
				capacity_changed = (
					requested_capacity != particle_slots
					or (
						_storage_capacity > 0
						and requested_capacity != _storage_capacity
					)
				)
				particle_slots = requested_capacity
			"flow_rate":
				flow_rate = clampf(float(value), 0.0, 1.0)
			"flow_speed_pixels":
				flow_speed_pixels = maxf(float(value), 1.0)
			"base_speed":
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
				trail_lifetime = maxf(float(value), 0.1)
			"line_width_min":
				line_width_min = clampf(float(value), 1.0, 5.0)
			"line_width_max":
				line_width_max = clampf(float(value), 1.0, 5.0)
			"particle_alpha":
				particle_alpha = clampf(float(value), 0.0, 1.0)
			"maximum_segment_length", "trail_segment_max_length_pixels":
				maximum_segment_length = maxf(float(value), 1.0)
			"reservoir_enabled":
				reservoir_enabled = bool(value)
			"reservoir_center_pixels":
				reservoir_center_pixels = _variant_to_vector2(
					value, reservoir_center_pixels
				)
			"reservoir_radius_pixels":
				reservoir_radius_pixels = maxf(float(value), 8.0)
				orbit_geometry_changed = true
			"reservoir_influence_pixels":
				reservoir_influence_pixels = maxf(float(value), 0.0)
			"reservoir_swirl_speed":
				reservoir_swirl_speed = maxf(float(value), 0.0)
			"reservoir_orbit_radius_min_ratio":
				reservoir_orbit_radius_min_ratio = clampf(float(value), 0.02, 1.0)
				orbit_geometry_changed = true
			"reservoir_orbit_radius_max_ratio":
				reservoir_orbit_radius_max_ratio = clampf(float(value), 0.02, 1.0)
				orbit_geometry_changed = true
			"reservoir_orbit_full_speed_ratio":
				reservoir_orbit_full_speed_ratio = clampf(float(value), 0.05, 1.0)
			"reservoir_orbit_max_angular_speed":
				reservoir_orbit_max_angular_speed = clampf(float(value), 0.1, 3.0)
			"reservoir_capture_y_ratio":
				reservoir_capture_y_ratio = clampf(float(value), 0.05, 1.0)
			"reservoir_capture_edge_softness_pixels":
				reservoir_capture_edge_softness_pixels = maxf(float(value), 0.0)
			"reservoir_entry_min_incidence":
				reservoir_entry_min_incidence = clampf(float(value), 0.0, 1.0)
			"reservoir_entry_pull_strength":
				reservoir_entry_pull_strength = clampf(float(value), 0.0, 8.0)
			"reservoir_entry_min_inward_speed_ratio":
				reservoir_entry_min_inward_speed_ratio = clampf(float(value), 0.0, 1.0)
			"reservoir_gate_staging_radius_ratio":
				reservoir_gate_staging_radius_ratio = clampf(float(value), 0.50, 0.95)
			"gate_open":
				gate_open = bool(value)
			"gate_aperture":
				gate_aperture = clampf(float(value), 0.0, 1.0)
			"gate_width_pixels":
				gate_aperture = clampf(
					float(value) * 0.5 / maxf(reservoir_radius_pixels, 0.001),
					0.0,
					1.0
				)
			"gate_width":
				var pixel_width := float(value) * _pixels_per_world_unit()
				gate_aperture = clampf(
					pixel_width * 0.5 / maxf(reservoir_radius_pixels, 0.001),
					0.0,
					1.0
				)
			_:
				return false
	if line_width_max < line_width_min:
		line_width_max = line_width_min
	if capacity_changed:
		reset()
	else:
		if orbit_geometry_changed:
			_refresh_orbit_radii()
		_synchronize_active_slots()
	if interaction_conversion_changed:
		_rebuild_interaction_cache()
	return true


func set_paused(value: bool) -> void:
	_paused = value


func is_paused() -> bool:
	return _paused


func set_gate_open(value: bool) -> void:
	gate_open = value


func set_gate_aperture(value: float) -> void:
	gate_aperture = clampf(value, 0.0, 1.0)


func set_segment_sink(callback: Callable) -> void:
	## A direct callback avoids thousands of signal dispatches when a renderer and
	## model are deliberately coupled. The public signal is still always emitted.
	_segment_sink = callback


func set_spawn_provider(provider: Callable) -> void:
	## Optional lifecycle seam for future addressable sources. The provider is
	## called as provider(head_id, generation, lane_seed) and may return a Vector2
	## or {"position": Vector2}. Invalid/empty results retain the left inlet.
	_spawn_provider = provider


func set_interaction_polygons(
	polygons: Array[GPUFlowInteractionPolygon]
) -> void:
	_unbind_interaction_polygon_signals()
	_interaction_polygons = polygons.duplicate()
	_bind_interaction_polygon_signals()
	_rebuild_interaction_cache()


func get_active_head_snapshots() -> Array[Dictionary]:
	## Object allocation occurs only on explicit inspection, never in fixed steps.
	var result: Array[Dictionary] = []
	for slot in range(_storage_capacity):
		if not _head_is_readable(slot):
			continue
		result.append({
			"id": slot,
			"slot_id": slot,
			"slot_index": slot,
			"active": true,
			"generation": _generations[slot],
			"position": _positions[slot],
			"velocity": _velocities[slot],
			"state": _states[slot],
			"state_name": _state_name(_states[slot]),
			"state_time": _state_times[slot],
			"lane_seed": _lane_seeds[slot],
		})
	return result


func get_active_head_arrays() -> Dictionary:
	## Compact parallel arrays for salmon/source assignment without per-head
	## dictionaries. Returned PackedArrays are snapshots and safe for readers.
	var ids := PackedInt32Array()
	var generations := PackedInt32Array()
	var positions := PackedVector2Array()
	var velocities := PackedVector2Array()
	var states := PackedByteArray()
	for slot in range(_storage_capacity):
		if not _head_is_readable(slot):
			continue
		ids.append(slot)
		generations.append(_generations[slot])
		positions.append(_positions[slot])
		velocities.append(_velocities[slot])
		states.append(_states[slot])
	return {
		"ids": ids,
		"generations": generations,
		"positions": positions,
		"velocities": velocities,
		"states": states,
	}


func get_active_head_ids() -> PackedInt32Array:
	var ids := PackedInt32Array()
	for slot in range(_storage_capacity):
		if _head_is_readable(slot):
			ids.append(slot)
	return ids


func get_active_head_positions() -> PackedVector2Array:
	var positions := PackedVector2Array()
	for slot in range(_storage_capacity):
		if _head_is_readable(slot):
			positions.append(_positions[slot])
	return positions


func runtime_summary() -> Dictionary:
	var state_counts := PackedInt32Array()
	state_counts.resize(HeadState.size())
	state_counts.fill(0)
	var readable_count := 0
	for slot in range(_storage_capacity):
		if _enabled[slot] == 0:
			continue
		var state: int = _states[slot]
		state_counts[state] += 1
		if _head_is_readable(slot):
			readable_count += 1
	return {
		"backend": "cpu_compact_water_heads",
		"fixed_hz": FIXED_HZ,
		"fixed_step_index": _fixed_step_index,
		"simulation_time": _simulation_time,
		"accumulator": _fixed_accumulator,
		"paused": _paused,
		"capacity": _storage_capacity,
		"active_slot_count": _active_slot_count,
		"readable_head_count": readable_count,
		"state_counts": Array(state_counts),
		"reservoir_gate_open": gate_open,
		"reservoir_gate_aperture": gate_aperture,
		"reservoir_gate_release_probability": (
			gate_aperture if gate_open else 0.0
		),
		"interaction_polygon_count": _interaction_cache.size(),
		"interaction_input_coordinates": "configured world_size, Y-up",
		"segment_history_owned_by_model": false,
		"renderer_owned_by_model": false,
		"custom_spawn_provider": _spawn_provider.is_valid(),
	}


func _fixed_step(delta: float) -> void:
	_synchronize_active_slots()
	for slot in range(_storage_capacity):
		if _enabled[slot] == 0:
			continue
		_step_head(slot, delta)
	_simulation_time += delta
	_fixed_step_index += 1


func _step_head(slot: int, delta: float) -> void:
	_state_times[slot] += delta
	var state: int = _states[slot]
	if state == HeadState.RECYCLE_WAIT:
		if _state_times[slot] >= trail_lifetime + RECYCLE_SAFETY_SECONDS:
			_spawn_at_inlet(slot)
		return
	if state == HeadState.ABSORBED:
		if _state_times[slot] >= trail_lifetime + RECYCLE_SAFETY_SECONDS:
			_spawn_at_inlet(slot)
		return

	var old_position: Vector2 = _positions[slot]
	var next_position := old_position
	match state:
		HeadState.ENTERING:
			next_position = _step_entering(slot, old_position, delta)
		HeadState.RETAINED:
			next_position = _step_retained(slot, old_position, delta)
		HeadState.GATE_STAGING:
			next_position = _step_gate_staging(slot, old_position, delta)
		HeadState.GATE_FLUSHING:
			next_position = _step_gate_flushing(slot, old_position, delta)
		HeadState.EXITING:
			next_position = _step_exiting(slot, old_position, delta)
		HeadState.RELEASED:
			next_position = _step_released(slot, old_position, delta)
		_:
			next_position = _step_ordinary_flow(slot, old_position, delta)

	_positions[slot] = next_position
	if _states[slot] != HeadState.ABSORBED:
		_velocities[slot] = (next_position - old_position) / maxf(delta, EPSILON)
	_emit_completed_segment(slot, old_position, next_position)

	if _states[slot] == HeadState.ABSORBED:
		return
	if (
		next_position.x < -EXIT_MARGIN
		or next_position.x > stage_size.x
		or next_position.y < -EXIT_MARGIN
		or next_position.y > stage_size.y + EXIT_MARGIN
	):
		_states[slot] = HeadState.RECYCLE_WAIT
		_state_times[slot] = 0.0


func _step_ordinary_flow(
	slot: int,
	point: Vector2,
	delta: float
) -> Vector2:
	var speed := _head_speed(slot)
	var target_velocity := _flow_target_velocity(slot, point, speed)
	var state: int = _states[slot]
	if state == HeadState.FLOWING:
		target_velocity = _apply_repeller_field(
			slot, point, target_velocity, speed
		)
	var resolved_velocity := _approach_velocity(
		_velocities[slot], target_velocity, delta
	)
	var next_point := point + resolved_velocity * delta

	if reservoir_enabled and _reservoir_decided[slot] == 0:
		var admitted := _evaluate_reservoir_decision(slot, point, next_point, speed)
		if admitted:
			return next_point

	state = _states[slot]
	if state == HeadState.BYPASSING:
		var clear_x := _reservoir_clear_x(speed, delta)
		if point.x - reservoir_center_pixels.x > clear_x:
			_states[slot] = HeadState.FLOWING
			_state_times[slot] = 0.0
	elif state == HeadState.FLOWING:
		next_point = _resolve_swept_interactions(
			slot, point, next_point, speed, delta
		)
	return next_point


func _evaluate_reservoir_decision(
	slot: int,
	point: Vector2,
	next_point: Vector2,
	speed: float
) -> bool:
	var relative_start := point - reservoir_center_pixels
	var relative_end := next_point - reservoir_center_pixels
	var decision_x := _reservoir_decision_x(speed, FIXED_DELTA)
	if relative_end.x < decision_x or relative_start.x >= 0.0:
		return false
	if relative_start.x > decision_x:
		# A runtime reset/geometry edit can place a head beyond the plane. It still
		# receives exactly one decision at its current geometry, never a retry.
		decision_x = relative_start.x
	var segment_x := relative_end.x - relative_start.x
	var decision_fraction := 0.0
	if absf(segment_x) > EPSILON:
		decision_fraction = clampf(
			(decision_x - relative_start.x) / segment_x, 0.0, 1.0
		)
	var decision_y := lerpf(
		relative_start.y, relative_end.y, decision_fraction
	)
	var capture_limit := _reservoir_capture_limit_y()
	_reservoir_decided[slot] = 1
	_state_times[slot] = 0.0
	if absf(decision_y) <= capture_limit:
		_states[slot] = HeadState.ENTERING
		_capture_envelope_entered[slot] = 0
		return true
	_states[slot] = HeadState.BYPASSING
	return false


func _step_entering(
	slot: int,
	point: Vector2,
	delta: float
) -> Vector2:
	if not reservoir_enabled:
		_states[slot] = HeadState.RELEASED
		_state_times[slot] = 0.0
		return _step_released(slot, point, delta)
	var speed := _head_speed(slot)
	var relative := point - reservoir_center_pixels
	var distance := maxf(relative.length(), 0.001)
	var radial := _safe_radial(relative, _orbit_seeds[slot])
	var tangent := Vector2(-radial.y, radial.x)
	var orbit_radius: float = _orbit_radii[slot]
	var orbit_tangent_speed := _orbit_tangent_speed(orbit_radius)
	var target_velocity := _flow_target_velocity(slot, point, speed)
	var envelope_radius := reservoir_radius_pixels + reservoir_influence_pixels
	var entry_weight := 1.0 - _smoothstep(
		reservoir_radius_pixels,
		maxf(envelope_radius, reservoir_radius_pixels + 0.001),
		distance
	)
	var radial_error := distance - orbit_radius
	var entry_velocity := (
		tangent * orbit_tangent_speed * 0.20
		- radial * maxf(radial_error, 0.0) * reservoir_entry_pull_strength
	)
	target_velocity = target_velocity.lerp(entry_velocity, entry_weight)
	var resolved_velocity := _approach_velocity(
		_velocities[slot], target_velocity, delta
	)
	var minimum_inward_speed := minf(
		speed * reservoir_entry_min_inward_speed_ratio,
		maxf(radial_error, 0.0) * reservoir_entry_pull_strength
	)
	var inward_speed := resolved_velocity.dot(-radial)
	if inward_speed < minimum_inward_speed:
		resolved_velocity += -radial * (minimum_inward_speed - inward_speed)
	var next_point := point + resolved_velocity * delta

	if distance <= envelope_radius:
		_capture_envelope_entered[slot] = 1
	var rim_fraction := _first_circle_intersection(
		relative,
		next_point - reservoir_center_pixels,
		reservoir_radius_pixels
	)
	if distance > reservoir_radius_pixels and rim_fraction >= 0.0:
		var rim_relative := relative.lerp(
			next_point - reservoir_center_pixels, rim_fraction
		)
		var rim_normal := _safe_radial(rim_relative, _orbit_seeds[slot])
		next_point = (
			reservoir_center_pixels
			+ rim_normal * reservoir_radius_pixels * 0.995
		)
		_states[slot] = HeadState.RETAINED
		_state_times[slot] = 0.0
		_gate_sector_latched[slot] = 0
		return next_point

	if _capture_envelope_entered[slot] != 0:
		next_point = _contain_at_radius(
			point, next_point, resolved_velocity, envelope_radius
		)
	return next_point


func _step_retained(
	slot: int,
	point: Vector2,
	delta: float
) -> Vector2:
	if not reservoir_enabled:
		_states[slot] = HeadState.RELEASED
		_state_times[slot] = 0.0
		return _step_released(slot, point, delta)
	if _should_select_gate_release(slot, point):
		_states[slot] = HeadState.GATE_STAGING
		_state_times[slot] = 0.0
		return _step_gate_staging(slot, point, delta)
	var relative := point - reservoir_center_pixels
	var distance := maxf(relative.length(), 0.001)
	var radial := _safe_radial(relative, _orbit_seeds[slot])
	var tangent := Vector2(-radial.y, radial.x)
	var orbit_radius: float = _orbit_radii[slot]
	var orbit_velocity := (
		tangent * _orbit_tangent_speed(orbit_radius)
		- radial * (distance - orbit_radius) * 2.35
	)
	var resolved_velocity := _approach_velocity(
		_velocities[slot], orbit_velocity, delta
	)
	return _contain_at_radius(
		point,
		point + resolved_velocity * delta,
		resolved_velocity,
		reservoir_radius_pixels * 0.995
	)


func _step_gate_staging(
	slot: int,
	point: Vector2,
	delta: float
) -> Vector2:
	if not gate_open or gate_aperture <= 0.0:
		_states[slot] = HeadState.RETAINED
		_state_times[slot] = 0.0
		return _step_retained(slot, point, delta)
	var relative := point - reservoir_center_pixels
	var distance := maxf(relative.length(), 0.001)
	var radial := _safe_radial(relative, _orbit_seeds[slot])
	var tangent := Vector2(-radial.y, radial.x)
	var orbit_ratio := _orbit_radii[slot] / maxf(reservoir_radius_pixels, 0.001)
	var staging_ratio := clampf(
		maxf(reservoir_gate_staging_radius_ratio, orbit_ratio), 0.50, 0.95
	)
	var staging_radius := reservoir_radius_pixels * staging_ratio
	var tangent_speed := _staging_tangent_speed(distance)
	var target_velocity := (
		tangent * tangent_speed
		- radial * (distance - staging_radius) * 2.35
	)
	var resolved_velocity := _approach_velocity(
		_velocities[slot], target_velocity, delta
	)
	var next_point := _contain_at_radius(
		point,
		point + resolved_velocity * delta,
		resolved_velocity,
		reservoir_radius_pixels * 0.995
	)
	var next_distance := next_point.distance_to(reservoir_center_pixels)
	# Tangential integration has a small outward equilibrium offset. A selected
	# head is already committed, so a bounded fallback advances it to flushing
	# rather than letting a subpixel tolerance own it forever.
	var tolerance := maxf(8.0, reservoir_radius_pixels * 0.05)
	var staging_timeout := 2.0 if gate_aperture >= 0.999 else 3.5
	if (
		absf(next_distance - staging_radius) <= tolerance
		or _state_times[slot] >= staging_timeout
	):
		_states[slot] = HeadState.GATE_FLUSHING
		_state_times[slot] = 0.0
	return next_point


func _step_gate_flushing(
	slot: int,
	point: Vector2,
	delta: float
) -> Vector2:
	if not gate_open or gate_aperture <= 0.0:
		_states[slot] = HeadState.RETAINED
		_state_times[slot] = 0.0
		return _step_retained(slot, point, delta)
	var relative := point - reservoir_center_pixels
	var distance := maxf(relative.length(), 0.001)
	var half_width := _gate_half_width_pixels()
	if relative.x > 0.0 and absf(relative.y) < half_width:
		_states[slot] = HeadState.EXITING
		_state_times[slot] = 0.0
		return _step_exiting(slot, point, delta)
	var radial := _safe_radial(relative, _orbit_seeds[slot])
	var tangent := Vector2(-radial.y, radial.x)
	var orbit_ratio := _orbit_radii[slot] / maxf(reservoir_radius_pixels, 0.001)
	var staging_radius := reservoir_radius_pixels * clampf(
		maxf(reservoir_gate_staging_radius_ratio, orbit_ratio), 0.50, 0.95
	)
	var target_velocity := (
		tangent * _staging_tangent_speed(distance)
		- radial * (distance - staging_radius) * 2.35
	)
	var resolved_velocity := _approach_velocity(
		_velocities[slot], target_velocity, delta
	)
	return _contain_at_radius(
		point,
		point + resolved_velocity * delta,
		resolved_velocity,
		reservoir_radius_pixels * 0.995
	)


func _step_exiting(
	slot: int,
	point: Vector2,
	delta: float
) -> Vector2:
	if not gate_open or gate_aperture <= 0.0:
		_states[slot] = HeadState.RETAINED
		_state_times[slot] = 0.0
		return _step_retained(slot, point, delta)
	var relative := point - reservoir_center_pixels
	var half_width := _gate_half_width_pixels()
	if absf(relative.y) > half_width + 1.0:
		_states[slot] = HeadState.GATE_FLUSHING
		_state_times[slot] = 0.0
		return _step_gate_flushing(slot, point, delta)
	var speed := _head_speed(slot)
	var target_velocity := Vector2(speed * 1.55, -relative.y * 5.0)
	var resolved_velocity := _approach_velocity(
		_velocities[slot], target_velocity, delta
	)
	var next_relative := point + resolved_velocity * delta - reservoir_center_pixels
	next_relative.y = clampf(next_relative.y, -half_width, half_width)
	var rim_x := sqrt(maxf(
		reservoir_radius_pixels * reservoir_radius_pixels
		- next_relative.y * next_relative.y,
		0.0
	))
	if next_relative.x >= rim_x:
		_states[slot] = HeadState.RELEASED
		_state_times[slot] = 0.0
	return reservoir_center_pixels + next_relative


func _step_released(
	slot: int,
	point: Vector2,
	delta: float
) -> Vector2:
	var speed := _head_speed(slot)
	var ordinary_velocity := _flow_target_velocity(slot, point, speed)
	var relative := point - reservoir_center_pixels
	var clear_x := reservoir_radius_pixels + reservoir_influence_pixels
	var outlet_weight := 1.0 - _smoothstep(
		reservoir_radius_pixels * 0.75, maxf(clear_x, 0.001), relative.x
	)
	var outlet_velocity := Vector2(speed * 1.45, -relative.y * 4.0)
	var target_velocity := ordinary_velocity.lerp(outlet_velocity, outlet_weight)
	var resolved_velocity := _approach_velocity(
		_velocities[slot], target_velocity, delta
	)
	if _state_times[slot] >= trail_lifetime and relative.x > clear_x:
		_states[slot] = HeadState.FLOWING
		_state_times[slot] = 0.0
	return point + resolved_velocity * delta


func _should_select_gate_release(slot: int, point: Vector2) -> bool:
	if not gate_open or gate_aperture <= 0.0:
		_gate_sector_latched[slot] = 0
		return false
	# Diameter-wide means a hard drain: every retained head is committed on its
	# next fixed tick. Staging preserves a continuous spiral instead of a spoke.
	if gate_aperture >= 0.999:
		return true
	var relative := point - reservoir_center_pixels
	var distance := maxf(relative.length(), 0.001)
	var radial_error := absf(distance - _orbit_radii[slot])
	var orbit_settled := radial_error <= maxf(4.0, _orbit_radii[slot] * 0.10)
	var in_gate_sector := (
		relative.x > 0.0
		and absf(relative.y) / distance < gate_aperture
		and orbit_settled
	)
	if not in_gate_sector:
		_gate_sector_latched[slot] = 0
		return false
	if _gate_sector_latched[slot] != 0:
		return false
	_gate_sector_latched[slot] = 1
	_gate_attempts[slot] += 1
	var selector := _hash11(
		float(slot) * 17.137
		+ float(_gate_attempts[slot]) * 0.731
		+ float(_generations[slot]) * 3.119
		+ stage_phase * 7.0
	)
	return selector < gate_aperture


func _apply_repeller_field(
	slot: int,
	point: Vector2,
	target_velocity: Vector2,
	speed: float
) -> Vector2:
	var result := target_velocity
	for record: Dictionary in _interaction_cache:
		var mode: int = record["mode"]
		var enabled: bool = record["enabled"]
		var strength: float = record["repellent_force"]
		if (
			not enabled
			or mode != GPUFlowInteractionPolygon.Mode.REPEL
			or strength <= 0.0
		):
			continue
		var influence: float = record["influence_pixels"]
		var bounds: Rect2 = record["bounds"]
		if not bounds.grow(influence).has_point(point):
			continue
		var vertices: PackedVector2Array = record["vertices"]
		var inside := _point_in_polygon(point, vertices)
		var closest := _closest_polygon_edge(point, record)
		var closest_distance: float = closest["distance"]
		if not inside and closest_distance > influence:
			continue
		var proximity := 1.0
		if not inside:
			proximity = 1.0 - _smoothstep(
				0.0, maxf(influence, 0.001), closest_distance
			)
		var centroid: Vector2 = record["centroid"]
		var stable_seed: float = record["stable_seed"]
		var vertical_side := -1.0 if point.y < centroid.y else 1.0
		if absf(point.y - centroid.y) < 1.0:
			vertical_side = (
				-1.0
				if _hash11(float(slot) * 3.173 + stable_seed * 97.0) < 0.5
				else 1.0
			)
		var outward: Vector2 = closest["outward"]
		var active_strength := strength * proximity
		result += (
			outward * speed * 1.10
			+ Vector2(0.0, vertical_side * speed * 0.85)
		) * active_strength
		result.x = maxf(result.x, speed * 0.08)
	return result


func _resolve_swept_interactions(
	slot: int,
	point: Vector2,
	initial_next_point: Vector2,
	speed: float,
	delta: float
) -> Vector2:
	var next_point := initial_next_point
	for record: Dictionary in _interaction_cache:
		var enabled: bool = record["enabled"]
		if not enabled:
			continue
		var bounds: Rect2 = record["bounds"]
		if not _segment_overlaps_rect(point, next_point, bounds):
			continue
		var vertices: PackedVector2Array = record["vertices"]
		if _point_in_polygon(point, vertices):
			# Runtime edits never retroactively consume a head already inside.
			continue
		var mode: int = record["mode"]
		var orientation: float = record["orientation"]
		var earliest_crossing := 2.0
		var crossing_outward := Vector2(-1.0, 0.0)
		for vertex_index in range(vertices.size()):
			var edge_start := vertices[vertex_index]
			var edge_end := vertices[(vertex_index + 1) % vertices.size()]
			var edge := edge_end - edge_start
			var right_normal := Vector2(edge.y, -edge.x).normalized()
			var outward := right_normal if orientation >= 0.0 else -right_normal
			if (
				mode == GPUFlowInteractionPolygon.Mode.ABSORB
				and outward.x >= -0.15
			):
				continue
			if (next_point - point).dot(outward) >= 0.0:
				continue
			var crossing := _segment_intersection_fraction(
				point, next_point, edge_start, edge_end
			)
			if crossing >= 0.0 and crossing < earliest_crossing:
				earliest_crossing = crossing
				crossing_outward = outward
		if earliest_crossing > 1.0:
			continue
		var crossing_point := point.lerp(next_point, earliest_crossing)
		var stable_seed: float = record["stable_seed"]
		if mode == GPUFlowInteractionPolygon.Mode.ABSORB:
			var absorption_fraction: float = record["absorption_fraction"]
			var absorption_selector := _hash11(
				float(slot) * 19.731
				+ stable_seed * 811.0
				+ stage_phase * 7.0
			)
			if absorption_selector < absorption_fraction:
				next_point = crossing_point - crossing_outward * 1.5
				_states[slot] = HeadState.ABSORBED
				_state_times[slot] = 0.0
				_velocities[slot] = Vector2.ZERO
				break
			var wave_strength: float = record["wave_strength"]
			var wave_direction := (
				-1.0
				if _hash11(float(slot) * 5.271 + stable_seed * 173.0) < 0.5
				else 1.0
			)
			var rejected_velocity := (
				(next_point - point) / maxf(delta, EPSILON)
			)
			rejected_velocity.y += (
				wave_direction * speed * wave_strength * 0.35
			)
			rejected_velocity.x = maxf(rejected_velocity.x, speed * 0.08)
			next_point = point + rejected_velocity * delta
		else:
			var repellent_strength: float = record["repellent_force"]
			if repellent_strength <= 0.0:
				continue
			var centroid: Vector2 = record["centroid"]
			var vertical_side := -1.0 if crossing_point.y < centroid.y else 1.0
			if absf(crossing_point.y - centroid.y) < 1.0:
				vertical_side = (
					-1.0
					if _hash11(float(slot) * 3.173 + stable_seed * 97.0) < 0.5
					else 1.0
				)
			var remaining_step := next_point.distance_to(crossing_point)
			var redirected_direction := Vector2(
				maxf(0.12, 0.38 + crossing_outward.x * 0.22),
				vertical_side * (0.85 + absf(crossing_outward.y) * 0.25)
			).normalized()
			var redirected_endpoint := (
				crossing_point
				+ crossing_outward * 1.5
				+ redirected_direction * remaining_step
			)
			next_point = next_point.lerp(
				redirected_endpoint, repellent_strength
			)
	return next_point


func _closest_polygon_edge(point: Vector2, record: Dictionary) -> Dictionary:
	var vertices: PackedVector2Array = record["vertices"]
	var orientation: float = record["orientation"]
	var closest_distance_squared := INF
	var closest_outward := Vector2(-1.0, 0.0)
	for vertex_index in range(vertices.size()):
		var edge_start := vertices[vertex_index]
		var edge_end := vertices[(vertex_index + 1) % vertices.size()]
		var edge := edge_end - edge_start
		var edge_length_squared := maxf(edge.length_squared(), EPSILON)
		var edge_fraction := clampf(
			(point - edge_start).dot(edge) / edge_length_squared, 0.0, 1.0
		)
		var closest_point := edge_start + edge * edge_fraction
		var distance_squared := point.distance_squared_to(closest_point)
		if distance_squared < closest_distance_squared:
			closest_distance_squared = distance_squared
			var right_normal := Vector2(edge.y, -edge.x).normalized()
			closest_outward = right_normal if orientation >= 0.0 else -right_normal
	return {
		"distance": sqrt(maxf(closest_distance_squared, 0.0)),
		"outward": closest_outward,
	}


func _emit_completed_segment(
	slot: int,
	from_position: Vector2,
	to_position: Vector2
) -> void:
	if _suppress_segments:
		return
	var length := from_position.distance_to(to_position)
	if length <= 0.0001 or length > maximum_segment_length:
		return
	var style_seed: float = _style_seeds[slot]
	var width := lerpf(line_width_min, line_width_max, style_seed)
	var palette_index := clampi(int(floor(style_seed * float(PALETTE_SIZE))), 0, PALETTE_SIZE - 1)
	segment_created.emit(
		from_position, to_position, width, palette_index, particle_alpha
	)
	if _segment_sink.is_valid():
		_segment_sink.call(
			from_position, to_position, width, palette_index, particle_alpha
		)


func _flow_target_velocity(
	slot: int,
	point: Vector2,
	speed: float
) -> Vector2:
	return Vector2(
		speed,
		_flow_noise(point, _lane_seeds[slot]) * noise_strength
	)


func _flow_noise(point: Vector2, seed: float) -> float:
	var first := sin(
		point.x * noise_scale
		+ point.y * noise_scale * 0.73
		+ _simulation_time * noise_speed
		+ seed * TAU
		+ stage_phase
	)
	var second := sin(
		point.x * noise_scale * 0.31
		- point.y * noise_scale * 1.27
		- _simulation_time * noise_speed * 0.63
		+ seed * 11.0
	)
	return first * 0.68 + second * 0.32


func _head_speed(slot: int) -> float:
	var base_speed := flow_speed_pixels * maxf(flow_rate, min_active_flow)
	return base_speed * lerpf(
		1.0 - speed_variation,
		1.0 + speed_variation,
		_hash11(float(slot) * 2.371)
	)


func _approach_velocity(
	current: Vector2,
	target: Vector2,
	delta: float
) -> Vector2:
	if velocity_response <= 0.0:
		return target
	var response_alpha := 1.0 - exp(-velocity_response * delta)
	return current.lerp(target, response_alpha)


func _orbit_tangent_speed(orbit_radius: float) -> float:
	var orbit_ratio := orbit_radius / maxf(reservoir_radius_pixels, 0.001)
	var tangent_scale := minf(
		orbit_ratio / maxf(reservoir_orbit_full_speed_ratio, 0.02), 1.0
	)
	return minf(
		reservoir_swirl_speed * tangent_scale,
		maxf(reservoir_orbit_max_angular_speed, 0.01) * orbit_radius
	)


func _staging_tangent_speed(distance: float) -> float:
	var speed := minf(
		reservoir_swirl_speed,
		maxf(reservoir_orbit_max_angular_speed, 0.01) * maxf(distance, 0.01)
	)
	if gate_aperture >= 0.999:
		return maxf(speed, maxf(_current_base_speed() * 0.35, 40.0))
	return speed


func _contain_at_radius(
	point: Vector2,
	next_point: Vector2,
	resolved_velocity: Vector2,
	containment_radius: float
) -> Vector2:
	var next_relative := next_point - reservoir_center_pixels
	var next_distance := next_relative.length()
	if next_distance <= containment_radius:
		return next_point
	var containment_normal := _safe_radial(next_relative, 0.5)
	var corrected_velocity := resolved_velocity
	var outward_speed := corrected_velocity.dot(containment_normal)
	if outward_speed > 0.0:
		corrected_velocity -= containment_normal * outward_speed
	var corrected_point := point + corrected_velocity * FIXED_DELTA
	var corrected_relative := corrected_point - reservoir_center_pixels
	var corrected_distance := corrected_relative.length()
	if corrected_distance > containment_radius:
		corrected_point = (
			reservoir_center_pixels
			+ _safe_radial(corrected_relative, 0.5) * containment_radius
		)
	return corrected_point


func _ensure_storage() -> void:
	if _storage_capacity != maxi(particle_slots, 1):
		reset()


func _resize_storage(capacity: int) -> void:
	_storage_capacity = capacity
	_positions.resize(capacity)
	_velocities.resize(capacity)
	_states.resize(capacity)
	_enabled.resize(capacity)
	_reservoir_decided.resize(capacity)
	_capture_envelope_entered.resize(capacity)
	_gate_sector_latched.resize(capacity)
	_generations.resize(capacity)
	_gate_attempts.resize(capacity)
	_state_times.resize(capacity)
	_lane_seeds.resize(capacity)
	_style_seeds.resize(capacity)
	_orbit_seeds.resize(capacity)
	_orbit_radii.resize(capacity)


func _clear_slot(slot: int) -> void:
	_positions[slot] = Vector2(INLET_X, stage_size.y * 0.5)
	_velocities[slot] = Vector2.ZERO
	_states[slot] = HeadState.RECYCLE_WAIT
	_reservoir_decided[slot] = 0
	_capture_envelope_entered[slot] = 0
	_gate_sector_latched[slot] = 0
	_gate_attempts[slot] = 0
	_state_times[slot] = 0.0


func _initialize_slot_seeds(slot: int) -> void:
	_lane_seeds[slot] = _hash11(float(slot) + stage_phase * 19.0)
	_style_seeds[slot] = _hash11(float(slot) * 1.913 + stage_phase * 31.0)
	_orbit_seeds[slot] = _hash11(
		float(slot) * 5.713 + stage_phase * 43.0 + 0.317
	)
	_orbit_radii[slot] = _orbit_radius_for_seed(_orbit_seeds[slot])


func _refresh_orbit_radii() -> void:
	for slot in range(_storage_capacity):
		_orbit_radii[slot] = _orbit_radius_for_seed(_orbit_seeds[slot])


func _orbit_radius_for_seed(seed: float) -> float:
	var minimum_ratio := clampf(
		minf(
			reservoir_orbit_radius_min_ratio,
			reservoir_orbit_radius_max_ratio
		),
		0.02,
		1.0
	)
	var maximum_ratio := clampf(
		maxf(
			reservoir_orbit_radius_min_ratio,
			reservoir_orbit_radius_max_ratio
		),
		minimum_ratio,
		1.0
	)
	return reservoir_radius_pixels * lerpf(
		minimum_ratio, maximum_ratio, seed
	)


func _spawn_initially_distributed(slot: int) -> void:
	# A deterministic phase distribution fills the river without simulating eight
	# seconds in _ready(). Heads already downstream of the decision plane are
	# permanently bypass-latched for this lifecycle, so the reservoir starts empty.
	var phase := _hash11(float(slot) * 7.117 + stage_phase * 13.0)
	var lane_y := lerpf(
		INLET_MARGIN_Y,
		stage_size.y - INLET_MARGIN_Y,
		_lane_seeds[slot]
	)
	var position := Vector2(lerpf(INLET_X, stage_size.x, phase), lane_y)
	_positions[slot] = position
	_velocities[slot] = _flow_target_velocity(
		slot, position, _head_speed(slot)
	)
	_states[slot] = HeadState.FLOWING
	_state_times[slot] = 0.0
	_reservoir_decided[slot] = 0
	_capture_envelope_entered[slot] = 0
	_gate_sector_latched[slot] = 0
	_gate_attempts[slot] = 0
	if reservoir_enabled:
		var decision_x := _reservoir_decision_x(
			_head_speed(slot), FIXED_DELTA
		)
		var relative_x := position.x - reservoir_center_pixels.x
		if relative_x >= decision_x:
			_reservoir_decided[slot] = 1
			if relative_x <= _reservoir_clear_x(
				_head_speed(slot), FIXED_DELTA
			):
				_states[slot] = HeadState.BYPASSING


func _spawn_at_inlet(slot: int) -> void:
	_generations[slot] += 1
	_initialize_slot_seeds(slot)
	var default_position := Vector2(
		INLET_X,
		lerpf(
			INLET_MARGIN_Y,
			stage_size.y - INLET_MARGIN_Y,
			_lane_seeds[slot]
		)
	)
	var spawn_position := _spawn_provider_position(slot, default_position)
	_positions[slot] = spawn_position
	_velocities[slot] = _flow_target_velocity(
		slot, spawn_position, _head_speed(slot)
	)
	_states[slot] = HeadState.FLOWING
	_state_times[slot] = 0.0
	_reservoir_decided[slot] = 0
	_capture_envelope_entered[slot] = 0
	_gate_sector_latched[slot] = 0
	_gate_attempts[slot] = 0


func _spawn_provider_position(slot: int, fallback: Vector2) -> Vector2:
	if not _spawn_provider.is_valid():
		return fallback
	var provided: Variant = _spawn_provider.call(
		slot, _generations[slot], _lane_seeds[slot]
	)
	if provided is Vector2:
		var provided_position: Vector2 = provided
		if is_finite(provided_position.x) and is_finite(provided_position.y):
			return provided_position
	if provided is Dictionary:
		var definition: Dictionary = provided
		if definition.has("position"):
			return _variant_to_vector2(definition["position"], fallback)
	return fallback


func _synchronize_active_slots() -> void:
	var desired := _desired_active_slot_count()
	if desired == _active_slot_count and _storage_capacity == particle_slots:
		return
	_active_slot_count = desired
	for slot in range(_storage_capacity):
		if slot < desired:
			if _enabled[slot] == 0:
				_enabled[slot] = 1
				_spawn_at_inlet(slot)
		else:
			_enabled[slot] = 0
			_clear_slot(slot)


func _desired_active_slot_count() -> int:
	if flow_rate <= 0.0:
		return 0
	return clampi(
		int(ceil(float(maxi(particle_slots, 1)) * flow_rate)),
		0,
		maxi(particle_slots, 1)
	)


func _head_is_readable(slot: int) -> bool:
	if slot < 0 or slot >= _storage_capacity or _enabled[slot] == 0:
		return false
	var state: int = _states[slot]
	return state != HeadState.ABSORBED and state != HeadState.RECYCLE_WAIT


func _bind_interaction_polygon_signals() -> void:
	var callback := Callable(self, "_on_interaction_polygon_changed")
	for polygon: GPUFlowInteractionPolygon in _interaction_polygons:
		if polygon == null:
			continue
		if not polygon.changed.is_connected(callback):
			polygon.changed.connect(callback)


func _unbind_interaction_polygon_signals() -> void:
	var callback := Callable(self, "_on_interaction_polygon_changed")
	for polygon: GPUFlowInteractionPolygon in _interaction_polygons:
		if polygon == null:
			continue
		if polygon.changed.is_connected(callback):
			polygon.changed.disconnect(callback)


func _on_interaction_polygon_changed() -> void:
	_rebuild_interaction_cache()


func _rebuild_interaction_cache() -> void:
	_interaction_cache.clear()
	for polygon: GPUFlowInteractionPolygon in _interaction_polygons:
		if _interaction_cache.size() >= MAX_INTERACTION_POLYGONS:
			break
		if polygon == null or not polygon.is_valid_polygon(polygon.vertices):
			continue
		var native_vertices := _world_vertices_to_native(polygon.vertices)
		var bounds := _polygon_bounds(native_vertices)
		var centroid := _polygon_centroid(native_vertices)
		var signed_area := _polygon_signed_area(native_vertices)
		_interaction_cache.append({
			"vertices": native_vertices,
			"bounds": bounds,
			"centroid": centroid,
			"orientation": 1.0 if signed_area >= 0.0 else -1.0,
			"stable_seed": _stable_interaction_seed(polygon.element_id),
			"mode": int(polygon.mode),
			"absorption_fraction": clampf(polygon.absorption_fraction, 0.0, 1.0),
			"repellent_force": clampf(polygon.repellent_force, 0.0, 1.0),
			"wave_strength": clampf(polygon.wave_strength, 0.0, 1.0),
			"influence_pixels": maxf(
				polygon.influence * _pixels_per_world_unit(), 0.0
			),
			"enabled": polygon.enabled,
		})


func _world_vertices_to_native(
	world_vertices: PackedVector2Array
) -> PackedVector2Array:
	var native_vertices := PackedVector2Array()
	var safe_world_width := maxf(world_size.x, 0.001)
	var safe_world_height := maxf(world_size.y, 0.001)
	for point: Vector2 in world_vertices:
		native_vertices.append(Vector2(
			point.x / safe_world_width * stage_size.x,
			stage_size.y - point.y / safe_world_height * stage_size.y
		))
	return native_vertices


func _polygon_bounds(vertices: PackedVector2Array) -> Rect2:
	var minimum := vertices[0]
	var maximum := vertices[0]
	for point: Vector2 in vertices:
		minimum.x = minf(minimum.x, point.x)
		minimum.y = minf(minimum.y, point.y)
		maximum.x = maxf(maximum.x, point.x)
		maximum.y = maxf(maximum.y, point.y)
	return Rect2(minimum, maximum - minimum)


func _polygon_centroid(vertices: PackedVector2Array) -> Vector2:
	var sum := Vector2.ZERO
	for point: Vector2 in vertices:
		sum += point
	return sum / float(maxi(vertices.size(), 1))


func _polygon_signed_area(vertices: PackedVector2Array) -> float:
	var twice_area := 0.0
	for index in range(vertices.size()):
		var current := vertices[index]
		var following := vertices[(index + 1) % vertices.size()]
		twice_area += current.cross(following)
	return twice_area * 0.5


func _point_in_polygon(point: Vector2, vertices: PackedVector2Array) -> bool:
	var inside := false
	for index in range(vertices.size()):
		var current := vertices[index]
		var following := vertices[(index + 1) % vertices.size()]
		var crosses_y := (current.y > point.y) != (following.y > point.y)
		var safe_y_delta := following.y - current.y
		if absf(safe_y_delta) < EPSILON:
			safe_y_delta = -EPSILON if safe_y_delta < 0.0 else EPSILON
		var crossing_x := (
			(following.x - current.x)
			* (point.y - current.y)
			/ safe_y_delta
			+ current.x
		)
		if crosses_y and point.x < crossing_x:
			inside = not inside
	return inside


func _segment_overlaps_rect(
	start: Vector2,
	end: Vector2,
	bounds: Rect2
) -> bool:
	var minimum_x := minf(start.x, end.x)
	var maximum_x := maxf(start.x, end.x)
	var minimum_y := minf(start.y, end.y)
	var maximum_y := maxf(start.y, end.y)
	return not (
		maximum_x < bounds.position.x
		or minimum_x > bounds.end.x
		or maximum_y < bounds.position.y
		or minimum_y > bounds.end.y
	)


func _segment_intersection_fraction(
	segment_start: Vector2,
	segment_end: Vector2,
	edge_start: Vector2,
	edge_end: Vector2
) -> float:
	var segment := segment_end - segment_start
	var edge := edge_end - edge_start
	var denominator := segment.cross(edge)
	if absf(denominator) <= EPSILON:
		return -1.0
	var offset := edge_start - segment_start
	var segment_fraction := offset.cross(edge) / denominator
	var edge_fraction := offset.cross(segment) / denominator
	if (
		segment_fraction >= 0.0
		and segment_fraction <= 1.0
		and edge_fraction >= 0.0
		and edge_fraction <= 1.0
	):
		return segment_fraction
	return -1.0


func _first_circle_intersection(
	segment_start: Vector2,
	segment_end: Vector2,
	radius: float
) -> float:
	var segment := segment_end - segment_start
	var quadratic_a := segment.length_squared()
	if quadratic_a <= EPSILON:
		return -1.0
	var quadratic_b := 2.0 * segment_start.dot(segment)
	var quadratic_c := segment_start.length_squared() - radius * radius
	var discriminant := (
		quadratic_b * quadratic_b - 4.0 * quadratic_a * quadratic_c
	)
	if discriminant < 0.0:
		return -1.0
	var root := sqrt(discriminant)
	var inverse_denominator := 0.5 / quadratic_a
	var first_fraction := (-quadratic_b - root) * inverse_denominator
	var second_fraction := (-quadratic_b + root) * inverse_denominator
	if first_fraction >= 0.0 and first_fraction <= 1.0:
		return first_fraction
	if second_fraction >= 0.0 and second_fraction <= 1.0:
		return second_fraction
	return -1.0


func _reservoir_capture_limit_y() -> float:
	var half_height := maxf(
		reservoir_radius_pixels
		* clampf(reservoir_capture_y_ratio, 0.05, 1.0),
		0.01
	)
	var softness := clampf(
		reservoir_capture_edge_softness_pixels, 0.01, half_height
	)
	var minimum_incidence := clampf(
		reservoir_entry_min_incidence, 0.0, 1.0
	)
	var incidence_limit := half_height * sqrt(maxf(
		1.0 - minimum_incidence * minimum_incidence, 0.0
	))
	var soft_edge_limit := maxf(half_height - softness * 0.5, 0.01)
	return minf(incidence_limit, soft_edge_limit)


func _reservoir_decision_x(speed: float, delta: float) -> float:
	var lead := maxf(32.0, speed * delta * 2.0)
	return -(reservoir_radius_pixels + reservoir_influence_pixels + lead)


func _reservoir_clear_x(speed: float, delta: float) -> float:
	return -_reservoir_decision_x(speed, delta)


func _gate_half_width_pixels() -> float:
	return reservoir_radius_pixels * clampf(gate_aperture, 0.0, 1.0)


func _current_base_speed() -> float:
	return flow_speed_pixels * maxf(flow_rate, min_active_flow)


func _safe_radial(relative: Vector2, fallback_seed: float) -> Vector2:
	var length := relative.length()
	if length > 0.001:
		return relative / length
	var angle := fallback_seed * TAU
	return Vector2(cos(angle), sin(angle))


func _pixels_per_world_unit() -> float:
	return stage_size.x / maxf(world_size.x, 0.001)


func _stable_interaction_seed(element_id: StringName) -> float:
	var text := String(element_id)
	var accumulator := 2166136261
	for index in range(text.length()):
		accumulator = int(
			(accumulator ^ text.unicode_at(index)) * 16777619
		) & 0x7fffffff
	return float(accumulator % 1000003) / 1000003.0


func _hash11(value: float) -> float:
	return fposmod(sin(value * 127.1 + 311.7) * 43758.5453123, 1.0)


func _smoothstep(edge_start: float, edge_end: float, value: float) -> float:
	if absf(edge_end - edge_start) <= EPSILON:
		return 0.0 if value < edge_start else 1.0
	var fraction := clampf(
		(value - edge_start) / (edge_end - edge_start), 0.0, 1.0
	)
	return fraction * fraction * (3.0 - 2.0 * fraction)


func _variant_to_vector2(value: Variant, fallback: Vector2) -> Vector2:
	if value is Vector2:
		var vector_value: Vector2 = value
		if is_finite(vector_value.x) and is_finite(vector_value.y):
			return vector_value
	if value is Vector2i:
		return Vector2(value)
	if value is Array:
		var array_value: Array = value
		if array_value.size() == 2:
			var parsed := Vector2(float(array_value[0]), float(array_value[1]))
			if is_finite(parsed.x) and is_finite(parsed.y):
				return parsed
	if value is Dictionary:
		var dictionary_value: Dictionary = value
		if dictionary_value.has("x") and dictionary_value.has("y"):
			var parsed := Vector2(
				float(dictionary_value["x"]),
				float(dictionary_value["y"])
			)
			if is_finite(parsed.x) and is_finite(parsed.y):
				return parsed
	return fallback


func _state_name(state: int) -> String:
	match state:
		HeadState.FLOWING:
			return "flowing"
		HeadState.ENTERING:
			return "entering"
		HeadState.RETAINED:
			return "retained"
		HeadState.GATE_STAGING:
			return "gate_staging"
		HeadState.GATE_FLUSHING:
			return "gate_flushing"
		HeadState.EXITING:
			return "exiting"
		HeadState.RELEASED:
			return "released"
		HeadState.BYPASSING:
			return "bypassing"
		HeadState.ABSORBED:
			return "absorbed"
		HeadState.RECYCLE_WAIT:
			return "recycle_wait"
	return "unknown"
