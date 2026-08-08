class_name GPUSalmon2D
extends Node2D

## Isolated, write-only GPU salmon subsystem.
##
## A 300 x 1 CPU control texture carries only release generations, lane
## selectors, and palette indices. Head motion, water contact, latching, fading,
## and immutable trail emission remain GPU-owned. No simulation state is read
## back to the CPU.

signal salmon_released(
	requested_count: int,
	scheduled_count: int,
	release_serial: int
)
signal pause_changed(paused: bool)

const HEAD_SHADER := preload(
	"res://flow/gpu_stage/gpu_salmon_head.gdshader"
)
const SEGMENT_SHADER := preload(
	"res://flow/gpu_stage/gpu_salmon_segment.gdshader"
)
const DRAW_SHADER := preload(
	"res://flow/gpu_stage/gpu_salmon_draw.gdshader"
)

const CAPACITY := 300
const DEFAULT_RELEASE_COUNT := 25
const PALETTE_SIZE := 5
const SEGMENT_CAPACITY_MARGIN := 1.25

const SALMON_COLORS: Array[Color] = [
	Color("ff5c8a"),
	Color("ff7a72"),
	Color("ff8c42"),
	Color("ffad33"),
	Color("ffd23f"),
]

@export_group("Runtime")
@export var start_paused: bool = false
@export_range(1, 120, 1) var simulation_fps: int = 30
@export_range(-4096, 4096, 1) var salmon_z_index: int = 20
@export var stage_size := Vector2(1920.0, 1080.0)
@export var stage_phase: float = 0.0

@export_group("Upstream Field")
@export_range(1.0, 2400.0, 1.0) var upstream_speed_pixels: float = 100.0
@export_range(0.0, 1.0, 0.01) var speed_variation: float = 0.10
@export_range(0.0, 30.0, 0.1) var velocity_response: float = 12.0
@export_range(0.0, 300.0, 1.0) var noise_strength: float = 18.0
@export_range(0.0001, 0.1, 0.0001) var noise_scale: float = 0.010
@export_range(0.0, 10.0, 0.01) var noise_speed: float = 0.72

@export_group("Water Contact")
@export_range(0.0, 1.0, 0.001) var water_alpha_threshold: float = 0.001
## X half-extent of the centered contact rectangle; 120 gives 240px total.
@export_range(1.0, 480.0, 1.0) var water_lookahead_pixels: float = 120.0
## Y half-extent of the centered contact rectangle; 12 gives 24px total.
@export_range(1.0, 120.0, 1.0) var water_contact_half_height_pixels: float = 12.0
## Weights the selected 2D water direction against the current swim heading.
@export_range(0.0, 30.0, 0.1) var water_steering_strength: float = 5.0
@export_range(1.0, 480.0, 1.0) var spawn_search_width_pixels: float = 120.0
## Deliberately exceeds a 1080p half-height so every release selector can fall
## back to any active right-edge lane instead of silently missing sparse water.
@export_range(1.0, 4096.0, 1.0) var spawn_search_half_height_pixels: float = 2048.0
## Toggle only when a platform's ViewportTexture arrives vertically inverted.
@export var occupancy_flip_y: bool = false

@export_group("Appearance")
@export_range(8.0, 160.0, 1.0) var streak_length_pixels: float = 100.0
@export_range(1.0, 5.0, 0.1) var streak_width_pixels: float = 3.0
@export_range(0.05, 4.0, 0.05) var fade_seconds: float = 0.50
@export_range(0.0, 1.0, 0.01) var salmon_alpha: float = 1.0
@export_range(4.0, 128.0, 1.0) var segment_max_length_pixels: float = 32.0

var _head_particles: GPUParticles2D
var _segment_particles: GPUParticles2D
var _head_material: ShaderMaterial
var _segment_process_material: ShaderMaterial
var _segment_draw_material: ShaderMaterial
var _control_image: Image
var _control_texture: ImageTexture
var _empty_water_texture: ImageTexture
var _supplied_water_texture: Texture2D
var _slot_generations := PackedInt32Array()
var _write_slot: int = 0
var _release_serial: int = 0
var _total_scheduled: int = 0
var _last_scheduled: int = 0
var _paused: bool = false


func _ready() -> void:
	_build_control_texture()
	_build_particles()
	_apply_parameters()
	set_paused(start_paused)


