class_name GPULeaf2D
extends Node2D

## Isolated, write-only GPU leaf subsystem.
##
## A 300 x 2 CPU control texture contains only release commands: generations,
## stratified X selectors, palette indices, originating banks, and deterministic
## launch delays. Leaf position, water contact, irreversible attachment, path
## following, and visible disk rendering are GPU-owned. Simulation state is
## never read back to the CPU.

signal leaves_released(
	requested_count_per_side: int,
	scheduled_top_count: int,
	scheduled_bottom_count: int,
	scheduled_total_count: int,
	release_serial: int
)
signal pause_changed(paused: bool)

const HEAD_SHADER := preload("res://flow/gpu_stage/gpu_leaf_head.gdshader")
const DRAW_SHADER := preload("res://flow/gpu_stage/gpu_leaf_draw.gdshader")

const CAPACITY := 300
const MAX_PER_SIDE := 150
const DEFAULT_RELEASE_COUNT_PER_SIDE := 15
const PALETTE_SIZE := 7
const CONTROL_TEXTURE_ROWS := 2
const RELEASE_GAP_MULTIPLIER_MIN := 0.55
const RELEASE_GAP_MULTIPLIER_MAX := 1.45

const LEAF_COLORS: Array[Color] = [
	Color("8c3f0a"),
	Color("a95412"),
	Color("c47a12"),
	Color("c29a18"),
	Color("8a8f2a"),
	Color("4f772d"),
	Color("365f32"),
]

@export_group("Runtime")
@export var start_paused: bool = false
@export_range(1, 120, 1) var simulation_fps: int = 30
@export_range(-4096, 4096, 1) var leaf_z_index: int = 10
@export var stage_size := Vector2(1920.0, 1080.0)

@export_group("Release")
## Top and bottom leaves alternate. Each gap receives a stable 0.55..1.45x
## multiplier, while each bank's stratified X lanes are independently shuffled.
## The 0.20s default makes the latest leaf arrive about twice as late as before.
@export_range(0.0, 2.0, 0.001) var release_stagger_interval_seconds: float = 0.20

@export_group("Motion")
@export_range(1.0, 2400.0, 1.0) var free_speed_pixels: float = 120.0
@export_range(1.0, 2400.0, 1.0) var flow_speed_pixels: float = 300.0
@export_range(0.0, 1.0, 0.01) var speed_variation: float = 0.0
@export_range(0.0, 30.0, 0.1) var velocity_response: float = 8.0
@export_range(0.0, 120.0, 1.0) var free_sway_amplitude_min_pixels: float = 2.0
@export_range(0.0, 120.0, 1.0) var free_sway_amplitude_max_pixels: float = 6.0
@export_range(0.1, 10.0, 0.1) var free_sway_period_min_seconds: float = 1.2
@export_range(0.1, 10.0, 0.1) var free_sway_period_max_seconds: float = 2.8

@export_group("Free Water Search")
## FREE leaves sample a two-dimensional disk around their current point and
## gently bias their inward fall toward the nearest water sample.
@export_range(1.0, 480.0, 1.0) var free_water_search_radius_pixels: float = 120.0
@export_range(0.0, 1.0, 0.01) var free_water_steering_strength: float = 0.35
## Measured only along inward Y travel from the originating bank. The effective
## value is never less than half the stage height, so a leaf that misses water
## remains visible until it reaches the screen's horizontal midline.
@export_range(1.0, 4096.0, 1.0) var free_search_max_distance_pixels: float = 540.0
@export_range(0.05, 4.0, 0.05) var stopped_fade_seconds: float = 0.50

@export_group("Water Contact")
@export_range(0.0, 1.0, 0.001) var water_alpha_threshold: float = 0.001
@export_range(1.0, 120.0, 1.0) var contact_radius_pixels: float = 12.0
@export_range(1.0, 240.0, 1.0) var follow_probe_min_pixels: float = 8.0
@export_range(1.0, 480.0, 1.0) var follow_probe_max_pixels: float = 56.0
@export_range(1.0, 80.0, 1.0) var follow_turn_degrees: float = 35.0
## Cached headings are refreshed every few simulation frames. This follows a
## curving stream without reacting to every neighboring alpha sample.
@export_range(0.01, 1.0, 0.001) var follow_resample_interval_seconds: float = 0.12
## Toggle only when a platform's ViewportTexture arrives vertically inverted.
@export var occupancy_flip_y: bool = false

