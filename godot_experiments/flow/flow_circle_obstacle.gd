class_name FlowCircleObstacle
extends Resource

## Runtime-editable equivalent of Python's Obstacle dataclass.

const _FIELD_NAMES := [
	"element_id",
	"x",
	"y",
	"radius",
	"strength",
	"bend",
]

@export var element_id: StringName = &"circle_obstacle"
@export var x: float = 0.0
@export var y: float = 0.0
@export var radius: float = 0.25
@export var strength: float = 5.142857142857143
@export var bend: float = 1.2857142857142858

var center: Vector2:
	get:
		return Vector2(x, y)
	set(value):
		x = value.x
		y = value.y


func apply_dictionary(values: Dictionary) -> bool:
	## Validate a complete patch before mutating this resource.
	var next_element_id := element_id
	var next_x := x
	var next_y := y
	var next_radius := radius
	var next_strength := strength
	var next_bend := bend

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
			"x":
				if not _is_finite_number(value):
					return false
				next_x = float(value)
			"y":
				if not _is_finite_number(value):
					return false
				next_y = float(value)
			"radius":
				if not _is_finite_number(value):
					return false
				next_radius = float(value)
			"strength":
				if not _is_finite_number(value):
					return false
				next_strength = float(value)
			"bend":
				if not _is_finite_number(value):
					return false
				next_bend = float(value)

	if next_element_id == &"" or next_radius <= 0.0:
		return false
	if next_strength < 0.0:
		return false

	element_id = next_element_id
	x = next_x
	y = next_y
	radius = next_radius
	strength = next_strength
	bend = next_bend
	emit_changed()
	return true


func to_dictionary() -> Dictionary:
	return {
		"element_id": String(element_id),
		"x": x,
		"y": y,
		"radius": radius,
		"strength": strength,
		"bend": bend,
	}


static func _is_string(value: Variant) -> bool:
	return typeof(value) == TYPE_STRING or typeof(value) == TYPE_STRING_NAME


static func _is_finite_number(value: Variant) -> bool:
	return (
		typeof(value) == TYPE_INT or typeof(value) == TYPE_FLOAT
	) and is_finite(float(value))
