class_name BasinBudgetOverlay
extends Node2D

## Screen-space visualization of the basin budget and regime extractors.

const STAGE_SIZE := Vector2(1920.0, 1080.0)
const FONT := preload("res://flow/assets/fonts/BarlowCondensed-Medium.ttf")

const BLUE := Color("4ab0e1")
const WHITE := Color(1.0, 1.0, 1.0, 0.95)
const TYPE_ROTATION_RADIANS := -PI * 0.5
const HATCH_LINE_WIDTH_PIXELS := 3.0
const HATCH_GAP_PIXELS := 6.0
const HATCH_ALPHA := 0.33
const HATCH_PERIOD_PIXELS := HATCH_LINE_WIDTH_PIXELS + HATCH_GAP_PIXELS
const HATCH_AXIS_SCALE := 1.4142135623730951
const LABEL_HATCH_CLEARANCE_PIXELS := 6.0
const TIDE_HATCH_LINE_WIDTH_PIXELS := 3.0
const TIDE_HATCH_GAP_PIXELS := 6.0
const TIDE_HATCH_ALPHA := 0.20
const TIDE_HATCH_PERIOD_PIXELS := (
	TIDE_HATCH_LINE_WIDTH_PIXELS + TIDE_HATCH_GAP_PIXELS
)
const TIDE_FIRST_HATCH_Y := TIDE_HATCH_PERIOD_PIXELS * 0.5
const TIDE_HATCH_LINE_COUNT := 120
const TIDE_WINDOW_HOURS := 96.0
const TIDE_WINDOW_HALF_HOURS := TIDE_WINDOW_HOURS * 0.5
const TIDE_WINDOW_SAMPLE_COUNT := 97
const TIDE_LINE_MIN_LENGTH_PIXELS := 40.8
const TIDE_LINE_MAX_LENGTH_PIXELS := 306.0
const KINSHIP_FLOOD_LABEL := "KINSHIP FLOODPLAIN"
const KINSHIP_FLOOD_LABEL_ANCHOR := Vector2(690.0, 860.0)
const KINSHIP_FLOOD_LABEL_FONT_SIZE := 34
const WATERSHED_REGIME_INDEX := 6

var screen_id: StringName = &"screen"
var input_rate: float = 0.0
var extraction_fraction: float = 0.0
var remaining_rate: float = 0.0
var active_states: Array = []
var tide_series := PackedFloat32Array()
var tide_sample_position: float = 0.0
var tide_fifo_values: Array[float] = []
var render_tide: bool = true
var render_floodplain: bool = true
var render_budget: bool = true
var watershed_allocation_state: Dictionary = {}
var _tabular_font: FontVariation


func _ready() -> void:
	_tabular_font = FontVariation.new()
	_tabular_font.base_font = FONT
	_tabular_font.opentype_features = {
		TextServerManager.get_primary_interface().name_to_tag("tnum"): 1,
	}


func set_render_roles(
	p_render_tide: bool,
	p_render_floodplain: bool,
	p_render_budget: bool,
) -> void:
	render_tide = p_render_tide
	render_floodplain = p_render_floodplain
	render_budget = p_render_budget
	queue_redraw()


func configure(
	p_screen_id: StringName,
	p_input_rate: float,
	p_extraction_fraction: float,
	p_remaining_rate: float,
	p_active_states: Array,
	p_tide_series: PackedFloat32Array,
	p_tide_sample_position: float,
	p_watershed_allocation_state: Dictionary = {},
) -> void:
	screen_id = p_screen_id
	input_rate = clampf(p_input_rate, 0.0, 1.0)
	extraction_fraction = clampf(p_extraction_fraction, 0.0, 1.0)
	remaining_rate = clampf(p_remaining_rate, 0.0, 1.0)
	active_states = p_active_states.duplicate()
	watershed_allocation_state = p_watershed_allocation_state.duplicate(true)
	if render_tide:
		_update_tide_fifo(p_tide_series, p_tide_sample_position)
	queue_redraw()


func _draw() -> void:
	if screen_id == &"delta":
		if render_floodplain and _regime_active(0):
			_draw_floodplain(KINSHIP_FLOOD_LABEL, 0.25)
		elif (
			render_floodplain
			and float(watershed_allocation_state.get(
				"floodplain_fraction",
				0.0,
			)) > 0.000001
		):
			_draw_floodplain(
				"FLOODPLAIN",
				float(watershed_allocation_state["floodplain_fraction"]),
			)
		if render_tide:
			_draw_incoming_tide()
		if render_budget:
			_draw_budget_panel()


