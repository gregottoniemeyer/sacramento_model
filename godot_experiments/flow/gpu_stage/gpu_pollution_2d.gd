class_name GPUPollution2D
extends Node2D

## Isolated, write-only GPU pollution subsystem.
##
## A separate fixed 96 x 2 CPU control texture contains only bounded release
## commands. Each command supplies an exact source position, inward direction,
## generation, deterministic source seed, and launch delay. Seeking, water
## contact, local following, opaque water travel, and bounded center-miss fade
## or downstream retirement remain GPU-owned.

signal pollution_released(
	requested_count: int,
	scheduled_count: int,
	release_serial: int,
	source_ids: Array[String]
)
signal pause_changed(paused: bool)

const HEAD_SHADER := preload("res://flow/gpu_stage/gpu_pollution_head.gdshader")
# Reuse the leaf disk renderer verbatim. Pollution has its own process shader,
# resident particle pool, and control texture, so it cannot consume leaf slots.
const DRAW_SHADER := preload("res://flow/gpu_stage/gpu_leaf_draw.gdshader")

const CAPACITY := 96
const CONTROL_TEXTURE_ROWS := 2
const DEFAULT_COUNT_PER_SOURCE := 1
const POLLUTION_CLASS_MATERIAL := "material"
const POLLUTION_CLASS_HEAT := "heat"
const RELEASE_GAP_MULTIPLIER_MIN := 0.65
const RELEASE_GAP_MULTIPLIER_MAX := 1.35
# A resident command normally clears a 1920px stage in seconds. This long
# engine cycle prevents time-based particle recycling from becoming an
# observable retirement path; commands retire themselves at the right edge.
const PARTICLE_ENGINE_LIFETIME_SECONDS := 31536000.0

@export_group("Runtime")
@export var start_paused: bool = false
@export_range(1, 120, 1) var simulation_fps: int = 30
@export_range(-4096, 4096, 1) var pollution_z_index: int = 11
@export var stage_size := Vector2(1920.0, 1080.0)

@export_group("Release")
@export_range(0.0, 2.0, 0.001) var release_stagger_interval_seconds: float = 0.12

@export_group("Motion")
@export_range(1.0, 2400.0, 1.0) var free_speed_pixels: float = 120.0
@export_range(1.0, 2400.0, 1.0) var flow_speed_pixels: float = 300.0
@export_range(0.0, 1.0, 0.01) var speed_variation: float = 0.15
@export_range(0.0, 30.0, 0.1) var velocity_response: float = 8.0

@export_group("Free Water Search")
@export_range(1.0, 480.0, 1.0) var free_water_search_radius_pixels: float = 120.0
@export_range(0.0, 1.0, 0.01) var free_water_steering_strength: float = 0.35

@export_group("Water Following")
@export_range(0.0, 1.0, 0.001) var water_alpha_threshold: float = 0.001
@export_range(1.0, 120.0, 1.0) var contact_radius_pixels: float = 12.0
@export_range(1.0, 240.0, 1.0) var follow_probe_min_pixels: float = 8.0
@export_range(1.0, 480.0, 1.0) var follow_probe_max_pixels: float = 56.0
@export_range(1.0, 80.0, 1.0) var follow_turn_degrees: float = 35.0
@export_range(0.01, 1.0, 0.001) var follow_resample_interval_seconds: float = 0.12
@export var occupancy_flip_y: bool = false

@export_group("Appearance")
@export_range(1.0, 24.0, 0.1) var disk_diameter_pixels: float = 10.0
@export_range(0.0, 1.0, 0.01) var radius_variation: float = 0.40
@export var pollution_color := Color(0.38, 0.38, 0.38, 1.0)
@export var heat_pollution_color := Color(1.0, 0.0, 0.0, 1.0)
@export_range(0.05, 5.0, 0.05) var center_recheck_interval_seconds: float = 0.50
@export_range(0.0, 60.0, 0.1) var center_hold_seconds: float = 8.0
@export_range(0.1, 10.0, 0.1) var center_fade_seconds: float = 2.0