func configure(values: Dictionary) -> bool:
	## Unknown keys return false. Callers can therefore detect a controller/schema
	## mismatch without inspecting material uniforms.
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
			"stage_phase":
				stage_phase = float(value)
			"upstream_speed_pixels", "speed":
				upstream_speed_pixels = clampf(float(value), 1.0, 2400.0)
			"speed_variation":
				speed_variation = clampf(float(value), 0.0, 1.0)
			"velocity_response":
				velocity_response = clampf(float(value), 0.0, 30.0)
			"noise_strength":
				noise_strength = clampf(float(value), 0.0, 300.0)
			"noise_scale":
				noise_scale = clampf(float(value), 0.0001, 0.1)
			"noise_speed":
				noise_speed = clampf(float(value), 0.0, 10.0)
			"water_alpha_threshold", "alpha_threshold":
				water_alpha_threshold = clampf(float(value), 0.0, 1.0)
			"water_lookahead_pixels", "lookahead_pixels":
				water_lookahead_pixels = clampf(float(value), 1.0, 480.0)
			"water_contact_half_height_pixels":
				water_contact_half_height_pixels = clampf(
					float(value), 1.0, 120.0
				)
			"water_steering_strength":
				water_steering_strength = clampf(float(value), 0.0, 30.0)
			"spawn_search_width_pixels":
				spawn_search_width_pixels = clampf(float(value), 1.0, 480.0)
			"spawn_search_half_height_pixels":
				spawn_search_half_height_pixels = clampf(
					float(value), 1.0, 4096.0
				)
			"occupancy_flip_y":
				occupancy_flip_y = bool(value)
			"streak_length_pixels", "trail_length_pixels":
				streak_length_pixels = clampf(float(value), 8.0, 160.0)
			"streak_width_pixels", "line_width_pixels":
				streak_width_pixels = clampf(float(value), 1.0, 5.0)
			"fade_seconds":
				fade_seconds = clampf(float(value), 0.05, 4.0)
			"salmon_alpha", "alpha":
				salmon_alpha = clampf(float(value), 0.0, 1.0)
			"segment_max_length_pixels":
				segment_max_length_pixels = clampf(float(value), 4.0, 128.0)
			"salmon_z_index", "z_index":
				salmon_z_index = clampi(int(value), -4096, 4096)
			"paused":
				_paused = bool(value)
			_:
				return false
	_apply_parameters()
	set_paused(_paused)
	return true


func set_water_texture(texture: Texture2D) -> void:
	## The texture must contain water-only alpha and must be rendered before this
	## node. Do not supply the final canvas containing salmon, or fish will detect
	## themselves as water.
	_supplied_water_texture = texture
	_apply_water_texture()


func release_salmon(count: int = DEFAULT_RELEASE_COUNT) -> int:
	## Schedule exactly `count` control generations, overwriting oldest slots in a
	## fixed circular pool. Success means GPU work was scheduled; active/fading
	## counts intentionally remain GPU-authoritative and unread.
	if _control_image == null or _control_texture == null:
		return 0
	var requested := DEFAULT_RELEASE_COUNT if count < 0 else count
	requested = clampi(requested, 0, CAPACITY)
	if requested <= 0:
		return 0
	_release_serial += 1
	for release_index in range(requested):
		var slot := _write_slot
		var next_generation := _slot_generations[slot] + 1
		if next_generation > 1000000:
			next_generation = 1
		_slot_generations[slot] = next_generation
		# Mid-cell selectors avoid sampling exactly at stage boundaries. A tiny
		# batch rotation prevents successive releases from retracing identical lanes.
		var lane_selector := fposmod(
			(float(release_index) + 0.5) / float(requested)
			+ float(_release_serial - 1) * 0.037,
			1.0
		)
		var palette_index := (release_index + _release_serial - 1) % PALETTE_SIZE
		_control_image.set_pixel(
			slot,
			0,
			Color(
				float(next_generation),
				lane_selector,
				float(palette_index),
				1.0
			)
		)
		_write_slot = (_write_slot + 1) % CAPACITY
	_control_texture.update(_control_image)
	_last_scheduled = requested
	_total_scheduled += requested
	salmon_released.emit(requested, requested, _release_serial)
	return requested


func set_paused(value: bool) -> void:
	_paused = value
	var speed_scale := 0.0 if value else 1.0
	if _head_particles != null:
		_head_particles.speed_scale = speed_scale
	if _segment_particles != null:
		_segment_particles.speed_scale = speed_scale
	if is_node_ready():
		pause_changed.emit(value)


func pause(value: bool = true) -> void:
	set_paused(value)


func is_paused() -> bool:
	return _paused


func reset_salmon() -> void:
	if _control_image == null or _control_texture == null:
		return
	# Never reuse an old GPU generation number. keep_data can preserve CUSTOM.x
	# while paused or across an immediate reset+release packet; advancing the
	# disabled generation guarantees the following release is observed.
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
	_control_texture.update(_control_image)
	_write_slot = 0
	_release_serial = 0
	_total_scheduled = 0
	_last_scheduled = 0
	if _segment_particles != null:
		_segment_particles.restart(true)
	if _head_particles != null:
		_head_particles.restart(true)


