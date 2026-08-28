extends Node2D

const STAGE_SIZE := Vector2(1920.0, 1080.0)
const RESERVOIR_CENTER := Vector2(1388.57, 771.43)
const RESERVOIR_RADIUS := 223.71
const TYPE_ROTATION_RADIANS := -PI * 0.5
const HATCH_LINE_WIDTH_PIXELS := 3.0
const HATCH_GAP_PIXELS := 6.0
const HATCH_ALPHA := 0.33
const HATCH_PERIOD_PIXELS := HATCH_LINE_WIDTH_PIXELS + HATCH_GAP_PIXELS
const HATCH_AXIS_SCALE := 1.4142135623730951
const LABEL_FONT_SIZE := 24
const LABEL_AVAILABLE_HEIGHT_RATIO := 0.70
const LABEL_HATCH_CLEARANCE_PIXELS := 6.0
const BLUE := Color("4ab0e1")
const FIELD_GREEN := Color("6fbf73")
const GOLD := Color("d4af37")

var stage_index: int = 0
var gate_open: bool = true
var gate_half_width: float = 15.0
var reservoir_center: Vector2 = RESERVOIR_CENTER
var reservoir_radius: float = RESERVOIR_RADIUS
var reservoir_visible: bool = true
var drain_visible: bool = true
var obstacle_visible: bool = true
var show_status_label: bool = true
var data_center_color: Color = Color("ff0000")
var interaction_polygons: Array[Dictionary] = []
var shoreline_obstacles: Array[Dictionary] = []


func set_gate_open(value: bool) -> void:
	if gate_open == value:
		return
	gate_open = value
	queue_redraw()


func set_gate_half_width(value: float) -> void:
	if is_equal_approx(gate_half_width, value):
		return
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
	if (
		reservoir_visible == show_reservoir
		and drain_visible == show_drains
		and obstacle_visible == show_obstacles
	):
		return
	reservoir_visible = show_reservoir
	drain_visible = show_drains
	obstacle_visible = show_obstacles
	queue_redraw()


func set_data_center_color(value: Color) -> void:
	var next_color := Color(value.r, value.g, value.b, 1.0)
	if data_center_color.is_equal_approx(next_color):
		return
	data_center_color = next_color
	queue_redraw()


func is_reservoir_visible() -> bool:
	return reservoir_visible


func get_visible_interaction_polygon_count() -> int:
	var visible_count := 0
	for definition: Dictionary in interaction_polygons:
		if not bool(definition.get("enabled", true)):
			continue
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


func get_interaction_polygon_count() -> int:
	return interaction_polygons.size()


func get_shoreline_obstacle_count() -> int:
	return shoreline_obstacles.size()


func _draw() -> void:
	if reservoir_visible:
		_draw_reservoir()
	_draw_interaction_polygons()
	_draw_shoreline_obstacles()
	if not show_status_label:
		return
	var label := "GPU STAGE %d · 300 SLOTS / ~150 ACTIVE · 30 HZ · GATE %s / %.0f PX" % [
		stage_index + 1,
		"OPEN" if gate_open else "CLOSED",
		gate_half_width * 2.0,
	]
	draw_set_transform(Vector2(54.0, 1040.0), TYPE_ROTATION_RADIANS, Vector2.ONE)
	draw_string(
		ThemeDB.fallback_font,
		Vector2.ZERO,
		label,
		HORIZONTAL_ALIGNMENT_LEFT,
		-1.0,
		24,
		Color("d1edf4")
	)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


func _draw_interaction_polygons() -> void:
	for definition: Dictionary in interaction_polygons:
		if not bool(definition.get("enabled", true)):
			continue
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
		var bounds := _polygon_bounds(vertices)
		var visual_kind := String(definition.get("visual_kind", ""))
		var color := _geometry_color(visual_kind, String(definition.get("mode", "")))
		var label := String(definition.get("label", ""))
		var label_text_rect := (
			_vertical_label_text_rect(bounds, label)
			if not label.is_empty()
			else Rect2()
		)
		_draw_hatched_rect(bounds, color, label_text_rect)
		if not label.is_empty():
			_draw_vertical_label(bounds, label, color)


func _draw_shoreline_obstacles() -> void:
	for definition: Dictionary in shoreline_obstacles:
		var vertices_variant: Variant = definition.get(
			"vertices", PackedVector2Array()
		)
		if not vertices_variant is PackedVector2Array:
			continue
		var vertices: PackedVector2Array = vertices_variant
		if vertices.size() < 2:
			continue
		var color := GOLD
		var weight := clampf(float(definition.get("weight", 0.0)), 0.0, 1.0)
		color.a *= 0.35 + 0.65 * weight
		_draw_hatched_rect(_polygon_bounds(vertices), color)


func _draw_reservoir() -> void:
	var bounds := Rect2(
		reservoir_center - Vector2.ONE * reservoir_radius,
		Vector2.ONE * reservoir_radius * 2.0,
	)
	_draw_hatched_rect(
		bounds,
		BLUE,
		_vertical_label_text_rect(bounds, "RESERVOIR"),
	)
	_draw_vertical_label(bounds, "RESERVOIR", BLUE)