var _head_particles: GPUParticles2D
var _head_material: ShaderMaterial
var _head_draw_material: ShaderMaterial
var _control_image: Image
var _control_texture: ImageTexture
var _empty_water_texture: ImageTexture
var _supplied_water_texture: Texture2D
var _slot_generations := PackedInt32Array()
var _slot_enabled := PackedByteArray()
var _slot_source_ids: Array[String] = []
var _write_slot: int = 0
var _release_serial: int = 0
var _total_requested: int = 0
var _total_scheduled: int = 0
var _overwritten_command_slots: int = 0
var _last_requested_count: int = 0
var _last_scheduled_count: int = 0
var _last_release_stagger_span_seconds: float = 0.0
var _last_min_release_gap_seconds: float = 0.0
var _last_max_release_gap_seconds: float = 0.0
var _last_source_ids: Array[String] = []
var _last_source_release_counts: Dictionary = {}
var _total_scheduled_by_source: Dictionary = {}
var _paused: bool = false


func _ready() -> void:
	_build_control_texture()
	_build_particles()
	_apply_parameters()
	set_paused(start_paused or _paused)


func configure(values: Dictionary) -> bool:
	## Unknown or malformed keys return false so controller/schema mismatches
	## remain visible rather than silently changing the artwork.
	for raw_key: Variant in values:
		var key := String(raw_key)
		var value: Variant = values[raw_key]
		match key:
			"capacity":
				if int(value) != CAPACITY:
					return false
			"simulation_fps", "fixed_fps":
				simulation_fps = clampi(int(value), 1, 120)
			"stage_size":
				var parsed_size: Variant = _variant_to_vector2(value)
				if parsed_size == null:
					return false
				stage_size = Vector2(
					maxf(float(parsed_size.x), 1.0),
					maxf(float(parsed_size.y), 1.0)
				)
			"release_stagger_interval_seconds", "release_interval_seconds":
				release_stagger_interval_seconds = clampf(float(value), 0.0, 2.0)
			"free_speed_pixels", "free_speed":
				free_speed_pixels = clampf(float(value), 1.0, 2400.0)
			"flow_speed_pixels", "flow_speed":
				flow_speed_pixels = clampf(float(value), 1.0, 2400.0)
			"speed_variation":
				speed_variation = clampf(float(value), 0.0, 1.0)
			"velocity_response":
				velocity_response = clampf(float(value), 0.0, 30.0)
			"free_water_search_radius_pixels", "free_search_radius_pixels":
				free_water_search_radius_pixels = clampf(float(value), 1.0, 480.0)
			"free_water_steering_strength", "free_search_steering_strength":
				free_water_steering_strength = clampf(float(value), 0.0, 1.0)
			"water_alpha_threshold", "alpha_threshold":
				water_alpha_threshold = clampf(float(value), 0.0, 1.0)
			"contact_radius_pixels", "water_contact_radius_pixels":
				contact_radius_pixels = clampf(float(value), 1.0, 120.0)
			"follow_probe_min_pixels":
				follow_probe_min_pixels = clampf(float(value), 1.0, 240.0)
			"follow_probe_max_pixels":
				follow_probe_max_pixels = clampf(float(value), 1.0, 480.0)
			"follow_turn_degrees":
				follow_turn_degrees = clampf(float(value), 1.0, 80.0)
			"follow_resample_interval_seconds", "follow_resample_seconds":
				follow_resample_interval_seconds = clampf(float(value), 0.01, 1.0)
			"occupancy_flip_y":
				occupancy_flip_y = bool(value)
			"disk_diameter_pixels", "streak_width_pixels", "diameter_pixels":
				disk_diameter_pixels = clampf(float(value), 1.0, 24.0)
			"disk_radius_pixels", "radius_pixels":
				disk_diameter_pixels = clampf(float(value) * 2.0, 1.0, 24.0)
			"radius_variation", "line_width_variation", "width_variation":
				radius_variation = clampf(float(value), 0.0, 1.0)
			"pollution_color", "color":
				var parsed_color: Variant = _variant_to_color(value)
				if parsed_color == null:
					return false
				pollution_color = parsed_color
				pollution_color.a = 1.0
			"heat_pollution_color", "data_center_pollution_color":
				var parsed_heat_color: Variant = _variant_to_color(value)
				if parsed_heat_color == null:
					return false
				heat_pollution_color = parsed_heat_color
				heat_pollution_color.a = 1.0
			"center_recheck_interval_seconds", "center_recheck_seconds":
				center_recheck_interval_seconds = clampf(float(value), 0.05, 5.0)
			"center_hold_seconds", "center_catch_hold_seconds":
				center_hold_seconds = clampf(float(value), 0.0, 60.0)
			"center_fade_seconds", "center_miss_fade_seconds":
				center_fade_seconds = clampf(float(value), 0.1, 10.0)
			"pollution_z_index", "z_index":
				pollution_z_index = clampi(int(value), -4096, 4096)
			"paused":
				_paused = bool(value)
			_:
				return false
	follow_probe_max_pixels = maxf(follow_probe_max_pixels, follow_probe_min_pixels)
	pollution_color.a = 1.0
	heat_pollution_color.a = 1.0
	_apply_parameters()
	set_paused(_paused)
	return true


