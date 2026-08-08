class_name FlowPolygonObstacle
extends Resource

## Runtime-editable equivalent of Python's PolygonObstacle dataclass.

const _FIELD_NAMES := [
	"element_id",
	"vertices",
	"strength",
	"bend",
	"influence",
]

@export var element_id: StringName = &"polygon_obstacle"
@export var vertices: PackedVector2Array = PackedVector2Array()
@export var strength: float = 5.142857142857143
@export var bend: float = 1.2857142857142858
@export var influence: float = 0.8357142857142859


func apply_dictionary(values: Dictionary) -> bool:
	## Validate a complete patch before mutating this resource.
	var next_element_id := element_id
	var next_vertices := vertices.duplicate()
	var next_strength := strength
	var next_bend := bend
	var next_influence := influence

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
			"strength":
				if not _is_finite_number(value):
					return false
				next_strength = float(value)
			"bend":
				if not _is_finite_number(value):
					return false
				next_bend = float(value)
			"influence":
				if not _is_finite_number(value):
					return false
				next_influence = float(value)

	if next_element_id == &"":
		return false
	if not _is_valid_polygon(next_vertices):
		return false
	if next_strength < 0.0 or next_influence <= 0.0:
		return false

	element_id = next_element_id
	vertices = next_vertices
	strength = next_strength
	bend = next_bend
	influence = next_influence
	emit_changed()
	return true


func to_dictionary() -> Dictionary:
	return {
		"element_id": String(element_id),
		"vertices": _vertices_to_array(vertices),
		"strength": strength,
		"bend": bend,
		"influence": influence,
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
		twice_area += current.x * following.y - following.x * current.y
	return absf(twice_area) > 0.000001


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
