extends Node2D
class_name FlowModel2D

## Reusable Godot port of the core water simulation in ink_flow_lines_v04.py.
##
## Simulation coordinates remain in the Python 16 x 9, Y-up world. Conversion
## to Godot's Y-down canvas happens only when trails and debug geometry draw.
## The solver is intentionally custom: soft influence fields, midpoint
## integration, absorbers, and reservoir circulation are not rigid-body
## collision responses.

signal config_applied(screen_id: StringName, revision: int)
signal parameter_changed(screen_id: StringName, path: StringName, value: Variant)
signal geometry_changed(screen_id: StringName, kind: StringName, element_id: StringName)
signal gate_changed(screen_id: StringName, reservoir_id: StringName, gate_open: bool, outlet_width: float)
signal action_completed(screen_id: StringName, action: StringName, details: Dictionary)
signal control_error(screen_id: StringName, message: String, details: Dictionary)
signal simulation_reset(screen_id: StringName)
signal stats_updated(screen_id: StringName, stats: Dictionary)

@export var screen_id: StringName = &"screen"
@export var preset: FlowProfile
@export var auto_start: bool = true
@export var accept_keyboard_input: bool = true


class TrailRing:
	var capacity: int = 2
	var storage: PackedVector2Array = PackedVector2Array()
	var first: int = 0
	var count: int = 0

	func _init(new_capacity: int = 2) -> void:
		configure(new_capacity)

	func configure(new_capacity: int) -> void:
		capacity = maxi(2, new_capacity)
		storage = PackedVector2Array()
		storage.resize(capacity)
		first = 0
		count = 0

	func clear() -> void:
		first = 0
		count = 0

	func append(point: Vector2) -> void:
		if count < capacity:
			storage[(first + count) % capacity] = point
			count += 1
			return
		storage[first] = point
		first = (first + 1) % capacity

	func erase_oldest(amount: int = 1) -> void:
		var removed := mini(maxi(amount, 0), count)
		first = (first + removed) % capacity
		count -= removed
		if count == 0:
			first = 0

	func point_at(logical_index: int) -> Vector2:
		if logical_index < 0 or logical_index >= count:
			return Vector2.INF
		return storage[(first + logical_index) % capacity]

	func set_point_at(logical_index: int, point: Vector2) -> void:
		if logical_index < 0 or logical_index >= count:
			return
		storage[(first + logical_index) % capacity] = point

	func copy_from(other: TrailRing) -> void:
		configure(other.capacity)
		for logical_index in range(other.count):
			append(other.point_at(logical_index))

	func as_packed_array() -> PackedVector2Array:
		var result := PackedVector2Array()
		result.resize(count)
		for logical_index in range(count):
			result[logical_index] = point_at(logical_index)
		return result

	func visible_count(world_size: Vector2) -> int:
		var result := 0
		for logical_index in range(count):
			var point := point_at(logical_index)
			if (
				point.x >= 0.0
				and point.x <= world_size.x
				and point.y >= 0.0
				and point.y <= world_size.y
			):
				result += 1
		return result


class WaterSlot:
	var slot_index: int
	var is_source: bool
	var active: bool = false
	var position: Vector2 = Vector2.ZERO
	var launch_time_ms: float = INF
	var retiring: bool = false
	var retirement_flow_rate: float = NAN
	var flow_sample: float = 0.5
	var flow_offset: float = 0.0
	var shore_sample: float = 0.0
	var shore_angle_offset: float = 0.0
	var width_sample: float = 0.5
	var color_index: int = 0
	var width_points: float = 1.0
	var color: Color = Color.WHITE
	var retained_reservoir_id: StringName = &""
	var retention_birth_ms: float = INF
	var release_progress: float = 0.0
	var release_threshold: float = INF
	var release_ready: bool = false
	var absorber_id: StringName = &""
	var absorption_target_x: float = NAN
	var absorbed: bool = false
	var trail: TrailRing

	func _init(index: int, source: bool, trail_capacity: int) -> void:
		slot_index = index
		is_source = source
		trail = TrailRing.new(trail_capacity)


class DebugOverlay extends Node2D:
	var model: Node

	func _draw() -> void:
		if model != null:
			model.call(&"draw_debug_geometry_on", self)


const PROTOCOL_NAME := "ink-flow/1"
const MAX_SIMULATION_FRAMES_PER_PHYSICS_TICK := 8
const REFERENCE_OUTPUT_DPI := 120.0
const POINTS_PER_INCH := 72.0
const PROFILE_STROKE_TO_CANVAS_PIXELS := REFERENCE_OUTPUT_DPI / POINTS_PER_INCH
const STRUCTURAL_PARAMETERS: Array[StringName] = [
	&"world_size",
	&"max_particles",
	&"retention_capacity",
	&"trail_length",
	&"random_seed",
]

var _config: FlowProfile
var _slots: Array[WaterSlot] = []
var _line_nodes: Array[Line2D] = []
var _rng := RandomNumberGenerator.new()
var _source_target: int = 0
var _simulation_time_seconds: float = 0.0
var _simulation_accumulator: float = 0.0
var _running: bool = true
var _pending_messages: Array[Dictionary] = []
var _last_revision: int = -1
var _last_stats_second: int = -1
var _controller_metadata: Dictionary = {}
var _debug_overlay: DebugOverlay


func _ready() -> void:
	add_to_group("flow_models")
	if preset == null:
		preset = load("res://flow/default_flow_profile.tres") as FlowProfile
	if preset == null:
		push_error("FlowModel2D: default FlowProfile could not be loaded")
		set_physics_process(false)
		return
	var preset_error := preset.validate()
	if not preset_error.is_empty():
		push_error("FlowModel2D: invalid preset: %s" % preset_error)
		set_physics_process(false)
		return

	_config = preset.duplicate_for_runtime()
	var model_errors := _validate_config(_config)
	if not model_errors.is_empty():
		push_error("FlowModel2D: invalid preset: %s" % ", ".join(model_errors))
		set_physics_process(false)
		return
	_seed_rng()
	_debug_overlay = DebugOverlay.new()
	_debug_overlay.name = "DebugGeometry"
	_debug_overlay.model = self
	_debug_overlay.z_index = 2
	add_child(_debug_overlay)
	_build_water_pool()
	_running = auto_start

	var viewport := get_viewport()
	if viewport != null and not viewport.size_changed.is_connected(_on_viewport_size_changed):
		viewport.size_changed.connect(_on_viewport_size_changed)
	_queue_all_redraw()


func _exit_tree() -> void:
	var viewport := get_viewport()
	if viewport != null and viewport.size_changed.is_connected(_on_viewport_size_changed):
		viewport.size_changed.disconnect(_on_viewport_size_changed)


func _physics_process(delta: float) -> void:
	if _config == null:
		return

	_apply_pending_messages()
	var frame_dt := 1.0 / maxf(float(_config.target_fps), 1.0)
	# Bound both work per callback and accumulated debt. Eight frames still
	# permits the schema's 240 Hz ceiling under the project's 60 Hz physics
	# clock, but a long stall cannot create an ever-growing catch-up spiral.
	_simulation_accumulator = minf(
		_simulation_accumulator + delta,
		frame_dt * float(MAX_SIMULATION_FRAMES_PER_PHYSICS_TICK)
	)
	var frames_processed := 0
	while (
		_simulation_accumulator >= frame_dt
		and frames_processed < MAX_SIMULATION_FRAMES_PER_PHYSICS_TICK
	):
		if _running:
			_simulate_frame(frame_dt)
		_simulation_accumulator -= frame_dt
		frames_processed += 1

	if frames_processed > 0:
		_refresh_all_trails()
		_queue_all_redraw()
		_emit_periodic_stats()


func _unhandled_input(event: InputEvent) -> void:
	if not accept_keyboard_input:
		return
	var key_event := event as InputEventKey
	if key_event == null or not key_event.pressed or key_event.echo:
		return

	for digit in range(10):
		if key_event.keycode == KEY_0 + digit:
			set_flow_rate(float(digit) / 9.0)
			get_viewport().set_input_as_handled()
			return

	match key_event.keycode:
		KEY_V:
			queue_action(&"toggle_debug_geometry")
		KEY_G:
			var first_reservoir := _first_reservoir_id()
			if first_reservoir != &"":
				toggle_gate(first_reservoir)
		KEY_BRACKETLEFT:
			_adjust_first_gate(-_config.gate_width_step)
		KEY_BRACKETRIGHT:
			_adjust_first_gate(_config.gate_width_step)
		KEY_F12:
			queue_action(&"capture_screenshot")
		_:
			return
	get_viewport().set_input_as_handled()


func _draw() -> void:
	if _config == null:
		return
	var canvas_size := _canvas_size()
	draw_rect(Rect2(Vector2.ZERO, canvas_size), _config.background_color, true)


func _seed_rng() -> void:
	if _config.random_seed < 0:
		_rng.randomize()
	else:
		_rng.seed = _config.random_seed


