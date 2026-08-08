extends Node2D
class_name GPUFlowStage2D

## One native 1920 x 1080 GPU flow stage.
##
## The particle shader and draw shader remain shared with the feasibility
## prototype. This node adds production-scene identity, controller-compatible
## gate methods, keyboard controls, and a compact runtime inspection API.

signal gate_changed(
	screen_id: StringName,
	reservoir_id: StringName,
	gate_open: bool,
	outlet_width: float
)
signal pause_changed(screen_id: StringName, paused: bool)
signal debug_visibility_changed(screen_id: StringName, visible: bool)
signal stage_title_changed(screen_id: StringName, title: String, visible: bool)
signal model_date_changed(
	screen_id: StringName,
	date_mm_dd: String,
	day_of_year: int
)
signal watershed_data_row_changed(
	screen_id: StringName,
	row_index: int,
	row_count: int,
	raw_value: float,
	normalized_flow: float,
	scaled_flow: float,
	high_variation: bool,
	model_date_time: String
)
signal interaction_geometry_changed(screen_id: StringName, polygon_count: int)
signal source_geometry_changed(screen_id: StringName, source_count: int)
signal salmon_released(
	screen_id: StringName,
	requested_count: int,
	scheduled_count: int,
	release_serial: int
)
signal leaves_released(
	screen_id: StringName,
	requested_count_per_side: int,
	scheduled_top_count: int,
	scheduled_bottom_count: int,
	scheduled_total_count: int,
	release_serial: int
)

const PARTICLE_SHADER := preload(
	"res://flow/gpu_prototype/gpu_flow_particle.gdshader"
)
const SEGMENT_PARTICLE_SHADER := preload(
	"res://flow/gpu_prototype/gpu_flow_segment_particle.gdshader"
)
const HEAD_DRAW_SHADER := preload(
	"res://flow/gpu_prototype/gpu_flow_head_draw.gdshader"
)
const DRAW_SHADER := preload(
	"res://flow/gpu_prototype/gpu_flow_draw.gdshader"
)
const OVERLAY_SCRIPT := preload(
	"res://flow/gpu_prototype/gpu_flow_overlay.gd"
)
const WATER_COMPOSITE_SHADER := preload(
	"res://flow/gpu_stage/gpu_water_composite.gdshader"
)
const SALMON_SCRIPT := preload(
	"res://flow/gpu_stage/gpu_salmon_2d.gd"
)
const LEAF_SCRIPT := preload(
	"res://flow/gpu_stage/gpu_leaf_2d.gd"
)
const GPUFlowInteractionPolygon = preload(
	"res://flow/gpu_stage/gpu_flow_interaction_polygon.gd"
)
const GPUFlowSourcePolygon = preload(
	"res://flow/gpu_stage/gpu_flow_source_polygon.gd"
)
const SOURCE_TEXTURE_PACKER_SCRIPT := preload(
	"res://flow/gpu_stage/gpu_flow_source_texture_packer.gd"
)
const STAGE_TITLE_FONT := preload(
	"res://flow/assets/fonts/BarlowCondensed-Medium.ttf"
)

