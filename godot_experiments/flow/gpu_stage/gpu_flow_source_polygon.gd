class_name GPUFlowSourcePolygon
extends Resource

## Runtime-addressable source geometry for GPU-owned water heads.
##
## Vertices and flow_direction use the controller's 16 x 9 world coordinates
## (Y points upward). GPUFlowSourceTexturePacker performs the one-time conversion
## to native stage pixels. A source emits across every downstream-facing edge;
## edge probability is proportional to length * outward-normal alignment.

const MAX_VERTICES := 12
const NO_SEED := -1
const MAX_SEED := 2147483647
const ALIGNMENT_EPSILON := 1.0e-9
const SAMPLE_ENDPOINT_EPSILON := 1.0e-12

const _FIELD_NAMES := [
	"element_id",
	"id",
	"vertices",
	"enabled",
	"emission_fraction",
	"flow_direction",
	"seed",
]

@export var element_id: StringName = &"source_polygon"
@export var vertices: PackedVector2Array = PackedVector2Array()
@export var enabled: bool = true
@export_range(0.0, 1.0, 0.001) var emission_fraction: float = 1.0
@export var flow_direction: Vector2 = Vector2.RIGHT
## NO_SEED uses the supplied sample directly. A nonnegative seed adds a stable
## deterministic phase without introducing mutable CPU or GPU random state.
@export_range(NO_SEED, MAX_SEED, 1) var seed: int = NO_SEED


func apply_dictionary(values: Dictionary) -> bool:
	## Validate the complete patch before mutating this resource.
	if (
		values.has("id")
		and values.has("element_id")
		and String(values["id"]) != String(values["element_id"])
	):
		return false
	var next_element_id: StringName = element_id
	var next_vertices: PackedVector2Array = vertices.duplicate()
	var next_enabled: bool = enabled
	var next_emission_fraction: float = emission_fraction
	var next_flow_direction: Vector2 = flow_direction
	var next_seed: int = seed

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
			"enabled":
				if typeof(value) != TYPE_BOOL:
					return false
				next_enabled = bool(value)
			"emission_fraction":
				if not _is_finite_number(value):
					return false
				next_emission_fraction = float(value)
			"flow_direction":
				var parsed_direction: Variant = _parse_point(value)
				if parsed_direction == null:
					return false
				next_flow_direction = parsed_direction
			"seed":
				var parsed_seed: Variant = _parse_seed(value)
				if parsed_seed == null:
					return false
				next_seed = int(parsed_seed)

	var candidate_error := _validation_error_for(
		next_element_id,
		next_vertices,
		next_emission_fraction,
		next_flow_direction,
		next_seed,
	)
	if not candidate_error.is_empty():
		return false

	element_id = next_element_id
	vertices = next_vertices
	enabled = next_enabled
	emission_fraction = next_emission_fraction
	flow_direction = next_flow_direction
	seed = next_seed
	emit_changed()
	return true


func validate() -> String:
	return _validation_error_for(
		element_id,
		vertices,
		emission_fraction,
		flow_direction,
		seed,
	)


func to_dictionary() -> Dictionary:
	var result := {
		"element_id": String(element_id),
		"vertices": vertices_to_array(vertices),
		"enabled": enabled,
		"emission_fraction": emission_fraction,
		"flow_direction": [flow_direction.x, flow_direction.y],
	}
	if seed != NO_SEED:
		result["seed"] = seed
	return result


func sample_emission_point(
	sample01: float,
	downstream_epsilon: float = 0.0,
) -> Vector2:
	## CPU diagnostic/reference for projected downstream-edge selection. The GPU
	## source shader keeps this Y choice and independently distributes X across the
	## packed polygon bounds.
	if (
		not is_finite(sample01)
		or not is_finite(downstream_epsilon)
		or downstream_epsilon < 0.0
		or not validate().is_empty()
	):
		return Vector2.INF

	var edges := selected_downstream_edges(vertices, flow_direction)
	if edges.is_empty():
		return Vector2.INF
	var unit_sample := _phased_unit_sample(sample01, seed)
	var total_weight := 0.0
	for edge_info: Dictionary in edges:
		total_weight += float(edge_info["weight"])
	if total_weight <= ALIGNMENT_EPSILON:
		return Vector2.INF

	var target_weight := unit_sample * total_weight
	var accumulated_weight := 0.0
	for edge_array_index in range(edges.size()):
		var edge_info: Dictionary = edges[edge_array_index]
		var edge_weight := float(edge_info["weight"])
		var is_last_edge := edge_array_index == edges.size() - 1
		if target_weight < accumulated_weight + edge_weight or is_last_edge:
			var local_sample := clampf(
				(target_weight - accumulated_weight) / edge_weight,
				0.0,
				1.0,
			)
			var start: Vector2 = edge_info["start"]
			var end: Vector2 = edge_info["end"]
			var outward_normal: Vector2 = edge_info["outward_normal"]
			return start.lerp(end, local_sample) + outward_normal * downstream_epsilon
		accumulated_weight += edge_weight
	return Vector2.INF


