class_name FlowReservoir
extends Resource

## Circular pool with an open upstream face and a gated downstream wall.

const _FIELD_NAMES := [
	"element_id",
	"x",
	"y",
	"radius",
	"outlet_width",
	"gate_open",
	"circulation",
	"swirl_strength",
	"confinement_strength",
	"wall_strength",
	"outlet_strength",
	"wall_influence",
	"orbit_radius_fraction",
	"orbit_radius_spread",
]

@export var element_id: StringName = &"reservoir"
@export var x: float = 0.0
@export var y: float = 0.0
@export var radius: float = 1.0
@export var outlet_width: float = 0.25
@export var gate_open: bool = true
@export var circulation: float = 1.0
@export var swirl_strength: float = 3.085714285714286
@export var confinement_strength: float = 3.2
@export var wall_strength: float = 10.285714285714286
@export var outlet_strength: float = 5.142857142857143
@export var wall_influence: float = 0.28285714285714286
@export_range(0.0, 1.0, 0.001) var orbit_radius_fraction: float = 0.62
@export_range(0.0, 2.0, 0.001, "or_greater") var orbit_radius_spread: float = 0.52

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
	var next_outlet_width := outlet_width
	var next_gate_open := gate_open
	var next_circulation := circulation
	var next_swirl_strength := swirl_strength
	var next_confinement_strength := confinement_strength
	var next_wall_strength := wall_strength
	var next_outlet_strength := outlet_strength
	var next_wall_influence := wall_influence
	var next_orbit_radius_fraction := orbit_radius_fraction
	var next_orbit_radius_spread := orbit_radius_spread

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
			"gate_open":
				if typeof(value) != TYPE_BOOL:
					return false
				next_gate_open = bool(value)
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
			"outlet_width":
				if not _is_finite_number(value):
					return false
				next_outlet_width = float(value)
			"circulation":
				if not _is_finite_number(value):
					return false
				next_circulation = float(value)
			"swirl_strength":
				if not _is_finite_number(value):
					return false
				next_swirl_strength = float(value)
			"confinement_strength":
				if not _is_finite_number(value):
					return false
				next_confinement_strength = float(value)
			"wall_strength":
				if not _is_finite_number(value):
					return false
				next_wall_strength = float(value)
			"outlet_strength":
				if not _is_finite_number(value):
					return false
				next_outlet_strength = float(value)
			"wall_influence":
				if not _is_finite_number(value):
					return false
				next_wall_influence = float(value)
			"orbit_radius_fraction":
				if not _is_finite_number(value):
					return false
				next_orbit_radius_fraction = float(value)
			"orbit_radius_spread":
				if not _is_finite_number(value):
					return false
				next_orbit_radius_spread = float(value)

	if next_element_id == &"" or next_radius <= 0.0:
		return false
	if next_outlet_width < 0.0 or next_outlet_width > next_radius * 2.0:
		return false
	if (
		next_swirl_strength < 0.0
		or next_confinement_strength < 0.0
		or next_wall_strength < 0.0
		or next_outlet_strength < 0.0
		or next_wall_influence <= 0.0
	):
		return false
	if next_orbit_radius_fraction < 0.0 or next_orbit_radius_fraction > 1.0:
		return false
	if next_orbit_radius_spread < 0.0:
		return false

	element_id = next_element_id
	x = next_x
	y = next_y
	radius = next_radius
	outlet_width = next_outlet_width
	gate_open = next_gate_open
	circulation = next_circulation
	swirl_strength = next_swirl_strength
	confinement_strength = next_confinement_strength
	wall_strength = next_wall_strength
	outlet_strength = next_outlet_strength
	wall_influence = next_wall_influence
	orbit_radius_fraction = next_orbit_radius_fraction
	orbit_radius_spread = next_orbit_radius_spread
	emit_changed()
	return true


func to_dictionary() -> Dictionary:
	return {
		"element_id": String(element_id),
		"x": x,
		"y": y,
		"radius": radius,
		"outlet_width": outlet_width,
		"gate_open": gate_open,
		"circulation": circulation,
		"swirl_strength": swirl_strength,
		"confinement_strength": confinement_strength,
		"wall_strength": wall_strength,
		"outlet_strength": outlet_strength,
		"wall_influence": wall_influence,
		"orbit_radius_fraction": orbit_radius_fraction,
		"orbit_radius_spread": orbit_radius_spread,
	}


static func _is_string(value: Variant) -> bool:
	return typeof(value) == TYPE_STRING or typeof(value) == TYPE_STRING_NAME


static func _is_finite_number(value: Variant) -> bool:
	return (
		typeof(value) == TYPE_INT or typeof(value) == TYPE_FLOAT
	) and is_finite(float(value))
