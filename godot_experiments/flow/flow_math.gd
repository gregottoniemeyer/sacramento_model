class_name FlowMath
extends RefCounted

## Pure geometry and deterministic sampling helpers for the flow model.
##
## All geometry uses the simulation's Python-compatible, Y-up coordinate
## system. Conversion to Godot's screen-space Y direction belongs at the
## rendering boundary, not in these functions.

const EPSILON := 1.0e-9
const BOUNDARY_EPSILON := 1.0e-8
const GOLDEN_RATIO_CONJUGATE := 0.6180339887498949
const SILVER_RATIO_CONJUGATE := 0.4142135623730951


static func safe_normalized(
	vector: Vector2,
	fallback: Vector2 = Vector2.ZERO,
) -> Vector2:
	## Return a unit vector, or a normalized fallback for a near-zero input.
	var length_squared := vector.length_squared()
	if length_squared > EPSILON * EPSILON:
		return vector / sqrt(length_squared)

	var fallback_length_squared := fallback.length_squared()
	if fallback_length_squared > EPSILON * EPSILON:
		return fallback / sqrt(fallback_length_squared)
	return Vector2.ZERO


static func rectangle_vertices(
	center: Vector2,
	size: Vector2,
	angle_degrees: float,
) -> PackedVector2Array:
	## Return four corners in counterclockwise order in Y-up model space.
	var half_size := size * 0.5
	var angle_radians := deg_to_rad(angle_degrees)
	var local_vertices := PackedVector2Array([
		Vector2(-half_size.x, -half_size.y),
		Vector2(half_size.x, -half_size.y),
		Vector2(half_size.x, half_size.y),
		Vector2(-half_size.x, half_size.y),
	])
	var result := PackedVector2Array()
	result.resize(local_vertices.size())
	for index in range(local_vertices.size()):
		result[index] = local_vertices[index].rotated(angle_radians) + center
	return result


static func polygon_signed_area(vertices: PackedVector2Array) -> float:
	## Positive area means counterclockwise winding in Y-up model space.
	if vertices.size() < 3:
		return 0.0

	var twice_area := 0.0
	for index in range(vertices.size()):
		var next_index := (index + 1) % vertices.size()
		twice_area += (
			vertices[index].x * vertices[next_index].y
			- vertices[next_index].x * vertices[index].y
		)
	return 0.5 * twice_area


static func point_inside_polygon(
	point: Vector2,
	vertices: PackedVector2Array,
) -> bool:
	## Even-odd test matching the Python flow model.
	if vertices.size() < 3:
		return false

	var inside := false
	for index in range(vertices.size()):
		var start := vertices[index]
		var end := vertices[(index + 1) % vertices.size()]
		var crosses_y := (start.y > point.y) != (end.y > point.y)
		var edge_dy := end.y - start.y
		if absf(edge_dy) < EPSILON:
			continue
		var crossing_x := (
			(end.x - start.x) * (point.y - start.y) / edge_dy
			+ start.x
		)
		if crosses_y and point.x < crossing_x:
			inside = not inside
	return inside


static func closest_point_on_segment(
	point: Vector2,
	start: Vector2,
	end: Vector2,
) -> Vector2:
	var edge := end - start
	var edge_length_squared := edge.length_squared()
	if edge_length_squared <= EPSILON * EPSILON:
		return start
	var projection := clampf(
		(point - start).dot(edge) / edge_length_squared,
		0.0,
		1.0,
	)
	return start + projection * edge


static func closest_polygon_boundary(
	point: Vector2,
	vertices: PackedVector2Array,
) -> Dictionary:
	## Return edge_index, point, offset, and distance for the nearest edge.
	if vertices.is_empty():
		return {
			"edge_index": -1,
			"point": point,
			"offset": Vector2.ZERO,
			"distance": INF,
		}

	var closest_edge_index := -1
	var closest_point := point
	var closest_distance_squared := INF
	for index in range(vertices.size()):
		var candidate := closest_point_on_segment(
			point,
			vertices[index],
			vertices[(index + 1) % vertices.size()],
		)
		var distance_squared := point.distance_squared_to(candidate)
		if distance_squared < closest_distance_squared:
			closest_distance_squared = distance_squared
			closest_edge_index = index
			closest_point = candidate

	return {
		"edge_index": closest_edge_index,
		"point": closest_point,
		"offset": point - closest_point,
		"distance": sqrt(closest_distance_squared),
	}


