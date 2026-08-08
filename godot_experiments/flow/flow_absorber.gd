class_name FlowAbsorber
extends Resource

## Runtime-editable equivalent of Python's Absorber dataclass.

const _FIELD_NAMES := [
	"element_id",
	"x",
	"y",
	"width",
	"height",
	"absorption_fraction",
	"stop_margin_fraction",
]

@export var element_id: StringName = &"absorber"
@export var x: float = 0.0
@export var y: float = 0.0
@export var width: float = 0.5
@export var height: float = 0.5
@export_range(0.0, 1.0, 0.001) var absorption_fraction: float = 1.0
@export_range(0.0, 0.49, 0.001) var stop_margin_fraction: float = 0.12

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
	var next_absorption_fraction := absorption_fraction
	var next_stop_margin_fraction := stop_margin_fraction

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
			"absorption_fraction":
				if not _is_finite_number(value):
					return false
				next_absorption_fraction = float(value)
			"stop_margin_fraction":
				if not _is_finite_number(value):
					return false
				next_stop_margin_fraction = float(value)

	if next_element_id == &"":
		return false
	if next_width <= 0.0 or next_height <= 0.0:
		return false
	if next_absorption_fraction < 0.0 or next_absorption_fraction > 1.0:
		return false
	if next_stop_margin_fraction < 0.0 or next_stop_margin_fraction > 0.49:
		return false

	element_id = next_element_id
	x = next_x
	y = next_y
	width = next_width
	height = next_height
	absorption_fraction = next_absorption_fraction
	stop_margin_fraction = next_stop_margin_fraction
	emit_changed()
	return true


func to_dictionary() -> Dictionary:
	return {
		"element_id": String(element_id),
		"x": x,
		"y": y,
		"width": width,
		"height": height,
		"absorption_fraction": absorption_fraction,
		"stop_margin_fraction": stop_margin_fraction,
	}


static func _is_string(value: Variant) -> bool:
	return typeof(value) == TYPE_STRING or typeof(value) == TYPE_STRING_NAME


static func _is_finite_number(value: Variant) -> bool:
	return (
		typeof(value) == TYPE_INT or typeof(value) == TYPE_FLOAT
	) and is_finite(float(value))
