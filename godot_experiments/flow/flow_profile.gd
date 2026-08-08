class_name FlowProfile
extends Resource

## Serializable source configuration for one independent flow simulation.
##
## A scene may share this preset Resource safely because FlowModel2D calls
## duplicate_for_runtime() before changing any parameters or geometry.

const MAX_WATER_SLOTS := 1500
const MAX_TRAIL_STORAGE_POINTS := 2_000_000

const _PARAMETER_SCHEMA := {
	"world_size": {
		"type": "vector2", "component_minimum": 0.001,
		"requires_reset": true,
	},
	"legacy_world_height": {
		"type": "float", "minimum": 0.001, "requires_reset": false,
	},
	"target_fps": {
		"type": "int", "minimum": 1, "maximum": 240,
		"requires_reset": false,
	},
	"simulation_substeps": {
		"type": "int", "minimum": 1, "maximum": 200,
		"requires_reset": false,
	},
	"max_particles": {
		"type": "int", "minimum": 1, "maximum": MAX_WATER_SLOTS,
		"requires_reset": true,
	},
	"retention_capacity": {
		"type": "int", "minimum": 0, "maximum": MAX_WATER_SLOTS,
		"requires_reset": true,
	},
	"trail_length": {
		"type": "int", "minimum": 2, "maximum": 20000,
		"requires_reset": true,
	},
	"flow_rate": {
		"type": "float", "minimum": 0.0, "maximum": 1.0,
		"requires_reset": false,
	},
	"max_flow_speed": {
		"type": "float", "minimum": 0.0, "requires_reset": false,
	},
	"flow_variation": {
		"type": "float", "minimum": 0.0, "maximum": 1.0,
		"requires_reset": false,
	},
	"min_active_flow": {
		"type": "float", "minimum": 0.000001, "maximum": 1.0,
		"requires_reset": false,
	},
	"particle_launch_delay_ms": {
		"type": "float", "minimum": 0.0, "requires_reset": false,
	},
	"random_seed": {
		"type": "int", "minimum": -1, "requires_reset": true,
		"description": "-1 preserves Python RANDOM_SEED=None behavior.",
	},
	"base_flow": {
		"type": "vector2", "requires_reset": false,
	},
	"noise_strength": {
		"type": "float", "minimum": 0.0, "requires_reset": false,
	},
	"noise_scale": {
		"type": "float", "minimum": 0.000001, "requires_reset": false,
	},
	"noise_speed": {
		"type": "float", "requires_reset": false,
	},
	"shore_exit_angle_jitter_degrees": {
		"type": "float", "minimum": 0.0, "maximum": 180.0,
		"requires_reset": false,
	},
	"separation_radius": {
		"type": "float", "minimum": 0.0, "requires_reset": false,
	},
	"separation_strength": {
		"type": "float", "minimum": 0.0, "requires_reset": false,
	},
	"separation_x_scale": {
		"type": "float", "minimum": 0.0, "maximum": 1.0,
		"requires_reset": false,
	},
	"separation_max_force": {
		"type": "float", "minimum": 0.0, "requires_reset": false,
	},
	"line_width_min": {
		"type": "float", "minimum": 0.001, "requires_reset": false,
	},
	"line_width_max": {
		"type": "float", "minimum": 0.001, "requires_reset": false,
	},
	"particle_alpha": {
		"type": "float", "minimum": 0.0, "maximum": 1.0,
		"requires_reset": false,
	},
	"background_color": {
		"type": "color", "requires_reset": false,
	},
	"line_colors": {
		"type": "color_array", "minimum_size": 1,
		"requires_reset": false,
	},
	"spawn_x": {
		"type": "float", "requires_reset": false,
	},
	"spawn_y_margin": {
		"type": "float", "minimum": 0.0, "requires_reset": false,
	},
	"reservoir_release_rate": {
		"type": "float", "minimum": 0.0, "requires_reset": false,
	},
	"release_threshold_min": {
		"type": "float", "minimum": 0.000001, "requires_reset": false,
	},
	"release_threshold_max": {
		"type": "float", "minimum": 0.000001, "requires_reset": false,
	},
	"gate_width_step": {
		"type": "float", "minimum": 0.0, "requires_reset": false,
	},
	"debug_geometry_visible": {
		"type": "bool", "requires_reset": false,
	},
	"debug_geometry_color": {
		"type": "color", "requires_reset": false,
	},
	"debug_geometry_line_width": {
		"type": "float", "minimum": 0.0, "requires_reset": false,
	},
}