func _build_water_pool() -> void:
	for line in _line_nodes:
		if is_instance_valid(line):
			line.queue_free()
	_line_nodes.clear()
	_slots.clear()

	var total_slots := _config.max_particles + _config.retention_capacity
	for slot_index in range(total_slots):
		var slot := WaterSlot.new(
			slot_index,
			slot_index < _config.max_particles,
			_config.trail_length
		)
		slot.flow_sample = fposmod(
			float(slot_index + 1) * 0.6180339887498949,
			1.0
		)
		slot.flow_offset = (
			slot.flow_sample * 2.0 - 1.0
		) * _config.flow_variation
		slot.shore_sample = (
			fposmod(float(slot_index + 1) * 0.4142135623730951, 1.0)
			* 2.0
			- 1.0
		)
		slot.shore_angle_offset = deg_to_rad(
			slot.shore_sample * _config.shore_exit_angle_jitter_degrees
		)
		slot.width_sample = _rng.randf()
		slot.color_index = _rng.randi_range(0, maxi(_config.line_colors.size() - 1, 0))
		_apply_slot_style(slot)
		_slots.append(slot)

		var line := Line2D.new()
		line.name = "WaterTrail_%03d" % slot_index
		line.width = _profile_stroke_to_canvas(slot.width_points)
		line.default_color = slot.color
		line.joint_mode = Line2D.LINE_JOINT_ROUND
		line.begin_cap_mode = Line2D.LINE_CAP_ROUND
		line.end_cap_mode = Line2D.LINE_CAP_ROUND
		line.antialiased = true
		line.round_precision = 6
		line.visible = false
		line.z_index = 1
		add_child(line)
		_line_nodes.append(line)

	_source_target = _particle_count_for_rate(_config.flow_rate)
	for source_index in range(_config.max_particles):
		if source_index < _source_target:
			_reset_source_slot(
				_slots[source_index],
				float(source_index) * _config.particle_launch_delay_ms
			)
		else:
			_deactivate_slot(_slots[source_index])

	_simulation_time_seconds = 0.0
	_refresh_all_trails()
	simulation_reset.emit(screen_id)


func _apply_slot_style(slot: WaterSlot) -> void:
	slot.width_points = lerpf(
		_config.line_width_min,
		_config.line_width_max,
		clampf(slot.width_sample, 0.0, 1.0)
	)
	if _config.line_colors.is_empty():
		slot.color = Color.WHITE
	else:
		slot.color_index = posmod(slot.color_index, _config.line_colors.size())
		slot.color = _config.line_colors[slot.color_index]
	slot.color.a *= _config.particle_alpha


func _refresh_slot_styles() -> void:
	for slot_index in range(_slots.size()):
		var slot := _slots[slot_index]
		_apply_slot_style(slot)
		if slot_index < _line_nodes.size():
			_line_nodes[slot_index].width = _profile_stroke_to_canvas(slot.width_points)
			_line_nodes[slot_index].default_color = slot.color


func _particle_count_for_rate(rate: float) -> int:
	var clamped_rate := clampf(rate, 0.0, 1.0)
	if clamped_rate <= 0.0:
		return 0
	return maxi(
		1,
		_round_nonnegative_ties_to_even(
			float(_config.max_particles) * clamped_rate
		)
	)


func _round_nonnegative_ties_to_even(value: float) -> int:
	# Python's round() resolves exact .5 ties toward the even integer, while
	# Godot's roundi() resolves them away from zero.
	var lower := floori(value)
	var fraction := value - float(lower)
	if is_equal_approx(fraction, 0.5):
		return lower if lower % 2 == 0 else lower + 1
	return floori(value + 0.5)


func _reset_source_slot(slot: WaterSlot, launch_time_ms: float) -> void:
	var spawn := _spawn_position(slot.slot_index)
	slot.active = true
	slot.position = spawn
	slot.launch_time_ms = launch_time_ms
	slot.retiring = false
	slot.retirement_flow_rate = NAN
	slot.retained_reservoir_id = &""
	slot.retention_birth_ms = INF
	slot.release_progress = 0.0
	slot.release_threshold = INF
	slot.release_ready = false
	slot.absorber_id = &""
	slot.absorption_target_x = NAN
	slot.absorbed = false
	slot.trail.clear()
	slot.trail.append(spawn)


func _deactivate_slot(slot: WaterSlot) -> void:
	slot.active = false
	slot.launch_time_ms = INF
	slot.retiring = false
	slot.retirement_flow_rate = NAN
	slot.retained_reservoir_id = &""
	slot.retention_birth_ms = INF
	slot.release_progress = 0.0
	slot.release_threshold = INF
	slot.release_ready = false
	slot.absorber_id = &""
	slot.absorption_target_x = NAN
	slot.absorbed = false
	slot.trail.clear()
	if slot.slot_index < _line_nodes.size():
		_line_nodes[slot.slot_index].visible = false
		_line_nodes[slot.slot_index].clear_points()


func _spawn_position(source_index: int) -> Vector2:
	var channel := _spawn_channel(_config)
	var lower: float = channel.x
	var upper: float = channel.y
	var center := (lower + upper) * 0.5
	var half_span := (upper - lower) * 0.5
	var levels_per_side := ceili(float(maxi(_config.max_particles - 1, 0)) / 2.0)
	var spacing := half_span / maxf(float(levels_per_side), 1.0)
	var level := int((source_index + 1) / 2)
	var direction := 0.0
	if source_index > 0:
		direction = 1.0 if source_index % 2 == 1 else -1.0
	return Vector2(_config.spawn_x, center + direction * float(level) * spacing)


func _spawn_channel(config: FlowProfile) -> Vector2:
	var sample_x := clampf(config.spawn_x, 0.0, config.world_size.x)
	var bottom_edge := 0.0
	var top_edge := config.world_size.y
	for shoreline in config.shorelines:
		var intersections := FlowMath.vertical_polygon_intersections(
			shoreline.vertices,
			sample_x
		)
		if intersections.is_empty():
			continue
		if String(shoreline.side).to_lower() == "bottom":
			bottom_edge = maxf(
				bottom_edge,
				intersections[intersections.size() - 1]
			)
		elif String(shoreline.side).to_lower() == "top":
			top_edge = minf(top_edge, intersections[0])
	var lower := maxf(0.0, bottom_edge) + config.spawn_y_margin
	var upper := minf(config.world_size.y, top_edge) - config.spawn_y_margin
	return Vector2(lower, upper)


func _simulate_frame(frame_dt: float) -> void:
	var substeps := maxi(_config.simulation_substeps, 1)
	var substep_dt := frame_dt / float(substeps)
	var separation_forces := _compute_separation_forces()

	for substep in range(substeps):
		var time_value := _simulation_time_seconds + float(substep) * substep_dt
		var elapsed_ms := time_value * 1000.0
		_update_reservoir_release_progress(substep_dt, elapsed_ms)

		var moving_indices: Array[int] = []
		var absorbed_before: Dictionary = {}
		for slot in _slots:
			if not slot.active or elapsed_ms < slot.launch_time_ms:
				continue
			absorbed_before[slot.slot_index] = slot.absorbed
			if not slot.absorbed:
				moving_indices.append(slot.slot_index)

		var midpoint_positions: Array[Vector2] = []
		midpoint_positions.resize(moving_indices.size())
		for local_index in range(moving_indices.size()):
			var slot := _slots[moving_indices[local_index]]
			var first_velocity := _velocity_for_slot(
				slot,
				slot.position,
				time_value,
				separation_forces[slot.slot_index]
			)
			midpoint_positions[local_index] = (
				slot.position + first_velocity * substep_dt * 0.5
			)

		var next_positions: Array[Vector2] = []
		next_positions.resize(moving_indices.size())
		for local_index in range(moving_indices.size()):
			var slot := _slots[moving_indices[local_index]]
			var midpoint_velocity := _velocity_for_slot(
				slot,
				midpoint_positions[local_index],
				time_value + substep_dt * 0.5,
				separation_forces[slot.slot_index]
			)
			next_positions[local_index] = slot.position + midpoint_velocity * substep_dt

		for local_index in range(moving_indices.size()):
			_slots[moving_indices[local_index]].position = next_positions[local_index]

		for slot in _slots:
			if not slot.active or elapsed_ms < slot.launch_time_ms:
				continue
			_update_absorber_state(slot)
			var was_absorbed: bool = absorbed_before.get(slot.slot_index, slot.absorbed)
			if was_absorbed:
				slot.trail.erase_oldest()
			else:
				slot.trail.append(slot.position)

		var source_candidates: Array[int] = []
		for source_index in range(_config.max_particles):
			var source := _slots[source_index]
			if (
				source.active
				and elapsed_ms >= source.launch_time_ms
				and not source.absorbed
			):
				source_candidates.append(source_index)
		_capture_sources_in_reservoirs(source_candidates, elapsed_ms)

	_simulation_time_seconds += frame_dt
	_finish_water_lifecycles()


func _compute_separation_forces() -> Array[Vector2]:
	var result: Array[Vector2] = []
	result.resize(_slots.size())
	result.fill(Vector2.ZERO)
	if _config.separation_radius <= 0.0:
		return result

	var elapsed_ms := _simulation_time_seconds * 1000.0
	var grid: Dictionary = {}
	var candidates: Array[int] = []
	for source_index in range(_config.max_particles):
		var slot := _slots[source_index]
		if not slot.active or slot.absorbed or elapsed_ms < slot.launch_time_ms:
			continue
		candidates.append(source_index)
		var cell := Vector2i(
			floori(slot.position.x / _config.separation_radius),
			floori(slot.position.y / _config.separation_radius)
		)
		if not grid.has(cell):
			grid[cell] = []
		var members: Array = grid[cell]
		members.append(source_index)

	for source_index in candidates:
		var source := _slots[source_index]
		var source_cell := Vector2i(
			floori(source.position.x / _config.separation_radius),
			floori(source.position.y / _config.separation_radius)
		)
		for offset_y in range(-1, 2):
			for offset_x in range(-1, 2):
				var neighbor_cell := source_cell + Vector2i(offset_x, offset_y)
				if not grid.has(neighbor_cell):
					continue
				for other_index_variant in grid[neighbor_cell]:
					var other_index: int = other_index_variant
					if other_index <= source_index:
						continue
					var delta := source.position - _slots[other_index].position
					var distance := delta.length()
					if distance >= _config.separation_radius:
						continue
					var direction: Vector2
					if distance <= 0.000001:
						direction = Vector2(0.0, -1.0)
					else:
						direction = delta / distance
					var pressure := pow(
						1.0 - distance / _config.separation_radius,
						2.0
					)
					result[source_index] += direction * pressure
					result[other_index] -= direction * pressure

	for source_index in candidates:
		var force := result[source_index] * _config.separation_strength
		force.x *= _config.separation_x_scale
		if force.length() > _config.separation_max_force:
			force = force.normalized() * _config.separation_max_force
		result[source_index] = force
	return result