const STAGE_SIZE := Vector2(1920.0, 1080.0)
const WORLD_SIZE := Vector2(16.0, 9.0)
const PIXELS_PER_WORLD_UNIT := STAGE_SIZE.x / WORLD_SIZE.x
const PARTICLE_FIXED_FPS := 0
const TRAIL_SEGMENT_BUDGET_FPS := 30
const TRAIL_SEGMENT_CAPACITY_MARGIN := 1.25
const TRAIL_PREWARM_GUARD_FRAMES := 2
const PALETTE_LAYER_COUNT := 7
const FLOW_PALETTE := [
	Color(1.0, 1.0, 1.0, 1.0),
	Color(0.918, 0.969, 0.933, 1.0),
	Color(0.827, 0.937, 0.863, 1.0),
	Color(0.675, 0.882, 0.686, 1.0),
	Color(0.482, 0.812, 0.769, 1.0),
	Color(0.290, 0.690, 0.882, 1.0),
	Color(0.118, 0.565, 1.0, 1.0),
]
const MAX_PENDING_CONTROL_MESSAGES := 256
const RESERVOIR_ID := &"reservoir_main"
const MIN_GATE_WIDTH := 0.0
const MAX_GATE_WIDTH := 10.0
const DEFAULT_MAX_FLOW_SPEED_PIXELS := 600.0
const MAX_INTERACTION_POLYGONS := 8
const INTERACTION_TEXELS_PER_POLYGON := 16
const INTERACTION_TEXTURE_WIDTH := (
	MAX_INTERACTION_POLYGONS * INTERACTION_TEXELS_PER_POLYGON
)
const MAX_SOURCE_POLYGONS := 8
const STAGE_TITLE_POSITION := Vector2(40.0, 40.0)
const STAGE_TITLE_COLOR := Color("4ab0e1")
const STAGE_TITLE_FONT_SIZE := 40
const MODEL_DATE_POSITION := Vector2(40.0, 980.0)
const MODEL_DATE_LABEL_SIZE := Vector2(300.0, 72.0)
const MODEL_CALENDAR_DAY_COUNT := 365
const MODEL_MINUTES_PER_DAY := 1440
const MODEL_YEAR_MINUTE_COUNT := MODEL_CALENDAR_DAY_COUNT * MODEL_MINUTES_PER_DAY
const MODEL_YEAR_FRAMES_AT_30_FPS := 21600
const MODEL_MONTH_LENGTHS := [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
const BACKGROUND_Z_INDEX := -100
const BACKGROUND_GRID_Z_INDEX := -75
const STAGE_TITLE_Z_INDEX := -50
const DEFAULT_GRID_COLOR := Color(
	74.0 / 255.0,
	176.0 / 255.0,
	225.0 / 255.0,
	0.75
)

@export_group("Identity")
@export var stage_index: int = 0:
	set(value):
		stage_index = maxi(value, 0)
		_apply_identity()
@export var model_id: StringName = &"gpu_flow_model"
@export var screen_id: StringName = &"screen"
@export var control_target: StringName = &""
@export var stage_title: String = "":
	set(value):
		stage_title = value
		_apply_stage_title()
@export var stage_title_visible: bool = true:
	set(value):
		stage_title_visible = value
		_apply_stage_title()

@export_group("Presentation")
@export var stage_grid_visible: bool = true:
	set(value):
		stage_grid_visible = value
		_apply_background_grid()
@export_range(1.0, 960.0, 1.0) var stage_grid_spacing_pixels: float = 120.0:
	set(value):
		stage_grid_spacing_pixels = maxf(value, 1.0)
		_rebuild_background_grid()
@export_range(0.1, 8.0, 0.1) var stage_grid_line_width_pixels: float = 1.0:
	set(value):
		stage_grid_line_width_pixels = maxf(value, 0.1)
		_rebuild_background_grid()
@export var stage_grid_color: Color = DEFAULT_GRID_COLOR:
	set(value):
		stage_grid_color = value
		_rebuild_background_grid()
@export var stage_date_visible: bool = true:
	set(value):
		stage_date_visible = value
		_apply_model_date(false)
@export_range(1.0, 86400.0, 1.0) var model_year_duration_seconds: float = 720.0
@export_range(0, MODEL_CALENDAR_DAY_COUNT - 1, 1) var model_start_day_index: int = 0
@export var model_calendar_auto_advance: bool = true

@export_group("Watershed Data")
@export_file("*.txt") var watershed_data_path: String = ""
@export var watershed_data_drives_flow_rate: bool = true
@export var watershed_interpolate_flow_rate: bool = true

@export_group("Runtime")
@export var auto_start: bool = true
@export var accept_keyboard_input: bool = true
@export var debug_visible: bool = true:
	set(value):
		debug_visible = value
		_apply_debug_visibility()

@export_group("Particles")
@export_range(1, 2000, 1) var particle_slots: int = 300
@export_range(0.0, 1.0, 0.01) var flow_rate: float = 0.5
@export_range(1.0, 2400.0, 1.0) var flow_speed_pixels: float = DEFAULT_MAX_FLOW_SPEED_PIXELS
@export_range(0.000001, 1.0, 0.000001) var min_active_flow: float = 0.001
@export_range(0.0, 1.0, 0.01) var speed_variation: float = 0.14
@export_range(0.0, 30.0, 0.1) var velocity_response: float = 12.0
@export_range(0.0, 300.0, 1.0) var noise_strength: float = 52.0
@export_range(0.0001, 0.1, 0.0001) var noise_scale: float = 0.010
@export_range(0.0, 10.0, 0.01) var noise_speed: float = 0.72
@export_range(0.1, 8.0, 0.1) var trail_lifetime: float = 2.0
@export_range(1.0, 5.0, 0.1) var line_width_min: float = 1.0
@export_range(1.0, 5.0, 0.1) var line_width_max: float = 5.0
@export_range(0.0, 4.0, 0.1) var trail_segment_overlap_pixels: float = 0.0
@export_range(8.0, 256.0, 1.0) var trail_segment_max_length_pixels: float = 96.0
@export_range(0.0, 1.0, 0.01) var particle_alpha: float = 0.94
@export var background_color: Color = Color("05090d"):
	set(value):
		background_color = value
		_apply_background_color()

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
		# Preserve the controller's raw request separately. If the same atomic update
		# later enlarges the reservoir, its wider aperture must not have been lost by
		# clamping against the old radius first.
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
@export var install_default_interaction_examples: bool = true
@export var interaction_polygons: Array[GPUFlowInteractionPolygon] = []

@export_group("Water Sources")
@export var install_default_source_examples: bool = true
@export var source_polygons: Array[GPUFlowSourcePolygon] = []

@export_group("Salmon")
@export var salmon_enabled: bool = true
@export_range(1, 300, 1) var salmon_per_release: int = 25
@export_range(1.0, 600.0, 1.0) var salmon_min_speed_pixels: float = 60.0
@export_range(0.0, 1.0, 0.001) var salmon_water_alpha_threshold: float = 0.001
@export_range(1.0, 960.0, 1.0) var salmon_contact_width_pixels: float = 240.0
@export_range(1.0, 240.0, 1.0) var salmon_contact_height_pixels: float = 24.0
@export_range(0.0, 30.0, 0.1) var salmon_water_steering_strength: float = 5.0
@export var salmon_occupancy_flip_y: bool = false
@export_range(8.0, 160.0, 1.0) var salmon_trail_length_pixels: float = 100.0
@export_range(1.0, 5.0, 0.1) var salmon_line_width_pixels: float = 3.0
@export_range(0.05, 4.0, 0.05) var salmon_fade_seconds: float = 0.50
@export_range(0.0, 1.0, 0.01) var salmon_alpha: float = 1.0

@export_group("Leaves")
@export var leaves_enabled: bool = true
@export_range(1, 150, 1) var leaves_per_side: int = 15
@export_range(0.0, 2.0, 0.001) var leaf_release_stagger_interval_seconds: float = 0.20
@export_range(1.0, 2400.0, 1.0) var leaf_free_speed_pixels: float = 120.0
@export_range(1.0, 2400.0, 1.0) var leaf_flow_speed_pixels: float = 300.0
@export_range(0.0, 1.0, 0.01) var leaf_speed_variation: float = 0.0
@export_range(0.0, 30.0, 0.1) var leaf_velocity_response: float = 8.0
@export_range(0.0, 120.0, 1.0) var leaf_sway_amplitude_min_pixels: float = 2.0
@export_range(0.0, 120.0, 1.0) var leaf_sway_amplitude_max_pixels: float = 6.0
@export_range(0.1, 10.0, 0.1) var leaf_sway_period_min_seconds: float = 1.2
@export_range(0.1, 10.0, 0.1) var leaf_sway_period_max_seconds: float = 2.8
@export_range(1.0, 480.0, 1.0) var leaf_free_water_search_radius_pixels: float = 120.0
@export_range(0.0, 1.0, 0.01) var leaf_free_water_steering_strength: float = 0.35
@export_range(1.0, 4096.0, 1.0) var leaf_free_search_max_distance_pixels: float = 256.0
@export_range(0.05, 4.0, 0.05) var leaf_stopped_fade_seconds: float = 0.50
@export_range(0.0, 1.0, 0.001) var leaf_water_alpha_threshold: float = 0.001
@export_range(1.0, 120.0, 1.0) var leaf_contact_radius_pixels: float = 12.0
@export_range(1.0, 240.0, 1.0) var leaf_follow_probe_min_pixels: float = 8.0
@export_range(1.0, 480.0, 1.0) var leaf_follow_probe_max_pixels: float = 56.0
@export_range(1.0, 80.0, 1.0) var leaf_follow_turn_degrees: float = 35.0
@export_range(0.01, 1.0, 0.001) var leaf_follow_resample_interval_seconds: float = 0.12
@export var leaf_occupancy_flip_y: bool = false
## Disk diameter; `leaves.disk_radius_pixels` is the canonical runtime alias.
@export_range(1.0, 10.0, 0.1) var leaf_line_width_pixels: float = 10.0
## Radius/diameter growth above the base, exposed as `leaves.radius_variation`.
@export_range(0.0, 1.0, 0.01) var leaf_line_width_variation: float = 1.0
@export_range(0.0, 1.0, 0.01) var leaf_alpha: float = 1.0

var particles: GPUParticles2D
var _trail_segments: GPUParticles2D
var _process_material: ShaderMaterial
var _trail_process_material: ShaderMaterial
var _draw_material: ShaderMaterial
var _head_layers: Array[GPUParticles2D] = []
var _trail_segment_layers: Array[GPUParticles2D] = []
var _process_material_layers: Array[ShaderMaterial] = []
var _trail_process_material_layers: Array[ShaderMaterial] = []
var _draw_material_layers: Array[ShaderMaterial] = []
var _overlay: Node2D
var _background_rect: ColorRect
var _background_grid: Node2D
var _stage_title_layer: Node2D
var _stage_title_label: Label
var _model_date_label: Label
var _water_viewport: SubViewport
var _water_canvas: Node2D
var _salmon_school: GPUSalmon2D
var _leaf_field: GPULeaf2D
var _interaction_data_texture: ImageTexture
var _source_texture_packer: GPUFlowSourceTexturePacker
var _source_data_texture: ImageTexture
var _source_geometry_batch_depth: int = 0
var _source_geometry_dirty: bool = false
var _paused: bool = false
var _pending_messages: Array[Dictionary] = []
var _trail_recording_warmup_frames: int = 0
var _model_year_elapsed_seconds: float = 0.0
var _model_day_index: int = 0
var _model_minute_of_day: int = 0
var _model_date_source: StringName = &"internal_clock"
var _watershed_raw_values := PackedFloat32Array()
var _watershed_normalized_flow := PackedFloat32Array()
var _watershed_scaled_flow := PackedFloat32Array()
var _watershed_high_variation := PackedByteArray()
var _watershed_data_river: String = ""
var _watershed_data_error: String = ""
var _watershed_row_index: int = -1
var _watershed_row_fraction: float = 0.0
var _watershed_interpolated_flow_rate: float = 0.0


func _ready() -> void:
	add_to_group(&"flow_models")
	_install_default_interaction_polygons_if_needed()
	_install_default_source_polygons_if_needed()
	_source_texture_packer = SOURCE_TEXTURE_PACKER_SCRIPT.new(
		STAGE_SIZE,
		WORLD_SIZE
	)
	_source_data_texture = _source_texture_packer.get_texture()
	_load_watershed_data()
	_build_background()
	_build_background_grid()
	_build_water_render_surface()
	_build_particles()
	_build_salmon()
	_build_leaves()
	_build_overlay()
	_build_stage_title()
	_bind_interaction_polygon_signals()
	_bind_source_polygon_signals()
	_apply_identity()
	_apply_runtime_parameters()
	_apply_interaction_geometry()
	_apply_source_geometry()
	_apply_gate()
	_apply_debug_visibility()
	_apply_stage_title()
	_reset_model_calendar()
	set_paused(not auto_start)


func _process(delta: float) -> void:
	_advance_model_calendar(delta)
	if _trail_recording_warmup_frames > 0:
		_trail_recording_warmup_frames -= 1
		if _trail_recording_warmup_frames == 0:
			for process_material in _process_material_layers:
				process_material.set_shader_parameter(
					&"trail_recording_enabled", true
				)
				process_material.set_shader_parameter(
					&"reservoir_admission_enabled", true
				)
				process_material.set_shader_parameter(
					&"interaction_admission_enabled", true
				)
	if _pending_messages.is_empty():
		return
	# Swap the queue in O(1) so a controller burst never pays Array.pop_front()
	# shifts for every packet. Messages arriving during application wait for the
	# next frame boundary.
	var messages := _pending_messages
	_pending_messages = []
	for message in messages:
		_apply_control_message(message)


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
		KEY_L:
			release_leaves()
		_:
			return
	get_viewport().set_input_as_handled()


func accepts_control_target(target: String) -> bool:
	return (
		target == "*"
		or target == String(screen_id)
		or target == String(model_id)
		or (not control_target.is_empty() and target == String(control_target))
		or target == name
		or is_in_group(StringName(target))
	)


func get_control_target() -> StringName:
	return control_target


func get_model_id() -> StringName:
	return model_id


func get_screen_id() -> StringName:
	return screen_id


func get_native_size() -> Vector2:
	return STAGE_SIZE


func queue_control_message(message: Dictionary) -> void:
	if _pending_messages.size() >= MAX_PENDING_CONTROL_MESSAGES:
		# Preserve recent control state under pathological packet bursts. The bus
		# already coalesces unchanged legacy chair packets; this cap protects
		# modern-protocol senders that do not.
		_pending_messages.remove_at(0)
	_pending_messages.append(message.duplicate(true))


func set_gate_open(reservoir_or_value: Variant, value: Variant = null) -> void:
	# Supports set_gate_open(true) and the CPU-compatible
	# set_gate_open(&"reservoir_main", true).
	gate_open = bool(reservoir_or_value if value == null else value)


func set_flow_rate(value: float) -> void:
	# A direct keyboard/API rate is an intentional manual override. The data
	# timeline can be resumed through `watershed.drives_flow_rate = true`.
	watershed_data_drives_flow_rate = false
	flow_rate = clampf(value, 0.0, 1.0)
	# Digit keys and direct water-rate calls must not rebuild or retune either
	# ecology system. Salmon and leaves still react naturally to the resulting
	# water-only occupancy image, but their release generations, speeds, and
	# immutable segment pools remain untouched.
	_apply_water_rate_parameters()


func set_gate_width(reservoir_or_width: Variant, value: Variant = null) -> void:
	# Width is the full opening in 16 x 9 world units. At native resolution,
	# 0.25 units is 30 px (15 px on either side of the outlet center).
	gate_width = float(reservoir_or_width if value == null else value)


func set_gate_half_width(value_pixels: float) -> void:
	# Legacy helper retained for code written against gpu_prototype.
	gate_width = value_pixels * 2.0 / PIXELS_PER_WORLD_UNIT


func adjust_gate_width(delta_world_units: float) -> void:
	gate_width += delta_world_units


func adjust_gate_half_width(delta_pixels: float) -> void:
	set_gate_half_width(get_gate_half_width_pixels() + delta_pixels)


func get_gate_half_width_pixels() -> float:
	return minf(
		gate_width * PIXELS_PER_WORLD_UNIT * 0.5,
		maxf(reservoir_radius_pixels, 0.001)
	)


func get_full_gate_width_world_units() -> float:
	## The widest meaningful opening is the reservoir diameter. This keeps the
	## keyboard and controller maximum aligned with release probability 1.0.
	return maxf(
		reservoir_radius_pixels * 2.0 / PIXELS_PER_WORLD_UNIT,
		MIN_GATE_WIDTH
	)


func _refresh_gate_width_for_reservoir() -> void:
	# Re-evaluate the retained raw request after a resize. This makes a batched
	# radius+width update independent of dictionary/field order.
	gate_width = _requested_gate_width


func get_gate_aperture_fraction() -> float:
	return clampf(
		get_gate_half_width_pixels() / maxf(reservoir_radius_pixels, 0.001),
		0.0,
		1.0
	)


func get_effective_gate_release_probability() -> float:
	if not gate_open:
		return 0.0
	return get_gate_aperture_fraction()


func toggle_gate(_reservoir_id: StringName = RESERVOIR_ID) -> void:
	gate_open = not gate_open


func set_paused(value: bool) -> void:
	_paused = value
	for head_layer in _head_layers:
		head_layer.speed_scale = 0.0 if _paused else 1.0
	for segment_layer in _trail_segment_layers:
		segment_layer.speed_scale = 0.0 if _paused else 1.0
	if _salmon_school != null:
		_salmon_school.set_paused(_paused)
	if _leaf_field != null:
		_leaf_field.set_paused(_paused)
	if is_node_ready():
		pause_changed.emit(screen_id, _paused)


func is_paused() -> bool:
	return _paused


func set_debug_visible(value: bool) -> void:
	debug_visible = value


func toggle_debug_visibility() -> void:
	debug_visible = not debug_visible


func apply_runtime_parameters() -> void:
	## Re-applies exported flow and reservoir values after a controller changes
	## one or more properties directly.
	_apply_runtime_parameters()


func apply_interaction_polygons() -> void:
	## Re-upload exported polygon resources after direct runtime edits.
	_bind_interaction_polygon_signals()
	_apply_interaction_geometry()


func apply_source_polygons() -> void:
	## Re-upload exported source resources after direct runtime edits.
	_bind_source_polygon_signals()
	_source_geometry_dirty = false
	_apply_source_geometry()


func get_interaction_polygon(element_id: StringName) -> GPUFlowInteractionPolygon:
	return _find_interaction_polygon(element_id)


func get_source_polygon(element_id: StringName) -> GPUFlowSourcePolygon:
	return _find_source_polygon(element_id)


func release_salmon(count: int = -1) -> int:
	if not salmon_enabled or _salmon_school == null:
		return 0
	var requested := salmon_per_release if count < 0 else count
	if requested < 1 or requested > GPUSalmon2D.CAPACITY:
		return 0
	return _salmon_school.release_salmon(requested)


func release_leaves(count_per_side: int = -1) -> int:
	if not leaves_enabled or _leaf_field == null:
		return 0
	var requested := leaves_per_side if count_per_side < 0 else count_per_side
	if requested < 1 or requested > GPULeaf2D.MAX_PER_SIDE:
		return 0
	return _leaf_field.release_leaves(requested)


func set_model_date_mm_dd(model_date_time: String) -> bool:
	## Accepts MM/DD or MM/DD-HH:MM. A valid external value becomes
	## authoritative until the internal data clock is enabled again.
	var parsed_time := _parse_model_date_time(model_date_time)
	if parsed_time.x < 0:
		return false
	model_calendar_auto_advance = false
	_model_date_source = &"external_mm_dd"
	_model_day_index = parsed_time.x
	_model_minute_of_day = parsed_time.y
	_align_model_elapsed_to_current_day()
	_apply_model_date()
	_update_watershed_timeline()
	return true


func set_model_date_time(model_date_time: String) -> bool:
	return set_model_date_mm_dd(model_date_time)


func set_model_calendar_auto_advance(value: bool) -> void:
	model_calendar_auto_advance = value
	if model_calendar_auto_advance:
		_model_date_source = &"internal_clock"
		_align_model_elapsed_to_current_day()
	elif _model_date_source == &"internal_clock":
		_model_date_source = &"manual_hold"
	_apply_model_date(false)
	_update_watershed_timeline()


func reset_model_calendar() -> void:
	## Resets only the presentation calendar; water and ecology state are intact.
	_reset_model_calendar()


func get_current_watershed_data_row() -> Dictionary:
	if _watershed_row_index < 0 or _watershed_normalized_flow.is_empty():
		return {}
	return {
		"row_index": _watershed_row_index,
		"row_count": _watershed_normalized_flow.size(),
		"raw_value": float(_watershed_raw_values[_watershed_row_index]),
		"normalized_flow": float(
			_watershed_normalized_flow[_watershed_row_index]
		),
		"scaled_flow": float(_watershed_scaled_flow[_watershed_row_index]),
		"high_variation": bool(
			_watershed_high_variation[_watershed_row_index]
		),
		"interpolated_flow_rate": _watershed_interpolated_flow_rate,
		"row_fraction": _watershed_row_fraction,
		"model_date_time": _format_model_date_time(
			_model_day_index,
			_model_minute_of_day
		),
	}


func set_runtime_parameter(
	path: StringName,
	value: Variant,
	apply_immediately: bool = true
) -> bool:
	var path_string := String(path)
	# Presentation-only changes must never rebuild particle materials or ecology
	# pools. The setters update the screen-fixed label directly.
	match path_string:
		"stage.title", "stage_title":
			stage_title = String(value)
			return true
		"stage.title_visible", "stage_title_visible":
			stage_title_visible = bool(value)
			return true
		"stage.grid_visible", "stage_grid_visible":
			stage_grid_visible = bool(value)
			return true
		"stage.grid_spacing_pixels", "stage_grid_spacing_pixels":
			stage_grid_spacing_pixels = clampf(float(value), 1.0, 960.0)
			return true
		"stage.grid_line_width_pixels", "stage_grid_line_width_pixels":
			stage_grid_line_width_pixels = clampf(float(value), 0.1, 8.0)
			return true
		"stage.grid_color", "stage_grid_color":
			stage_grid_color = Color(value)
			return true
		"stage.date_visible", "stage_date_visible":
			stage_date_visible = bool(value)
			return true
		"stage.date", "calendar.date", "model_date":
			return set_model_date_mm_dd(String(value))
		"calendar.day_index", "model_day_index":
			var parsed_day_index := _strict_nonnegative_int(value)
			if parsed_day_index < 0 or parsed_day_index >= MODEL_CALENDAR_DAY_COUNT:
				return false
			model_calendar_auto_advance = false
			_model_date_source = &"external_day_index"
			_set_model_day_index(parsed_day_index)
			_align_model_elapsed_to_current_day()
			_update_watershed_timeline()
			return true
		"calendar.auto_advance", "model_calendar_auto_advance":
			set_model_calendar_auto_advance(bool(value))
			return true
		"calendar.year_duration_seconds", "model_year_duration_seconds":
			model_year_duration_seconds = clampf(float(value), 1.0, 86400.0)
			_align_model_elapsed_to_current_day()
			_update_watershed_timeline()
			return true
		"calendar.start_day_index", "model_start_day_index":
			var parsed_start_day := _strict_nonnegative_int(value)
			if parsed_start_day < 0 or parsed_start_day >= MODEL_CALENDAR_DAY_COUNT:
				return false
			model_start_day_index = parsed_start_day
			_reset_model_calendar()
			return true
		"watershed.data_path", "watershed_data_path":
			watershed_data_path = String(value)
			var data_loaded := _load_watershed_data()
			if data_loaded:
				_update_watershed_timeline()
			return data_loaded
		"watershed.drives_flow_rate", "watershed_data_drives_flow_rate":
			watershed_data_drives_flow_rate = bool(value)
			if watershed_data_drives_flow_rate:
				_update_watershed_timeline()
			return true
		"watershed.interpolate_flow_rate", "watershed_interpolate_flow_rate":
			watershed_interpolate_flow_rate = bool(value)
			_update_watershed_timeline()
			return true
	if _is_source_parameter_path(path_string):
		if not apply_immediately:
			_source_geometry_batch_depth += 1
		var source_changed := _set_source_parameter_by_path(path_string, value)
		if not apply_immediately:
			_source_geometry_batch_depth = maxi(
				_source_geometry_batch_depth - 1,
				0
			)
		return source_changed
	if _is_interaction_parameter_path(path_string):
		var interaction_changed := _set_interaction_parameter_by_path(
			path_string,
			value
		)
		if interaction_changed and apply_immediately:
			_apply_interaction_geometry()
		return interaction_changed
	match path_string:
		"flow_rate":
			watershed_data_drives_flow_rate = false
			flow_rate = clampf(float(value), 0.0, 1.0)
		"flow_speed_pixels", "base_speed":
			flow_speed_pixels = maxf(float(value), 1.0)
		"max_flow_speed":
			# CPU/controller units use 10 as the default maximum. Sixty native
			# pixels per unit preserves the prototype's 300 px/s at flow_rate 0.5.
			flow_speed_pixels = maxf(float(value) * 60.0, 1.0)
		"min_active_flow":
			min_active_flow = clampf(float(value), 0.000001, 1.0)
		"speed_variation":
			speed_variation = clampf(float(value), 0.0, 1.0)
		"velocity_response", "flow_velocity_response":
			velocity_response = clampf(float(value), 0.0, 30.0)
		"noise_strength":
			noise_strength = maxf(float(value), 0.0)
		"noise_scale":
			noise_scale = maxf(float(value), 0.0001)
		"noise_speed":
			noise_speed = maxf(float(value), 0.0)
		"trail_lifetime":
			trail_lifetime = clampf(float(value), 0.1, 8.0)
		"active_ratio":
			watershed_data_drives_flow_rate = false
			flow_rate = clampf(float(value), 0.0, 1.0)
		"line_width_min":
			line_width_min = clampf(float(value), 1.0, 5.0)
		"line_width_max":
			line_width_max = clampf(float(value), 1.0, 5.0)
		"trail_segment_overlap_pixels":
			trail_segment_overlap_pixels = clampf(float(value), 0.0, 4.0)
		"trail_segment_max_length_pixels":
			trail_segment_max_length_pixels = clampf(float(value), 8.0, 256.0)
		"particle_alpha":
			particle_alpha = clampf(float(value), 0.0, 1.0)
		"salmon.enabled", "salmon_enabled":
			salmon_enabled = bool(value)
		"salmon.per_release", "salmon_per_release":
			var parsed_salmon_count := _strict_positive_int(value)
			if parsed_salmon_count < 1 or parsed_salmon_count > GPUSalmon2D.CAPACITY:
				return false
			salmon_per_release = parsed_salmon_count
		"salmon.min_speed_pixels", "salmon_min_speed_pixels":
			salmon_min_speed_pixels = clampf(float(value), 1.0, 600.0)
		"salmon.water_alpha_threshold", "salmon_water_alpha_threshold":
			salmon_water_alpha_threshold = clampf(float(value), 0.0, 1.0)
		"salmon.contact_width_pixels", "salmon_contact_width_pixels":
			salmon_contact_width_pixels = clampf(float(value), 1.0, 960.0)
		"salmon.contact_height_pixels", "salmon_contact_height_pixels":
			salmon_contact_height_pixels = clampf(float(value), 1.0, 240.0)
		"salmon.water_steering_strength", "salmon_water_steering_strength":
			salmon_water_steering_strength = clampf(float(value), 0.0, 30.0)
		"salmon.occupancy_flip_y", "salmon_occupancy_flip_y":
			salmon_occupancy_flip_y = bool(value)
		"salmon.trail_length_pixels", "salmon_trail_length_pixels":
			salmon_trail_length_pixels = clampf(float(value), 8.0, 160.0)
		"salmon.line_width_pixels", "salmon_line_width_pixels":
			salmon_line_width_pixels = clampf(float(value), 1.0, 5.0)
		"salmon.fade_seconds", "salmon_fade_seconds":
			salmon_fade_seconds = clampf(float(value), 0.05, 4.0)
		"salmon.alpha", "salmon_alpha":
			salmon_alpha = clampf(float(value), 0.0, 1.0)
		"leaves.enabled", "leaves_enabled":
			leaves_enabled = bool(value)
		"leaves.per_side", "leaves_per_side":
			var parsed_leaf_count := _strict_positive_int(value)
			if parsed_leaf_count < 1 or parsed_leaf_count > GPULeaf2D.MAX_PER_SIDE:
				return false
			leaves_per_side = parsed_leaf_count
		"leaves.release_stagger_interval_seconds", \
				"leaf_release_stagger_interval_seconds":
			leaf_release_stagger_interval_seconds = clampf(float(value), 0.0, 2.0)
		"leaves.free_speed_pixels", "leaf_free_speed_pixels":
			leaf_free_speed_pixels = clampf(float(value), 1.0, 2400.0)
		"leaves.flow_speed_pixels", "leaf_flow_speed_pixels":
			leaf_flow_speed_pixels = clampf(float(value), 1.0, 2400.0)
		"leaves.speed_variation", "leaf_speed_variation":
			leaf_speed_variation = clampf(float(value), 0.0, 1.0)
		"leaves.velocity_response", "leaf_velocity_response":
			leaf_velocity_response = clampf(float(value), 0.0, 30.0)
		"leaves.sway_amplitude_min_pixels", "leaf_sway_amplitude_min_pixels":
			leaf_sway_amplitude_min_pixels = clampf(float(value), 0.0, 120.0)
		"leaves.sway_amplitude_max_pixels", "leaf_sway_amplitude_max_pixels":
			leaf_sway_amplitude_max_pixels = clampf(float(value), 0.0, 120.0)
		"leaves.sway_period_min_seconds", "leaf_sway_period_min_seconds":
			leaf_sway_period_min_seconds = clampf(float(value), 0.1, 10.0)
		"leaves.sway_period_max_seconds", "leaf_sway_period_max_seconds":
			leaf_sway_period_max_seconds = clampf(float(value), 0.1, 10.0)
		"leaves.free_water_search_radius_pixels", \
				"leaf_free_water_search_radius_pixels":
			leaf_free_water_search_radius_pixels = clampf(float(value), 1.0, 480.0)
		"leaves.free_water_steering_strength", \
				"leaf_free_water_steering_strength":
			leaf_free_water_steering_strength = clampf(float(value), 0.0, 1.0)
		"leaves.free_search_max_distance_pixels", \
				"leaf_free_search_max_distance_pixels":
			leaf_free_search_max_distance_pixels = clampf(float(value), 1.0, 4096.0)
		"leaves.stopped_fade_seconds", "leaf_stopped_fade_seconds":
			leaf_stopped_fade_seconds = clampf(float(value), 0.05, 4.0)
		"leaves.water_alpha_threshold", "leaf_water_alpha_threshold":
			leaf_water_alpha_threshold = clampf(float(value), 0.0, 1.0)
		"leaves.contact_radius_pixels", "leaf_contact_radius_pixels":
			leaf_contact_radius_pixels = clampf(float(value), 1.0, 120.0)
		"leaves.follow_probe_min_pixels", "leaf_follow_probe_min_pixels":
			leaf_follow_probe_min_pixels = clampf(float(value), 1.0, 240.0)
		"leaves.follow_probe_max_pixels", "leaf_follow_probe_max_pixels":
			leaf_follow_probe_max_pixels = clampf(float(value), 1.0, 480.0)
		"leaves.follow_turn_degrees", "leaf_follow_turn_degrees":
			leaf_follow_turn_degrees = clampf(float(value), 1.0, 80.0)
		"leaves.follow_resample_interval_seconds", \
				"leaf_follow_resample_interval_seconds":
			leaf_follow_resample_interval_seconds = clampf(float(value), 0.01, 1.0)
		"leaves.occupancy_flip_y", "leaf_occupancy_flip_y":
			leaf_occupancy_flip_y = bool(value)
		"leaves.line_width_pixels", "leaf_line_width_pixels":
			leaf_line_width_pixels = clampf(float(value), 1.0, 10.0)
		"leaves.disk_radius_pixels", "leaf_disk_radius_pixels":
			leaf_line_width_pixels = clampf(float(value) * 2.0, 1.0, 10.0)
		"leaves.line_width_variation", "leaf_line_width_variation", \
				"leaves.radius_variation", "leaf_radius_variation":
			leaf_line_width_variation = clampf(float(value), 0.0, 1.0)
		"leaves.alpha", "leaf_alpha":
			leaf_alpha = clampf(float(value), 0.0, 1.0)
		"background_color":
			background_color = Color(value)
		"reservoir.reservoir_main.gate_open", "gate_open":
			gate_open = bool(value)
		"reservoir.reservoir_main.outlet_width", "gate_width", "outlet_width":
			gate_width = float(value)
		"reservoir_center_pixels":
			var parsed_center := _variant_to_vector2(value, reservoir_center_pixels)
			reservoir_center_pixels = parsed_center
		"reservoir.reservoir_main.x":
			reservoir_center_pixels.x = float(value) * PIXELS_PER_WORLD_UNIT
		"reservoir.reservoir_main.y":
			reservoir_center_pixels.y = (
				WORLD_SIZE.y - float(value)
			) * PIXELS_PER_WORLD_UNIT
		"reservoir.reservoir_main.radius":
			reservoir_radius_pixels = maxf(float(value) * PIXELS_PER_WORLD_UNIT, 1.0)
			_refresh_gate_width_for_reservoir()
		"reservoir.reservoir_main.wall_influence":
			reservoir_influence_pixels = maxf(
				float(value) * PIXELS_PER_WORLD_UNIT,
				0.0
			)
		"reservoir.reservoir_main.circulation":
			reservoir_swirl_speed = maxf(float(value) * 72.5, 0.0)
		"reservoir.reservoir_main.swirl_strength":
			reservoir_swirl_speed = maxf(float(value) * 47.0, 0.0)
		"reservoir.reservoir_main.orbit_radius_min_ratio":
			reservoir_orbit_radius_min_ratio = clampf(float(value), 0.02, 1.0)
		"reservoir.reservoir_main.orbit_radius_max_ratio":
			reservoir_orbit_radius_max_ratio = clampf(float(value), 0.02, 1.0)
		"reservoir.reservoir_main.orbit_full_speed_ratio":
			reservoir_orbit_full_speed_ratio = clampf(float(value), 0.05, 1.0)
		"reservoir.reservoir_main.orbit_max_angular_speed":
			reservoir_orbit_max_angular_speed = clampf(float(value), 0.1, 3.0)
		"reservoir.reservoir_main.capture_y_ratio":
			reservoir_capture_y_ratio = clampf(float(value), 0.05, 1.0)
		"reservoir.reservoir_main.capture_edge_softness":
			reservoir_capture_edge_softness_pixels = clampf(
				float(value) * PIXELS_PER_WORLD_UNIT,
				0.0,
				120.0
			)
		"reservoir.reservoir_main.entry_min_incidence":
			reservoir_entry_min_incidence = clampf(float(value), 0.0, 1.0)
		"reservoir.reservoir_main.entry_pull_strength":
			reservoir_entry_pull_strength = clampf(float(value), 0.0, 8.0)
		"reservoir.reservoir_main.entry_min_inward_speed_ratio":
			reservoir_entry_min_inward_speed_ratio = clampf(float(value), 0.0, 1.0)
		"reservoir.reservoir_main.gate_staging_radius_ratio":
			reservoir_gate_staging_radius_ratio = clampf(float(value), 0.50, 0.95)
		"reservoir_radius_pixels":
			reservoir_radius_pixels = maxf(float(value), 8.0)
			_refresh_gate_width_for_reservoir()
		"reservoir_influence_pixels":
			reservoir_influence_pixels = maxf(float(value), 0.0)
		"reservoir_swirl_speed":
			reservoir_swirl_speed = maxf(float(value), 0.0)
		"reservoir_orbit_radius_min_ratio":
			reservoir_orbit_radius_min_ratio = clampf(float(value), 0.02, 1.0)
		"reservoir_orbit_radius_max_ratio":
			reservoir_orbit_radius_max_ratio = clampf(float(value), 0.02, 1.0)
		"reservoir_orbit_full_speed_ratio":
			reservoir_orbit_full_speed_ratio = clampf(float(value), 0.05, 1.0)
		"reservoir_orbit_max_angular_speed":
			reservoir_orbit_max_angular_speed = clampf(float(value), 0.1, 3.0)
		"reservoir_capture_y_ratio":
			reservoir_capture_y_ratio = clampf(float(value), 0.05, 1.0)
		"reservoir_capture_edge_softness_pixels":
			reservoir_capture_edge_softness_pixels = clampf(
				float(value),
				0.0,
				120.0
			)
		"reservoir_entry_min_incidence":
			reservoir_entry_min_incidence = clampf(float(value), 0.0, 1.0)
		"reservoir_entry_pull_strength":
			reservoir_entry_pull_strength = clampf(float(value), 0.0, 8.0)
		"reservoir_entry_min_inward_speed_ratio":
			reservoir_entry_min_inward_speed_ratio = clampf(float(value), 0.0, 1.0)
		"reservoir_gate_staging_radius_ratio":
			reservoir_gate_staging_radius_ratio = clampf(float(value), 0.50, 0.95)
		_:
			return false
	if apply_immediately:
		_apply_runtime_parameters()
		_apply_gate()
	return true


func _is_direct_apply_parameter_path(path: String) -> bool:
	return path in [
		"stage.title",
		"stage_title",
		"stage.title_visible",
		"stage_title_visible",
		"stage.grid_visible",
		"stage_grid_visible",
		"stage.grid_spacing_pixels",
		"stage_grid_spacing_pixels",
		"stage.grid_line_width_pixels",
		"stage_grid_line_width_pixels",
		"stage.grid_color",
		"stage_grid_color",
		"stage.date_visible",
		"stage_date_visible",
		"stage.date",
		"calendar.date",
		"model_date",
		"calendar.day_index",
		"model_day_index",
		"calendar.auto_advance",
		"model_calendar_auto_advance",
		"calendar.year_duration_seconds",
		"model_year_duration_seconds",
		"calendar.start_day_index",
		"model_start_day_index",
		"watershed.data_path",
		"watershed_data_path",
		"watershed.drives_flow_rate",
		"watershed_data_drives_flow_rate",
		"watershed.interpolate_flow_rate",
		"watershed_interpolate_flow_rate",
	]


func runtime_summary() -> Dictionary:
	if _head_layers.is_empty() or _process_material_layers.is_empty():
		return {}
	var head_layer_slot_counts: Array[int] = []
	var head_layer_allocated_amounts: Array[int] = []
	var active_head_layer_counts: Array[int] = []
	var head_layer_z_indices: Array[int] = []
	var head_layer_z_as_relative: Array[bool] = []
	var head_layer_amount_ratios: Array[float] = []
	var head_layer_fixed_fps: Array[int] = []
	var trail_segment_capacities: Array[int] = []
	var trail_segment_z_indices: Array[int] = []
	var trail_segment_z_as_relative: Array[bool] = []
	var trail_segment_fixed_fps_values: Array[int] = []
	var trail_segment_emitter_paths: Array[String] = []
	var forced_palette_color_uniforms: Array = []
	var force_palette_color_uniforms: Array[bool] = []
	var particle_index_offset_uniforms: Array[float] = []
	var particle_index_stride_uniforms: Array[float] = []
	var base_speed_uniforms: Array[float] = []
	var velocity_response_uniforms: Array[float] = []
	var gate_open_uniforms: Array[bool] = []
	var gate_half_width_uniforms: Array[float] = []
	var reservoir_center_uniforms: Array[Vector2] = []
	var reservoir_radius_uniforms: Array[float] = []
	var reservoir_admission_enabled_uniforms: Array[bool] = []
	var interaction_admission_enabled_uniforms: Array[bool] = []
	var interaction_count_uniforms: Array[int] = []
	var interaction_texture_bound_uniforms: Array[bool] = []
	var source_count_uniforms: Array[int] = []
	var source_texture_bound_uniforms: Array[bool] = []
	var trail_recording_enabled_uniforms: Array[bool] = []
	var head_layer_speed_scales: Array[float] = []
	var trail_segment_speed_scales: Array[float] = []
	var total_segment_capacity: int = 0
	var any_segment_native_trail_enabled: bool = false
	var any_segment_autonomous_emission: bool = false
	for layer_index in range(_head_layers.size()):
		var head_layer: GPUParticles2D = _head_layers[layer_index]
		var segment_layer: GPUParticles2D = _trail_segment_layers[layer_index]
		var process_material: ShaderMaterial = _process_material_layers[layer_index]
		head_layer_slot_counts.append(_layer_slot_count(layer_index))
		head_layer_allocated_amounts.append(head_layer.amount)
		active_head_layer_counts.append(_active_layer_slot_count(layer_index))
		head_layer_z_indices.append(head_layer.z_index)
		head_layer_z_as_relative.append(head_layer.z_as_relative)
		head_layer_amount_ratios.append(head_layer.amount_ratio)
		head_layer_fixed_fps.append(head_layer.fixed_fps)
		head_layer_speed_scales.append(head_layer.speed_scale)
		trail_segment_capacities.append(segment_layer.amount)
		trail_segment_z_indices.append(segment_layer.z_index)
		trail_segment_z_as_relative.append(segment_layer.z_as_relative)
		trail_segment_fixed_fps_values.append(segment_layer.fixed_fps)
		trail_segment_speed_scales.append(segment_layer.speed_scale)
		trail_segment_emitter_paths.append(String(head_layer.sub_emitter))
		forced_palette_color_uniforms.append(
			process_material.get_shader_parameter(&"forced_palette_color")
		)
		force_palette_color_uniforms.append(bool(
			process_material.get_shader_parameter(&"force_palette_color")
		))
		particle_index_offset_uniforms.append(float(
			process_material.get_shader_parameter(&"particle_index_offset")
		))
		particle_index_stride_uniforms.append(float(
			process_material.get_shader_parameter(&"particle_index_stride")
		))
		base_speed_uniforms.append(float(
			process_material.get_shader_parameter(&"base_speed")
		))
		velocity_response_uniforms.append(float(
			process_material.get_shader_parameter(&"velocity_response")
		))
		gate_open_uniforms.append(bool(
			process_material.get_shader_parameter(&"gate_open")
		))
		gate_half_width_uniforms.append(float(
			process_material.get_shader_parameter(&"gate_half_width")
		))
		reservoir_center_uniforms.append(Vector2(
			process_material.get_shader_parameter(&"reservoir_center")
		))
		reservoir_radius_uniforms.append(float(
			process_material.get_shader_parameter(&"reservoir_radius")
		))
		reservoir_admission_enabled_uniforms.append(bool(
			process_material.get_shader_parameter(&"reservoir_admission_enabled")
		))
		interaction_admission_enabled_uniforms.append(bool(
			process_material.get_shader_parameter(&"interaction_admission_enabled")
		))
		interaction_count_uniforms.append(int(
			process_material.get_shader_parameter(&"interaction_count")
		))
		interaction_texture_bound_uniforms.append(
			process_material.get_shader_parameter(&"interaction_data_texture") != null
		)
		source_count_uniforms.append(int(
			process_material.get_shader_parameter(&"source_count")
		))
		source_texture_bound_uniforms.append(
			process_material.get_shader_parameter(&"source_data_texture") != null
		)
		trail_recording_enabled_uniforms.append(bool(
			process_material.get_shader_parameter(&"trail_recording_enabled")
		))
		total_segment_capacity += segment_layer.amount
		any_segment_native_trail_enabled = (
			any_segment_native_trail_enabled or segment_layer.trail_enabled
		)
		any_segment_autonomous_emission = (
			any_segment_autonomous_emission or segment_layer.emitting
		)
	var interaction_definitions: Array[Dictionary] = []
	for interaction_polygon: GPUFlowInteractionPolygon in _gpu_interaction_polygons():
		var interaction_definition := interaction_polygon.to_dictionary()
		interaction_definition["vertices_pixels"] = _polygon_native_vertices(
			interaction_polygon.vertices
		)
		interaction_definitions.append(interaction_definition)
	var source_definitions: Array[Dictionary] = []
	for source_polygon: GPUFlowSourcePolygon in _gpu_source_polygons():
		var source_definition := source_polygon.to_dictionary()
		source_definition["vertices_pixels"] = _polygon_native_vertices(
			source_polygon.vertices
		)
		source_definitions.append(source_definition)
	var salmon_summary: Dictionary = (
		_salmon_school.runtime_summary()
		if _salmon_school != null
		else {}
	)
	var leaf_summary: Dictionary = (
		_leaf_field.runtime_summary()
		if _leaf_field != null
		else {}
	)
	var watershed_row := get_current_watershed_data_row()
	var watershed_row_count := _watershed_normalized_flow.size()
	return {
		"stage_index": stage_index,
		"model_id": String(model_id),
		"screen_id": String(screen_id),
		"control_target": String(control_target),
		"stage_title": stage_title,
		"stage_title_visible": stage_title_visible,
		"stage_title_position": STAGE_TITLE_POSITION,
		"stage_title_color": STAGE_TITLE_COLOR,
		"stage_title_font_size": STAGE_TITLE_FONT_SIZE,
		"stage_title_font_resource": STAGE_TITLE_FONT.resource_path,
		"stage_title_z_index": STAGE_TITLE_Z_INDEX,
		"background_z_index": BACKGROUND_Z_INDEX,
		"stage_grid_visible": stage_grid_visible,
		"stage_grid_spacing_pixels": stage_grid_spacing_pixels,
		"stage_grid_line_width_pixels": stage_grid_line_width_pixels,
		"stage_grid_color": stage_grid_color,
		"stage_grid_z_index": BACKGROUND_GRID_Z_INDEX,
		"stage_grid_line_count": (
			_background_grid.get_child_count()
			if _background_grid != null
			else 0
		),
		"stage_date_visible": stage_date_visible,
		"stage_date_text": _format_model_date_time(
			_model_day_index,
			_model_minute_of_day
		),
		"stage_date_format": "MM/DD-HH:MM",
		"stage_date_position": MODEL_DATE_POSITION,
		"stage_date_color": STAGE_TITLE_COLOR,
		"stage_date_font_size": STAGE_TITLE_FONT_SIZE,
		"stage_date_font_resource": STAGE_TITLE_FONT.resource_path,
		"stage_date_z_index": STAGE_TITLE_Z_INDEX,
		"model_day_index": _model_day_index,
		"model_day_of_year": _model_day_index + 1,
		"model_minute_of_day": _model_minute_of_day,
		"model_elapsed_seconds": _model_year_elapsed_seconds,
		"model_year_progress": (
			_model_year_elapsed_seconds
			/ maxf(model_year_duration_seconds, 0.001)
		),
		"model_year_duration_seconds": model_year_duration_seconds,
		"model_year_frames_at_30_fps": MODEL_YEAR_FRAMES_AT_30_FPS,
		"model_year_minute_count": MODEL_YEAR_MINUTE_COUNT,
		"model_calendar_day_count": MODEL_CALENDAR_DAY_COUNT,
		"model_calendar_auto_advance": model_calendar_auto_advance,
		"model_calendar_source": String(_model_date_source),
		"model_start_day_index": model_start_day_index,
		"watershed_data_path": watershed_data_path,
		"watershed_data_loaded": watershed_row_count > 0,
		"watershed_data_error": _watershed_data_error,
		"watershed_data_river": _watershed_data_river,
		"watershed_data_row_count": watershed_row_count,
		"watershed_data_row_index": _watershed_row_index,
		"watershed_data_row_fraction": _watershed_row_fraction,
		"watershed_data_drives_flow_rate": watershed_data_drives_flow_rate,
		"watershed_interpolate_flow_rate": watershed_interpolate_flow_rate,
		"watershed_interpolated_flow_rate": _watershed_interpolated_flow_rate,
		"watershed_flow_percent": _watershed_interpolated_flow_rate * 100.0,
		"watershed_row_duration_seconds": (
			model_year_duration_seconds / float(watershed_row_count)
			if watershed_row_count > 0
			else 0.0
		),
		"watershed_model_minutes_per_row": (
			float(MODEL_YEAR_MINUTE_COUNT) / float(watershed_row_count)
			if watershed_row_count > 0
			else 0.0
		),
		"watershed_current_row": watershed_row,
		"stage_title_below_animated_features": true,
		"stage_grid_above_background": true,
		"stage_text_above_grid": true,
		"stage_size": STAGE_SIZE,
		"water_texture_bound": (
			_water_viewport != null and _water_viewport.get_texture() != null
		),
		"water_texture_size": (
			Vector2(_water_viewport.size)
			if _water_viewport != null
			else Vector2.ZERO
		),
		"water_texture_transparent": (
			_water_viewport.transparent_bg if _water_viewport != null else false
		),
		"water_texture_render_once": true,
		"water_texture_excludes_background": true,
		"water_texture_excludes_stage_grid": true,
		"water_texture_excludes_debug_overlay": true,
		"water_texture_excludes_stage_title": true,
		"water_texture_excludes_stage_date": true,
		"amount": particle_slots,
		"amount_ratio": particles.amount_ratio,
		"flow_rate": flow_rate,
		"active_heads_approx": ceili(
			float(particle_slots) * clampf(flow_rate, 0.0, 1.0)
		),
		"palette_layer_count": PALETTE_LAYER_COUNT,
		"head_layer_count": _head_layers.size(),
		"trail_segment_layer_count": _trail_segment_layers.size(),
		"head_layer_slot_counts": head_layer_slot_counts,
		"head_layer_allocated_amounts": head_layer_allocated_amounts,
		"active_head_layer_counts": active_head_layer_counts,
		"head_layer_amount_ratios": head_layer_amount_ratios,
		"head_layer_fixed_fps": head_layer_fixed_fps,
		"head_layer_speed_scales": head_layer_speed_scales,
		"head_layer_z_indices": head_layer_z_indices,
		"head_layer_z_as_relative": head_layer_z_as_relative,
		"palette_colors": FLOW_PALETTE,
		"forced_palette_color_uniforms": forced_palette_color_uniforms,
		"force_palette_color_uniforms": force_palette_color_uniforms,
		"particle_index_offset_uniforms": particle_index_offset_uniforms,
		"particle_index_stride_uniforms": particle_index_stride_uniforms,
		"base_speed_uniforms": base_speed_uniforms,
		"velocity_response_uniforms": velocity_response_uniforms,
		"gate_open_uniforms": gate_open_uniforms,
		"gate_half_width_uniforms": gate_half_width_uniforms,
		"reservoir_center_uniforms": reservoir_center_uniforms,
		"reservoir_radius_uniforms": reservoir_radius_uniforms,
		"reservoir_admission_enabled_uniforms": (
			reservoir_admission_enabled_uniforms
		),
		"interaction_admission_enabled_uniforms": (
			interaction_admission_enabled_uniforms
		),
		"interaction_count_uniforms": interaction_count_uniforms,
		"interaction_texture_bound_uniforms": interaction_texture_bound_uniforms,
		"source_count_uniforms": source_count_uniforms,
		"source_texture_bound_uniforms": source_texture_bound_uniforms,
		"interaction_polygon_count": interaction_definitions.size(),
		"polygon_object_count": interaction_definitions.size(),
		"interaction_polygons": interaction_definitions,
		"polygon_objects": interaction_definitions,
		"source_polygon_count": source_definitions.size(),
		"source_polygons": source_definitions,
		"source_texture_packer": (
			_source_texture_packer.runtime_summary()
			if _source_texture_packer != null
			else {}
		),
		"source_overlay_count": (
			int(_overlay.call(&"get_source_polygon_count"))
			if _overlay != null
			else 0
		),
		"salmon_enabled": salmon_enabled,
		"salmon_per_release": salmon_per_release,
		"salmon_min_speed_pixels": salmon_min_speed_pixels,
		"salmon_contact_width_pixels": salmon_contact_width_pixels,
		"salmon_contact_height_pixels": salmon_contact_height_pixels,
		"salmon_water_steering_strength": salmon_water_steering_strength,
		"salmon_occupancy_flip_y": salmon_occupancy_flip_y,
		"salmon_summary": salmon_summary,
		"leaves_enabled": leaves_enabled,
		"leaves_per_side": leaves_per_side,
		"leaf_release_stagger_interval_seconds": leaf_release_stagger_interval_seconds,
		"leaf_free_speed_pixels": leaf_free_speed_pixels,
		"leaf_flow_speed_pixels": leaf_flow_speed_pixels,
		"leaf_free_water_search_radius_pixels": leaf_free_water_search_radius_pixels,
		"leaf_free_water_steering_strength": leaf_free_water_steering_strength,
		"leaf_free_search_max_distance_pixels": leaf_free_search_max_distance_pixels,
		"leaf_stopped_fade_seconds": leaf_stopped_fade_seconds,
		"leaf_contact_radius_pixels": leaf_contact_radius_pixels,
		"leaf_follow_probe_min_pixels": leaf_follow_probe_min_pixels,
		"leaf_follow_probe_max_pixels": leaf_follow_probe_max_pixels,
		"leaf_follow_turn_degrees": leaf_follow_turn_degrees,
		"leaf_follow_resample_interval_seconds": leaf_follow_resample_interval_seconds,
		"leaf_line_width_variation": leaf_line_width_variation,
		"leaf_disk_radius_pixels": leaf_line_width_pixels * 0.5,
		"leaf_radius_variation": leaf_line_width_variation,
		"leaf_occupancy_flip_y": leaf_occupancy_flip_y,
		"leaf_summary": leaf_summary,
		"interaction_overlay_count": (
			int(_overlay.call(&"get_interaction_polygon_count"))
			if _overlay != null
			else 0
		),
		"polygon_overlay_count": (
			int(_overlay.call(&"get_interaction_polygon_count"))
			if _overlay != null
			else 0
		),
		"base_speed_uniform": _process_material.get_shader_parameter(&"base_speed"),
		"velocity_response_uniform": _process_material.get_shader_parameter(
			&"velocity_response"
		),
		"trail_mode": "immutable_gpu_segments",
		"trail_segment_capacity": total_segment_capacity,
		"trail_segment_capacities": trail_segment_capacities,
		"trail_segment_z_indices": trail_segment_z_indices,
		"trail_segment_z_as_relative": trail_segment_z_as_relative,
		"trail_segment_fixed_fps_values": trail_segment_fixed_fps_values,
		"trail_segment_speed_scales": trail_segment_speed_scales,
		"trail_segment_emitter_paths": trail_segment_emitter_paths,
		"trail_recording_enabled_uniforms": trail_recording_enabled_uniforms,
		"trail_segment_native_trail_enabled": any_segment_native_trail_enabled,
		"trail_segment_autonomous_emission": any_segment_autonomous_emission,
		"trail_segment_emitter_path": String(particles.sub_emitter),
		"trail_segment_fixed_fps": (
			_trail_segments.fixed_fps if _trail_segments != null else 0
		),
		"trail_segment_interpolate": (
			_trail_segments.interpolate if _trail_segments != null else true
		),
		"trail_segment_texture_size": (
			_trail_segments.texture.get_size()
			if _trail_segments != null and _trail_segments.texture != null
			else Vector2.ZERO
		),
		"trail_segment_lifetime_uniform": _draw_material.get_shader_parameter(
			&"trail_lifetime_seconds"
		),
		"trail_segment_process_lifetime_uniform": (
			_trail_process_material.get_shader_parameter(
				&"segment_lifetime_seconds"
			)
		),
		"trail_segment_overlap_pixels": trail_segment_overlap_pixels,
		"trail_segment_overlap_pixels_uniform": _process_material.get_shader_parameter(
			&"trail_segment_overlap_pixels"
		),
		"trail_segment_max_length_pixels": trail_segment_max_length_pixels,
		"trail_segment_max_length_pixels_uniform": _process_material.get_shader_parameter(
			&"trail_segment_max_length_pixels"
		),
		"trail_recording_enabled_uniform": _process_material.get_shader_parameter(
			&"trail_recording_enabled"
		),
		"fixed_fps": particles.fixed_fps,
		"interpolate": particles.interpolate,
		"trail_enabled": particles.trail_enabled,
		"head_texture_size": (
			particles.texture.get_size()
			if particles.texture != null
			else Vector2.ZERO
		),
		"trail_lifetime": trail_lifetime,
		"gate_open": gate_open,
		"gate_width": gate_width,
		"gate_width_requested": _requested_gate_width,
		"gate_full_width": get_full_gate_width_world_units(),
		"gate_half_width": get_gate_half_width_pixels(),
		"gate_half_width_pixels": get_gate_half_width_pixels(),
		"gate_aperture_fraction": get_gate_aperture_fraction(),
		"gate_fully_open": (
			gate_open && get_gate_aperture_fraction() >= 0.999
		),
		"gate_release_probability_effective": (
			get_effective_gate_release_probability()
		),
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
		"reservoir_center_pixels": reservoir_center_pixels,
		"reservoir_radius_pixels": reservoir_radius_pixels,
		"reservoir_center_uniform": _process_material.get_shader_parameter(
			&"reservoir_center"
		),
		"reservoir_radius_uniform": _process_material.get_shader_parameter(
			&"reservoir_radius"
		),
		"reservoir_orbit_radius_min_ratio_uniform": _process_material.get_shader_parameter(
			&"reservoir_orbit_radius_min_ratio"
		),
		"reservoir_orbit_radius_max_ratio_uniform": _process_material.get_shader_parameter(
			&"reservoir_orbit_radius_max_ratio"
		),
		"reservoir_orbit_full_speed_ratio_uniform": _process_material.get_shader_parameter(
			&"reservoir_orbit_full_speed_ratio"
		),
		"reservoir_orbit_max_angular_speed_uniform": _process_material.get_shader_parameter(
			&"reservoir_orbit_max_angular_speed"
		),
		"reservoir_capture_y_ratio_uniform": _process_material.get_shader_parameter(
			&"reservoir_capture_y_ratio"
		),
		"reservoir_capture_edge_softness_uniform": _process_material.get_shader_parameter(
			&"reservoir_capture_edge_softness"
		),
		"reservoir_entry_min_incidence_uniform": _process_material.get_shader_parameter(
			&"reservoir_entry_min_incidence"
		),
		"reservoir_entry_pull_strength_uniform": _process_material.get_shader_parameter(
			&"reservoir_entry_pull_strength"
		),
		"reservoir_entry_min_inward_speed_ratio_uniform": _process_material.get_shader_parameter(
			&"reservoir_entry_min_inward_speed_ratio"
		),
		"reservoir_gate_staging_radius_ratio_uniform": _process_material.get_shader_parameter(
			&"reservoir_gate_staging_radius_ratio"
		),
		"gate_open_uniform": _process_material.get_shader_parameter(&"gate_open"),
		"gate_half_width_uniform": _process_material.get_shader_parameter(
			&"gate_half_width"
		),
		"interaction_count_uniform": _process_material.get_shader_parameter(
			&"interaction_count"
		),
		"interaction_admission_enabled_uniform": _process_material.get_shader_parameter(
			&"interaction_admission_enabled"
		),
		"interaction_data_texture_bound": (
			_process_material.get_shader_parameter(&"interaction_data_texture") != null
		),
		"interaction_data_texture_size": (
			_interaction_data_texture.get_size()
			if _interaction_data_texture != null
			else Vector2.ZERO
		),
		"source_count_uniform": _process_material.get_shader_parameter(
			&"source_count"
		),
		"source_data_texture_bound": (
			_process_material.get_shader_parameter(&"source_data_texture") != null
		),
		"source_data_texture_size": (
			_source_data_texture.get_size()
			if _source_data_texture != null
			else Vector2.ZERO
		),
		"paused": _paused,
		"debug_visible": debug_visible,
		"debug_overlay_visible": _overlay.visible if _overlay != null else false,
	}


func _apply_control_message(message: Dictionary) -> void:
	_begin_source_geometry_batch()
	var runtime_parameters_changed := false
	var command := String(message.get("command", ""))
	if command == "set_gate":
		if message.has("gate_open"):
			gate_open = bool(message["gate_open"])
		if message.has("outlet_width"):
			gate_width = float(message["outlet_width"])
	elif command == "set_parameter":
		var command_path := String(message.get("path", ""))
		var command_changed := set_runtime_parameter(
			StringName(command_path),
			message.get("value"),
			false
		)
		runtime_parameters_changed = (
			command_changed
			and not _is_direct_apply_parameter_path(command_path)
		)

	var changes: Variant = message.get("changes", {})
	if changes is Dictionary:
		for path: Variant in changes:
			var change_path := String(path)
			var parameter_changed := set_runtime_parameter(
				StringName(change_path),
				changes[path],
				false
			)
			if not _is_direct_apply_parameter_path(change_path):
				runtime_parameters_changed = (
					parameter_changed or runtime_parameters_changed
				)

	var geometry_operations: Variant = message.get("geometry_ops", [])
	if geometry_operations is Array:
		for operation_variant: Variant in geometry_operations:
			if operation_variant is Dictionary:
				runtime_parameters_changed = (
					_apply_geometry_operation(operation_variant)
					or runtime_parameters_changed
				)

	if runtime_parameters_changed:
		_apply_runtime_parameters()
		_apply_gate()

	var actions: Variant = message.get("actions", [])
	if actions is Array:
		for action: Variant in actions:
			var action_name := ""
			var action_arguments: Dictionary = {}
			if action is Dictionary:
				action_name = String(action.get("name", action.get("action", "")))
				var arguments_variant: Variant = action.get("arguments", {})
				if arguments_variant is Dictionary:
					action_arguments = arguments_variant
			else:
				action_name = String(action)
			match action_name.strip_edges().to_lower():
				"pause":
					set_paused(true)
				"resume":
					set_paused(false)
				"toggle_gate":
					toggle_gate()
				"toggle_debug", "toggle_debug_geometry":
					toggle_debug_visibility()
				"release_salmon":
					var requested_salmon := salmon_per_release
					if action_arguments.has("count"):
						requested_salmon = _strict_positive_int(
							action_arguments["count"]
						)
					if (
						requested_salmon >= 1
						and requested_salmon <= GPUSalmon2D.CAPACITY
					):
						release_salmon(requested_salmon)
				"release_leaves":
					var requested_leaves := leaves_per_side
					if action_arguments.has("count_per_side"):
						requested_leaves = _strict_positive_int(
							action_arguments["count_per_side"]
						)
					elif action_arguments.has("count"):
						requested_leaves = _strict_positive_int(
							action_arguments["count"]
						)
					if (
						requested_leaves >= 1
						and requested_leaves <= GPULeaf2D.MAX_PER_SIDE
					):
						release_leaves(requested_leaves)
				"reset":
					_reset_model_calendar()
					_defer_trail_recording_until_after_preprocess()
					for head_layer in _head_layers:
						head_layer.restart(true)
					for segment_layer in _trail_segment_layers:
						segment_layer.restart(true)
					if _salmon_school != null:
						_salmon_school.reset_salmon()
					if _leaf_field != null:
						_leaf_field.reset_leaves()
	_end_source_geometry_batch()


func _apply_geometry_operation(operation: Dictionary) -> bool:
	var raw_kind := String(operation.get("kind", "")).strip_edges().to_lower()
	var operation_name := String(
		operation.get("op", "upsert")
	).strip_edges().to_lower()
	if raw_kind == "reservoir":
		if operation_name in ["upsert", "add", "update"]:
			var reservoir_id := String(operation.get("id", RESERVOIR_ID))
			if reservoir_id != String(RESERVOIR_ID):
				return false
			var definition: Variant = operation.get("value", {})
			if definition is Dictionary:
				return _apply_reservoir_definition(definition)
		elif operation_name == "replace":
			var definitions: Variant = operation.get("values", [])
			if definitions is Array:
				for definition_variant: Variant in definitions:
					if not definition_variant is Dictionary:
						continue
					if String(definition_variant.get("element_id", RESERVOIR_ID)) == String(RESERVOIR_ID):
						return _apply_reservoir_definition(definition_variant)
		return false

	if _canonical_source_kind(raw_kind) != "":
		match operation_name:
			"upsert", "add", "update":
				return _upsert_source_polygon(operation)
			"remove", "delete":
				return _remove_source_polygon(StringName(String(operation.get(
					"id",
					operation.get("element_id", "")
				))))
			"replace":
				var source_values: Variant = operation.get("values", [])
				if source_values is Array:
					return _replace_source_polygons(source_values)
		return false

	var kind := _canonical_interaction_kind(raw_kind)
	if kind == "":
		return false
	match operation_name:
		"upsert", "add", "update":
			return _upsert_interaction_polygon(operation, kind)
		"remove", "delete":
			return _remove_interaction_polygon(
				StringName(String(operation.get(
					"id",
					operation.get("element_id", "")
				)))
			)
		"replace":
			# A replacement is always the complete unified interaction set. Mode
			# aliases are intentionally rejected here so `kind: absorber` can never
			# erase repellers (or vice versa) by surprise.
			if kind != "polygon":
				return false
			var replacement_values: Variant = operation.get("values", [])
			if replacement_values is Array:
				return _replace_interaction_polygons(replacement_values)
	return false


func _apply_reservoir_definition(definition: Dictionary) -> bool:
	var changed := false
	for field_variant: Variant in definition:
		var field := String(field_variant)
		if field in ["element_id", "id"]:
			continue
		changed = (
			set_runtime_parameter(
				StringName("reservoir.%s.%s" % [String(RESERVOIR_ID), field]),
				definition[field_variant],
				false
			)
			or changed
		)
	return changed


func _canonical_interaction_kind(kind: String) -> String:
	match kind.strip_edges().to_lower():
		"polygon", "polygons", "interaction", "interactions", \
		"interaction_polygon", "interaction_polygons", \
		"polygon_obstacle", "polygon_obstacles":
			return "polygon"
		"absorber", "absorbers":
			return "absorber"
		"obstacle", "obstacles", "repeller", "repellers":
			return "repeller"
	return ""


func _canonical_source_kind(kind: String) -> String:
	match kind.strip_edges().to_lower():
		"source", "sources", "source_polygon", "source_polygons", \
		"water_source", "water_sources":
			return "source"
	return ""


func _is_interaction_parameter_path(path: String) -> bool:
	var components := path.split(".", false)
	return (
		components.size() == 3
		and _canonical_interaction_kind(components[0]) != ""
	)


func _is_source_parameter_path(path: String) -> bool:
	var components := path.split(".", false)
	return (
		components.size() == 3
		and _canonical_source_kind(components[0]) != ""
	)


func _set_source_parameter_by_path(path: String, value: Variant) -> bool:
	var components := path.split(".", false)
	if components.size() != 3:
		return false
	var source := _find_source_polygon(StringName(components[1]))
	if source == null:
		return false
	var field := components[2].to_lower()
	match field:
		"fraction", "emission", "rate":
			field = "emission_fraction"
		"direction":
			field = "flow_direction"
		"id", "element_id":
			return false
	return source.apply_dictionary({field: value})


func _set_interaction_parameter_by_path(path: String, value: Variant) -> bool:
	var components := path.split(".", false)
	if components.size() != 3:
		return false
	var polygon := _find_interaction_polygon(StringName(components[1]))
	if polygon == null:
		return false
	var field := components[2].to_lower()
	match field:
		"absorption":
			field = "absorption_fraction"
		"repel", "strength":
			field = "repellent_force"
		"perturbation":
			field = "wave_strength"
		"id", "element_id":
			# Stable controller IDs are immutable. Remove and upsert to rename one.
			return false
	return polygon.apply_dictionary({field: value})


func _upsert_interaction_polygon(operation: Dictionary, kind: String) -> bool:
	var element_id := StringName(String(operation.get(
		"id",
		operation.get("element_id", "")
	)))
	if element_id == &"":
		return false
	var definition_variant: Variant = operation.get("value", {})
	if not definition_variant is Dictionary:
		return false
	var definition: Dictionary = definition_variant.duplicate(true)
	# The operation ID is authoritative. Erase both accepted payload aliases
	# before inserting it so Dictionary iteration order cannot rename the object.
	definition.erase("id")
	definition.erase("element_id")
	definition["element_id"] = String(element_id)
	if not definition.has("mode"):
		if kind == "absorber":
			definition["mode"] = "absorb"
		elif kind == "repeller":
			definition["mode"] = "repel"

	var existing := _find_interaction_polygon(element_id)
	if existing != null:
		var updated := existing.apply_dictionary(definition)
		if updated:
			_apply_interaction_geometry()
		return updated
	if interaction_polygons.size() >= MAX_INTERACTION_POLYGONS:
		return false
	var created := GPUFlowInteractionPolygon.new()
	if created == null or not created.apply_dictionary(definition):
		return false
	interaction_polygons.append(created)
	_connect_interaction_polygon(created)
	_apply_interaction_geometry()
	return true


func _remove_interaction_polygon(element_id: StringName) -> bool:
	var polygon_index := _find_interaction_polygon_index(element_id)
	if polygon_index < 0:
		return false
	var polygon := interaction_polygons[polygon_index]
	_disconnect_interaction_polygon(polygon)
	interaction_polygons.remove_at(polygon_index)
	_apply_interaction_geometry()
	return true


func _replace_interaction_polygons(values: Array) -> bool:
	if values.size() > MAX_INTERACTION_POLYGONS:
		return false
	var replacements: Array[GPUFlowInteractionPolygon] = []
	var replacement_ids: Dictionary = {}
	for definition_variant: Variant in values:
		if not definition_variant is Dictionary:
			return false
		var definition: Dictionary = definition_variant.duplicate(true)
		var element_id := StringName(String(
			definition.get("element_id", definition.get("id", ""))
		))
		if element_id == &"" or replacement_ids.has(element_id):
			return false
		definition.erase("id")
		definition.erase("element_id")
		definition["element_id"] = String(element_id)
		var polygon := GPUFlowInteractionPolygon.new()
		if polygon == null or not polygon.apply_dictionary(definition):
			return false
		replacement_ids[element_id] = true
		replacements.append(polygon)
	for old_polygon: GPUFlowInteractionPolygon in interaction_polygons:
		_disconnect_interaction_polygon(old_polygon)
	interaction_polygons = replacements
	_bind_interaction_polygon_signals()
	_apply_interaction_geometry()
	return true


func _upsert_source_polygon(operation: Dictionary) -> bool:
	var element_id := StringName(String(operation.get(
		"id",
		operation.get("element_id", "")
	)))
	if element_id == &"":
		return false
	var definition_variant: Variant = operation.get("value", {})
	if not definition_variant is Dictionary:
		return false
	var definition: Dictionary = definition_variant.duplicate(true)
	definition.erase("id")
	definition.erase("element_id")
	definition["element_id"] = String(element_id)
	var existing := _find_source_polygon(element_id)
	if existing != null:
		return existing.apply_dictionary(definition)
	if source_polygons.size() >= MAX_SOURCE_POLYGONS:
		return false
	var created := GPUFlowSourcePolygon.new()
	if created == null or not created.apply_dictionary(definition):
		return false
	source_polygons.append(created)
	_connect_source_polygon(created)
	_request_source_geometry_apply()
	return true


func _remove_source_polygon(element_id: StringName) -> bool:
	var source_index := _find_source_polygon_index(element_id)
	if source_index < 0:
		return false
	var source := source_polygons[source_index]
	_disconnect_source_polygon(source)
	source_polygons.remove_at(source_index)
	_request_source_geometry_apply()
	return true


func _replace_source_polygons(values: Array) -> bool:
	if values.size() > MAX_SOURCE_POLYGONS:
		return false
	var replacements: Array[GPUFlowSourcePolygon] = []
	var replacement_ids: Dictionary = {}
	for definition_variant: Variant in values:
		if not definition_variant is Dictionary:
			return false
		var definition: Dictionary = definition_variant.duplicate(true)
		var element_id := StringName(String(
			definition.get("element_id", definition.get("id", ""))
		))
		if element_id == &"" or replacement_ids.has(element_id):
			return false
		definition.erase("id")
		definition.erase("element_id")
		definition["element_id"] = String(element_id)
		var source := GPUFlowSourcePolygon.new()
		if source == null or not source.apply_dictionary(definition):
			return false
		replacement_ids[element_id] = true
		replacements.append(source)
	for old_source: GPUFlowSourcePolygon in source_polygons:
		_disconnect_source_polygon(old_source)
	source_polygons = replacements
	_bind_source_polygon_signals()
	_request_source_geometry_apply()
	return true


func _find_source_polygon(element_id: StringName) -> GPUFlowSourcePolygon:
	var source_index := _find_source_polygon_index(element_id)
	return source_polygons[source_index] if source_index >= 0 else null


func _find_source_polygon_index(element_id: StringName) -> int:
	for source_index in range(source_polygons.size()):
		var source := source_polygons[source_index]
		if source != null and source.element_id == element_id:
			return source_index
	return -1


func _find_interaction_polygon(element_id: StringName) -> GPUFlowInteractionPolygon:
	var polygon_index := _find_interaction_polygon_index(element_id)
	return interaction_polygons[polygon_index] if polygon_index >= 0 else null


func _find_interaction_polygon_index(element_id: StringName) -> int:
	for polygon_index in range(interaction_polygons.size()):
		var polygon := interaction_polygons[polygon_index]
		if polygon != null and polygon.element_id == element_id:
			return polygon_index
	return -1


func _bind_interaction_polygon_signals() -> void:
	for polygon: GPUFlowInteractionPolygon in interaction_polygons:
		_connect_interaction_polygon(polygon)


func _connect_interaction_polygon(polygon: GPUFlowInteractionPolygon) -> void:
	if polygon == null:
		return
	var callback := Callable(self, &"_on_interaction_polygon_changed")
	if not polygon.changed.is_connected(callback):
		polygon.changed.connect(callback)


func _disconnect_interaction_polygon(polygon: GPUFlowInteractionPolygon) -> void:
	if polygon == null:
		return
	var callback := Callable(self, &"_on_interaction_polygon_changed")
	if polygon.changed.is_connected(callback):
		polygon.changed.disconnect(callback)


func _on_interaction_polygon_changed() -> void:
	_apply_interaction_geometry()


func _bind_source_polygon_signals() -> void:
	for source: GPUFlowSourcePolygon in source_polygons:
		_connect_source_polygon(source)


func _begin_source_geometry_batch() -> void:
	_source_geometry_batch_depth += 1


func _end_source_geometry_batch() -> void:
	_source_geometry_batch_depth = maxi(_source_geometry_batch_depth - 1, 0)
	if _source_geometry_batch_depth == 0 and _source_geometry_dirty:
		_source_geometry_dirty = false
		_apply_source_geometry()


func _request_source_geometry_apply() -> void:
	if _source_geometry_batch_depth > 0:
		_source_geometry_dirty = true
		return
	_source_geometry_dirty = false
	_apply_source_geometry()


func _connect_source_polygon(source: GPUFlowSourcePolygon) -> void:
	if source == null:
		return
	var callback := Callable(self, &"_on_source_polygon_changed")
	if not source.changed.is_connected(callback):
		source.changed.connect(callback)


func _disconnect_source_polygon(source: GPUFlowSourcePolygon) -> void:
	if source == null:
		return
	var callback := Callable(self, &"_on_source_polygon_changed")
	if source.changed.is_connected(callback):
		source.changed.disconnect(callback)


func _on_source_polygon_changed() -> void:
	_request_source_geometry_apply()


func _install_default_interaction_polygons_if_needed() -> void:
	if not install_default_interaction_examples or not interaction_polygons.is_empty():
		return
	var absorber := GPUFlowInteractionPolygon.new()
	var repeller := GPUFlowInteractionPolygon.new()
	if absorber != null:
		absorber.apply_dictionary({
			"element_id": "absorber_test",
			"vertices": [
				[4.20, 7.35],
				[5.30, 7.55],
				[5.10, 8.45],
				[4.10, 8.25],
			],
			"mode": "absorb",
			"absorption_fraction": 0.50,
			"repellent_force": 0.0,
			"wave_strength": 0.18,
			"influence": 0.35,
		})
		interaction_polygons.append(absorber)
	if repeller != null:
		repeller.apply_dictionary({
			"element_id": "repeller_test",
			"vertices": [
				[7.40, 6.00],
				[8.40, 6.20],
				[8.20, 7.40],
				[7.30, 7.10],
			],
			"mode": "repel",
			"absorption_fraction": 0.0,
			"repellent_force": 0.70,
			"wave_strength": 0.0,
			"influence": 0.80,
		})
		interaction_polygons.append(repeller)


func _install_default_source_polygons_if_needed() -> void:
	if not install_default_source_examples or not source_polygons.is_empty():
		return
	var source := GPUFlowSourcePolygon.new()
	if source != null and source.apply_dictionary({
		"element_id": "source_test",
		"vertices": [
			[1.20, 3.60],
			[2.00, 3.60],
			[2.00, 5.40],
			[1.20, 5.40],
		],
		"enabled": true,
		"emission_fraction": 0.18,
		"flow_direction": [1.0, 0.0],
		"seed": 1701,
	}):
		source_polygons.append(source)


func _variant_to_vector2(value: Variant, fallback: Vector2) -> Vector2:
	if value is Vector2:
		return value
	if value is Vector2i:
		return Vector2(value)
	if value is Array and value.size() >= 2:
		return Vector2(float(value[0]), float(value[1]))
	if value is Dictionary and value.has("x") and value.has("y"):
		return Vector2(float(value["x"]), float(value["y"]))
	return fallback


func _strict_positive_int(value: Variant) -> int:
	if typeof(value) == TYPE_INT:
		return int(value)
	if typeof(value) == TYPE_FLOAT:
		var numeric_value := float(value)
		if is_finite(numeric_value) and numeric_value == floor(numeric_value):
			return int(numeric_value)
	return -1


func _strict_nonnegative_int(value: Variant) -> int:
	if typeof(value) == TYPE_INT:
		return int(value) if int(value) >= 0 else -1
	if typeof(value) == TYPE_FLOAT:
		var numeric_value := float(value)
		if (
			is_finite(numeric_value)
			and numeric_value >= 0.0
			and numeric_value == floor(numeric_value)
		):
			return int(numeric_value)
	return -1


func _apply_identity() -> void:
	for layer_index in range(_process_material_layers.size()):
		var process_material: ShaderMaterial = _process_material_layers[layer_index]
		process_material.set_shader_parameter(
			&"stage_phase", float(stage_index) * 1.731
		)
		process_material.set_shader_parameter(
			&"particle_index_stride", float(PALETTE_LAYER_COUNT)
		)
		process_material.set_shader_parameter(
			&"particle_index_offset", float(layer_index)
		)
		process_material.set_shader_parameter(&"force_palette_color", true)
		process_material.set_shader_parameter(
			&"forced_palette_color", FLOW_PALETTE[layer_index]
		)
		_head_layers[layer_index].seed = (
			7301 + stage_index * 997 + layer_index * 131
		)
		_trail_segment_layers[layer_index].seed = (
			9301 + stage_index * 997 + layer_index * 131
		)
	if _overlay != null:
		_overlay.set(&"stage_index", stage_index)
		_overlay.queue_redraw()


func _apply_water_rate_parameters() -> void:
	var effective_base_speed := (
		flow_speed_pixels * maxf(flow_rate, min_active_flow)
	)
	for process_material in _process_material_layers:
		process_material.set_shader_parameter(&"base_speed", effective_base_speed)
	var desired_ratio: float = clampf(flow_rate, 0.0, 1.0)
	for layer_index in range(_head_layers.size()):
		var head_layer: GPUParticles2D = _head_layers[layer_index]
		var desired_amount: int = maxi(_layer_slot_count(layer_index), 1)
		if head_layer.amount != desired_amount:
			head_layer.amount = desired_amount
		if not is_equal_approx(head_layer.amount_ratio, desired_ratio):
			head_layer.amount_ratio = desired_ratio


func _apply_runtime_parameters() -> void:
	for process_material in _process_material_layers:
		process_material.set_shader_parameter(&"stage_size", STAGE_SIZE)
		process_material.set_shader_parameter(
			&"particle_slot_count", float(maxi(particle_slots, 1))
		)
		process_material.set_shader_parameter(&"speed_variation", speed_variation)
		process_material.set_shader_parameter(
			&"velocity_response", velocity_response
		)
		process_material.set_shader_parameter(&"noise_strength", noise_strength)
		process_material.set_shader_parameter(&"noise_scale", noise_scale)
		process_material.set_shader_parameter(&"noise_speed", noise_speed)
		process_material.set_shader_parameter(
			&"line_width_min", minf(line_width_min, line_width_max)
		)
		process_material.set_shader_parameter(
			&"line_width_max", maxf(line_width_min, line_width_max)
		)
		process_material.set_shader_parameter(&"particle_alpha", particle_alpha)
		process_material.set_shader_parameter(
			&"trail_lifetime_seconds", clampf(trail_lifetime, 0.1, 8.0)
		)
		process_material.set_shader_parameter(
			&"trail_segment_overlap_pixels", trail_segment_overlap_pixels
		)
		process_material.set_shader_parameter(
			&"trail_segment_max_length_pixels",
			trail_segment_max_length_pixels
		)
		process_material.set_shader_parameter(&"reservoir_center", reservoir_center_pixels)
		process_material.set_shader_parameter(&"reservoir_radius", reservoir_radius_pixels)
		process_material.set_shader_parameter(
			&"reservoir_influence", reservoir_influence_pixels
		)
		process_material.set_shader_parameter(
			&"reservoir_swirl_speed", reservoir_swirl_speed
		)
		process_material.set_shader_parameter(
			&"reservoir_orbit_radius_min_ratio",
			reservoir_orbit_radius_min_ratio
		)
		process_material.set_shader_parameter(
			&"reservoir_orbit_radius_max_ratio",
			reservoir_orbit_radius_max_ratio
		)
		process_material.set_shader_parameter(
			&"reservoir_orbit_full_speed_ratio",
			reservoir_orbit_full_speed_ratio
		)
		process_material.set_shader_parameter(
			&"reservoir_orbit_max_angular_speed",
			reservoir_orbit_max_angular_speed
		)
		process_material.set_shader_parameter(
			&"reservoir_capture_y_ratio", reservoir_capture_y_ratio
		)
		process_material.set_shader_parameter(
			&"reservoir_capture_edge_softness",
			reservoir_capture_edge_softness_pixels
		)
		process_material.set_shader_parameter(
			&"reservoir_entry_min_incidence",
			reservoir_entry_min_incidence
		)
		process_material.set_shader_parameter(
			&"reservoir_entry_pull_strength",
			reservoir_entry_pull_strength
		)
		process_material.set_shader_parameter(
			&"reservoir_entry_min_inward_speed_ratio",
			reservoir_entry_min_inward_speed_ratio
		)
		process_material.set_shader_parameter(
			&"reservoir_gate_staging_radius_ratio",
			reservoir_gate_staging_radius_ratio
		)
	_apply_trail_draw_parameters()
	if _overlay != null:
		_overlay.call(
			&"set_reservoir_geometry",
			reservoir_center_pixels,
			reservoir_radius_pixels
		)
	_apply_water_rate_parameters()
	_apply_salmon_parameters()
	_apply_leaf_parameters()


func _apply_salmon_parameters() -> void:
	if _salmon_school == null:
		return
	var effective_speed := maxf(
		flow_speed_pixels * maxf(flow_rate, min_active_flow),
		salmon_min_speed_pixels
	)
	var maximum_step_length := (
		effective_speed
		* (1.0 + speed_variation)
		/ 30.0
		* 1.5
	)
	_salmon_school.configure({
		"stage_size": STAGE_SIZE,
		"stage_phase": float(stage_index) * 1.731,
		"upstream_speed_pixels": effective_speed,
		"speed_variation": speed_variation,
		"velocity_response": velocity_response,
		"noise_strength": noise_strength,
		"noise_scale": noise_scale,
		"noise_speed": noise_speed,
		"water_alpha_threshold": salmon_water_alpha_threshold,
		"water_lookahead_pixels": salmon_contact_width_pixels * 0.5,
		"water_contact_half_height_pixels": salmon_contact_height_pixels * 0.5,
		"water_steering_strength": salmon_water_steering_strength,
		"occupancy_flip_y": salmon_occupancy_flip_y,
		"spawn_search_width_pixels": salmon_contact_width_pixels * 0.5,
		"streak_length_pixels": salmon_trail_length_pixels,
		"streak_width_pixels": salmon_line_width_pixels,
		"fade_seconds": salmon_fade_seconds,
		"salmon_alpha": salmon_alpha if salmon_enabled else 0.0,
		"segment_max_length_pixels": clampf(
			maxf(32.0, maximum_step_length),
			32.0,
			128.0
		),
	})
	_salmon_school.set_water_texture(get_water_texture())
	_salmon_school.set_paused(_paused)


func _apply_leaf_parameters() -> void:
	if _leaf_field == null:
		return
	# Keep paired ranges coherent regardless of controller dictionary order.
	leaf_follow_probe_max_pixels = maxf(
		leaf_follow_probe_max_pixels,
		leaf_follow_probe_min_pixels
	)
	leaf_sway_amplitude_max_pixels = maxf(
		leaf_sway_amplitude_max_pixels,
		leaf_sway_amplitude_min_pixels
	)
	leaf_sway_period_max_seconds = maxf(
		leaf_sway_period_max_seconds,
		leaf_sway_period_min_seconds
	)
	_leaf_field.configure({
		"stage_size": STAGE_SIZE,
		"release_stagger_interval_seconds": leaf_release_stagger_interval_seconds,
		"free_speed_pixels": leaf_free_speed_pixels,
		"flow_speed_pixels": leaf_flow_speed_pixels,
		"speed_variation": leaf_speed_variation,
		"velocity_response": leaf_velocity_response,
		"free_sway_amplitude_min_pixels": leaf_sway_amplitude_min_pixels,
		"free_sway_amplitude_max_pixels": leaf_sway_amplitude_max_pixels,
		"free_sway_period_min_seconds": leaf_sway_period_min_seconds,
		"free_sway_period_max_seconds": leaf_sway_period_max_seconds,
		"free_water_search_radius_pixels": leaf_free_water_search_radius_pixels,
		"free_water_steering_strength": leaf_free_water_steering_strength,
		"free_search_max_distance_pixels": leaf_free_search_max_distance_pixels,
		"stopped_fade_seconds": leaf_stopped_fade_seconds,
		"water_alpha_threshold": leaf_water_alpha_threshold,
		"contact_radius_pixels": leaf_contact_radius_pixels,
		"follow_probe_min_pixels": leaf_follow_probe_min_pixels,
		"follow_probe_max_pixels": leaf_follow_probe_max_pixels,
		"follow_turn_degrees": leaf_follow_turn_degrees,
		"follow_resample_interval_seconds": leaf_follow_resample_interval_seconds,
		"occupancy_flip_y": leaf_occupancy_flip_y,
		"streak_width_pixels": leaf_line_width_pixels,
		"line_width_variation": leaf_line_width_variation,
		"leaf_alpha": leaf_alpha if leaves_enabled else 0.0,
	})
	_leaf_field.set_water_texture(get_water_texture())
	_leaf_field.set_paused(_paused)


func _apply_trail_draw_parameters() -> void:
	var desired_lifetime: float = clampf(trail_lifetime, 0.1, 8.0)
	for draw_material in _draw_material_layers:
		draw_material.set_shader_parameter(
			&"trail_lifetime_seconds", desired_lifetime
		)
	for trail_process_material in _trail_process_material_layers:
		trail_process_material.set_shader_parameter(
			&"segment_lifetime_seconds", desired_lifetime
		)
	for layer_index in range(_trail_segment_layers.size()):
		var segment_layer: GPUParticles2D = _trail_segment_layers[layer_index]
		var desired_capacity: int = _required_trail_segment_capacity_for_layer(
			layer_index
		)
		if segment_layer.amount != desired_capacity:
			segment_layer.amount = desired_capacity
		if not is_equal_approx(segment_layer.lifetime, desired_lifetime):
			segment_layer.lifetime = desired_lifetime


func _required_trail_segment_capacity_for_layer(layer_index: int) -> int:
	var maximum_heads: int = _layer_slot_count(layer_index)
	if maximum_heads <= 0:
		# GPUParticles2D requires a non-zero allocation. The corresponding global
		# identity is outside particle_slot_count, so this tiny fallback stays idle.
		return 8
	return maxi(
		ceili(
			float(maximum_heads)
			* float(TRAIL_SEGMENT_BUDGET_FPS)
			* clampf(trail_lifetime, 0.1, 8.0)
			* TRAIL_SEGMENT_CAPACITY_MARGIN
		),
		8
	)


func _layer_slot_count(layer_index: int) -> int:
	if layer_index < 0 or layer_index >= PALETTE_LAYER_COUNT:
		return 0
	if particle_slots <= layer_index:
		return 0
	return (
		floori(
			float(particle_slots - 1 - layer_index)
			/ float(PALETTE_LAYER_COUNT)
		)
		+ 1
	)


func _active_layer_slot_count(layer_index: int) -> int:
	var enabled_slot_count: int = ceili(
		float(maxi(particle_slots, 1)) * clampf(flow_rate, 0.0, 1.0)
	)
	if enabled_slot_count <= layer_index:
		return 0
	return (
		floori(
			float(enabled_slot_count - 1 - layer_index)
			/ float(PALETTE_LAYER_COUNT)
		)
		+ 1
	)


func _apply_gate() -> void:
	var gate_half_width_pixels: float = get_gate_half_width_pixels()
	for process_material in _process_material_layers:
		process_material.set_shader_parameter(&"gate_open", gate_open)
		process_material.set_shader_parameter(
			&"gate_half_width", gate_half_width_pixels
		)
	if _overlay != null:
		_overlay.call(&"set_gate_open", gate_open)
		_overlay.call(&"set_gate_half_width", gate_half_width_pixels)
	if is_node_ready():
		gate_changed.emit(screen_id, RESERVOIR_ID, gate_open, gate_width)


func _apply_interaction_geometry() -> void:
	var active_polygons := _gpu_interaction_polygons()
	var data_image := Image.create(
		INTERACTION_TEXTURE_WIDTH,
		1,
		false,
		Image.FORMAT_RGBAF
	)
	data_image.fill(Color(0.0, 0.0, 0.0, 0.0))
	var overlay_definitions: Array[Dictionary] = []
	for polygon_index in range(active_polygons.size()):
		var polygon := active_polygons[polygon_index]
		var native_vertices := _polygon_native_vertices(polygon.vertices)
		var bounds := _native_polygon_bounds(native_vertices)
		var centroid := _native_polygon_centroid(native_vertices)
		var orientation := (
			1.0 if _native_polygon_signed_area(native_vertices) >= 0.0 else -1.0
		)
		var record_start := polygon_index * INTERACTION_TEXELS_PER_POLYGON
		data_image.set_pixel(
			record_start,
			0,
			Color(
				float(polygon.mode),
				polygon.absorption_fraction,
				polygon.repellent_force,
				polygon.wave_strength
			)
		)
		data_image.set_pixel(
			record_start + 1,
			0,
			Color(
				float(native_vertices.size()),
				polygon.influence * PIXELS_PER_WORLD_UNIT,
				_stable_interaction_seed(polygon.element_id),
				orientation
			)
		)
		data_image.set_pixel(
			record_start + 2,
			0,
			Color(bounds.position.x, bounds.position.y, bounds.end.x, bounds.end.y)
		)
		data_image.set_pixel(
			record_start + 3,
			0,
			Color(centroid.x, centroid.y, 0.0, 1.0 if polygon.enabled else 0.0)
		)
		for vertex_index in range(native_vertices.size()):
			var vertex := native_vertices[vertex_index]
			data_image.set_pixel(
				record_start + 4 + vertex_index,
				0,
				Color(vertex.x, vertex.y, 0.0, 0.0)
			)
		overlay_definitions.append({
			"element_id": String(polygon.element_id),
			"vertices": native_vertices,
			"mode": GPUFlowInteractionPolygon.mode_name(polygon.mode),
			"enabled": polygon.enabled,
		})
	if _interaction_data_texture == null:
		_interaction_data_texture = ImageTexture.create_from_image(data_image)
	else:
		_interaction_data_texture.update(data_image)
	for process_material in _process_material_layers:
		process_material.set_shader_parameter(
			&"interaction_data_texture",
			_interaction_data_texture
		)
		process_material.set_shader_parameter(
			&"interaction_count",
			active_polygons.size()
		)
	if _overlay != null:
		_overlay.call(&"set_interaction_polygons", overlay_definitions)
	if is_node_ready():
		interaction_geometry_changed.emit(screen_id, active_polygons.size())


func _apply_source_geometry() -> void:
	_source_geometry_dirty = false
	if _source_texture_packer == null:
		_source_texture_packer = SOURCE_TEXTURE_PACKER_SCRIPT.new(
			STAGE_SIZE,
			WORLD_SIZE
		)
	var active_sources := _gpu_source_polygons()
	_source_texture_packer.pack_sources(active_sources)
	_source_data_texture = _source_texture_packer.get_texture()
	var packed_count := _source_texture_packer.get_record_count()
	for process_material in _process_material_layers:
		process_material.set_shader_parameter(
			&"source_data_texture",
			_source_data_texture
		)
		process_material.set_shader_parameter(&"source_count", packed_count)
		process_material.set_shader_parameter(&"source_admission_enabled", true)

	var overlay_definitions: Array[Dictionary] = []
	for record: Dictionary in _source_texture_packer.get_record_definitions():
		var vertices: PackedVector2Array = record["vertices_pixels"]
		var downstream_edges: Array[Dictionary] = []
		var edge_records: Array[Dictionary] = record["edge_records"]
		for edge_record: Dictionary in edge_records:
			if float(edge_record.get("weight", 0.0)) <= 0.000001:
				continue
			var edge_index := int(edge_record["edge_index"])
			downstream_edges.append({
				"edge_index": edge_index,
				"start": vertices[edge_index],
				"end": vertices[(edge_index + 1) % vertices.size()],
				"outward_normal": edge_record["outward_normal"],
			})
		overlay_definitions.append({
			"element_id": String(record["element_id"]),
			"vertices": vertices,
			"enabled": bool(record["enabled"]),
			"downstream_edges": downstream_edges,
		})
	if _overlay != null:
		_overlay.call(&"set_source_polygons", overlay_definitions)
	if is_node_ready():
		source_geometry_changed.emit(screen_id, packed_count)


func _gpu_interaction_polygons() -> Array[GPUFlowInteractionPolygon]:
	var result: Array[GPUFlowInteractionPolygon] = []
	var seen_ids: Dictionary = {}
	for polygon: GPUFlowInteractionPolygon in interaction_polygons:
		if result.size() >= MAX_INTERACTION_POLYGONS:
			break
		if (
			polygon == null
			or polygon.element_id == &""
			or seen_ids.has(polygon.element_id)
			or not GPUFlowInteractionPolygon.is_valid_polygon(polygon.vertices)
		):
			continue
		seen_ids[polygon.element_id] = true
		result.append(polygon)
	return result


func _gpu_source_polygons() -> Array[GPUFlowSourcePolygon]:
	var result: Array[GPUFlowSourcePolygon] = []
	var seen_ids: Dictionary = {}
	for source: GPUFlowSourcePolygon in source_polygons:
		if result.size() >= MAX_SOURCE_POLYGONS:
			break
		if (
			source == null
			or source.element_id == &""
			or seen_ids.has(source.element_id)
			or not source.validate().is_empty()
		):
			continue
		seen_ids[source.element_id] = true
		result.append(source)
	return result


func _polygon_native_vertices(world_vertices: PackedVector2Array) -> PackedVector2Array:
	var native_vertices := PackedVector2Array()
	for world_vertex: Vector2 in world_vertices:
		native_vertices.append(Vector2(
			world_vertex.x * PIXELS_PER_WORLD_UNIT,
			(WORLD_SIZE.y - world_vertex.y) * PIXELS_PER_WORLD_UNIT
		))
	return native_vertices


func _native_polygon_bounds(vertices: PackedVector2Array) -> Rect2:
	var minimum := vertices[0]
	var maximum := vertices[0]
	for vertex: Vector2 in vertices:
		minimum = minimum.min(vertex)
		maximum = maximum.max(vertex)
	return Rect2(minimum, maximum - minimum)


func _native_polygon_centroid(vertices: PackedVector2Array) -> Vector2:
	var centroid := Vector2.ZERO
	for vertex: Vector2 in vertices:
		centroid += vertex
	return centroid / float(maxi(vertices.size(), 1))


func _native_polygon_signed_area(vertices: PackedVector2Array) -> float:
	var twice_area := 0.0
	for vertex_index in range(vertices.size()):
		var current := vertices[vertex_index]
		var following := vertices[(vertex_index + 1) % vertices.size()]
		twice_area += current.x * following.y - following.x * current.y
	return twice_area * 0.5


func _stable_interaction_seed(element_id: StringName) -> float:
	var accumulator: int = 2166136261
	var text_id := String(element_id)
	for character_index in range(text_id.length()):
		accumulator = (
			((accumulator ^ text_id.unicode_at(character_index)) * 16777619)
			& 0x7fffffff
		)
	return float(accumulator % 1000003) / 1000003.0


func _apply_debug_visibility() -> void:
	if _overlay != null:
		_overlay.visible = debug_visible
	if is_node_ready():
		debug_visibility_changed.emit(screen_id, debug_visible)


func _defer_trail_recording_until_after_preprocess() -> void:
	# The head emitter prewarms eight seconds so screens open already populated.
	# A child sub-emitter does not age those prewarm emissions in lockstep; if
	# recording is left on, its pool initially fills with disconnected samples.
	# Keep storing the head's completed position during prewarm, then begin
	# immutable history on the first normal simulation tick.
	for process_material in _process_material_layers:
		process_material.set_shader_parameter(&"trail_recording_enabled", false)
		process_material.set_shader_parameter(&"reservoir_admission_enabled", false)
		process_material.set_shader_parameter(&"interaction_admission_enabled", false)
	_trail_recording_warmup_frames = TRAIL_PREWARM_GUARD_FRAMES


func _build_particles() -> void:
	# Each palette color owns one immutable segment pool. Global particle IDs are
	# interleaved across the seven head emitters, preserving an exact total slot
	# count and exact amount-ratio threshold while giving every color stable Z.
	_head_layers.clear()
	_trail_segment_layers.clear()
	_process_material_layers.clear()
	_trail_process_material_layers.clear()
	_draw_material_layers.clear()
	var segment_texture: ImageTexture = _make_segment_texture()
	var head_texture: ImageTexture = _make_head_texture()
	var interaction_image := Image.create(
		INTERACTION_TEXTURE_WIDTH,
		1,
		false,
		Image.FORMAT_RGBAF
	)
	interaction_image.fill(Color(0.0, 0.0, 0.0, 0.0))
	_interaction_data_texture = ImageTexture.create_from_image(interaction_image)
	var desired_lifetime: float = clampf(trail_lifetime, 0.1, 8.0)
	var desired_ratio: float = clampf(flow_rate, 0.0, 1.0)
	for layer_index in range(PALETTE_LAYER_COUNT):
		# The child emitter owns immutable, fading motion samples. It must exist
		# before its head emitter so the parent can address it as a sub-emitter.
		var segment_layer := GPUParticles2D.new()
		segment_layer.name = (
			"FlowLineTrailSegments"
			if layer_index == 0
			else "FlowLineTrailSegments%d" % (layer_index + 1)
		)
		segment_layer.emitting = false
		segment_layer.amount = _required_trail_segment_capacity_for_layer(
			layer_index
		)
		segment_layer.amount_ratio = 1.0
		segment_layer.lifetime = desired_lifetime
		segment_layer.preprocess = 0.0
		# Render-paced parent append and child consume passes prevent a fixed-step
		# catch-up frame from overwriting one immutable sub-emission batch.
		segment_layer.fixed_fps = PARTICLE_FIXED_FPS
		segment_layer.interpolate = false
		segment_layer.fract_delta = false
		segment_layer.randomness = 0.0
		segment_layer.explosiveness = 0.0
		segment_layer.local_coords = true
		segment_layer.use_fixed_seed = true
		segment_layer.seed = 9301 + stage_index * 997 + layer_index * 131
		segment_layer.visibility_rect = Rect2(
			Vector2(-256.0, -256.0),
			STAGE_SIZE + Vector2(512.0, 512.0)
		)
		segment_layer.trail_enabled = false
		var segment_process_material := ShaderMaterial.new()
		segment_process_material.shader = SEGMENT_PARTICLE_SHADER
		segment_layer.process_material = segment_process_material
		var segment_draw_material := ShaderMaterial.new()
		segment_draw_material.shader = DRAW_SHADER
		segment_layer.material = segment_draw_material
		segment_layer.texture = segment_texture
		segment_layer.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		segment_layer.z_index = layer_index
		segment_layer.z_as_relative = false
		_water_canvas.add_child(segment_layer)
		_trail_segment_layers.append(segment_layer)
		_trail_process_material_layers.append(segment_process_material)
		_draw_material_layers.append(segment_draw_material)

		var process_material := ShaderMaterial.new()
		process_material.shader = PARTICLE_SHADER
		process_material.set_shader_parameter(&"trail_recording_enabled", false)
		process_material.set_shader_parameter(&"reservoir_admission_enabled", false)
		process_material.set_shader_parameter(&"interaction_admission_enabled", false)
		process_material.set_shader_parameter(&"interaction_count", 0)
		process_material.set_shader_parameter(
			&"interaction_data_texture",
			_interaction_data_texture
		)
		process_material.set_shader_parameter(&"source_count", 0)
		process_material.set_shader_parameter(&"source_admission_enabled", true)
		process_material.set_shader_parameter(
			&"source_data_texture",
			_source_data_texture
		)
		process_material.set_shader_parameter(
			&"particle_index_stride", float(PALETTE_LAYER_COUNT)
		)
		process_material.set_shader_parameter(
			&"particle_index_offset", float(layer_index)
		)
		process_material.set_shader_parameter(&"force_palette_color", true)
		process_material.set_shader_parameter(
			&"forced_palette_color", FLOW_PALETTE[layer_index]
		)
		var head_layer := GPUParticles2D.new()
		head_layer.name = (
			"FlowLineHeads"
			if layer_index == 0
			else "FlowLineHeads%d" % (layer_index + 1)
		)
		head_layer.amount = maxi(_layer_slot_count(layer_index), 1)
		head_layer.amount_ratio = desired_ratio
		head_layer.lifetime = 8.0
		head_layer.preprocess = 8.0
		head_layer.fixed_fps = PARTICLE_FIXED_FPS
		head_layer.interpolate = true
		head_layer.fract_delta = false
		head_layer.randomness = 0.0
		head_layer.explosiveness = 0.0
		head_layer.local_coords = true
		head_layer.use_fixed_seed = true
		head_layer.seed = 7301 + stage_index * 997 + layer_index * 131
		head_layer.visibility_rect = Rect2(
			Vector2(-256.0, -256.0),
			STAGE_SIZE + Vector2(512.0, 512.0)
		)
		head_layer.trail_enabled = false
		head_layer.process_material = process_material
		var head_draw_material := ShaderMaterial.new()
		head_draw_material.shader = HEAD_DRAW_SHADER
		head_layer.material = head_draw_material
		head_layer.texture = head_texture
		head_layer.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
		head_layer.z_index = layer_index
		head_layer.z_as_relative = false
		_water_canvas.add_child(head_layer)
		head_layer.sub_emitter = head_layer.get_path_to(segment_layer)
		_head_layers.append(head_layer)
		_process_material_layers.append(process_material)

	# Preserve the original scalar fields as first-layer compatibility aliases.
	particles = _head_layers[0]
	_trail_segments = _trail_segment_layers[0]
	_process_material = _process_material_layers[0]
	_trail_process_material = _trail_process_material_layers[0]
	_draw_material = _draw_material_layers[0]
	_trail_recording_warmup_frames = TRAIL_PREWARM_GUARD_FRAMES


func _build_background() -> void:
	_background_rect = ColorRect.new()
	_background_rect.name = "Background"
	_background_rect.position = Vector2.ZERO
	_background_rect.size = STAGE_SIZE
	_background_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_background_rect.z_index = BACKGROUND_Z_INDEX
	_background_rect.z_as_relative = false
	add_child(_background_rect)
	_apply_background_color()


func _apply_background_color() -> void:
	if _background_rect != null:
		_background_rect.color = background_color


func _build_background_grid() -> void:
	_background_grid = Node2D.new()
	_background_grid.name = "BackgroundGrid"
	_background_grid.z_index = BACKGROUND_GRID_Z_INDEX
	_background_grid.z_as_relative = false
	add_child(_background_grid)
	_rebuild_background_grid()


func _apply_background_grid() -> void:
	if _background_grid != null:
		_background_grid.visible = stage_grid_visible


func _rebuild_background_grid() -> void:
	if _background_grid == null:
		return
	for child in _background_grid.get_children():
		_background_grid.remove_child(child)
		child.queue_free()

	var spacing := maxf(stage_grid_spacing_pixels, 1.0)
	# Start one interval in and stop before the far boundary. The grid is a
	# modeling reference, not a frame around the screen.
	var x := spacing
	while x < STAGE_SIZE.x:
		var line_x := x + 0.5
		_add_background_grid_line(
			Vector2(line_x, 0.0),
			Vector2(line_x, STAGE_SIZE.y)
		)
		x += spacing

	var y := spacing
	while y < STAGE_SIZE.y:
		var line_y := y + 0.5
		_add_background_grid_line(
			Vector2(0.0, line_y),
			Vector2(STAGE_SIZE.x, line_y)
		)
		y += spacing
	_apply_background_grid()


func _add_background_grid_line(
	start_point: Vector2,
	end_point: Vector2
) -> void:
	var line := Line2D.new()
	line.width = stage_grid_line_width_pixels
	line.default_color = stage_grid_color
	line.antialiased = false
	line.add_point(start_point)
	line.add_point(end_point)
	_background_grid.add_child(line)


func _build_water_render_surface() -> void:
	# Water is rendered once into a transparent viewport. Its texture is both the
	# visible water layer and the authoritative occupancy input for salmon and
	# leaves. Background/debug/ecology stay outside this viewport so a
	# nonzero alpha sample always means visible water.
	_water_viewport = SubViewport.new()
	_water_viewport.name = "WaterOnlyViewport"
	_water_viewport.size = Vector2i(int(STAGE_SIZE.x), int(STAGE_SIZE.y))
	_water_viewport.transparent_bg = true
	_water_viewport.disable_3d = true
	_water_viewport.gui_disable_input = true
	_water_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_water_viewport.render_target_clear_mode = SubViewport.CLEAR_MODE_ALWAYS
	_water_viewport.msaa_2d = Viewport.MSAA_4X
	add_child(_water_viewport)

	_water_canvas = Node2D.new()
	_water_canvas.name = "WaterOnlyCanvas"
	_water_viewport.add_child(_water_canvas)

	var water_display := Sprite2D.new()
	water_display.name = "WaterTextureDisplay"
	water_display.centered = false
	water_display.texture = _water_viewport.get_texture()
	water_display.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	var composite_material := ShaderMaterial.new()
	composite_material.shader = WATER_COMPOSITE_SHADER
	water_display.material = composite_material
	water_display.z_index = 0
	water_display.z_as_relative = false
	add_child(water_display)


func get_water_texture() -> Texture2D:
	if _water_viewport == null:
		return null
	return _water_viewport.get_texture()


func _build_salmon() -> void:
	_salmon_school = SALMON_SCRIPT.new() as GPUSalmon2D
	_salmon_school.name = "GPUSalmonSchool"
	# Salmon must remain outside WaterOnlyViewport or they would count themselves
	# as water on the next occupancy sample.
	add_child(_salmon_school)
	_salmon_school.set_water_texture(get_water_texture())
	var release_callback := Callable(self, &"_on_salmon_released")
	if not _salmon_school.salmon_released.is_connected(release_callback):
		_salmon_school.salmon_released.connect(release_callback)


func _on_salmon_released(
	requested_count: int,
	scheduled_count: int,
	release_serial: int
) -> void:
	salmon_released.emit(
		screen_id,
		requested_count,
		scheduled_count,
		release_serial
	)


func _build_leaves() -> void:
	_leaf_field = LEAF_SCRIPT.new() as GPULeaf2D
	_leaf_field.name = "GPULeafField"
	# Leaves sample water occupancy and therefore remain siblings of the
	# WaterOnlyViewport, never children of its feedback-free water canvas.
	add_child(_leaf_field)
	_leaf_field.set_water_texture(get_water_texture())
	var release_callback := Callable(self, &"_on_leaves_released")
	if not _leaf_field.leaves_released.is_connected(release_callback):
		_leaf_field.leaves_released.connect(release_callback)


func _on_leaves_released(
	requested_count_per_side: int,
	scheduled_top_count: int,
	scheduled_bottom_count: int,
	scheduled_total_count: int,
	release_serial: int
) -> void:
	leaves_released.emit(
		screen_id,
		requested_count_per_side,
		scheduled_top_count,
		scheduled_bottom_count,
		scheduled_total_count,
		release_serial
	)


func _build_overlay() -> void:
	_overlay = OVERLAY_SCRIPT.new() as Node2D
	_overlay.name = "ReservoirAndStatusOverlay"
	_overlay.z_index = 100
	_overlay.z_as_relative = false
	_overlay.set(&"stage_index", stage_index)
	_overlay.set(&"show_status_label", false)
	_overlay.call(
		&"set_reservoir_geometry",
		reservoir_center_pixels,
		reservoir_radius_pixels
	)
	add_child(_overlay)


func _build_stage_title() -> void:
	_stage_title_layer = Node2D.new()
	_stage_title_layer.name = "StageTitleLayer"
	_stage_title_layer.z_index = STAGE_TITLE_Z_INDEX
	_stage_title_layer.z_as_relative = false
	add_child(_stage_title_layer)

	_stage_title_label = Label.new()
	_stage_title_label.name = "StageTitle"
	_stage_title_label.position = STAGE_TITLE_POSITION
	_stage_title_label.size = Vector2(
		STAGE_SIZE.x - STAGE_TITLE_POSITION.x * 2.0,
		96.0
	)
	_stage_title_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_stage_title_label.focus_mode = Control.FOCUS_NONE
	_stage_title_label.autowrap_mode = TextServer.AUTOWRAP_OFF
	_stage_title_label.clip_text = false
	_stage_title_label.add_theme_font_override(&"font", STAGE_TITLE_FONT)
	_stage_title_label.add_theme_font_size_override(
		&"font_size",
		STAGE_TITLE_FONT_SIZE
	)
	_stage_title_label.add_theme_color_override(
		&"font_color",
		STAGE_TITLE_COLOR
	)
	_stage_title_layer.add_child(_stage_title_label)

	_model_date_label = Label.new()
	_model_date_label.name = "ModelDate"
	_model_date_label.position = MODEL_DATE_POSITION
	_model_date_label.size = MODEL_DATE_LABEL_SIZE
	_model_date_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_model_date_label.focus_mode = Control.FOCUS_NONE
	_model_date_label.autowrap_mode = TextServer.AUTOWRAP_OFF
	_model_date_label.clip_text = false
	_model_date_label.add_theme_font_override(&"font", STAGE_TITLE_FONT)
	_model_date_label.add_theme_font_size_override(
		&"font_size",
		STAGE_TITLE_FONT_SIZE
	)
	_model_date_label.add_theme_color_override(
		&"font_color",
		STAGE_TITLE_COLOR
	)
	_stage_title_layer.add_child(_model_date_label)
	_apply_stage_title()
	_apply_model_date()


func _apply_stage_title() -> void:
	if _stage_title_label == null:
		return
	_stage_title_label.text = stage_title
	_stage_title_label.visible = stage_title_visible
	if is_node_ready():
		stage_title_changed.emit(screen_id, stage_title, stage_title_visible)


func _load_watershed_data() -> bool:
	_watershed_raw_values = PackedFloat32Array()
	_watershed_normalized_flow = PackedFloat32Array()
	_watershed_scaled_flow = PackedFloat32Array()
	_watershed_high_variation = PackedByteArray()
	_watershed_data_river = ""
	_watershed_data_error = ""
	_watershed_row_index = -1
	_watershed_row_fraction = 0.0
	_watershed_interpolated_flow_rate = 0.0

	if watershed_data_path.is_empty():
		return false
	if not FileAccess.file_exists(watershed_data_path):
		_watershed_data_error = "Watershed data file not found: %s" % watershed_data_path
		push_warning(_watershed_data_error)
		return false

	var contents := FileAccess.get_file_as_string(watershed_data_path)
	for raw_line in contents.split("\n", false):
		var line := String(raw_line).strip_edges()
		if line.is_empty():
			continue
		if line.begins_with("#"):
			for metadata_token in line.trim_prefix("#").strip_edges().split(" ", false):
				var token := String(metadata_token)
				if token.begins_with("river="):
					_watershed_data_river = token.trim_prefix("river=")
			continue
		if line.begins_with("frame"):
			continue
		var columns := line.split("\t", false)
		if columns.size() < 5:
			continue
		if (
			not String(columns[0]).is_valid_int()
			or not String(columns[1]).is_valid_float()
			or not String(columns[2]).is_valid_float()
			or not String(columns[3]).is_valid_float()
			or not String(columns[4]).is_valid_int()
		):
			continue
		# The pipeline calls this column `cfs`, but Delta currently contains
		# gauge height in feet. Keep the runtime field unit-neutral.
		_watershed_raw_values.append(float(columns[1]))
		_watershed_normalized_flow.append(
			clampf(float(columns[2]), 0.0, 1.0)
		)
		_watershed_scaled_flow.append(float(columns[3]))
		_watershed_high_variation.append(1 if int(columns[4]) != 0 else 0)

	if _watershed_normalized_flow.is_empty():
		_watershed_data_error = "Watershed data file has no valid rows: %s" % watershed_data_path
		push_warning(_watershed_data_error)
		return false
	if watershed_data_drives_flow_rate:
		flow_rate = float(_watershed_normalized_flow[0])
	return true


func _update_watershed_timeline() -> void:
	var row_count := _watershed_normalized_flow.size()
	if row_count <= 0:
		return
	var year_seconds := maxf(model_year_duration_seconds, 0.001)
	var year_progress := clampf(
		_model_year_elapsed_seconds / year_seconds,
		0.0,
		0.999999
	)
	var row_position := year_progress * float(row_count)
	var next_row_index := mini(floori(row_position), row_count - 1)
	var row_fraction := row_position - floorf(row_position)
	var following_row_index := (next_row_index + 1) % row_count
	var current_normalized := float(
		_watershed_normalized_flow[next_row_index]
	)
	var following_normalized := float(
		_watershed_normalized_flow[following_row_index]
	)
	_watershed_interpolated_flow_rate = (
		lerpf(current_normalized, following_normalized, row_fraction)
		if watershed_interpolate_flow_rate
		else current_normalized
	)
	_watershed_row_fraction = row_fraction
	var row_changed := next_row_index != _watershed_row_index
	_watershed_row_index = next_row_index

	if watershed_data_drives_flow_rate:
		flow_rate = clampf(_watershed_interpolated_flow_rate, 0.0, 1.0)
		if not _process_material_layers.is_empty():
			_apply_water_rate_parameters()

	if row_changed and is_node_ready():
		watershed_data_row_changed.emit(
			screen_id,
			_watershed_row_index,
			row_count,
			float(_watershed_raw_values[_watershed_row_index]),
			float(_watershed_normalized_flow[_watershed_row_index]),
			float(_watershed_scaled_flow[_watershed_row_index]),
			bool(_watershed_high_variation[_watershed_row_index]),
			_format_model_date_time(_model_day_index, _model_minute_of_day)
		)


func _advance_model_calendar(delta: float) -> void:
	if _paused or not model_calendar_auto_advance or delta <= 0.0:
		return
	var year_seconds := maxf(model_year_duration_seconds, 0.001)
	_model_year_elapsed_seconds = fposmod(
		_model_year_elapsed_seconds + delta,
		year_seconds
	)
	var relative_model_minute := mini(
		floori(
			_model_year_elapsed_seconds
			* float(MODEL_YEAR_MINUTE_COUNT)
			/ year_seconds
		),
		MODEL_YEAR_MINUTE_COUNT - 1
	)
	var relative_day: int = floori(
		float(relative_model_minute) / float(MODEL_MINUTES_PER_DAY)
	)
	var next_minute_of_day := relative_model_minute % MODEL_MINUTES_PER_DAY
	var next_day_index: int = posmod(
		model_start_day_index + relative_day,
		MODEL_CALENDAR_DAY_COUNT
	)
	var day_changed := next_day_index != _model_day_index
	var time_changed := (
		day_changed or next_minute_of_day != _model_minute_of_day
	)
	_model_day_index = next_day_index
	_model_minute_of_day = next_minute_of_day
	if time_changed:
		_apply_model_date(day_changed)
	_update_watershed_timeline()


func _reset_model_calendar() -> void:
	_model_year_elapsed_seconds = 0.0
	_model_day_index = clampi(
		model_start_day_index,
		0,
		MODEL_CALENDAR_DAY_COUNT - 1
	)
	_model_minute_of_day = 0
	if model_calendar_auto_advance:
		_model_date_source = &"internal_clock"
	elif _model_date_source not in [&"external_mm_dd", &"external_day_index"]:
		_model_date_source = &"manual_hold"
	_apply_model_date()
	_update_watershed_timeline()


func _set_model_day_index(day_index: int) -> void:
	_model_day_index = posmod(day_index, MODEL_CALENDAR_DAY_COUNT)
	_model_minute_of_day = 0
	_apply_model_date()
	_update_watershed_timeline()


func _align_model_elapsed_to_current_day() -> void:
	var relative_day: int = posmod(
		_model_day_index - model_start_day_index,
		MODEL_CALENDAR_DAY_COUNT
	)
	_model_year_elapsed_seconds = (
		(
			float(relative_day)
			+ float(_model_minute_of_day) / float(MODEL_MINUTES_PER_DAY)
		)
		/ float(MODEL_CALENDAR_DAY_COUNT)
		* maxf(model_year_duration_seconds, 0.001)
	)


func _apply_model_date(emit_date_signal: bool = true) -> void:
	if _model_date_label == null:
		return
	var date_time := _format_model_date_time(
		_model_day_index,
		_model_minute_of_day
	)
	_model_date_label.text = date_time
	_model_date_label.visible = stage_date_visible
	if emit_date_signal and is_node_ready():
		model_date_changed.emit(
			screen_id,
			_format_model_date(_model_day_index),
			_model_day_index + 1
		)


func _format_model_date(day_index: int) -> String:
	var remaining_days: int = posmod(day_index, MODEL_CALENDAR_DAY_COUNT)
	for month_index in range(MODEL_MONTH_LENGTHS.size()):
		var days_in_month := int(MODEL_MONTH_LENGTHS[month_index])
		if remaining_days < days_in_month:
			return "%02d/%02d" % [month_index + 1, remaining_days + 1]
		remaining_days -= days_in_month
	return "12/31"


func _format_model_date_time(day_index: int, minute_of_day: int) -> String:
	var clamped_minute: int = clampi(
		minute_of_day,
		0,
		MODEL_MINUTES_PER_DAY - 1
	)
	var hours: int = floori(float(clamped_minute) / 60.0)
	var minutes: int = clamped_minute % 60
	return "%s-%02d:%02d" % [_format_model_date(day_index), hours, minutes]


func _parse_model_date_time(model_date_time: String) -> Vector2i:
	var normalized := model_date_time.strip_edges()
	if normalized.is_empty():
		return Vector2i(-1, -1)
	# Accept the earlier slash separator as input compatibility, but always render
	# the clearer canonical form MM/DD-HH:MM.
	var date_and_time := normalized.split("-", false, 1)
	if date_and_time.size() == 1:
		var legacy_parts := normalized.split("/", false)
		if legacy_parts.size() == 3:
			date_and_time = PackedStringArray([
				"%s/%s" % [legacy_parts[0], legacy_parts[1]],
				legacy_parts[2],
			])
	if date_and_time.is_empty() or date_and_time.size() > 2:
		return Vector2i(-1, -1)
	var parts := String(date_and_time[0]).split("/", false)
	if parts.size() != 2:
		return Vector2i(-1, -1)
	if not String(parts[0]).is_valid_int() or not String(parts[1]).is_valid_int():
		return Vector2i(-1, -1)
	var month := int(parts[0])
	var day := int(parts[1])
	if month < 1 or month > MODEL_MONTH_LENGTHS.size():
		return Vector2i(-1, -1)
	var days_in_month := int(MODEL_MONTH_LENGTHS[month - 1])
	if day < 1 or day > days_in_month:
		return Vector2i(-1, -1)
	var day_index := day - 1
	for month_index in range(month - 1):
		day_index += int(MODEL_MONTH_LENGTHS[month_index])
	var minute_of_day := 0
	if date_and_time.size() == 2:
		var time_parts := String(date_and_time[1]).split(":", false)
		if (
			time_parts.size() != 2
			or not String(time_parts[0]).is_valid_int()
			or not String(time_parts[1]).is_valid_int()
		):
			return Vector2i(-1, -1)
		var hours := int(time_parts[0])
		var minutes := int(time_parts[1])
		if hours < 0 or hours > 23 or minutes < 0 or minutes > 59:
			return Vector2i(-1, -1)
		minute_of_day = hours * 60 + minutes
	return Vector2i(day_index, minute_of_day)


func _make_segment_texture() -> ImageTexture:
	# One source pixel along the motion axis and an eight-pixel anti-aliased
	# width envelope. The emitted transform supplies each segment's length.
	var image := Image.create(1, 8, false, Image.FORMAT_RGBA8)
	image.fill(Color.WHITE)
	return ImageTexture.create_from_image(image)


func _make_head_texture() -> ImageTexture:
	var image := Image.create(1, 1, false, Image.FORMAT_RGBA8)
	image.fill(Color.WHITE)
	return ImageTexture.create_from_image(image)
