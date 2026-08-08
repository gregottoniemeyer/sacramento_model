extends Node2D
class_name CPUSalmonSchool2D

## Fixed-pool CPU salmon simulation driven by read-only water-head snapshots.
##
## Water snapshots identify a head with `slot_id`, `slot_index`, or the legacy
## `id` field and contain `position: Vector2` plus `velocity: Vector2`. Missing
## `active` means the returned snapshot is inherently active; explicit false is
## always rejected. The school never mutates snapshots.

signal salmon_released(requested_count: int, released_count: int, release_serial: int)

const STREAK_RENDERER_SCRIPT := preload(
	"res://flow/multimesh_stage/dynamic_salmon_streak_renderer.gd"
)

const CAPACITY := 300
const DEFAULT_RELEASE_COUNT := 25
const MIN_VELOCITY_SQUARED := 0.000001

const SALMON_COLORS: Array[Color] = [
	Color("ff5c8a"),
	Color("ff7a72"),
	Color("ff8c42"),
	Color("ffad33"),
	Color("ffd23f"),
]


class WaterSample:
	extends RefCounted
	var slot_key: String = ""
	var position: Vector2 = Vector2.ZERO
	var velocity: Vector2 = Vector2.ZERO

	func _init(
		new_slot_key: String,
		new_position: Vector2,
		new_velocity: Vector2
	) -> void:
		slot_key = new_slot_key
		position = new_position
		velocity = new_velocity


@export_group("Geometry")
@export var stage_size := Vector2(1920.0, 1080.0)
## Axis-aligned point-contact test. Water heads must remain inside this narrow,
## flow-aligned rectangle for a salmon to keep swimming.
@export_range(1.0, 600.0, 1.0) var water_contact_width_pixels: float = 240.0
@export_range(1.0, 240.0, 1.0) var water_contact_height_pixels: float = 24.0
@export_range(1.0, 300.0, 1.0) var right_edge_band_pixels: float = 120.0

@export_group("Streak")
@export_range(8.0, 160.0, 1.0) var streak_length_pixels: float = 50.0
@export_range(1.0, 5.0, 0.1) var streak_width_pixels: float = 2.0
@export_range(0.05, 4.0, 0.05) var fade_seconds: float = 0.50
@export_range(-4096, 4096, 1) var streak_z_index: int = 20:
	set(value):
		streak_z_index = clampi(value, -4096, 4096)
		_apply_renderer_z_index()

@export_group("Lifecycle")
@export var start_paused: bool = false
## A negative seed randomizes once at startup; a nonnegative seed makes color
## assignment repeatable without changing spatial candidate selection.
@export var random_seed: int = 7301

var _positions := PackedVector2Array()
var _velocities := PackedVector2Array()
var _directions := PackedVector2Array()
var _active := PackedByteArray()
var _fading := PackedByteArray()
var _fade_elapsed := PackedFloat32Array()
var _birth_order := PackedInt32Array()
var _color_indices := PackedInt32Array()
var _renderer: STREAK_RENDERER_SCRIPT
var _rng := RandomNumberGenerator.new()
var _paused: bool = false
var _next_birth_order: int = 1
var _release_serial: int = 0
var _total_released: int = 0
var _total_recycled: int = 0
var _simulation_time_seconds: float = 0.0


func _ready() -> void:
	_initialize_pool()
	_seed_rng()
	_renderer = STREAK_RENDERER_SCRIPT.new() as STREAK_RENDERER_SCRIPT
	_renderer.name = "DynamicSalmonStreakRenderer"
	_renderer.z_index_absolute = streak_z_index
	add_child(_renderer)
	_paused = start_paused
	reset()