func _velocity_for_slot(
	slot: WaterSlot,
	point: Vector2,
	time_value: float,
	separation_force: Vector2
) -> Vector2:
	var velocity := _config.base_flow
	velocity += _curl_noise(point, time_value)
	velocity += _shore_force(slot, point)
	if slot.is_source:
		velocity += separation_force

	for obstacle in _config.circle_obstacles:
		velocity += _circle_obstacle_force(point, obstacle)
	for obstacle in _config.rectangle_obstacles:
		velocity += FlowMath.polygon_force(
			point,
			FlowMath.rectangle_vertices(
				obstacle.center,
				obstacle.size,
				obstacle.angle_degrees
			),
			obstacle.strength,
			obstacle.bend,
			obstacle.influence
		)
	for obstacle in _config.polygon_obstacles:
		velocity += FlowMath.polygon_force(
			point,
			obstacle.vertices,
			obstacle.strength,
			obstacle.bend,
			obstacle.influence
		)
	for reservoir in _config.reservoirs:
		velocity += _reservoir_force(slot, point, reservoir)

	var core_rate := _config.flow_rate
	if not is_nan(slot.retirement_flow_rate):
		core_rate = slot.retirement_flow_rate
	var particle_rate := 0.0
	if core_rate > 0.0:
		particle_rate = clampf(
			core_rate + slot.flow_offset,
			_config.min_active_flow,
			1.0
		)
	var world_scale := _config.world_size.y / maxf(_config.legacy_world_height, 0.001)
	var maximum_speed := particle_rate * _config.max_flow_speed * world_scale
	var base_reference := maxf(absf(_config.base_flow.x), 0.000001)
	velocity *= maximum_speed / base_reference
	if velocity.length() > maximum_speed:
		velocity = velocity.normalized() * maximum_speed
	return velocity


func _curl_noise(point: Vector2, time_value: float) -> Vector2:
	var x := point.x * _config.noise_scale
	var y := point.y * _config.noise_scale
	var time_phase := time_value * _config.noise_speed
	return Vector2(
		sin(y * 1.7 + time_phase)
			+ 0.55 * sin(x * 1.1 - y * 0.8 - time_phase * 1.4),
		cos(x * 1.5 - time_phase * 0.8)
			- 0.55 * cos(y * 1.2 + x * 0.7 + time_phase)
	) * _config.noise_strength


func _shore_force(slot: WaterSlot, point: Vector2) -> Vector2:
	var result := Vector2.ZERO
	for shoreline in _config.shorelines:
		var force := FlowMath.polygon_force(
			point,
			shoreline.vertices,
			shoreline.strength,
			0.0,
			shoreline.influence,
			shoreline.power,
			shoreline.force_offset
		)
		result += force.rotated(slot.shore_angle_offset)
	return result


func _circle_obstacle_force(point: Vector2, obstacle: FlowCircleObstacle) -> Vector2:
	var offset := point - obstacle.center
	var distance := offset.length()
	var radial := offset / maxf(distance, 0.05 * _world_scale())
	var influence := clampf(
		(obstacle.radius * 2.6 - distance) / maxf(obstacle.radius * 1.6, 0.000001),
		0.0,
		1.0
	)
	var tangent := Vector2(-radial.y, radial.x)
	var force := radial * influence * obstacle.strength
	force += tangent * influence * obstacle.bend
	if distance < obstacle.radius:
		force += radial * obstacle.strength * 5.0 * (obstacle.radius - distance)
	return force


func _reservoir_force(
	slot: WaterSlot,
	point: Vector2,
	reservoir: FlowReservoir
) -> Vector2:
	var local := point - reservoir.center
	var distance := local.length()
	var radial := FlowMath.safe_normalized(local, Vector2.ZERO)
	var force := Vector2.ZERO
	var inside := distance < reservoir.radius
	var downstream_half := local.x >= 0.0
	var half_gate_width := clampf(
		reservoir.outlet_width * 0.5,
		0.0,
		reservoir.radius
	)
	var in_gate := downstream_half and absf(local.y) <= half_gate_width
	var selected_for_release := (
		slot.release_ready
		and slot.retained_reservoir_id == reservoir.element_id
	)
	var usable_gate := in_gate and reservoir.gate_open and selected_for_release
	var release := inside and usable_gate
	var pooling := inside and not release

	if pooling:
		force -= _config.base_flow
		var tangent := Vector2(-radial.y, radial.x)
		force += tangent * reservoir.swirl_strength * reservoir.circulation
		var orbit_sample := fposmod(
			float(slot.slot_index + 1) * 0.7548776662466927,
			1.0
		)
		var target_radius_fraction := clampf(
			reservoir.orbit_radius_fraction
				+ (orbit_sample - 0.5) * reservoir.orbit_radius_spread,
			0.08,
			0.94
		)
		var radial_error := reservoir.radius * target_radius_fraction - distance
		force += radial * radial_error * reservoir.confinement_strength

	if release:
		var gate_center := reservoir.center + Vector2(reservoir.radius, 0.0)
		var toward_gate := FlowMath.safe_normalized(
			gate_center - point,
			Vector2.RIGHT
		)
		force += toward_gate * reservoir.outlet_strength
		force += _config.base_flow
		force.y -= local.y * (
			reservoir.outlet_strength
			/ maxf(half_gate_width, 0.05 * _world_scale())
		)

	var wall_distance := absf(distance - reservoir.radius)
	var near_wall := (
		downstream_half
		and not usable_gate
		and wall_distance < reservoir.wall_influence
	)
	if near_wall:
		var wall_weight := pow(
			1.0 - wall_distance / maxf(reservoir.wall_influence, 0.000001),
			2.0
		)
		var wall_side := -1.0 if distance < reservoir.radius else 1.0
		force += radial * reservoir.wall_strength * wall_weight * wall_side
	return force


func _update_reservoir_release_progress(timestep: float, elapsed_ms: float) -> void:
	for slot_index in range(_config.max_particles, _slots.size()):
		var slot := _slots[slot_index]
		if (
			not slot.active
			or elapsed_ms < slot.launch_time_ms
			or slot.release_ready
			or slot.retained_reservoir_id == &""
		):
			continue
		var reservoir := _find_reservoir(slot.retained_reservoir_id)
		if reservoir == null or not reservoir.gate_open:
			continue
		var aperture := _reservoir_gate_fraction(reservoir)
		if aperture <= 0.0:
			continue
		slot.release_progress += aperture * _config.reservoir_release_rate * timestep
		if slot.release_progress >= slot.release_threshold:
			slot.release_ready = true


func _reservoir_gate_fraction(reservoir: FlowReservoir) -> float:
	return clampf(
		reservoir.outlet_width / maxf(reservoir.radius * 2.0, 0.000001),
		0.0,
		1.0
	)


func _capture_sources_in_reservoirs(
	source_indices: Array[int],
	elapsed_ms: float
) -> void:
	# A retention slot may be claimed at most once in this substep. This mirrors
	# the Python batch transfer and prevents a burst geometry edit from cycling
	# through the same small retention pool hundreds of times before one sample
	# can be displayed.
	var claimed_retention_slots: Dictionary = {}
	for source_index in source_indices:
		var source := _slots[source_index]
		if not source.active:
			continue
		for reservoir in _config.reservoirs:
			if source.position.distance_to(reservoir.center) >= reservoir.radius:
				continue
			_capture_source(
				source,
				reservoir,
				elapsed_ms,
				claimed_retention_slots
			)
			break


func _capture_source(
	source: WaterSlot,
	reservoir: FlowReservoir,
	elapsed_ms: float,
	claimed_retention_slots: Dictionary
) -> bool:
	var retained_slot := _claim_retention_slot(claimed_retention_slots)
	if retained_slot == null:
		return false
	claimed_retention_slots[retained_slot.slot_index] = true

	retained_slot.active = true
	retained_slot.position = source.position
	retained_slot.launch_time_ms = elapsed_ms
	retained_slot.retiring = false
	retained_slot.retirement_flow_rate = source.retirement_flow_rate
	retained_slot.flow_sample = source.flow_sample
	retained_slot.flow_offset = source.flow_offset
	retained_slot.shore_sample = source.shore_sample
	retained_slot.shore_angle_offset = source.shore_angle_offset
	retained_slot.width_sample = source.width_sample
	retained_slot.color_index = source.color_index
	retained_slot.width_points = source.width_points
	retained_slot.color = source.color
	retained_slot.retained_reservoir_id = reservoir.element_id
	retained_slot.retention_birth_ms = elapsed_ms
	retained_slot.release_threshold = _rng.randf_range(
		_config.release_threshold_min,
		_config.release_threshold_max
	)
	if reservoir.gate_open and _reservoir_gate_fraction(reservoir) > 0.0:
		retained_slot.release_progress = _rng.randf_range(
			0.0,
			retained_slot.release_threshold
		)
	else:
		retained_slot.release_progress = 0.0
	retained_slot.release_ready = false
	retained_slot.absorber_id = &""
	retained_slot.absorption_target_x = NAN
	retained_slot.absorbed = false
	retained_slot.trail.copy_from(source.trail)

	var retained_line := _line_nodes[retained_slot.slot_index]
	retained_line.width = _profile_stroke_to_canvas(retained_slot.width_points)
	retained_line.default_color = retained_slot.color

	if source.slot_index < _source_target:
		_reset_source_slot(source, elapsed_ms)
	else:
		_deactivate_slot(source)
	return true