func _draw_floodplain(label: String, allocation_fraction: float) -> void:
	var flood_color := BLUE
	flood_color.a = HATCH_ALPHA
	var base_polygon := PackedVector2Array([
		Vector2(250.0, 330.0),
		Vector2(610.0, 245.0),
		Vector2(1050.0, 285.0),
		Vector2(1515.0, 510.0),
		Vector2(1600.0, 790.0),
		Vector2(1260.0, 970.0),
		Vector2(660.0, 920.0),
		Vector2(285.0, 715.0),
	])
	var center := Vector2.ZERO
	for vertex: Vector2 in base_polygon:
		center += vertex
	center /= float(base_polygon.size())
	var area_scale := clampf(
		sqrt(clampf(allocation_fraction, 0.0, 1.0) / 0.25),
		0.45,
		1.35,
	)
	var flood_polygon := PackedVector2Array()
	for vertex: Vector2 in base_polygon:
		flood_polygon.append(center + (vertex - center) * area_scale)
	_draw_hatched_polygon(
		flood_polygon,
		flood_color,
		_vertical_text_rect(
			KINSHIP_FLOOD_LABEL_ANCHOR,
			label,
			KINSHIP_FLOOD_LABEL_FONT_SIZE,
		),
	)
	_draw_vertical_text(
		KINSHIP_FLOOD_LABEL_ANCHOR,
		label,
		-1.0,
		KINSHIP_FLOOD_LABEL_FONT_SIZE,
		Color(BLUE, 0.92),
	)


func _draw_hatched_polygon(
	polygon: PackedVector2Array,
	color: Color,
	label_text_rect: Rect2,
) -> void:
	if polygon.size() < 3:
		return
	var hatch_color := color
	hatch_color.a = HATCH_ALPHA
	var minimum_sum := INF
	var maximum_sum := -INF
	for vertex: Vector2 in polygon:
		var diagonal_sum := vertex.x + vertex.y
		minimum_sum = minf(minimum_sum, diagonal_sum)
		maximum_sum = maxf(maximum_sum, diagonal_sum)
	var step := HATCH_PERIOD_PIXELS * HATCH_AXIS_SCALE
	var diagonal_sum := floorf(minimum_sum / step) * step
	while diagonal_sum <= maximum_sum + step:
		var intersections := PackedVector2Array()
		for vertex_index in range(polygon.size()):
			var start: Vector2 = polygon[vertex_index]
			var finish: Vector2 = polygon[(vertex_index + 1) % polygon.size()]
			var start_sum := start.x + start.y
			var finish_sum := finish.x + finish.y
			var sum_delta := finish_sum - start_sum
			if is_zero_approx(sum_delta):
				continue
			var edge_fraction := (diagonal_sum - start_sum) / sum_delta
			if edge_fraction >= 0.0 and edge_fraction < 1.0:
				intersections.append(start.lerp(finish, edge_fraction))
		if intersections.size() >= 2:
			var line_start := intersections[0]
			var line_finish := intersections[0]
			for intersection: Vector2 in intersections:
				if intersection.x < line_start.x:
					line_start = intersection
				if intersection.x > line_finish.x:
					line_finish = intersection
			_draw_capped_line_around_label(
				line_start,
				line_finish,
				hatch_color,
				HATCH_LINE_WIDTH_PIXELS,
				label_text_rect,
			)
		diagonal_sum += step


func _draw_capped_line_around_label(
	start: Vector2,
	finish: Vector2,
	color: Color,
	width: float,
	label_text_rect: Rect2,
) -> void:
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


func _draw_incoming_tide() -> void:
	if tide_series.is_empty() or tide_fifo_values.size() != TIDE_WINDOW_SAMPLE_COUNT:
		return
	_draw_horizontal_hatched_tide_polygon(_tide_area_polygon())


func _tide_area_polygon() -> PackedVector2Array:
	var polygon := PackedVector2Array([Vector2(STAGE_SIZE.x, 0.0)])
	for sample_index in range(TIDE_WINDOW_SAMPLE_COUNT):
		var sample_fraction := float(sample_index) / float(
			TIDE_WINDOW_SAMPLE_COUNT - 1
		)
		polygon.append(Vector2(
			STAGE_SIZE.x - _tide_line_length(tide_fifo_values[sample_index]),
			sample_fraction * STAGE_SIZE.y,
		))
	polygon.append(Vector2(STAGE_SIZE.x, STAGE_SIZE.y))
	return polygon