@export_group("Appearance")
## Disk diameter and deterministic upward size variation.
@export_range(1.0, 10.0, 0.1) var streak_width_pixels: float = 10.0
@export_range(0.0, 1.0, 0.01) var line_width_variation: float = 1.0
@export_range(0.0, 1.0, 0.01) var leaf_alpha: float = 1.0

var _head_particles: GPUParticles2D
var _head_material: ShaderMaterial
var _head_draw_material: ShaderMaterial
var _control_image: Image
var _control_texture: ImageTexture
var _empty_water_texture: ImageTexture
var _supplied_water_texture: Texture2D
var _slot_generations := PackedInt32Array()
var _write_slot: int = 0
var _release_serial: int = 0
var _total_scheduled_top: int = 0
var _total_scheduled_bottom: int = 0
var _last_scheduled_per_side: int = 0
var _last_scheduled_total: int = 0
var _last_release_stagger_span_seconds: float = 0.0
var _last_min_release_gap_seconds: float = 0.0
var _last_max_release_gap_seconds: float = 0.0
var _last_top_lane_order := PackedInt32Array()
var _last_bottom_lane_order := PackedInt32Array()
var _paused: bool = false


func _ready() -> void:
	_build_control_texture()
	_build_particles()
	_apply_parameters()
	set_paused(start_paused)


func configure(values: Dictionary) -> bool:
	## Unknown keys return false so controller/schema mismatches remain visible.
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
				stage_size = _variant_to_vector2(value, stage_size)
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
			"free_sway_amplitude_min_pixels", "sway_amplitude_min_pixels":
				free_sway_amplitude_min_pixels = clampf(float(value), 0.0, 120.0)
			"free_sway_amplitude_max_pixels", "sway_amplitude_max_pixels":
				free_sway_amplitude_max_pixels = clampf(float(value), 0.0, 120.0)
			"free_sway_period_min_seconds", "sway_period_min_seconds":
				free_sway_period_min_seconds = clampf(float(value), 0.1, 10.0)
			"free_sway_period_max_seconds", "sway_period_max_seconds":
				free_sway_period_max_seconds = clampf(float(value), 0.1, 10.0)
			"free_water_search_radius_pixels", "free_search_radius_pixels":
				free_water_search_radius_pixels = clampf(float(value), 1.0, 480.0)
			"free_water_steering_strength", "free_search_steering_strength":
				free_water_steering_strength = clampf(float(value), 0.0, 1.0)
			"free_search_max_distance_pixels", "free_search_distance_pixels":
				free_search_max_distance_pixels = clampf(float(value), 1.0, 4096.0)
			"stopped_fade_seconds", "miss_fade_seconds":
				stopped_fade_seconds = clampf(float(value), 0.05, 4.0)
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
			"streak_width_pixels", "line_width_pixels":
				streak_width_pixels = clampf(float(value), 1.0, 10.0)
			"disk_radius_pixels", "radius_pixels":
				streak_width_pixels = clampf(float(value) * 2.0, 1.0, 10.0)
			"line_width_variation", "width_variation", "radius_variation":
				line_width_variation = clampf(float(value), 0.0, 1.0)
			"leaf_alpha", "alpha":
				leaf_alpha = clampf(float(value), 0.0, 1.0)
			"leaf_z_index", "z_index":
				leaf_z_index = clampi(int(value), -4096, 4096)
			"paused":
				_paused = bool(value)
			_:
				return false
	# Keep the probe range valid even when controller keys arrive in either order.
	follow_probe_max_pixels = maxf(
		follow_probe_max_pixels,
		follow_probe_min_pixels
	)
	free_sway_amplitude_max_pixels = maxf(
		free_sway_amplitude_max_pixels,
		free_sway_amplitude_min_pixels
	)
	free_sway_period_max_seconds = maxf(
		free_sway_period_max_seconds,
		free_sway_period_min_seconds
	)
	free_search_max_distance_pixels = maxf(
		free_search_max_distance_pixels,
		stage_size.y * 0.5
	)
	_apply_parameters()
	set_paused(_paused)
	return true


func set_water_texture(texture: Texture2D) -> void:
	## Supply only the transparent water-only texture. Feeding the final canvas
	## would let leaves detect themselves, salmon, debug geometry, or background.
	_supplied_water_texture = texture
	_apply_water_texture()


