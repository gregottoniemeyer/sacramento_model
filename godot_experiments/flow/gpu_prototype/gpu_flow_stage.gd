extends Node2D

const PARTICLE_SHADER := preload(
	"res://flow/gpu_prototype/gpu_flow_particle.gdshader"
)
const SEGMENT_PARTICLE_SHADER := preload(
	"res://flow/gpu_prototype/gpu_flow_segment_particle.gdshader"
)
const HEAD_DRAW_SHADER := preload(
	"res://flow/gpu_prototype/gpu_flow_head_draw.gdshader"
)
const DRAW_SHADER := preload("res://flow/gpu_prototype/gpu_flow_draw.gdshader")
const OVERLAY_SCRIPT := preload("res://flow/gpu_prototype/gpu_flow_overlay.gd")
const STAGE_SIZE := Vector2(1920.0, 1080.0)
const PARTICLE_COUNT := 300
const ACTIVE_HEAD_RATIO := 0.5
const PARTICLE_FIXED_FPS := 0
const TRAIL_LIFETIME_SECONDS := 2.0
const TRAIL_SEGMENT_CAPACITY := 22500
const TRAIL_PREWARM_GUARD_FRAMES := 2
const RESERVOIR_CENTER := Vector2(1388.57, 771.43)
const RESERVOIR_RADIUS := 223.71
const MIN_GATE_HALF_WIDTH := 3.0
const MAX_GATE_HALF_WIDTH := RESERVOIR_RADIUS
const INTERACTION_TEXTURE_WIDTH := 128

var stage_index: int = 0
var particles: GPUParticles2D
var gate_open: bool = true
var gate_half_width: float = 15.0
var _process_material: ShaderMaterial
var _trail_segments: GPUParticles2D
var _trail_process_material: ShaderMaterial
var _head_draw_material: ShaderMaterial
var _draw_material: ShaderMaterial
var _overlay: Node2D
var _interaction_data_texture: ImageTexture
var _trail_recording_warmup_frames: int = 0


func _ready() -> void:
	_build_particles()
	_build_overlay()
	queue_redraw()


func _process(_delta: float) -> void:
	if _trail_recording_warmup_frames <= 0:
		return
	_trail_recording_warmup_frames -= 1
	if _trail_recording_warmup_frames == 0 and _process_material != null:
		_process_material.set_shader_parameter(&"trail_recording_enabled", true)
		_process_material.set_shader_parameter(&"reservoir_admission_enabled", true)
		_process_material.set_shader_parameter(&"interaction_admission_enabled", true)


func set_gate_open(value: bool) -> void:
	gate_open = value
	if _process_material != null:
		_process_material.set_shader_parameter(&"gate_open", gate_open)
	if _overlay != null:
		_overlay.call(&"set_gate_open", gate_open)


func toggle_gate() -> void:
	set_gate_open(not gate_open)


func set_gate_half_width(value: float) -> void:
	gate_half_width = clampf(value, MIN_GATE_HALF_WIDTH, MAX_GATE_HALF_WIDTH)
	if _process_material != null:
		_process_material.set_shader_parameter(&"gate_half_width", gate_half_width)
	if _overlay != null:
		_overlay.call(&"set_gate_half_width", gate_half_width)


func adjust_gate_half_width(delta: float) -> void:
	set_gate_half_width(gate_half_width + delta)


func set_paused(value: bool) -> void:
	if particles != null:
		particles.speed_scale = 0.0 if value else 1.0
	if _trail_segments != null:
		_trail_segments.speed_scale = 0.0 if value else 1.0