func _claim_retention_slot(claimed_retention_slots: Dictionary) -> WaterSlot:
	for slot_index in range(_config.max_particles, _slots.size()):
		if (
			not claimed_retention_slots.has(slot_index)
			and not _slots[slot_index].active
		):
			return _slots[slot_index]

	var oldest: WaterSlot = null
	for slot_index in range(_config.max_particles, _slots.size()):
		if claimed_retention_slots.has(slot_index):
			continue
		var candidate := _slots[slot_index]
		if oldest == null or candidate.retention_birth_ms < oldest.retention_birth_ms:
			oldest = candidate
	if oldest != null:
		_deactivate_slot(oldest)
	return oldest


func _update_absorber_state(slot: WaterSlot) -> void:
	if slot.absorbed:
		return

	if slot.absorber_id == &"":
		for absorber_index in range(_config.absorbers.size()):
			var absorber := _config.absorbers[absorber_index]
			if not _point_inside_absorber(slot.position, absorber):
				continue
			var absorber_salt := String(absorber.element_id).hash()
			var selection_sample := FlowMath.stable_unit_sample(
				slot.slot_index,
				absorber_salt
			)
			if selection_sample >= clampf(absorber.absorption_fraction, 0.0, 1.0):
				continue
			var margin_fraction := clampf(
				absorber.stop_margin_fraction,
				0.0,
				0.49
			)
			var stop_sample := FlowMath.stable_unit_sample(
				slot.slot_index,
				absorber_salt,
				0.7548776662466927,
				0.5698402909980532
			)
			var left := absorber.center.x - absorber.size.x * 0.5
			slot.absorber_id = absorber.element_id
			slot.absorption_target_x = (
				left
				+ absorber.size.x
				* (margin_fraction + stop_sample * (1.0 - 2.0 * margin_fraction))
			)
			break

	if slot.absorber_id == &"":
		return
	var tracked_absorber := _find_absorber(slot.absorber_id)
	if tracked_absorber == null:
		slot.absorber_id = &""
		slot.absorption_target_x = NAN
		return

	var bottom := tracked_absorber.center.y - tracked_absorber.size.y * 0.5
	var top := tracked_absorber.center.y + tracked_absorber.size.y * 0.5
	var interior_margin := minf(
		tracked_absorber.size.x,
		tracked_absorber.size.y
	) * 0.005
	slot.position.y = clampf(
		slot.position.y,
		bottom + interior_margin,
		top - interior_margin
	)
	if slot.position.x >= slot.absorption_target_x:
		slot.position.x = slot.absorption_target_x
		slot.absorbed = true


func _point_inside_absorber(point: Vector2, absorber: FlowAbsorber) -> bool:
	var half_size := absorber.size * 0.5
	return (
		point.x >= absorber.center.x - half_size.x
		and point.x <= absorber.center.x + half_size.x
		and point.y >= absorber.center.y - half_size.y
		and point.y <= absorber.center.y + half_size.y
	)


func _finish_water_lifecycles() -> void:
	var elapsed_ms := _simulation_time_seconds * 1000.0
	var escape_margin := 0.5 * _world_scale()
	for slot in _slots:
		if not slot.active or elapsed_ms < slot.launch_time_ms:
			continue
		if slot.position.x >= _config.world_size.x:
			slot.retiring = true

		var hard_escape := (
			slot.position.x < _config.spawn_x - escape_margin
			or slot.position.y < -escape_margin
			or slot.position.y > _config.world_size.y + escape_margin
		)
		var completed := (
			(slot.retiring or slot.absorbed)
			and slot.trail.visible_count(_config.world_size) < 2
		)
		if not hard_escape and not completed:
			continue

		if slot.is_source and slot.slot_index < _source_target:
			_reset_source_slot(slot, elapsed_ms)
		else:
			_deactivate_slot(slot)


func _world_scale() -> float:
	return _config.world_size.y / maxf(_config.legacy_world_height, 0.001)


func _profile_stroke_to_canvas(profile_width: float) -> float:
	return profile_width * PROFILE_STROKE_TO_CANVAS_PIXELS


func _find_reservoir(element_id: StringName) -> FlowReservoir:
	for reservoir in _config.reservoirs:
		if reservoir.element_id == element_id:
			return reservoir
	return null


func _find_absorber(element_id: StringName) -> FlowAbsorber:
	for absorber in _config.absorbers:
		if absorber.element_id == element_id:
			return absorber
	return null


func _canvas_size() -> Vector2:
	var viewport := get_viewport()
	if viewport == null:
		return Vector2(1920.0, 1080.0)
	return viewport.get_visible_rect().size


func world_to_canvas(point: Vector2) -> Vector2:
	var canvas_size := _canvas_size()
	return Vector2(
		point.x / maxf(_config.world_size.x, 0.000001) * canvas_size.x,
		(_config.world_size.y - point.y)
			/ maxf(_config.world_size.y, 0.000001)
			* canvas_size.y
	)


func canvas_to_world(point: Vector2) -> Vector2:
	var canvas_size := _canvas_size()
	return Vector2(
		point.x / maxf(canvas_size.x, 0.000001) * _config.world_size.x,
		_config.world_size.y
			- point.y / maxf(canvas_size.y, 0.000001) * _config.world_size.y
	)


func _world_points_to_canvas(points: PackedVector2Array) -> PackedVector2Array:
	var result := PackedVector2Array()
	result.resize(points.size())
	for point_index in range(points.size()):
		result[point_index] = world_to_canvas(points[point_index])
	return result


func _refresh_all_trails() -> void:
	if _config == null:
		return
	var elapsed_ms := _simulation_time_seconds * 1000.0
	for slot_index in range(_slots.size()):
		var slot := _slots[slot_index]
		var line := _line_nodes[slot_index]
		var visible := (
			slot.active
			and elapsed_ms >= slot.launch_time_ms
			and slot.trail.count >= 2
		)
		line.visible = visible
		if visible:
			line.points = _world_points_to_canvas(slot.trail.as_packed_array())
		else:
			line.clear_points()


func _on_viewport_size_changed() -> void:
	_refresh_all_trails()
	_queue_all_redraw()


func _queue_all_redraw() -> void:
	queue_redraw()
	if is_instance_valid(_debug_overlay):
		_debug_overlay.queue_redraw()


func draw_debug_geometry_on(canvas: CanvasItem) -> void:
	if _config == null:
		return
	var obstacle_color := _config.debug_geometry_color
	var shore_color := Color.from_string("sandybrown", obstacle_color)
	var absorber_color := Color.from_string("yellowgreen", obstacle_color)
	var width := _profile_stroke_to_canvas(_config.debug_geometry_line_width)

	for obstacle in _config.circle_obstacles:
		_draw_world_circle(canvas, obstacle.center, obstacle.radius, obstacle_color, width)
	for obstacle in _config.rectangle_obstacles:
		_draw_world_polygon_outline(
			canvas,
			FlowMath.rectangle_vertices(
				obstacle.center,
				obstacle.size,
				obstacle.angle_degrees
			),
			obstacle_color,
			width
		)
	for obstacle in _config.polygon_obstacles:
		_draw_world_polygon_outline(canvas, obstacle.vertices, obstacle_color, width)
	for shoreline in _config.shorelines:
		_draw_world_polygon_outline(canvas, shoreline.vertices, shore_color, width)
	for absorber in _config.absorbers:
		var half_size := absorber.size * 0.5
		var vertices := PackedVector2Array([
			absorber.center + Vector2(-half_size.x, -half_size.y),
			absorber.center + Vector2(half_size.x, -half_size.y),
			absorber.center + Vector2(half_size.x, half_size.y),
			absorber.center + Vector2(-half_size.x, half_size.y),
		])
		_draw_world_polygon_outline(canvas, vertices, absorber_color, width)
	for reservoir in _config.reservoirs:
		_draw_reservoir_debug(canvas, reservoir, obstacle_color, width)


func _draw_world_circle(
	canvas: CanvasItem,
	center: Vector2,
	radius: float,
	color: Color,
	width: float
) -> void:
	var points := PackedVector2Array()
	var point_count := 72
	points.resize(point_count + 1)
	for point_index in range(point_count + 1):
		var angle := TAU * float(point_index) / float(point_count)
		points[point_index] = world_to_canvas(
			center + Vector2(cos(angle), sin(angle)) * radius
		)
	canvas.draw_polyline(points, color, width, true)


func _draw_world_polygon_outline(
	canvas: CanvasItem,
	vertices: PackedVector2Array,
	color: Color,
	width: float
) -> void:
	if vertices.size() < 2:
		return
	var closed := PackedVector2Array()
	closed.resize(vertices.size() + 1)
	for vertex_index in range(vertices.size()):
		closed[vertex_index] = world_to_canvas(vertices[vertex_index])
	closed[vertices.size()] = world_to_canvas(vertices[0])
	canvas.draw_polyline(closed, color, width, true)


func _draw_reservoir_debug(
	canvas: CanvasItem,
	reservoir: FlowReservoir,
	color: Color,
	width: float
) -> void:
	var capture_color := color
	capture_color.a *= 0.35
	_draw_world_circle(canvas, reservoir.center, reservoir.radius, capture_color, width)

	var gate_angle := 0.0
	if reservoir.gate_open and reservoir.radius > 0.0:
		gate_angle = asin(clampf(
			reservoir.outlet_width * 0.5 / reservoir.radius,
			0.0,
			1.0
		))
	if not reservoir.gate_open or gate_angle <= 0.000001:
		_draw_world_arc(
			canvas,
			reservoir.center,
			reservoir.radius,
			-PI * 0.5,
			PI * 0.5,
			color,
			width
		)
	else:
		_draw_world_arc(
			canvas,
			reservoir.center,
			reservoir.radius,
			-PI * 0.5,
			-gate_angle,
			color,
			width
		)
		_draw_world_arc(
			canvas,
			reservoir.center,
			reservoir.radius,
			gate_angle,
			PI * 0.5,
			color,
			width
		)


