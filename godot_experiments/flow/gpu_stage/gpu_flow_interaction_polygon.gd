class_name GPUFlowInteractionPolygon
extends Resource

## One runtime-addressable polygon used by the GPU flow stage.
##
## Vertices use the controller's 16 x 9 world coordinates (Y points upward).
## The production stage converts them to native 1920 x 1080 pixels before the
## particle-process shader reads them. Both interaction modes intentionally use
## the same resource and controller schema.

enum Mode {
	ABSORB,
	REPEL,
}

const MAX_VERTICES := 12
const _FIELD_NAMES := [
	"element_id",
	"id",
	"vertices",
	"mode",
	"absorption_fraction",
	"repellent_force",
	"wave_strength",
	"influence",
	"enabled",
]

@export var element_id: StringName = &"interaction_polygon"
@export var vertices: PackedVector2Array = PackedVector2Array()
@export var mode: Mode = Mode.REPEL
@export_range(0.0, 1.0, 0.001) var absorption_fraction: float = 0.0
@export_range(0.0, 1.0, 0.001) var repellent_force: float = 0.65
@export_range(0.0, 1.0, 0.001) var wave_strength: float = 0.16
@export_range(0.0, 4.0, 0.01) var influence: float = 0.65
@export var enabled: bool = true


func apply_dictionary(values: Dictionary) -> bool:
	## Validate the complete patch before mutating this resource.
	var next_element_id := element_id
	var next_vertices := vertices.duplicate()
	var next_mode := mode
	var next_absorption_fraction := absorption_fraction
	var next_repellent_force := repellent_force
	var next_wave_strength := wave_strength
	var next_influence := influence
	var next_enabled := enabled

	for raw_key: Variant in values:
		var key := String(raw_key)
		if not _FIELD_NAMES.has(key):
			return false
		var value: Variant = values[raw_key]
		match key:
			"element_id", "id":
				if not _is_string(value):
					return false
				next_element_id = StringName(String(value))
			"vertices":
				var parsed_vertices: Variant = _parse_vertices(value)
				if parsed_vertices == null:
					return false
				next_vertices = parsed_vertices
			"mode":
				var parsed_mode := _parse_mode(value)
				if parsed_mode < 0:
					return false
				next_mode = parsed_mode
			"absorption_fraction":
				if not _is_finite_number(value):
					return false
				next_absorption_fraction = float(value)
			"repellent_force":
				if not _is_finite_number(value):
					return false
				next_repellent_force = float(value)
			"wave_strength":
				if not _is_finite_number(value):
					return false
				next_wave_strength = float(value)
			"influence":
				if not _is_finite_number(value):
					return false
				next_influence = float(value)
			"enabled":
				if typeof(value) != TYPE_BOOL:
					return false
				next_enabled = bool(value)

	if next_element_id == &"" or not is_valid_polygon(next_vertices):
		return false
	if (
		next_absorption_fraction < 0.0
		or next_absorption_fraction > 1.0
		or next_repellent_force < 0.0
		or next_repellent_force > 1.0
		or next_wave_strength < 0.0
		or next_wave_strength > 1.0
		or next_influence < 0.0
	):
		return false

	element_id = next_element_id
	vertices = next_vertices
	mode = next_mode
	absorption_fraction = next_absorption_fraction
	repellent_force = next_repellent_force
	wave_strength = next_wave_strength
	influence = next_influence
	enabled = next_enabled
	emit_changed()
	return true


func to_dictionary() -> Dictionary:
	return {
		"element_id": String(element_id),
		"vertices": vertices_to_array(vertices),
		"mode": mode_name(mode),
		"absorption_fraction": absorption_fraction,
		"repellent_force": repellent_force,
		"wave_strength": wave_strength,
		"influence": influence,
		"enabled": enabled,
	}


static func mode_name(value: Mode) -> String:
	return "absorb" if value == Mode.ABSORB else "repel"


static func is_valid_polygon(points: PackedVector2Array) -> bool:
	if points.size() < 3 or points.size() > MAX_VERTICES:
		return false
	for point: Vector2 in points:
		if not is_finite(point.x) or not is_finite(point.y):
			return false
	for index in range(points.size()):
		if points[index].distance_squared_to(
			points[(index + 1) % points.size()]
		) <= 0.000000000001:
			return false
	return FlowMath.polygon_is_simple(points)


static func _parse_mode(value: Variant) -> int:
	if typeof(value) == TYPE_INT:
		var numeric_mode := int(value)
		return numeric_mode if numeric_mode in [Mode.ABSORB, Mode.REPEL] else -1
	if typeof(value) == TYPE_FLOAT:
		var numeric_value := float(value)
		if not is_finite(numeric_value) or numeric_value != floor(numeric_value):
			return -1
		var numeric_mode := int(numeric_value)
		return numeric_mode if numeric_mode in [Mode.ABSORB, Mode.REPEL] else -1
	if _is_string(value):
		match String(value).to_lower():
			"absorb", "absorber":
				return Mode.ABSORB
			"repel", "repeller", "obstacle":
				return Mode.REPEL
	return -1


static func _parse_vertices(value: Variant) -> Variant:
	if value is PackedVector2Array:
		var packed_value: PackedVector2Array = value
		return packed_value.duplicate()
	if not value is Array:
		return null
	var parsed := PackedVector2Array()
	for item: Variant in value:
		var point: Variant = _parse_point(item)
		if point == null:
			return null
		parsed.append(point)
	return parsed


static func _parse_point(value: Variant) -> Variant:
	if value is Vector2:
		var point: Vector2 = value
		return point if is_finite(point.x) and is_finite(point.y) else null
	if value is Vector2i:
		return Vector2(value)
	if value is Array and value.size() == 2:
		if _is_finite_number(value[0]) and _is_finite_number(value[1]):
			return Vector2(float(value[0]), float(value[1]))
	if value is Dictionary and value.has("x") and value.has("y"):
		if _is_finite_number(value["x"]) and _is_finite_number(value["y"]):
			return Vector2(float(value["x"]), float(value["y"]))
	return null


static func vertices_to_array(points: PackedVector2Array) -> Array:
	var result: Array = []
	for point: Vector2 in points:
		result.append([point.x, point.y])
	return result


static func _is_string(value: Variant) -> bool:
	return typeof(value) == TYPE_STRING or typeof(value) == TYPE_STRING_NAME


static func _is_finite_number(value: Variant) -> bool:
	return (
		typeof(value) == TYPE_INT or typeof(value) == TYPE_FLOAT
	) and is_finite(float(value))