func set_water_texture(texture: Texture2D) -> void:
	## Supply the transparent water-only texture. Pollution seeks inward from its
	## exact source and, after contact, remains latched through alpha gaps.
	_supplied_water_texture = texture
	_apply_water_texture()


func release_from_sources(sources: Array[Dictionary]) -> int:
	## Schedules at most the fixed pool capacity. Sources are interleaved in a
	## stable round-robin when count > 1, so one source cannot monopolize a burst.
	## Each source requires source_id, position_pixels, inward_direction_pixels,
	## and pollution_class (`material` or `heat`), with an optional count. A
	## confluence import may set start_latched so an edge source begins in the
	## water-following state instead of using the legacy vertical center search.
	if _control_image == null or _control_texture == null:
		return 0

	var valid_sources: Array[Dictionary] = []
	var requested_count := 0
	for source: Dictionary in sources:
		var requested_for_source := _source_count(source.get("count", DEFAULT_COUNT_PER_SOURCE))
		requested_count += requested_for_source
		if requested_for_source <= 0:
			continue
		var source_id := String(source.get("source_id", "")).strip_edges()
		if (
			source_id.is_empty()
			or not source.has("position_pixels")
			or not source.has("inward_direction_pixels")
			or not source.has("pollution_class")
		):
			continue
		var parsed_position: Variant = _variant_to_vector2(source["position_pixels"])
		var parsed_inward: Variant = _variant_to_vector2(
			source["inward_direction_pixels"]
		)
		if parsed_position == null or parsed_inward == null:
			continue
		var position: Vector2 = parsed_position
		var inward_direction: Vector2 = parsed_inward
		var pollution_class := String(source["pollution_class"]).strip_edges().to_lower()
		var start_latched := bool(source.get("start_latched", false))
		if (
			position.x < 0.0
			or position.x > stage_size.x
			or position.y < 0.0
			or position.y > stage_size.y
			or inward_direction.length_squared() <= 0.000001
			or (
				absf(inward_direction.y) <= 0.000001
				and not start_latched
			)
			or pollution_class not in [
				POLLUTION_CLASS_MATERIAL,
				POLLUTION_CLASS_HEAT,
			]
		):
			continue
		valid_sources.append({
			"source_id": source_id,
			"position_pixels": position,
			"inward_direction_pixels": inward_direction.normalized(),
			"pollution_class": pollution_class,
			"start_latched": start_latched,
			"remaining": requested_for_source,
		})

	_last_requested_count = requested_count
	_total_requested += requested_count
	var commands: Array[Dictionary] = []
	var any_remaining := true
	while commands.size() < CAPACITY and any_remaining:
		any_remaining = false
		for source_index in range(valid_sources.size()):
			if commands.size() >= CAPACITY:
				break
			var remaining := int(valid_sources[source_index]["remaining"])
			if remaining <= 0:
				continue
			any_remaining = true
			commands.append(valid_sources[source_index])
			valid_sources[source_index]["remaining"] = remaining - 1

	var scheduled_count := commands.size()
	_last_scheduled_count = scheduled_count
	_last_source_ids = []
	_last_source_release_counts = {}
	_last_release_stagger_span_seconds = 0.0
	_last_min_release_gap_seconds = 0.0
	_last_max_release_gap_seconds = 0.0
	if scheduled_count <= 0:
		return 0

	_release_serial += 1
	var release_delay_seconds := 0.0
	var minimum_gap_seconds := INF
	var maximum_gap_seconds := 0.0
	for sequence_index in range(scheduled_count):
		var command: Dictionary = commands[sequence_index]
		var source_id := String(command["source_id"])
		var position: Vector2 = command["position_pixels"]
		var inward_direction: Vector2 = command["inward_direction_pixels"]
		var pollution_class := String(command["pollution_class"])
		if not _last_source_release_counts.has(source_id):
			_last_source_ids.append(source_id)
			_last_source_release_counts[source_id] = 0
		_last_source_release_counts[source_id] = (
			int(_last_source_release_counts[source_id]) + 1
		)
		_total_scheduled_by_source[source_id] = (
			int(_total_scheduled_by_source.get(source_id, 0)) + 1
		)

		var slot := _write_slot
		if _slot_enabled[slot] != 0:
			_overwritten_command_slots += 1
		var next_generation := _slot_generations[slot] + 1
		if next_generation > 1000000:
			next_generation = 1
		_slot_generations[slot] = next_generation
		_slot_enabled[slot] = 1
		_slot_source_ids[slot] = source_id
		var source_class_tag := (
			2.0 if pollution_class == POLLUTION_CLASS_HEAT else 1.0
		)
		if bool(command.get("start_latched", false)):
			source_class_tag += 2.0
		_control_image.set_pixel(
			slot,
			0,
			Color(
				float(next_generation),
				position.x,
				position.y,
				source_class_tag
			)
		)
		_control_image.set_pixel(
			slot,
			1,
			Color(
				release_delay_seconds,
				_stable_source_seed_unit(source_id),
				inward_direction.x,
				inward_direction.y
			)
		)
		if sequence_index < scheduled_count - 1:
			var gap_seconds := (
				release_stagger_interval_seconds
				* _deterministic_release_gap_multiplier(
					_release_serial,
					sequence_index
				)
			)
			minimum_gap_seconds = minf(minimum_gap_seconds, gap_seconds)
			maximum_gap_seconds = maxf(maximum_gap_seconds, gap_seconds)
			release_delay_seconds += gap_seconds
		_write_slot = (_write_slot + 1) % CAPACITY

	_control_texture.update(_control_image)
	_last_release_stagger_span_seconds = release_delay_seconds
	_last_min_release_gap_seconds = (
		0.0 if minimum_gap_seconds == INF else minimum_gap_seconds
	)
	_last_max_release_gap_seconds = maximum_gap_seconds
	_total_scheduled += scheduled_count
	pollution_released.emit(
		requested_count,
		scheduled_count,
		_release_serial,
		_last_source_ids.duplicate()
	)
	return scheduled_count