func release_leaves(
	count_per_side: int = DEFAULT_RELEASE_COUNT_PER_SIDE
) -> int:
	## Returns the total scheduled count. The count argument is per river bank,
	## so the default release schedules 15 top + 15 bottom = 30 leaves.
	if _control_image == null or _control_texture == null:
		return 0
	var requested_per_side := (
		DEFAULT_RELEASE_COUNT_PER_SIDE if count_per_side < 0 else count_per_side
	)
	requested_per_side = clampi(requested_per_side, 0, MAX_PER_SIDE)
	if requested_per_side <= 0:
		return 0

	_release_serial += 1
	var release_delay_seconds := 0.0
	var minimum_gap_seconds := INF
	var maximum_gap_seconds := 0.0
	var scheduled_total := requested_per_side * 2
	var top_lane_order := _deterministic_lane_order(
		requested_per_side,
		0,
		_release_serial
	)
	var bottom_lane_order := _deterministic_lane_order(
		requested_per_side,
		1,
		_release_serial
	)
	_last_top_lane_order = top_lane_order.duplicate()
	_last_bottom_lane_order = bottom_lane_order.duplicate()
	for release_index in range(requested_per_side):
		for side_index in range(2):
			var sequence_index := release_index * 2 + side_index
			var slot := _write_slot
			var next_generation := _slot_generations[slot] + 1
			if next_generation > 1000000:
				next_generation = 1
			_slot_generations[slot] = next_generation
			# Each cohort independently spans the complete X axis, but lane rank is
			# shuffled separately from launch time. The bank therefore never types a
			# visibly ordered left-to-right sequence across the screen.
			var lane_rank := (
				top_lane_order[release_index]
				if side_index == 0
				else bottom_lane_order[release_index]
			)
			var lane_selector := fposmod(
				(float(lane_rank) + 0.5) / float(requested_per_side)
				+ float(_release_serial - 1) * 0.031
				+ float(side_index) * 0.017,
				1.0
			)
			var palette_index := (
				release_index * 2 + side_index + _release_serial - 1
			) % PALETTE_SIZE
			# Alpha is data, not display opacity: 1 means top-origin (+Y),
			# 2 means bottom-origin (-Y), and 0 means disabled.
			var side_code := float(side_index + 1)
			_control_image.set_pixel(
				slot,
				0,
				Color(
					float(next_generation),
					lane_selector,
					float(palette_index),
					side_code
				)
			)
			# Row one is command metadata. The GPU counts down this delay before
			# placing the head at its bank, so no invisible pre-spawn bridge exists.
			_control_image.set_pixel(
				slot,
				1,
				Color(
					release_delay_seconds,
					0.0,
					0.0,
					0.0
				)
			)
			if sequence_index < scheduled_total - 1:
				var gap_multiplier := _deterministic_release_gap_multiplier(
					_release_serial,
					sequence_index
				)
				var gap_seconds := (
					release_stagger_interval_seconds * gap_multiplier
				)
				minimum_gap_seconds = minf(minimum_gap_seconds, gap_seconds)
				maximum_gap_seconds = maxf(maximum_gap_seconds, gap_seconds)
				release_delay_seconds += gap_seconds
			_write_slot = (_write_slot + 1) % CAPACITY
	_control_texture.update(_control_image)

	_last_scheduled_per_side = requested_per_side
	_last_scheduled_total = scheduled_total
	_last_release_stagger_span_seconds = release_delay_seconds
	_last_min_release_gap_seconds = (
		0.0 if minimum_gap_seconds == INF else minimum_gap_seconds
	)
	_last_max_release_gap_seconds = maximum_gap_seconds
	_total_scheduled_top += requested_per_side
	_total_scheduled_bottom += requested_per_side
	leaves_released.emit(
		requested_per_side,
		requested_per_side,
		requested_per_side,
		_last_scheduled_total,
		_release_serial
	)
	return _last_scheduled_total


func set_paused(value: bool) -> void:
	_paused = value
	var speed_scale := 0.0 if value else 1.0
	if _head_particles != null:
		_head_particles.speed_scale = speed_scale
	if is_node_ready():
		pause_changed.emit(value)


func pause(value: bool = true) -> void:
	set_paused(value)


func is_paused() -> bool:
	return _paused