func _draw_world_arc(
	canvas: CanvasItem,
	center: Vector2,
	radius: float,
	start_angle: float,
	end_angle: float,
	color: Color,
	width: float
) -> void:
	var point_count := maxi(4, ceili(absf(end_angle - start_angle) * 24.0))
	var points := PackedVector2Array()
	points.resize(point_count + 1)
	for point_index in range(point_count + 1):
		var fraction := float(point_index) / float(point_count)
		var angle := lerpf(start_angle, end_angle, fraction)
		points[point_index] = world_to_canvas(
			center + Vector2(cos(angle), sin(angle)) * radius
		)
	canvas.draw_polyline(points, color, width, true)


func _emit_periodic_stats() -> void:
	var current_second := floori(_simulation_time_seconds)
	if current_second == _last_stats_second:
		return
	_last_stats_second = current_second
	stats_updated.emit(screen_id, get_runtime_stats())


func get_runtime_stats() -> Dictionary:
	var active_sources := 0
	var retained_count := 0
	var absorbed_count := 0
	for slot in _slots:
		if not slot.active:
			continue
		if slot.is_source:
			active_sources += 1
		else:
			retained_count += 1
		if slot.absorbed:
			absorbed_count += 1
	return {
		"screen_id": String(screen_id),
		"simulation_time": _simulation_time_seconds,
		"flow_rate": _config.flow_rate,
		"source_target": _source_target,
		"active_sources": active_sources,
		"retained_water": retained_count,
		"absorbing_water": absorbed_count,
		"revision": _last_revision,
		"running": _running,
	}


func _capture_screenshot() -> void:
	call_deferred("_save_screenshot_after_draw")


func _save_screenshot_after_draw() -> void:
	await RenderingServer.frame_post_draw
	var directory := "user://ink_flow_screenshots"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(directory))
	var timestamp := Time.get_datetime_string_from_system().replace(":", "-")
	var path := "%s/%s_%s.png" % [directory, String(screen_id), timestamp]
	var image := get_viewport().get_texture().get_image()
	var error := image.save_png(path)
	if error == OK:
		action_completed.emit(
			screen_id,
			&"capture_screenshot",
			{"path": ProjectSettings.globalize_path(path)}
		)
	else:
		_emit_control_error(
			"Could not save screenshot.",
			{"path": path, "error": error}
		)


# ---------------------------------------------------------------------------
# Runtime control API
# ---------------------------------------------------------------------------

func accepts_control_target(target: String) -> bool:
	return (
		target == "*"
		or target == String(screen_id)
		or target == name
		or is_in_group(target)
	)


func queue_control_message(message: Dictionary) -> void:
	_pending_messages.append(message.duplicate(true))


func apply_patch(changes: Dictionary, revision: int = -1) -> void:
	var message := {
		"protocol": PROTOCOL_NAME,
		"changes": changes.duplicate(true),
	}
	if revision >= 0:
		message["revision"] = revision
	queue_control_message(message)


func set_parameter(path: StringName, value: Variant) -> void:
	queue_control_message({
		"protocol": PROTOCOL_NAME,
		"changes": {String(path): value},
	})


func set_flow_rate(rate: float) -> void:
	set_parameter(&"flow_rate", clampf(rate, 0.0, 1.0))


func set_gate_open(reservoir_id: StringName, gate_open: bool) -> void:
	set_parameter(
		StringName("reservoir.%s.gate_open" % String(reservoir_id)),
		gate_open
	)


func set_gate_width(reservoir_id: StringName, outlet_width: float) -> void:
	set_parameter(
		StringName("reservoir.%s.outlet_width" % String(reservoir_id)),
		outlet_width
	)


func toggle_gate(reservoir_id: StringName) -> void:
	var reservoir := _find_reservoir(reservoir_id)
	if reservoir == null:
		_emit_control_error(
			"Cannot toggle an unknown reservoir.",
			{"reservoir_id": String(reservoir_id)}
		)
		return
	set_gate_open(reservoir_id, not reservoir.gate_open)


func upsert_geometry(
	kind: StringName,
	element_id: StringName,
	definition: Dictionary
) -> void:
	queue_control_message({
		"protocol": PROTOCOL_NAME,
		"geometry_ops": [{
			"op": "upsert",
			"kind": String(kind),
			"id": String(element_id),
			"value": definition.duplicate(true),
		}],
	})


func remove_geometry(kind: StringName, element_id: StringName) -> void:
	queue_control_message({
		"protocol": PROTOCOL_NAME,
		"geometry_ops": [{
			"op": "remove",
			"kind": String(kind),
			"id": String(element_id),
		}],
	})


func replace_geometry_set(kind: StringName, definitions: Array) -> void:
	queue_control_message({
		"protocol": PROTOCOL_NAME,
		"geometry_ops": [{
			"op": "replace",
			"kind": String(kind),
			"values": definitions.duplicate(true),
		}],
	})


func queue_action(action: StringName, arguments: Dictionary = {}) -> void:
	queue_control_message({
		"protocol": PROTOCOL_NAME,
		"actions": [{
			"name": String(action),
			"arguments": arguments.duplicate(true),
		}],
	})


func get_state_snapshot() -> Dictionary:
	return {
		"protocol": PROTOCOL_NAME,
		"screen_id": String(screen_id),
		"revision": _last_revision,
		"parameters": _parameter_snapshot(),
		"geometry": _geometry_snapshot(),
		"stats": get_runtime_stats(),
		"metadata": _controller_metadata.duplicate(true),
	}


func describe_parameters() -> Dictionary:
	var result: Dictionary = {}
	var schema := FlowProfile.parameter_schema()
	for parameter_name in schema:
		var description: Dictionary = schema[parameter_name].duplicate(true)
		description["value"] = _serialize_variant(_config.get(parameter_name))
		result[parameter_name] = description
	return result


func _apply_pending_messages() -> void:
	if _pending_messages.is_empty():
		return
	var messages := _pending_messages
	_pending_messages = []
	for message in messages:
		_apply_control_message(message)


func _apply_control_message(message: Dictionary) -> void:
	var revision := int(message.get("revision", -1))
	var enforce_revision := not bool(message.get("legacy", false))
	if enforce_revision and revision >= 0 and revision <= _last_revision:
		return

	var candidate := _config.duplicate_for_runtime()
	var change_paths: Array[StringName] = []
	var geometry_events: Array[Dictionary] = []
	var errors := PackedStringArray()
	var has_config_changes := false

	var changes_variant: Variant = message.get(
		"changes",
		message.get("parameters", {})
	)
	if changes_variant is Dictionary:
		for path_variant in changes_variant:
			var path := String(path_variant)
			var error := _apply_change(
				candidate,
				path,
				changes_variant[path_variant]
			)
			if error.is_empty():
				has_config_changes = true
				change_paths.append(StringName(path))
			else:
				errors.append(error)

	if message.has("command"):
		var command_error := _apply_command_to_candidate(
			candidate,
			message,
			change_paths
		)
		if command_error.is_empty():
			has_config_changes = has_config_changes or not change_paths.is_empty()
		else:
			errors.append(command_error)

	var operations: Variant = message.get("geometry_ops", [])
	if operations is Array:
		for operation_variant in operations:
			if not operation_variant is Dictionary:
				errors.append("Every geometry operation must be a dictionary.")
				continue
			var geometry_error := _apply_geometry_operation(
				candidate,
				operation_variant,
				geometry_events
			)
			if geometry_error.is_empty():
				has_config_changes = true
			else:
				errors.append(geometry_error)

	if errors.is_empty() and has_config_changes:
		errors = _validate_config(candidate)
	if not errors.is_empty():
		_emit_control_error(
			"Rejected an atomic flow configuration update.",
			{"revision": revision, "errors": Array(errors)}
		)
		return

	if has_config_changes:
		_commit_config(candidate)
		for path in change_paths:
			parameter_changed.emit(
				screen_id,
				path,
				_serialize_variant(_value_for_path(_config, String(path)))
			)
		for geometry_event in geometry_events:
			geometry_changed.emit(
				screen_id,
				StringName(geometry_event["kind"]),
				StringName(geometry_event.get("id", ""))
			)

	if message.get("metadata", null) is Dictionary:
		_controller_metadata = message["metadata"].duplicate(true)

	var actions: Variant = message.get("actions", [])
	if actions is Array:
		for action_variant in actions:
			_apply_action(action_variant)

	if enforce_revision and revision >= 0:
		_last_revision = revision
	if has_config_changes:
		config_applied.emit(screen_id, revision)


func _apply_command_to_candidate(
	candidate: FlowProfile,
	message: Dictionary,
	change_paths: Array[StringName]
) -> String:
	var command := String(message.get("command", ""))
	match command:
		"", "apply_patch":
			return ""
		"set_parameter":
			var path := String(message.get("path", ""))
			if path.is_empty() or not message.has("value"):
				return "set_parameter requires path and value."
			var error := _apply_change(candidate, path, message["value"])
			if error.is_empty():
				change_paths.append(StringName(path))
			return error
		"set_gate":
			var reservoir_id := String(message.get("reservoir_id", ""))
			if reservoir_id.is_empty():
				return "set_gate requires reservoir_id."
			for field in ["gate_open", "outlet_width"]:
				if message.has(field):
					var gate_path := "reservoir.%s.%s" % [reservoir_id, field]
					var gate_error := _apply_change(
						candidate,
						gate_path,
						message[field]
					)
					if not gate_error.is_empty():
						return gate_error
					change_paths.append(StringName(gate_path))
			return ""
		_:
			return "Unknown flow command: %s" % command


