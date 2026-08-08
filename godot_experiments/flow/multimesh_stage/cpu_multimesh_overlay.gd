class_name CPUMultiMeshOverlay
extends Node2D

## Native-coordinate debug geometry for the CPU-head + MultiMesh stage.
##
## This node performs no model/world conversion. All vertices, reservoir
## geometry, downstream edge endpoints, outward normals, and gate widths must
## already be expressed in the same native 1920 x 1080 coordinate system.
## Debug visibility is owned exclusively by CanvasItem.visible.

const STAGE_SIZE := Vector2(1920.0, 1080.0)
const DEFAULT_RESERVOIR_CENTER := Vector2(1388.57, 771.43)
const DEFAULT_RESERVOIR_RADIUS := 223.71
const MIN_RESERVOIR_RADIUS := 1.0
const UPSTREAM_OPENING_ANGLE := 0.30

# #D4AF37, retained exactly from the approved interaction overlay.
const INTERACTION_COLOR := Color(0.83137255, 0.68627451, 0.21568627, 1.0)
# Violet is distinct from the cyan reservoir, green/orange gate, gold
# interactions, and the blue/green water palette.
const SOURCE_COLOR := Color(0.78039216, 0.49019608, 1.0, 1.0)
const RESERVOIR_COLOR := Color(0.22, 0.76, 0.92, 0.90)
const CLOSED_GATE_COLOR := Color(1.0, 0.68235294, 0.34117647, 1.0)
const OPEN_GATE_COLOR := Color(0.41176471, 0.87450980, 0.60392157, 1.0)

const POLYGON_LINE_WIDTH := 4.0
const RESERVOIR_LINE_WIDTH := 5.0
const CLOSED_GATE_LINE_WIDTH := 9.0
const OPEN_GATE_LINE_WIDTH := 5.0
const DISABLED_ALPHA_MULTIPLIER := 0.35
const SOURCE_TICK_INSET := 2.0
const SOURCE_TICK_LENGTH := 13.0
const SOURCE_ARROW_BACK_LENGTH := 5.0
const SOURCE_ARROW_HALF_WIDTH := 3.5
const SOURCE_MARKER_LINE_WIDTH := 3.0

var reservoir_center: Vector2 = DEFAULT_RESERVOIR_CENTER
var reservoir_radius: float = DEFAULT_RESERVOIR_RADIUS
var gate_open: bool = true
var gate_half_width: float = 15.0

var _interaction_polygons: Array[Dictionary] = []
var _source_polygons: Array[Dictionary] = []


func set_reservoir_geometry(center: Vector2, radius: float) -> void:
	if (
		not is_finite(center.x)
		or not is_finite(center.y)
		or not is_finite(radius)
	):
		return
	reservoir_center = center
	reservoir_radius = maxf(radius, MIN_RESERVOIR_RADIUS)
	queue_redraw()


func set_gate(open: bool, half_width: float) -> void:
	if not is_finite(half_width):
		return
	gate_open = open
	gate_half_width = maxf(half_width, 0.0)
	queue_redraw()


func set_interaction_polygons(definitions: Array[Dictionary]) -> void:
	var copied_definitions: Array[Dictionary] = []
	for definition: Dictionary in definitions:
		var vertices := _vertices_from_variant(
			definition.get("vertices", PackedVector2Array())
		)
		if vertices.size() < 3:
			continue
		copied_definitions.append({
			"vertices": vertices,
			"enabled": bool(definition.get("enabled", true)),
		})
	_interaction_polygons = copied_definitions
	queue_redraw()