func reset_leaves() -> void:
	if _control_image == null or _control_texture == null:
		return
	# Advance every disabled generation. keep_data can preserve CUSTOM.x while
	# paused; this guarantees an immediate post-reset release is observed.
	for slot in range(CAPACITY):
		var next_generation := _slot_generations[slot] + 1
		if next_generation > 1000000:
			next_generation = 1
		_slot_generations[slot] = next_generation
		_control_image.set_pixel(
			slot,
			0,
			Color(float(next_generation), 0.0, 0.0, 0.0)
		)
		_control_image.set_pixel(slot, 1, Color(0.0, 0.0, 0.0, 0.0))
	_control_texture.update(_control_image)
	_write_slot = 0
	_release_serial = 0
	_total_scheduled_top = 0
	_total_scheduled_bottom = 0
	_last_scheduled_per_side = 0
	_last_scheduled_total = 0
	_last_release_stagger_span_seconds = 0.0
	_last_min_release_gap_seconds = 0.0
	_last_max_release_gap_seconds = 0.0
	_last_top_lane_order = PackedInt32Array()
	_last_bottom_lane_order = PackedInt32Array()
	if _head_particles != null:
		_head_particles.restart(true)


func reset() -> void:
	reset_leaves()


func runtime_summary() -> Dictionary:
	var palette_hex: Array[String] = []
	for color: Color in LEAF_COLORS:
		palette_hex.append("#%s" % color.to_html(false).to_upper())
	var base_radius := streak_width_pixels * 0.5
	var maximum_radius := base_radius * (1.0 + line_width_variation)
	return {
		"backend": "gpu_leaf_control_texture",
		"capacity": CAPACITY,
		"maximum_release_count_per_side": MAX_PER_SIDE,
		"default_release_count_per_side": DEFAULT_RELEASE_COUNT_PER_SIDE,
		"control_texture_rows": CONTROL_TEXTURE_ROWS,
		"release_stagger_interval_seconds": release_stagger_interval_seconds,
		"release_gap_multiplier_min": RELEASE_GAP_MULTIPLIER_MIN,
		"release_gap_multiplier_max": RELEASE_GAP_MULTIPLIER_MAX,
		"last_release_stagger_span_seconds": _last_release_stagger_span_seconds,
		"last_min_release_gap_seconds": _last_min_release_gap_seconds,
		"last_max_release_gap_seconds": _last_max_release_gap_seconds,
		"release_schedule": (
			"ALTERNATING_TOP_BOTTOM_DETERMINISTIC_IRREGULAR_X_SHUFFLED"
		),
		"release_x_order": "INDEPENDENT_DETERMINISTIC_SHUFFLE_PER_BANK",
		"release_time_x_correlation": "DECOUPLED",
		"last_top_lane_order": Array(_last_top_lane_order),
		"last_bottom_lane_order": Array(_last_bottom_lane_order),
		"segment_capacity": 0,
		"release_serial": _release_serial,
		"total_scheduled_top": _total_scheduled_top,
		"total_scheduled_bottom": _total_scheduled_bottom,
		"total_scheduled": _total_scheduled_top + _total_scheduled_bottom,
		"last_scheduled_per_side": _last_scheduled_per_side,
		"last_scheduled_total": _last_scheduled_total,
		"next_write_slot": _write_slot,
		"paused": _paused,
		"water_texture_assigned": _supplied_water_texture != null,
		"water_alpha_threshold": water_alpha_threshold,
		"contact_radius_pixels": contact_radius_pixels,
		"follow_probe_min_pixels": follow_probe_min_pixels,
		"follow_probe_max_pixels": follow_probe_max_pixels,
		"follow_turn_degrees": follow_turn_degrees,
		"follow_resample_interval_seconds": follow_resample_interval_seconds,
		"occupancy_flip_y": occupancy_flip_y,
		"free_speed_pixels": free_speed_pixels,
		"flow_speed_pixels": flow_speed_pixels,
		"speed_variation": speed_variation,
		"velocity_response": velocity_response,
		"free_sway_amplitude_min_pixels": free_sway_amplitude_min_pixels,
		"free_sway_amplitude_max_pixels": free_sway_amplitude_max_pixels,
		"free_sway_period_min_seconds": free_sway_period_min_seconds,
		"free_sway_period_max_seconds": free_sway_period_max_seconds,
		"free_water_search_radius_pixels": free_water_search_radius_pixels,
		"free_water_steering_strength": free_water_steering_strength,
		"free_search_max_distance_pixels": free_search_max_distance_pixels,
		"free_search_distance_measure": "INWARD_Y_FROM_ORIGIN_BANK_TO_MIDLINE",
		"free_search_policy": "NEARBY_2D_WATER_STEERING_UNTIL_SCREEN_MIDLINE",
		"minimum_fade_inward_distance_pixels": stage_size.y * 0.5,
		"free_search_backward_samples": "REJECTED",
		"free_search_axis_samples": 17,
		"stopped_fade_seconds": stopped_fade_seconds,
		# Width is the disk diameter; radius names are the canonical API.
		"streak_width_pixels": streak_width_pixels,
		"line_width_variation": line_width_variation,
		"radius_variation": line_width_variation,
		"disk_diameter_pixels": streak_width_pixels,
		"disk_radius_pixels": base_radius,
		"minimum_leaf_radius_pixels": base_radius,
		"maximum_leaf_radius_pixels": maximum_radius,
		"minimum_leaf_diameter_pixels": streak_width_pixels,
		"maximum_leaf_diameter_pixels": maximum_radius * 2.0,
		"leaf_width_scale_min": 1.0,
		"leaf_width_scale_max": 1.0 + line_width_variation,
		"minimum_leaf_width_pixels": streak_width_pixels,
		"maximum_leaf_width_pixels": maximum_radius * 2.0,
		"per_leaf_size_deterministic": true,
		"size_seed": "INDEX_AND_RELEASE_GENERATION",
		"spatial_alpha_profile": "RADIAL_ANTIALIASED_DISK_EDGE",
		"render_primitive": "ANTIALIASED_DISK_HEAD",
		"trail_primitive": "NONE",
		"head_only_rendering": true,
		"segment_emission": false,
		"palette": palette_hex,
		"z_index": leaf_z_index,
		"simulation_fps": simulation_fps,
		"state_transition": "FREE_TO_WATER_LATCHED_IRREVERSIBLE",
		"release_edges": "TOP_BOTTOM",
		"top_free_direction": "+Y",
		"bottom_free_direction": "-Y",
		"free_sway_axis": "X",
		"latched_initial_direction": "+X",
		"latched_follow_reference_axis": "CACHED_WATER_HEADING",
		"latched_heading_constraint": "LOCAL_CONTINUITY_WITH_DOWNSTREAM_BIAS",
		"latched_follow_resampling": "PERIODIC_DETERMINISTIC_PHASE",
		"latched_follow_support": "MULTI_RADIUS_CENTER_AND_FLANK_WATER_SUPPORT",
		"latched_retirement": "RIGHT_EDGE_AFTER_DISK",
		"miss_behavior": "REACH_SCREEN_MIDLINE_THEN_FADE",
		"miss_state": "STOPPED_FADING",
		"miss_retirement": "FREEZE_FADE_THEN_INACTIVE",
		"head_process_gpu": true,
		"water_contact_gpu": true,
		"free_water_search_gpu": true,
		"water_follow_gpu": true,
		"stopped_fade_gpu": true,
		"immutable_segments": false,
		"spatial_alpha_gpu": true,
		"per_segment_trail_lifetime": false,
		"cpu_readback": false,
		"gpu_active_count_available": false,
	}