static func selected_downstream_edges(
	points: PackedVector2Array,
	direction: Vector2,
) -> Array[Dictionary]:
	## Each selected edge includes edge_index, endpoints, outward normal, length,
	## alignment, and weight. weight = length * positive alignment.
	var result: Array[Dictionary] = []
	if (
		not is_valid_polygon(points)
		or not is_finite(direction.x)
		or not is_finite(direction.y)
		or direction.length_squared() <= ALIGNMENT_EPSILON * ALIGNMENT_EPSILON
	):
		return result

	var normalized_direction := direction.normalized()
	var counterclockwise := FlowMath.polygon_signed_area(points) > 0.0
	for index in range(points.size()):
		var start := points[index]
		var end := points[(index + 1) % points.size()]
		var edge := end - start
		var edge_length := edge.length()
		var outward_normal := Vector2.ZERO
		if counterclockwise:
			outward_normal = Vector2(edge.y, -edge.x) / edge_length
		else:
			outward_normal = Vector2(-edge.y, edge.x) / edge_length
		var alignment := outward_normal.dot(normalized_direction)
		if alignment <= ALIGNMENT_EPSILON:
			continue
		result.append({
			"edge_index": index,
			"start": start,
			"end": end,
			"outward_normal": outward_normal,
			"length": edge_length,
			"alignment": alignment,
			"weight": edge_length * alignment,
		})
	return result


static func is_valid_polygon(points: PackedVector2Array) -> bool:
	if points.size() < 3 or points.size() > MAX_VERTICES:
		return false
	for point: Vector2 in points:
		if not is_finite(point.x) or not is_finite(point.y):
			return false
	for index in range(points.size()):
		if points[index].distance_squared_to(
			points[(index + 1) % points.size()]
		) <= ALIGNMENT_EPSILON * ALIGNMENT_EPSILON:
			return false
	return FlowMath.polygon_is_simple(points)


static func vertices_to_array(points: PackedVector2Array) -> Array:
	var result: Array = []
	for point: Vector2 in points:
		result.append([point.x, point.y])
	return result


static func seed_phase(value: int) -> float:
	return 0.0 if value == NO_SEED else FlowMath.stable_unit_sample(0, value)


static func _phased_unit_sample(sample01: float, sample_seed: int) -> float:
	var unit_sample := clampf(sample01, 0.0, 1.0)
	if unit_sample >= 1.0:
		unit_sample = 1.0 - SAMPLE_ENDPOINT_EPSILON
	if sample_seed != NO_SEED:
		unit_sample = FlowMath.unit_fraction(unit_sample + seed_phase(sample_seed))
	return unit_sample


static func _validation_error_for(
	candidate_element_id: StringName,
	candidate_vertices: PackedVector2Array,
	candidate_emission_fraction: float,
	candidate_flow_direction: Vector2,
	candidate_seed: int,
) -> String:
	if candidate_element_id == &"":
		return "A GPU source polygon needs a nonempty element_id."
	if not is_valid_polygon(candidate_vertices):
		return "A GPU source polygon needs 3-12 finite vertices forming a simple polygon."
	if (
		not is_finite(candidate_emission_fraction)
		or candidate_emission_fraction < 0.0
		or candidate_emission_fraction > 1.0
	):
		return "emission_fraction must be between 0 and 1."
	if (
		not is_finite(candidate_flow_direction.x)
		or not is_finite(candidate_flow_direction.y)
		or candidate_flow_direction.length_squared()
		<= ALIGNMENT_EPSILON * ALIGNMENT_EPSILON
	):
		return "flow_direction must be finite and nonzero."
	if candidate_seed < NO_SEED or candidate_seed > MAX_SEED:
		return "seed must be null, -1, or a nonnegative 32-bit integer."
	return ""


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


static func _parse_seed(value: Variant) -> Variant:
	if value == null:
		return NO_SEED
	if not _is_finite_number(value):
		return null
	var numeric_value := float(value)
	if (
		numeric_value != floor(numeric_value)
		or numeric_value < float(NO_SEED)
		or numeric_value > float(MAX_SEED)
	):
		return null
	return int(numeric_value)


static func _is_string(value: Variant) -> bool:
	return typeof(value) == TYPE_STRING or typeof(value) == TYPE_STRING_NAME


static func _is_finite_number(value: Variant) -> bool:
	return (
		typeof(value) == TYPE_INT or typeof(value) == TYPE_FLOAT
	) and is_finite(float(value))
