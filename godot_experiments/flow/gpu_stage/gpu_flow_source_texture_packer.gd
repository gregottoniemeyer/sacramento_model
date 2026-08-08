class_name GPUFlowSourceTexturePacker
extends RefCounted

## Packs up to eight GPUFlowSourcePolygon resources into one 128 x 1 RGBAF
## texture. Every source owns exactly sixteen texels: four metadata texels and
## twelve vertex/edge texels. Disabled and zero-emission sources remain packed so
## their stable ID-to-record mapping does not change when policy toggles.

const MAX_SOURCES := 8
const MAX_VERTICES := GPUFlowSourcePolygon.MAX_VERTICES
const TEXELS_PER_SOURCE := 16
const TEXTURE_WIDTH := MAX_SOURCES * TEXELS_PER_SOURCE
const SAMPLE_ENDPOINT_EPSILON := 1.0e-7
const WEIGHT_EPSILON := 1.0e-6

const DEFAULT_STAGE_SIZE := Vector2(1920.0, 1080.0)
const DEFAULT_WORLD_SIZE := Vector2(16.0, 9.0)

var stage_size: Vector2 = DEFAULT_STAGE_SIZE
var world_size: Vector2 = DEFAULT_WORLD_SIZE

var _image: Image
var _texture: ImageTexture
var _records: Array[Dictionary] = []
var _record_index_by_id: Dictionary = {}
var _warnings := PackedStringArray()
var _ignored_capacity_count: int = 0
var _revision: int = 0


func _init(
	configured_stage_size: Vector2 = DEFAULT_STAGE_SIZE,
	configured_world_size: Vector2 = DEFAULT_WORLD_SIZE,
) -> void:
	if _coordinate_space_is_valid(configured_stage_size, configured_world_size):
		stage_size = configured_stage_size
		world_size = configured_world_size
	_rebuild_empty_texture()


func set_coordinate_space(
	configured_stage_size: Vector2,
	configured_world_size: Vector2,
) -> bool:
	if not _coordinate_space_is_valid(configured_stage_size, configured_world_size):
		return false
	stage_size = configured_stage_size
	world_size = configured_world_size
	return true


func pack_sources(source_values: Array) -> int:
	## Invalid resources and later duplicate IDs are skipped. The first eight valid,
	## unique records retain input order, including disabled records.
	_records.clear()
	_record_index_by_id.clear()
	_warnings.clear()
	_ignored_capacity_count = 0
	var seen_ids: Dictionary = {}
	for source_index in range(source_values.size()):
		var value: Variant = source_values[source_index]
		if not value is GPUFlowSourcePolygon:
			_warnings.append("Source %d is not a GPUFlowSourcePolygon." % source_index)
			continue
		var source: GPUFlowSourcePolygon = value
		var source_error := source.validate()
		if not source_error.is_empty():
			_warnings.append(
				"Source %d (%s) is invalid: %s"
				% [source_index, source.element_id, source_error]
			)
			continue
		var id_string := String(source.element_id)
		if seen_ids.has(id_string):
			_warnings.append("Duplicate source ID skipped: %s" % id_string)
			continue
		seen_ids[id_string] = true
		if _records.size() >= MAX_SOURCES:
			_ignored_capacity_count += 1
			continue
		var definition := _build_record_definition(source, _records.size())
		if definition.is_empty():
			_warnings.append("Source %s has no downstream-facing edge." % id_string)
			continue
		_record_index_by_id[id_string] = _records.size()
		_records.append(definition)

	if _ignored_capacity_count > 0:
		_warnings.append(
			"%d valid unique source(s) exceeded the %d-record GPU capacity."
			% [_ignored_capacity_count, MAX_SOURCES]
		)
	_pack_image()
	_revision += 1
	return _records.size()


func get_texture() -> ImageTexture:
	return _texture


func get_image() -> Image:
	## Configuration-time inspection only; shaders never require CPU readback.
	return _image


func get_record_count() -> int:
	return _records.size()


func get_record_index(element_id: StringName) -> int:
	return int(_record_index_by_id.get(String(element_id), -1))