func release_salmon(
	water_heads: Array[Dictionary],
	count: int = DEFAULT_RELEASE_COUNT
) -> int:
	## Spawn at x=stage width using distinct edge-water slots whenever possible.
	var requested_count := clampi(count, 0, CAPACITY)
	if requested_count <= 0 or _renderer == null:
		return 0
	var candidates := _collect_water_samples(water_heads, true)
	if candidates.is_empty():
		return 0
	var spawn_samples := _spread_spawn_samples(candidates, requested_count)
	var release_slots := _select_release_slots(requested_count)
	var released_count := mini(spawn_samples.size(), release_slots.size())
	if released_count <= 0:
		return 0
	var occurrence_totals: Dictionary = {}
	for sample: WaterSample in spawn_samples:
		occurrence_totals[sample.slot_key] = (
			int(occurrence_totals.get(sample.slot_key, 0)) + 1
		)
	var occurrence_indices: Dictionary = {}

	_release_serial += 1
	for release_index in range(released_count):
		var slot: int = release_slots[release_index]
		var sample: WaterSample = spawn_samples[release_index]
		var group_count := int(occurrence_totals.get(sample.slot_key, 1))
		var group_index := int(occurrence_indices.get(sample.slot_key, 0))
		occurrence_indices[sample.slot_key] = group_index + 1
		var y_offset := 0.0
		if group_count > 1:
			y_offset = lerpf(
				-water_contact_height_pixels * 0.45,
				water_contact_height_pixels * 0.45,
				float(group_index) / float(group_count - 1)
			)
		var recycled := _active[slot] != 0
		if recycled:
			_total_recycled += 1
		_positions[slot] = Vector2(
			stage_size.x,
			clampf(sample.position.y + y_offset, 0.0, stage_size.y)
		)
		_velocities[slot] = -sample.velocity
		_directions[slot] = _travel_direction_or_left(_velocities[slot])
		_active[slot] = 1
		_fading[slot] = 0
		_fade_elapsed[slot] = 0.0
		_birth_order[slot] = _next_birth_order
		_next_birth_order += 1
		_color_indices[slot] = _rng.randi_range(0, SALMON_COLORS.size() - 1)
		_draw_slot(slot, 1.0)

	_total_released += released_count
	salmon_released.emit(requested_count, released_count, _release_serial)
	return released_count


func update_salmon(delta_seconds: float, water_heads: Array[Dictionary]) -> void:
	## Advance active fish once. Fading is latched: a fish that misses water can
	## never reacquire it during this lifecycle.
	if _paused or delta_seconds <= 0.0 or _renderer == null:
		return
	_simulation_time_seconds += delta_seconds
	var water_samples := _collect_water_samples(water_heads, false)
	for slot in range(CAPACITY):
		if _active[slot] == 0:
			continue
		if _fading[slot] != 0:
			_advance_fade(slot, delta_seconds)
			continue

		var nearest := _nearest_water_sample(_positions[slot], water_samples)
		if nearest == null:
			_latch_fade(slot)
			_draw_slot(slot, 1.0)
			continue

		_velocities[slot] = -nearest.velocity
		if _velocities[slot].length_squared() > MIN_VELOCITY_SQUARED:
			_directions[slot] = _velocities[slot].normalized()
		_positions[slot] += _velocities[slot] * delta_seconds
		_draw_slot(slot, 1.0)


func set_paused(value: bool) -> void:
	_paused = value


func is_paused() -> bool:
	return _paused


func reset() -> void:
	if _active.size() != CAPACITY:
		_initialize_pool()
	_positions.fill(Vector2.ZERO)
	_velocities.fill(Vector2.ZERO)
	_directions.fill(Vector2.LEFT)
	_active.fill(0)
	_fading.fill(0)
	_fade_elapsed.fill(0.0)
	_birth_order.fill(0)
	_color_indices.fill(0)
	_next_birth_order = 1
	_release_serial = 0
	_total_released = 0
	_total_recycled = 0
	_simulation_time_seconds = 0.0
	_seed_rng()
	if _renderer != null:
		_renderer.reset()