func set_paused(value: bool) -> void:
	_paused = value
	if _head_particles != null:
		_head_particles.speed_scale = 0.0 if value else 1.0
	if is_node_ready():
		pause_changed.emit(value)


func is_paused() -> bool:
	return _paused


func reset_pollution() -> void:
	if _control_image != null and _control_texture != null:
		# Bump disabled generations so keep_data cannot preserve a prior command
		# through a paused reset followed by immediate slot reuse.
		for slot in range(CAPACITY):
			var next_generation := _slot_generations[slot] + 1
			if next_generation > 1000000:
				next_generation = 1
			_slot_generations[slot] = next_generation
			_slot_enabled[slot] = 0
			_slot_source_ids[slot] = ""
			_control_image.set_pixel(
				slot,
				0,
				Color(float(next_generation), 0.0, 0.0, 0.0)
			)
			_control_image.set_pixel(slot, 1, Color(0.0, 0.0, 0.0, 0.0))
		_control_texture.update(_control_image)
	_write_slot = 0
	_release_serial = 0
	_total_requested = 0
	_total_scheduled = 0
	_overwritten_command_slots = 0
	_last_requested_count = 0
	_last_scheduled_count = 0
	_last_release_stagger_span_seconds = 0.0
	_last_min_release_gap_seconds = 0.0
	_last_max_release_gap_seconds = 0.0
	_last_source_ids = []
	_last_source_release_counts = {}
	_total_scheduled_by_source = {}
	if _head_particles != null:
		_head_particles.restart(true)


func reset() -> void:
	reset_pollution()