func get_record_definitions() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for record: Dictionary in _records:
		result.append(record.duplicate(true))
	return result


func get_warnings() -> PackedStringArray:
	return _warnings.duplicate()


func sample_packed_emission_point(
	record_index: int,
	sample01: float,
	downstream_epsilon_pixels: float = 0.0,
	horizontal_sample01: float = 0.5,
) -> Vector2:
	## Exact CPU reference for the shader loop. Y follows the selected projected
	## downstream edge while X uses an independent sample across packed bounds.
	## It deliberately samples the packed Image rather than the source Resource.
	if (
		_image == null
		or record_index < 0
		or record_index >= _records.size()
		or not is_finite(sample01)
		or not is_finite(horizontal_sample01)
		or not is_finite(downstream_epsilon_pixels)
		or downstream_epsilon_pixels < 0.0
	):
		return Vector2.INF
	var metadata0 := _record_pixel(record_index, 0)
	var metadata1 := _record_pixel(record_index, 1)
	var metadata2 := _record_pixel(record_index, 2)
	var metadata3 := _record_pixel(record_index, 3)
	var vertex_count := clampi(int(round(metadata0.r)), 0, MAX_VERTICES)
	var total_weight := metadata1.a
	if vertex_count < 3 or total_weight <= WEIGHT_EPSILON:
		return Vector2.INF
	var unit_sample := clampf(sample01, 0.0, 1.0)
	if unit_sample >= 1.0:
		unit_sample = 1.0 - SAMPLE_ENDPOINT_EPSILON
	if metadata3.a >= 0.5:
		unit_sample = fposmod(unit_sample + metadata0.a, 1.0)
	var horizontal_unit_sample := clampf(horizontal_sample01, 0.0, 1.0)
	if horizontal_unit_sample >= 1.0:
		horizontal_unit_sample = 1.0 - SAMPLE_ENDPOINT_EPSILON
	if metadata3.a >= 0.5:
		horizontal_unit_sample = fposmod(
			horizontal_unit_sample + metadata0.a,
			1.0,
		)
	var minimum_x := minf(metadata2.r, metadata2.b)
	var maximum_x := maxf(metadata2.r, metadata2.b)
	var target_weight := unit_sample * total_weight
	var orientation := 1.0 if metadata1.b >= 0.0 else -1.0
	for vertex_index in range(vertex_count):
		var vertex_record := _record_pixel(record_index, 4 + vertex_index)
		var edge_weight := vertex_record.b
		var cumulative_weight := vertex_record.a
		if edge_weight <= WEIGHT_EPSILON or target_weight >= cumulative_weight:
			continue
		var previous_weight := cumulative_weight - edge_weight
		var local_sample := clampf(
			(target_weight - previous_weight) / edge_weight,
			0.0,
			1.0,
		)
		var next_index := (vertex_index + 1) % vertex_count
		var next_record := _record_pixel(record_index, 4 + next_index)
		var edge_start := Vector2(vertex_record.r, vertex_record.g)
		var edge_end := Vector2(next_record.r, next_record.g)
		var edge := edge_end - edge_start
		var right_normal := Vector2(edge.y, -edge.x).normalized()
		var outward_normal := right_normal if orientation >= 0.0 else -right_normal
		var spawn_point := (
			edge_start.lerp(edge_end, local_sample)
			+ outward_normal * downstream_epsilon_pixels
		)
		spawn_point.x = lerpf(minimum_x, maximum_x, horizontal_unit_sample)
		return spawn_point
	return Vector2.INF


func runtime_summary() -> Dictionary:
	var ids: Array[String] = []
	var total_enabled_fraction := 0.0
	for record: Dictionary in _records:
		ids.append(String(record["element_id"]))
		if bool(record["enabled"]):
			total_enabled_fraction += float(record["emission_fraction"])
	return {
		"backend": "gpu_source_rgba32f_texture",
		"max_sources": MAX_SOURCES,
		"max_vertices": MAX_VERTICES,
		"texels_per_source": TEXELS_PER_SOURCE,
		"texture_size": Vector2i(TEXTURE_WIDTH, 1),
		"record_count": _records.size(),
		"record_ids": ids,
		"total_enabled_emission_fraction": total_enabled_fraction,
		"ignored_capacity_count": _ignored_capacity_count,
		"warnings": Array(_warnings),
		"stage_size": stage_size,
		"world_size": world_size,
		"revision": _revision,
		"texture_ready": _texture != null,
		"shader_readback_required": false,
	}