func _apply_change(
	candidate: FlowProfile,
	path: String,
	value: Variant
) -> String:
	var canonical_path := _canonical_parameter_path(path)
	var parts := canonical_path.split(".")
	if parts.size() == 3 and parts[0] in [
		"circle",
		"rectangle",
		"polygon",
		"shoreline",
		"absorber",
		"reservoir",
	]:
		var element := _find_geometry(candidate, parts[0], StringName(parts[1]))
		if element == null:
			return "Unknown %s geometry id: %s" % [parts[0], parts[1]]
		if parts[2] == "element_id":
			return "Geometry IDs are stable; remove and upsert to replace an ID."
		if not _object_has_property(element, StringName(parts[2])):
			return "%s has no property named %s." % [parts[1], parts[2]]
		var current: Variant = element.get(parts[2])
		var coerced := _coerce_value(current, value)
		if not coerced["ok"]:
			return coerced["error"]
		if parts[0] == "reservoir" and parts[2] == "outlet_width":
			coerced["value"] = clampf(
				float(coerced["value"]),
				0.0,
				float(element.get("radius")) * 2.0
			)
		if not bool(element.call(
			"apply_dictionary",
			{parts[2]: coerced["value"]}
		)):
			return "Invalid value for %s.%s." % [parts[1], parts[2]]
		return ""

	var property_name := StringName(canonical_path)
	if property_name in [
		&"circle_obstacles",
		&"rectangle_obstacles",
		&"polygon_obstacles",
		&"shorelines",
		&"absorbers",
		&"reservoirs",
	]:
		return "Geometry collections must be changed through geometry_ops."
	if not _object_has_property(candidate, property_name):
		return "Unknown flow parameter: %s" % path
	var current: Variant = candidate.get(property_name)
	var coerced := _coerce_value(current, value)
	if not coerced["ok"]:
		return coerced["error"]
	candidate.set(property_name, coerced["value"])
	return ""


func _canonical_parameter_path(path: String) -> String:
	var aliases := {
		"flow.rate": "flow_rate",
		"flow.max_speed": "max_flow_speed",
		"flow.variation": "flow_variation",
		"noise.strength": "noise_strength",
		"noise.scale": "noise_scale",
		"noise.speed": "noise_speed",
		"separation.radius": "separation_radius",
		"separation.strength": "separation_strength",
		"debug.visible": "debug_geometry_visible",
	}
	return aliases.get(path, path)


func _coerce_value(current: Variant, value: Variant) -> Dictionary:
	match typeof(current):
		TYPE_BOOL:
			if typeof(value) == TYPE_BOOL:
				return {"ok": true, "value": value}
		TYPE_INT:
			if (
				(typeof(value) == TYPE_INT or typeof(value) == TYPE_FLOAT)
				and is_finite(float(value))
				and is_equal_approx(float(value), roundf(float(value)))
			):
				return {"ok": true, "value": int(value)}
		TYPE_FLOAT:
			if (
				(typeof(value) == TYPE_INT or typeof(value) == TYPE_FLOAT)
				and is_finite(float(value))
			):
				return {"ok": true, "value": float(value)}
		TYPE_STRING:
			return {"ok": true, "value": String(value)}
		TYPE_STRING_NAME:
			return {"ok": true, "value": StringName(String(value))}
		TYPE_VECTOR2:
			var vector_result: Variant = _variant_to_vector2(value)
			if vector_result != null:
				return {"ok": true, "value": vector_result}
		TYPE_COLOR:
			var color_result: Variant = _variant_to_color(value)
			if color_result != null:
				return {"ok": true, "value": color_result}
		TYPE_ARRAY:
			if value is Array:
				return {"ok": true, "value": value.duplicate(true)}
		TYPE_PACKED_COLOR_ARRAY:
			if value is Array or value is PackedColorArray:
				var colors := PackedColorArray()
				for color_value in value:
					var parsed_color: Variant = _variant_to_color(color_value)
					if parsed_color == null:
						return {
							"ok": false,
							"error": "Every palette entry must be a color.",
						}
					colors.append(parsed_color)
				return {"ok": true, "value": colors}
		TYPE_PACKED_VECTOR2_ARRAY:
			if value is Array or value is PackedVector2Array:
				var points := PackedVector2Array()
				for point_value in value:
					var parsed_point: Variant = _variant_to_vector2(point_value)
					if parsed_point == null:
						return {
							"ok": false,
							"error": "Every vertex must contain two finite numbers.",
						}
					points.append(parsed_point)
				return {"ok": true, "value": points}
		TYPE_PACKED_INT32_ARRAY:
			if value is Array or value is PackedInt32Array:
				var integers := PackedInt32Array()
				for integer_value in value:
					if (
						typeof(integer_value) != TYPE_INT
						and typeof(integer_value) != TYPE_FLOAT
					):
						return {
							"ok": false,
							"error": "Every edge index must be an integer.",
						}
					var numeric := float(integer_value)
					if not is_finite(numeric) or not is_equal_approx(numeric, roundf(numeric)):
						return {
							"ok": false,
							"error": "Every edge index must be an integer.",
						}
					integers.append(int(numeric))
				return {"ok": true, "value": integers}
		_:
			if typeof(current) == typeof(value):
				return {"ok": true, "value": value}
	return {
		"ok": false,
		"error": "Could not convert runtime value to the target property type.",
	}


func _variant_to_vector2(value: Variant) -> Variant:
	if value is Vector2:
		return value if is_finite(value.x) and is_finite(value.y) else null
	if (
		value is Array
		and value.size() == 2
		and _is_finite_number(value[0])
		and _is_finite_number(value[1])
	):
		return Vector2(float(value[0]), float(value[1]))
	if (
		value is Dictionary
		and value.has("x")
		and value.has("y")
		and _is_finite_number(value["x"])
		and _is_finite_number(value["y"])
	):
		return Vector2(float(value["x"]), float(value["y"]))
	return null


func _variant_to_color(value: Variant) -> Variant:
	if value is Color:
		return value
	if value is String:
		var invalid := Color(2.0, 2.0, 2.0, 2.0)
		var parsed := Color.from_string(value, invalid)
		return null if parsed == invalid else parsed
	if (
		value is Array
		and (value.size() == 3 or value.size() == 4)
		and _is_finite_number(value[0])
		and _is_finite_number(value[1])
		and _is_finite_number(value[2])
		and (value.size() == 3 or _is_finite_number(value[3]))
	):
		return Color(
			float(value[0]),
			float(value[1]),
			float(value[2]),
			float(value[3]) if value.size() > 3 else 1.0
		)
	return null


func _is_finite_number(value: Variant) -> bool:
	return (
		typeof(value) == TYPE_INT or typeof(value) == TYPE_FLOAT
	) and is_finite(float(value))


func _apply_geometry_operation(
	candidate: FlowProfile,
	operation: Dictionary,
	events: Array[Dictionary]
) -> String:
	var op := String(operation.get("op", "upsert")).to_lower()
	var kind := _normalize_geometry_kind(String(operation.get("kind", "")))
	if kind.is_empty():
		return "Unknown geometry kind: %s" % operation.get("kind", "")

	if op == "replace":
		var values: Variant = operation.get("values", [])
		if not values is Array:
			return "A replace geometry operation requires an array of values."
		var replacement: Array[Resource] = []
		for definition_variant in values:
			if not definition_variant is Dictionary:
				return "Every replacement geometry value must be a dictionary."
			var definition: Dictionary = definition_variant
			var element_id := StringName(definition.get(
				"element_id",
				definition.get("id", "")
			))
			if element_id == &"":
				return "Every replacement geometry value needs a stable id."
			var resource := _new_geometry_resource(kind)
			if resource == null:
				return "Could not create geometry kind %s." % kind
			resource.set("element_id", element_id)
			var resource_patch: Dictionary = (
				definition as Dictionary
			).duplicate(true)
			resource_patch.erase("id")
			resource_patch["element_id"] = String(element_id)
			if not bool(resource.call("apply_dictionary", resource_patch)):
				return "Invalid %s geometry definition for %s." % [kind, element_id]
			replacement.append(resource)
		_replace_geometry_array(candidate, kind, replacement)
		events.append({"kind": kind, "id": ""})
		return ""

	var element_id := StringName(operation.get(
		"id",
		operation.get("element_id", "")
	))
	if element_id == &"":
		return "Geometry operations require a stable id."

	match op:
		"upsert", "add", "update":
			var definition: Variant = operation.get("value", {})
			if not definition is Dictionary:
				return "An upsert geometry operation requires a dictionary value."
			var resource := _find_geometry(candidate, kind, element_id)
			if resource == null:
				resource = _new_geometry_resource(kind)
				if resource == null:
					return "Could not create geometry kind %s." % kind
				resource.set("element_id", element_id)
				_append_geometry(candidate, kind, resource)
			var resource_patch: Dictionary = (
				definition as Dictionary
			).duplicate(true)
			resource_patch.erase("id")
			resource_patch["element_id"] = String(element_id)
			if not bool(resource.call("apply_dictionary", resource_patch)):
				return "Invalid %s geometry definition for %s." % [kind, element_id]
			resource.set("element_id", element_id)
			events.append({"kind": kind, "id": String(element_id)})
			return ""
		"remove", "delete":
			if not _remove_geometry(candidate, kind, element_id):
				return "Cannot remove unknown %s id %s." % [kind, element_id]
			events.append({"kind": kind, "id": String(element_id)})
			return ""
		_:
			return "Unknown geometry operation: %s" % op