func runtime_summary() -> Dictionary:
	var base_radius := disk_diameter_pixels * 0.5
	var maximum_radius := base_radius * (1.0 + radius_variation)
	return {
		"backend": "gpu_pollution_control_texture",
		"capacity": CAPACITY,
		"control_texture_rows": CONTROL_TEXTURE_ROWS,
		"particle_engine_lifetime_seconds": PARTICLE_ENGINE_LIFETIME_SECONDS,
		"release_serial": _release_serial,
		"total_requested": _total_requested,
		"total_scheduled": _total_scheduled,
		"last_requested_count": _last_requested_count,
		"last_scheduled_count": _last_scheduled_count,
		"next_write_slot": _write_slot,
		"circular_reuse": true,
		"overwritten_command_slots": _overwritten_command_slots,
		"resident_command_slots": _resident_command_slot_count(),
		"resident_command_source_ids": _resident_command_source_ids(),
		"last_source_ids": _last_source_ids.duplicate(),
		"last_source_release_counts": _last_source_release_counts.duplicate(true),
		"total_scheduled_by_source": _total_scheduled_by_source.duplicate(true),
		"release_stagger_interval_seconds": release_stagger_interval_seconds,
		"release_gap_multiplier_min": RELEASE_GAP_MULTIPLIER_MIN,
		"release_gap_multiplier_max": RELEASE_GAP_MULTIPLIER_MAX,
		"last_release_stagger_span_seconds": _last_release_stagger_span_seconds,
		"last_min_release_gap_seconds": _last_min_release_gap_seconds,
		"last_max_release_gap_seconds": _last_max_release_gap_seconds,
		"release_schedule": "ROUND_ROBIN_SOURCES_DETERMINISTIC_IRREGULAR_STAGGER",
		"paused": _paused,
		"water_texture_assigned": _supplied_water_texture != null,
		"stage_size": stage_size,
		"simulation_fps": simulation_fps,
		"z_index": pollution_z_index,
		"free_speed_pixels": free_speed_pixels,
		"flow_speed_pixels": flow_speed_pixels,
		"speed_variation": speed_variation,
		"velocity_response": velocity_response,
		"free_water_search_radius_pixels": free_water_search_radius_pixels,
		"free_water_steering_strength": free_water_steering_strength,
		"free_search_axis_samples": 17,
		"free_search_backward_samples": "REJECTED",
		"free_search_policy": "NEARBY_2D_INWARD_WATER_STEERING_TO_CENTERLINE",
		"free_search_stop": "CENTER_RECHECK_THEN_FADE",
		"free_search_centerline_y_pixels": stage_size.y * 0.5,
		"center_recheck_interval_seconds": center_recheck_interval_seconds,
		"center_hold_seconds": center_hold_seconds,
		"center_fade_seconds": center_fade_seconds,
		"center_max_visible_seconds": center_hold_seconds + center_fade_seconds,
		"center_recheck_policy": "THROTTLED_CONTACT_ONLY_DETERMINISTIC_PHASE",
		"water_alpha_threshold": water_alpha_threshold,
		"contact_radius_pixels": contact_radius_pixels,
		"contact_axis_samples": 9,
		"follow_probe_min_pixels": follow_probe_min_pixels,
		"follow_probe_max_pixels": follow_probe_max_pixels,
		"follow_turn_degrees": follow_turn_degrees,
		"follow_resample_interval_seconds": follow_resample_interval_seconds,
		"occupancy_flip_y": occupancy_flip_y,
		"disk_diameter_pixels": disk_diameter_pixels,
		"disk_radius_pixels": base_radius,
		"minimum_disk_radius_pixels": base_radius,
		"maximum_disk_radius_pixels": maximum_radius,
		"radius_variation": radius_variation,
		"pollution_color": "#%s" % pollution_color.to_html(true).to_upper(),
		"material_pollution_color": "#%s" % pollution_color.to_html(true).to_upper(),
		"heat_pollution_color": "#%s" % heat_pollution_color.to_html(true).to_upper(),
		"pollution_color_routing": "MATERIAL_GREY_HEAT_BRIGHT_RED",
		"pollution_classes": [POLLUTION_CLASS_MATERIAL, POLLUTION_CLASS_HEAT],
		"source_alpha": 1.0,
		"spatial_alpha_profile": "RADIAL_ANTIALIASED_DISK_EDGE",
		"render_primitive": "ANTIALIASED_DISK_HEAD",
		"draw_shader_reused": "res://flow/gpu_stage/gpu_leaf_draw.gdshader",
		"source_position_contract": "EXACT_SOURCE_PIXELS_WITH_INWARD_DIRECTION",
		"command_contract": (
			"SOURCE_ID_POSITION_INWARD_DIRECTION_CLASS_AND_OPTIONAL_COUNT"
		),
		"initial_state": "FREE_SEEKING",
		"water_attachment": "IRREVERSIBLE",
		"water_gap_behavior": "KEEP_CACHED_HEADING_AND_FULL_OPACITY",
		"opacity_behavior": "CONSTANT_ONE_UNTIL_CENTER_MISS_FADE",
		"fade_behavior": "CENTER_MISS_SMOOTH_AFTER_HOLD",
		"retirement": "LATCHED_RIGHT_EDGE_OR_CENTER_TIMEOUT_OR_EXPLICIT_RESET",
		"latched_retirement": "RIGHT_EDGE_AFTER_COMPLETE_DISK",
		"miss_retirement": "CENTER_RECHECK_HOLD_THEN_FADE_TO_INACTIVE",
		"bounded_pool": true,
		"head_process_gpu": true,
		"free_water_search_gpu": true,
		"water_follow_gpu": true,
		"cpu_readback": false,
		"gpu_active_count_available": false,
	}