static func texture_layout() -> Array[String]:
	return [
		"0: vertex_count, emission_fraction, enabled, seed_phase",
		"1: flow_direction_native.x, flow_direction_native.y, orientation, total_edge_weight",
		"2: bounds_min.x, bounds_min.y, bounds_max.x, bounds_max.y",
		"3: centroid.x, centroid.y, stable_id_hash, explicit_seed_flag",
		"4..15: vertex.x, vertex.y, outgoing_edge_weight, cumulative_edge_weight",
	]


func _build_record_definition(
	source: GPUFlowSourcePolygon,
	record_index: int,
) -> Dictionary:
	var native_vertices := _world_vertices_to_native(source.vertices)
	var native_direction := _world_direction_to_native(source.flow_direction)
	var orientation := 1.0 if _signed_area(native_vertices) >= 0.0 else -1.0
	var edge_records := _edge_records(native_vertices, native_direction, orientation)
	var total_weight := 0.0
	var downstream_edge_count := 0
	for edge_record: Dictionary in edge_records:
		total_weight = float(edge_record["cumulative_weight"])
		if float(edge_record["weight"]) > WEIGHT_EPSILON:
			downstream_edge_count += 1
	if total_weight <= WEIGHT_EPSILON or downstream_edge_count == 0:
		return {}
	var id_hash := _stable_id_hash(source.element_id)
	return {
		"record_index": record_index,
		"element_id": String(source.element_id),
		"vertices_pixels": native_vertices,
		"flow_direction_pixels": native_direction,
		"orientation": orientation,
		"bounds_pixels": _bounds(native_vertices),
		"centroid_pixels": _centroid(native_vertices),
		"edge_records": edge_records,
		"downstream_edge_count": downstream_edge_count,
		"total_downstream_weight": total_weight,
		"emission_fraction": source.emission_fraction,
		"enabled": source.enabled,
		"seed": source.seed,
		"seed_phase": GPUFlowSourcePolygon.seed_phase(source.seed),
		"explicit_seed": source.seed != GPUFlowSourcePolygon.NO_SEED,
		"stable_id_hash": id_hash,
	}


func _pack_image() -> void:
	_image = Image.create(TEXTURE_WIDTH, 1, false, Image.FORMAT_RGBAF)
	_image.fill(Color(0.0, 0.0, 0.0, 0.0))
	for record: Dictionary in _records:
		var record_index := int(record["record_index"])
		var record_start := record_index * TEXELS_PER_SOURCE
		var native_vertices: PackedVector2Array = record["vertices_pixels"]
		var native_direction: Vector2 = record["flow_direction_pixels"]
		var bounds: Rect2 = record["bounds_pixels"]
		var centroid: Vector2 = record["centroid_pixels"]
		_image.set_pixel(record_start, 0, Color(
			float(native_vertices.size()),
			float(record["emission_fraction"]),
			1.0 if bool(record["enabled"]) else 0.0,
			float(record["seed_phase"]),
		))
		_image.set_pixel(record_start + 1, 0, Color(
			native_direction.x,
			native_direction.y,
			float(record["orientation"]),
			float(record["total_downstream_weight"]),
		))
		_image.set_pixel(record_start + 2, 0, Color(
			bounds.position.x,
			bounds.position.y,
			bounds.end.x,
			bounds.end.y,
		))
		_image.set_pixel(record_start + 3, 0, Color(
			centroid.x,
			centroid.y,
			float(record["stable_id_hash"]),
			1.0 if bool(record["explicit_seed"]) else 0.0,
		))
		var edge_records: Array[Dictionary] = record["edge_records"]
		for vertex_index in range(native_vertices.size()):
			var vertex := native_vertices[vertex_index]
			var edge_record: Dictionary = edge_records[vertex_index]
			_image.set_pixel(record_start + 4 + vertex_index, 0, Color(
				vertex.x,
				vertex.y,
				float(edge_record["weight"]),
				float(edge_record["cumulative_weight"]),
			))
	if _texture == null:
		_texture = ImageTexture.create_from_image(_image)
	else:
		_texture.update(_image)