func reset() -> void:
	reset_salmon()


func runtime_summary() -> Dictionary:
	var palette_hex: Array[String] = []
	for color: Color in SALMON_COLORS:
		palette_hex.append("#%s" % color.to_html(false).to_upper())
	return {
		"backend": "gpu_salmon_control_texture",
		"capacity": CAPACITY,
		"segment_capacity": (
			_segment_particles.amount if _segment_particles != null else 0
		),
		"release_serial": _release_serial,
		"total_scheduled": _total_scheduled,
		"last_scheduled": _last_scheduled,
		"next_write_slot": _write_slot,
		"paused": _paused,
		"water_texture_assigned": _supplied_water_texture != null,
		"water_alpha_threshold": water_alpha_threshold,
		"water_lookahead_pixels": water_lookahead_pixels,
		"water_contact_half_height_pixels": water_contact_half_height_pixels,
		"water_steering_strength": water_steering_strength,
		"water_steering_mode": "DETERMINISTIC_2D_CONTACT_FIELD",
		"water_steering_reference": "CURRENT_SWIM_HEADING",
		"occupancy_flip_y": occupancy_flip_y,
		"upstream_speed_pixels": upstream_speed_pixels,
		"streak_length_pixels": streak_length_pixels,
		"streak_width_pixels": streak_width_pixels,
		"no_water_fade_seconds": fade_seconds,
		"trail_lifetime_seconds": _trail_lifetime_seconds(),
		"effective_trail_length_pixels": (
			upstream_speed_pixels * _trail_lifetime_seconds()
		),
		"immutable_loss_fade_limitation": (
			"The latched head emits a damped rolling trail with diminishing alpha; "
			+ "older immutable samples retain their own short spatial lifetime."
		),
		"palette": palette_hex,
		"z_index": salmon_z_index,
		"simulation_fps": simulation_fps,
		"head_process_gpu": true,
		"water_contact_gpu": true,
		"immutable_segments": true,
		"cpu_readback": false,
		"gpu_active_count_available": false,
	}


func _build_control_texture() -> void:
	_slot_generations.resize(CAPACITY)
	_slot_generations.fill(0)
	_control_image = Image.create(CAPACITY, 1, false, Image.FORMAT_RGBAF)
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
	var segment_texture := _make_white_ribbon_texture()

	_segment_particles = GPUParticles2D.new()
	_segment_particles.name = "GPUSalmonTrailSegments"
	_segment_particles.emitting = false
	_segment_particles.amount = _required_segment_capacity()
	_segment_particles.amount_ratio = 1.0
	_segment_particles.lifetime = _trail_lifetime_seconds()
	_segment_particles.fixed_fps = simulation_fps
	_segment_particles.interpolate = false
	_segment_particles.fract_delta = false
	_segment_particles.randomness = 0.0
	_segment_particles.explosiveness = 0.0
	_segment_particles.local_coords = true
	_segment_particles.use_fixed_seed = true
	_segment_particles.seed = 19301
	_segment_particles.visibility_rect = visibility
	_segment_particles.trail_enabled = false
	_segment_process_material = ShaderMaterial.new()
	_segment_process_material.shader = SEGMENT_SHADER
	_segment_particles.process_material = _segment_process_material
	_segment_draw_material = ShaderMaterial.new()
	_segment_draw_material.shader = DRAW_SHADER
	_segment_particles.material = _segment_draw_material
	_segment_particles.texture = segment_texture
	_segment_particles.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	_segment_particles.z_index = salmon_z_index
	_segment_particles.z_as_relative = false
	add_child(_segment_particles)

	_head_particles = GPUParticles2D.new()
	_head_particles.name = "GPUSalmonHeads"
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
	_head_particles.seed = 17301
	_head_particles.visibility_rect = visibility
	_head_particles.trail_enabled = false
	_head_material = ShaderMaterial.new()
	_head_material.shader = HEAD_SHADER
	_head_particles.process_material = _head_material
	# A transparent head texture keeps the resident control particles invisible;
	# only their immutable sub-emitted segments are drawn.
	_head_particles.texture = _make_transparent_texture()
	_head_particles.z_index = salmon_z_index
	_head_particles.z_as_relative = false
	add_child(_head_particles)
	_head_particles.sub_emitter = _head_particles.get_path_to(_segment_particles)
	_head_particles.restart(true)