@export_group("World and timing")
@export var world_size: Vector2 = Vector2(16.0, 9.0)
@export var legacy_world_height: float = 7.0
@export var target_fps: int = 30
@export var simulation_substeps: int = 20
@export var max_particles: int = 300
@export var retention_capacity: int = 100
@export var trail_length: int = 1200
@export var particle_launch_delay_ms: float = 10.0
## -1 is the Godot representation of Python RANDOM_SEED=None.
@export var random_seed: int = -1

@export_group("Water flow")
@export_range(0.0, 1.0, 0.001) var flow_rate: float = 0.5
@export var max_flow_speed: float = 10.0
@export_range(0.0, 1.0, 0.001) var flow_variation: float = 0.1
@export_range(0.000001, 1.0, 0.000001) var min_active_flow: float = 0.001
@export var base_flow: Vector2 = Vector2(2.5714285714285716, 0.0)
@export var noise_strength: float = 0.7714285714285715
@export var noise_scale: float = 1.1666666666666665
@export var noise_speed: float = 0.75
@export var shore_exit_angle_jitter_degrees: float = 16.0

@export_group("Particle separation")
@export var separation_radius: float = 0.18000000000000002
@export var separation_strength: float = 1.6071428571428572
@export_range(0.0, 1.0, 0.001) var separation_x_scale: float = 0.15
@export var separation_max_force: float = 1.9285714285714288

@export_group("Water rendering")
@export var line_width_min: float = 0.5
@export var line_width_max: float = 3.0
@export_range(0.0, 1.0, 0.001) var particle_alpha: float = 1.0
@export var background_color: Color = Color.BLACK
@export var line_colors: PackedColorArray = PackedColorArray([
	Color("#FFFFFF"),
	Color("#EAF7EE"),
	Color("#D3EFDC"),
	Color("#ACE1AF"),
	Color("#7BCFC4"),
	Color("#4AB0E1"),
	Color("#1E90FF"),
])

@export_group("Spawn and release")
@export var spawn_x: float = -0.0642857142857143
@export var spawn_y_margin: float = 0.19285714285714287
@export var reservoir_release_rate: float = 2.0
@export var release_threshold_min: float = 0.5
@export var release_threshold_max: float = 1.5
@export var gate_width_step: float = 0.0642857142857143

@export_group("Debug geometry")
@export var debug_geometry_visible: bool = true
@export var debug_geometry_color: Color = Color("#FFA500")
@export var debug_geometry_line_width: float = 1.5

@export_group("Geometry")
@export var circle_obstacles: Array[FlowCircleObstacle] = []
@export var rectangle_obstacles: Array[FlowRectangleObstacle] = []
@export var polygon_obstacles: Array[FlowPolygonObstacle] = []
@export var shorelines: Array[FlowShoreline] = []
@export var absorbers: Array[FlowAbsorber] = []
@export var reservoirs: Array[FlowReservoir] = []