func _normalize_geometry_kind(kind: String) -> String:
	match kind.to_lower().replace("_obstacle", ""):
		"circle", "circles":
			return "circle"
		"rectangle", "rectangles":
			return "rectangle"
		"polygon", "polygons":
			return "polygon"
		"shoreline", "shorelines", "shore":
			return "shoreline"
		"absorber", "absorbers":
			return "absorber"
		"reservoir", "reservoirs":
			return "reservoir"
	return ""


func _new_geometry_resource(kind: String) -> Resource:
	match kind:
		"circle":
			return FlowCircleObstacle.new()
		"rectangle":
			return FlowRectangleObstacle.new()
		"polygon":
			return FlowPolygonObstacle.new()
		"shoreline":
			return FlowShoreline.new()
		"absorber":
			return FlowAbsorber.new()
		"reservoir":
			return FlowReservoir.new()
	return null


func _geometry_array(config: FlowProfile, kind: String) -> Array:
	match kind:
		"circle":
			return config.circle_obstacles
		"rectangle":
			return config.rectangle_obstacles
		"polygon":
			return config.polygon_obstacles
		"shoreline":
			return config.shorelines
		"absorber":
			return config.absorbers
		"reservoir":
			return config.reservoirs
	return []


func _append_geometry(config: FlowProfile, kind: String, resource: Resource) -> void:
	match kind:
		"circle":
			config.circle_obstacles.append(resource as FlowCircleObstacle)
		"rectangle":
			config.rectangle_obstacles.append(resource as FlowRectangleObstacle)
		"polygon":
			config.polygon_obstacles.append(resource as FlowPolygonObstacle)
		"shoreline":
			config.shorelines.append(resource as FlowShoreline)
		"absorber":
			config.absorbers.append(resource as FlowAbsorber)
		"reservoir":
			config.reservoirs.append(resource as FlowReservoir)


func _replace_geometry_array(
	config: FlowProfile,
	kind: String,
	resources: Array[Resource]
) -> void:
	match kind:
		"circle":
			var circle_values: Array[FlowCircleObstacle] = []
			for resource in resources:
				circle_values.append(resource as FlowCircleObstacle)
			config.circle_obstacles = circle_values
		"rectangle":
			var rectangle_values: Array[FlowRectangleObstacle] = []
			for resource in resources:
				rectangle_values.append(resource as FlowRectangleObstacle)
			config.rectangle_obstacles = rectangle_values
		"polygon":
			var polygon_values: Array[FlowPolygonObstacle] = []
			for resource in resources:
				polygon_values.append(resource as FlowPolygonObstacle)
			config.polygon_obstacles = polygon_values
		"shoreline":
			var shoreline_values: Array[FlowShoreline] = []
			for resource in resources:
				shoreline_values.append(resource as FlowShoreline)
			config.shorelines = shoreline_values
		"absorber":
			var absorber_values: Array[FlowAbsorber] = []
			for resource in resources:
				absorber_values.append(resource as FlowAbsorber)
			config.absorbers = absorber_values
		"reservoir":
			var reservoir_values: Array[FlowReservoir] = []
			for resource in resources:
				reservoir_values.append(resource as FlowReservoir)
			config.reservoirs = reservoir_values


func _find_geometry(
	config: FlowProfile,
	kind: String,
	element_id: StringName
) -> Resource:
	for resource in _geometry_array(config, kind):
		if resource != null and resource.element_id == element_id:
			return resource
	return null


func _remove_geometry(
	config: FlowProfile,
	kind: String,
	element_id: StringName
) -> bool:
	var resources := _geometry_array(config, kind)
	for resource_index in range(resources.size()):
		if resources[resource_index].element_id == element_id:
			resources.remove_at(resource_index)
			return true
	return false


func _validate_config(config: FlowProfile) -> PackedStringArray:
	var errors := PackedStringArray()
	var profile_error := config.validate()
	if not profile_error.is_empty():
		errors.append(profile_error)
	if config.world_size.x <= 0.0 or config.world_size.y <= 0.0:
		errors.append("world_size must be positive.")
	if config.legacy_world_height <= 0.0:
		errors.append("legacy_world_height must be positive.")
	if config.target_fps < 1:
		errors.append("target_fps must be at least 1.")
	if config.simulation_substeps < 1:
		errors.append("simulation_substeps must be at least 1.")
	if config.max_particles < 1:
		errors.append("max_particles must be at least 1.")
	if config.retention_capacity < 0:
		errors.append("retention_capacity cannot be negative.")
	if config.trail_length < 2:
		errors.append("trail_length must be at least 2.")
	if config.flow_rate < 0.0 or config.flow_rate > 1.0:
		errors.append("flow_rate must be between 0 and 1.")
	if config.base_flow.x <= 0.0:
		errors.append("The current model requires positive-X base_flow.")
	if config.line_colors.is_empty():
		errors.append("line_colors must contain at least one color.")
	if config.release_threshold_min <= 0.0:
		errors.append("release_threshold_min must be positive.")
	if config.release_threshold_max < config.release_threshold_min:
		errors.append("release_threshold_max must not be below the minimum.")

	_validate_geometry_ids(config, errors)
	for obstacle in config.circle_obstacles:
		if obstacle.radius <= 0.0:
			errors.append("Circle %s must have a positive radius." % obstacle.element_id)
	for obstacle in config.rectangle_obstacles:
		if obstacle.size.x <= 0.0 or obstacle.size.y <= 0.0:
			errors.append("Rectangle %s must have a positive size." % obstacle.element_id)
	for obstacle in config.polygon_obstacles:
		if not FlowMath.polygon_is_simple(obstacle.vertices):
			errors.append("Polygon %s is degenerate or self-intersecting." % obstacle.element_id)
	for shoreline in config.shorelines:
		if not FlowMath.polygon_is_simple(shoreline.vertices):
			errors.append("Shoreline %s is degenerate or self-intersecting." % shoreline.element_id)
		var chain_error := FlowMath.shoreline_chain_validation_error(
			shoreline.vertices,
			shoreline.water_edge_indices
		)
		if not chain_error.is_empty():
			errors.append("Shoreline %s: %s" % [shoreline.element_id, chain_error])
		if String(shoreline.side).to_lower() not in ["bottom", "top"]:
			errors.append("Shoreline %s side must be bottom or top." % shoreline.element_id)
	for absorber in config.absorbers:
		if absorber.size.x <= 0.0 or absorber.size.y <= 0.0:
			errors.append("Absorber %s must have a positive size." % absorber.element_id)
		if absorber.absorption_fraction < 0.0 or absorber.absorption_fraction > 1.0:
			errors.append("Absorber %s fraction must be between 0 and 1." % absorber.element_id)
	for reservoir in config.reservoirs:
		if reservoir.radius <= 0.0:
			errors.append("Reservoir %s must have a positive radius." % reservoir.element_id)
		if reservoir.outlet_width < 0.0 or reservoir.outlet_width > reservoir.radius * 2.0:
			errors.append("Reservoir %s outlet width must fit its diameter." % reservoir.element_id)

	if errors.is_empty():
		var channel := _spawn_channel(config)
		if channel.x >= channel.y:
			errors.append("Shoreline polygons leave no open inlet channel.")
	return errors


func _validate_geometry_ids(
	config: FlowProfile,
	errors: PackedStringArray
) -> void:
	for kind in [
		"circle",
		"rectangle",
		"polygon",
		"shoreline",
		"absorber",
		"reservoir",
	]:
		var seen: Dictionary = {}
		for resource in _geometry_array(config, kind):
			var element_id := String(resource.element_id)
			if element_id.is_empty():
				errors.append("Every %s needs a stable nonempty id." % kind)
			elif seen.has(element_id):
				errors.append("Duplicate %s id: %s" % [kind, element_id])
			else:
				seen[element_id] = true


func _commit_config(candidate: FlowProfile) -> void:
	var previous := _config
	var previous_flow_rate := previous.flow_rate
	var structural_change := _has_structural_change(previous, candidate)
	var previous_gates := _gate_state_dictionary(previous)
	_config = candidate

	if structural_change:
		_seed_rng()
		_build_water_pool()
	else:
		_apply_flow_rate_transition(previous_flow_rate, _config.flow_rate)
		if not is_equal_approx(previous.flow_variation, _config.flow_variation):
			_refresh_flow_offsets()
		if not is_equal_approx(
			previous.shore_exit_angle_jitter_degrees,
			_config.shore_exit_angle_jitter_degrees
		):
			_refresh_shore_offsets()
		_refresh_slot_styles()
		_reconcile_geometry_references(previous)
		_refresh_all_trails()

	for reservoir in _config.reservoirs:
		var old_state: Dictionary = previous_gates.get(String(reservoir.element_id), {})
		if (
			old_state.is_empty()
			or bool(old_state.get("gate_open", false)) != reservoir.gate_open
			or not is_equal_approx(
				float(old_state.get("outlet_width", -1.0)),
				reservoir.outlet_width
			)
		):
			gate_changed.emit(
				screen_id,
				reservoir.element_id,
				reservoir.gate_open,
				reservoir.outlet_width
			)
	_queue_all_redraw()


func _has_structural_change(previous: FlowProfile, candidate: FlowProfile) -> bool:
	for property_name in STRUCTURAL_PARAMETERS:
		if previous.get(property_name) != candidate.get(property_name):
			return true
	return false