static func polygon_force(
	point: Vector2,
	vertices: PackedVector2Array,
	strength: float,
	bend: float,
	influence_distance: float,
	influence_power: float = 1.0,
	distance_offset: float = 0.0,
) -> Vector2:
	## Push and steer one point around a closed polygon boundary.
	## This follows polygon_obstacle_force() in ink_flow_lines_v04.py.
	if vertices.size() < 3:
		return Vector2.ZERO

	var boundary := closest_polygon_boundary(point, vertices)
	var edge_index: int = boundary["edge_index"]
	if edge_index < 0:
		return Vector2.ZERO

	var nearest_offset: Vector2 = boundary["offset"]
	var distance: float = boundary["distance"]
	var inside := point_inside_polygon(point, vertices)
	# Match Python's treatment of exact boundary samples as boundary, not as
	# penetrations that need the emergency inside push.
	inside = inside and distance >= BOUNDARY_EPSILON

	var outward := Vector2.ZERO
	if distance >= BOUNDARY_EPSILON:
		outward = nearest_offset / distance
		if inside:
			outward *= -1.0
	else:
		var edge := (
			vertices[(edge_index + 1) % vertices.size()]
			- vertices[edge_index]
		)
		if polygon_signed_area(vertices) >= 0.0:
			outward = safe_normalized(Vector2(edge.y, -edge.x))
		else:
			outward = safe_normalized(Vector2(-edge.y, edge.x))

	if outward == Vector2.ZERO:
		return Vector2.ZERO

	var influence := 0.0
	if influence_distance > EPSILON:
		var effective_distance := distance + distance_offset
		influence = clampf(
			(influence_distance - effective_distance) / influence_distance,
			0.0,
			1.0,
		)
		influence = pow(influence, influence_power)
	if inside:
		influence = 1.0

	var force := outward * (influence * strength)
	var tangent := Vector2(-outward.y, outward.x)
	force += tangent * (influence * bend)

	if inside:
		force += outward * strength * (2.0 + 5.0 * distance)
	return force


static func polygon_is_simple(vertices: PackedVector2Array) -> bool:
	## Reject degenerate polygons and intersections between nonadjacent edges.
	var vertex_count := vertices.size()
	if vertex_count < 3 or absf(polygon_signed_area(vertices)) <= EPSILON:
		return false

	for index in range(vertex_count):
		if (
			vertices[index].distance_squared_to(
				vertices[(index + 1) % vertex_count]
			)
			<= EPSILON * EPSILON
		):
			return false

	for first_index in range(vertex_count):
		var first_next := (first_index + 1) % vertex_count
		for second_index in range(first_index + 1, vertex_count):
			var second_next := (second_index + 1) % vertex_count
			# Adjacent edges are expected to meet at their shared vertex.
			if first_next == second_index or second_next == first_index:
				continue
			if _segments_intersect(
				vertices[first_index],
				vertices[first_next],
				vertices[second_index],
				vertices[second_next],
			):
				return false
	return true


static func shoreline_chain_validation_error(
	vertices: PackedVector2Array,
	indices: Variant,
) -> String:
	## Return an empty string for a valid forward-adjacent water-edge chain.
	if vertices.size() < 3:
		return "A shoreline polygon needs at least three vertices."
	if not _is_supported_index_collection(indices):
		return "Shoreline indices must be an Array or packed integer array."
	if indices.size() < 2:
		return "A shoreline water edge needs at least two indices."

	var vertex_count := vertices.size()
	for chain_index in range(indices.size()):
		var vertex_index := int(indices[chain_index])
		if vertex_index < 0 or vertex_index >= vertex_count:
			return "A shoreline water-edge index is outside the vertex list."
		if chain_index == 0:
			continue
		var previous_index := int(indices[chain_index - 1])
		if vertex_index != (previous_index + 1) % vertex_count:
			return (
				"Shoreline water-edge indices must be forward-adjacent "
				+ "in polygon order."
			)
	return ""


