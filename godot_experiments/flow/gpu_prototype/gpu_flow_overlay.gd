extends Node2D

const STAGE_SIZE := Vector2(1920.0, 1080.0)
const RESERVOIR_CENTER := Vector2(1388.57, 771.43)
const RESERVOIR_RADIUS := 223.71

var stage_index: int = 0
var gate_open: bool = true
var gate_half_width: float = 15.0
var reservoir_center: Vector2 = RESERVOIR_CENTER
var reservoir_radius: float = RESERVOIR_RADIUS
var reservoir_visible: bool = true
var drain_visible: bool = true
var obstacle_visible: bool = true
var show_status_label: bool = true
var interaction_polygons: Array[Dictionary] = []
var shoreline_obstacles: Array[Dictionary] = []
var source_polygons: Array[Dictionary] = []


func set_gate_open(value: bool) -> void:
	gate_open = value
	queue_redraw()


func set_gate_half_width(value: float) -> void:
	gate_half_width = value
	queue_redraw()


func set_reservoir_geometry(center: Vector2, radius: float) -> void:
	reservoir_center = center
	reservoir_radius = maxf(radius, 1.0)
	queue_redraw()


func set_feature_visibility(
	show_reservoir: bool,
	show_drains: bool,
	show_obstacles: bool,
) -> void:
	reservoir_visible = show_reservoir
	drain_visible = show_drains
	obstacle_visible = show_obstacles
	queue_redraw()


func is_reservoir_visible() -> bool:
	return reservoir_visible


func get_visible_interaction_polygon_count() -> int:
	var visible_count := 0
	for definition: Dictionary in interaction_polygons:
		match String(definition.get("mode", "")):
			"absorb":
				if drain_visible:
					visible_count += 1
			"repel":
				if obstacle_visible:
					visible_count += 1
	return visible_count


func set_interaction_polygons(definitions: Array[Dictionary]) -> void:
	interaction_polygons = definitions.duplicate(true)
	queue_redraw()


func set_shoreline_obstacles(definitions: Array[Dictionary]) -> void:
	shoreline_obstacles = definitions.duplicate(true)
	queue_redraw()


func set_source_polygons(definitions: Array[Dictionary]) -> void:
	source_polygons = definitions.duplicate(true)
	queue_redraw()


func get_interaction_polygon_count() -> int:
	return interaction_polygons.size()


func get_shoreline_obstacle_count() -> int:
	return shoreline_obstacles.size()


func get_source_polygon_count() -> int:
	return source_polygons.size()


func _draw() -> void:
	if reservoir_visible:
		_draw_reservoir()
	_draw_interaction_polygons()
	_draw_shoreline_obstacles()
	_draw_source_polygons()
	draw_rect(Rect2(Vector2.ZERO, STAGE_SIZE), Color("1f3642"), false, 2.0)
	if not show_status_label:
		return
	var label := "GPU STAGE %d · 300 SLOTS / ~150 ACTIVE · 30 HZ · GATE %s / %.0f PX" % [
		stage_index + 1,
		"OPEN" if gate_open else "CLOSED",
		gate_half_width * 2.0,
	]
	draw_string(
		ThemeDB.fallback_font,
		Vector2(36.0, 54.0),
		label,
		HORIZONTAL_ALIGNMENT_LEFT,
		-1.0,
		24,
		Color("d1edf4")
	)


func _draw_interaction_polygons() -> void:
	var outline_color := Color("d4af37")
	for definition: Dictionary in interaction_polygons:
		match String(definition.get("mode", "")):
			"absorb":
				if not drain_visible:
					continue
			"repel":
				if not obstacle_visible:
					continue
		var vertices_variant: Variant = definition.get("vertices", PackedVector2Array())
		if not vertices_variant is PackedVector2Array:
			continue
		var vertices: PackedVector2Array = vertices_variant
		if vertices.size() < 3:
			continue
		var closed_vertices := vertices.duplicate()
		closed_vertices.append(vertices[0])
		var color := outline_color
		if not bool(definition.get("enabled", true)):
			color.a *= 0.35
		draw_polyline(closed_vertices, color, 4.0, true)