func _build_control_texture() -> void:
	_slot_generations.resize(CAPACITY)
	_slot_generations.fill(0)
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
	_head_particles.name = "GPULeafHeads"
	_head_particles.emitting = true
	_head_particles.amount = CAPACITY
	_head_particles.amount_ratio = 1.0
	_head_particles.lifetime = 60.0
	_head_particles.preprocess = 0.0
	_head_particles.fixed_fps = simulation_fps
	_head_particles.interpolate = true
	_head_particles.fract_delta = false
	_head_particles.randomness = 0.0
	_head_particles.explosiveness = 1.0
	_head_particles.local_coords = true
	_head_particles.use_fixed_seed = true
	_head_particles.seed = 27301
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
	_head_particles.z_index = leaf_z_index
	_head_particles.z_as_relative = false
	add_child(_head_particles)
	_head_particles.restart(true)


func _apply_parameters() -> void:
	if _head_particles == null or _head_material == null:
		return
	_head_particles.fixed_fps = simulation_fps
	_head_particles.z_index = leaf_z_index
	_head_material.set_shader_parameter(&"leaf_control_texture", _control_texture)
	_head_material.set_shader_parameter(&"stage_size", stage_size)
	_head_material.set_shader_parameter(&"slot_capacity", float(CAPACITY))
	_head_material.set_shader_parameter(&"occupancy_flip_y", occupancy_flip_y)
	_head_material.set_shader_parameter(&"free_speed_pixels", free_speed_pixels)
	_head_material.set_shader_parameter(&"flow_speed_pixels", flow_speed_pixels)
	_head_material.set_shader_parameter(&"speed_variation", speed_variation)
	_head_material.set_shader_parameter(&"velocity_response", velocity_response)
	_head_material.set_shader_parameter(
		&"free_sway_amplitude_min_pixels", free_sway_amplitude_min_pixels
	)
	_head_material.set_shader_parameter(
		&"free_sway_amplitude_max_pixels", free_sway_amplitude_max_pixels
	)
	_head_material.set_shader_parameter(
		&"free_sway_period_min_seconds", free_sway_period_min_seconds
	)
	_head_material.set_shader_parameter(
		&"free_sway_period_max_seconds", free_sway_period_max_seconds
	)
	_head_material.set_shader_parameter(
		&"free_water_search_radius_pixels", free_water_search_radius_pixels
	)
	_head_material.set_shader_parameter(
		&"free_water_steering_strength", free_water_steering_strength
	)
	_head_material.set_shader_parameter(
		&"free_search_max_distance_pixels", free_search_max_distance_pixels
	)
	_head_material.set_shader_parameter(&"stopped_fade_seconds", stopped_fade_seconds)
	_head_material.set_shader_parameter(&"water_alpha_threshold", water_alpha_threshold)
	_head_material.set_shader_parameter(&"contact_radius_pixels", contact_radius_pixels)
	_head_material.set_shader_parameter(
		&"follow_probe_min_pixels", follow_probe_min_pixels
	)
	_head_material.set_shader_parameter(
		&"follow_probe_max_pixels", follow_probe_max_pixels
	)
	_head_material.set_shader_parameter(
		&"follow_turn_radians", deg_to_rad(follow_turn_degrees)
	)
	_head_material.set_shader_parameter(
		&"follow_resample_interval_seconds", follow_resample_interval_seconds
	)
	_head_material.set_shader_parameter(&"streak_width_pixels", streak_width_pixels)
	_head_material.set_shader_parameter(
		&"line_width_variation", line_width_variation
	)
	_head_material.set_shader_parameter(&"leaf_alpha", leaf_alpha)
	_apply_water_texture()