func duplicate_for_runtime() -> FlowProfile:
	## Duplicate every nested Resource so seven simulations never share state.
	var runtime := duplicate(false) as FlowProfile
	runtime.line_colors = line_colors.duplicate()

	var runtime_circles: Array[FlowCircleObstacle] = []
	for item in circle_obstacles:
		if item != null:
			runtime_circles.append(item.duplicate(true) as FlowCircleObstacle)
	runtime.circle_obstacles = runtime_circles

	var runtime_rectangles: Array[FlowRectangleObstacle] = []
	for item in rectangle_obstacles:
		if item != null:
			runtime_rectangles.append(item.duplicate(true) as FlowRectangleObstacle)
	runtime.rectangle_obstacles = runtime_rectangles

	var runtime_polygons: Array[FlowPolygonObstacle] = []
	for item in polygon_obstacles:
		if item != null:
			runtime_polygons.append(item.duplicate(true) as FlowPolygonObstacle)
	runtime.polygon_obstacles = runtime_polygons

	var runtime_shorelines: Array[FlowShoreline] = []
	for item in shorelines:
		if item != null:
			runtime_shorelines.append(item.duplicate(true) as FlowShoreline)
	runtime.shorelines = runtime_shorelines

	var runtime_absorbers: Array[FlowAbsorber] = []
	for item in absorbers:
		if item != null:
			runtime_absorbers.append(item.duplicate(true) as FlowAbsorber)
	runtime.absorbers = runtime_absorbers

	var runtime_reservoirs: Array[FlowReservoir] = []
	for item in reservoirs:
		if item != null:
			runtime_reservoirs.append(item.duplicate(true) as FlowReservoir)
	runtime.reservoirs = runtime_reservoirs
	return runtime


func to_parameter_dictionary() -> Dictionary:
	## Return native Godot values suitable for a local controller or snapshot.
	return {
		"world_size": world_size,
		"legacy_world_height": legacy_world_height,
		"target_fps": target_fps,
		"simulation_substeps": simulation_substeps,
		"max_particles": max_particles,
		"retention_capacity": retention_capacity,
		"trail_length": trail_length,
		"flow_rate": flow_rate,
		"max_flow_speed": max_flow_speed,
		"flow_variation": flow_variation,
		"min_active_flow": min_active_flow,
		"particle_launch_delay_ms": particle_launch_delay_ms,
		"random_seed": random_seed,
		"base_flow": base_flow,
		"noise_strength": noise_strength,
		"noise_scale": noise_scale,
		"noise_speed": noise_speed,
		"shore_exit_angle_jitter_degrees": shore_exit_angle_jitter_degrees,
		"separation_radius": separation_radius,
		"separation_strength": separation_strength,
		"separation_x_scale": separation_x_scale,
		"separation_max_force": separation_max_force,
		"line_width_min": line_width_min,
		"line_width_max": line_width_max,
		"particle_alpha": particle_alpha,
		"background_color": background_color,
		"line_colors": line_colors.duplicate(),
		"spawn_x": spawn_x,
		"spawn_y_margin": spawn_y_margin,
		"reservoir_release_rate": reservoir_release_rate,
		"release_threshold_min": release_threshold_min,
		"release_threshold_max": release_threshold_max,
		"gate_width_step": gate_width_step,
		"debug_geometry_visible": debug_geometry_visible,
		"debug_geometry_color": debug_geometry_color,
		"debug_geometry_line_width": debug_geometry_line_width,
	}


func get_parameter_dictionary() -> Dictionary:
	return to_parameter_dictionary()


static func parameter_schema() -> Dictionary:
	return _PARAMETER_SCHEMA.duplicate(true)


static func get_parameter_schema() -> Dictionary:
	return parameter_schema()


func apply_parameter_dictionary(values: Dictionary) -> String:
	## Apply a scalar patch atomically. An empty String means success.
	var candidate := to_parameter_dictionary()
	for raw_key in values:
		var key := String(raw_key)
		if not _PARAMETER_SCHEMA.has(key):
			return "Unknown flow parameter '%s'." % key
		var normalized := _normalize_parameter_value(
			key,
			values[raw_key],
			_PARAMETER_SCHEMA[key]
		)
		if not bool(normalized["ok"]):
			return String(normalized["error"])
		candidate[key] = normalized["value"]

	var validation_error := _validate_parameter_values(candidate)
	if not validation_error.is_empty():
		return validation_error
	if (
		int(candidate["retention_capacity"]) < 1
		and not reservoirs.is_empty()
	):
		return "retention_capacity must be at least 1 while reservoirs exist."

	for key in candidate:
		set(StringName(key), candidate[key])
	emit_changed()
	return ""