func _draw_hatched_rect(
	rectangle: Rect2,
	color: Color,
	label_text_rect: Rect2 = Rect2(),
) -> void:
	if rectangle.size.x <= 0.0 or rectangle.size.y <= 0.0:
		return
	var hatch_color := color
	hatch_color.a = HATCH_ALPHA
	var step := HATCH_PERIOD_PIXELS * HATCH_AXIS_SCALE
	var x := floorf(
		(rectangle.position.x - rectangle.size.y) / step
	) * step
	while x <= rectangle.end.x + step:
		var start := Vector2(x, rectangle.end.y)
		var finish := Vector2(x + rectangle.size.y, rectangle.position.y)
		# Clip the fixed global hatch lattice to the live rectangle. As an
		# extractor widens, existing diagonals extend at its edge instead of
		# drawing outside the region or swimming with the animated bounds.
		var clipped_segment := _clipped_segment_to_rect(
			start,
			finish,
			rectangle,
		)
		if clipped_segment.size() != 2:
			x += step
			continue
		_draw_capped_line_around_label(
			clipped_segment[0],
			clipped_segment[1],
			hatch_color,
			HATCH_LINE_WIDTH_PIXELS,
			label_text_rect,
		)
		x += step


func _clipped_segment_to_rect(
	start: Vector2,
	finish: Vector2,
	rectangle: Rect2,
) -> PackedVector2Array:
	var interval := _segment_rect_interval(start, finish, rectangle)
	if interval.x < 0.0:
		return PackedVector2Array()
	return PackedVector2Array([
		start.lerp(finish, interval.x),
		start.lerp(finish, interval.y),
	])


func _draw_capped_line_around_label(
	start: Vector2,
	finish: Vector2,
	color: Color,
	width: float,
	label_text_rect: Rect2,
) -> void:
	if label_text_rect.size.x <= 0.0 or label_text_rect.size.y <= 0.0:
		_draw_capped_line(start, finish, color, width)
		return
	var exclusion := label_text_rect.grow(
		LABEL_HATCH_CLEARANCE_PIXELS + width * 0.5
	)
	var interval := _segment_rect_interval(start, finish, exclusion)
	if interval.x < 0.0:
		_draw_capped_line(start, finish, color, width)
		return
	if interval.x > 0.0001:
		_draw_capped_line(start, start.lerp(finish, interval.x), color, width)
	if interval.y < 0.9999:
		_draw_capped_line(start.lerp(finish, interval.y), finish, color, width)


func _segment_rect_interval(start: Vector2, finish: Vector2, rectangle: Rect2) -> Vector2:
	var enter := 0.0
	var exit := 1.0
	var delta := finish - start
	for axis in range(2):
		var start_value := start.x if axis == 0 else start.y
		var delta_value := delta.x if axis == 0 else delta.y
		var minimum := rectangle.position.x if axis == 0 else rectangle.position.y
		var maximum := rectangle.end.x if axis == 0 else rectangle.end.y
		if is_zero_approx(delta_value):
			if start_value < minimum or start_value > maximum:
				return Vector2(-1.0, -1.0)
			continue
		var first := (minimum - start_value) / delta_value
		var second := (maximum - start_value) / delta_value
		if first > second:
			var swap := first
			first = second
			second = swap
		enter = maxf(enter, first)
		exit = minf(exit, second)
		if enter >= exit:
			return Vector2(-1.0, -1.0)
	return Vector2(enter, exit)


func _draw_capped_line(
	start: Vector2,
	finish: Vector2,
	color: Color,
	width: float,
) -> void:
	draw_line(start, finish, color, width, true)
	var radius := width * 0.5
	draw_circle(start, radius, color, true)
	draw_circle(finish, radius, color, true)


func _polygon_bounds(vertices: PackedVector2Array) -> Rect2:
	var minimum := vertices[0]
	var maximum := vertices[0]
	for vertex: Vector2 in vertices:
		minimum = minimum.min(vertex)
		maximum = maximum.max(vertex)
	return Rect2(minimum, maximum - minimum)


func _geometry_color(visual_kind: String, mode: String) -> Color:
	match visual_kind:
		"data_center":
			return data_center_color
		"field":
			return FIELD_GREEN
		"water_project":
			return BLUE
		"mine":
			return GOLD
	return FIELD_GREEN if mode == "absorb" else GOLD


func _draw_vertical_label(bounds: Rect2, text: String, color: Color) -> void:
	var anchor := bounds.get_center() + Vector2(0.0, bounds.size.y * 0.35)
	draw_set_transform(anchor, TYPE_ROTATION_RADIANS, Vector2.ONE)
	draw_string(
		ThemeDB.fallback_font,
		Vector2.ZERO,
		text,
		HORIZONTAL_ALIGNMENT_CENTER,
		bounds.size.y * LABEL_AVAILABLE_HEIGHT_RATIO,
		LABEL_FONT_SIZE,
		color,
	)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


func _vertical_label_text_rect(bounds: Rect2, text: String) -> Rect2:
	if text.is_empty():
		return Rect2()
	var font := ThemeDB.fallback_font
	var available_height := bounds.size.y * LABEL_AVAILABLE_HEIGHT_RATIO
	var text_width := minf(
		font.get_string_size(
			text,
			HORIZONTAL_ALIGNMENT_LEFT,
			-1.0,
			LABEL_FONT_SIZE,
		).x,
		available_height,
	)
	var local_text_start := (available_height - text_width) * 0.5
	var anchor := bounds.get_center() + Vector2(0.0, bounds.size.y * 0.35)
	var font_ascent := font.get_ascent(LABEL_FONT_SIZE)
	var font_descent := font.get_descent(LABEL_FONT_SIZE)
	return Rect2(
		Vector2(
			anchor.x - font_ascent,
			anchor.y - local_text_start - text_width,
		),
		Vector2(font_ascent + font_descent, text_width),
	)