func runtime_summary() -> Dictionary:
	var active_count: int = 0
	var fading_count: int = 0
	for slot in range(CAPACITY):
		if _active[slot] != 0:
			active_count += 1
			if _fading[slot] != 0:
				fading_count += 1
	var palette_hex: Array[String] = []
	for color: Color in SALMON_COLORS:
		palette_hex.append("#%s" % color.to_html(false).to_upper())
	return {
		"backend": "cpu_salmon_dynamic_multimesh",
		"capacity": CAPACITY,
		"active_count": active_count,
		"swimming_count": active_count - fading_count,
		"fading_count": fading_count,
		"release_serial": _release_serial,
		"total_released": _total_released,
		"total_recycled": _total_recycled,
		"simulation_time_seconds": _simulation_time_seconds,
		"paused": _paused,
		"stage_size": stage_size,
		"water_contact_width_pixels": water_contact_width_pixels,
		"water_contact_height_pixels": water_contact_height_pixels,
		"right_edge_band_pixels": right_edge_band_pixels,
		"streak_length_pixels": streak_length_pixels,
		"streak_width_pixels": streak_width_pixels,
		"fade_seconds": fade_seconds,
		"palette": palette_hex,
		"renderer": (
			_renderer.runtime_summary() if _renderer != null else {}
		),
	}


func active_snapshots() -> Array[Dictionary]:
	## Compact read-only inspection data for tests and a future stage summary.
	var result: Array[Dictionary] = []
	for slot in range(CAPACITY):
		if _active[slot] == 0:
			continue
		result.append({
			"slot_index": slot,
			"position": _positions[slot],
			"velocity": _velocities[slot],
			"direction": _directions[slot],
			"fading": _fading[slot] != 0,
			"fade_elapsed": _fade_elapsed[slot],
			"birth_order": _birth_order[slot],
			"color": SALMON_COLORS[_color_indices[slot]],
		})
	return result


func _initialize_pool() -> void:
	_positions.resize(CAPACITY)
	_velocities.resize(CAPACITY)
	_directions.resize(CAPACITY)
	_active.resize(CAPACITY)
	_fading.resize(CAPACITY)
	_fade_elapsed.resize(CAPACITY)
	_birth_order.resize(CAPACITY)
	_color_indices.resize(CAPACITY)


func _seed_rng() -> void:
	if random_seed < 0:
		_rng.randomize()
	else:
		_rng.seed = random_seed


func _collect_water_samples(
	water_heads: Array[Dictionary],
	right_edge_only: bool
) -> Array[WaterSample]:
	var result: Array[WaterSample] = []
	var seen_slots: Dictionary = {}
	var edge_band := maxf(right_edge_band_pixels, 0.0)
	for head: Dictionary in water_heads:
		var active_value: Variant = head.get("active", true)
		if not bool(active_value):
			continue
		var position_value: Variant = head.get("position", null)
		var velocity_value: Variant = head.get("velocity", null)
		if not position_value is Vector2 or not velocity_value is Vector2:
			continue
		var position: Vector2 = position_value
		var velocity: Vector2 = velocity_value
		if (
			not is_finite(position.x)
			or not is_finite(position.y)
			or not is_finite(velocity.x)
			or not is_finite(velocity.y)
		):
			continue
		var slot_value: Variant = null
		var slot_prefix := ""
		if head.has("slot_id"):
			slot_value = head["slot_id"]
			slot_prefix = "id:"
		elif head.has("slot_index"):
			slot_value = head["slot_index"]
			slot_prefix = "index:"
		elif head.has("id"):
			slot_value = head["id"]
			slot_prefix = "id:"
		else:
			continue
		var slot_key := slot_prefix + str(slot_value)
		if seen_slots.has(slot_key):
			continue
		if position.y < 0.0 or position.y > stage_size.y:
			continue
		if right_edge_only and absf(position.x - stage_size.x) > edge_band:
			continue
		seen_slots[slot_key] = true
		result.append(WaterSample.new(slot_key, position, velocity))
	return result