func _build_control_texture() -> void:
	_slot_generations.resize(CAPACITY)
	_slot_generations.fill(0)
	_slot_enabled.resize(CAPACITY)
	_slot_enabled.fill(0)
	_slot_source_ids.resize(CAPACITY)
	for slot in range(CAPACITY):
		_slot_source_ids[slot] = ""
	_control_image = Image.create(
		CAPACITY,
		CONTROL_TEXTURE_ROWS,
		false,
		Image.FORMAT_RGBAF
	)
	_control_image.fill(Color(0.0, 0.0, 0.0, 0.0))
	_control_texture = ImageTexture.create_from_image(_control_image)
	var empty_image := Image.create(1, 1, false, Image.FORMAT_RGBA8)
	empty_image.fill(Color(0.0, 0.0, 0.0, 0.0))
	_empty_water_texture = ImageTexture.create_from_image(empty_image)


func _build_particles() -> void:
	var visibility := Rect2(
		Vector2(-256.0, -256.0),
		stage_size + Vector2(512.0, 512.0)
	)
	_head_particles = GPUParticles2D.new()
	_head_particles.name = "GPUPollutionHeads"
	_head_particles.emitting = true
	_head_particles.amount = CAPACITY
	_head_particles.amount_ratio = 1.0
	_head_particles.lifetime = PARTICLE_ENGINE_LIFETIME_SECONDS
	_head_particles.preprocess = 0.0
	_head_particles.fixed_fps = simulation_fps
	_head_particles.interpolate = true
	_head_particles.fract_delta = false
	_head_particles.randomness = 0.0
	_head_particles.explosiveness = 1.0
	_head_particles.local_coords = true
	_head_particles.use_fixed_seed = true
	_head_particles.seed = 91873
	_head_particles.visibility_rect = visibility
	_head_particles.trail_enabled = false
	_head_material = ShaderMaterial.new()
	_head_material.shader = HEAD_SHADER
	_head_particles.process_material = _head_material
	_head_draw_material = ShaderMaterial.new()
	_head_draw_material.shader = DRAW_SHADER
	_head_particles.material = _head_draw_material
	_head_particles.texture = _make_white_disk_texture()
	_head_particles.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	_head_particles.z_index = pollution_z_index
	_head_particles.z_as_relative = false
	add_child(_head_particles)
	_head_particles.restart(true)