func _rebuild_empty_texture() -> void:
	_image = Image.create(TEXTURE_WIDTH, 1, false, Image.FORMAT_RGBAF)
	_image.fill(Color(0.0, 0.0, 0.0, 0.0))
	_texture = ImageTexture.create_from_image(_image)


func _record_pixel(record_index: int, offset: int) -> Color:
	return _image.get_pixel(record_index * TEXELS_PER_SOURCE + offset, 0)


func _world_vertices_to_native(points: PackedVector2Array) -> PackedVector2Array:
	var scale := Vector2(stage_size.x / world_size.x, stage_size.y / world_size.y)
	var result := PackedVector2Array()
	for point: Vector2 in points:
		result.append(Vector2(point.x * scale.x, (world_size.y - point.y) * scale.y))
	return result


func _world_direction_to_native(direction: Vector2) -> Vector2:
	var scale := Vector2(stage_size.x / world_size.x, stage_size.y / world_size.y)
	return Vector2(direction.x * scale.x, -direction.y * scale.y).normalized()


static func _edge_records(
	vertices: PackedVector2Array,
	direction: Vector2,
	orientation: float,
) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var cumulative_weight := 0.0
	for vertex_index in range(vertices.size()):
		var start := vertices[vertex_index]
		var end := vertices[(vertex_index + 1) % vertices.size()]
		var edge := end - start
		var edge_length := edge.length()
		var right_normal := Vector2(edge.y, -edge.x) / edge_length
		var outward_normal := right_normal if orientation >= 0.0 else -right_normal
		var alignment := maxf(outward_normal.dot(direction), 0.0)
		var weight := edge_length * alignment
		if weight <= WEIGHT_EPSILON:
			weight = 0.0
		cumulative_weight += weight
		result.append({
			"edge_index": vertex_index,
			"outward_normal": outward_normal,
			"alignment": alignment,
			"weight": weight,
			"cumulative_weight": cumulative_weight,
		})
	return result


static func _bounds(vertices: PackedVector2Array) -> Rect2:
	var minimum := vertices[0]
	var maximum := vertices[0]
	for vertex: Vector2 in vertices:
		minimum = minimum.min(vertex)
		maximum = maximum.max(vertex)
	return Rect2(minimum, maximum - minimum)


static func _centroid(vertices: PackedVector2Array) -> Vector2:
	var result := Vector2.ZERO
	for vertex: Vector2 in vertices:
		result += vertex
	return result / float(vertices.size())


static func _signed_area(vertices: PackedVector2Array) -> float:
	var twice_area := 0.0
	for vertex_index in range(vertices.size()):
		var current := vertices[vertex_index]
		var following := vertices[(vertex_index + 1) % vertices.size()]
		twice_area += current.x * following.y - following.x * current.y
	return twice_area * 0.5


static func _stable_id_hash(element_id: StringName) -> float:
	var accumulator: int = 2166136261
	var text_id := String(element_id)
	for character_index in range(text_id.length()):
		accumulator = (
			((accumulator ^ text_id.unicode_at(character_index)) * 16777619)
			& 0x7fffffff
		)
	return float(accumulator % 1000003) / 1000003.0


static func _coordinate_space_is_valid(
	candidate_stage_size: Vector2,
	candidate_world_size: Vector2,
) -> bool:
	return (
		is_finite(candidate_stage_size.x)
		and is_finite(candidate_stage_size.y)
		and is_finite(candidate_world_size.x)
		and is_finite(candidate_world_size.y)
		and candidate_stage_size.x > 0.0
		and candidate_stage_size.y > 0.0
		and candidate_world_size.x > 0.0
		and candidate_world_size.y > 0.0
	)