static func shoreline_chain_is_valid(
	vertices: PackedVector2Array,
	indices: Variant,
) -> bool:
	return shoreline_chain_validation_error(vertices, indices).is_empty()


static func vertical_polygon_intersections(
	vertices: PackedVector2Array,
	x: float,
	epsilon: float = EPSILON,
) -> PackedFloat32Array:
	## Return all segment intersections with x=constant, sorted by Y.
	## Inclusive endpoints and vertical-edge handling match the Python inlet
	## channel calculation; duplicate vertex hits are intentionally retained.
	var intersections := PackedFloat32Array()
	if vertices.size() < 2:
		return intersections

	for index in range(vertices.size()):
		var start := vertices[index]
		var end := vertices[(index + 1) % vertices.size()]
		var delta_x := end.x - start.x
		if absf(delta_x) < epsilon:
			if absf(x - start.x) < epsilon:
				intersections.append(start.y)
				intersections.append(end.y)
			continue

		var fraction := (x - start.x) / delta_x
		if fraction >= 0.0 and fraction <= 1.0:
			intersections.append(
				start.y + fraction * (end.y - start.y)
			)

	intersections.sort()
	return intersections


static func unit_fraction(value: float) -> float:
	## fposmod keeps the result in [0, 1), including for negative inputs.
	return fposmod(value, 1.0)


static func low_discrepancy_sample(
	index: int,
	multiplier: float = GOLDEN_RATIO_CONJUGATE,
	offset: float = 0.0,
) -> float:
	## Match the Python model's fract((index + 1) * multiplier + offset).
	return unit_fraction((float(index) + 1.0) * multiplier + offset)


static func stable_unit_sample(
	index: int,
	salt: int = 0,
	index_multiplier: float = GOLDEN_RATIO_CONJUGATE,
	salt_multiplier: float = SILVER_RATIO_CONJUGATE,
) -> float:
	## Deterministic low-discrepancy sample keyed by a slot and geometry salt.
	return unit_fraction(
		(float(index) + 1.0) * index_multiplier
		+ (float(salt) + 1.0) * salt_multiplier
	)


static func _cross(left: Vector2, right: Vector2) -> float:
	return left.x * right.y - left.y * right.x


static func _point_on_segment(
	point: Vector2,
	start: Vector2,
	end: Vector2,
) -> bool:
	if absf(_cross(end - start, point - start)) > EPSILON:
		return false
	return (
		point.x >= minf(start.x, end.x) - EPSILON
		and point.x <= maxf(start.x, end.x) + EPSILON
		and point.y >= minf(start.y, end.y) - EPSILON
		and point.y <= maxf(start.y, end.y) + EPSILON
	)


static func _segments_intersect(
	first_start: Vector2,
	first_end: Vector2,
	second_start: Vector2,
	second_end: Vector2,
) -> bool:
	var first_side_start := _cross(
		first_end - first_start,
		second_start - first_start,
	)
	var first_side_end := _cross(
		first_end - first_start,
		second_end - first_start,
	)
	var second_side_start := _cross(
		second_end - second_start,
		first_start - second_start,
	)
	var second_side_end := _cross(
		second_end - second_start,
		first_end - second_start,
	)

	if (
		((first_side_start > EPSILON and first_side_end < -EPSILON)
		or (first_side_start < -EPSILON and first_side_end > EPSILON))
		and ((second_side_start > EPSILON and second_side_end < -EPSILON)
		or (second_side_start < -EPSILON and second_side_end > EPSILON))
	):
		return true

	if absf(first_side_start) <= EPSILON and _point_on_segment(
		second_start, first_start, first_end
	):
		return true
	if absf(first_side_end) <= EPSILON and _point_on_segment(
		second_end, first_start, first_end
	):
		return true
	if absf(second_side_start) <= EPSILON and _point_on_segment(
		first_start, second_start, second_end
	):
		return true
	if absf(second_side_end) <= EPSILON and _point_on_segment(
		first_end, second_start, second_end
	):
		return true
	return false


static func _is_supported_index_collection(indices: Variant) -> bool:
	return (
		indices is Array
		or indices is PackedInt32Array
		or indices is PackedInt64Array
	)