func _apply_flow_rate_transition(old_rate: float, new_rate: float) -> void:
	var old_target := _source_target
	var new_target := _particle_count_for_rate(new_rate)
	var elapsed_ms := _simulation_time_seconds * 1000.0
	_source_target = new_target

	if new_target > old_target:
		var launch_offset := 0
		for source_index in range(old_target, new_target):
			var slot := _slots[source_index]
			if slot.active:
				slot.retiring = false
				slot.retirement_flow_rate = NAN
			else:
				_reset_source_slot(
					slot,
					elapsed_ms + float(launch_offset) * _config.particle_launch_delay_ms
				)
				launch_offset += 1
	elif new_target < old_target:
		for source_index in range(new_target, old_target):
			var slot := _slots[source_index]
			if slot.active and slot.launch_time_ms <= elapsed_ms:
				slot.retiring = true
				slot.retirement_flow_rate = old_rate
			else:
				_deactivate_slot(slot)


func _refresh_flow_offsets() -> void:
	for slot in _slots:
		slot.flow_offset = (slot.flow_sample * 2.0 - 1.0) * _config.flow_variation


func _refresh_shore_offsets() -> void:
	for slot in _slots:
		slot.shore_angle_offset = deg_to_rad(
			slot.shore_sample * _config.shore_exit_angle_jitter_degrees
		)


func _reconcile_geometry_references(previous: FlowProfile) -> void:
	for slot in _slots:
		if not slot.active:
			continue
		if not slot.is_source and slot.retained_reservoir_id != &"":
			var new_reservoir := _find_reservoir(slot.retained_reservoir_id)
			if new_reservoir == null:
				_deactivate_slot(slot)
				continue
			var old_reservoir := _find_geometry(
				previous,
				"reservoir",
				slot.retained_reservoir_id
			) as FlowReservoir
			if old_reservoir != null:
				_remap_retained_reservoir_slot(
					slot,
					old_reservoir,
					new_reservoir
				)

		if slot.absorber_id == &"":
			continue
		var new_absorber := _find_absorber(slot.absorber_id)
		if new_absorber == null:
			slot.absorber_id = &""
			slot.absorption_target_x = NAN
			slot.absorbed = false
			continue
		var old_absorber := _find_geometry(
			previous,
			"absorber",
			slot.absorber_id
		) as FlowAbsorber
		if old_absorber != null:
			_remap_tracked_absorber_slot(slot, old_absorber, new_absorber)


func _remap_retained_reservoir_slot(
	slot: WaterSlot,
	old_reservoir: FlowReservoir,
	new_reservoir: FlowReservoir
) -> void:
	if (
		old_reservoir.center.is_equal_approx(new_reservoir.center)
		and is_equal_approx(old_reservoir.radius, new_reservoir.radius)
	):
		return
	if (
		old_reservoir.radius <= 0.0
		or slot.position.distance_to(old_reservoir.center)
			> old_reservoir.radius + FlowMath.BOUNDARY_EPSILON
	):
		# A retained slot that has already left its former gate keeps moving
		# downstream; editing the lake must not teleport released water.
		return

	var radius_scale := new_reservoir.radius / old_reservoir.radius
	slot.position = (
		new_reservoir.center
		+ (slot.position - old_reservoir.center) * radius_scale
	)
	for logical_index in range(slot.trail.count):
		var point := slot.trail.point_at(logical_index)
		if (
			point.distance_to(old_reservoir.center)
			> old_reservoir.radius + FlowMath.BOUNDARY_EPSILON
		):
			continue
		slot.trail.set_point_at(
			logical_index,
			new_reservoir.center
				+ (point - old_reservoir.center) * radius_scale
		)


func _remap_tracked_absorber_slot(
	slot: WaterSlot,
	old_absorber: FlowAbsorber,
	new_absorber: FlowAbsorber
) -> void:
	if (
		old_absorber.center.is_equal_approx(new_absorber.center)
		and old_absorber.size.is_equal_approx(new_absorber.size)
	):
		return
	if (
		old_absorber.size.x <= 0.0
		or old_absorber.size.y <= 0.0
		or new_absorber.size.x <= 0.0
		or new_absorber.size.y <= 0.0
	):
		return

	var old_left := old_absorber.center.x - old_absorber.size.x * 0.5
	var new_left := new_absorber.center.x - new_absorber.size.x * 0.5
	var target_fraction := clampf(
		(slot.absorption_target_x - old_left) / old_absorber.size.x,
		0.0,
		1.0
	)
	slot.absorption_target_x = new_left + target_fraction * new_absorber.size.x
	slot.position = _remap_absorber_point(
		slot.position,
		old_absorber,
		new_absorber
	)
	for logical_index in range(slot.trail.count):
		var point := slot.trail.point_at(logical_index)
		if not _point_inside_absorber(point, old_absorber):
			continue
		slot.trail.set_point_at(
			logical_index,
			_remap_absorber_point(point, old_absorber, new_absorber)
		)


func _remap_absorber_point(
	point: Vector2,
	old_absorber: FlowAbsorber,
	new_absorber: FlowAbsorber
) -> Vector2:
	var normalized_local := Vector2(
		(point.x - old_absorber.center.x) / old_absorber.size.x,
		(point.y - old_absorber.center.y) / old_absorber.size.y
	)
	return new_absorber.center + Vector2(
		normalized_local.x * new_absorber.size.x,
		normalized_local.y * new_absorber.size.y
	)


func _gate_state_dictionary(config: FlowProfile) -> Dictionary:
	var result: Dictionary = {}
	for reservoir in config.reservoirs:
		result[String(reservoir.element_id)] = {
			"gate_open": reservoir.gate_open,
			"outlet_width": reservoir.outlet_width,
		}
	return result


func _apply_action(action_variant: Variant) -> void:
	var action_name := ""
	var arguments: Dictionary = {}
	if action_variant is String:
		action_name = action_variant
	elif action_variant is Dictionary:
		action_name = String(action_variant.get("name", ""))
		if action_variant.get("arguments", null) is Dictionary:
			arguments = action_variant["arguments"]
	else:
		_emit_control_error("Invalid action value.", {"action": action_variant})
		return

	match action_name:
		"toggle_debug_geometry":
			_config.debug_geometry_visible = true
			_queue_all_redraw()
			action_completed.emit(
				screen_id,
				StringName(action_name),
				{"visible": _config.debug_geometry_visible}
			)
		"reset":
			_seed_rng()
			_build_water_pool()
			action_completed.emit(screen_id, StringName(action_name), {})
		"pause":
			_running = false
			action_completed.emit(screen_id, StringName(action_name), {})
		"resume":
			_running = true
			action_completed.emit(screen_id, StringName(action_name), {})
		"capture_screenshot":
			_capture_screenshot()
		"release_salmon", "release_leaves":
			_emit_control_error(
				"%s belongs to the next overlay-port milestone." % action_name,
				{"action": action_name, "arguments": arguments}
			)
		_:
			_emit_control_error(
				"Unknown flow action: %s" % action_name,
				{"action": action_name}
			)


func _parameter_snapshot() -> Dictionary:
	var result: Dictionary = {}
	for parameter_name in describe_parameters():
		result[parameter_name] = _serialize_variant(_config.get(parameter_name))
	return result


func _geometry_snapshot() -> Dictionary:
	var result: Dictionary = {}
	for kind in [
		"circle",
		"rectangle",
		"polygon",
		"shoreline",
		"absorber",
		"reservoir",
	]:
		var values: Array = []
		for resource in _geometry_array(_config, kind):
			values.append(resource.to_dictionary())
		result[kind] = values
	return result


func _serialize_variant(value: Variant) -> Variant:
	match typeof(value):
		TYPE_VECTOR2:
			return [value.x, value.y]
		TYPE_COLOR:
			return value.to_html(true)
		TYPE_STRING_NAME:
			return String(value)
		TYPE_ARRAY:
			var array_result: Array = []
			for item in value:
				array_result.append(_serialize_variant(item))
			return array_result
		TYPE_PACKED_COLOR_ARRAY:
			var color_result: Array = []
			for color in value:
				color_result.append(color.to_html(true))
			return color_result
		TYPE_PACKED_VECTOR2_ARRAY:
			var point_result: Array = []
			for point in value:
				point_result.append([point.x, point.y])
			return point_result
		TYPE_PACKED_INT32_ARRAY, TYPE_PACKED_INT64_ARRAY:
			var integer_result: Array = []
			for integer in value:
				integer_result.append(int(integer))
			return integer_result
		TYPE_DICTIONARY:
			var dictionary_result: Dictionary = {}
			for key in value:
				dictionary_result[String(key)] = _serialize_variant(value[key])
			return dictionary_result
		TYPE_OBJECT:
			if value != null and value.has_method("to_dictionary"):
				return value.to_dictionary()
	return value


func _value_for_path(config: FlowProfile, path: String) -> Variant:
	var canonical := _canonical_parameter_path(path)
	var parts := canonical.split(".")
	if parts.size() == 3:
		var element := _find_geometry(config, parts[0], StringName(parts[1]))
		if element != null and _object_has_property(element, StringName(parts[2])):
			return element.get(parts[2])
	if _object_has_property(config, StringName(canonical)):
		return config.get(canonical)
	return null


func _object_has_property(object: Object, property_name: StringName) -> bool:
	for property in object.get_property_list():
		if StringName(property["name"]) == property_name:
			return true
	return false


func _first_reservoir_id() -> StringName:
	if _config == null or _config.reservoirs.is_empty():
		return &""
	return _config.reservoirs[0].element_id


func _adjust_first_gate(delta_width: float) -> void:
	var reservoir_id := _first_reservoir_id()
	if reservoir_id == &"":
		return
	var reservoir := _find_reservoir(reservoir_id)
	set_gate_width(
		reservoir_id,
		clampf(
			reservoir.outlet_width + delta_width,
			0.0,
			reservoir.radius * 2.0
		)
	)


func _emit_control_error(message: String, details: Dictionary = {}) -> void:
	push_warning("FlowModel2D[%s]: %s" % [screen_id, message])
	control_error.emit(screen_id, message, details)
