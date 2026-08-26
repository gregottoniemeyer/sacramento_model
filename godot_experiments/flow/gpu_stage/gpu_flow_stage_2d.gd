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
signal regimes_changed(
	screen_id: StringName,
	active_names: Array,
	active_indices: Array,
	revision: int
)
signal basin_budget_changed(
	screen_id: StringName,
	input_rate: float,
	extraction_fraction: float,
	remaining_rate: float
)
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
const BasinBudgetModel := preload("res://flow/basin_budget.gd")
const BASIN_BUDGET_OVERLAY_SCRIPT := preload(
	"res://flow/gpu_stage/basin_budget_overlay.gd"
)
const GPUFlowInteractionPolygon = preload(
	"res://flow/gpu_stage/gpu_flow_interaction_polygon.gd"
)
const STAGE_TITLE_FONT := preload(
	"res://flow/assets/fonts/BarlowCondensed-Medium.ttf"
)

const STAGE_SIZE := Vector2(1920.0, 1080.0)
const WORLD_SIZE := Vector2(16.0, 9.0)
const PIXELS_PER_WORLD_UNIT := STAGE_SIZE.x / WORLD_SIZE.x
const PARTICLE_FIXED_FPS := 0
const HEAD_EMISSION_CYCLE_SECONDS := 8.0
const HEAD_PREPROCESS_SECONDS := 16.0
const HEAD_EMISSION_RANDOMNESS := 0.0
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
const WATERSHED_AI_CONTROL_SCOPE := "watershed-ai/2"
const WATERSHED_AI_STATE_PATH := "watershed.ai.state"
const WATERSHED_AI_STATE_SCHEMA_VERSION := 2
const WATERSHED_REGIME_INDEX := 6
const WATER_PROJECTS_REGIME_INDEX := 3
const WATERSHED_AI_TOP_LEVEL_FIELDS: Array[String] = [
	"protocol",
	"revision",
	"target",
	"changes",
	"geometry_ops",
	"actions",
	"metadata",
	"control_scope",
]
const WATERSHED_AI_STATE_FIELDS: Array[String] = [
	"schema_version",
	"decision_id",
	"atmospheric_input_rate",
	"reservoir_release_rate",
	"available_supply_rate",
	"extraction_fraction",
	"remaining_rate",
	"salmon_fraction",
	"floodplain_fraction",
	"agriculture_fraction",
	"data_center_fraction",
	"city_fraction",
	"reservoir_storage_fraction",
	"hydropower_fraction",
	"water_project_fraction",
]
const WATERSHED_AI_FRACTION_FIELDS: Array[String] = [
	"atmospheric_input_rate",
	"reservoir_release_rate",
	"available_supply_rate",
	"extraction_fraction",
	"remaining_rate",
	"salmon_fraction",
	"floodplain_fraction",
	"agriculture_fraction",
	"data_center_fraction",
	"city_fraction",
	"reservoir_storage_fraction",
	"hydropower_fraction",
	"water_project_fraction",
]
const RESERVOIR_ID := &"reservoir_main"
const MIN_GATE_WIDTH := 0.0
const MAX_GATE_WIDTH := 10.0
const DEFAULT_MAX_FLOW_SPEED_PIXELS := 600.0
const MAX_INTERACTION_POLYGONS := 8
const INTERACTION_TEXELS_PER_POLYGON := 16
const INTERACTION_TEXTURE_WIDTH := (
	MAX_INTERACTION_POLYGONS * INTERACTION_TEXELS_PER_POLYGON
)
const SHORELINE_OBSTACLE_COUNT := 2
const SHORELINE_EDGE_SPAN_COUNT := 16
const SHORELINE_EDGE_VERTEX_COUNT := SHORELINE_EDGE_SPAN_COUNT + 1
const SHORELINE_TOP_ID := &"shoreline_obstacle_top"
const SHORELINE_BOTTOM_ID := &"shoreline_obstacle_bottom"
const SHORELINE_MAX_INTRUSION_WORLD := 2.60
const SHORELINE_MIN_CHANNEL_HEIGHT_WORLD := 5.25
const SHORELINE_INFLUENCE_WORLD := 0.75
const SHORELINE_INLET_BASE_MARGIN_PIXELS := 28.0
const SHORELINE_CLOSURE_MARGIN_WORLD := 2.0
const EDGE_TURBULENCE_BAND_PIXELS := 180.0
const EDGE_TURBULENCE_WALL_BAND_PIXELS := 40.0
const EDGE_TURBULENCE_CROSSFLOW_RATIO := 0.65
const EDGE_TURBULENCE_STREAMWISE_RATIO := 0.08
const EDGE_TURBULENCE_INWARD_RATIO := 0.75
const REGIME_GEOMETRY_BASELINE_KEY := "authored"
const REGIME_GEOMETRY_WORLD_EDGE_MARGIN := 0.25
const REGIME_RESERVOIR_X_FRACTION_RANGE := Vector2(0.32, 0.82)
const REGIME_RESERVOIR_Y_FRACTION_RANGE := Vector2(0.24, 0.76)
const REGIME_DRAIN_SLOT_CAPACITY := 5
const REGIME_OBSTACLE_SLOT_CAPACITY := 2
const REGIME_FIELD_X_RANGE := Vector2(1.50, 14.50)
const REGIME_FIELD_LANE_PADDING_WORLD := 0.18
const REGIME_FIELD_ROOT_WIDTH_RANGE := Vector2(0.90, 1.30)
const REGIME_FIELD_DEPTH_RANGE := Vector2(1.55, 2.15)
const BANK_FIELD_SUCTION_REACH_PIXELS := 720.0
const BANK_FIELD_SUCTION_CROSSFLOW_RATIO := 3.0
const BANK_FIELD_SUCTION_STREAMWISE_RATIO := 0.0
const BANK_FIELD_MIN_WITHDRAWAL_SPEED_PIXELS := 720.0
const BANK_FIELD_CAPTURE_DEPTH_PIXELS := 18.0
const INTERACTION_BANK_EDGE_EPSILON_PIXELS := 1.0
const TYPE_ROTATION_RADIANS := -PI * 0.5
const TYPE_ROTATION_DEGREES := -90.0
const STAGE_TITLE_POSITION := Vector2(60.0, 540.0)
const STAGE_TITLE_COLOR := Color("4ab0e1")
const STAGE_TITLE_FONT_SIZE := 60
const MODEL_DATE_FONT_SIZE := 48
const MODEL_DATE_OPENTYPE_FEATURE := "tnum"
const MODEL_DATE_POSITION := Vector2(1860.0, 540.0)
const WATER_TEMPERATURE_EXPECTED_ROW_COUNT := 720
const DELTA_TIDE_EXPECTED_ROW_COUNT := 8760
const FLOW_DENSITY_LOW_RATE := 0.01
const FLOW_DENSITY_LOW_LINE_COUNT := 20
const FLOW_DENSITY_FULL_LINE_COUNT := 1000
const DELTA_TIDE_DATA_PATH := (
	"res://flow/data/tide/sf_bay_9414290_tide_hourly_2025_2026.txt"
)
const WATER_TEMPERATURE_INTERPOLATION_MODE := (
	"HALF_OPEN_ANNUAL_LINEAR_WRAP"
)
const REGIME_PANEL_POSITION := Vector2(1324.0, 1050.0)
const REGIME_HEADING_TEXT := "Regime"
const REGIME_HEADING_FONT_SIZE := 48
const REGIME_NAME_FONT_SIZE := STAGE_TITLE_FONT_SIZE
const REGIME_HEADING_LOCAL_Y := 6.0
const REGIME_NAME_START_Y := 60.0
const REGIME_NAME_ROW_HEIGHT := 72.0
const REGIME_ACTIVE_ALPHA := 1.0
const REGIME_INACTIVE_ALPHA := 0.25
const DELTA_WATER_PROJECT_DISPLAY_NAME := "Water Project"
const DELTA_WATERSHED_DISPLAY_NAME := "AI Watershed"
const MODEL_CALENDAR_DAY_COUNT := 365
const MODEL_MINUTES_PER_DAY := 1440
const MODEL_YEAR_MINUTE_COUNT := MODEL_CALENDAR_DAY_COUNT * MODEL_MINUTES_PER_DAY
const MODEL_YEAR_FRAMES_AT_30_FPS := 21600
const MODEL_MONTH_LENGTHS := [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
const BACKGROUND_Z_INDEX := -100
const BACKGROUND_GRID_Z_INDEX := -75
const TIDE_OVERLAY_Z_INDEX := -60
const STAGE_TITLE_Z_INDEX := -50
const GEOMETRY_OVERLAY_Z_INDEX := -1
const WATER_DISPLAY_Z_INDEX := 0
const MORNING_FOG_START_MINUTE := 3 * 60
const MORNING_FOG_END_MINUTE := 10 * 60
const BASIN_INPUT_RUNNING_AVERAGE_DAYS := 30.0
const BASIN_INPUT_MINIMUM_RATE := 0.02
const MORNING_FOG_WINDOW_MINUTES := (
	MORNING_FOG_END_MINUTE - MORNING_FOG_START_MINUTE
)
const MORNING_FOG_PEAK_MULTIPLIER := (
	PI * float(MODEL_MINUTES_PER_DAY)
	/ (2.0 * float(MORNING_FOG_WINDOW_MINUTES))
)
const DEFAULT_GRID_COLOR := Color(
	74.0 / 255.0,
	176.0 / 255.0,
	225.0 / 255.0,
	0.25
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
@export var regime_panel_visible: bool = false:
	set(value):
		regime_panel_visible = value
		_apply_regime_panel()
@export var regime_heading_visible: bool = true:
	set(value):
		regime_heading_visible = value
		_apply_regime_panel()

@export_group("Regime Modulation")
@export var regime_profile_physics_enabled: bool = false

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
@export var stage_temperature_visible: bool = false:
	set(value):
		stage_temperature_visible = value
		_apply_water_temperature()
@export_range(1.0, 86400.0, 1.0) var model_year_duration_seconds: float = 720.0
@export_range(0, MODEL_CALENDAR_DAY_COUNT - 1, 1) var model_start_day_index: int = 0
@export var model_calendar_auto_advance: bool = true

@export_group("Watershed Data")
@export_file("*.txt") var watershed_data_path: String = ""
@export var watershed_data_drives_flow_rate: bool = true
@export var watershed_interpolate_flow_rate: bool = true

@export_group("Water Temperature")
@export_file("*.txt") var temperature_data_path: String = "":
	set(value):
		temperature_data_path = value
		if is_node_ready():
			_load_temperature_data()
			_update_temperature_timeline()
@export var temperature_data_column: String = "":
	set(value):
		temperature_data_column = value
		if is_node_ready():
			_load_temperature_data()
			_update_temperature_timeline()

@export_group("Runtime")
@export var auto_start: bool = true
@export var accept_keyboard_input: bool = true
@export var debug_visible: bool = true:
	set(_value):
		debug_visible = true
		_apply_debug_visibility()

@export_group("Particles")
@export_range(1, 2000, 1) var particle_slots: int = 1000
@export_range(0.0, 1.0, 0.01) var flow_rate: float = 0.5
@export_range(1.0, 2400.0, 1.0) var flow_speed_pixels: float = DEFAULT_MAX_FLOW_SPEED_PIXELS
@export_range(0.000001, 1.0, 0.000001) var min_active_flow: float = 0.25
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
@export_range(1.0, 4096.0, 1.0) var leaf_free_search_max_distance_pixels: float = 540.0
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
var _stage_title_font: FontVariation
var _model_date_label: Label
var _model_timeline: Node
var _model_regimes: Node
var _basin_budget_canvas: CanvasLayer
var _basin_budget_overlay: Node2D
var _delta_tide_overlay: Node2D
var _regime_panel: Node2D
var _regime_heading_label: Label
var _regime_name_labels: Array[Label] = []
var _regime_snapshot: Dictionary = {}
var _regime_extractor_polygons: Array[GPUFlowInteractionPolygon] = []
var _basin_input_rate: float = 0.5
var _basin_extraction_fraction: float = 0.0
var _basin_remaining_rate: float = 0.5
var _water_viewport: SubViewport
var _water_canvas: Node2D
var _salmon_school: GPUSalmon2D
var _leaf_field: GPULeaf2D
var _interaction_data_texture: ImageTexture
var _shoreline_obstacles: Array[Dictionary] = []
var _shoreline_randomness: float = 0.0
var _edge_turbulence_parameter_upload_count: int = 0
var _regime_feature_state_for_screen: Dictionary = {}
var _regime_reservoir_override_enabled: bool = false
var _regime_reservoir_count_override_enabled: bool = false
var _regime_drain_override_enabled: bool = false
var _regime_drain_power_override_enabled: bool = false
var _regime_obstacle_override_enabled: bool = false
var _regime_obstacle_power_override_enabled: bool = false
var _regime_reservoir_present: bool = true
var _regime_drain_present: bool = true
var _regime_obstacle_present: bool = true
var _regime_reservoir_weight: float = 1.0
var _regime_drain_weight: float = 1.0
var _regime_drain_power: float = 1.0
var _regime_obstacle_weight: float = 1.0
var _regime_obstacle_power: float = 1.0
var _regime_reservoir_count: float = 0.0
var _regime_gate_override_enabled: bool = false
var _regime_gate_open_fraction: float = 1.0
var _regime_gate_aperture_override_enabled: bool = false
var _regime_gate_aperture_fraction: float = 0.0
var _regime_salmon_activity: float = 0.0
var _regime_leaf_activity: float = 0.0
var _last_regime_salmon_release_day: int = -1
var _last_regime_leaf_release_day: int = -1
var _regime_geometry_initialized: bool = false
var _authored_reservoir_center_pixels := Vector2.ZERO
var _authored_interaction_vertices: Dictionary = {}
var _authored_interaction_instance_ids: Dictionary = {}
var _authored_interaction_enabled: Dictionary = {}
var _applied_regime_geometry_keys: Dictionary = {
	"reservoir": "",
	"drain": "",
	"obstacle": "",
}
var _reservoir_geometry_revision: int = 0
var _applied_regime_state_revision: int = -1
var _regime_layout_generation: int = 0
var _regime_layout_active_signature: String = ""
var _regime_geometry_update_count: int = 0
var _paused: bool = false
var _pause_state_applied_to_runtime: bool = false
var _gate_state_applied_to_runtime: bool = false
var _applied_gate_open: bool = true
var _applied_authored_gate_open: bool = true
var _applied_gate_half_width_pixels: float = 0.0
var _applied_gate_width_world_units: float = 0.0
var _regime_ecology_evaluation_count: int = 0
var _gate_state_upload_count: int = 0
var _shoreline_geometry_upload_count: int = 0
var _pending_messages: Array[Dictionary] = []
var _trail_recording_warmup_frames: int = 0
var _model_year_elapsed_seconds: float = 0.0
var _model_day_index: int = 0
var _model_minute_of_day: int = 0
var _model_date_source: StringName = &"internal_clock"
var _model_timeline_revision: int = 0
var _watershed_raw_values := PackedFloat32Array()
var _watershed_normalized_flow := PackedFloat32Array()
var _watershed_running_average_flow := PackedFloat32Array()
var _watershed_scaled_flow := PackedFloat32Array()
var _watershed_high_variation := PackedByteArray()
var _watershed_data_river: String = ""
var _watershed_data_error: String = ""
var _watershed_fog_baseline_mm_day: float = 0.0
var _watershed_fog_baseline_normalized: float = 0.0
var _morning_fog_pulse_multiplier: float = 0.0
var _watershed_row_index: int = -1
var _watershed_row_fraction: float = 0.0
var _watershed_interpolated_flow_rate: float = 0.0
var _watershed_buffered_flow_rate: float = 0.0
var _watershed_running_average_sample_count: int = 0
var _temperature_values := PackedFloat32Array()
var _temperature_data_error: String = ""
var _temperature_data_status: String = "NOT_CONFIGURED"
var _temperature_row_index: int = -1
var _temperature_row_fraction: float = 0.0
var _temperature_current_value_c: float = 0.0
var _temperature_value_valid: bool = false
var _delta_tide_heights := PackedFloat32Array()
var _delta_tide_normalized_heights := PackedFloat32Array()
var _delta_tide_normalized_velocities := PackedFloat32Array()
var _delta_tide_data_error: String = ""
var _delta_tide_data_status: String = "NOT_DELTA"
var _delta_tide_row_index: int = -1
var _delta_tide_row_fraction: float = 0.0
var _delta_tide_current_height_m: float = 0.0
var _delta_tide_current_normalized_height: float = 0.0
var _delta_tide_current_normalized_velocity: float = 0.0
var _watershed_ai_applied_state: Dictionary = {}
var _watershed_ai_applied_decision_id: String = ""
var _watershed_ai_applied_state_hash: String = ""
var _watershed_ai_last_error: String = ""
var _watershed_ai_apply_count: int = 0
var _watershed_ai_deduplicated_count: int = 0
var _watershed_ai_rejection_count: int = 0
var _watershed_ai_baseline_captured: bool = false
var _watershed_ai_baseline_flow_rate: float = 0.0
var _watershed_ai_baseline_data_drives_flow_rate: bool = true
var _watershed_ai_baseline_gate_open: bool = true


func _ready() -> void:
	add_to_group(&"flow_models")
	_bind_model_timeline()
	_bind_model_regimes()
	_install_regime_extractor_polygons()
	_recalculate_basin_budget(false)
	_apply_regime_features_from_state(_regime_snapshot)
	_install_default_interaction_polygons_if_needed()
	_ensure_regime_feature_slot_banks()
	_capture_authored_regime_geometry()
	_apply_regime_geometry_from_state()
	_load_watershed_data()
	_load_temperature_data()
	_load_delta_tide_data()
	_sync_from_model_timeline(false)
	_build_background()
	_build_background_grid()
	_build_water_render_surface()
	_build_particles()
	_build_salmon()
	_build_leaves()
	_build_overlay()
	_build_basin_budget_overlay()
	_build_stage_title()
	_bind_interaction_polygon_signals()
	_apply_identity()
	_apply_runtime_parameters()
	_apply_interaction_geometry()
	_apply_shoreline_geometry()
	_apply_gate()
	_apply_debug_visibility()
	_apply_stage_title()
	_apply_regime_ecology_schedule()
	if _model_timeline == null:
		_reset_model_calendar()
		_apply_local_paused(not auto_start)
	else:
		_sync_from_model_timeline(false)


func _process(delta: float) -> void:
	# ModelTimeline is the sole clock owner in the production project. Retain the
	# local advance only as a fallback when this reusable scene is embedded in a
	# project that has not installed the autoload.
	if _model_timeline == null:
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
		KEY_0, KEY_8, KEY_9:
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
			_toggle_debug_visibility_for_all_stages()
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


func get_model_date_time() -> String:
	return _format_model_date_time(
		_model_day_index,
		_model_minute_of_day,
	)


func get_native_size() -> Vector2:
	return STAGE_SIZE


func validate_watershed_ai_control_message(message: Dictionary) -> Dictionary:
	if String(message.get("control_scope", "")) != WATERSHED_AI_CONTROL_SCOPE:
		return {
			"ok": false,
			"error": "The message is not scoped to '%s'." % WATERSHED_AI_CONTROL_SCOPE,
		}
	for field_variant: Variant in message:
		var field := String(field_variant)
		if field not in WATERSHED_AI_TOP_LEVEL_FIELDS:
			return {
				"ok": false,
				"error": (
					"Watershed AI packets cannot contain top-level field '%s'."
					% field
				),
			}
	if String(message.get("protocol", "")) != "ink-flow/1":
		return {
			"ok": false,
			"error": "Watershed AI packets require protocol 'ink-flow/1'.",
		}
	var target_variant: Variant = message.get("target", "")
	if (
		not (target_variant is String or target_variant is StringName)
		or String(target_variant) != String(screen_id)
	):
		return {
			"ok": false,
			"error": (
				"Watershed AI target must be this stage's exact screen ID '%s'."
				% String(screen_id)
			),
		}
	var geometry_variant: Variant = message.get("geometry_ops", [])
	if not geometry_variant is Array or not Array(geometry_variant).is_empty():
		return {
			"ok": false,
			"error": "Watershed AI packets cannot contain geometry operations.",
		}
	var actions_variant: Variant = message.get("actions", [])
	if not actions_variant is Array or not Array(actions_variant).is_empty():
		return {
			"ok": false,
			"error": "Watershed AI packets cannot contain actions.",
		}
	var metadata_variant: Variant = message.get("metadata", {})
	if not metadata_variant is Dictionary:
		return {
			"ok": false,
			"error": "Watershed AI metadata must be a dictionary.",
		}
	var request_id := String(Dictionary(metadata_variant).get(
		"request_id",
		"",
	)).strip_edges()
	if request_id.is_empty() or request_id.length() > 128:
		return {
			"ok": false,
			"error": "Watershed AI metadata.request_id must contain 1..128 characters.",
		}
	if not _watershed_ai_regime_is_exclusive(_regime_snapshot):
		return {
			"ok": false,
			"error": "Watershed AI control requires exclusive active_indices [6].",
		}
	var changes_variant: Variant = message.get("changes", {})
	if not changes_variant is Dictionary:
		return {
			"ok": false,
			"error": "Watershed AI changes must be a dictionary.",
		}
	var changes: Dictionary = changes_variant
	if changes.size() != 1 or not changes.has(WATERSHED_AI_STATE_PATH):
		return {
			"ok": false,
			"error": (
				"Watershed AI packets require exactly one '%s' change."
				% WATERSHED_AI_STATE_PATH
			),
		}
	var state_result := _validated_watershed_ai_state(
		changes[WATERSHED_AI_STATE_PATH]
	)
	if not bool(state_result.get("ok", false)):
		return state_result
	var canonical_state: Dictionary = state_result.get("state", {})
	var state_hash := String(state_result.get("state_hash", ""))
	var decision_id := String(canonical_state.get("decision_id", ""))
	if (
		decision_id == _watershed_ai_applied_decision_id
		and not _watershed_ai_applied_decision_id.is_empty()
		and state_hash != _watershed_ai_applied_state_hash
	):
		return {
			"ok": false,
			"error": (
				"Watershed AI decision_id '%s' was reused with different state."
				% decision_id
			),
		}
	return {
		"ok": true,
		"state": canonical_state,
		"state_hash": state_hash,
	}


func get_watershed_ai_ack_state() -> Dictionary:
	return {
		"eligible": _watershed_ai_regime_is_exclusive(_regime_snapshot),
		"applied": not _watershed_ai_applied_decision_id.is_empty(),
		"applied_decision_id": _watershed_ai_applied_decision_id,
		"applied_state_hash": _watershed_ai_applied_state_hash,
		"applied_state": _watershed_ai_applied_state.duplicate(true),
		"last_error": _watershed_ai_last_error,
		"apply_count": _watershed_ai_apply_count,
		"deduplicated_count": _watershed_ai_deduplicated_count,
		"rejection_count": _watershed_ai_rejection_count,
		"fixed_bank_only": true,
		"current_observation": _watershed_ai_current_observation(),
	}


func _validated_watershed_ai_state(state_variant: Variant) -> Dictionary:
	if not state_variant is Dictionary:
		return {
			"ok": false,
			"error": "Watershed AI state must be a dictionary.",
		}
	var state: Dictionary = state_variant
	if state.size() != WATERSHED_AI_STATE_FIELDS.size():
		return {
			"ok": false,
			"error": "Watershed AI state must contain the complete canonical field set.",
		}
	for field: String in WATERSHED_AI_STATE_FIELDS:
		if not state.has(field):
			return {
				"ok": false,
				"error": "Watershed AI state is missing field '%s'." % field,
			}
	for field_variant: Variant in state:
		var field := String(field_variant)
		if field not in WATERSHED_AI_STATE_FIELDS:
			return {
				"ok": false,
				"error": "Watershed AI state has unknown field '%s'." % field,
			}
	var schema_version := _strict_nonnegative_int(state["schema_version"])
	if schema_version != WATERSHED_AI_STATE_SCHEMA_VERSION:
		return {
			"ok": false,
			"error": "Watershed AI state requires schema_version 2.",
		}
	if not (state["decision_id"] is String or state["decision_id"] is StringName):
		return {
			"ok": false,
			"error": "Watershed AI decision_id must be a string.",
		}
	var decision_id := String(state["decision_id"]).strip_edges()
	if decision_id.is_empty() or decision_id.length() > 128:
		return {
			"ok": false,
			"error": "Watershed AI decision_id must contain 1..128 characters.",
		}
	var canonical_state: Dictionary = {
		"schema_version": WATERSHED_AI_STATE_SCHEMA_VERSION,
		"decision_id": decision_id,
	}
	for field: String in WATERSHED_AI_FRACTION_FIELDS:
		var value_variant: Variant = state[field]
		if (
			typeof(value_variant) != TYPE_INT
			and typeof(value_variant) != TYPE_FLOAT
		):
			return {
				"ok": false,
				"error": "Watershed AI %s must be numeric." % field,
			}
		var value := float(value_variant)
		if not is_finite(value) or value < 0.0 or value > 1.0:
			return {
				"ok": false,
				"error": "Watershed AI %s must be finite and within 0..1." % field,
			}
		canonical_state[field] = value
	var allocation_sum := (
		float(canonical_state["salmon_fraction"])
		+ float(canonical_state["floodplain_fraction"])
		+ float(canonical_state["agriculture_fraction"])
		+ float(canonical_state["data_center_fraction"])
		+ float(canonical_state["city_fraction"])
	)
	if absf(allocation_sum - 1.0) > 0.000001:
		return {
			"ok": false,
			"error": "Watershed AI allocation fractions must sum to one.",
		}
	var extraction_sum := _watershed_ai_consumptive_fraction(canonical_state)
	if absf(
		float(canonical_state["extraction_fraction"]) - extraction_sum
	) > 0.000001:
		return {
			"ok": false,
			"error": "Watershed AI extraction_fraction is not the consumptive sum.",
		}
	if extraction_sum > 0.500001:
		return {
			"ok": false,
			"error": "Watershed AI sustainable extraction cannot exceed 50%.",
		}
	var expected_available := clampf(
		float(canonical_state["atmospheric_input_rate"])
		+ float(canonical_state["reservoir_release_rate"]),
		0.0,
		1.0,
	)
	if absf(
		float(canonical_state["available_supply_rate"]) - expected_available
	) > 0.000001:
		return {
			"ok": false,
			"error": "Watershed AI available supply does not match input plus release.",
		}
	var expected_remaining := expected_available * (1.0 - extraction_sum)
	if absf(
		float(canonical_state["remaining_rate"]) - expected_remaining
	) > 0.000001:
		return {
			"ok": false,
			"error": "Watershed AI remaining rate does not close the water budget.",
		}
	if (
		not is_zero_approx(float(canonical_state["hydropower_fraction"]))
		or not is_zero_approx(float(canonical_state["water_project_fraction"]))
	):
		return {
			"ok": false,
			"error": "Watershed AI keeps hydropower and water-project extraction at zero.",
		}
	# Reinsert every field in the published canonical order. Dictionary insertion
	# order then remains deterministic for diagnostics and cross-language clients.
	var ordered_state: Dictionary = {}
	for field: String in WATERSHED_AI_STATE_FIELDS:
		ordered_state[field] = canonical_state[field]
	return {
		"ok": true,
		"state": ordered_state,
		"state_hash": _watershed_ai_state_hash(ordered_state),
	}


func _watershed_ai_state_hash(state: Dictionary) -> String:
	# decision_id identifies a controller decision; the hash identifies only the
	# complete visual state so a new ID with identical values can skip GPU work.
	var parts := PackedStringArray([
		"schema_version=%d" % int(state.get("schema_version", 0)),
		"atmospheric_input_rate=%.9f" % float(state.get("atmospheric_input_rate", 0.0)),
		"reservoir_release_rate=%.9f" % float(state.get("reservoir_release_rate", 0.0)),
		"available_supply_rate=%.9f" % float(state.get("available_supply_rate", 0.0)),
		"extraction_fraction=%.9f" % float(state.get("extraction_fraction", 0.0)),
		"remaining_rate=%.9f" % float(state.get("remaining_rate", 0.0)),
		"salmon_fraction=%.9f" % float(state.get("salmon_fraction", 0.0)),
		"floodplain_fraction=%.9f" % float(state.get("floodplain_fraction", 0.0)),
		"agriculture_fraction=%.9f" % float(state.get("agriculture_fraction", 0.0)),
		"data_center_fraction=%.9f" % float(state.get("data_center_fraction", 0.0)),
		"city_fraction=%.9f" % float(state.get("city_fraction", 0.0)),
		"reservoir_storage_fraction=%.9f" % float(state.get("reservoir_storage_fraction", 0.0)),
		"hydropower_fraction=%.9f" % float(state.get("hydropower_fraction", 0.0)),
		"water_project_fraction=%.9f" % float(state.get("water_project_fraction", 0.0)),
	])
	return "\n".join(parts).sha256_text()


func _watershed_ai_consumptive_fraction(state: Dictionary) -> float:
	return clampf(
		float(state.get("agriculture_fraction", 0.0))
		+ float(state.get("data_center_fraction", 0.0))
		+ float(state.get("city_fraction", 0.0)),
		0.0,
		1.0,
	)


func _watershed_ai_current_observation() -> Dictionary:
	var temperature_value: Variant = (
		_temperature_current_value_c if _temperature_value_valid else null
	)
	return {
		"screen_id": String(screen_id),
		"model_date_time": _format_model_date_time(
			_model_day_index,
			_model_minute_of_day,
		),
		"model_day_index": _model_day_index,
		"model_minute_of_day": _model_minute_of_day,
		"flow_rate": flow_rate,
		"basin_input_rate": _basin_input_rate,
		"basin_extraction_fraction": _basin_extraction_fraction,
		"basin_remaining_rate": _basin_remaining_rate,
		"watershed_data_drives_flow_rate": watershed_data_drives_flow_rate,
		"watershed_row": get_current_watershed_data_row(),
		"temperature_c": temperature_value,
		"temperature_valid": _temperature_value_valid,
		"gate_open": gate_open,
		"effective_gate_open": _effective_gate_open(),
		"gate_aperture_fraction": _effective_gate_aperture_fraction(),
		"regime_active_indices": Array(
			_regime_snapshot.get("active_indices", [])
		).duplicate(),
		"regime_revision": int(_regime_snapshot.get("revision", 0)),
	}


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
	# This compatibility setter now controls the model's one atmospheric input.
	# The post-extraction remainder remains available as `flow_rate`.
	watershed_data_drives_flow_rate = false
	_basin_input_rate = clampf(value, 0.0, 1.0)
	_recalculate_basin_budget(false)
	# Digit keys and direct water-rate calls must not rebuild or retune either
	# ecology system. Salmon and leaves still react naturally to the resulting
	# water-only occupancy image, but their release generations, speeds, and
	# immutable segment pools remain untouched.
	_apply_water_rate_parameters()


func _recalculate_basin_budget(apply_water_parameters: bool = true) -> void:
	if (
		not _watershed_ai_applied_state.is_empty()
		and _watershed_ai_regime_is_exclusive(_regime_snapshot)
	):
		_basin_input_rate = float(
			_watershed_ai_applied_state["atmospheric_input_rate"]
		)
		# Derive the displayed budget from the same three allocations that
		# activate the field, data-center, and city systems. The aggregate on
		# the wire remains an audited invariant, not a second source of truth.
		_basin_extraction_fraction = _watershed_ai_consumptive_fraction(
			_watershed_ai_applied_state
		)
		_basin_remaining_rate = clampf(
			float(_watershed_ai_applied_state["available_supply_rate"])
			* (1.0 - _basin_extraction_fraction),
			0.0,
			1.0,
		)
	else:
		var active_states := Array(_regime_snapshot.get("active_states", []))
		_basin_extraction_fraction = BasinBudgetModel.total_extraction_fraction(
			active_states
		)
		_basin_remaining_rate = BasinBudgetModel.remaining_water(
			_basin_input_rate,
			active_states
		)
	# The particles visualize the sole output of the budget equation.
	flow_rate = _basin_remaining_rate
	_configure_basin_budget_overlay()
	if apply_water_parameters and not _process_material_layers.is_empty():
		_apply_water_rate_parameters()
	if is_node_ready():
		basin_budget_changed.emit(
			screen_id,
			_basin_input_rate,
			_basin_extraction_fraction,
			_basin_remaining_rate
		)


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
	if not _effective_gate_open():
		return 0.0
	return _effective_gate_aperture_fraction()


func _effective_gate_open() -> bool:
	return (
		gate_open
		and (
			not _regime_gate_override_enabled
			or _regime_gate_open_fraction > 0.000001
		)
	)


func _effective_gate_aperture_fraction() -> float:
	var aperture := (
		clampf(_regime_gate_aperture_fraction, 0.0, 1.0)
		if _regime_gate_aperture_override_enabled
		else get_gate_aperture_fraction()
	)
	if _regime_gate_override_enabled:
		aperture *= clampf(_regime_gate_open_fraction, 0.0, 1.0)
	return aperture


func _effective_gate_half_width_pixels() -> float:
	return reservoir_radius_pixels * _effective_gate_aperture_fraction()


func toggle_gate(_reservoir_id: StringName = RESERVOIR_ID) -> void:
	gate_open = not gate_open


func set_paused(value: bool) -> void:
	if _model_timeline != null:
		_model_timeline.call(&"set_paused", value)
	_apply_local_paused(value)


func _apply_local_paused(value: bool) -> void:
	var pause_state_changed := _paused != value
	if not pause_state_changed and _pause_state_applied_to_runtime:
		return
	_paused = value
	for head_layer in _head_layers:
		head_layer.speed_scale = 0.0 if _paused else 1.0
	for segment_layer in _trail_segment_layers:
		segment_layer.speed_scale = 0.0 if _paused else 1.0
	if _salmon_school != null:
		_salmon_school.set_paused(_paused)
	if _leaf_field != null:
		_leaf_field.set_paused(_paused)
	_pause_state_applied_to_runtime = (
		not _head_layers.is_empty()
		or not _trail_segment_layers.is_empty()
		or _salmon_school != null
		or _leaf_field != null
	)
	if pause_state_changed and is_node_ready():
		pause_changed.emit(screen_id, _paused)


func is_paused() -> bool:
	return _paused


func set_debug_visible(_value: bool) -> void:
	debug_visible = true


func toggle_debug_visibility() -> void:
	debug_visible = true


func _toggle_debug_visibility_for_all_stages() -> void:
	for model: Node in get_tree().get_nodes_in_group(&"flow_models"):
		if (
			is_instance_valid(model)
			and not model.is_queued_for_deletion()
			and model.has_method(&"set_debug_visible")
		):
			model.call(&"set_debug_visible", true)


func apply_runtime_parameters() -> void:
	## Re-applies exported flow and reservoir values after a controller changes
	## one or more properties directly.
	_apply_runtime_parameters()


func apply_interaction_polygons() -> void:
	## Re-upload exported polygon resources after direct runtime edits.
	_bind_interaction_polygon_signals()
	_apply_interaction_geometry()


func get_interaction_polygon(element_id: StringName) -> GPUFlowInteractionPolygon:
	return _find_interaction_polygon(element_id)


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


func set_shoreline_randomness(value: float) -> void:
	var next_value := clampf(value, 0.0, 1.0)
	if not is_finite(next_value):
		return
	if is_equal_approx(_shoreline_randomness, next_value):
		return
	_shoreline_randomness = next_value
	# The legacy data name now controls a uniform edge field. No geometry or
	# texture is regenerated when a regime changes.
	if is_node_ready():
		_apply_shoreline_geometry()


func get_shoreline_randomness() -> float:
	return _shoreline_randomness


func toggle_regime(regime_index: int) -> bool:
	if _model_regimes == null:
		return false
	return bool(_model_regimes.call(&"toggle_regime", regime_index))


func set_regime_active(regime_index: int, active: bool) -> bool:
	if _model_regimes == null:
		return false
	return bool(_model_regimes.call(
		&"set_regime_active",
		regime_index,
		active,
	))


func set_active_regime_names(names: Array) -> bool:
	if _model_regimes == null:
		return false
	return bool(_model_regimes.call(&"set_active_names", names))


func get_regime_state() -> Dictionary:
	if _model_regimes == null:
		return _regime_snapshot.duplicate(true)
	return Dictionary(_model_regimes.call(&"snapshot"))


func _bind_model_regimes() -> void:
	_model_regimes = get_node_or_null("/root/ModelRegimes")
	if _model_regimes == null:
		return
	var regimes_callback := Callable(self, &"_on_model_regimes_changed")
	if not _model_regimes.is_connected(&"regimes_changed", regimes_callback):
		_model_regimes.connect(&"regimes_changed", regimes_callback)
	_regime_snapshot = Dictionary(_model_regimes.call(&"snapshot"))


func _on_model_regimes_changed(state: Dictionary) -> void:
	var next_regime_revision := int(state.get("revision", 0))
	var next_active_signature := _regime_active_signature(state)
	if (
		_regime_geometry_initialized
		and next_active_signature != _regime_layout_active_signature
	):
		_regime_layout_generation += 1
	_regime_layout_active_signature = next_active_signature
	if (
		_regime_geometry_initialized
		and next_regime_revision != _applied_regime_state_revision
	):
		# A real regime transition releases every reservoir-owned head in place.
		# The shader observes this revision before reading the next reservoir center;
		# immutable orbit trails then fade while the water resumes downstream flow.
		_advance_reservoir_geometry_revision()
	_applied_regime_state_revision = next_regime_revision
	_regime_snapshot = state.duplicate(true)
	if (
		_watershed_ai_baseline_captured
		and not _watershed_ai_regime_is_exclusive(_regime_snapshot)
	):
		_restore_watershed_ai_baseline()
	_apply_regime_features_from_state(_regime_snapshot)
	_install_regime_extractor_polygons()
	_recalculate_basin_budget(false)
	_apply_interaction_geometry()
	_apply_regime_panel()
	_apply_regime_ecology_schedule()
	if is_node_ready():
		regimes_changed.emit(
			screen_id,
			Array(_regime_snapshot.get("active_names", [])).duplicate(),
			Array(_regime_snapshot.get("active_indices", [])).duplicate(),
			int(_regime_snapshot.get("revision", 0)),
		)


func _regime_active_signature(state: Dictionary) -> String:
	var active_indices_variant: Variant = state.get("active_indices", [])
	if not active_indices_variant is Array:
		return ""
	var parts := PackedStringArray()
	for index_variant: Variant in active_indices_variant:
		if typeof(index_variant) == TYPE_INT or typeof(index_variant) == TYPE_FLOAT:
			parts.append(str(int(index_variant)))
	return "|".join(parts)


func _watershed_ai_regime_is_exclusive(state: Dictionary) -> bool:
	var active_indices_variant: Variant = state.get("active_indices", [])
	if not active_indices_variant is Array:
		return false
	var active_indices: Array = active_indices_variant
	return (
		active_indices.size() == 1
		and int(active_indices[0]) == WATERSHED_REGIME_INDEX
	)


func _capture_watershed_ai_baseline() -> void:
	if _watershed_ai_baseline_captured:
		return
	_watershed_ai_baseline_flow_rate = _basin_input_rate
	_watershed_ai_baseline_data_drives_flow_rate = watershed_data_drives_flow_rate
	_watershed_ai_baseline_gate_open = gate_open
	_watershed_ai_baseline_captured = true


func _restore_watershed_ai_baseline() -> void:
	if not _watershed_ai_baseline_captured:
		return
	var restore_flow_rate := _watershed_ai_baseline_flow_rate
	var restore_data_drive := _watershed_ai_baseline_data_drives_flow_rate
	var restore_gate_open := _watershed_ai_baseline_gate_open
	_watershed_ai_applied_state = {}
	_watershed_ai_applied_decision_id = ""
	_watershed_ai_applied_state_hash = ""
	_watershed_ai_last_error = ""
	_watershed_ai_baseline_captured = false
	watershed_data_drives_flow_rate = restore_data_drive
	_basin_input_rate = clampf(restore_flow_rate, 0.0, 1.0)
	_recalculate_basin_budget(false)
	gate_open = restore_gate_open
	if restore_data_drive:
		_update_model_data_timelines()
	elif not _process_material_layers.is_empty():
		_apply_water_rate_parameters()


func _apply_watershed_ai_feature_overlay() -> void:
	if (
		_watershed_ai_applied_state.is_empty()
		or not _watershed_ai_regime_is_exclusive(_regime_snapshot)
	):
		return
	var storage := float(_watershed_ai_applied_state["reservoir_storage_fraction"])
	var release := float(_watershed_ai_applied_state["reservoir_release_rate"])
	var agriculture := float(_watershed_ai_applied_state["agriculture_fraction"])
	var data_centers := float(_watershed_ai_applied_state["data_center_fraction"])
	var city := float(_watershed_ai_applied_state["city_fraction"])
	var derived_features := {
		"reservoir_area_fraction": [storage, ["watershed_ai_reservoir"]],
		"reservoir_count": [1 if storage > 0.000001 else 0, ["watershed_ai_reservoir"]],
		"reservoir_gate_aperture_fraction": [clampf(release * 4.0, 0.0, 1.0), ["watershed_ai_reservoir"]],
		"drain_area_fraction": [clampf(agriculture + data_centers, 0.0, 1.0), ["watershed_ai_agriculture", "watershed_ai_data_center"]],
		"drain_power": [clampf(agriculture + data_centers, 0.0, 1.0), ["watershed_ai_agriculture", "watershed_ai_data_center"]],
		"obstacle_area_fraction": [city, ["watershed_ai_city"]],
		"obstacle_power": [city, ["watershed_ai_city"]],
		"shoreline_randomness": [0.0, ["watershed_ai"]],
	}
	for feature_name: String in derived_features:
		var feature: Array = derived_features[feature_name]
		var contributors: Array = feature[1]
		_regime_feature_state_for_screen[feature_name] = {
			"defined": true,
			"value": feature[0],
			"contributor_count": contributors.size(),
			"contributor_ids": contributors.duplicate(),
		}


func _apply_watershed_ai_control_message(message: Dictionary) -> bool:
	var validation := validate_watershed_ai_control_message(message)
	if not bool(validation.get("ok", false)):
		_watershed_ai_last_error = String(validation.get(
			"error",
			"Watershed AI state was rejected.",
		))
		_watershed_ai_rejection_count += 1
		return false
	var next_state: Dictionary = Dictionary(validation.get(
		"state",
		{},
	)).duplicate(true)
	var next_hash := String(validation.get("state_hash", ""))
	var next_decision_id := String(next_state.get("decision_id", ""))
	if (
		next_decision_id == _watershed_ai_applied_decision_id
		and next_hash == _watershed_ai_applied_state_hash
	):
		_watershed_ai_last_error = ""
		_watershed_ai_deduplicated_count += 1
		return true
	if (
		not _watershed_ai_applied_state_hash.is_empty()
		and next_hash == _watershed_ai_applied_state_hash
	):
		_watershed_ai_applied_decision_id = next_decision_id
		_watershed_ai_applied_state["decision_id"] = next_decision_id
		_watershed_ai_last_error = ""
		_watershed_ai_deduplicated_count += 1
		return true
	_capture_watershed_ai_baseline()
	_watershed_ai_applied_state = next_state
	_watershed_ai_applied_decision_id = next_decision_id
	_watershed_ai_applied_state_hash = next_hash
	_watershed_ai_last_error = ""
	watershed_data_drives_flow_rate = false
	_basin_input_rate = float(next_state["atmospheric_input_rate"])
	_recalculate_basin_budget(false)
	_apply_regime_features_from_state(_regime_snapshot)
	gate_open = float(next_state["reservoir_release_rate"]) > 0.000001
	_install_regime_extractor_polygons()
	_apply_interaction_geometry()
	_configure_basin_budget_overlay()
	_apply_regime_ecology_schedule()
	if not _process_material_layers.is_empty():
		_apply_water_rate_parameters()
	_watershed_ai_apply_count += 1
	return true


func _apply_regime_features_from_state(state: Dictionary) -> void:
	_regime_feature_state_for_screen = _regime_screen_feature_state(state)
	_apply_watershed_ai_feature_overlay()
	# The renderer remains opt-in so reusable/legacy stages preserve their authored
	# physics. Production wrappers opt in and then consume only their own screen row.
	if not regime_profile_physics_enabled:
		_regime_reservoir_override_enabled = false
		_regime_reservoir_count_override_enabled = false
		_regime_drain_override_enabled = false
		_regime_drain_power_override_enabled = false
		_regime_obstacle_override_enabled = false
		_regime_obstacle_power_override_enabled = false
		_regime_gate_aperture_override_enabled = false
		_regime_reservoir_present = true
		_regime_drain_present = true
		_regime_obstacle_present = true
		_regime_reservoir_weight = 1.0
		_regime_drain_weight = 1.0
		_regime_drain_power = 1.0
		_regime_obstacle_weight = 1.0
		_regime_obstacle_power = 1.0
		_regime_reservoir_count = 0.0
		set_shoreline_randomness(0.0)
		_apply_regime_geometry_from_state()
		_apply_regime_shader_parameters()
		return
	_regime_reservoir_override_enabled = _regime_feature_is_defined(
		_regime_feature_state_for_screen,
		"reservoir_area_fraction",
	)
	_regime_reservoir_count_override_enabled = _regime_feature_is_defined(
		_regime_feature_state_for_screen,
		"reservoir_count",
	)
	_regime_drain_override_enabled = _regime_feature_is_defined(
		_regime_feature_state_for_screen,
		"drain_area_fraction",
	)
	_regime_drain_power_override_enabled = _regime_feature_is_defined(
		_regime_feature_state_for_screen,
		"drain_power",
	)
	_regime_obstacle_override_enabled = _regime_feature_is_defined(
		_regime_feature_state_for_screen,
		"obstacle_area_fraction",
	)
	_regime_obstacle_power_override_enabled = _regime_feature_is_defined(
		_regime_feature_state_for_screen,
		"obstacle_power",
	)
	_regime_reservoir_weight = _regime_screen_fraction(
		_regime_feature_state_for_screen,
		"reservoir_area_fraction",
		1.0,
	)
	_regime_drain_weight = _regime_screen_fraction(
		_regime_feature_state_for_screen,
		"drain_area_fraction",
		1.0,
	)
	_regime_drain_power = _regime_screen_fraction(
		_regime_feature_state_for_screen,
		"drain_power",
		1.0,
	)
	_regime_obstacle_weight = _regime_screen_fraction(
		_regime_feature_state_for_screen,
		"obstacle_area_fraction",
		1.0,
	)
	_regime_obstacle_power = _regime_screen_fraction(
		_regime_feature_state_for_screen,
		"obstacle_power",
		1.0,
	)
	_regime_reservoir_count = _regime_screen_number(
		_regime_feature_state_for_screen,
		"reservoir_count",
		0.0,
		0.0,
		2.0,
	)
	_regime_reservoir_present = (
		(
			not _regime_reservoir_override_enabled
			or _regime_reservoir_weight > 0.000001
		)
		and (
			not _regime_reservoir_count_override_enabled
			or _regime_reservoir_count > 0.000001
		)
	)
	_regime_drain_present = (
		not _regime_drain_override_enabled
		or _regime_drain_weight > 0.000001
	)
	_regime_obstacle_present = (
		not _regime_obstacle_override_enabled
		or _regime_obstacle_weight > 0.000001
	)
	_regime_gate_aperture_override_enabled = _regime_feature_is_defined(
		_regime_feature_state_for_screen,
		"reservoir_gate_aperture_fraction",
	)
	_regime_gate_aperture_fraction = _regime_screen_fraction(
		_regime_feature_state_for_screen,
		"reservoir_gate_aperture_fraction",
		0.0,
	)
	set_shoreline_randomness(_regime_screen_fraction(
		_regime_feature_state_for_screen,
		"shoreline_randomness",
		0.0,
	))
	_apply_regime_geometry_from_state()
	_apply_regime_shader_parameters()


func _regime_screen_feature_state(state: Dictionary) -> Dictionary:
	var all_screens_variant: Variant = state.get(
		"effective_feature_state_by_screen",
		{},
	)
	if not all_screens_variant is Dictionary:
		return {}
	var screen_variant: Variant = Dictionary(all_screens_variant).get(
		String(screen_id),
		{},
	)
	return screen_variant if screen_variant is Dictionary else {}


func _regime_feature_is_defined(features: Dictionary, feature_name: String) -> bool:
	var state_variant: Variant = features.get(feature_name, {})
	return state_variant is Dictionary and bool(state_variant.get("defined", false))


func _regime_screen_fraction(
	features: Dictionary,
	feature_name: String,
	fallback: float,
) -> float:
	return _regime_screen_number(features, feature_name, fallback, 0.0, 1.0)


func _regime_screen_number(
	features: Dictionary,
	feature_name: String,
	fallback: float,
	minimum: float,
	maximum: float,
) -> float:
	var state_variant: Variant = features.get(feature_name, {})
	if not state_variant is Dictionary or not bool(state_variant.get("defined", false)):
		return fallback
	var value: Variant = state_variant.get("value", fallback)
	if typeof(value) != TYPE_INT and typeof(value) != TYPE_FLOAT:
		return fallback
	var numeric_value := float(value)
	if not is_finite(numeric_value):
		return fallback
	return clampf(numeric_value, minimum, maximum)


func _regime_fraction(features: Dictionary, feature_name: String) -> float:
	var value: Variant = features.get(feature_name, 0.0)
	if typeof(value) != TYPE_INT and typeof(value) != TYPE_FLOAT:
		return 0.0
	var numeric_value := float(value)
	if not is_finite(numeric_value):
		return 0.0
	return clampf(numeric_value, 0.0, 1.0)


func _ensure_regime_feature_slot_banks() -> void:
	## Allocate a bounded candidate bank once. Regime changes only translate and
	## enable these resources, so several fields can appear without runtime node or
	## resource growth. One interaction slot remains available for controller work.
	if not regime_profile_physics_enabled:
		return
	var drain_template: GPUFlowInteractionPolygon
	var obstacle_template: GPUFlowInteractionPolygon
	var drain_count := 0
	var obstacle_count := 0
	for polygon: GPUFlowInteractionPolygon in _gpu_interaction_polygons():
		if polygon.mode == GPUFlowInteractionPolygon.Mode.ABSORB:
			drain_count += 1
			if drain_template == null:
				drain_template = polygon
		else:
			obstacle_count += 1
			if obstacle_template == null:
				obstacle_template = polygon
	while (
		drain_template != null
		and drain_count < REGIME_DRAIN_SLOT_CAPACITY
		and interaction_polygons.size() < MAX_INTERACTION_POLYGONS
	):
		var clone := GPUFlowInteractionPolygon.new()
		var definition := drain_template.to_dictionary()
		definition["element_id"] = "regime_drain_slot_%d" % (drain_count + 1)
		definition["enabled"] = false
		if clone == null or not clone.apply_dictionary(definition):
			break
		interaction_polygons.append(clone)
		drain_count += 1
	while (
		obstacle_template != null
		and obstacle_count < REGIME_OBSTACLE_SLOT_CAPACITY
		and interaction_polygons.size() < MAX_INTERACTION_POLYGONS
	):
		var clone := GPUFlowInteractionPolygon.new()
		var definition := obstacle_template.to_dictionary()
		definition["element_id"] = "regime_obstacle_slot_%d" % (obstacle_count + 1)
		definition["enabled"] = false
		if clone == null or not clone.apply_dictionary(definition):
			break
		interaction_polygons.append(clone)
		obstacle_count += 1


func _capture_authored_regime_geometry() -> void:
	## Keep immutable fallbacks for a cleared/undefined regime. Runtime switching
	## only translates these existing slots; it never appends resources or nodes.
	if _regime_geometry_initialized:
		return
	_authored_reservoir_center_pixels = reservoir_center_pixels
	_authored_interaction_vertices.clear()
	_authored_interaction_instance_ids.clear()
	_authored_interaction_enabled.clear()
	for polygon: GPUFlowInteractionPolygon in _gpu_interaction_polygons():
		_authored_interaction_vertices[String(polygon.element_id)] = (
			polygon.vertices.duplicate()
		)
		_authored_interaction_instance_ids[String(polygon.element_id)] = (
			polygon.get_instance_id()
		)
		_authored_interaction_enabled[String(polygon.element_id)] = polygon.enabled
	_regime_geometry_initialized = true
	_regime_layout_active_signature = _regime_active_signature(_regime_snapshot)
	_applied_regime_state_revision = int(_regime_snapshot.get("revision", 0))


func _regime_feature_contributor_ids(feature_name: String) -> Array[String]:
	var result: Array[String] = []
	var state_variant: Variant = _regime_feature_state_for_screen.get(
		feature_name,
		{},
	)
	if not state_variant is Dictionary:
		return result
	var state: Dictionary = state_variant
	if not bool(state.get("defined", false)):
		return result
	var contributor_variant: Variant = state.get("contributor_ids", [])
	if not contributor_variant is Array:
		return result
	for contributor_id_variant: Variant in contributor_variant:
		var contributor_id := String(contributor_id_variant)
		if not contributor_id.is_empty() and not result.has(contributor_id):
			result.append(contributor_id)
	result.sort()
	return result


func _regime_geometry_key(feature_name: String) -> String:
	if not regime_profile_physics_enabled:
		return REGIME_GEOMETRY_BASELINE_KEY
	var contributors := _regime_layout_contributor_ids()
	if contributors.is_empty():
		return REGIME_GEOMETRY_BASELINE_KEY
	return "active:%s:%s:g%d" % [
		feature_name,
		"|".join(PackedStringArray(contributors)),
		_regime_layout_generation,
	]


func _regime_layout_contributor_ids() -> Array[String]:
	## Any regime with a defined physical effect owns a fresh complete layout for
	## the screen. Undefined feature values still retain authored strength/count,
	## while truly unaffected/no-op rows retain the authored layout exactly.
	var result: Array[String] = []
	for feature_name: String in [
		"reservoir_area_fraction",
		"drain_area_fraction",
		"obstacle_area_fraction",
		"shoreline_randomness",
	]:
		for contributor_id: String in _regime_feature_contributor_ids(feature_name):
			if not result.has(contributor_id):
				result.append(contributor_id)
	result.sort()
	return result


func _regime_applied_feature_slot_count(feature_kind: String) -> int:
	var capacity := 1
	var present := true
	var override_enabled := false
	var weight := 1.0
	match feature_kind:
		"drain":
			capacity = REGIME_DRAIN_SLOT_CAPACITY
			present = _regime_drain_present
			override_enabled = _regime_drain_override_enabled
			weight = _regime_drain_weight
		"obstacle":
			capacity = REGIME_OBSTACLE_SLOT_CAPACITY
			present = _regime_obstacle_present
			override_enabled = _regime_obstacle_override_enabled
			weight = _regime_obstacle_weight
	if not present:
		return 0
	if not override_enabled:
		return 1
	return clampi(ceili(clampf(weight, 0.0, 1.0) * float(capacity)), 1, capacity)


func _regime_managed_feature_slot_count(
	feature_kind: String,
	enabled_only: bool = false,
) -> int:
	var result := 0
	if feature_kind != "drain" and feature_kind != "obstacle":
		return 0
	var expected_mode := (
		GPUFlowInteractionPolygon.Mode.ABSORB
		if feature_kind == "drain"
		else GPUFlowInteractionPolygon.Mode.REPEL
	)
	for polygon: GPUFlowInteractionPolygon in _gpu_interaction_polygons():
		if (
			polygon.mode != expected_mode
			or not _is_regime_managed_interaction_polygon(polygon)
		):
			continue
		if not enabled_only or polygon.enabled:
			result += 1
	return result


func _is_regime_managed_interaction_polygon(
	polygon: GPUFlowInteractionPolygon,
) -> bool:
	var element_id := String(polygon.element_id)
	return (
		_authored_interaction_instance_ids.has(element_id)
		and int(_authored_interaction_instance_ids[element_id])
			== polygon.get_instance_id()
	)


func _regime_seeded_center_world(
	feature_kind: String,
	contributors: Array[String],
	slot_index: int,
	half_extent: Vector2,
) -> Vector2:
	var region := Rect2(
		Vector2(REGIME_GEOMETRY_WORLD_EDGE_MARGIN, 1.0),
		Vector2(
			WORLD_SIZE.x - REGIME_GEOMETRY_WORLD_EDGE_MARGIN * 2.0,
			WORLD_SIZE.y - 2.0,
		),
	)
	match feature_kind:
		"drain":
			region = Rect2(Vector2(2.0, 1.0), Vector2(11.5, 3.1))
		"obstacle":
			region = Rect2(Vector2(3.0, 4.7), Vector2(11.0, 3.2))
	var minimum_center := region.position + half_extent
	var maximum_center := region.end - half_extent
	if maximum_center.x < minimum_center.x:
		minimum_center.x = region.get_center().x
		maximum_center.x = minimum_center.x
	if maximum_center.y < minimum_center.y:
		minimum_center.y = region.get_center().y
		maximum_center.y = minimum_center.y
	var slot_capacity := 1
	match feature_kind:
		"drain":
			slot_capacity = REGIME_DRAIN_SLOT_CAPACITY
		"obstacle":
			slot_capacity = REGIME_OBSTACLE_SLOT_CAPACITY
	var effective_slot_index := slot_index
	if slot_capacity > 1 and not contributors.is_empty():
		# Every real active-set transition reverses the visible lane assignment.
		# Contributor/generation seeds still vary positions within those lanes.
		var reverse_lanes := _regime_layout_generation % 2 == 1
		if reverse_lanes:
			effective_slot_index = slot_capacity - 1 - slot_index
	if slot_capacity > 1 and maximum_center.x > minimum_center.x:
		var complete_minimum_x := minimum_center.x
		var complete_width := maximum_center.x - minimum_center.x
		var slot_width := complete_width / float(slot_capacity)
		minimum_center.x = (
			complete_minimum_x + slot_width * float(effective_slot_index)
		)
		maximum_center.x = (
			complete_minimum_x + slot_width * float(effective_slot_index + 1)
		)
	if contributors.is_empty():
		return region.get_center()
	var blended_center := Vector2.ZERO
	for contributor_id: String in contributors:
		var seed_prefix := "%s:%s:%s:%d:g%d" % [
			String(screen_id),
			contributor_id,
			feature_kind,
			slot_index,
			_regime_layout_generation,
		]
		blended_center += Vector2(
			lerpf(
				minimum_center.x,
				maximum_center.x,
				_stable_interaction_seed(StringName(seed_prefix + ":x")),
			),
			lerpf(
				minimum_center.y,
				maximum_center.y,
				_stable_interaction_seed(StringName(seed_prefix + ":y")),
			),
		)
	return blended_center / float(contributors.size())


func _regime_contributor_seed_average(
	contributors: Array[String],
	slot_index: int,
	property_name: String,
) -> float:
	if contributors.is_empty():
		return _stable_interaction_seed(StringName(
			"%s:authored:drain:%d:%s:g%d" % [
				String(screen_id),
				slot_index,
				property_name,
				_regime_layout_generation,
			]
		))
	var total := 0.0
	for contributor_id: String in contributors:
		total += _stable_interaction_seed(StringName(
			"%s:%s:drain:%d:%s:g%d" % [
				String(screen_id),
				contributor_id,
				slot_index,
				property_name,
				_regime_layout_generation,
			]
		))
	return total / float(contributors.size())


func _regime_field_bank_phase(_contributors: Array[String]) -> int:
	# Adjacent real transitions always swap every field to the opposite bank.
	return _regime_layout_generation % 2


func _regime_seeded_field_vertices_world(
	contributors: Array[String],
	slot_index: int,
	active_count: int,
) -> PackedVector2Array:
	## Each managed field is an axis-aligned rectangle touching exactly one
	## physical bank. Active slots are stratified across the river length, while
	## a seeded phase alternates top/bottom so four Agriculture fields resolve
	## to 2 + 2. Bank contact lets the drain shader pull water through the field.
	var lane_count := maxi(active_count, 1)
	var active_slot_index := clampi(slot_index, 0, lane_count - 1)
	var lane_width := (
		REGIME_FIELD_X_RANGE.y - REGIME_FIELD_X_RANGE.x
	) / float(lane_count)
	var lane_left := (
		REGIME_FIELD_X_RANGE.x + lane_width * float(active_slot_index)
	)
	var lane_right := lane_left + lane_width
	var field_width := lerpf(
		REGIME_FIELD_ROOT_WIDTH_RANGE.x,
		REGIME_FIELD_ROOT_WIDTH_RANGE.y,
		_regime_contributor_seed_average(contributors, slot_index, "root"),
	)
	var depth := lerpf(
		REGIME_FIELD_DEPTH_RANGE.x,
		REGIME_FIELD_DEPTH_RANGE.y,
		_regime_contributor_seed_average(contributors, slot_index, "depth"),
	)
	var half_width := field_width * 0.5
	var center_minimum := lane_left + half_width + REGIME_FIELD_LANE_PADDING_WORLD
	var center_maximum := lane_right - half_width - REGIME_FIELD_LANE_PADDING_WORLD
	if center_maximum < center_minimum:
		center_minimum = (lane_left + lane_right) * 0.5
		center_maximum = center_minimum
	var center_x := lerpf(
		center_minimum,
		center_maximum,
		_regime_contributor_seed_average(contributors, slot_index, "x"),
	)
	var top_bank := (
		(slot_index + _regime_field_bank_phase(contributors)) % 2 == 0
	)
	if top_bank:
		return PackedVector2Array([
			Vector2(center_x - half_width, WORLD_SIZE.y - depth),
			Vector2(center_x + half_width, WORLD_SIZE.y - depth),
			Vector2(center_x + half_width, WORLD_SIZE.y),
			Vector2(center_x - half_width, WORLD_SIZE.y),
		])
	return PackedVector2Array([
		Vector2(center_x - half_width, 0.0),
		Vector2(center_x + half_width, 0.0),
		Vector2(center_x + half_width, depth),
		Vector2(center_x - half_width, depth),
	])


func _regime_seeded_reservoir_center_pixels(
	contributors: Array[String],
) -> Vector2:
	if contributors.is_empty():
		return _authored_reservoir_center_pixels
	var minimum_center := Vector2(
		maxf(
			STAGE_SIZE.x * REGIME_RESERVOIR_X_FRACTION_RANGE.x,
			reservoir_radius_pixels + reservoir_influence_pixels + 32.0,
		),
		maxf(
			STAGE_SIZE.y * REGIME_RESERVOIR_Y_FRACTION_RANGE.x,
			reservoir_radius_pixels + 32.0,
		),
	)
	var maximum_center := Vector2(
		minf(
			STAGE_SIZE.x * REGIME_RESERVOIR_X_FRACTION_RANGE.y,
			STAGE_SIZE.x - reservoir_radius_pixels - 64.0,
		),
		minf(
			STAGE_SIZE.y * REGIME_RESERVOIR_Y_FRACTION_RANGE.y,
			STAGE_SIZE.y - reservoir_radius_pixels - 32.0,
		),
	)
	maximum_center = maximum_center.max(minimum_center)
	var blended_center := Vector2.ZERO
	for contributor_id: String in contributors:
		var seed_prefix := "%s:%s:reservoir:0:g%d" % [
			String(screen_id),
			contributor_id,
			_regime_layout_generation,
		]
		blended_center += Vector2(
			lerpf(
				minimum_center.x,
				maximum_center.x,
				_stable_interaction_seed(StringName(seed_prefix + ":x")),
			),
			lerpf(
				minimum_center.y,
				maximum_center.y,
				_stable_interaction_seed(StringName(seed_prefix + ":y")),
			),
		)
	return blended_center / float(contributors.size())


func _world_polygon_bounds(vertices: PackedVector2Array) -> Rect2:
	if vertices.is_empty():
		return Rect2()
	var minimum := vertices[0]
	var maximum := vertices[0]
	for vertex: Vector2 in vertices:
		minimum = minimum.min(vertex)
		maximum = maximum.max(vertex)
	return Rect2(minimum, maximum - minimum)


func _translated_polygon_vertices(
	vertices: PackedVector2Array,
	target_center: Vector2,
) -> PackedVector2Array:
	var translated := PackedVector2Array()
	if vertices.is_empty():
		return translated
	var centroid := Vector2.ZERO
	for vertex: Vector2 in vertices:
		centroid += vertex
	centroid /= float(vertices.size())
	var offset := target_center - centroid
	for vertex: Vector2 in vertices:
		translated.append(vertex + offset)
	return translated


func _packed_vector2_arrays_equal(
	first: PackedVector2Array,
	second: PackedVector2Array,
) -> bool:
	if first.size() != second.size():
		return false
	for index in range(first.size()):
		if not first[index].is_equal_approx(second[index]):
			return false
	return true


func _advance_reservoir_geometry_revision() -> void:
	_reservoir_geometry_revision = (_reservoir_geometry_revision + 1) % 1000000
	for process_material in _process_material_layers:
		process_material.set_shader_parameter(
			&"reservoir_geometry_revision",
			float(_reservoir_geometry_revision),
		)


func _apply_regime_geometry_from_state() -> void:
	if not _regime_geometry_initialized:
		return
	var reservoir_key := _regime_geometry_key("reservoir_area_fraction")
	var drain_key := _regime_geometry_key("drain_area_fraction")
	var obstacle_key := _regime_geometry_key("obstacle_area_fraction")
	var layout_contributors := _regime_layout_contributor_ids()
	var drain_active_count := _regime_applied_feature_slot_count("drain")
	var obstacle_active_count := _regime_applied_feature_slot_count("obstacle")
	var any_geometry_changed := false

	if String(_applied_regime_geometry_keys.get("reservoir", "")) != reservoir_key:
		var next_reservoir_center := _authored_reservoir_center_pixels
		if reservoir_key != REGIME_GEOMETRY_BASELINE_KEY:
			next_reservoir_center = _regime_seeded_reservoir_center_pixels(
				layout_contributors,
			)
		if not reservoir_center_pixels.is_equal_approx(next_reservoir_center):
			reservoir_center_pixels = next_reservoir_center
			for process_material in _process_material_layers:
				process_material.set_shader_parameter(
					&"reservoir_center",
					reservoir_center_pixels,
				)
			if _overlay != null:
				_overlay.call(
					&"set_reservoir_geometry",
					reservoir_center_pixels,
					reservoir_radius_pixels,
				)
			any_geometry_changed = true
		_applied_regime_geometry_keys["reservoir"] = reservoir_key

	var interaction_geometry_changed := false
	var drain_slot := 0
	var obstacle_slot := 0
	for polygon: GPUFlowInteractionPolygon in _gpu_interaction_polygons():
		var element_id := String(polygon.element_id)
		# Geometry added or vertex-edited by the controller remains controller-owned.
		# Only the exact startup resources captured above participate in regime moves.
		if (
			not _authored_interaction_vertices.has(element_id)
			or int(_authored_interaction_instance_ids.get(element_id, -1))
				!= polygon.get_instance_id()
		):
			continue
		var baseline_variant: Variant = _authored_interaction_vertices[element_id]
		var baseline_vertices: PackedVector2Array = baseline_variant
		var feature_kind := (
			"drain"
			if polygon.mode == GPUFlowInteractionPolygon.Mode.ABSORB
			else "obstacle"
		)
		var feature_key := drain_key if feature_kind == "drain" else obstacle_key
		var slot_index := drain_slot if feature_kind == "drain" else obstacle_slot
		if feature_kind == "drain":
			drain_slot += 1
		else:
			obstacle_slot += 1
		var target_vertices := baseline_vertices.duplicate()
		var target_enabled := bool(_authored_interaction_enabled.get(
			element_id,
			polygon.enabled,
		))
		if feature_key != REGIME_GEOMETRY_BASELINE_KEY:
			target_enabled = slot_index < (
				drain_active_count
				if feature_kind == "drain"
				else obstacle_active_count
			)
			if feature_kind == "drain":
				target_vertices = _regime_seeded_field_vertices_world(
					layout_contributors,
					slot_index,
					drain_active_count,
				)
			else:
				var bounds := _world_polygon_bounds(baseline_vertices)
				target_vertices = _translated_polygon_vertices(
					baseline_vertices,
					_regime_seeded_center_world(
						feature_kind,
						layout_contributors,
						slot_index,
						bounds.size * 0.5,
					),
				)
		if not _packed_vector2_arrays_equal(polygon.vertices, target_vertices):
			polygon.vertices = target_vertices
			interaction_geometry_changed = true
		if polygon.enabled != target_enabled:
			polygon.enabled = target_enabled
			interaction_geometry_changed = true
	_applied_regime_geometry_keys["drain"] = drain_key
	_applied_regime_geometry_keys["obstacle"] = obstacle_key
	if interaction_geometry_changed:
		if not _process_material_layers.is_empty():
			_apply_interaction_geometry()
		any_geometry_changed = true

	if any_geometry_changed:
		_regime_geometry_update_count += 1


func _apply_regime_shader_parameters() -> void:
	for process_material in _process_material_layers:
		process_material.set_shader_parameter(
			&"regime_profile_physics_enabled",
			regime_profile_physics_enabled
		)
		process_material.set_shader_parameter(
			&"regime_reservoir_override_enabled",
			_regime_reservoir_override_enabled
		)
		process_material.set_shader_parameter(
			&"regime_reservoir_present",
			_regime_reservoir_present
		)
		process_material.set_shader_parameter(
			&"regime_drain_override_enabled",
			_regime_drain_override_enabled
		)
		process_material.set_shader_parameter(
			&"regime_drain_power_override_enabled",
			_regime_drain_power_override_enabled
		)
		process_material.set_shader_parameter(
			&"regime_obstacle_override_enabled",
			_regime_obstacle_override_enabled
		)
		process_material.set_shader_parameter(
			&"regime_obstacle_power_override_enabled",
			_regime_obstacle_power_override_enabled
		)
		process_material.set_shader_parameter(
			&"regime_reservoir_weight",
			_regime_reservoir_weight
		)
		process_material.set_shader_parameter(
			&"regime_drain_weight",
			_regime_drain_weight
		)
		process_material.set_shader_parameter(
			&"regime_drain_power",
			_regime_drain_power
		)
		process_material.set_shader_parameter(
			&"regime_obstacle_weight",
			_regime_obstacle_weight
		)
		process_material.set_shader_parameter(
			&"regime_obstacle_power",
			_regime_obstacle_power
		)
		process_material.set_shader_parameter(
			&"reservoir_geometry_revision",
			float(_reservoir_geometry_revision)
		)
	if _overlay != null:
		_overlay.call(
			&"set_feature_visibility",
			_regime_reservoir_present,
			_regime_drain_present,
			_regime_obstacle_present,
		)


func _regime_schedules_for_screen() -> Dictionary:
	var all_screens_variant: Variant = _regime_snapshot.get(
		"active_schedules_by_screen",
		{},
	)
	if not all_screens_variant is Dictionary:
		return {}
	var screen_variant: Variant = Dictionary(all_screens_variant).get(
		String(screen_id),
		{},
	)
	return screen_variant if screen_variant is Dictionary else {}


func _apply_regime_reservoir_gate_schedule() -> void:
	if not regime_profile_physics_enabled:
		_regime_gate_override_enabled = false
		_regime_gate_open_fraction = 1.0
		_apply_gate()
		return
	var active_profiles_variant: Variant = _regime_snapshot.get(
		"active_profiles",
		{},
	)
	if not active_profiles_variant is Dictionary:
		_regime_gate_override_enabled = false
		_regime_gate_open_fraction = 1.0
		_apply_gate()
		return
	var total_scheduled_area := 0.0
	var open_scheduled_area := 0.0
	for profile_variant: Variant in Dictionary(active_profiles_variant).values():
		if not profile_variant is Dictionary:
			continue
		var resolved := _resolved_active_profile_for_screen(profile_variant)
		var features: Dictionary = resolved.get("features", {})
		var schedule: Dictionary = resolved.get("schedule", {})
		if not features.has("reservoir_area_fraction"):
			continue
		var area := clampf(float(features["reservoir_area_fraction"]), 0.0, 1.0)
		if area <= 0.000001:
			continue
		var open_start := _schedule_day_index(
			schedule,
			"reservoir_gate_open_start_mm_dd",
		)
		var open_end := _schedule_day_index(
			schedule,
			"reservoir_gate_open_end_mm_dd",
		)
		if open_start < 0 or open_end < 0:
			continue
		total_scheduled_area += area
		if _day_is_in_wrapped_schedule(
			_model_day_index,
			open_start,
			open_end,
		):
			open_scheduled_area += area
	_regime_gate_override_enabled = total_scheduled_area > 0.000001
	_regime_gate_open_fraction = (
		open_scheduled_area / total_scheduled_area
		if _regime_gate_override_enabled
		else 1.0
	)
	_apply_gate()


func _resolved_active_profile_for_screen(profile: Dictionary) -> Dictionary:
	var defaults_variant: Variant = profile.get("defaults", {})
	var defaults: Dictionary = (
		defaults_variant if defaults_variant is Dictionary else {}
	)
	var features_variant: Variant = defaults.get("features", {})
	var schedule_variant: Variant = defaults.get("schedule", {})
	var features: Dictionary = (
		Dictionary(features_variant).duplicate(true)
		if features_variant is Dictionary
		else {}
	)
	var schedule: Dictionary = (
		Dictionary(schedule_variant).duplicate(true)
		if schedule_variant is Dictionary
		else {}
	)
	var overrides_variant: Variant = profile.get("river_overrides", {})
	if overrides_variant is Dictionary:
		var override_variant: Variant = Dictionary(overrides_variant).get(
			String(screen_id),
			{},
		)
		if override_variant is Dictionary:
			var override: Dictionary = override_variant
			var override_features_variant: Variant = override.get("features", {})
			if override_features_variant is Dictionary:
				var override_features: Dictionary = override_features_variant
				for key: Variant in override_features:
					features[key] = override_features[key]
			var override_schedule_variant: Variant = override.get("schedule", {})
			if override_schedule_variant is Dictionary:
				var override_schedule: Dictionary = override_schedule_variant
				for key: Variant in override_schedule:
					schedule[key] = override_schedule[key]
	return {"features": features, "schedule": schedule}


func _apply_regime_ecology_schedule() -> void:
	_regime_ecology_evaluation_count += 1
	_apply_regime_reservoir_gate_schedule()
	_regime_salmon_activity = 0.0
	_regime_leaf_activity = 0.0
	if not regime_profile_physics_enabled:
		return
	var schedules := _regime_schedules_for_screen()
	if schedules.is_empty():
		_rearm_regime_release_days_after_date_change()
		return
	var features := _regime_screen_feature_state(_regime_snapshot)
	var salmon_in_season := false
	var salmon_due_today := false
	var leaf_in_season := false
	var leaf_due_today := false
	for schedule_variant: Variant in schedules.values():
		if not schedule_variant is Dictionary:
			continue
		var schedule: Dictionary = schedule_variant
		var salmon_start := _schedule_day_index(schedule, "salmon_start_mm_dd")
		var salmon_end := _schedule_day_index(schedule, "salmon_end_mm_dd")
		if (
			salmon_start >= 0
			and salmon_end >= 0
			and _day_is_in_wrapped_schedule(
				_model_day_index,
				salmon_start,
				salmon_end,
			)
		):
			salmon_in_season = true
			var salmon_interval := _schedule_interval_days(
				schedule,
				"salmon_interval_days",
			)
			salmon_due_today = (
				salmon_due_today
				or posmod(
					_model_day_index - salmon_start,
					MODEL_CALENDAR_DAY_COUNT,
				) % salmon_interval == 0
			)
		var leaf_start := _schedule_day_index(schedule, "leaf_start_mm_dd")
		var leaf_end := _schedule_day_index(schedule, "leaf_end_mm_dd")
		if (
			leaf_start >= 0
			and leaf_end >= 0
			and _day_is_in_wrapped_schedule(
				_model_day_index,
				leaf_start,
				leaf_end,
			)
		):
			leaf_in_season = true
			var leaf_interval := _schedule_interval_days(
				schedule,
				"leaf_interval_days",
			)
			leaf_due_today = (
				leaf_due_today
				or posmod(
					_model_day_index - leaf_start,
					MODEL_CALENDAR_DAY_COUNT,
				) % leaf_interval == 0
			)
	if salmon_in_season:
		_regime_salmon_activity = _regime_screen_fraction(
			features,
			"salmon_activity",
			0.0,
		)
		if (
			_regime_salmon_activity > 0.0
			and salmon_due_today
			and _last_regime_salmon_release_day != _model_day_index
		):
			var salmon_count := _scaled_regime_release_count(
				salmon_per_release,
				_regime_salmon_activity,
			)
			if salmon_count > 0 and release_salmon(salmon_count) > 0:
				_last_regime_salmon_release_day = _model_day_index
	else:
		_rearm_regime_release_days_after_date_change()
	if leaf_in_season:
		_regime_leaf_activity = _regime_screen_fraction(
			features,
			"leaf_activity",
			0.0,
		)
		if (
			_regime_leaf_activity > 0.0
			and leaf_due_today
			and _last_regime_leaf_release_day != _model_day_index
		):
			var leaf_count_per_side := _scaled_regime_release_count(
				leaves_per_side,
				_regime_leaf_activity,
			)
			if leaf_count_per_side > 0 and release_leaves(leaf_count_per_side) > 0:
				_last_regime_leaf_release_day = _model_day_index
	else:
		_rearm_regime_release_days_after_date_change()


func _scaled_regime_release_count(base_count: int, activity: float) -> int:
	var safe_base := maxi(base_count, 0)
	var safe_activity := clampf(activity, 0.0, 1.0)
	return clampi(
		floori(float(safe_base) * safe_activity + 0.5),
		0,
		safe_base,
	)


func _rearm_regime_release_days_after_date_change() -> void:
	# A same-day off/on toggle must not look like a second daily event. Once the
	# model date advances, clearing the marker lets a later valid season fire.
	if _last_regime_salmon_release_day != _model_day_index:
		_last_regime_salmon_release_day = -1
	if _last_regime_leaf_release_day != _model_day_index:
		_last_regime_leaf_release_day = -1


func _schedule_day_index(schedule: Dictionary, key: String) -> int:
	var date_text := String(schedule.get(key, "")).strip_edges()
	if date_text.is_empty():
		return -1
	return _parse_model_date_time(date_text).x


func _schedule_interval_days(schedule: Dictionary, key: String) -> int:
	var interval_text := String(schedule.get(key, "1")).strip_edges()
	if not interval_text.is_valid_int():
		return 1
	return maxi(int(interval_text), 1)


func _day_is_in_wrapped_schedule(day: int, start_day: int, end_day: int) -> bool:
	if start_day <= end_day:
		return day >= start_day and day <= end_day
	return day >= start_day or day <= end_day


func _bind_model_timeline() -> void:
	_model_timeline = get_node_or_null("/root/ModelTimeline")
	if _model_timeline == null:
		return
	var timeline_callback := Callable(self, &"_on_model_timeline_changed")
	if not _model_timeline.is_connected(&"timeline_changed", timeline_callback):
		_model_timeline.connect(&"timeline_changed", timeline_callback)
	_model_timeline.call(
		&"configure_if_needed",
		model_year_duration_seconds,
		model_start_day_index,
		model_calendar_auto_advance,
		not auto_start,
	)
	_sync_from_model_timeline(false)


func _on_model_timeline_changed(state: Dictionary) -> void:
	# ModelTimeline already built the authoritative snapshot for this signal.
	# Reuse it across every stage instead of allocating a second Dictionary per
	# stage, per rendered frame.
	_sync_from_model_timeline(true, state)


func _sync_from_model_timeline(
	emit_date_signal: bool = true,
	timeline_state: Dictionary = {},
) -> void:
	if _model_timeline == null:
		return
	var snapshot: Dictionary = (
		timeline_state
		if not timeline_state.is_empty()
		else Dictionary(_model_timeline.call(&"snapshot"))
	)
	if snapshot.is_empty():
		return
	var previous_day_index := _model_day_index
	var previous_minute_of_day := _model_minute_of_day
	_model_year_elapsed_seconds = float(snapshot.get(
		"elapsed_seconds", _model_year_elapsed_seconds
	))
	_model_day_index = int(snapshot.get("day_index", _model_day_index))
	_model_minute_of_day = int(snapshot.get(
		"minute_of_day", _model_minute_of_day
	))
	model_year_duration_seconds = float(snapshot.get(
		"year_duration_seconds", model_year_duration_seconds
	))
	model_start_day_index = int(snapshot.get(
		"start_day_index", model_start_day_index
	))
	model_calendar_auto_advance = bool(snapshot.get(
		"auto_advance", model_calendar_auto_advance
	))
	_model_date_source = StringName(String(snapshot.get(
		"source", String(_model_date_source)
	)))
	_model_timeline_revision = int(snapshot.get(
		"revision", _model_timeline_revision
	))
	_apply_local_paused(bool(snapshot.get("paused", _paused)))
	var day_changed := previous_day_index != _model_day_index
	var minute_changed := previous_minute_of_day != _model_minute_of_day
	if day_changed or minute_changed:
		_apply_model_date(emit_date_signal and day_changed)
	_update_model_data_timelines()
	# Ecology schedules and reservoir gate seasons have day precision. Regime
	# changes apply them immediately through _on_model_regimes_changed(); timeline
	# frames only need a reevaluation when the synthetic calendar day changes.
	if day_changed:
		_apply_regime_ecology_schedule()


func set_model_date_mm_dd(model_date_time: String) -> bool:
	## Accepts MM/DD or MM/DD-HH:MM. A valid external value becomes
	## authoritative until the internal data clock is enabled again.
	var parsed_time := _parse_model_date_time(model_date_time)
	if parsed_time.x < 0:
		return false
	if _model_timeline != null:
		_model_timeline.call(
			&"set_date",
			parsed_time.x,
			parsed_time.y,
			&"external_mm_dd",
		)
		return true
	model_calendar_auto_advance = false
	_model_date_source = &"external_mm_dd"
	_model_day_index = parsed_time.x
	_model_minute_of_day = parsed_time.y
	_align_model_elapsed_to_current_day()
	_apply_model_date()
	_update_model_data_timelines()
	_apply_regime_ecology_schedule()
	return true


func set_model_date_time(model_date_time: String) -> bool:
	return set_model_date_mm_dd(model_date_time)


func set_model_calendar_auto_advance(value: bool) -> void:
	if _model_timeline != null:
		_model_timeline.call(&"set_auto_advance", value)
		return
	model_calendar_auto_advance = value
	if model_calendar_auto_advance:
		_model_date_source = &"internal_clock"
		_align_model_elapsed_to_current_day()
	elif _model_date_source == &"internal_clock":
		_model_date_source = &"manual_hold"
	_apply_model_date(false)
	_update_model_data_timelines()


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
		"buffered_flow_rate": _watershed_buffered_flow_rate,
		"running_average_flow": float(
			_watershed_running_average_flow[_watershed_row_index]
		),
		"basin_input_rate": _basin_input_rate,
		"basin_extraction_fraction": _basin_extraction_fraction,
		"basin_remaining_rate": _basin_remaining_rate,
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
		"debug.geometry_visible", "debug_visible":
			set_debug_visible(bool(value))
			return true
		"stage.title", "stage_title":
			stage_title = String(value)
			return true
		"stage.title_visible", "stage_title_visible":
			stage_title_visible = bool(value)
			return true
		"stage.regime_panel_visible", "regime_panel_visible":
			regime_panel_visible = bool(value)
			return true
		"stage.regime_heading_visible", "regime_heading_visible":
			regime_heading_visible = bool(value)
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
		"stage.temperature_visible", "temperature.visible", \
		"temperature_visible", "stage_temperature_visible":
			stage_temperature_visible = bool(value)
			return true
		"temperature.data_path", "stage.temperature_data_path", \
		"temperature_data_path":
			temperature_data_path = String(value)
			return _temperature_data_status == "READY"
		"temperature.data_column", "stage.temperature_data_column", \
		"temperature_data_column":
			temperature_data_column = String(value)
			return _temperature_data_status == "READY"
		"stage.date", "calendar.date", "model_date":
			return set_model_date_mm_dd(String(value))
		"calendar.day_index", "model_day_index":
			var parsed_day_index := _strict_nonnegative_int(value)
			if parsed_day_index < 0 or parsed_day_index >= MODEL_CALENDAR_DAY_COUNT:
				return false
			if _model_timeline != null:
				_model_timeline.call(
					&"set_date",
					parsed_day_index,
					0,
					&"external_day_index",
				)
			else:
				model_calendar_auto_advance = false
				_model_date_source = &"external_day_index"
				_set_model_day_index(parsed_day_index)
				_align_model_elapsed_to_current_day()
				_update_model_data_timelines()
			return true
		"calendar.auto_advance", "model_calendar_auto_advance":
			set_model_calendar_auto_advance(bool(value))
			return true
		"calendar.year_duration_seconds", "model_year_duration_seconds":
			var parsed_year_duration := clampf(float(value), 1.0, 86400.0)
			if _model_timeline != null:
				_model_timeline.call(
					&"set_year_duration", parsed_year_duration
				)
			else:
				model_year_duration_seconds = parsed_year_duration
				_align_model_elapsed_to_current_day()
				_update_model_data_timelines()
			return true
		"calendar.start_day_index", "model_start_day_index":
			var parsed_start_day := _strict_nonnegative_int(value)
			if parsed_start_day < 0 or parsed_start_day >= MODEL_CALENDAR_DAY_COUNT:
				return false
			if _model_timeline != null:
				_model_timeline.call(
					&"set_start_day_index", parsed_start_day, true
				)
			else:
				model_start_day_index = parsed_start_day
				_reset_model_calendar()
			return true
		"watershed.data_path", "watershed_data_path":
			watershed_data_path = String(value)
			var data_loaded := _load_watershed_data()
			if data_loaded:
				_update_model_data_timelines()
			return data_loaded
		"watershed.drives_flow_rate", "watershed_data_drives_flow_rate":
			watershed_data_drives_flow_rate = bool(value)
			if watershed_data_drives_flow_rate:
				_update_model_data_timelines()
			return true
		"watershed.interpolate_flow_rate", "watershed_interpolate_flow_rate":
			watershed_interpolate_flow_rate = bool(value)
			_update_model_data_timelines()
			return true
		"shoreline.randomness", "shorelines.randomness", "shoreline_randomness":
			if typeof(value) != TYPE_INT and typeof(value) != TYPE_FLOAT:
				return false
			var shoreline_value := float(value)
			if not is_finite(shoreline_value):
				return false
			set_shoreline_randomness(shoreline_value)
			return true
		"regimes.active_names", "active_regimes":
			if not value is Array:
				return false
			return set_active_regime_names(value)
		"regimes.active_indices":
			if _model_regimes == null or not value is Array:
				return false
			return bool(_model_regimes.call(&"set_active_indices", value))
		"regimes.kinship":
			return set_regime_active(0, bool(value))
		"regimes.agriculture", "regimes.ranch":
			return set_regime_active(1, bool(value))
		"regimes.gold_rush":
			return set_regime_active(2, bool(value))
		"regimes.water_projects":
			return set_regime_active(3, bool(value))
		"regimes.hydropower":
			return set_regime_active(4, bool(value))
		"regimes.tech":
			return set_regime_active(5, bool(value))
		"regimes.watershed":
			return set_regime_active(6, bool(value))
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
			_basin_input_rate = clampf(float(value), 0.0, 1.0)
			_recalculate_basin_budget(false)
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
			_basin_input_rate = clampf(float(value), 0.0, 1.0)
			_recalculate_basin_budget(false)
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
			if not reservoir_center_pixels.is_equal_approx(parsed_center):
				reservoir_center_pixels = parsed_center
				if _regime_geometry_initialized:
					_authored_reservoir_center_pixels = reservoir_center_pixels
					_advance_reservoir_geometry_revision()
		"reservoir.reservoir_main.x":
			var next_x := float(value) * PIXELS_PER_WORLD_UNIT
			if not is_equal_approx(reservoir_center_pixels.x, next_x):
				reservoir_center_pixels.x = next_x
				if _regime_geometry_initialized:
					_authored_reservoir_center_pixels.x = next_x
					_advance_reservoir_geometry_revision()
		"reservoir.reservoir_main.y":
			var next_y := (
				WORLD_SIZE.y - float(value)
			) * PIXELS_PER_WORLD_UNIT
			if not is_equal_approx(reservoir_center_pixels.y, next_y):
				reservoir_center_pixels.y = next_y
				if _regime_geometry_initialized:
					_authored_reservoir_center_pixels.y = next_y
					_advance_reservoir_geometry_revision()
		"reservoir.reservoir_main.radius":
			var next_radius := maxf(float(value) * PIXELS_PER_WORLD_UNIT, 1.0)
			if not is_equal_approx(reservoir_radius_pixels, next_radius):
				reservoir_radius_pixels = next_radius
				if _regime_geometry_initialized:
					_advance_reservoir_geometry_revision()
				_refresh_gate_width_for_reservoir()
		"reservoir.reservoir_main.wall_influence":
			var next_influence := maxf(
				float(value) * PIXELS_PER_WORLD_UNIT,
				0.0
			)
			if not is_equal_approx(reservoir_influence_pixels, next_influence):
				reservoir_influence_pixels = next_influence
				if _regime_geometry_initialized:
					_advance_reservoir_geometry_revision()
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
			var next_radius := maxf(float(value), 8.0)
			if not is_equal_approx(reservoir_radius_pixels, next_radius):
				reservoir_radius_pixels = next_radius
				if _regime_geometry_initialized:
					_advance_reservoir_geometry_revision()
				_refresh_gate_width_for_reservoir()
		"reservoir_influence_pixels":
			var next_influence := maxf(float(value), 0.0)
			if not is_equal_approx(reservoir_influence_pixels, next_influence):
				reservoir_influence_pixels = next_influence
				if _regime_geometry_initialized:
					_advance_reservoir_geometry_revision()
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
		"debug.geometry_visible",
		"debug_visible",
		"stage.title",
		"stage_title",
		"stage.title_visible",
		"stage_title_visible",
		"stage.regime_panel_visible",
		"regime_panel_visible",
		"stage.regime_heading_visible",
		"regime_heading_visible",
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
		"stage.temperature_visible",
		"temperature.visible",
		"temperature_visible",
		"stage_temperature_visible",
		"temperature.data_path",
		"stage.temperature_data_path",
		"temperature_data_path",
		"temperature.data_column",
		"stage.temperature_data_column",
		"temperature_data_column",
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
		"shoreline.randomness",
		"shorelines.randomness",
		"shoreline_randomness",
		"regimes.active_names",
		"active_regimes",
		"regimes.active_indices",
		"regimes.kinship",
		"regimes.agriculture",
		"regimes.ranch",
		"regimes.gold_rush",
		"regimes.water_projects",
		"regimes.hydropower",
		"regimes.tech",
		"regimes.watershed",
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
	var head_layer_logical_active_ratios: Array[float] = []
	var head_layer_fixed_fps: Array[int] = []
	var head_layer_preprocess_seconds: Array[float] = []
	var head_layer_randomness: Array[float] = []
	var head_layer_explosiveness: Array[float] = []
	var head_layer_fixed_seed_enabled: Array[bool] = []
	var head_layer_seeds: Array[int] = []
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
	var reservoir_geometry_revision_uniforms: Array[float] = []
	var reservoir_radius_uniforms: Array[float] = []
	var reservoir_admission_enabled_uniforms: Array[bool] = []
	var regime_profile_physics_enabled_uniforms: Array[bool] = []
	var regime_reservoir_override_enabled_uniforms: Array[bool] = []
	var regime_reservoir_present_uniforms: Array[bool] = []
	var regime_drain_override_enabled_uniforms: Array[bool] = []
	var regime_drain_power_override_enabled_uniforms: Array[bool] = []
	var regime_obstacle_override_enabled_uniforms: Array[bool] = []
	var regime_obstacle_power_override_enabled_uniforms: Array[bool] = []
	var regime_reservoir_weight_uniforms: Array[float] = []
	var regime_drain_weight_uniforms: Array[float] = []
	var regime_drain_power_uniforms: Array[float] = []
	var regime_obstacle_weight_uniforms: Array[float] = []
	var regime_obstacle_power_uniforms: Array[float] = []
	var interaction_admission_enabled_uniforms: Array[bool] = []
	var interaction_count_uniforms: Array[int] = []
	var interaction_texture_bound_uniforms: Array[bool] = []
	var shoreline_count_uniforms: Array[int] = []
	var shoreline_texture_bound_uniforms: Array[bool] = []
	var shoreline_inlet_y_range_uniforms: Array[Vector2] = []
	var active_particle_count_uniforms: Array[float] = []
	var water_coverage_fraction_uniforms: Array[float] = []
	var edge_turbulence_amount_uniforms: Array[float] = []
	var edge_turbulence_band_uniforms: Array[float] = []
	var edge_turbulence_wall_band_uniforms: Array[float] = []
	var bank_field_suction_reach_uniforms: Array[float] = []
	var bank_field_suction_crossflow_uniforms: Array[float] = []
	var bank_field_suction_streamwise_uniforms: Array[float] = []
	var bank_field_min_withdrawal_speed_uniforms: Array[float] = []
	var bank_field_capture_depth_uniforms: Array[float] = []
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
		head_layer_logical_active_ratios.append(
			_flow_line_layer_amount_ratio(layer_index, flow_rate)
		)
		head_layer_fixed_fps.append(head_layer.fixed_fps)
		head_layer_preprocess_seconds.append(head_layer.preprocess)
		head_layer_randomness.append(head_layer.randomness)
		head_layer_explosiveness.append(head_layer.explosiveness)
		head_layer_fixed_seed_enabled.append(head_layer.use_fixed_seed)
		head_layer_seeds.append(head_layer.seed)
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
		reservoir_geometry_revision_uniforms.append(float(
			process_material.get_shader_parameter(&"reservoir_geometry_revision")
		))
		reservoir_radius_uniforms.append(float(
			process_material.get_shader_parameter(&"reservoir_radius")
		))
		reservoir_admission_enabled_uniforms.append(bool(
			process_material.get_shader_parameter(&"reservoir_admission_enabled")
		))
		regime_profile_physics_enabled_uniforms.append(bool(
			process_material.get_shader_parameter(&"regime_profile_physics_enabled")
		))
		regime_reservoir_override_enabled_uniforms.append(bool(
			process_material.get_shader_parameter(&"regime_reservoir_override_enabled")
		))
		regime_reservoir_present_uniforms.append(bool(
			process_material.get_shader_parameter(&"regime_reservoir_present")
		))
		regime_drain_override_enabled_uniforms.append(bool(
			process_material.get_shader_parameter(&"regime_drain_override_enabled")
		))
		regime_drain_power_override_enabled_uniforms.append(bool(
			process_material.get_shader_parameter(&"regime_drain_power_override_enabled")
		))
		regime_obstacle_override_enabled_uniforms.append(bool(
			process_material.get_shader_parameter(&"regime_obstacle_override_enabled")
		))
		regime_obstacle_power_override_enabled_uniforms.append(bool(
			process_material.get_shader_parameter(&"regime_obstacle_power_override_enabled")
		))
		regime_reservoir_weight_uniforms.append(float(
			process_material.get_shader_parameter(&"regime_reservoir_weight")
		))
		regime_drain_weight_uniforms.append(float(
			process_material.get_shader_parameter(&"regime_drain_weight")
		))
		regime_drain_power_uniforms.append(float(
			process_material.get_shader_parameter(&"regime_drain_power")
		))
		regime_obstacle_weight_uniforms.append(float(
			process_material.get_shader_parameter(&"regime_obstacle_weight")
		))
		regime_obstacle_power_uniforms.append(float(
			process_material.get_shader_parameter(&"regime_obstacle_power")
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
		shoreline_count_uniforms.append(int(
			process_material.get_shader_parameter(&"shoreline_count")
		))
		shoreline_texture_bound_uniforms.append(false)
		shoreline_inlet_y_range_uniforms.append(Vector2(
			process_material.get_shader_parameter(&"shoreline_inlet_y_range")
		))
		active_particle_count_uniforms.append(float(
			process_material.get_shader_parameter(&"active_particle_count")
		))
		water_coverage_fraction_uniforms.append(float(
			process_material.get_shader_parameter(&"water_coverage_fraction")
		))
		edge_turbulence_amount_uniforms.append(float(
			process_material.get_shader_parameter(&"edge_turbulence_amount")
		))
		edge_turbulence_band_uniforms.append(float(
			process_material.get_shader_parameter(&"edge_turbulence_band_pixels")
		))
		edge_turbulence_wall_band_uniforms.append(float(
			process_material.get_shader_parameter(
				&"edge_turbulence_wall_band_pixels"
			)
		))
		bank_field_suction_reach_uniforms.append(float(
			process_material.get_shader_parameter(
				&"bank_field_suction_reach_pixels"
			)
		))
		bank_field_suction_crossflow_uniforms.append(float(
			process_material.get_shader_parameter(
				&"bank_field_suction_crossflow_ratio"
			)
		))
		bank_field_suction_streamwise_uniforms.append(float(
			process_material.get_shader_parameter(
				&"bank_field_suction_streamwise_ratio"
			)
		))
		bank_field_min_withdrawal_speed_uniforms.append(float(
			process_material.get_shader_parameter(
				&"bank_field_min_withdrawal_speed_pixels"
			)
		))
		bank_field_capture_depth_uniforms.append(float(
			process_material.get_shader_parameter(
				&"bank_field_capture_depth_pixels"
			)
		))
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
	var regime_field_bank_layouts: Array[Dictionary] = []
	var regime_field_bank_counts := {
		"top": 0,
		"bottom": 0,
		"connected": 0,
		"enabled": 0,
	}
	for interaction_polygon: GPUFlowInteractionPolygon in _gpu_interaction_polygons():
		var interaction_definition := interaction_polygon.to_dictionary()
		var native_vertices := _polygon_native_vertices(
			interaction_polygon.vertices,
		)
		var native_bounds := _native_polygon_bounds(native_vertices)
		var bank_drain_sign := _native_bank_drain_sign(
			interaction_polygon.mode,
			native_bounds,
		)
		var bank_connected := absf(bank_drain_sign) > 0.5
		var bank_side := _bank_side_name(bank_drain_sign)
		var regime_managed := _is_regime_managed_interaction_polygon(
			interaction_polygon,
		)
		interaction_definition["vertices_pixels"] = native_vertices
		interaction_definition["regime_managed"] = regime_managed
		interaction_definition["bank_connected"] = bank_connected
		interaction_definition["bank_side"] = bank_side
		interaction_definition["intake_direction_pixels"] = Vector2(
			0.0,
			bank_drain_sign,
		)
		interaction_definitions.append(interaction_definition)
		if (
			regime_managed
			and interaction_polygon.mode == GPUFlowInteractionPolygon.Mode.ABSORB
			and bank_connected
		):
			var layout := interaction_definition.duplicate(true)
			regime_field_bank_layouts.append(layout)
			regime_field_bank_counts["connected"] += 1
			if interaction_polygon.enabled:
				regime_field_bank_counts["enabled"] += 1
				if bank_side == "TOP":
					regime_field_bank_counts["top"] += 1
				elif bank_side == "BOTTOM":
					regime_field_bank_counts["bottom"] += 1
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
	var regime_state := get_regime_state()
	var active_regime_extractor_count := 0
	for extractor: GPUFlowInteractionPolygon in _regime_extractor_polygons:
		if extractor != null and extractor.enabled:
			active_regime_extractor_count += 1
	var active_states := Array(regime_state.get("active_states", []))
	var delta_tide_visible := screen_id == &"delta"
	var kinship_delta_visible := (
		delta_tide_visible and active_states.size() > 0 and bool(active_states[0])
	)
	var shoreline_definitions := _shoreline_runtime_definitions()
	var shoreline_ids: Array[String] = []
	for shoreline_definition: Dictionary in shoreline_definitions:
		shoreline_ids.append(String(shoreline_definition["element_id"]))
	return {
		"stage_index": stage_index,
		"model_id": String(model_id),
		"screen_id": String(screen_id),
		"control_target": String(control_target),
		"stage_title": stage_title,
		"stage_title_display_text": _formatted_stage_title(),
		"stage_title_visible": stage_title_visible,
		"stage_title_position": STAGE_TITLE_POSITION,
		"stage_title_position_anchor": "CENTERLINE",
		"stage_title_rotation_degrees": TYPE_ROTATION_DEGREES,
		"stage_title_color": STAGE_TITLE_COLOR,
		"stage_title_font_size": STAGE_TITLE_FONT_SIZE,
		"stage_title_font_resource": STAGE_TITLE_FONT.resource_path,
		"stage_title_font_instance_id": (
			_stage_title_font.get_instance_id()
			if _stage_title_font != null
			else 0
		),
		"stage_title_tabular_numerals": true,
		"stage_title_opentype_feature": MODEL_DATE_OPENTYPE_FEATURE,
		"stage_title_temperature_integrated": true,
		"stage_title_temperature_visible": (
			stage_title_visible and stage_temperature_visible
		),
		"stage_title_z_index": STAGE_TITLE_Z_INDEX,
		"regime_state_shared": _model_regimes != null,
		"regime_state_scope": String(regime_state.get("scope", "")),
		"regime_names": Array(regime_state.get("regime_names", [])).duplicate(),
		"regime_ids": Array(regime_state.get("regime_ids", [])).duplicate(),
		"regime_active_states": Array(
			regime_state.get("active_states", [])
		).duplicate(),
		"active_regime_indices": Array(
			regime_state.get("active_indices", [])
		).duplicate(),
		"active_regime_names": Array(
			regime_state.get("active_names", [])
		).duplicate(),
		"active_regime_count": int(regime_state.get("active_count", 0)),
		"regime_extraction_breakdown": Array(
			regime_state.get("extraction_breakdown", [])
		).duplicate(true),
		"basin_input_kind": "precipitation+snowmelt+humidity+fog",
		"basin_input_rate": _basin_input_rate,
		"basin_input_percent": _basin_input_rate * 100.0,
		"total_extraction_fraction": _basin_extraction_fraction,
		"total_extraction_percent": _basin_extraction_fraction * 100.0,
		"basin_remaining_rate": _basin_remaining_rate,
		"basin_remaining_percent": _basin_remaining_rate * 100.0,
		"basin_budget_equation": "output=input*(1-extraction)",
		"active_regime_extractor_count": active_regime_extractor_count,
		"extractor_shape": "rectangle",
		"field_shape": "rectangle",
		"data_center_shape": "rectangle",
		"extractor_hatch_angle_degrees": 45.0,
		"extractor_hatch_line_width_pixels": 3.0,
		"extractor_hatch_gap_pixels": 6.0,
		"extractor_hatch_spacing_pixels": 6.0,
		"extractor_hatch_max_alpha": 0.33,
		"geometry_hatch_alpha": 0.33,
		"geometry_hatch_alpha_mode": "FIXED_UNIFORM",
		"geometry_label_background": "TRANSPARENT_HATCH_KNOCKOUT",
		"geometry_label_hatch_clearance_pixels": 6.0,
		"field_hatch_color": Color("6fbf73"),
		"data_center_hatch_color": Color.WHITE,
		"geometry_hatching_visible_when_active": debug_visible,
		"geometry_outline_borders": false,
		"geometry_hatch_line_caps": "ROUND",
		"repeller_display_term": "CITY",
		"geometry_overlay_z_index": GEOMETRY_OVERLAY_Z_INDEX,
		"water_display_z_index": WATER_DISPLAY_Z_INDEX,
		"geometry_below_water": GEOMETRY_OVERLAY_Z_INDEX < WATER_DISPLAY_Z_INDEX,
		"delta_budget_panel_background": "TRANSPARENT",
		"delta_budget_panel_background_alpha": 0.0,
		"field_bank_connected": true,
		"field_water_withdrawal_enabled": true,
		"overlay_text_rotation_degrees": TYPE_ROTATION_DEGREES,
		"kinship_delta_flood_visible": kinship_delta_visible,
		"kinship_delta_floodplain_visible": kinship_delta_visible,
		"kinship_delta_flood_render_style": "BORDERLESS_45_DEGREE_HATCH",
		"kinship_delta_flood_solid_fill": false,
		"kinship_delta_flood_hatch_color": Color("4ab0e1"),
		"kinship_delta_flood_hatch_alpha": 0.33,
		"kinship_delta_flood_hatch_angle_degrees": 45.0,
		"kinship_delta_flood_hatch_line_width_pixels": 3.0,
		"kinship_delta_flood_hatch_gap_pixels": 6.0,
		"kinship_delta_flood_hatch_line_caps": "ROUND",
		"kinship_delta_flood_label_hatch_clearance_pixels": 6.0,
		"delta_tide_visible": delta_tide_visible,
		"delta_tide_visible_in_all_regimes": delta_tide_visible,
		"delta_tide_data_path": DELTA_TIDE_DATA_PATH,
		"delta_tide_data_status": _delta_tide_data_status,
		"delta_tide_data_error": _delta_tide_data_error,
		"delta_tide_data_row_count": _delta_tide_heights.size(),
		"delta_tide_data_row_index": _delta_tide_row_index,
		"delta_tide_data_row_fraction": _delta_tide_row_fraction,
		"delta_tide_station_id": "9414290",
		"delta_tide_station_name": "San Francisco, CA",
		"delta_tide_product": "NOAA CO-OPS hourly tide predictions",
		"delta_tide_water_level_m_mllw": _delta_tide_current_height_m,
		"delta_tide_normalized_height": _delta_tide_current_normalized_height,
		"delta_tide_normalized_velocity": _delta_tide_current_normalized_velocity,
		"delta_tide_phase": (
			"FLOOD"
			if _delta_tide_current_normalized_velocity >= 0.0
			else "EBB"
		),
		"delta_tide_animation_direction": "BOTTOM_TO_TOP",
		"delta_tide_origin_side": "RIGHT",
		"delta_tide_render_style": "RIGHT_ANCHORED_CENTERED_96H_FIFO_HATCHED_AREA",
		"delta_tide_area_shape": "RIGHT_ANCHORED_HOURLY_TIDE_POLYGON",
		"delta_tide_series_sample_count": _delta_tide_normalized_heights.size(),
		"delta_tide_series_sample_position": (
			float(_delta_tide_row_index) + _delta_tide_row_fraction
		),
		"delta_tide_visible_line_count": 120,
		"delta_tide_first_line_y": 4.5,
		"delta_tide_last_line_y": 1075.5,
		"delta_tide_current_sample_screen_y": 540.0,
		"delta_tide_current_sample_centered": true,
		"delta_tide_history_capacity": 97,
		"delta_tide_history_update_mode": "WRAPPED_LINEAR_HOURLY_FIFO_WINDOW",
		"delta_tide_history_order": "OLDEST_TOP_NEWEST_BOTTOM",
		"delta_tide_migration_pixels_per_sample": 11.25,
		"delta_tide_bar_value_dimension": "POLYGON_LEFT_BOUNDARY_X_FROM_TIDE_HEIGHT",
		"delta_tide_line_length_range_pixels": Vector2(40.8, 306.0),
		"delta_tide_line_length_scale": 0.34,
		"delta_tide_line_length_reduction_percent": 66.0,
		"delta_tide_length_source": "NORMALIZED_TIDE_HEIGHT",
		"delta_tide_line_color": Color.WHITE,
		"delta_tide_line_color_name": "WHITE",
		"delta_tide_line_alpha": 0.20,
		"delta_budget_percentage_font_resource": STAGE_TITLE_FONT.resource_path,
		"delta_budget_percentage_tabular_numerals": true,
		"delta_tide_fill_line_orientation": "HORIZONTAL",
		"delta_tide_fill_line_width_pixels": 3.0,
		"delta_tide_fill_line_gap_pixels": 6.0,
		"delta_tide_fill_line_period_pixels": 9.0,
		"delta_tide_skips_screen_boundary_gridlines": true,
		"delta_tide_boundary_visible": false,
		"delta_tide_label_visible": false,
		"delta_tide_window_hours": 96.0,
		"delta_tide_window_past_hours": 48.0,
		"delta_tide_window_future_hours": 48.0,
		"delta_tide_window_sample_count": 97,
		"delta_tide_wrap_enabled": true,
		"delta_tide_timeline_source": "SHARED_MODEL_YEAR_PROGRESS",
		"delta_tide_antialiasing_profile": "PIXEL_ALIGNED_HORIZONTAL_STRIPES",
		"delta_tide_z_index": TIDE_OVERLAY_Z_INDEX,
		"delta_tide_below_text": TIDE_OVERLAY_Z_INDEX < STAGE_TITLE_Z_INDEX,
		"delta_tide_arrowheads": false,
		"regime_revision": int(regime_state.get("revision", 0)),
		"regime_profile_path": String(regime_state.get("profile_path", "")),
		"regime_profiles_loaded": bool(
			regime_state.get("profiles_loaded", false)
		),
		"regime_profile_count": int(regime_state.get("profile_count", 0)),
		"regime_profile_reload_revision": int(
			regime_state.get("profile_reload_revision", 0)
		),
		"regime_profile_diagnostics": Array(
			regime_state.get("profile_diagnostics", [])
		).duplicate(true),
		"regime_effective_features": Dictionary(
			regime_state.get("effective_features", {})
		).duplicate(true),
		"regime_active_schedules": Dictionary(
			regime_state.get("active_schedules", {})
		).duplicate(true),
		"regime_effective_feature_state_by_screen": Dictionary(
			regime_state.get("effective_feature_state_by_screen", {})
		).duplicate(true),
		"regime_active_schedules_by_screen": Dictionary(
			regime_state.get("active_schedules_by_screen", {})
		).duplicate(true),
		"regime_effective_feature_state": (
			_regime_feature_state_for_screen.duplicate(true)
		),
		"regime_profile_physics_enabled": regime_profile_physics_enabled,
		"regime_feature_budget_semantics": "PER_RIVER_DEFINED_CONTRIBUTOR_MEAN",
		"regime_applied_feature_budgets": {
			"reservoir_area_fraction": _regime_reservoir_weight,
			"reservoir_count_raw": _regime_reservoir_count,
			"reservoir_gate_aperture_fraction": (
				_effective_gate_aperture_fraction()
			),
			"drain_area_fraction": _regime_drain_weight,
			"drain_power": _regime_drain_power,
			"obstacle_area_fraction": _regime_obstacle_weight,
			"obstacle_power": _regime_obstacle_power,
			"shoreline_randomness": _shoreline_randomness,
		},
		"regime_applied_feature_overrides": {
			"reservoir": _regime_reservoir_override_enabled,
			"reservoir_count": _regime_reservoir_count_override_enabled,
			"drain_area": _regime_drain_override_enabled,
			"drain_power": _regime_drain_power_override_enabled,
			"obstacle_area": _regime_obstacle_override_enabled,
			"obstacle_power": _regime_obstacle_power_override_enabled,
			"reservoir_gate": _regime_gate_override_enabled,
		},
		"regime_feature_presence": {
			"reservoir": _regime_reservoir_present,
			"drain": _regime_drain_present,
			"obstacle": _regime_obstacle_present,
		},
		"regime_gate_open_fraction": _regime_gate_open_fraction,
		"regime_reservoir_count_desired_raw": _regime_reservoir_count,
		"regime_reservoir_count_rendered": 1 if _regime_reservoir_present else 0,
		"regime_reservoir_renderer_capacity": 1,
		"regime_feature_slot_capacities": {
			"drain": REGIME_DRAIN_SLOT_CAPACITY,
			"obstacle": REGIME_OBSTACLE_SLOT_CAPACITY,
		},
		"regime_feature_slot_counts_desired": {
			"drain": _regime_applied_feature_slot_count("drain"),
			"obstacle": _regime_applied_feature_slot_count("obstacle"),
		},
		"regime_feature_slot_counts_rendered": {
			"drain": _regime_managed_feature_slot_count("drain", true),
			"obstacle": _regime_managed_feature_slot_count("obstacle", true),
		},
		"regime_feature_slot_counts_resident": {
			"drain": _regime_managed_feature_slot_count("drain"),
			"obstacle": _regime_managed_feature_slot_count("obstacle"),
		},
		"regime_feature_controller_spare_capacity": {
			"interaction": maxi(
				MAX_INTERACTION_POLYGONS - _gpu_interaction_polygons().size(),
				0,
			),
		},
		"regime_geometry_mode": "GENERATION_SALTED_BOUNDED_SLOT_BANKS",
		"regime_layout_generation": _regime_layout_generation,
		"regime_layout_active_signature": _regime_layout_active_signature,
		"regime_geometry_keys": _applied_regime_geometry_keys.duplicate(true),
		"regime_geometry_update_count": _regime_geometry_update_count,
		"regime_geometry_undefined_fallback": "AUTHORED_GEOMETRY",
		"regime_geometry_mixed_contributors": "SORTED_CONTRIBUTOR_GENERATION_SEED",
		"regime_geometry_layout_contributor_ids": _regime_layout_contributor_ids(),
		"regime_geometry_preserves_particle_pools": true,
		"field_intake_mode": "BANK_CONNECTED_LATERAL_SUCTION",
		"field_absorption_edge_mode": "RIVER_FACING_MOUTH",
		"field_turn_mode": "SHARP_QUARTER_TURN_AT_MOUTH",
		"field_draining_state_policy": "RECORD_THROUGH_FIELD_THEN_RECYCLE_OFFSCREEN",
		"field_tail_policy": "IMMUTABLE_SEGMENTS_FADE_WITHOUT_TELEPORT",
		"regime_field_bank_layouts": regime_field_bank_layouts,
		"regime_field_bank_counts": regime_field_bank_counts,
		"bank_field_suction_reach_pixels": BANK_FIELD_SUCTION_REACH_PIXELS,
		"bank_field_suction_crossflow_ratio": (
			BANK_FIELD_SUCTION_CROSSFLOW_RATIO
		),
		"bank_field_suction_streamwise_ratio": (
			BANK_FIELD_SUCTION_STREAMWISE_RATIO
		),
		"bank_field_min_withdrawal_speed_pixels": (
			BANK_FIELD_MIN_WITHDRAWAL_SPEED_PIXELS
		),
		"bank_field_capture_depth_pixels": BANK_FIELD_CAPTURE_DEPTH_PIXELS,
		"regime_salmon_activity": _regime_salmon_activity,
		"regime_leaf_activity": _regime_leaf_activity,
		"regime_last_salmon_release_day_index": _last_regime_salmon_release_day,
		"regime_last_leaf_release_day_index": _last_regime_leaf_release_day,
		"regime_ecology_evaluation_count": _regime_ecology_evaluation_count,
		"gate_state_upload_count": _gate_state_upload_count,
		"shoreline_geometry_upload_count": _shoreline_geometry_upload_count,
		"edge_turbulence_parameter_upload_count": (
			_edge_turbulence_parameter_upload_count
		),
		"regime_panel_visible": (
			_regime_panel.visible if _regime_panel != null else false
		),
		"regime_panel_position": REGIME_PANEL_POSITION,
		"regime_panel_rotation_degrees": TYPE_ROTATION_DEGREES,
		"regime_heading_visible": (
			_regime_heading_label.visible
			if _regime_heading_label != null
			else false
		),
		"regime_heading_text": REGIME_HEADING_TEXT,
		"regime_heading_font_size": REGIME_HEADING_FONT_SIZE,
		"regime_name_font_size": REGIME_NAME_FONT_SIZE,
		"regime_name_row_height": REGIME_NAME_ROW_HEIGHT,
		"regime_active_alpha": REGIME_ACTIVE_ALPHA,
		"regime_inactive_alpha": REGIME_INACTIVE_ALPHA,
		"regime_panel_z_index": STAGE_TITLE_Z_INDEX,
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
		"stage_date_position_anchor": "CENTERLINE",
		"stage_date_rotation_degrees": TYPE_ROTATION_DEGREES,
		"stage_date_color": STAGE_TITLE_COLOR,
		"stage_date_font_size": MODEL_DATE_FONT_SIZE,
		"stage_date_font_resource": STAGE_TITLE_FONT.resource_path,
		"stage_date_tabular_numerals": true,
		"stage_date_opentype_feature": MODEL_DATE_OPENTYPE_FEATURE,
		"stage_date_z_index": STAGE_TITLE_Z_INDEX,
		"water_temperature_visible": (
			stage_title_visible and stage_temperature_visible
		),
		"water_temperature_text": _formatted_water_temperature(),
		"water_temperature_value_c": (
			_temperature_current_value_c if _temperature_value_valid else null
		),
		"water_temperature_value_valid": _temperature_value_valid,
		"water_temperature_position": STAGE_TITLE_POSITION,
		"water_temperature_position_anchor": "CENTERLINE",
		"water_temperature_rotation_degrees": TYPE_ROTATION_DEGREES,
		"water_temperature_color": STAGE_TITLE_COLOR,
		"water_temperature_font_size": STAGE_TITLE_FONT_SIZE,
		"water_temperature_font_resource": STAGE_TITLE_FONT.resource_path,
		"water_temperature_font_shared_with_date": true,
		"water_temperature_font_shared_with_title": true,
		"water_temperature_font_instance_id": (
			_stage_title_font.get_instance_id()
			if _stage_title_font != null
			else 0
		),
		"water_temperature_tabular_numerals": true,
		"water_temperature_opentype_feature": MODEL_DATE_OPENTYPE_FEATURE,
		"water_temperature_z_index": STAGE_TITLE_Z_INDEX,
		"water_temperature_format": "%.1f °C",
		"water_temperature_fallback_text": "— °C",
		"water_temperature_data_path": temperature_data_path,
		"water_temperature_data_column": temperature_data_column,
		"water_temperature_data_loaded": _temperature_data_status == "READY",
		"water_temperature_data_status": _temperature_data_status,
		"water_temperature_data_error": _temperature_data_error,
		"water_temperature_data_row_count": _temperature_values.size(),
		"water_temperature_data_expected_row_count": (
			WATER_TEMPERATURE_EXPECTED_ROW_COUNT
		),
		"water_temperature_data_row_count_matches_expected": (
			_temperature_values.size() == WATER_TEMPERATURE_EXPECTED_ROW_COUNT
		),
		"water_temperature_data_row_index": _temperature_row_index,
		"water_temperature_data_row_fraction": _temperature_row_fraction,
		"water_temperature_interpolation_mode": (
			WATER_TEMPERATURE_INTERPOLATION_MODE
		),
		"water_temperature_node_path": "StageTitleLayer/StageTitle",
		"water_temperature_integrated_with_stage_title": true,
		"water_temperature_outside_water_viewport": true,
		# Stage-prefixed aliases keep presentation inspection consistent with the
		# existing stage title/date keys while the data keys remain grouped under
		# water_temperature_data_*.
		"stage_temperature_visible": (
			stage_title_visible and stage_temperature_visible
		),
		"stage_temperature_text": _formatted_water_temperature(),
		"stage_temperature_value_c": (
			_temperature_current_value_c if _temperature_value_valid else null
		),
		"stage_temperature_position": STAGE_TITLE_POSITION,
		"stage_temperature_position_anchor": "CENTERLINE",
		"stage_temperature_rotation_degrees": TYPE_ROTATION_DEGREES,
		"stage_temperature_color": STAGE_TITLE_COLOR,
		"stage_temperature_font_size": STAGE_TITLE_FONT_SIZE,
		"stage_temperature_font_resource": STAGE_TITLE_FONT.resource_path,
		"stage_temperature_tabular_numerals": true,
		"stage_temperature_opentype_feature": MODEL_DATE_OPENTYPE_FEATURE,
		"stage_temperature_integrated_with_stage_title": true,
		"stage_temperature_z_index": STAGE_TITLE_Z_INDEX,
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
		"model_timeline_shared": _model_timeline != null,
		"model_timeline_scope": "GODOT_PROCESS",
		"model_timeline_revision": _model_timeline_revision,
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
		"watershed_buffered_flow_rate": _watershed_buffered_flow_rate,
		"watershed_buffered_flow_percent": _watershed_buffered_flow_rate * 100.0,
		"basin_input_buffer_mode": "TRAILING_CYCLIC_RUNNING_AVERAGE",
		"basin_input_running_average_days": BASIN_INPUT_RUNNING_AVERAGE_DAYS,
		"basin_input_running_average_sample_count": (
			_watershed_running_average_sample_count
		),
		"basin_input_minimum_rate": BASIN_INPUT_MINIMUM_RATE,
		"basin_input_minimum_percent": BASIN_INPUT_MINIMUM_RATE * 100.0,
		"basin_input_floor_applied_after_fog": true,
		"fog_baseline_mm_day": _watershed_fog_baseline_mm_day,
		"fog_baseline_normalized": _watershed_fog_baseline_normalized,
		"fog_morning_window_minutes": Vector2i(
			MORNING_FOG_START_MINUTE,
			MORNING_FOG_END_MINUTE,
		),
		"fog_morning_window_local_time": "03:00-10:00",
		"fog_morning_pulse_multiplier": _morning_fog_pulse_multiplier,
		"fog_morning_active": _morning_fog_pulse_multiplier > 0.0,
		"fog_daily_volume_preserved": true,
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
		"watershed_ai_control_scope": WATERSHED_AI_CONTROL_SCOPE,
		"watershed_ai_state_path": WATERSHED_AI_STATE_PATH,
		"watershed_ai_state_schema_version": WATERSHED_AI_STATE_SCHEMA_VERSION,
		"watershed_ai_exclusive_active": _watershed_ai_regime_is_exclusive(
			_regime_snapshot
		),
		"watershed_ai_applied": not _watershed_ai_applied_decision_id.is_empty(),
		"watershed_ai_applied_decision_id": _watershed_ai_applied_decision_id,
		"watershed_ai_applied_state_hash": _watershed_ai_applied_state_hash,
		"watershed_ai_applied_state": _watershed_ai_applied_state.duplicate(true),
		"watershed_ai_last_error": _watershed_ai_last_error,
		"watershed_ai_apply_count": _watershed_ai_apply_count,
		"watershed_ai_deduplicated_count": _watershed_ai_deduplicated_count,
		"watershed_ai_rejection_count": _watershed_ai_rejection_count,
		"watershed_ai_fixed_bank_only": true,
		"watershed_ai_current_observation": _watershed_ai_current_observation(),
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
		"water_texture_excludes_stage_temperature": true,
		"water_texture_excludes_regime_panel": true,
		"amount": particle_slots,
		"amount_ratio": _flow_line_amount_ratio(flow_rate),
		"flow_rate": flow_rate,
		"active_heads_approx": _flow_line_target_count(flow_rate),
		"water_line_density_low_rate": FLOW_DENSITY_LOW_RATE,
		"water_line_density_low_count": FLOW_DENSITY_LOW_LINE_COUNT,
		"water_line_density_full_count": FLOW_DENSITY_FULL_LINE_COUNT,
		"water_line_density_mapping": "1_PERCENT_20__100_PERCENT_1000",
		"palette_layer_count": PALETTE_LAYER_COUNT,
		"head_layer_count": _head_layers.size(),
		"trail_segment_layer_count": _trail_segment_layers.size(),
		"head_layer_slot_counts": head_layer_slot_counts,
		"head_layer_allocated_amounts": head_layer_allocated_amounts,
		"active_head_layer_counts": active_head_layer_counts,
		"head_layer_amount_ratios": head_layer_amount_ratios,
		"head_layer_logical_active_ratios": head_layer_logical_active_ratios,
		"head_layer_fixed_fps": head_layer_fixed_fps,
		"head_layer_preprocess_seconds": head_layer_preprocess_seconds,
		"head_layer_randomness": head_layer_randomness,
		"head_layer_explosiveness": head_layer_explosiveness,
		"head_layer_fixed_seed_enabled": head_layer_fixed_seed_enabled,
		"head_layer_seeds": head_layer_seeds,
		"head_emission_timing": "EVENLY_PHASED_DIRECT_RECYCLE_CONTINUOUS",
		"head_native_amount_ratio_strategy": "FULL_CYCLE_SHADER_GATED",
		"head_emission_cycle_seconds": HEAD_EMISSION_CYCLE_SECONDS,
		"head_preprocess_seconds": HEAD_PREPROCESS_SECONDS,
		"head_reentry_waits_for_native_cycle": false,
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
		"regime_profile_physics_enabled_uniforms": (
			regime_profile_physics_enabled_uniforms
		),
		"regime_reservoir_override_enabled_uniforms": (
			regime_reservoir_override_enabled_uniforms
		),
		"regime_reservoir_present_uniforms": (
			regime_reservoir_present_uniforms
		),
		"regime_drain_override_enabled_uniforms": (
			regime_drain_override_enabled_uniforms
		),
		"regime_drain_power_override_enabled_uniforms": (
			regime_drain_power_override_enabled_uniforms
		),
		"regime_obstacle_override_enabled_uniforms": (
			regime_obstacle_override_enabled_uniforms
		),
		"regime_obstacle_power_override_enabled_uniforms": (
			regime_obstacle_power_override_enabled_uniforms
		),
		"regime_reservoir_weight_uniforms": regime_reservoir_weight_uniforms,
		"regime_drain_weight_uniforms": regime_drain_weight_uniforms,
		"regime_drain_power_uniforms": regime_drain_power_uniforms,
		"regime_obstacle_weight_uniforms": regime_obstacle_weight_uniforms,
		"regime_obstacle_power_uniforms": regime_obstacle_power_uniforms,
		"interaction_admission_enabled_uniforms": (
			interaction_admission_enabled_uniforms
		),
		"interaction_count_uniforms": interaction_count_uniforms,
		"interaction_texture_bound_uniforms": interaction_texture_bound_uniforms,
		"shoreline_count_uniforms": shoreline_count_uniforms,
		"shoreline_texture_bound_uniforms": shoreline_texture_bound_uniforms,
		"shoreline_inlet_y_range_uniforms": shoreline_inlet_y_range_uniforms,
		"active_particle_count_uniforms": active_particle_count_uniforms,
		"water_coverage_fraction_uniforms": water_coverage_fraction_uniforms,
		"water_coverage_model": "CENTER_BAND_SYMMETRIC_FLOW_PERCENT",
		"water_inlet_band_y_range_pixels": _flow_inlet_band_y_range_pixels(
			flow_rate
		),
		"water_inlet_band_center_y_pixels": STAGE_SIZE.y * 0.5,
		"edge_turbulence_amount_uniforms": edge_turbulence_amount_uniforms,
		"edge_turbulence_band_uniforms": edge_turbulence_band_uniforms,
		"edge_turbulence_wall_band_uniforms": (
			edge_turbulence_wall_band_uniforms
		),
		"bank_field_suction_reach_uniforms": bank_field_suction_reach_uniforms,
		"bank_field_suction_crossflow_uniforms": (
			bank_field_suction_crossflow_uniforms
		),
		"bank_field_suction_streamwise_uniforms": (
			bank_field_suction_streamwise_uniforms
		),
		"bank_field_min_withdrawal_speed_uniforms": (
			bank_field_min_withdrawal_speed_uniforms
		),
		"bank_field_capture_depth_uniforms": bank_field_capture_depth_uniforms,
		"interaction_polygon_count": interaction_definitions.size(),
		"polygon_object_count": interaction_definitions.size(),
		"interaction_polygons": interaction_definitions,
		"polygon_objects": interaction_definitions,
		"shoreline_randomness": _shoreline_randomness,
		"shoreline_effect_mode": "EDGE_TURBULENCE",
		"edge_turbulence_amount": _shoreline_randomness,
		"edge_turbulence_band_pixels": EDGE_TURBULENCE_BAND_PIXELS,
		"edge_turbulence_wall_band_pixels": EDGE_TURBULENCE_WALL_BAND_PIXELS,
		"edge_turbulence_crossflow_ratio": EDGE_TURBULENCE_CROSSFLOW_RATIO,
		"edge_turbulence_streamwise_ratio": EDGE_TURBULENCE_STREAMWISE_RATIO,
		"edge_turbulence_inward_ratio": EDGE_TURBULENCE_INWARD_RATIO,
		"shoreline_count": shoreline_definitions.size(),
		"shoreline_vertex_count": 0,
		"shoreline_ids": shoreline_ids,
		"shoreline_obstacles": shoreline_definitions,
		"shoreline_inlet_y_range_pixels": _shoreline_inlet_y_range_pixels(),
		"shoreline_preserves_interaction_capacity": true,
		"shoreline_overlay_count": (
			int(_overlay.call(&"get_shoreline_obstacle_count"))
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
		"interaction_overlay_visible_count": (
			int(_overlay.call(&"get_visible_interaction_polygon_count"))
			if _overlay != null
			else 0
		),
		"reservoir_overlay_visible": (
			bool(_overlay.call(&"is_reservoir_visible"))
			if _overlay != null
			else false
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
		"gate_open": _effective_gate_open(),
		"gate_open_authored": gate_open,
		"gate_open_regime_override_enabled": _regime_gate_override_enabled,
		"gate_open_regime_fraction": _regime_gate_open_fraction,
		"gate_width": gate_width,
		"gate_width_requested": _requested_gate_width,
		"gate_full_width": get_full_gate_width_world_units(),
		"gate_half_width": _effective_gate_half_width_pixels(),
		"gate_half_width_pixels": _effective_gate_half_width_pixels(),
		"gate_half_width_pixels_authored": get_gate_half_width_pixels(),
		"gate_aperture_fraction": _effective_gate_aperture_fraction(),
		"gate_aperture_fraction_authored": get_gate_aperture_fraction(),
		"gate_aperture_regime_override_enabled": (
			_regime_gate_aperture_override_enabled
		),
		"gate_fully_open": (
			_effective_gate_open() && _effective_gate_aperture_fraction() >= 0.999
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
		"reservoir_center_pixels_authored": _authored_reservoir_center_pixels,
		"reservoir_geometry_revision": _reservoir_geometry_revision,
		"reservoir_geometry_revision_uniforms": (
			reservoir_geometry_revision_uniforms
		),
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
		"shoreline_count_uniform": _process_material.get_shader_parameter(
			&"shoreline_count"
		),
		"shoreline_data_texture_bound": false,
		"shoreline_data_texture_size": Vector2.ZERO,
		"paused": _paused,
		"debug_visible": debug_visible,
		"debug_overlay_visible": _overlay.visible if _overlay != null else false,
	}


func _apply_control_message(message: Dictionary) -> void:
	if String(message.get("control_scope", "")) == WATERSHED_AI_CONTROL_SCOPE:
		_apply_watershed_ai_control_message(message)
		return
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


func _is_interaction_parameter_path(path: String) -> bool:
	var components := path.split(".", false)
	return (
		components.size() == 3
		and _canonical_interaction_kind(components[0]) != ""
	)


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
	var updated := polygon.apply_dictionary({field: value})
	if updated and field in ["vertices", "enabled", "mode"]:
		_release_interaction_from_regime_geometry(polygon.element_id)
		# The resource's changed signal fires synchronously before ownership is
		# released, so repack once after transferring ownership.
		_apply_interaction_geometry()
	return updated


func _release_interaction_from_regime_geometry(element_id: StringName) -> void:
	var key := String(element_id)
	_authored_interaction_vertices.erase(key)
	_authored_interaction_instance_ids.erase(key)
	_authored_interaction_enabled.erase(key)


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
		if updated and (
			definition.has("vertices")
			or definition.has("enabled")
			or definition.has("mode")
		):
			_release_interaction_from_regime_geometry(element_id)
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
	_release_interaction_from_regime_geometry(element_id)
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
	_authored_interaction_vertices.clear()
	_authored_interaction_instance_ids.clear()
	_authored_interaction_enabled.clear()
	_bind_interaction_polygon_signals()
	_apply_interaction_geometry()
	return true




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




func _install_regime_extractor_polygons() -> void:
	_regime_extractor_polygons.clear()
	var active_states := Array(_regime_snapshot.get("active_states", []))
	var watershed_ai_active := (
		not _watershed_ai_applied_state.is_empty()
		and _watershed_ai_regime_is_exclusive(_regime_snapshot)
	)
	for definition: Dictionary in BasinBudgetModel.extractor_definitions():
		var extractor := GPUFlowInteractionPolygon.new()
		if extractor == null:
			continue
		var regime_index := int(definition["regime_index"])
		var visual_kind := String(definition.get("kind", ""))
		var allocation_fraction := 0.0
		if watershed_ai_active:
			if visual_kind == "field":
				allocation_fraction = float(
					_watershed_ai_applied_state["agriculture_fraction"]
				)
			elif visual_kind == "data_center":
				allocation_fraction = float(
					_watershed_ai_applied_state["data_center_fraction"]
				)
		var enabled := (
			allocation_fraction > 0.000001
			if watershed_ai_active
			else (
				regime_index >= 0
				and regime_index < active_states.size()
				and bool(active_states[regime_index])
			)
		)
		var extractor_rectangle: Rect2 = definition["rect_world"]
		if watershed_ai_active and enabled:
			extractor_rectangle = _watershed_ai_scaled_extractor_rect(
				extractor_rectangle,
				allocation_fraction,
			)
		var valid := extractor.apply_dictionary({
			"element_id": definition["element_id"],
			"vertices": BasinBudgetModel.rect_vertices(extractor_rectangle),
			"mode": "absorb",
			"absorption_fraction": (
				clampf(allocation_fraction * 0.5, 0.0, 1.0)
				if watershed_ai_active
				else definition["absorption_fraction"]
			),
			"repellent_force": 0.0,
			"wave_strength": 0.0,
			"influence": 0.0,
			"enabled": enabled,
		})
		if valid:
			_regime_extractor_polygons.append(extractor)


func _watershed_ai_scaled_extractor_rect(
	rectangle: Rect2,
	allocation_fraction: float,
) -> Rect2:
	var width_scale := clampf(
		sqrt(clampf(allocation_fraction, 0.0, 1.0) / 0.20),
		0.45,
		1.45,
	)
	var next_width := rectangle.size.x * width_scale
	var next_x := clampf(
		rectangle.get_center().x - next_width * 0.5,
		0.0,
		WORLD_SIZE.x - next_width,
	)
	return Rect2(
		Vector2(next_x, rectangle.position.y),
		Vector2(next_width, rectangle.size.y),
	)


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
	var active_particle_count := _flow_line_target_count(flow_rate)
	for process_material in _process_material_layers:
		process_material.set_shader_parameter(&"base_speed", effective_base_speed)
		process_material.set_shader_parameter(
			&"active_particle_count", float(active_particle_count)
		)
		process_material.set_shader_parameter(
			&"water_coverage_fraction", clampf(flow_rate, 0.0, 1.0)
		)
	for layer_index in range(_head_layers.size()):
		var head_layer: GPUParticles2D = _head_layers[layer_index]
		var desired_amount: int = maxi(_layer_slot_count(layer_index), 1)
		if head_layer.amount != desired_amount:
			head_layer.amount = desired_amount
		# Keep Godot's complete native emission cycle active. Logical selection is
		# evenly phased in the head shader; a reduced native amount_ratio is the
		# source of low-flow batch emission and blank intervals.
		if not is_equal_approx(head_layer.amount_ratio, 1.0):
			head_layer.amount_ratio = 1.0


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
		process_material.set_shader_parameter(
			&"bank_field_suction_reach_pixels",
			BANK_FIELD_SUCTION_REACH_PIXELS,
		)
		process_material.set_shader_parameter(
			&"bank_field_suction_crossflow_ratio",
			BANK_FIELD_SUCTION_CROSSFLOW_RATIO,
		)
		process_material.set_shader_parameter(
			&"bank_field_suction_streamwise_ratio",
			BANK_FIELD_SUCTION_STREAMWISE_RATIO,
		)
		process_material.set_shader_parameter(
			&"bank_field_min_withdrawal_speed_pixels",
			BANK_FIELD_MIN_WITHDRAWAL_SPEED_PIXELS,
		)
		process_material.set_shader_parameter(
			&"bank_field_capture_depth_pixels",
			BANK_FIELD_CAPTURE_DEPTH_PIXELS,
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
	_apply_regime_shader_parameters()
	_apply_trail_draw_parameters()
	if _overlay != null:
		_overlay.call(
			&"set_reservoir_geometry",
			reservoir_center_pixels,
			reservoir_radius_pixels
		)
	_configure_basin_budget_overlay()
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
	var enabled_slot_count := _flow_line_target_count(flow_rate)
	var active_count := 0
	for local_slot_index in range(_layer_slot_count(layer_index)):
		var global_slot_index := (
			local_slot_index * PALETTE_LAYER_COUNT + layer_index
		)
		if _flow_line_global_slot_enabled(global_slot_index, enabled_slot_count):
			active_count += 1
	return active_count


func _flow_line_global_slot_enabled(
	global_slot_index: int,
	enabled_slot_count: int
) -> bool:
	var capacity := maxi(particle_slots, 1)
	var enabled_count := clampi(enabled_slot_count, 0, capacity)
	if (
		enabled_count <= 0
		or global_slot_index < 0
		or global_slot_index >= capacity
	):
		return false
	return (
		floori(
			float(global_slot_index + 1) * float(enabled_count)
			/ float(capacity)
		)
		> floori(
			float(global_slot_index) * float(enabled_count)
			/ float(capacity)
		)
	)


func _flow_line_target_count(normalized_rate: float) -> int:
	var capacity := maxi(particle_slots, 1)
	var low_count := mini(FLOW_DENSITY_LOW_LINE_COUNT, capacity)
	var rate := clampf(normalized_rate, 0.0, 1.0)
	if rate <= 0.0:
		return 0
	if rate <= FLOW_DENSITY_LOW_RATE:
		return clampi(
			roundi(float(low_count) * rate / FLOW_DENSITY_LOW_RATE),
			0,
			capacity,
		)
	return clampi(
		roundi(
			lerpf(
				float(low_count),
				float(capacity),
				(rate - FLOW_DENSITY_LOW_RATE)
				/ (1.0 - FLOW_DENSITY_LOW_RATE),
			)
		),
		0,
		capacity,
	)


func _flow_line_amount_ratio(normalized_rate: float) -> float:
	return float(_flow_line_target_count(normalized_rate)) / float(maxi(particle_slots, 1))


func _flow_line_layer_amount_ratio(layer_index: int, normalized_rate: float) -> float:
	var layer_capacity := _layer_slot_count(layer_index)
	if layer_capacity <= 0:
		return 0.0
	var enabled_slot_count := _flow_line_target_count(normalized_rate)
	var enabled_layer_count := 0
	for local_slot_index in range(layer_capacity):
		var global_slot_index := (
			local_slot_index * PALETTE_LAYER_COUNT + layer_index
		)
		if _flow_line_global_slot_enabled(global_slot_index, enabled_slot_count):
			enabled_layer_count += 1
	return float(enabled_layer_count) / float(layer_capacity)


func _flow_inlet_band_y_range_pixels(normalized_rate: float) -> Vector2:
	var full_range := _shoreline_inlet_y_range_pixels()
	var center_y := (full_range.x + full_range.y) * 0.5
	var half_height := (
		(full_range.y - full_range.x)
		* clampf(normalized_rate, 0.0, 1.0)
		* 0.5
	)
	return Vector2(center_y - half_height, center_y + half_height)


func _apply_gate() -> void:
	var gate_half_width_pixels: float = _effective_gate_half_width_pixels()
	var effective_gate_open := _effective_gate_open()
	var runtime_targets_ready := (
		not _process_material_layers.is_empty() or _overlay != null
	)
	if not runtime_targets_ready:
		_gate_state_applied_to_runtime = false
		return
	if (
		_gate_state_applied_to_runtime
		and _applied_gate_open == effective_gate_open
		and _applied_authored_gate_open == gate_open
		and is_equal_approx(
			_applied_gate_half_width_pixels,
			gate_half_width_pixels,
		)
		and is_equal_approx(
			_applied_gate_width_world_units,
			gate_width,
		)
	):
		return
	for process_material in _process_material_layers:
		process_material.set_shader_parameter(&"gate_open", effective_gate_open)
		process_material.set_shader_parameter(
			&"gate_half_width", gate_half_width_pixels
		)
	if _overlay != null:
		_overlay.call(&"set_gate_open", effective_gate_open)
		_overlay.call(&"set_gate_half_width", gate_half_width_pixels)
	_applied_gate_open = effective_gate_open
	_applied_authored_gate_open = gate_open
	_applied_gate_half_width_pixels = gate_half_width_pixels
	_applied_gate_width_world_units = gate_width
	_gate_state_applied_to_runtime = (
		not _process_material_layers.is_empty() and _overlay != null
	)
	_gate_state_upload_count += 1
	if is_node_ready():
		gate_changed.emit(screen_id, RESERVOIR_ID, effective_gate_open, gate_width)


func _build_shoreline_obstacles() -> void:
	## Generate one immutable, stage-specific water-edge chain for each bank.
	## Runtime regime changes alter only the packed weight, never these vertices.
	var bottom_intrusions := _shoreline_intrusion_samples("bottom")
	var top_intrusions := _shoreline_intrusion_samples("top")
	var maximum_combined_intrusion := (
		WORLD_SIZE.y - SHORELINE_MIN_CHANNEL_HEIGHT_WORLD
	)
	for sample_index in range(SHORELINE_EDGE_VERTEX_COUNT):
		var combined := (
			float(bottom_intrusions[sample_index])
			+ float(top_intrusions[sample_index])
		)
		if combined <= maximum_combined_intrusion or combined <= 0.000001:
			continue
		var safe_scale := maximum_combined_intrusion / combined
		bottom_intrusions[sample_index] *= safe_scale
		top_intrusions[sample_index] *= safe_scale

	var bottom_edge := PackedVector2Array()
	var top_edge := PackedVector2Array()
	for sample_index in range(SHORELINE_EDGE_VERTEX_COUNT):
		var sample_x := float(sample_index)
		bottom_edge.append(Vector2(
			sample_x,
			float(bottom_intrusions[sample_index])
		))
		top_edge.append(Vector2(
			sample_x,
			WORLD_SIZE.y - float(top_intrusions[sample_index])
		))

	var bottom_polygon := bottom_edge.duplicate()
	bottom_polygon.append(Vector2(
		WORLD_SIZE.x + 1.0,
		-SHORELINE_CLOSURE_MARGIN_WORLD
	))
	bottom_polygon.append(Vector2(
		-1.0,
		-SHORELINE_CLOSURE_MARGIN_WORLD
	))
	var top_polygon := top_edge.duplicate()
	top_polygon.append(Vector2(
		WORLD_SIZE.x + 1.0,
		WORLD_SIZE.y + SHORELINE_CLOSURE_MARGIN_WORLD
	))
	top_polygon.append(Vector2(
		-1.0,
		WORLD_SIZE.y + SHORELINE_CLOSURE_MARGIN_WORLD
	))

	_shoreline_obstacles = [
		{
			"element_id": String(SHORELINE_TOP_ID),
			"side": "top",
			"channel_y_sign_pixels": 1.0,
			"weight": _shoreline_randomness,
			"influence_world": SHORELINE_INFLUENCE_WORLD,
			"vertices_world": top_edge,
			"polygon_vertices_world": top_polygon,
		},
		{
			"element_id": String(SHORELINE_BOTTOM_ID),
			"side": "bottom",
			"channel_y_sign_pixels": -1.0,
			"weight": _shoreline_randomness,
			"influence_world": SHORELINE_INFLUENCE_WORLD,
			"vertices_world": bottom_edge,
			"polygon_vertices_world": bottom_polygon,
		},
	]


func _shoreline_intrusion_samples(side: String) -> PackedFloat32Array:
	var samples := PackedFloat32Array()
	samples.resize(SHORELINE_EDGE_VERTEX_COUNT)
	for sample_index in range(SHORELINE_EDGE_VERTEX_COUNT):
		var seed_id := StringName("%s:%d:shoreline:%s:%d" % [
			String(screen_id),
			stage_index,
			side,
			sample_index,
		])
		samples[sample_index] = _stable_interaction_seed(seed_id)
	# One light low-pass pass creates connected bends without imposing the same
	# envelope on every river. Endpoints use clamped neighbors, so the inlet and
	# outlet are part of each stage's generated bank shape too.
	var smoothed := samples.duplicate()
	for sample_index in range(SHORELINE_EDGE_VERTEX_COUNT):
		var previous_index := maxi(sample_index - 1, 0)
		var following_index := mini(
			sample_index + 1,
			SHORELINE_EDGE_VERTEX_COUNT - 1
		)
		smoothed[sample_index] = (
			float(samples[previous_index])
			+ 2.0 * float(samples[sample_index])
			+ float(samples[following_index])
		) * 0.25 * SHORELINE_MAX_INTRUSION_WORLD
	return smoothed


func _shoreline_inlet_y_range_pixels() -> Vector2:
	return Vector2(
		SHORELINE_INLET_BASE_MARGIN_PIXELS,
		STAGE_SIZE.y - SHORELINE_INLET_BASE_MARGIN_PIXELS
	)


func _apply_shoreline_geometry() -> void:
	_edge_turbulence_parameter_upload_count += 1
	var inlet_y_range := _shoreline_inlet_y_range_pixels()
	for process_material in _process_material_layers:
		process_material.set_shader_parameter(&"shoreline_count", 0)
		process_material.set_shader_parameter(
			&"shoreline_inlet_y_range",
			inlet_y_range
		)
		process_material.set_shader_parameter(
			&"edge_turbulence_amount",
			_shoreline_randomness
		)
		process_material.set_shader_parameter(
			&"edge_turbulence_band_pixels",
			EDGE_TURBULENCE_BAND_PIXELS
		)
		process_material.set_shader_parameter(
			&"edge_turbulence_wall_band_pixels",
			EDGE_TURBULENCE_WALL_BAND_PIXELS
		)
		process_material.set_shader_parameter(
			&"edge_turbulence_crossflow_ratio",
			EDGE_TURBULENCE_CROSSFLOW_RATIO
		)
		process_material.set_shader_parameter(
			&"edge_turbulence_streamwise_ratio",
			EDGE_TURBULENCE_STREAMWISE_RATIO
		)
		process_material.set_shader_parameter(
			&"edge_turbulence_inward_ratio",
			EDGE_TURBULENCE_INWARD_RATIO
		)
	if _overlay != null:
		var no_shoreline_obstacles: Array[Dictionary] = []
		_overlay.call(&"set_shoreline_obstacles", no_shoreline_obstacles)


func _shoreline_runtime_definitions() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for definition: Dictionary in _shoreline_obstacles:
		var world_vertices: PackedVector2Array = definition["vertices_world"]
		var polygon_vertices: PackedVector2Array = (
			definition["polygon_vertices_world"]
		)
		result.append({
			"element_id": String(definition["element_id"]),
			"side": String(definition["side"]),
			"weight": float(definition.get("weight", 0.0)),
			"influence_world": float(definition["influence_world"]),
			"vertices": world_vertices.duplicate(),
			"vertices_world": world_vertices.duplicate(),
			"vertices_pixels": _polygon_native_vertices(world_vertices),
			"polygon_vertices_world": polygon_vertices.duplicate(),
		})
	return result


func _apply_interaction_geometry() -> void:
	var active_polygons: Array[GPUFlowInteractionPolygon] = []
	# The explicit budget extractors are the physical withdrawal geometry for
	# Agriculture, Gold Rush, Water Projects, and Tech. Put them first so their
	# visible bank rectangles and the water simulation use the same shapes.
	for extractor: GPUFlowInteractionPolygon in _regime_extractor_polygons:
		if extractor != null and extractor.enabled:
			active_polygons.append(extractor)
	var explicit_extractors_active := not active_polygons.is_empty()
	for polygon: GPUFlowInteractionPolygon in _gpu_interaction_polygons():
		var regime_managed := _is_regime_managed_interaction_polygon(polygon)
		# Keep controller-owned disabled records packed. Their enabled flag stays
		# zero in the texture, preserving fixed slot addressing without making
		# them visible or interactive. Disabled regime-managed slots can be
		# omitted because their slot bank is reconstructed from the active state.
		if not polygon.enabled and regime_managed:
			continue
		# Regime-owned drain slots are the retained fallback for regimes such as
		# Hydropower that have no explicit budget rectangle. When explicit
		# extractors are active, omitting those generic drains prevents double
		# withdrawal and keeps the bounded eight-polygon GPU contract.
		if (
			explicit_extractors_active
			and polygon.mode == GPUFlowInteractionPolygon.Mode.ABSORB
			and regime_managed
		):
			continue
		if active_polygons.size() < MAX_INTERACTION_POLYGONS:
			active_polygons.append(polygon)
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
		var bank_drain_sign := _native_bank_drain_sign(polygon.mode, bounds)
		var extractor_metadata := _basin_extractor_definition(
			String(polygon.element_id),
		)
		var visual_kind := String(extractor_metadata.get(
			"kind",
			"field" if polygon.mode == GPUFlowInteractionPolygon.Mode.ABSORB else "obstacle",
		))
		var geometry_label := String(extractor_metadata.get(
			"label",
			"FIELD" if polygon.mode == GPUFlowInteractionPolygon.Mode.ABSORB else "CITY",
		))
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
			Color(
				centroid.x,
				centroid.y,
				bank_drain_sign,
				1.0 if polygon.enabled else 0.0,
			)
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
			"bank_connected": absf(bank_drain_sign) > 0.5,
			"bank_side": _bank_side_name(bank_drain_sign),
			"intake_direction_pixels": Vector2(0.0, bank_drain_sign),
			"visual_kind": visual_kind,
			"label": geometry_label,
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


func _basin_extractor_definition(element_id: String) -> Dictionary:
	for definition: Dictionary in BasinBudgetModel.extractor_definitions():
		if String(definition.get("element_id", "")) == element_id:
			return definition
	return {}




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


func _native_bank_drain_sign(mode: int, bounds: Rect2) -> float:
	if mode != GPUFlowInteractionPolygon.Mode.ABSORB:
		return 0.0
	var touches_top := (
		bounds.position.y <= INTERACTION_BANK_EDGE_EPSILON_PIXELS
	)
	var touches_bottom := (
		bounds.end.y >= STAGE_SIZE.y - INTERACTION_BANK_EDGE_EPSILON_PIXELS
	)
	if touches_top == touches_bottom:
		return 0.0
	# Native coordinates point down: top-bank suction is -Y, bottom-bank +Y.
	return -1.0 if touches_top else 1.0


func _bank_side_name(bank_drain_sign: float) -> String:
	if bank_drain_sign < -0.5:
		return "TOP"
	if bank_drain_sign > 0.5:
		return "BOTTOM"
	return "NONE"


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
		_overlay.visible = true
	if is_node_ready():
		debug_visibility_changed.emit(screen_id, true)


func _defer_trail_recording_until_after_preprocess() -> void:
	# The head emitter prewarms sixteen seconds so low-speed, center-originating
	# flow opens in a steady spatial distribution rather than an inlet packet.
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
	# count while giving every color stable Z. The native emitters always run a
	# complete cycle; the shader selects evenly phased logical slots.
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
		process_material.set_shader_parameter(&"shoreline_count", 0)
		process_material.set_shader_parameter(
			&"particle_index_stride", float(PALETTE_LAYER_COUNT)
		)
		process_material.set_shader_parameter(
			&"particle_index_offset", float(layer_index)
		)
		process_material.set_shader_parameter(
			&"particle_slot_count", float(maxi(particle_slots, 1))
		)
		process_material.set_shader_parameter(
			&"active_particle_count",
			float(_flow_line_target_count(flow_rate))
		)
		process_material.set_shader_parameter(
			&"water_coverage_fraction", clampf(flow_rate, 0.0, 1.0)
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
		# Native amount ratio must remain full. Godot's reduced amount-ratio path
		# is unsuitable for a continuous low-count source; shader gating selects
		# the logical population at evenly spaced global phases instead.
		head_layer.amount_ratio = 1.0
		head_layer.lifetime = HEAD_EMISSION_CYCLE_SECONDS
		head_layer.preprocess = (
			HEAD_PREPROCESS_SECONDS
			+ float(layer_index)
			* HEAD_EMISSION_CYCLE_SECONDS
			/ float(maxi(particle_slots, 1))
		)
		head_layer.fixed_fps = PARTICLE_FIXED_FPS
		head_layer.interpolate = true
		head_layer.fract_delta = false
		# The global slot selector and small per-layer pre-process phase offset
		# provide an exact deterministic schedule; lifetime randomness would turn
		# that schedule back into uneven bursts.
		head_layer.randomness = HEAD_EMISSION_RANDOMNESS
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
	water_display.z_index = WATER_DISPLAY_Z_INDEX
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
	# Extraction geometry is land infrastructure beneath the visible river.
	_overlay.z_index = GEOMETRY_OVERLAY_Z_INDEX
	_overlay.z_as_relative = false
	_overlay.set(&"stage_index", stage_index)
	_overlay.set(&"show_status_label", false)
	_overlay.call(
		&"set_reservoir_geometry",
		reservoir_center_pixels,
		reservoir_radius_pixels
	)
	add_child(_overlay)


func _build_basin_budget_overlay() -> void:
	_delta_tide_overlay = BASIN_BUDGET_OVERLAY_SCRIPT.new() as Node2D
	_delta_tide_overlay.name = "DeltaTideOverlay"
	_delta_tide_overlay.z_index = TIDE_OVERLAY_Z_INDEX
	_delta_tide_overlay.z_as_relative = false
	_delta_tide_overlay.call(&"set_render_roles", true, false, false)
	add_child(_delta_tide_overlay)

	_basin_budget_canvas = CanvasLayer.new()
	_basin_budget_canvas.name = "BasinBudgetCanvas"
	_basin_budget_canvas.layer = 10
	add_child(_basin_budget_canvas)
	_basin_budget_overlay = BASIN_BUDGET_OVERLAY_SCRIPT.new() as Node2D
	_basin_budget_overlay.name = "BasinBudgetOverlay"
	_basin_budget_overlay.z_index = 0
	_basin_budget_overlay.z_as_relative = false
	_basin_budget_overlay.call(&"set_render_roles", false, true, true)
	_basin_budget_canvas.add_child(_basin_budget_overlay)
	_configure_basin_budget_overlay()


func _configure_basin_budget_overlay() -> void:
	if _basin_budget_overlay == null and _delta_tide_overlay == null:
		return
	var tide_sample_position := (
		float(_delta_tide_row_index) + _delta_tide_row_fraction
	)
	for budget_overlay: Node2D in [_delta_tide_overlay, _basin_budget_overlay]:
		if budget_overlay == null:
			continue
		budget_overlay.call(
			&"configure",
			screen_id,
			_basin_input_rate,
			_basin_extraction_fraction,
			_basin_remaining_rate,
			Array(_regime_snapshot.get("active_states", [])),
			_delta_tide_normalized_heights,
			tide_sample_position,
			_watershed_ai_applied_state,
		)


func _build_stage_title() -> void:
	_stage_title_layer = Node2D.new()
	_stage_title_layer.name = "StageTitleLayer"
	_stage_title_layer.z_index = STAGE_TITLE_Z_INDEX
	_stage_title_layer.z_as_relative = false
	add_child(_stage_title_layer)

	_stage_title_font = FontVariation.new()
	_stage_title_font.base_font = STAGE_TITLE_FONT
	_stage_title_font.opentype_features = {
		TextServerManager.get_primary_interface().name_to_tag(
			MODEL_DATE_OPENTYPE_FEATURE
		): 1,
	}

	_stage_title_label = Label.new()
	_stage_title_label.name = "StageTitle"
	_stage_title_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_stage_title_label.focus_mode = Control.FOCUS_NONE
	_stage_title_label.autowrap_mode = TextServer.AUTOWRAP_OFF
	_stage_title_label.clip_text = false
	_stage_title_label.add_theme_font_override(&"font", _stage_title_font)
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
	_model_date_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_model_date_label.focus_mode = Control.FOCUS_NONE
	_model_date_label.autowrap_mode = TextServer.AUTOWRAP_OFF
	_model_date_label.clip_text = false
	_model_date_label.add_theme_font_override(&"font", _stage_title_font)
	_model_date_label.add_theme_font_size_override(
		&"font_size",
		MODEL_DATE_FONT_SIZE
	)
	_model_date_label.add_theme_color_override(
		&"font_color",
		STAGE_TITLE_COLOR
	)
	_stage_title_layer.add_child(_model_date_label)
	_build_regime_panel()
	_apply_stage_title()
	_apply_model_date()
	_apply_water_temperature()


func _build_regime_panel() -> void:
	_regime_panel = Node2D.new()
	_regime_panel.name = "ActiveRegimes"
	_regime_panel.position = REGIME_PANEL_POSITION
	_regime_panel.rotation = TYPE_ROTATION_RADIANS
	_stage_title_layer.add_child(_regime_panel)

	_regime_heading_label = Label.new()
	_regime_heading_label.name = "Heading"
	_regime_heading_label.text = REGIME_HEADING_TEXT
	_regime_heading_label.position = Vector2(0.0, REGIME_HEADING_LOCAL_Y)
	_regime_heading_label.size = Vector2(520.0, REGIME_NAME_START_Y)
	_regime_heading_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_regime_heading_label.focus_mode = Control.FOCUS_NONE
	_regime_heading_label.autowrap_mode = TextServer.AUTOWRAP_OFF
	_regime_heading_label.clip_text = false
	_regime_heading_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_regime_heading_label.add_theme_font_override(&"font", STAGE_TITLE_FONT)
	_regime_heading_label.add_theme_font_size_override(
		&"font_size",
		REGIME_HEADING_FONT_SIZE,
	)
	_regime_heading_label.add_theme_color_override(
		&"font_color",
		STAGE_TITLE_COLOR,
	)
	_regime_panel.add_child(_regime_heading_label)

	_regime_name_labels.clear()
	for index in range(7):
		var regime_label := Label.new()
		regime_label.name = "Regime%d" % (index + 1)
		regime_label.position = Vector2(
			0.0,
			REGIME_NAME_START_Y + float(index) * REGIME_NAME_ROW_HEIGHT,
		)
		regime_label.size = Vector2(520.0, REGIME_NAME_ROW_HEIGHT)
		regime_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		regime_label.focus_mode = Control.FOCUS_NONE
		regime_label.autowrap_mode = TextServer.AUTOWRAP_OFF
		regime_label.clip_text = false
		regime_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		regime_label.add_theme_font_override(&"font", STAGE_TITLE_FONT)
		regime_label.add_theme_font_size_override(
			&"font_size",
			REGIME_NAME_FONT_SIZE,
		)
		_regime_panel.add_child(regime_label)
		_regime_name_labels.append(regime_label)
	_apply_regime_panel()


func _apply_regime_panel() -> void:
	if _regime_panel == null:
		return
	_regime_panel.visible = regime_panel_visible
	if _regime_heading_label != null:
		_regime_heading_label.visible = regime_heading_visible
	var names := Array(_regime_snapshot.get("regime_names", []))
	var active_states := Array(_regime_snapshot.get("active_states", []))
	for index in range(_regime_name_labels.size()):
		var label := _regime_name_labels[index]
		label.text = _regime_display_name(names, index)
		var active := index < active_states.size() and bool(active_states[index])
		var label_color := STAGE_TITLE_COLOR
		label_color.a = (
			REGIME_ACTIVE_ALPHA if active else REGIME_INACTIVE_ALPHA
		)
		label.add_theme_color_override(&"font_color", label_color)


func _regime_display_name(names: Array, index: int) -> String:
	if screen_id == &"delta":
		if index == WATER_PROJECTS_REGIME_INDEX:
			return DELTA_WATER_PROJECT_DISPLAY_NAME
		if index == WATERSHED_REGIME_INDEX:
			return DELTA_WATERSHED_DISPLAY_NAME
	return String(names[index]) if index < names.size() else ""


func _apply_stage_title(emit_title_signal: bool = true) -> void:
	if _stage_title_label == null:
		return
	var next_text := _formatted_stage_title()
	if _stage_title_label.text != next_text:
		_stage_title_label.text = next_text
		_center_label_on_rotated_centerline(
			_stage_title_label,
			STAGE_TITLE_POSITION
		)
	_stage_title_label.visible = stage_title_visible
	if emit_title_signal and is_node_ready():
		stage_title_changed.emit(screen_id, stage_title, stage_title_visible)


func _formatted_stage_title() -> String:
	if not stage_temperature_visible:
		return stage_title
	var temperature_text := _formatted_water_temperature()
	if stage_title.is_empty():
		return temperature_text
	return "%s (%s)" % [stage_title, temperature_text]


func _formatted_water_temperature() -> String:
	if _temperature_value_valid:
		return "%.1f °C" % _temperature_current_value_c
	return "— °C"


func _load_temperature_data() -> bool:
	_temperature_values = PackedFloat32Array()
	_temperature_data_error = ""
	_temperature_data_status = "NOT_CONFIGURED"
	_temperature_row_index = -1
	_temperature_row_fraction = 0.0
	_temperature_current_value_c = 0.0
	_temperature_value_valid = false

	if temperature_data_path.is_empty() or temperature_data_column.is_empty():
		_apply_water_temperature()
		return false
	if not FileAccess.file_exists(temperature_data_path):
		return _fail_temperature_data_load(
			"FILE_NOT_FOUND",
			"Water temperature data file not found: %s" % temperature_data_path,
		)

	var header_found := false
	var temperature_column_index := -1
	var data_line_number := 0
	var contents := FileAccess.get_file_as_string(temperature_data_path)
	for raw_line in contents.split("\n", false):
		data_line_number += 1
		var line := String(raw_line).strip_edges()
		if line.is_empty() or line.begins_with("#"):
			continue
		var columns := _split_temperature_data_line(line)
		if not header_found:
			if columns.is_empty() or String(columns[0]).strip_edges() != "frame":
				continue
			header_found = true
			for column_index in range(columns.size()):
				if String(columns[column_index]).strip_edges() == temperature_data_column:
					temperature_column_index = column_index
					break
			if temperature_column_index < 0:
				return _fail_temperature_data_load(
					"COLUMN_NOT_FOUND",
					"Water temperature column '%s' not found in: %s" % [
						temperature_data_column,
						temperature_data_path,
					],
				)
			continue
		if columns.size() <= temperature_column_index:
			return _fail_temperature_data_load(
				"INVALID_ROW",
				"Water temperature row %d is missing column '%s': %s" % [
					data_line_number,
					temperature_data_column,
					temperature_data_path,
				],
			)
		var frame_text := String(columns[0]).strip_edges()
		var temperature_text := String(
			columns[temperature_column_index]
		).strip_edges()
		if not frame_text.is_valid_int() or not temperature_text.is_valid_float():
			return _fail_temperature_data_load(
				"INVALID_ROW",
				"Water temperature row %d has invalid numeric data: %s" % [
					data_line_number,
					temperature_data_path,
				],
			)
		var frame_index := int(frame_text)
		if frame_index != _temperature_values.size():
			return _fail_temperature_data_load(
				"INVALID_FRAME_SEQUENCE",
				"Water temperature frame %d should be %d: %s" % [
					frame_index,
					_temperature_values.size(),
					temperature_data_path,
				],
			)
		var temperature_value := float(temperature_text)
		if not is_finite(temperature_value):
			return _fail_temperature_data_load(
				"INVALID_ROW",
				"Water temperature row %d is not finite: %s" % [
					data_line_number,
					temperature_data_path,
				],
			)
		_temperature_values.append(temperature_value)

	if not header_found:
		return _fail_temperature_data_load(
			"INVALID_HEADER",
			"Water temperature data has no frame header: %s" % temperature_data_path,
		)
	if _temperature_values.is_empty():
		return _fail_temperature_data_load(
			"NO_VALID_ROWS",
			"Water temperature data has no valid rows: %s" % temperature_data_path,
		)
	if _temperature_values.size() != WATER_TEMPERATURE_EXPECTED_ROW_COUNT:
		return _fail_temperature_data_load(
			"INVALID_ROW_COUNT",
			"Water temperature data has %d rows; expected %d: %s" % [
				_temperature_values.size(),
				WATER_TEMPERATURE_EXPECTED_ROW_COUNT,
				temperature_data_path,
			],
		)
	_temperature_data_status = "READY"
	return true


func _split_temperature_data_line(line: String) -> PackedStringArray:
	# Production data is comma-delimited. Accept the pipeline's earlier tabular
	# export too so an already-provisioned installation does not lose its label.
	if line.contains(","):
		return line.split(",", true)
	return line.split("\t", true)


func _fail_temperature_data_load(status: String, message: String) -> bool:
	_temperature_values = PackedFloat32Array()
	_temperature_data_status = status
	_temperature_data_error = message
	_temperature_row_index = -1
	_temperature_row_fraction = 0.0
	_temperature_current_value_c = 0.0
	_temperature_value_valid = false
	_apply_water_temperature()
	push_warning(message)
	return false


func _update_model_data_timelines() -> void:
	_update_watershed_timeline()
	_update_temperature_timeline()
	_update_delta_tide_timeline()


func _update_temperature_timeline() -> void:
	var row_count := _temperature_values.size()
	if row_count <= 0:
		_temperature_row_index = -1
		_temperature_row_fraction = 0.0
		_temperature_current_value_c = 0.0
		_temperature_value_valid = false
		_apply_water_temperature()
		return
	var year_seconds := maxf(model_year_duration_seconds, 0.001)
	var year_progress := clampf(
		_model_year_elapsed_seconds / year_seconds,
		0.0,
		0.999999,
	)
	var row_position := year_progress * float(row_count)
	var next_row_index := mini(floori(row_position), row_count - 1)
	var row_fraction := row_position - floorf(row_position)
	var following_row_index := (next_row_index + 1) % row_count
	_temperature_row_index = next_row_index
	_temperature_row_fraction = row_fraction
	_temperature_current_value_c = lerpf(
		float(_temperature_values[next_row_index]),
		float(_temperature_values[following_row_index]),
		row_fraction,
	)
	_temperature_value_valid = is_finite(_temperature_current_value_c)
	_apply_water_temperature()


func _load_delta_tide_data() -> bool:
	_delta_tide_heights = PackedFloat32Array()
	_delta_tide_normalized_heights = PackedFloat32Array()
	_delta_tide_normalized_velocities = PackedFloat32Array()
	_delta_tide_data_error = ""
	_delta_tide_data_status = "NOT_DELTA"
	_delta_tide_row_index = -1
	_delta_tide_row_fraction = 0.0
	_delta_tide_current_height_m = 0.0
	_delta_tide_current_normalized_height = 0.0
	_delta_tide_current_normalized_velocity = 0.0
	if screen_id != &"delta":
		return false
	if not FileAccess.file_exists(DELTA_TIDE_DATA_PATH):
		_delta_tide_data_status = "FILE_NOT_FOUND"
		_delta_tide_data_error = (
			"Delta tide data file not found: %s" % DELTA_TIDE_DATA_PATH
		)
		push_warning(_delta_tide_data_error)
		return false
	var line_number := 0
	for raw_line in FileAccess.get_file_as_string(
		DELTA_TIDE_DATA_PATH
	).split("\n", false):
		line_number += 1
		var line := String(raw_line).strip_edges()
		if line.is_empty() or line.begins_with("#") or line.begins_with("frame"):
			continue
		var columns := line.split("\t", false)
		if columns.size() < 5:
			return _fail_delta_tide_data_load(
				"INVALID_ROW",
				"Delta tide row %d has fewer than five columns." % line_number,
			)
		if (
			not String(columns[0]).is_valid_int()
			or not String(columns[2]).is_valid_float()
			or not String(columns[3]).is_valid_float()
			or not String(columns[4]).is_valid_float()
		):
			return _fail_delta_tide_data_load(
				"INVALID_ROW",
				"Delta tide row %d has invalid numeric data." % line_number,
			)
		var frame_index := int(columns[0])
		if frame_index != _delta_tide_heights.size():
			return _fail_delta_tide_data_load(
				"INVALID_FRAME_SEQUENCE",
				"Delta tide frame %d should be %d." % [
					frame_index,
					_delta_tide_heights.size(),
				],
			)
		var height := float(columns[2])
		var normalized_height := float(columns[3])
		var normalized_velocity := float(columns[4])
		if (
			not is_finite(height)
			or not is_finite(normalized_height)
			or not is_finite(normalized_velocity)
		):
			return _fail_delta_tide_data_load(
				"INVALID_ROW",
				"Delta tide row %d contains a non-finite value." % line_number,
			)
		_delta_tide_heights.append(height)
		_delta_tide_normalized_heights.append(clampf(normalized_height, 0.0, 1.0))
		_delta_tide_normalized_velocities.append(clampf(normalized_velocity, -1.0, 1.0))
	if _delta_tide_heights.size() != DELTA_TIDE_EXPECTED_ROW_COUNT:
		return _fail_delta_tide_data_load(
			"INVALID_ROW_COUNT",
			"Delta tide data has %d rows; expected %d." % [
				_delta_tide_heights.size(),
				DELTA_TIDE_EXPECTED_ROW_COUNT,
			],
		)
	_delta_tide_data_status = "READY"
	_delta_tide_current_height_m = float(_delta_tide_heights[0])
	_delta_tide_current_normalized_height = float(
		_delta_tide_normalized_heights[0]
	)
	_delta_tide_current_normalized_velocity = float(
		_delta_tide_normalized_velocities[0]
	)
	return true


func _fail_delta_tide_data_load(status: String, message: String) -> bool:
	_delta_tide_heights = PackedFloat32Array()
	_delta_tide_normalized_heights = PackedFloat32Array()
	_delta_tide_normalized_velocities = PackedFloat32Array()
	_delta_tide_data_status = status
	_delta_tide_data_error = message
	_delta_tide_row_index = -1
	_delta_tide_row_fraction = 0.0
	_delta_tide_current_height_m = 0.0
	_delta_tide_current_normalized_height = 0.0
	_delta_tide_current_normalized_velocity = 0.0
	push_warning(message)
	return false


func _update_delta_tide_timeline() -> void:
	var row_count := _delta_tide_heights.size()
	if row_count <= 0:
		return
	var year_seconds := maxf(model_year_duration_seconds, 0.001)
	var year_progress := clampf(
		_model_year_elapsed_seconds / year_seconds,
		0.0,
		0.999999,
	)
	var row_position := year_progress * float(row_count)
	var row_index := mini(floori(row_position), row_count - 1)
	var following_index := (row_index + 1) % row_count
	var row_fraction := row_position - floorf(row_position)
	_delta_tide_row_index = row_index
	_delta_tide_row_fraction = row_fraction
	_delta_tide_current_height_m = lerpf(
		float(_delta_tide_heights[row_index]),
		float(_delta_tide_heights[following_index]),
		row_fraction,
	)
	_delta_tide_current_normalized_height = lerpf(
		float(_delta_tide_normalized_heights[row_index]),
		float(_delta_tide_normalized_heights[following_index]),
		row_fraction,
	)
	_delta_tide_current_normalized_velocity = lerpf(
		float(_delta_tide_normalized_velocities[row_index]),
		float(_delta_tide_normalized_velocities[following_index]),
		row_fraction,
	)
	_configure_basin_budget_overlay()


func _load_watershed_data() -> bool:
	_watershed_raw_values = PackedFloat32Array()
	_watershed_normalized_flow = PackedFloat32Array()
	_watershed_running_average_flow = PackedFloat32Array()
	_watershed_scaled_flow = PackedFloat32Array()
	_watershed_high_variation = PackedByteArray()
	_watershed_data_river = ""
	_watershed_data_error = ""
	_watershed_fog_baseline_mm_day = 0.0
	_watershed_fog_baseline_normalized = 0.0
	_morning_fog_pulse_multiplier = 0.0
	_watershed_row_index = -1
	_watershed_row_fraction = 0.0
	_watershed_interpolated_flow_rate = 0.0
	_watershed_buffered_flow_rate = 0.0
	_watershed_running_average_sample_count = 0

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
				elif token.begins_with("fog_baseline_mm_day="):
					var raw_fog_mm := token.trim_prefix("fog_baseline_mm_day=")
					if raw_fog_mm.is_valid_float():
						_watershed_fog_baseline_mm_day = maxf(float(raw_fog_mm), 0.0)
				elif token.begins_with("fog_baseline_norm="):
					var raw_fog_norm := token.trim_prefix("fog_baseline_norm=")
					if raw_fog_norm.is_valid_float():
						_watershed_fog_baseline_normalized = clampf(
							float(raw_fog_norm), 0.0, 1.0
						)
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
		# Column two is atmospheric basin arrival in mm/day. Keep this retained
		# API field unit-neutral so older controllers can still read raw_value.
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
	_rebuild_watershed_running_average()
	if watershed_data_drives_flow_rate:
		_morning_fog_pulse_multiplier = _morning_fog_multiplier(
			_model_minute_of_day
		)
		_watershed_buffered_flow_rate = float(
			_watershed_running_average_flow[0]
		)
		_basin_input_rate = _atmospheric_input_with_morning_fog(
			_watershed_buffered_flow_rate
		)
		_recalculate_basin_budget(false)
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
	var current_buffered := float(
		_watershed_running_average_flow[next_row_index]
	)
	var following_buffered := float(
		_watershed_running_average_flow[following_row_index]
	)
	_watershed_buffered_flow_rate = (
		lerpf(current_buffered, following_buffered, row_fraction)
		if watershed_interpolate_flow_rate
		else current_buffered
	)
	_watershed_row_fraction = row_fraction
	var row_changed := next_row_index != _watershed_row_index
	_watershed_row_index = next_row_index

	if watershed_data_drives_flow_rate:
		_morning_fog_pulse_multiplier = _morning_fog_multiplier(
			_model_minute_of_day
		)
		_basin_input_rate = _atmospheric_input_with_morning_fog(
			_watershed_buffered_flow_rate
		)
		_recalculate_basin_budget(false)
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


func _morning_fog_multiplier(minute_of_day: int) -> float:
	if (
		minute_of_day < MORNING_FOG_START_MINUTE
		or minute_of_day > MORNING_FOG_END_MINUTE
	):
		return 0.0
	var window_progress := clampf(
		float(minute_of_day - MORNING_FOG_START_MINUTE)
		/ float(MORNING_FOG_WINDOW_MINUTES),
		0.0,
		1.0,
	)
	return sin(window_progress * PI) * MORNING_FOG_PEAK_MULTIPLIER


func _rebuild_watershed_running_average() -> void:
	_watershed_running_average_flow = PackedFloat32Array()
	var row_count := _watershed_normalized_flow.size()
	if row_count <= 0:
		_watershed_running_average_sample_count = 0
		return
	_watershed_running_average_sample_count = clampi(
		roundi(
			float(row_count)
			* BASIN_INPUT_RUNNING_AVERAGE_DAYS
			/ float(MODEL_CALENDAR_DAY_COUNT)
		),
		1,
		row_count,
	)
	for row_index in range(row_count):
		var total := 0.0
		for sample_offset in range(_watershed_running_average_sample_count):
			var sample_index := posmod(
				row_index - sample_offset,
				row_count,
			)
			total += float(_watershed_normalized_flow[sample_index])
		_watershed_running_average_flow.append(
			total / float(_watershed_running_average_sample_count)
		)


func _atmospheric_input_with_morning_fog(base_rate: float) -> float:
	# The 720-point series contains the daily-average fog volume. Replace that
	# constant component with a smooth dawn pulse whose 24-hour integral is the
	# same, so the model gains timing without inventing extra annual water.
	var fog_adjustment := _watershed_fog_baseline_normalized * (
		_morning_fog_pulse_multiplier - 1.0
	)
	return clampf(
		maxf(base_rate + fog_adjustment, BASIN_INPUT_MINIMUM_RATE),
		0.0,
		1.0,
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
	_update_model_data_timelines()
	if day_changed:
		_apply_regime_ecology_schedule()


func _reset_model_calendar() -> void:
	if _model_timeline != null:
		_model_timeline.call(&"reset")
		return
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
	_update_model_data_timelines()
	_apply_regime_ecology_schedule()


func _set_model_day_index(day_index: int) -> void:
	if _model_timeline != null:
		_model_timeline.call(
			&"set_date",
			posmod(day_index, MODEL_CALENDAR_DAY_COUNT),
			0,
			&"external_day_index",
		)
		return
	_model_day_index = posmod(day_index, MODEL_CALENDAR_DAY_COUNT)
	_model_minute_of_day = 0
	_apply_model_date()
	_update_model_data_timelines()
	_apply_regime_ecology_schedule()


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
	_center_label_on_rotated_centerline(
		_model_date_label,
		MODEL_DATE_POSITION
	)
	if emit_date_signal and is_node_ready():
		model_date_changed.emit(
			screen_id,
			_format_model_date(_model_day_index),
			_model_day_index + 1
		)


func _apply_water_temperature() -> void:
	# Temperature is part of the stage title. Re-center only when its one-decimal
	# display value changes, and do not emit a title-change signal on each model
	# timeline update.
	_apply_stage_title(false)


func _center_label_on_rotated_centerline(
	label: Label,
	centerline: Vector2
) -> void:
	label.reset_size()
	label.pivot_offset = label.size * 0.5
	label.position = centerline - label.pivot_offset
	label.rotation = TYPE_ROTATION_RADIANS


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