func _spread_spawn_samples(
	candidates: Array[WaterSample],
	requested_count: int
) -> Array[WaterSample]:
	var sorted_candidates := candidates.duplicate()
	sorted_candidates.sort_custom(Callable(self, "_water_sample_y_less"))
	var result: Array[WaterSample] = []
	var candidate_count := sorted_candidates.size()
	if candidate_count == 0 or requested_count <= 0:
		return result
	if requested_count == 1:
		result.append(sorted_candidates[candidate_count / 2])
		return result
	if candidate_count >= requested_count:
		for output_index in range(requested_count):
			var source_index := roundi(
				float(output_index)
				* float(candidate_count - 1)
				/ float(requested_count - 1)
			)
			result.append(sorted_candidates[source_index])
		return result

	# Every distinct stream appears once before duplicates are introduced.
	for sample: WaterSample in sorted_candidates:
		result.append(sample)
	var duplicate_index: int = 0
	while result.size() < requested_count:
		result.append(sorted_candidates[duplicate_index % candidate_count])
		duplicate_index += 1
	return result


func _water_sample_y_less(first: WaterSample, second: WaterSample) -> bool:
	if not is_equal_approx(first.position.y, second.position.y):
		return first.position.y < second.position.y
	return first.slot_key < second.slot_key


func _select_release_slots(requested_count: int) -> PackedInt32Array:
	var result := PackedInt32Array()
	for slot in range(CAPACITY):
		if _active[slot] == 0:
			result.append(slot)
			if result.size() >= requested_count:
				return result

	var selected_for_recycle := PackedByteArray()
	selected_for_recycle.resize(CAPACITY)
	selected_for_recycle.fill(0)
	while result.size() < requested_count:
		var oldest_slot: int = -1
		var oldest_birth: int = 0x7fffffff
		for slot in range(CAPACITY):
			if (
				_active[slot] == 0
				or selected_for_recycle[slot] != 0
				or _birth_order[slot] >= oldest_birth
			):
				continue
			oldest_birth = _birth_order[slot]
			oldest_slot = slot
		if oldest_slot < 0:
			break
		selected_for_recycle[oldest_slot] = 1
		result.append(oldest_slot)
	return result


func _nearest_water_sample(
	point: Vector2,
	samples: Array[WaterSample]
) -> WaterSample:
	var nearest: WaterSample = null
	var half_width := maxf(water_contact_width_pixels * 0.5, 0.0001)
	var half_height := maxf(water_contact_height_pixels * 0.5, 0.0001)
	var nearest_normalized_distance_squared := INF
	for sample: WaterSample in samples:
		var offset := sample.position - point
		if absf(offset.x) > half_width or absf(offset.y) > half_height:
			continue
		var normalized_distance_squared := (
			offset.x * offset.x / (half_width * half_width)
			+ offset.y * offset.y / (half_height * half_height)
		)
		if normalized_distance_squared <= nearest_normalized_distance_squared:
			nearest_normalized_distance_squared = normalized_distance_squared
			nearest = sample
	return nearest


func _latch_fade(slot: int) -> void:
	_fading[slot] = 1
	_fade_elapsed[slot] = 0.0
	_velocities[slot] = Vector2.ZERO


func _advance_fade(slot: int, delta_seconds: float) -> void:
	_fade_elapsed[slot] += delta_seconds
	var duration := maxf(fade_seconds, 0.0001)
	var progress := clampf(_fade_elapsed[slot] / duration, 0.0, 1.0)
	if progress >= 1.0:
		_deactivate_slot(slot)
		return
	_draw_slot(slot, 1.0 - progress)


func _deactivate_slot(slot: int) -> void:
	_active[slot] = 0
	_fading[slot] = 0
	_fade_elapsed[slot] = 0.0
	_velocities[slot] = Vector2.ZERO
	_renderer.hide_streak(slot)


func _draw_slot(slot: int, alpha: float) -> void:
	var color := SALMON_COLORS[_color_indices[slot]]
	_renderer.set_streak(
		slot,
		_positions[slot],
		_directions[slot],
		streak_length_pixels,
		streak_width_pixels,
		color,
		alpha
	)


func _travel_direction_or_left(velocity: Vector2) -> Vector2:
	if velocity.length_squared() <= MIN_VELOCITY_SQUARED:
		return Vector2.LEFT
	return velocity.normalized()


func _apply_renderer_z_index() -> void:
	if _renderer != null:
		_renderer.z_index_absolute = streak_z_index