func set_source_polygons(definitions: Array[Dictionary]) -> void:
	## downstream_edges accepts the native-coordinate dictionaries returned by
	## CPUFlowSourcePolygon.selected_downstream_edges() after caller conversion.
	## edge_index + outward_normal is sufficient; explicit start/end is also
	## accepted when edge_index is unavailable.
	var copied_definitions: Array[Dictionary] = []
	for definition: Dictionary in definitions:
		var vertices := _vertices_from_variant(
			definition.get("vertices", PackedVector2Array())
		)
		if vertices.size() < 3:
			continue
		var downstream_value: Variant = definition.get(
			"downstream_edges",
			definition.get("selected_downstream_edges", []),
		)
		var downstream_edges := _copy_downstream_edges(
			downstream_value,
			vertices,
		)
		copied_definitions.append({
			"vertices": vertices,
			"enabled": bool(definition.get("enabled", true)),
			"downstream_edges": downstream_edges,
		})
	_source_polygons = copied_definitions
	queue_redraw()


func get_interaction_polygon_count() -> int:
	return _interaction_polygons.size()


func get_source_polygon_count() -> int:
	return _source_polygons.size()


func _draw() -> void:
	_draw_reservoir()
	_draw_interaction_polygons()
	_draw_source_polygons()


func _draw_reservoir() -> void:
	# Match the approved GPU overlay: an upstream opening around PI and the
	# controlled downstream gate around zero.
	var marker_half_width := clampf(
		gate_half_width,
		0.0,
		reservoir_radius,
	)
	var gate_angle := asin(clampf(
		marker_half_width / reservoir_radius,
		0.0,
		1.0,
	))
	draw_arc(
		reservoir_center,
		reservoir_radius,
		gate_angle,
		PI - UPSTREAM_OPENING_ANGLE,
		96,
		RESERVOIR_COLOR,
		RESERVOIR_LINE_WIDTH,
		true,
	)
	draw_arc(
		reservoir_center,
		reservoir_radius,
		PI + UPSTREAM_OPENING_ANGLE,
		TAU - gate_angle,
		96,
		RESERVOIR_COLOR,
		RESERVOIR_LINE_WIDTH,
		true,
	)
	if not gate_open:
		draw_arc(
			reservoir_center,
			reservoir_radius,
			-gate_angle,
			gate_angle,
			12,
			CLOSED_GATE_COLOR,
			CLOSED_GATE_LINE_WIDTH,
			true,
		)
		return

	var gate_x := reservoir_center.x + sqrt(maxf(
		reservoir_radius * reservoir_radius
		- marker_half_width * marker_half_width,
		0.0,
	))
	draw_line(
		Vector2(gate_x - 8.0, reservoir_center.y - marker_half_width),
		Vector2(gate_x + 20.0, reservoir_center.y - marker_half_width),
		OPEN_GATE_COLOR,
		OPEN_GATE_LINE_WIDTH,
		true,
	)
	draw_line(
		Vector2(gate_x - 8.0, reservoir_center.y + marker_half_width),
		Vector2(gate_x + 20.0, reservoir_center.y + marker_half_width),
		OPEN_GATE_COLOR,
		OPEN_GATE_LINE_WIDTH,
		true,
	)


func _draw_interaction_polygons() -> void:
	for definition: Dictionary in _interaction_polygons:
		var vertices: PackedVector2Array = definition["vertices"]
		var color := _enabled_color(
			INTERACTION_COLOR,
			bool(definition["enabled"]),
		)
		_draw_closed_polygon(vertices, color)


func _draw_source_polygons() -> void:
	for definition: Dictionary in _source_polygons:
		var vertices: PackedVector2Array = definition["vertices"]
		var color := _enabled_color(
			SOURCE_COLOR,
			bool(definition["enabled"]),
		)
		_draw_closed_polygon(vertices, color)
		var edges_value: Variant = definition["downstream_edges"]
		if not edges_value is Array:
			continue
		for edge_value: Variant in edges_value:
			if not edge_value is Dictionary:
				continue
			var edge_info: Dictionary = edge_value
			_draw_source_edge_marker(edge_info, color)