func _draw_shoreline_obstacles() -> void:
	var outline_color := Color("d4af37")
	for definition: Dictionary in shoreline_obstacles:
		var vertices_variant: Variant = definition.get(
			"vertices", PackedVector2Array()
		)
		if not vertices_variant is PackedVector2Array:
			continue
		var vertices: PackedVector2Array = vertices_variant
		if vertices.size() < 2:
			continue
		var color := outline_color
		var weight := clampf(float(definition.get("weight", 0.0)), 0.0, 1.0)
		color.a *= 0.35 + 0.65 * weight
		# Only the water-facing edge is visible. The offscreen land closure is
		# deliberately absent so debug drawing matches the segments used by physics.
		draw_polyline(vertices, color, 4.0, true)


func _draw_source_polygons() -> void:
	# Violet distinguishes sources from gold interactions and the cyan reservoir.
	var outline_color := Color(0.78039216, 0.49019608, 1.0, 1.0)
	for definition: Dictionary in source_polygons:
		var vertices_variant: Variant = definition.get(
			"vertices", PackedVector2Array()
		)
		if not vertices_variant is PackedVector2Array:
			continue
		var vertices: PackedVector2Array = vertices_variant
		if vertices.size() < 3:
			continue
		var color := outline_color
		if not bool(definition.get("enabled", true)):
			color.a *= 0.35
		var closed_vertices := vertices.duplicate()
		closed_vertices.append(vertices[0])
		draw_polyline(closed_vertices, color, 4.0, true)
		var edges_variant: Variant = definition.get("downstream_edges", [])
		if not edges_variant is Array:
			continue
		for edge_variant: Variant in edges_variant:
			if not edge_variant is Dictionary:
				continue
			_draw_source_edge_marker(edge_variant, color)


func _draw_source_edge_marker(edge: Dictionary, color: Color) -> void:
	var start_variant: Variant = edge.get("start")
	var end_variant: Variant = edge.get("end")
	var normal_variant: Variant = edge.get("outward_normal")
	if (
		not start_variant is Vector2
		or not end_variant is Vector2
		or not normal_variant is Vector2
	):
		return
	var start: Vector2 = start_variant
	var end: Vector2 = end_variant
	var outward: Vector2 = normal_variant
	if outward.length_squared() <= 0.000000000001:
		return
	outward = outward.normalized()
	var tangent := Vector2(-outward.y, outward.x)
	var midpoint := start.lerp(end, 0.5)
	var tick_start := midpoint - outward * 2.0
	var tip := midpoint + outward * 13.0
	var arrow_base := tip - outward * 5.0
	draw_line(tick_start, tip, color, 3.0, true)
	draw_line(tip, arrow_base + tangent * 3.5, color, 3.0, true)
	draw_line(tip, arrow_base - tangent * 3.5, color, 3.0, true)


func _draw_reservoir() -> void:
	var wall_color := Color(0.22, 0.76, 0.92, 0.90)
	var opening_angle := 0.30
	# Do not visually saturate below a truly full aperture. The previous 0.95
	# clamp made a 95%-open gate look indistinguishable from the 100% hard drain.
	var gate_angle := asin(clampf(gate_half_width / reservoir_radius, 0.0, 1.0))
	# Leave an upstream opening around PI and a downstream gate around zero.
	draw_arc(
		reservoir_center,
		reservoir_radius,
		gate_angle,
		PI - opening_angle,
		96,
		wall_color,
		5.0,
		true
	)
	draw_arc(
		reservoir_center,
		reservoir_radius,
		PI + opening_angle,
		TAU - gate_angle,
		96,
		wall_color,
		5.0,
		true
	)
	if not gate_open:
		draw_arc(
			reservoir_center,
			reservoir_radius,
			-gate_angle,
			gate_angle,
			12,
			Color("ffae57"),
			9.0,
			true
		)
	else:
		var marker_half_width := clampf(gate_half_width, 0.0, reservoir_radius)
		# The bars mark the endpoints of the actual circular chord. Keeping them at
		# center.x + radius put full-width markers a radius outside the arc endpoints.
		var gate_x := reservoir_center.x + sqrt(maxf(
			reservoir_radius * reservoir_radius
			- marker_half_width * marker_half_width,
			0.0
		))
		draw_line(
			Vector2(gate_x - 8.0, reservoir_center.y - marker_half_width),
			Vector2(gate_x + 20.0, reservoir_center.y - marker_half_width),
			Color("69df9a"),
			5.0
		)
		draw_line(
			Vector2(gate_x - 8.0, reservoir_center.y + marker_half_width),
			Vector2(gate_x + 20.0, reservoir_center.y + marker_half_width),
			Color("69df9a"),
			5.0
		)
