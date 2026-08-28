class_name GPUSalmon2D
extends Node2D

## Isolated, write-only GPU salmon subsystem.
##
## A fixed 300 x 2 CPU control texture carries release commands: row zero holds
## generations, ordinary lanes (or routed captured speeds), palette indices,
## and routed destination-group offsets; row one optionally holds a Delta cohort
## edge anchor, exact branch merge X, and authoritative survival bit.
## Head motion, water contact, reverse-Bezier routing, latching, fading, and
## immutable trail emission remain GPU-owned. No simulation state is read back.

signal salmon_released(
	requested_count: int,
	scheduled_count: int,
	release_serial: int
)
signal salmon_cohorts_released(
	cohorts: Array,
	requested_count: int,
	scheduled_count: int,
	survivor_count: int,
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
const DEFAULT_COHORT_COUNT := 25
const CONTROL_TEXTURE_ROWS := 2
const PALETTE_SIZE := 5
const SEGMENT_CAPACITY_MARGIN := 1.25
const COHORT_EDGE_EPSILON_PIXELS := 0.5
const DELTA_ROUTE_ANCHOR_EPSILON_PIXELS := 1.0
const DELTA_ROUTE_TRUNK_CENTER_Y_PIXELS := 540.0
const DELTA_ROUTE_TURN_PIXELS := 240.0
const DELTA_ROUTE_APPROACH_PIXELS := 240.0
const DELTA_ROUTE_LOOKAHEAD_PIXELS := 120.0
const DELTA_ROUTE_SPAWN_STAGGER_SECONDS := 2.50
const DELTA_ROUTE_GROUP_OFFSET_MAX_SECONDS := 6.0
const DELTA_ROUTE_SCREEN_IDS: Array[String] = [
	"mount_shasta",
	"mccloud_pit",
	"cottonwood_creek",
	"mill_creek",
	"feather_river",
	"american_river",
]
const DELTA_ROUTE_ANCHORS: Array[Vector2] = [
	Vector2(0.0, 120.0),
	Vector2(0.0, 840.0),
	Vector2(1200.0, 1080.0),
	Vector2(360.0, 1080.0),
	Vector2(600.0, 0.0),
	Vector2(1440.0, 0.0),
]
const DELTA_ROUTE_MERGE_X_PIXELS: Array[float] = [
	480.0,
	480.0,
	1440.0,
	720.0,
	960.0,
	1680.0,
]

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

@export_group("Delta Cohort Rail")
@export_range(60.0, 300.0, 1.0) var delta_route_turn_pixels: float = (
	DELTA_ROUTE_TURN_PIXELS
)
@export_range(0.0, 1080.0, 1.0) var delta_route_trunk_center_y_pixels: float = (
	DELTA_ROUTE_TRUNK_CENTER_Y_PIXELS
)
@export_range(60.0, 600.0, 1.0) var delta_route_approach_pixels: float = (
	DELTA_ROUTE_APPROACH_PIXELS
)
@export_range(16.0, 360.0, 1.0) var delta_route_lookahead_pixels: float = (
	DELTA_ROUTE_LOOKAHEAD_PIXELS
)
@export_range(0.0, 5.0, 0.05) var delta_route_spawn_stagger_seconds: float = (
	DELTA_ROUTE_SPAWN_STAGGER_SECONDS
)
@export_range(0.0, 12.0, 0.05) var delta_route_group_offset_max_seconds: float = (
	DELTA_ROUTE_GROUP_OFFSET_MAX_SECONDS
)

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
var _last_release_mode: String = "NONE"
var _last_cohorts: Array[Dictionary] = []
var _last_cohort_requested_count: int = 0
var _last_cohort_scheduled_count: int = 0
var _last_cohort_survivor_count: int = 0
var _last_cohort_death_count: int = 0
var _total_cohort_scheduled: int = 0
var _total_cohort_survivors: int = 0
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
			"delta_route_turn_pixels":
				delta_route_turn_pixels = clampf(float(value), 60.0, 300.0)
			"delta_route_trunk_center_y_pixels":
				delta_route_trunk_center_y_pixels = clampf(
					float(value), 0.0, stage_size.y
				)
			"delta_route_approach_pixels":
				delta_route_approach_pixels = clampf(float(value), 60.0, 600.0)
			"delta_route_lookahead_pixels":
				delta_route_lookahead_pixels = clampf(float(value), 16.0, 360.0)
			"delta_route_spawn_stagger_seconds":
				delta_route_spawn_stagger_seconds = clampf(float(value), 0.0, 5.0)
			"delta_route_group_offset_max_seconds":
				delta_route_group_offset_max_seconds = clampf(float(value), 0.0, 12.0)
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
	_clear_last_cohort_release(&"STANDARD")
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
		# Row one is reserved for Delta cohort routing. Clearing it explicitly is
		# essential when the circular pool overwrites a routed generation with an
		# ordinary upstream-stage release.
		_control_image.set_pixel(slot, 1, Color(0.0, 0.0, 0.0, 0.0))
		_write_slot = (_write_slot + 1) % CAPACITY
	_control_texture.update(_control_image)
	_last_scheduled = requested
	_total_scheduled += requested
	salmon_released.emit(requested, requested, _release_serial)
	return requested


func release_salmon_cohorts(cohorts: Array[Dictionary]) -> int:
	## Jointly schedules bounded, destination-routed Delta cohorts in the same
	## fixed 300-slot pool used by release_salmon(). Each dictionary requires a
	## non-empty `source_screen` (also used as the destination name unless
	## `destination_screen` is supplied), an edge anchor under
	## `destination_anchor_pixels` (aliases: `destination_anchor`, `destination`),
	## and an optional count from 1 through 25 (default/full cohort 25). The anchor
	## must match one of the six fixed Delta tributary mouths; its exact merge X is
	## encoded alongside it for GPU-only reverse-cubic steering. A cohort may
	## additionally provide an exact `survivor_count` or a `survival_fraction` in
	## 0..1. The CPU writes one deterministic survival bit per fish, so the supplied
	## survivor total is authoritative without reading live GPU state back.
	if _control_image == null or _control_texture == null or cohorts.is_empty():
		return 0

	var valid_cohorts: Array[Dictionary] = []
	var total_requested := 0
	for cohort: Dictionary in cohorts:
		var source_screen := String(cohort.get("source_screen", "")).strip_edges()
		var destination_screen := String(cohort.get(
			"destination_screen",
			cohort.get("destination_name", source_screen),
		)).strip_edges()
		var requested_count := _strict_positive_int(
			cohort.get("count", DEFAULT_COHORT_COUNT)
		)
		var destination_value: Variant = cohort.get(
			"destination_anchor_pixels",
			cohort.get("destination_anchor", cohort.get("destination", null)),
		)
		var destination := _validated_cohort_destination(destination_value)
		var route_index := _delta_route_index_for_anchor(destination)
		if (
			source_screen.is_empty()
			or destination_screen.is_empty()
			or requested_count <= 0
			or requested_count > DEFAULT_COHORT_COUNT
			or not is_finite(destination.x)
			or not is_finite(destination.y)
			or route_index < 0
		):
			continue
		var survivor_count := _resolved_cohort_survivor_count(
			cohort,
			requested_count,
		)
		if survivor_count < 0:
			continue
		valid_cohorts.append({
			"source_screen": source_screen,
			"destination_screen": destination_screen,
			"destination_anchor_pixels": destination,
			"destination_route_index": route_index,
			"destination_merge_x_pixels": DELTA_ROUTE_MERGE_X_PIXELS[route_index],
			"requested_count": requested_count,
			"survivor_count": survivor_count,
		})
		total_requested += requested_count

	var total_to_schedule := mini(total_requested, CAPACITY)
	if total_to_schedule <= 0:
		return 0

	_release_serial += 1
	var scheduled_total := 0
	var scheduled_survivor_total := 0
	# Routed generations must not change speed after their CPU handoff deadline is
	# scheduled. Row-zero G stores their captured base speed and A stores one plus
	# the cohort's exact group offset; ordinary G/A remain lane selector / 1.0.
	var captured_base_speed_pixels := maxf(upstream_speed_pixels, 1.0)
	var cohort_summaries: Array[Dictionary] = []
	for cohort_index in range(valid_cohorts.size()):
		if scheduled_total >= total_to_schedule:
			break
		var cohort: Dictionary = valid_cohorts[cohort_index]
		var destination_route_index := int(cohort["destination_route_index"])
		var group_offset_seconds := _cohort_group_offset_seconds(
			_release_serial,
			destination_route_index,
		)
		var requested_count := int(cohort["requested_count"])
		var requested_survivors := int(cohort["survivor_count"])
		var scheduled_count := mini(
			requested_count,
			total_to_schedule - scheduled_total,
		)
		var cohort_scheduled_survivors := 0
		var rotation := posmod(
			_release_serial * 7 + cohort_index * 11,
			requested_count,
		)
		for fish_index in range(scheduled_count):
			var slot := _write_slot
			var next_generation := _slot_generations[slot] + 1
			if next_generation > 1000000:
				next_generation = 1
			_slot_generations[slot] = next_generation
			var palette_index := (
				cohort_index + fish_index + _release_serial - 1
			) % PALETTE_SIZE
			var survives := _cohort_fish_survives(
				fish_index,
				requested_count,
				requested_survivors,
				rotation,
			)
			if survives:
				cohort_scheduled_survivors += 1
			_control_image.set_pixel(
				slot,
				0,
				Color(
					float(next_generation),
					captured_base_speed_pixels,
					float(palette_index),
					1.0 + group_offset_seconds,
				),
			)
			var destination: Vector2 = Vector2(cohort["destination_anchor_pixels"])
			var destination_merge_x := float(
				cohort["destination_merge_x_pixels"]
			)
			# Row one is (destination.x, destination.y, merge_x, survives).
			# merge_x == 0 identifies ordinary, non-routed generations.
			_control_image.set_pixel(
				slot,
				1,
				Color(
					destination.x,
					destination.y,
					destination_merge_x,
					1.0 if survives else 0.0,
				),
			)
			_write_slot = (_write_slot + 1) % CAPACITY
		cohort_summaries.append({
			"source_screen": String(cohort["source_screen"]),
			"destination_screen": String(cohort["destination_screen"]),
			"destination_anchor_pixels": Vector2(
				cohort["destination_anchor_pixels"]
			),
			"destination_route_index": destination_route_index,
			"destination_merge_x_pixels": float(
				cohort["destination_merge_x_pixels"]
			),
			"captured_base_speed_pixels": captured_base_speed_pixels,
			"group_offset_seconds": group_offset_seconds,
			"destination_edge": _cohort_destination_edge(
				Vector2(cohort["destination_anchor_pixels"])
			),
			"requested_count": requested_count,
			"scheduled_count": scheduled_count,
			"requested_survivor_count": requested_survivors,
			"scheduled_survivor_count": cohort_scheduled_survivors,
			"survivor_count": cohort_scheduled_survivors,
			"scheduled_death_count": (
				scheduled_count - cohort_scheduled_survivors
			),
			"death_count": scheduled_count - cohort_scheduled_survivors,
			"survival_fraction": (
				float(requested_survivors) / float(requested_count)
			),
		})
		scheduled_total += scheduled_count
		scheduled_survivor_total += cohort_scheduled_survivors

	_control_texture.update(_control_image)
	_last_release_mode = "COHORTS"
	_last_cohorts = cohort_summaries
	_last_cohort_requested_count = total_requested
	_last_cohort_scheduled_count = scheduled_total
	_last_cohort_survivor_count = scheduled_survivor_total
	_last_cohort_death_count = scheduled_total - scheduled_survivor_total
	_total_cohort_scheduled += scheduled_total
	_total_cohort_survivors += scheduled_survivor_total
	_last_scheduled = scheduled_total
	_total_scheduled += scheduled_total
	salmon_released.emit(total_requested, scheduled_total, _release_serial)
	salmon_cohorts_released.emit(
		_last_cohorts.duplicate(true),
		total_requested,
		scheduled_total,
		scheduled_survivor_total,
		_release_serial,
	)
	return scheduled_total


func _clear_last_cohort_release(mode: StringName) -> void:
	_last_release_mode = String(mode)
	_last_cohorts = []
	_last_cohort_requested_count = 0
	_last_cohort_scheduled_count = 0
	_last_cohort_survivor_count = 0
	_last_cohort_death_count = 0


func _strict_positive_int(value: Variant) -> int:
	if typeof(value) != TYPE_INT and typeof(value) != TYPE_FLOAT:
		return -1
	var numeric_value := float(value)
	if (
		not is_finite(numeric_value)
		or numeric_value < 1.0
		or not is_equal_approx(numeric_value, roundf(numeric_value))
	):
		return -1
	return int(numeric_value)


func _strict_nonnegative_int(value: Variant) -> int:
	if typeof(value) != TYPE_INT and typeof(value) != TYPE_FLOAT:
		return -1
	var numeric_value := float(value)
	if (
		not is_finite(numeric_value)
		or numeric_value < 0.0
		or not is_equal_approx(numeric_value, roundf(numeric_value))
	):
		return -1
	return int(numeric_value)


func _resolved_cohort_survivor_count(
	cohort: Dictionary,
	count: int,
) -> int:
	if cohort.has("survivor_count"):
		var explicit_count := _strict_nonnegative_int(cohort["survivor_count"])
		if explicit_count < 0 or explicit_count > count:
			return -1
		return explicit_count
	if cohort.has("survival_fraction"):
		var value: Variant = cohort["survival_fraction"]
		if typeof(value) != TYPE_INT and typeof(value) != TYPE_FLOAT:
			return -1
		var fraction := float(value)
		if not is_finite(fraction) or fraction < 0.0 or fraction > 1.0:
			return -1
		return clampi(floori(float(count) * fraction + 0.5), 0, count)
	return count


func _validated_cohort_destination(value: Variant) -> Vector2:
	if value == null:
		return Vector2(INF, INF)
	var parsed := _variant_to_vector2(value, Vector2(INF, INF))
	if not is_finite(parsed.x) or not is_finite(parsed.y):
		return Vector2(INF, INF)
	var epsilon := COHORT_EDGE_EPSILON_PIXELS
	if (
		parsed.x < -epsilon
		or parsed.x > stage_size.x + epsilon
		or parsed.y < -epsilon
		or parsed.y > stage_size.y + epsilon
	):
		return Vector2(INF, INF)
	# Tributary destinations are deliberately limited to the left, top, and
	# bottom boundaries. The right boundary is the shared Delta/ocean release.
	if parsed.x <= epsilon:
		return Vector2(0.0, clampf(parsed.y, 0.0, stage_size.y))
	if parsed.y <= epsilon:
		return Vector2(clampf(parsed.x, 0.0, stage_size.x), 0.0)
	if parsed.y >= stage_size.y - epsilon:
		return Vector2(
			clampf(parsed.x, 0.0, stage_size.x),
			stage_size.y,
		)
	return Vector2(INF, INF)


func _cohort_destination_edge(destination: Vector2) -> String:
	if destination.x <= COHORT_EDGE_EPSILON_PIXELS:
		return "LEFT"
	if destination.y <= COHORT_EDGE_EPSILON_PIXELS:
		return "TOP"
	return "BOTTOM"


func _delta_route_index_for_anchor(destination: Vector2) -> int:
	if not is_finite(destination.x) or not is_finite(destination.y):
		return -1
	for route_index in range(DELTA_ROUTE_ANCHORS.size()):
		if destination.distance_to(DELTA_ROUTE_ANCHORS[route_index]) <= (
			DELTA_ROUTE_ANCHOR_EPSILON_PIXELS
		):
			return route_index
	return -1


func _delta_route_runtime_summaries() -> Array[Dictionary]:
	var routes: Array[Dictionary] = []
	var trunk_y := clampf(delta_route_trunk_center_y_pixels, 0.0, stage_size.y)
	var turn_handle := maxf(delta_route_turn_pixels, 60.0)
	for route_index in range(DELTA_ROUTE_ANCHORS.size()):
		var point_0 := DELTA_ROUTE_ANCHORS[route_index]
		var inward := _delta_route_inward_direction(point_0)
		var point_3 := Vector2(
			DELTA_ROUTE_MERGE_X_PIXELS[route_index],
			trunk_y,
		)
		var horizontal_handle := minf(
			turn_handle,
			maxf(180.0, absf(point_3.y - point_0.y) * 0.5),
		)
		var inlet_handle := (
			horizontal_handle
			if absf(inward.x) > 0.5
			else minf(
				turn_handle,
				maxf(absf(point_3.y - point_0.y) * 0.45, 60.0),
			)
		)
		var outlet_handle := (
			horizontal_handle
			if absf(inward.x) > 0.5
			else minf(turn_handle, 180.0)
		)
		var point_1 := point_0 + inward * inlet_handle
		var point_2 := point_3 - Vector2(outlet_handle, 0.0)
		routes.append({
			"route_index": route_index,
			"destination_screen": DELTA_ROUTE_SCREEN_IDS[route_index],
			"destination_anchor_pixels": point_0,
			"merge_x_pixels": DELTA_ROUTE_MERGE_X_PIXELS[route_index],
			"inward_direction": inward,
			"point_0": point_0,
			"point_1": point_1,
			"point_2": point_2,
			"point_3": point_3,
		})
	return routes


func _delta_route_inward_direction(destination: Vector2) -> Vector2:
	if destination.x <= COHORT_EDGE_EPSILON_PIXELS:
		return Vector2.RIGHT
	if destination.y <= COHORT_EDGE_EPSILON_PIXELS:
		return Vector2.DOWN
	return Vector2.UP


func _cohort_fish_survives(
	fish_index: int,
	cohort_count: int,
	survivor_count: int,
	rotation: int,
) -> bool:
	if survivor_count <= 0:
		return false
	if survivor_count >= cohort_count:
		return true
	# This thresholded, rotated stratification marks exactly survivor_count of
	# cohort_count indices without RNG state or a CPU collection that grows over
	# time. Rotation changes the identities on each joint release while retaining
	# the exact authoritative total.
	var rotated_index := posmod(fish_index + rotation, cohort_count)
	return (
		floori(float(rotated_index + 1) * float(survivor_count) / float(cohort_count))
		> floori(float(rotated_index) * float(survivor_count) / float(cohort_count))
	)


func _cohort_group_offset_seconds(
	release_serial: int,
	destination_route_index: int,
) -> float:
	## Deterministic destination-level visual timing. Route index is the immutable
	## destination identity; release serial changes the ordering on every release.
	## The exact result is encoded in every routed command for that cohort.
	var seed := (
		float(maxi(release_serial, 0)) * 37.719
		+ float(maxi(destination_route_index, 0) + 1) * 91.337
	)
	var unit_offset := fposmod(
		sin(seed * 12.9898 + 78.233) * 43758.5453123,
		1.0,
	)
	return unit_offset * maxf(delta_route_group_offset_max_seconds, 0.0)


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
		_control_image.set_pixel(slot, 1, Color(0.0, 0.0, 0.0, 0.0))
	_control_texture.update(_control_image)
	_write_slot = 0
	_release_serial = 0
	_total_scheduled = 0
	_last_scheduled = 0
	_last_release_mode = "NONE"
	_last_cohorts = []
	_last_cohort_requested_count = 0
	_last_cohort_scheduled_count = 0
	_last_cohort_survivor_count = 0
	_last_cohort_death_count = 0
	_total_cohort_scheduled = 0
	_total_cohort_survivors = 0
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
		"control_texture_rows": CONTROL_TEXTURE_ROWS,
		"segment_capacity": (
			_segment_particles.amount if _segment_particles != null else 0
		),
		"release_serial": _release_serial,
		"total_scheduled": _total_scheduled,
		"last_scheduled": _last_scheduled,
		"last_release_mode": _last_release_mode,
		"cohort_release_supported": true,
		"default_cohort_count": DEFAULT_COHORT_COUNT,
		"last_cohorts": _last_cohorts.duplicate(true),
		"last_cohort_count": _last_cohorts.size(),
		"last_cohort_requested_count": _last_cohort_requested_count,
		"last_cohort_scheduled_count": _last_cohort_scheduled_count,
		"last_cohort_survivor_count": _last_cohort_survivor_count,
		"last_cohort_death_count": _last_cohort_death_count,
		"total_cohort_scheduled": _total_cohort_scheduled,
		"total_cohort_survivors": _total_cohort_survivors,
		"cohort_route_mode": "DELTA_REVERSE_CUBIC_BEZIER_RAIL",
		"cohort_route_command_encoding": (
			"ROW0_G_CAPTURED_BASE_SPEED_A_ONE_PLUS_GROUP_OFFSET_"
			+ "ROW1_XY_ANCHOR_B_MERGE_X_A_SURVIVES"
		),
		"cohort_route_count": DELTA_ROUTE_ANCHORS.size(),
		"cohort_routes": _delta_route_runtime_summaries(),
		"cohort_route_turn_pixels": delta_route_turn_pixels,
		"cohort_route_trunk_center_y_pixels": delta_route_trunk_center_y_pixels,
		"cohort_route_approach_pixels": delta_route_approach_pixels,
		"cohort_route_lookahead_pixels": delta_route_lookahead_pixels,
		"cohort_route_spawn_stagger_seconds": delta_route_spawn_stagger_seconds,
		"cohort_route_group_offset_max_seconds": (
			delta_route_group_offset_max_seconds
		),
		"cohort_route_spawn_mode": "IMMEDIATE_RIGHT_TRUNK_NO_WATER_DEPENDENCY",
		"cohort_route_motion_mode": "TIME_BOUNDED_TRUNK_THEN_EXACT_CUBIC",
		"cohort_route_arrival_mode": "EXACT_EDGE_ANCHOR_THEN_RETIRE",
		"cohort_survival_authority": "CPU_COMMAND_TEXTURE",
		"cohort_death_mode": "DETERMINISTIC_IN_DELTA_FADE",
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
	_control_image = Image.create(
		CAPACITY,
		CONTROL_TEXTURE_ROWS,
		false,
		Image.FORMAT_RGBAF,
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
	_head_material.set_shader_parameter(
		&"delta_route_turn_pixels",
		delta_route_turn_pixels,
	)
	_head_material.set_shader_parameter(
		&"delta_route_trunk_center_y_pixels",
		delta_route_trunk_center_y_pixels,
	)
	_head_material.set_shader_parameter(
		&"delta_route_approach_pixels",
		delta_route_approach_pixels,
	)
	_head_material.set_shader_parameter(
		&"delta_route_lookahead_pixels",
		delta_route_lookahead_pixels,
	)
	_head_material.set_shader_parameter(
		&"delta_route_spawn_stagger_seconds",
		delta_route_spawn_stagger_seconds,
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