func _draw_closed_polygon(
	vertices: PackedVector2Array,
	color: Color,
) -> void:
	if vertices.size() < 3:
		return
	var closed_vertices := vertices.duplicate()
	closed_vertices.append(vertices[0])
	draw_polyline(
		closed_vertices,
		color,
		POLYGON_LINE_WIDTH,
		true,
	)


func _draw_source_edge_marker(edge_info: Dictionary, color: Color) -> void:
	var start: Vector2 = edge_info["start"]
	var end: Vector2 = edge_info["end"]
	var outward_normal: Vector2 = edge_info["outward_normal"]
	if outward_normal.length_squared() <= 0.000000000001:
		return
	outward_normal = outward_normal.normalized()
	var tangent := Vector2(-outward_normal.y, outward_normal.x)
	var midpoint := start.lerp(end, 0.5)
	var tick_start := midpoint - outward_normal * SOURCE_TICK_INSET
	var tip := midpoint + outward_normal * SOURCE_TICK_LENGTH
	var arrow_base := tip - outward_normal * SOURCE_ARROW_BACK_LENGTH
	draw_line(
		tick_start,
		tip,
		color,
		SOURCE_MARKER_LINE_WIDTH,
		true,
	)
	draw_line(
		tip,
		arrow_base + tangent * SOURCE_ARROW_HALF_WIDTH,
		color,
		SOURCE_MARKER_LINE_WIDTH,
		true,
	)
	draw_line(
		tip,
		arrow_base - tangent * SOURCE_ARROW_HALF_WIDTH,
		color,
		SOURCE_MARKER_LINE_WIDTH,
		true,
	)


static func _copy_downstream_edges(
	value: Variant,
	vertices: PackedVector2Array,
) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if not value is Array:
		return result
	for raw_edge: Variant in value:
		if not raw_edge is Dictionary:
			continue
		var edge: Dictionary = raw_edge
		var edge_index := _integral_index(edge.get("edge_index", -1))
		var start_variant: Variant = null
		var end_variant: Variant = null
		if edge_index >= 0 and edge_index < vertices.size():
			start_variant = vertices[edge_index]
			end_variant = vertices[(edge_index + 1) % vertices.size()]
		else:
			start_variant = _vector_from_variant(edge.get("start", null))
			end_variant = _vector_from_variant(edge.get("end", null))
		var normal_variant: Variant = _vector_from_variant(
			edge.get("outward_normal", null)
		)
		if start_variant == null or end_variant == null or normal_variant == null:
			continue
		var start: Vector2 = start_variant
		var end: Vector2 = end_variant
		var outward_normal: Vector2 = normal_variant
		if outward_normal.length_squared() <= 0.000000000001:
			continue
		result.append({
			"edge_index": edge_index,
			"start": start,
			"end": end,
			"outward_normal": outward_normal.normalized(),
		})
	return result


static func _vertices_from_variant(value: Variant) -> PackedVector2Array:
	if value is PackedVector2Array:
		var packed: PackedVector2Array = value
		return packed.duplicate()
	if not value is Array:
		return PackedVector2Array()
	var result := PackedVector2Array()
	for raw_point: Variant in value:
		var point: Variant = _vector_from_variant(raw_point)
		if point == null:
			return PackedVector2Array()
		result.append(point)
	return result


static func _vector_from_variant(value: Variant) -> Variant:
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


static func _integral_index(value: Variant) -> int:
	if not _is_finite_number(value):
		return -1
	var numeric_value := float(value)
	if numeric_value != floor(numeric_value):
		return -1
	return int(numeric_value)


static func _is_finite_number(value: Variant) -> bool:
	return (
		typeof(value) == TYPE_INT or typeof(value) == TYPE_FLOAT
	) and is_finite(float(value))


static func _enabled_color(color: Color, enabled: bool) -> Color:
	if enabled:
		return color
	var disabled_color := color
	disabled_color.a *= DISABLED_ALPHA_MULTIPLIER
	return disabled_color