func _apply_water_texture() -> void:
	if _head_material == null:
		return
	var texture := _supplied_water_texture
	if texture == null:
		texture = _empty_water_texture
	_head_material.set_shader_parameter(&"water_occupancy_texture", texture)


func _deterministic_release_gap_multiplier(
	release_serial: int,
	sequence_index: int
) -> float:
	# A bounded integer polynomial avoids runtime RNG state and remains stable
	# after reset: release serial one reproduces the same irregular cadence.
	var sequence := sequence_index + 1
	var mixed: int = posmod(
		release_serial * 92821
		+ sequence * 68917
		+ sequence * sequence * 31337
		+ release_serial * sequence * 7919,
		1000003
	)
	var unit_value := float(mixed) / 1000002.0
	return lerpf(
		RELEASE_GAP_MULTIPLIER_MIN,
		RELEASE_GAP_MULTIPLIER_MAX,
		unit_value
	)


func _deterministic_lane_order(
	count: int,
	side_index: int,
	release_serial: int
) -> PackedInt32Array:
	## Fisher-Yates with an integer-only stable mix. This preserves one sample
	## in every stratified X lane while removing any dependence between X and
	## the monotonically increasing launch delay.
	var order := PackedInt32Array()
	order.resize(maxi(count, 0))
	for index in range(count):
		order[index] = index
	for index in range(count - 1, 0, -1):
		var step := count - index
		var bank := side_index + 1
		var mixed: int = posmod(
			release_serial * 92821
			+ bank * 68917
			+ step * 31337
			+ release_serial * step * 7919
			+ bank * step * 104729,
			1000003
		)
		var swap_index := mixed % (index + 1)
		var held := order[index]
		order[index] = order[swap_index]
		order[swap_index] = held
	return order


func _make_white_disk_texture() -> ImageTexture:
	# UV-space disk coverage is calculated by gpu_leaf_draw.gdshader. The
	# particle transform scales this single white texel to each stable diameter.
	var image := Image.create(1, 1, false, Image.FORMAT_RGBA8)
	image.fill(Color.WHITE)
	return ImageTexture.create_from_image(image)


func _variant_to_vector2(value: Variant, fallback: Vector2) -> Vector2:
	if value is Vector2:
		var vector_value: Vector2 = value
		return vector_value
	if value is Vector2i:
		return Vector2(value)
	if value is Array:
		var values: Array = value
		if values.size() >= 2:
			return Vector2(float(values[0]), float(values[1]))
	if value is Dictionary:
		var dictionary: Dictionary = value
		if dictionary.has("x") and dictionary.has("y"):
			return Vector2(float(dictionary["x"]), float(dictionary["y"]))
	return fallback