func validate() -> String:
	var scalar_error := _validate_parameter_values(to_parameter_dictionary())
	if not scalar_error.is_empty():
		return scalar_error

	var collections := {
		"circle_obstacles": circle_obstacles,
		"rectangle_obstacles": rectangle_obstacles,
		"polygon_obstacles": polygon_obstacles,
		"shorelines": shorelines,
		"absorbers": absorbers,
		"reservoirs": reservoirs,
	}
	for collection_name in collections:
		var seen_ids: Dictionary = {}
		for element in collections[collection_name]:
			if element == null:
				return "%s contains a null resource." % collection_name
			var identifier := String(element.element_id)
			if identifier.is_empty():
				return "%s contains an empty element_id." % collection_name
			if seen_ids.has(identifier):
				return "%s contains duplicate element_id '%s'." % [
					collection_name,
					identifier,
				]
			seen_ids[identifier] = true
	if not reservoirs.is_empty() and retention_capacity < 1:
		return "retention_capacity must be at least 1 while reservoirs exist."
	return ""


func to_dictionary() -> Dictionary:
	## Produce a JSON-friendly full snapshot, including all geometry.
	var parameters := to_parameter_dictionary()
	parameters["world_size"] = _vector_to_array(world_size)
	parameters["base_flow"] = _vector_to_array(base_flow)
	parameters["background_color"] = background_color.to_html(true)
	parameters["debug_geometry_color"] = debug_geometry_color.to_html(true)
	var serialized_colors: Array = []
	for color in line_colors:
		serialized_colors.append(color.to_html(true))
	parameters["line_colors"] = serialized_colors

	return {
		"parameters": parameters,
		"circle_obstacles": _resources_to_dictionaries(circle_obstacles),
		"rectangle_obstacles": _resources_to_dictionaries(rectangle_obstacles),
		"polygon_obstacles": _resources_to_dictionaries(polygon_obstacles),
		"shorelines": _resources_to_dictionaries(shorelines),
		"absorbers": _resources_to_dictionaries(absorbers),
		"reservoirs": _resources_to_dictionaries(reservoirs),
	}


static func _normalize_parameter_value(
	key: String,
	value: Variant,
	schema: Dictionary
) -> Dictionary:
	var kind := String(schema["type"])
	match kind:
		"int":
			if not _is_finite_number(value):
				return _normalization_error(key, "must be an integer")
			var numeric := float(value)
			if not is_equal_approx(numeric, roundf(numeric)):
				return _normalization_error(key, "must be an integer")
			var integer_value := int(numeric)
			var integer_range_error := _range_error(float(integer_value), schema)
			return (
				_normalization_error(key, integer_range_error)
				if not integer_range_error.is_empty()
				else {"ok": true, "value": integer_value, "error": ""}
			)
		"float":
			if not _is_finite_number(value):
				return _normalization_error(key, "must be numeric")
			var float_value := float(value)
			var float_range_error := _range_error(float_value, schema)
			return (
				_normalization_error(key, float_range_error)
				if not float_range_error.is_empty()
				else {"ok": true, "value": float_value, "error": ""}
			)
		"bool":
			if typeof(value) != TYPE_BOOL:
				return _normalization_error(key, "must be a boolean")
			return {"ok": true, "value": bool(value), "error": ""}
		"vector2":
			var vector: Variant = _parse_vector2(value)
			if vector == null:
				return _normalization_error(key, "must be a finite Vector2 or [x, y]")
			if schema.has("component_minimum"):
				var minimum := float(schema["component_minimum"])
				if vector.x < minimum or vector.y < minimum:
					return _normalization_error(
						key,
						"components must be at least %s" % minimum
					)
			return {"ok": true, "value": vector, "error": ""}
		"color":
			var color: Variant = _parse_color(value)
			if color == null:
				return _normalization_error(key, "must be a Color or HTML color")
			return {"ok": true, "value": color, "error": ""}
		"color_array":
			var colors: Variant = _parse_color_array(value)
			if colors == null:
				return _normalization_error(key, "must be an array of colors")
			if colors.size() < int(schema.get("minimum_size", 0)):
				return _normalization_error(key, "must contain at least one color")
			return {"ok": true, "value": colors, "error": ""}
		_:
			return _normalization_error(key, "has an unsupported schema type")