func runtime_summary() -> Dictionary:
	if particles == null:
		return {}
	return {
		"stage_index": stage_index,
		"amount": particles.amount,
		"amount_ratio": particles.amount_ratio,
		"active_heads_approx": roundi(particles.amount * particles.amount_ratio),
		"fixed_fps": particles.fixed_fps,
		"interpolate": particles.interpolate,
		"trail_enabled": particles.trail_enabled,
		"trail_lifetime": TRAIL_LIFETIME_SECONDS,
		"trail_mode": "immutable_gpu_segments",
		"trail_segment_capacity": (
			_trail_segments.amount if _trail_segments != null else 0
		),
		"trail_segment_native_trail_enabled": (
			_trail_segments.trail_enabled if _trail_segments != null else false
		),
		"trail_segment_autonomous_emission": (
			_trail_segments.emitting if _trail_segments != null else true
		),
		"trail_segment_lifetime": (
			_trail_segments.lifetime if _trail_segments != null else 0.0
		),
		"trail_segment_lifetime_uniform": (
			_trail_process_material.get_shader_parameter(&"segment_lifetime_seconds")
			if _trail_process_material != null
			else 0.0
		),
		"trail_segment_fixed_fps": (
			_trail_segments.fixed_fps if _trail_segments != null else 0
		),
		"trail_segment_interpolate": (
			_trail_segments.interpolate if _trail_segments != null else true
		),
		"trail_segment_fract_delta": (
			_trail_segments.fract_delta if _trail_segments != null else true
		),
		"trail_segment_process_shader_matches": (
			_trail_process_material != null
			and _trail_process_material.shader == SEGMENT_PARTICLE_SHADER
		),
		"trail_draw_shader_matches": (
			_draw_material != null and _draw_material.shader == DRAW_SHADER
		),
		"trail_segment_texture_size": (
			_trail_segments.texture.get_size()
			if _trail_segments != null and _trail_segments.texture != null
			else Vector2.ZERO
		),
		"heads_hidden": (
			_head_draw_material != null
			and _head_draw_material.shader == HEAD_DRAW_SHADER
		),
		"trail_recording_enabled_uniform": (
			_process_material.get_shader_parameter(&"trail_recording_enabled")
			if _process_material != null
			else false
		),
		"reservoir_admission_enabled_uniform": (
			_process_material.get_shader_parameter(&"reservoir_admission_enabled")
			if _process_material != null
			else false
		),
		"head_texture_size": (
			particles.texture.get_size()
			if particles.texture != null
			else Vector2.ZERO
		),
		"head_speed_scale": particles.speed_scale,
		"trail_segment_speed_scale": (
			_trail_segments.speed_scale if _trail_segments != null else -1.0
		),
		"gate_open": gate_open,
		"gate_uniform": _process_material.get_shader_parameter(&"gate_open"),
		"gate_half_width": gate_half_width,
		"gate_half_width_uniform": _process_material.get_shader_parameter(&"gate_half_width"),
		"shader_uniform_count": PARTICLE_SHADER.get_shader_uniform_list().size(),
		"interaction_count_uniform": _process_material.get_shader_parameter(
			&"interaction_count"
		),
		"interaction_admission_enabled_uniform": (
			_process_material.get_shader_parameter(&"interaction_admission_enabled")
		),
		"interaction_data_texture_bound": (
			_process_material.get_shader_parameter(&"interaction_data_texture") != null
		),
	}


