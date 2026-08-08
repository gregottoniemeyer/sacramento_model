class_name FlowRectangleObstacle
extends Resource

## Runtime-editable equivalent of Python's RectangleObstacle dataclass.

const _FIELD_NAMES := [
	"element_id",
	"x",
	"y",
	"width",
	"height",
	"angle_degrees",
	"strength",
	"bend",
	"influence",
]

@export var element_id: StringName = &"rectangle_obstacle"
@export var x: float = 0.0
@export var y: float = 0.0
@export var width: float = 1.0
@export var height: float = 1.0
@export var angle_degrees: float = 0.0
@export var strength: float = 5.142857142857143
@export var bend: float = 1.2857142857142858
@export var influence: float = 0.8357142857142859

var center: Vector2:
	get:
		return Vector2(x, y)
	set(value):
		x = value.x
		y = value.y

var size: Vector2:
	get:
		return Vector2(width, height)
	set(value):
		width = value.x
		height = value.y


func apply_dictionary(values: Dictionary) -> bool:
	## Validate a complete patch before mutating this resource.
	var next_element_id := element_id
	var next_x := x
	var next_y := y
	var next_width := width
	var next_height := height
	var next_angle_degrees := angle_degrees
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
			"x":
				if not _is_finite_number(value):
					return false
				next_x = float(value)
			"y":
				if not _is_finite_number(value):
					return false
				next_y = float(value)
			"width":
				if not _is_finite_number(value):
					return false
				next_width = float(value)
			"height":
				if not _is_finite_number(value):
					return false
				next_height = float(value)
			"angle_degrees":
				if not _is_finite_number(value):
					return false
				next_angle_degrees = float(value)
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
	if next_width <= 0.0 or next_height <= 0.0:
		return false
	if next_strength < 0.0 or next_influence <= 0.0:
		return false

	element_id = next_element_id
	x = next_x
	y = next_y
	width = next_width
	height = next_height
	angle_degrees = next_angle_degrees
	strength = next_strength
	bend = next_bend
	influence = next_influence
	emit_changed()
	return true


func to_dictionary() -> Dictionary:
	return {
		"element_id": String(element_id),
		"x": x,
		"y": y,
		"width": width,
		"height": height,
		"angle_degrees": angle_degrees,
		"strength": strength,
		"bend": bend,
		"influence": influence,
	}


static func _is_string(value: Variant) -> bool:
	return typeof(value) == TYPE_STRING or typeof(value) == TYPE_STRING_NAME


static func _is_finite_number(value: Variant) -> bool:
	return (
		typeof(value) == TYPE_INT or typeof(value) == TYPE_FLOAT
	) and is_finite(float(value))
