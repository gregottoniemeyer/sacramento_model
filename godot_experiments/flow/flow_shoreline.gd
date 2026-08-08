class_name FlowShoreline
extends Resource

## Solid land polygon plus its explicit water-facing edge chain.
## Coordinates remain in the Python model's 16 x 9, Y-up world.

const _FIELD_NAMES := [
	"element_id",
	"vertices",
	"water_edge_indices",
	"side",
	"strength",
	"influence",
	"power",
	"force_offset",
]

@export var element_id: StringName = &"shoreline"
@export var vertices: PackedVector2Array = PackedVector2Array()
@export var water_edge_indices: PackedInt32Array = PackedInt32Array()
@export_enum("bottom", "top") var side: String = "bottom"
@export var strength: float = 5.142857142857143
@export var influence: float = 1.092857142857143
@export var power: float = 2.0
@export var force_offset: float = 0.6428571428571429


func apply_dictionary(values: Dictionary) -> bool:
	## Validate a complete patch before mutating this resource.
	var next_element_id := element_id
	var next_vertices := vertices.duplicate()
	var next_water_edge_indices := water_edge_indices.duplicate()
	var next_side := side
	var next_strength := strength
	var next_influence := influence
	var next_power := power
	var next_force_offset := force_offset

	for raw_key in values:
		var key := String(raw_key)
		if not _FIELD_NAMES.has(key):
			return false
		var value: Variant = values[raw_key]
		match key:
			"element_id":
				if not _is_string(value):
					return false
				next_element_id = StringName(String(value))
			"vertices":
				var parsed_vertices: Variant = _parse_vertices(value)
				if parsed_vertices == null:
					return false
				next_vertices = parsed_vertices
			"water_edge_indices":
				var parsed_indices: Variant = _parse_indices(value)
				if parsed_indices == null:
					return false
				next_water_edge_indices = parsed_indices
			"side":
				if not _is_string(value):
					return false
				next_side = String(value).to_lower()
			"strength":
				if not _is_finite_number(value):
					return false
				next_strength = float(value)
			"influence":
				if not _is_finite_number(value):
					return false
				next_influence = float(value)
			"power":
				if not _is_finite_number(value):
					return false
				next_power = float(value)
			"force_offset":
				if not _is_finite_number(value):
					return false
				next_force_offset = float(value)

	if next_element_id == &"":
		return false
	if next_side != "bottom" and next_side != "top":
		return false
	if not _is_valid_polygon(next_vertices):
		return false
	if not _is_valid_edge_chain(next_vertices, next_water_edge_indices):
		return false
	if next_strength < 0.0 or next_influence <= 0.0:
		return false
	if next_power <= 0.0 or next_force_offset < 0.0:
		return false

	element_id = next_element_id
	vertices = next_vertices
	water_edge_indices = next_water_edge_indices
	side = next_side
	strength = next_strength
	influence = next_influence
	power = next_power
	force_offset = next_force_offset
	emit_changed()
	return true


func to_dictionary() -> Dictionary:
	var indices: Array = []
	for index in water_edge_indices:
		indices.append(index)
	return {
		"element_id": String(element_id),
		"vertices": _vertices_to_array(vertices),
		"water_edge_indices": indices,
		"side": side,
		"strength": strength,
		"influence": influence,
		"power": power,
		"force_offset": force_offset,
	}


static func _is_valid_polygon(points: PackedVector2Array) -> bool:
	if points.size() < 3:
		return false
	var twice_area := 0.0
	for index in range(points.size()):
		var current := points[index]
		var following := points[(index + 1) % points.size()]
		if not is_finite(current.x) or not is_finite(current.y):
			return false
		if current.distance_squared_to(following) <= 0.000000000001:
			return false
		twice_area += current.x * following.y - following.x * current.y
	return absf(twice_area) > 0.000001


static func _is_valid_edge_chain(
	points: PackedVector2Array,
	indices: PackedInt32Array
) -> bool:
	if indices.size() < 2:
		return false
	for chain_index in range(indices.size()):
		var vertex_index := indices[chain_index]
		if vertex_index < 0 or vertex_index >= points.size():
			return false
		if chain_index > 0:
			var previous := indices[chain_index - 1]
			if vertex_index != (previous + 1) % points.size():
				return false
	return true


static func _parse_vertices(value: Variant) -> Variant:
	if value is PackedVector2Array:
		var packed_value: PackedVector2Array = value
		return packed_value.duplicate()
	if not value is Array:
		return null
	var parsed := PackedVector2Array()
	for item in value:
		var point: Variant = _parse_point(item)
		if point == null:
			return null
		parsed.append(point)
	return parsed


static func _parse_point(value: Variant) -> Variant:
	if value is Vector2:
		var point: Vector2 = value
		return point if is_finite(point.x) and is_finite(point.y) else null
	if value is Array and value.size() == 2:
		if _is_finite_number(value[0]) and _is_finite_number(value[1]):
			return Vector2(float(value[0]), float(value[1]))
	if value is Dictionary and value.has("x") and value.has("y"):
		if _is_finite_number(value["x"]) and _is_finite_number(value["y"]):
			return Vector2(float(value["x"]), float(value["y"]))
	return null


static func _parse_indices(value: Variant) -> Variant:
	if value is PackedInt32Array:
		var packed_value: PackedInt32Array = value
		return packed_value.duplicate()
	if not value is Array and not value is PackedInt64Array:
		return null
	var parsed := PackedInt32Array()
	for item in value:
		if not _is_finite_number(item):
			return null
		var numeric := float(item)
		if not is_equal_approx(numeric, roundf(numeric)):
			return null
		parsed.append(int(numeric))
	return parsed


static func _vertices_to_array(points: PackedVector2Array) -> Array:
	var result: Array = []
	for point in points:
		result.append([point.x, point.y])
	return result


static func _is_string(value: Variant) -> bool:
	return typeof(value) == TYPE_STRING or typeof(value) == TYPE_STRING_NAME


static func _is_finite_number(value: Variant) -> bool:
	return (
		typeof(value) == TYPE_INT or typeof(value) == TYPE_FLOAT
	) and is_finite(float(value))