func _draw_horizontal_hatched_tide_polygon(
	polygon: PackedVector2Array,
) -> void:
	var hatch_color := Color.WHITE
	hatch_color.a = TIDE_HATCH_ALPHA
	for hatch_index in range(TIDE_HATCH_LINE_COUNT):
		var line_y := (
			TIDE_FIRST_HATCH_Y
			+ float(hatch_index) * TIDE_HATCH_PERIOD_PIXELS
		)
		var minimum_x := INF
		var maximum_x := -INF
		for vertex_index in range(polygon.size()):
			var start: Vector2 = polygon[vertex_index]
			var finish: Vector2 = polygon[(vertex_index + 1) % polygon.size()]
			if not (
				(start.y <= line_y and finish.y > line_y)
				or (finish.y <= line_y and start.y > line_y)
			):
				continue
			var edge_fraction := (line_y - start.y) / (finish.y - start.y)
			var intersection_x := lerpf(start.x, finish.x, edge_fraction)
			minimum_x = minf(minimum_x, intersection_x)
			maximum_x = maxf(maximum_x, intersection_x)
		if is_finite(minimum_x) and maximum_x > minimum_x:
			_draw_capped_line(
				Vector2(minimum_x, line_y),
				Vector2(maximum_x, line_y),
				hatch_color,
				TIDE_HATCH_LINE_WIDTH_PIXELS,
			)


func _tide_line_length(normalized_height: float) -> float:
	return lerpf(
		TIDE_LINE_MIN_LENGTH_PIXELS,
		TIDE_LINE_MAX_LENGTH_PIXELS,
		clampf(normalized_height, 0.0, 1.0),
	)


func _update_tide_fifo(
	p_tide_series: PackedFloat32Array,
	p_tide_sample_position: float,
) -> void:
	if p_tide_series.is_empty():
		tide_series = PackedFloat32Array()
		tide_fifo_values.clear()
		tide_sample_position = 0.0
		return
	if tide_series.size() != p_tide_series.size():
		tide_series = p_tide_series.duplicate()
	tide_sample_position = fposmod(
		p_tide_sample_position,
		float(tide_series.size()),
	)
	tide_fifo_values.clear()
	for sample_index in range(TIDE_WINDOW_SAMPLE_COUNT):
		var hour_offset := float(sample_index) - TIDE_WINDOW_HALF_HOURS
		tide_fifo_values.append(_wrapped_tide_sample(
			tide_sample_position + hour_offset
		))


func _wrapped_tide_sample(sample_position: float) -> float:
	var wrapped_position := fposmod(sample_position, float(tide_series.size()))
	var first_index := floori(wrapped_position)
	var second_index := (first_index + 1) % tide_series.size()
	var fraction := wrapped_position - floorf(wrapped_position)
	return lerpf(
		float(tide_series[first_index]),
		float(tide_series[second_index]),
		fraction,
	)


func _draw_budget_panel() -> void:
	_draw_vertical_text(Vector2(1405.0, 205.0), "BASIN WATER BUDGET", -1.0, 24, BLUE)
	_draw_vertical_text(Vector2(1510.0, 205.0), "INPUT", -1.0, 24, WHITE)
	_draw_vertical_text(Vector2(1545.0, 205.0), "%.1f%%" % (input_rate * 100.0), -1.0, 24, WHITE, _tabular_font)
	_draw_vertical_text(Vector2(1640.0, 205.0), "TOTAL EXTRACTION", -1.0, 24, WHITE)
	_draw_vertical_text(Vector2(1675.0, 205.0), _formatted_extraction_percentage(), -1.0, 24, WHITE, _tabular_font)
	_draw_vertical_text(Vector2(1770.0, 205.0), "DELTA REMAINDER", -1.0, 24, BLUE)
	_draw_vertical_text(Vector2(1805.0, 205.0), "%.1f%%" % (remaining_rate * 100.0), -1.0, 24, BLUE, _tabular_font)


func _formatted_extraction_percentage() -> String:
	# Exclusive Watershed without an applied AI allocation has no defensible
	# extraction percentage. Render a pending value instead of a misleading 0%.
	if (
		_regime_active(WATERSHED_REGIME_INDEX)
		and watershed_allocation_state.is_empty()
	):
		return "—"
	return "%.1f%%" % (extraction_fraction * 100.0)


func _draw_vertical_text(
	anchor: Vector2,
	text: String,
	width: float,
	font_size: int,
	color: Color,
	font: Font = FONT,
) -> void:
	draw_set_transform(anchor, TYPE_ROTATION_RADIANS, Vector2.ONE)
	draw_string(
		font,
		Vector2.ZERO,
		text,
		HORIZONTAL_ALIGNMENT_LEFT,
		width,
		font_size,
		color,
	)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


func _vertical_text_rect(anchor: Vector2, text: String, font_size: int) -> Rect2:
	var text_width := FONT.get_string_size(
		text,
		HORIZONTAL_ALIGNMENT_LEFT,
		-1.0,
		font_size,
	).x
	var font_ascent := FONT.get_ascent(font_size)
	var font_descent := FONT.get_descent(font_size)
	return Rect2(
		anchor + Vector2(-font_ascent, -text_width),
		Vector2(font_ascent + font_descent, text_width),
	)


func _regime_active(index: int) -> bool:
	return index >= 0 and index < active_states.size() and bool(active_states[index])