static func _validate_parameter_values(values: Dictionary) -> String:
	# Re-run the complete schema here, even when values came from exported
	# Resource properties rather than apply_parameter_dictionary().  The model's
	# runtime controller builds an atomic candidate with several individual
	# assignments, then calls validate() once after the entire patch is present.
	# This keeps multi-field changes atomic while still enforcing every range.
	var normalized_values: Dictionary = {}
	for key in _PARAMETER_SCHEMA:
		if not values.has(key):
			return "Missing flow parameter '%s'." % key
		var normalized := _normalize_parameter_value(
			key,
			values[key],
			_PARAMETER_SCHEMA[key]
		)
		if not bool(normalized["ok"]):
			return String(normalized["error"])
		normalized_values[key] = normalized["value"]

	var water_slot_count := (
		int(normalized_values["max_particles"])
		+ int(normalized_values["retention_capacity"])
	)
	if water_slot_count > MAX_WATER_SLOTS:
		return "max_particles + retention_capacity cannot exceed %d." % MAX_WATER_SLOTS
	var trail_storage_points := (
		water_slot_count * int(normalized_values["trail_length"])
	)
	if trail_storage_points > MAX_TRAIL_STORAGE_POINTS:
		return (
			"Water-slot count × trail_length cannot exceed %d points."
			% MAX_TRAIL_STORAGE_POINTS
		)

	if (
		float(normalized_values["line_width_min"])
		> float(normalized_values["line_width_max"])
	):
		return "line_width_min cannot exceed line_width_max."
	if (
		float(normalized_values["release_threshold_min"])
		> float(normalized_values["release_threshold_max"])
	):
		return "release_threshold_min cannot exceed release_threshold_max."
	var size: Vector2 = normalized_values["world_size"]
	if float(normalized_values["spawn_y_margin"]) * 2.0 >= size.y:
		return "spawn_y_margin leaves no vertical spawn channel."
	var flow: Vector2 = normalized_values["base_flow"]
	if flow.x <= 0.0:
		return "base_flow.x must remain positive for the X-axis flow model."
	var colors: PackedColorArray = normalized_values["line_colors"]
	if colors.is_empty():
		return "line_colors must contain at least one color."
	return ""


static func _range_error(value: float, schema: Dictionary) -> String:
	if schema.has("minimum") and value < float(schema["minimum"]):
		return "must be at least %s" % schema["minimum"]
	if schema.has("maximum") and value > float(schema["maximum"]):
		return "must be at most %s" % schema["maximum"]
	return ""


static func _normalization_error(key: String, message: String) -> Dictionary:
	return {
		"ok": false,
		"value": null,
		"error": "Parameter '%s' %s." % [key, message],
	}


static func _parse_vector2(value: Variant) -> Variant:
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


static func _parse_color(value: Variant) -> Variant:
	if value is Color:
		return value
	if typeof(value) != TYPE_STRING and typeof(value) != TYPE_STRING_NAME:
		return null
	var invalid := Color(2.0, 2.0, 2.0, 2.0)
	var parsed := Color.from_string(String(value), invalid)
	return null if parsed == invalid else parsed


static func _parse_color_array(value: Variant) -> Variant:
	if value is PackedColorArray:
		var packed_value: PackedColorArray = value
		return packed_value.duplicate()
	if not value is Array:
		return null
	var colors := PackedColorArray()
	for item in value:
		var color: Variant = _parse_color(item)
		if color == null:
			return null
		colors.append(color)
	return colors


static func _resources_to_dictionaries(resources: Array) -> Array:
	var result: Array = []
	for resource in resources:
		if resource != null and resource.has_method("to_dictionary"):
			result.append(resource.to_dictionary())
	return result


static func _vector_to_array(value: Vector2) -> Array:
	return [value.x, value.y]


static func _is_finite_number(value: Variant) -> bool:
	return (
		typeof(value) == TYPE_INT or typeof(value) == TYPE_FLOAT
	) and is_finite(float(value))