func _apply_parameters() -> void:
	if _head_particles == null or _head_material == null:
		return
	_head_particles.fixed_fps = simulation_fps
	_head_particles.z_index = pollution_z_index
	_head_material.set_shader_parameter(&"pollution_control_texture", _control_texture)
	_head_material.set_shader_parameter(&"stage_size", stage_size)
	_head_material.set_shader_parameter(&"slot_capacity", float(CAPACITY))
	_head_material.set_shader_parameter(&"occupancy_flip_y", occupancy_flip_y)
	_head_material.set_shader_parameter(&"free_speed_pixels", free_speed_pixels)
	_head_material.set_shader_parameter(&"flow_speed_pixels", flow_speed_pixels)
	_head_material.set_shader_parameter(&"speed_variation", speed_variation)
	_head_material.set_shader_parameter(&"velocity_response", velocity_response)
	_head_material.set_shader_parameter(
		&"free_water_search_radius_pixels", free_water_search_radius_pixels
	)
	_head_material.set_shader_parameter(
		&"free_water_steering_strength", free_water_steering_strength
	)
	_head_material.set_shader_parameter(&"water_alpha_threshold", water_alpha_threshold)
	_head_material.set_shader_parameter(&"contact_radius_pixels", contact_radius_pixels)
	_head_material.set_shader_parameter(&"follow_probe_min_pixels", follow_probe_min_pixels)
	_head_material.set_shader_parameter(&"follow_probe_max_pixels", follow_probe_max_pixels)
	_head_material.set_shader_parameter(&"follow_turn_radians", deg_to_rad(follow_turn_degrees))
	_head_material.set_shader_parameter(
		&"follow_resample_interval_seconds",
		follow_resample_interval_seconds
	)
	_head_material.set_shader_parameter(&"disk_diameter_pixels", disk_diameter_pixels)
	_head_material.set_shader_parameter(&"radius_variation", radius_variation)
	_head_material.set_shader_parameter(
		&"center_recheck_interval_seconds",
		center_recheck_interval_seconds
	)
	_head_material.set_shader_parameter(&"center_hold_seconds", center_hold_seconds)
	_head_material.set_shader_parameter(&"center_fade_seconds", center_fade_seconds)
	pollution_color.a = 1.0
	heat_pollution_color.a = 1.0
	_head_material.set_shader_parameter(&"pollution_color", pollution_color)
	_head_material.set_shader_parameter(&"heat_pollution_color", heat_pollution_color)
	_apply_water_texture()


func _apply_water_texture() -> void:
	if _head_material == null:
		return
	var texture := _supplied_water_texture
	if texture == null:
		texture = _empty_water_texture
	_head_material.set_shader_parameter(&"water_occupancy_texture", texture)


func _resident_command_slot_count() -> int:
	var count := 0
	for enabled in _slot_enabled:
		if enabled != 0:
			count += 1
	return count


func _resident_command_source_ids() -> Array[String]:
	var source_ids: Array[String] = []
	for slot in range(_slot_source_ids.size()):
		if _slot_enabled[slot] == 0:
			continue
		var source_id := _slot_source_ids[slot]
		if not source_ids.has(source_id):
			source_ids.append(source_id)
	return source_ids


func _source_count(value: Variant) -> int:
	if not (value is int or value is float):
		return 0
	var numeric := float(value)
	if not is_finite(numeric) or numeric <= 0.0:
		return 0
	return clampi(int(floor(numeric)), 0, CAPACITY)


func _deterministic_release_gap_multiplier(
	release_serial: int,
	sequence_index: int
) -> float:
	var sequence := sequence_index + 1
	var mixed: int = posmod(
		release_serial * 92821
		+ sequence * 68917
		+ sequence * sequence * 31337
		+ release_serial * sequence * 7919,
		1000003
	)
	return lerpf(
		RELEASE_GAP_MULTIPLIER_MIN,
		RELEASE_GAP_MULTIPLIER_MAX,
		float(mixed) / 1000002.0
	)


func _stable_source_seed_unit(source_id: String) -> float:
	# A small deterministic polynomial avoids runtime RNG and String.hash state.
	var mixed := 17
	for index in range(source_id.length()):
		mixed = posmod(mixed * 131 + source_id.unicode_at(index), 1000003)
	return float(mixed) / 1000002.0


func _make_white_disk_texture() -> ImageTexture:
	# UV-space disk coverage comes from the existing leaf draw shader.
	var image := Image.create(1, 1, false, Image.FORMAT_RGBA8)
	image.fill(Color.WHITE)
	return ImageTexture.create_from_image(image)


func _variant_to_vector2(value: Variant) -> Variant:
	if value is Vector2:
		return value if is_finite(value.x) and is_finite(value.y) else null
	if value is Vector2i:
		return Vector2(value)
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
	return (value is int or value is float) and is_finite(float(value))