func _build_particles() -> void:
	_process_material = ShaderMaterial.new()
	_process_material.shader = PARTICLE_SHADER
	_process_material.set_shader_parameter(&"trail_recording_enabled", false)
	_process_material.set_shader_parameter(&"reservoir_admission_enabled", false)
	_process_material.set_shader_parameter(&"interaction_admission_enabled", false)
	_process_material.set_shader_parameter(&"interaction_count", 0)
	var interaction_image := Image.create(
		INTERACTION_TEXTURE_WIDTH,
		1,
		false,
		Image.FORMAT_RGBAF
	)
	interaction_image.fill(Color(0.0, 0.0, 0.0, 0.0))
	_interaction_data_texture = ImageTexture.create_from_image(interaction_image)
	_process_material.set_shader_parameter(
		&"interaction_data_texture",
		_interaction_data_texture
	)
	_trail_recording_warmup_frames = TRAIL_PREWARM_GUARD_FRAMES
	_process_material.set_shader_parameter(&"particle_slot_count", float(PARTICLE_COUNT))
	_process_material.set_shader_parameter(&"stage_phase", float(stage_index) * 1.731)
	_process_material.set_shader_parameter(&"velocity_response", 12.0)
	_process_material.set_shader_parameter(&"reservoir_entry_min_incidence", 0.50)
	_process_material.set_shader_parameter(&"reservoir_entry_pull_strength", 3.50)
	_process_material.set_shader_parameter(
		&"reservoir_entry_min_inward_speed_ratio", 0.30
	)
	_process_material.set_shader_parameter(
		&"reservoir_gate_staging_radius_ratio", 0.86
	)
	_process_material.set_shader_parameter(&"reservoir_orbit_radius_min_ratio", 0.05)
	_process_material.set_shader_parameter(&"reservoir_orbit_radius_max_ratio", 0.78)
	_process_material.set_shader_parameter(&"reservoir_orbit_full_speed_ratio", 0.46)
	_process_material.set_shader_parameter(&"reservoir_orbit_max_angular_speed", 1.50)
	_process_material.set_shader_parameter(&"gate_open", gate_open)
	_process_material.set_shader_parameter(&"gate_half_width", gate_half_width)
	_process_material.set_shader_parameter(
		&"trail_lifetime_seconds", TRAIL_LIFETIME_SECONDS
	)
	_process_material.set_shader_parameter(&"trail_segment_overlap_pixels", 0.0)
	_process_material.set_shader_parameter(
		&"trail_segment_max_length_pixels", 96.0
	)

	# Each child particle is one immutable completed motion sample. Size for all
	# 300 possible heads, not only the current 0.5 ratio, so runtime ratio changes
	# cannot reallocate the child pool while older samples are still visible.
	_trail_segments = GPUParticles2D.new()
	_trail_segments.name = "FlowLineTrailSegments"
	# The parent heads alone populate this sub-emitter pool. Autonomous emission
	# would consume the same slots and leave stationary one-sample trail gaps.
	_trail_segments.emitting = false
	_trail_segments.amount = TRAIL_SEGMENT_CAPACITY
	_trail_segments.amount_ratio = 1.0
	_trail_segments.lifetime = TRAIL_LIFETIME_SECONDS
	_trail_segments.preprocess = 0.0
	# The project render loop supplies the 30 FPS cap. Render-paced head/child
	# updates avoid multiple fixed-step parent batches competing in one frame.
	_trail_segments.fixed_fps = PARTICLE_FIXED_FPS
	_trail_segments.interpolate = false
	_trail_segments.fract_delta = false
	_trail_segments.randomness = 0.0
	_trail_segments.explosiveness = 0.0
	_trail_segments.local_coords = true
	_trail_segments.use_fixed_seed = true
	_trail_segments.seed = 9301 + stage_index * 997
	_trail_segments.visibility_rect = Rect2(
		Vector2(-256.0, -256.0),
		STAGE_SIZE + Vector2(512.0, 512.0)
	)
	_trail_segments.trail_enabled = false
	_trail_process_material = ShaderMaterial.new()
	_trail_process_material.shader = SEGMENT_PARTICLE_SHADER
	_trail_process_material.set_shader_parameter(
		&"segment_lifetime_seconds", TRAIL_LIFETIME_SECONDS
	)
	_trail_segments.process_material = _trail_process_material
	_draw_material = ShaderMaterial.new()
	_draw_material.shader = DRAW_SHADER
	_draw_material.set_shader_parameter(
		&"trail_lifetime_seconds", TRAIL_LIFETIME_SECONDS
	)
	_trail_segments.material = _draw_material
	_trail_segments.texture = _make_segment_texture()
	_trail_segments.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_trail_segments.z_index = 0
	add_child(_trail_segments)

	particles = GPUParticles2D.new()
	particles.name = "FlowLineHeads"
	particles.amount = PARTICLE_COUNT
	particles.amount_ratio = ACTIVE_HEAD_RATIO
	particles.lifetime = 8.0
	particles.preprocess = 8.0
	particles.fixed_fps = PARTICLE_FIXED_FPS
	particles.interpolate = true
	particles.fract_delta = false
	particles.randomness = 0.0
	particles.explosiveness = 0.0
	particles.local_coords = true
	particles.use_fixed_seed = true
	particles.seed = 7301 + stage_index * 997
	particles.visibility_rect = Rect2(Vector2(-256.0, -256.0), STAGE_SIZE + Vector2(512.0, 512.0))
	particles.trail_enabled = false
	particles.process_material = _process_material
	_head_draw_material = ShaderMaterial.new()
	_head_draw_material.shader = HEAD_DRAW_SHADER
	particles.material = _head_draw_material
	particles.texture = _make_head_texture()
	particles.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	particles.z_index = 1
	add_child(particles)
	particles.sub_emitter = particles.get_path_to(_trail_segments)


func _build_overlay() -> void:
	_overlay = OVERLAY_SCRIPT.new() as Node2D
	_overlay.name = "ReservoirAndStatusOverlay"
	_overlay.z_index = 100
	_overlay.z_as_relative = false
	_overlay.set(&"stage_index", stage_index)
	_overlay.set(&"gate_open", gate_open)
	_overlay.set(&"gate_half_width", gate_half_width)
	add_child(_overlay)


func _make_segment_texture() -> ImageTexture:
	# The emitted transform supplies length along this one-pixel motion axis;
	# the draw shader derives line width inside the eight-pixel envelope.
	var image := Image.create(1, 8, false, Image.FORMAT_RGBA8)
	image.fill(Color.WHITE)
	return ImageTexture.create_from_image(image)


func _make_head_texture() -> ImageTexture:
	var image := Image.create(1, 1, false, Image.FORMAT_RGBA8)
	image.fill(Color.WHITE)
	return ImageTexture.create_from_image(image)


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, STAGE_SIZE), Color("05090d"), true)