func _apply_parameters() -> void:
	if _head_particles == null or _head_material == null:
		return
	_head_particles.fixed_fps = simulation_fps
	_head_particles.z_index = salmon_z_index
	_head_material.set_shader_parameter(&"salmon_control_texture", _control_texture)
	_head_material.set_shader_parameter(&"stage_size", stage_size)
	_head_material.set_shader_parameter(&"slot_capacity", float(CAPACITY))
	_head_material.set_shader_parameter(&"occupancy_flip_y", occupancy_flip_y)
	_head_material.set_shader_parameter(&"upstream_speed_pixels", upstream_speed_pixels)
	_head_material.set_shader_parameter(&"speed_variation", speed_variation)
	_head_material.set_shader_parameter(&"velocity_response", velocity_response)
	_head_material.set_shader_parameter(&"noise_strength", noise_strength)
	_head_material.set_shader_parameter(&"noise_scale", noise_scale)
	_head_material.set_shader_parameter(&"noise_speed", noise_speed)
	_head_material.set_shader_parameter(&"stage_phase", stage_phase)
	_head_material.set_shader_parameter(&"water_alpha_threshold", water_alpha_threshold)
	_head_material.set_shader_parameter(&"water_lookahead_pixels", water_lookahead_pixels)
	_head_material.set_shader_parameter(
		&"water_contact_half_height_pixels",
		water_contact_half_height_pixels
	)
	_head_material.set_shader_parameter(
		&"water_steering_strength", water_steering_strength
	)
	_head_material.set_shader_parameter(
		&"spawn_search_width_pixels", spawn_search_width_pixels
	)
	_head_material.set_shader_parameter(
		&"spawn_search_half_height_pixels",
		spawn_search_half_height_pixels
	)
	_head_material.set_shader_parameter(&"streak_length_pixels", streak_length_pixels)
	_head_material.set_shader_parameter(&"streak_width_pixels", streak_width_pixels)
	_head_material.set_shader_parameter(&"fade_seconds", fade_seconds)
	_head_material.set_shader_parameter(&"salmon_alpha", salmon_alpha)
	_head_material.set_shader_parameter(
		&"segment_max_length_pixels", segment_max_length_pixels
	)
	_apply_water_texture()

	if _segment_particles != null:
		_segment_particles.fixed_fps = simulation_fps
		_segment_particles.z_index = salmon_z_index
		_segment_particles.lifetime = _trail_lifetime_seconds()
		var desired_capacity := _required_segment_capacity()
		if _segment_particles.amount != desired_capacity:
			_segment_particles.amount = desired_capacity
	if _segment_process_material != null:
		_segment_process_material.set_shader_parameter(
			&"trail_lifetime_seconds", _trail_lifetime_seconds()
		)
	if _segment_draw_material != null:
		_segment_draw_material.set_shader_parameter(
			&"trail_lifetime_seconds", _trail_lifetime_seconds()
		)
		_segment_draw_material.set_shader_parameter(
			&"segment_sample_seconds",
			1.0 / float(maxi(simulation_fps, 1))
		)


func _apply_water_texture() -> void:
	if _head_material == null:
		return
	var texture := _supplied_water_texture
	if texture == null:
		texture = _empty_water_texture
	_head_material.set_shader_parameter(&"water_occupancy_texture", texture)


func _required_segment_capacity() -> int:
	return maxi(
		ceili(
			float(CAPACITY)
			* float(maxi(simulation_fps, 1))
			* _trail_lifetime_seconds()
			* SEGMENT_CAPACITY_MARGIN
		),
		64
	)


func _trail_lifetime_seconds() -> float:
	# Spatial trail length is independent of the no-water latch fade. One fixed
	# simulation tick is the minimum useful immutable history.
	return maxf(
		streak_length_pixels / maxf(upstream_speed_pixels, 1.0),
		1.0 / float(maxi(simulation_fps, 1))
	)


func _make_white_ribbon_texture() -> ImageTexture:
	var image := Image.create(1, 8, false, Image.FORMAT_RGBA8)
	image.fill(Color.WHITE)
	return ImageTexture.create_from_image(image)


func _make_transparent_texture() -> ImageTexture:
	var image := Image.create(1, 1, false, Image.FORMAT_RGBA8)
	image.fill(Color(0.0, 0.0, 0.0, 0.0))
	return ImageTexture.create_from_image(image)


func _variant_to_vector2(value: Variant, fallback: Vector2) -> Vector2:
	if value is Vector2:
		var vector_value: Vector2 = value
		return vector_value
	if value is Vector2i:
		return Vector2(value)
	if value is Array:
		var array_value: Array = value
		if array_value.size() >= 2:
			return Vector2(float(array_value[0]), float(array_value[1]))
	if value is Dictionary:
		var dictionary_value: Dictionary = value
		if dictionary_value.has("x") and dictionary_value.has("y"):
			return Vector2(
				float(dictionary_value["x"]),
				float(dictionary_value["y"])
			)
	return fallback
